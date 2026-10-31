//! Native ext2/3/4 empty layout and record encoding; only CRC primitives reused.
const std = @import("std");
const root = @import("root.zig");
const c = root.c;
const model = @import("../../model.zig");
const s = @import("../../semantic.zig");
const mutation = @import("../../mutation.zig");
pub const Group = struct { first: u64, count: u32, bitmap: u64, inode_bitmap: u64, inode_table: u64, backup: bool };
pub const Geometry = struct {
    bytes: u64,
    block: u32,
    blocks: u64,
    per_group: u32,
    inodes_per_group: u32,
    inode_blocks: u32,
    descriptor_size: u32,
    descriptor_blocks: u32,
    groups: []Group,
    reserved: []const model.Range,
    filesystem: model.Filesystem,
};
fn backup(group: u64) bool {
    if (group <= 1) return true;
    for ([_]u64{ 3, 5, 7 }) |base| {
        var value = group;
        while (value % base == 0) value /= base;
        if (value == 1) return true;
    }
    return false;
}
pub fn describe(a: std.mem.Allocator, bytes: u64, sector: u32, filesystem: model.Filesystem) !*Geometry {
    const block = @max(4096, sector);
    if (bytes < 16 * 1024 * 1024 or bytes % block != 0 or bytes / block > root.MAX_SCAN_BLOCKS) return error.ExtInvalidCreateSize;
    const blocks = bytes / block;
    const per_group = block * 8;
    const count = try std.math.divCeil(u64, blocks, per_group);
    const descriptor_size: u32 = if (filesystem == .ext4) 64 else 32;
    const descriptor_blocks: u32 = @intCast(try std.math.divCeil(u64, count * descriptor_size, block));
    const inodes = try std.math.divCeil(u64, bytes / 16384, count);
    const per_inode_block = block / 256;
    const ipg: u32 = @intCast(std.mem.alignForward(u64, @max(inodes, 16), per_inode_block));
    if (@as(u64, ipg) * count > root.MAX_SCAN_INODES or ipg > block * 8) return error.ExtScanBudgetExceeded;
    const inode_blocks = ipg / per_inode_block;
    const groups = try a.alloc(Group, @intCast(count));
    var reserved: std.ArrayList(model.Range) = .empty;
    for (groups, 0..) |*g, index| {
        const first = @as(u64, index) * per_group;
        const n: u32 = @intCast(@min(per_group, blocks - first));
        const sb = backup(index);
        const table_start = first + if (sb) @as(u64, 1) + descriptor_blocks else 0;
        if (table_start + 2 + inode_blocks >= first + n) return error.ExtInvalidCreateSize;
        g.* = .{ .first = first, .count = n, .bitmap = table_start, .inode_bitmap = table_start + 1, .inode_table = table_start + 2, .backup = sb };
        try reserved.append(a, .{ .offset = first * block, .length = (table_start - first + 2 + inode_blocks) * block });
    }
    const result = try a.create(Geometry);
    result.* = .{ .bytes = bytes, .block = block, .blocks = blocks, .per_group = per_group, .inodes_per_group = ipg, .inode_blocks = inode_blocks, .descriptor_size = descriptor_size, .descriptor_blocks = descriptor_blocks, .groups = groups, .reserved = try reserved.toOwnedSlice(a), .filesystem = filesystem };
    return result;
}
pub fn requirements(a: std.mem.Allocator, g: *const Geometry) ![]s.Requirement {
    var list: std.ArrayList(s.Requirement) = .empty;
    for ([_]u64{ 1, 2 }) |id| try list.append(a, .{ .id = id, .bytes = g.block, .granule = g.block, .alignment = g.block, .bounds = .{ .offset = 0, .length = g.bytes } });
    if (g.filesystem != .ext2) {
        try list.append(a, .{ .id = 3, .bytes = @as(u64, 1024) * g.block, .granule = 1024 * g.block, .alignment = g.block, .bounds = .{ .offset = 0, .length = g.bytes } });
        if (g.filesystem == .ext3) try list.append(a, .{ .id = 4, .bytes = g.block, .granule = g.block, .alignment = g.block, .bounds = .{ .offset = 0, .length = g.bytes } });
    }
    return list.toOwnedSlice(a);
}
fn put(comptime T: type, b: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, b[at..][0..@sizeOf(T)], value, .little);
}
fn crc(seed: u32, b: []const u8) u32 {
    return c.ext2fs_crc32c_le(seed, b.ptr, b.len);
}
fn setBit(b: []u8, index: u64) void {
    b[@intCast(index / 8)] |= @as(u8, 1) << @intCast(index % 8);
}
fn place(placements: []const s.Placement, id: u64, block: u32) !u64 {
    for (placements) |p| if (p.id == id and p.ranges.len == 1) return p.ranges[0].offset / block;
    return error.MissingAllocationPlacement;
}
fn inode(seed: u32, g: *const Geometry, number: u32, is_directory: bool, data: u64, length: u64, indirect: ?u64, links: u16) [256]u8 {
    var out: [256]u8 = @splat(0);
    put(u16, &out, 0, if (is_directory) 0x41ed else 0x8180);
    put(u32, &out, 4, @truncate(length));
    put(u32, &out, 108, @intCast(length >> 32));
    put(u16, &out, 26, links);
    put(u32, &out, 28, @intCast((length / g.block + @as(u64, @intFromBool(indirect != null))) * (g.block / 512)));
    put(u16, &out, 128, 32);
    if (g.filesystem == .ext4) {
        put(u32, &out, 32, 0x80000);
        put(u16, &out, 40, 0xf30a);
        put(u16, &out, 42, 1);
        put(u16, &out, 44, 4);
        put(u16, &out, 56, @intCast(length / g.block));
        put(u16, &out, 58, @intCast(data >> 32));
        put(u32, &out, 60, @truncate(data));
    } else {
        for (0..@intCast(@min(12, length / g.block))) |i| put(u32, &out, 40 + i * 4, @intCast(data + i));
        if (indirect) |b| put(u32, &out, 88, @intCast(b));
    }
    if (g.filesystem == .ext4) {
        var id: [4]u8 = undefined;
        put(u32, &id, 0, number);
        const hash = crc(crc(crc(seed, &id), &.{ 0, 0, 0, 0 }), &out);
        put(u16, &out, 124, @truncate(hash));
        put(u16, &out, 130, @truncate(hash >> 16));
    }
    return out;
}
fn directory(a: std.mem.Allocator, g: *const Geometry, seed: u32, number: u32, parent: u32, lost: bool) ![]u8 {
    const b = try a.alloc(u8, g.block);
    @memset(b, 0);
    const usable = g.block - @as(u32, if (g.filesystem == .ext4) 12 else 0);
    put(u32, b, 0, number);
    put(u16, b, 4, 12);
    b[6] = 1;
    b[7] = 2;
    b[8] = '.';
    put(u32, b, 12, parent);
    put(u16, b, 16, @intCast(if (lost) 12 else usable - 12));
    b[18] = 2;
    b[19] = 2;
    @memcpy(b[20..22], "..");
    if (lost) {
        put(u32, b, 24, 11);
        put(u16, b, 28, @intCast(usable - 24));
        b[30] = 10;
        b[31] = 2;
        @memcpy(b[32..42], "lost+found");
    }
    if (g.filesystem == .ext4) {
        put(u16, b, usable + 4, 12);
        b[usable + 7] = 0xde;
        var id: [4]u8 = undefined;
        put(u32, &id, 0, number);
        put(u32, b, usable + 8, crc(crc(crc(seed, &id), &.{ 0, 0, 0, 0 }), b[0..usable]));
    }
    return b;
}
pub fn encode(a: std.mem.Allocator, io: std.Io, target: model.Target, g: *const Geometry, placements: []const s.Placement) !mutation.MutationSet {
    const root_block = try place(placements, 1, g.block);
    const lost_block = try place(placements, 2, g.block);
    const journal = if (g.filesystem != .ext2) try place(placements, 3, g.block) else 0;
    const indirect: ?u64 = if (g.filesystem == .ext3) try place(placements, 4, g.block) else null;
    var sb = std.mem.zeroes(c.struct_ext2_super_block);
    sb.s_inodes_count = @intCast(@as(u64, g.inodes_per_group) * g.groups.len);
    sb.s_log_block_size = std.math.log2_int(u32, g.block) - 10;
    sb.s_log_cluster_size = sb.s_log_block_size;
    sb.s_blocks_per_group = g.per_group;
    sb.s_clusters_per_group = g.per_group;
    sb.s_inodes_per_group = g.inodes_per_group;
    sb.s_magic = c.EXT2_SUPER_MAGIC;
    sb.s_state = c.EXT2_VALID_FS;
    sb.s_errors = c.EXT2_ERRORS_RO;
    sb.s_max_mnt_count = @bitCast(@as(i16, -1));
    sb.s_rev_level = 1;
    sb.s_first_ino = 11;
    sb.s_inode_size = 256;
    sb.s_feature_compat = c.EXT2_FEATURE_COMPAT_EXT_ATTR | c.EXT2_FEATURE_COMPAT_DIR_INDEX;
    sb.s_feature_incompat = c.EXT2_FEATURE_INCOMPAT_FILETYPE;
    sb.s_feature_ro_compat = c.EXT2_FEATURE_RO_COMPAT_SPARSE_SUPER | c.EXT2_FEATURE_RO_COMPAT_LARGE_FILE;
    std.Io.random(io, &sb.s_uuid);
    sb.s_uuid[6] = (sb.s_uuid[6] & 15) | 0x40;
    sb.s_uuid[8] = (sb.s_uuid[8] & 63) | 0x80;
    if (g.filesystem != .ext2) {
        sb.s_feature_compat |= c.EXT3_FEATURE_COMPAT_HAS_JOURNAL;
        sb.s_journal_inum = 8;
    }
    if (g.filesystem == .ext4) {
        sb.s_feature_incompat |= c.EXT3_FEATURE_INCOMPAT_EXTENTS | c.EXT4_FEATURE_INCOMPAT_64BIT;
        sb.s_feature_ro_compat |= c.EXT4_FEATURE_RO_COMPAT_METADATA_CSUM | c.EXT4_FEATURE_RO_COMPAT_EXTRA_ISIZE | c.EXT4_FEATURE_RO_COMPAT_HUGE_FILE | c.EXT4_FEATURE_RO_COMPAT_DIR_NLINK;
        sb.s_desc_size = 64;
        sb.s_min_extra_isize = 32;
        sb.s_want_extra_isize = 32;
        sb.s_checksum_type = 1;
    }
    c.ext2fs_blocks_count_set(&sb, g.blocks);
    const seed = crc(0xffffffff, &sb.s_uuid);
    var collector: mutation.Collector = .{ .allocator = a, .target = target };
    const descriptors = try a.alloc(u8, @as(usize, g.descriptor_blocks) * g.block);
    @memset(descriptors, 0);
    var free_blocks: u64 = 0;
    for (g.groups, 0..) |group, index| {
        const bits = try a.alloc(u8, g.block);
        @memset(bits, 0);
        const inode_bits = try a.alloc(u8, g.block);
        @memset(inode_bits, 0);
        const end = group.inode_table + g.inode_blocks;
        for (@intCast(group.first)..@intCast(end)) |b| setBit(bits, b - group.first);
        for (placements) |p| for (p.ranges) |r| {
            var b = r.offset / g.block;
            while (b < try r.end() / g.block) : (b += 1) if (b >= group.first and b < group.first + group.count) setBit(bits, b - group.first);
        };
        var allocated: u32 = 0;
        for (0..group.count) |bit| if (bits[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0) {
            allocated += 1;
        };
        for (group.count..g.per_group) |bit| setBit(bits, bit);
        const used_inodes: u32 = if (index == 0) 11 else 0;
        for (0..used_inodes) |bit| setBit(inode_bits, bit);
        for (g.inodes_per_group..g.block * 8) |bit| setBit(inode_bits, bit);
        const desc = descriptors[index * g.descriptor_size ..][0..g.descriptor_size];
        put(u32, desc, 0, @intCast(group.bitmap));
        put(u32, desc, 4, @intCast(group.inode_bitmap));
        put(u32, desc, 8, @intCast(group.inode_table));
        put(u16, desc, 12, @intCast(group.count - allocated));
        put(u16, desc, 14, @intCast(g.inodes_per_group - used_inodes));
        put(u16, desc, 16, if (index == 0) 2 else 0);
        put(u16, desc, 18, 4);
        free_blocks += group.count - allocated;
        if (g.filesystem == .ext4) {
            put(u16, desc, 28, @intCast(g.inodes_per_group - used_inodes));
            const bc = crc(seed, bits);
            const ic = crc(seed, inode_bits[0 .. g.inodes_per_group / 8]);
            put(u16, desc, 24, @truncate(bc));
            put(u16, desc, 26, @truncate(ic));
            put(u16, desc, 56, @truncate(bc >> 16));
            put(u16, desc, 58, @truncate(ic >> 16));
            var group_number: [4]u8 = undefined;
            put(u32, &group_number, 0, @intCast(index));
            put(u16, desc, 30, @truncate(crc(crc(seed, &group_number), desc)));
        }
        try collector.write(group.bitmap * g.block, bits);
        try collector.write(group.inode_bitmap * g.block, inode_bits);
        const table = try a.alloc(u8, @as(usize, g.inode_blocks) * g.block);
        @memset(table, 0);
        if (index == 0) {
            @memcpy(table[256..512], &inode(seed, g, 2, true, root_block, g.block, null, 3));
            @memcpy(table[10 * 256 .. 11 * 256], &inode(seed, g, 11, true, lost_block, g.block, null, 2));
            if (journal != 0) @memcpy(table[7 * 256 .. 8 * 256], &inode(seed, g, 8, false, journal, @as(u64, 1024) * g.block, indirect, 1));
        }
        try collector.write(group.inode_table * g.block, table);
    }
    sb.s_free_inodes_count = sb.s_inodes_count - 11;
    c.ext2fs_free_blocks_count_set(&sb, free_blocks);
    try collector.write(root_block * g.block, try directory(a, g, seed, 2, 2, true));
    try collector.write(lost_block * g.block, try directory(a, g, seed, 11, 2, false));
    if (journal != 0) {
        const bytes = try a.alloc(u8, 1024 * g.block);
        @memset(bytes, 0);
        std.mem.writeInt(u32, bytes[0..4], 0xc03b3998, .big);
        std.mem.writeInt(u32, bytes[4..8], 4, .big);
        std.mem.writeInt(u32, bytes[12..16], g.block, .big);
        std.mem.writeInt(u32, bytes[16..20], 1024, .big);
        std.mem.writeInt(u32, bytes[20..24], 1, .big);
        std.mem.writeInt(u32, bytes[24..28], 1, .big);
        @memcpy(bytes[48..64], &sb.s_uuid);
        std.mem.writeInt(u32, bytes[64..68], 1, .big);
        try collector.write(journal * g.block, bytes);
        if (indirect) |b| {
            const pointers = try a.alloc(u8, g.block);
            @memset(pointers, 0);
            for (0..1012) |i| put(u32, pointers, i * 4, @intCast(journal + 12 + i));
            try collector.write(b * g.block, pointers);
        }
    }
    for (g.groups, 0..) |group, index| if (group.backup) {
        var copy = sb;
        copy.s_block_group_nr = @intCast(@min(index, 65535));
        if (g.filesystem == .ext4) copy.s_checksum = crc(0xffffffff, std.mem.asBytes(&copy)[0..1020]);
        try collector.write(if (index == 0) 1024 else group.first * g.block, std.mem.asBytes(&copy));
        try collector.write((group.first + 1) * g.block, descriptors);
    };
    const changes = try collector.finish();
    for (@constCast(changes.writes)) |*w| w.kind = .discard;
    return changes;
}
