//! ext semantic driver: shared placement, native layout, libext2fs record codecs.
const std = @import("std");
const s = @import("../../semantic.zig");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
const mutation = @import("../../mutation.zig");
const Builder = @import("../../mutation.zig").Builder;
const root = @import("root.zig");
const c = root.c;
const create = @import("create.zig");
const Session = @import("io.zig").Session;
const FORMAT_IDS = [_]model.Filesystem{ .ext2, .ext3, .ext4 };
pub const DRIVERS = init: {
    var list: [3]s.Driver = undefined;
    for (&list, &FORMAT_IDS) |*entry, *id| entry.* = .{ .filesystem = id.*, .context = id, .operations = &root.OPERATIONS, .vtable = &.{ .probe = root.probe, .open = open } };
    break :init list;
};
const Meta = struct { group: u32, kind: enum { block_bitmap, inode_bitmap, inode_table }, source: model.Range };
const Node = struct { number: u32, inode: []align(8) u8, directory: bool };
const ResizeGeometry = struct { blocks: u64, groups: u32, desc_blocks: u64, inodes: u32, reserved: []const model.Range };
const State = struct {
    a: std.mem.Allocator,
    io: std.Io,
    reader: device.Reader,
    format: model.Filesystem,
    snapshot: model.Snapshot,
    session: ?*Session = null,
    nodes: ?[]Node = null,
    units: ?[]s.AllocationUnit = null,
    metadata: []Meta = &.{},
    desired: ?*ResizeGeometry = null,
    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }
    fn load(self: *@This()) !*Session {
        if (self.session == null) {
            self.session = try Session.open(self.a, self.io, self.reader);
            try self.session.?.check(c.ext2fs_read_bitmaps(self.session.?.fs));
        }
        return self.session.?;
    }
    fn objects(self: *@This()) ![]Node {
        if (self.nodes) |nodes| return nodes;
        const session = try self.load();
        const fs = session.fs;
        var nodes: std.ArrayList(Node) = .empty;
        var scan: c.ext2_inode_scan = null;
        try session.check(c.ext2fs_open_inode_scan(fs, 0, &scan));
        defer c.ext2fs_close_inode_scan(scan);
        const size = fs.*.super.*.s_inode_size;
        const buffer = try self.a.alignedAlloc(u8, .@"8", size);
        while (true) {
            var number: u32 = 0;
            try session.check(c.ext2fs_get_next_inode_full(scan, &number, @ptrCast(@alignCast(buffer.ptr)), size));
            if (number == 0) break;
            if (c.ext2fs_test_inode_bitmap2(fs.*.inode_map, number) == 0) continue;
            const inode: *const c.struct_ext2_inode = @ptrCast(@alignCast(buffer.ptr));
            if (inode.i_links_count == 0 and number != c.EXT2_RESIZE_INO and number != c.EXT2_BAD_INO) continue;
            try nodes.append(self.a, .{ .number = number, .inode = try recordCopy(self.a, buffer), .directory = inode.i_mode & 0xf000 == 0x4000 });
        }
        self.nodes = try nodes.toOwnedSlice(self.a);
        return self.nodes.?;
    }
    fn allocations(self: *@This()) ![]s.AllocationUnit {
        if (self.units) |units| return units;
        const session = try self.load();
        const fs = session.fs;
        const sb = fs.*.super.*;
        if (self.desired == null) _ = try geometry(self, .{ .operation = .query });
        const desired = self.desired.?;
        var old_fixed: c.ext2fs_block_bitmap = null;
        try session.check(c.ext2fs_allocate_block_bitmap(fs, "reserved geometry", &old_fixed));
        defer c.ext2fs_free_block_bitmap(old_fixed);
        var metadata: std.ArrayList(Meta) = .empty;
        var units: std.ArrayList(s.AllocationUnit) = .empty;
        const block = fs.*.blocksize;
        for (0..fs.*.group_desc_count) |index| {
            const group: u32 = @intCast(index);
            _ = c.ext2fs_reserve_super_and_bgd(fs, group, old_fixed);
            for ([_]Meta{
                .{ .group = group, .kind = .block_bitmap, .source = .{ .offset = c.ext2fs_block_bitmap_loc(fs, group) * block, .length = block } },
                .{ .group = group, .kind = .inode_bitmap, .source = .{ .offset = c.ext2fs_inode_bitmap_loc(fs, group) * block, .length = block } },
                .{ .group = group, .kind = .inode_table, .source = .{ .offset = c.ext2fs_inode_table_loc(fs, group) * block, .length = @as(u64, fs.*.inode_blocks_per_group) * block } },
            }) |m| {
                try metadata.append(self.a, m);
                var table_block = m.source.offset / block;
                while (table_block < try m.source.end() / block) : (table_block += 1) _ = c.ext2fs_mark_block_bitmap2(old_fixed, table_block);
                if (group < desired.groups) try units.append(self.a, .{ .id = metaId(group, m.kind), .owner = metaId(group, m.kind), .sources = try self.a.dupe(model.Range, &.{m.source}), .content_bytes = m.source.length });
            }
        }
        const ranges = try metadata.toOwnedSlice(self.a);
        self.metadata = ranges;
        var owners: std.AutoHashMap(u64, u64) = .init(self.a);
        defer owners.deinit();
        for (try self.objects()) |node| {
            var owner: Owner = .{ .map = &owners, .inode = node.number };
            try session.check(c.ext2fs_block_iterate3(fs, node.number, c.BLOCK_FLAG_READ_ONLY, null, collectOwner, &owner));
            if (owner.failure) |err| return err;
        }
        var b: u64 = sb.s_first_data_block;
        while (b < c.ext2fs_blocks_count(fs.*.super)) : (b += 1) {
            if (c.ext2fs_test_block_bitmap2(fs.*.block_map, b) == 0 or c.ext2fs_test_block_bitmap2(old_fixed, b) != 0) continue;
            const range: model.Range = .{ .offset = b * block, .length = block };
            try units.append(self.a, .{ .id = b + 1, .owner = owners.get(b) orelse 0, .sources = try self.a.dupe(model.Range, &.{range}), .content_bytes = block });
        }
        self.units = try units.toOwnedSlice(self.a);
        return self.units.?;
    }
};
const Owner = struct { map: *std.AutoHashMap(u64, u64), inode: u32, failure: ?anyerror = null };
fn collectOwner(_: c.ext2_filsys, block: [*c]c.blk64_t, _: c.e2_blkcnt_t, _: c.blk64_t, _: c_int, ctx: ?*anyopaque) callconv(.c) c_int {
    const owner: *Owner = @ptrCast(@alignCast(ctx.?));
    if (block.* == 0) return 0;
    owner.map.put(block.*, owner.inode) catch |err| {
        owner.failure = err;
        return c.BLOCK_ABORT;
    };
    return 0;
}
fn metaId(group: u32, kind: @FieldType(Meta, "kind")) u64 {
    return (@as(u64, 1) << 63) | @as(u64, group) * 3 + @backingInt(kind);
}
fn open(ctx: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader, blank: bool) !s.Filesystem {
    const format = @as(*const model.Filesystem, @ptrCast(@alignCast(ctx))).*;
    const snapshot: model.Snapshot = if (blank) .{ .filesystem = format, .target = reader.target, .generation = 0, .block_size = reader.target.sector_size, .filesystem_bytes = 0, .clean = true, .capabilities = &root.OPERATIONS } else try root.inspect(ctx, a, io, reader);
    const state = try a.create(State);
    state.* = .{ .a = a, .io = io, .reader = reader, .format = format, .snapshot = snapshot };
    return .{ .context = state, .vtable = &OPS };
}
fn close(ctx: *anyopaque) void {
    const state = State.cast(ctx);
    if (state.session) |session| session.close();
    state.a.destroy(state);
}
fn inspect(ctx: *anyopaque) !model.Snapshot {
    return State.cast(ctx).snapshot;
}
fn object(ctx: *anyopaque, cursor: *s.Cursor) !?s.Object {
    const state = State.cast(ctx);
    if (state.snapshot.filesystem_bytes == 0) return null;
    const nodes = try state.objects();
    _ = try state.allocations();
    if (cursor.index < nodes.len) {
        const n = nodes[cursor.index];
        cursor.index += 1;
        const inode: *const c.struct_ext2_inode = @ptrCast(@alignCast(n.inode.ptr));
        const bytes = @as(u64, inode.i_size) | (if (inode.i_mode & 0xf000 == 0x8000) @as(u64, inode.i_size_high) << 32 else 0);
        return .{ .id = n.number, .kind = if (n.number < 11 and n.number != 2) .metadata else if (n.directory) .directory else .file, .bytes = bytes };
    }
    const index = cursor.index - nodes.len;
    if (index < state.metadata.len) {
        const m = state.metadata[index];
        cursor.index += 1;
        return .{ .id = metaId(m.group, m.kind), .kind = .metadata, .bytes = m.source.length };
    }
    if (index == state.metadata.len) {
        cursor.index += 1;
        return .{ .id = 0, .kind = .reserved, .bytes = 0 };
    }
    return null;
}

fn allocation(ctx: *anyopaque, cursor: *s.Cursor) !?s.AllocationUnit {
    const state = State.cast(ctx);
    if (state.snapshot.filesystem_bytes == 0) return null;
    const units = try state.allocations();
    if (cursor.index >= units.len) return null;
    const unit = units[cursor.index];
    cursor.index += 1;
    return unit;
}
fn configure(session: *Session, fs: c.ext2_filsys, g: *const ResizeGeometry) !void {
    const old_bytes = fs.*.desc_blocks * fs.*.blocksize;
    const new_bytes = g.desc_blocks * fs.*.blocksize;
    if (new_bytes > old_bytes) try session.check(c.ext2fs_resize_mem(old_bytes, new_bytes, @ptrCast(&fs.*.group_desc)));
    if (new_bytes > old_bytes) @memset(@as([*]u8, @ptrCast(fs.*.group_desc.?))[old_bytes..new_bytes], 0);
    c.ext2fs_blocks_count_set(fs.*.super, g.blocks);
    fs.*.group_desc_count = g.groups;
    fs.*.desc_blocks = g.desc_blocks;
    fs.*.super.*.s_inodes_count = g.inodes;
    fs.*.super.*.s_overhead_clusters = 0;
}
fn geometry(ctx: *anyopaque, intent: s.Intent) !s.Geometry {
    const state = State.cast(ctx);
    if (intent.operation == .create) {
        const g = try create.describe(state.a, state.reader.target.capacity, state.reader.target.sector_size, state.format);
        return .{ .bytes = g.bytes, .allocation_size = g.block, .reserved = g.reserved, .private = g };
    }
    const session = try state.load();
    const old = session.fs;
    const bytes = if (intent.operation == .grow or intent.operation == .shrink) intent.bytes else state.snapshot.filesystem_bytes;
    if (bytes < 16 * 1024 * 1024 or bytes > state.reader.target.capacity or bytes % old.*.blocksize != 0) return error.ExtInvalidResizeSize;
    if ((intent.operation == .grow and bytes < state.snapshot.filesystem_bytes) or (intent.operation == .shrink and bytes > state.snapshot.filesystem_bytes)) return error.ExtInvalidResizeDirection;
    if (old.*.super.*.s_feature_compat & c.EXT4_FEATURE_COMPAT_SPARSE_SUPER2 != 0) return error.ExtUnsupportedFeature;
    const blocks = bytes / old.*.blocksize;
    const groups: u32 = @intCast(try std.math.divCeil(u64, blocks - old.*.super.*.s_first_data_block, old.*.super.*.s_blocks_per_group));
    const desc_size: u32 = if (old.*.super.*.s_feature_incompat & c.EXT4_FEATURE_INCOMPAT_64BIT != 0) old.*.super.*.s_desc_size else 32;
    const g = try state.a.create(ResizeGeometry);
    g.* = .{ .blocks = blocks, .groups = groups, .desc_blocks = try std.math.divCeil(u64, @as(u64, groups) * desc_size, old.*.blocksize), .inodes = try std.math.mul(u32, groups, old.*.super.*.s_inodes_per_group), .reserved = &.{} };
    var copy: c.ext2_filsys = null;
    try session.check(c.ext2fs_dup_handle(old, &copy));
    defer c.ext2fs_free(copy);
    // Existing reserved descriptor blocks are consumed only by explicit layout
    // growth; shrinking keeps their physical reservation until re-encoded.
    if (g.desc_blocks > copy.*.desc_blocks) {
        const delta = g.desc_blocks - copy.*.desc_blocks;
        if (delta > copy.*.super.*.s_reserved_gdt_blocks) return error.ExtDescriptorReservationExhausted;
        copy.*.super.*.s_reserved_gdt_blocks -= @intCast(delta);
    }
    try configure(session, copy, g);
    var fixed: c.ext2fs_block_bitmap = null;
    try session.check(c.ext2fs_allocate_block_bitmap(copy, "target reservations", &fixed));
    defer c.ext2fs_free_block_bitmap(fixed);
    for (0..groups) |group| _ = c.ext2fs_reserve_super_and_bgd(copy, @intCast(group), fixed);
    var reserved: std.ArrayList(model.Range) = .empty;
    if (copy.*.super.*.s_first_data_block != 0) try reserved.append(state.a, .{ .offset = 0, .length = copy.*.blocksize });
    var b: u64 = copy.*.super.*.s_first_data_block;
    while (b < blocks) {
        if (c.ext2fs_test_block_bitmap2(fixed, b) == 0) {
            b += 1;
            continue;
        }
        const start = b;
        b += 1;
        while (b < blocks and c.ext2fs_test_block_bitmap2(fixed, b) != 0) b += 1;
        try reserved.append(state.a, .{ .offset = start * copy.*.blocksize, .length = (b - start) * copy.*.blocksize });
    }
    g.reserved = try reserved.toOwnedSlice(state.a);
    state.desired = g;
    return .{ .bytes = bytes, .allocation_size = old.*.blocksize, .reserved = g.reserved, .private = g };
}
fn requirements(ctx: *anyopaque, intent: s.Intent, desired: s.Geometry, _: []const s.Placement) !s.Requirements {
    const state = State.cast(ctx);
    if (intent.operation == .create) return .{ .units = &.{}, .additional = try create.requirements(state.a, @ptrCast(@alignCast(desired.private))) };
    if (intent.operation == .repair) return .{ .units = &.{} };
    const session = try state.load();
    const fs = session.fs;
    const g = state.desired.?;
    const units = try state.allocations();
    const reqs = try state.a.alloc(s.Requirement, units.len);
    for (units, reqs) |u, *r| {
        var bounds: model.Range = .{ .offset = @as(u64, fs.*.super.*.s_first_data_block) * fs.*.blocksize, .length = desired.bytes - @as(u64, fs.*.super.*.s_first_data_block) * fs.*.blocksize };
        if (u.id >> 63 != 0 and fs.*.super.*.s_feature_incompat & c.EXT4_FEATURE_INCOMPAT_FLEX_BG == 0) {
            const group = @as(u32, @intCast((u.id & ~(@as(u64, 1) << 63)) / 3));
            bounds.offset = c.ext2fs_group_first_block2(fs, group) * fs.*.blocksize;
            bounds.length = @min(@as(u64, fs.*.super.*.s_blocks_per_group) * fs.*.blocksize, desired.bytes - bounds.offset);
        }
        r.* = .{ .id = u.id, .bytes = u.content_bytes, .granule = @intCast(u.content_bytes), .alignment = fs.*.blocksize, .bounds = bounds };
    }
    var additional: std.ArrayList(s.Requirement) = .empty;
    for (@min(fs.*.group_desc_count, g.groups)..g.groups) |group| {
        const first = (@as(u64, fs.*.super.*.s_first_data_block) + group * fs.*.super.*.s_blocks_per_group) * fs.*.blocksize;
        const bounds: model.Range = .{ .offset = first, .length = @min(@as(u64, fs.*.super.*.s_blocks_per_group) * fs.*.blocksize, desired.bytes - first) };
        for ([_]@FieldType(Meta, "kind"){ .block_bitmap, .inode_bitmap, .inode_table }) |kind| {
            const size: u32 = if (kind == .inode_table) fs.*.inode_blocks_per_group * fs.*.blocksize else fs.*.blocksize;
            try additional.append(state.a, .{ .id = metaId(@intCast(group), kind), .bytes = size, .granule = size, .alignment = fs.*.blocksize, .bounds = bounds });
        }
    }
    // Explicit reserve for format codecs which need new extent index nodes.
    // Unused reservations are not marked allocated in the resulting bitmap.
    try additional.append(state.a, .{ .id = std.math.maxInt(u64), .bytes = 32 * fs.*.blocksize, .granule = fs.*.blocksize, .alignment = fs.*.blocksize, .bounds = .{ .offset = @as(u64, fs.*.super.*.s_first_data_block) * fs.*.blocksize, .length = desired.bytes - @as(u64, fs.*.super.*.s_first_data_block) * fs.*.blocksize } });
    return .{ .units = reqs, .additional = try additional.toOwnedSlice(state.a) };
}
const Mapping = struct {
    blocks: std.AutoHashMap(u64, u64),
    inode_map: std.AutoHashMap(u32, u32),
    spare: []const model.Range,
    spare_used: usize = 0,
    block_size: u32,
    fn translate(self: *@This(), block: u64) u64 {
        return self.blocks.get(block) orelse block;
    }
};
fn translateBlock(_: c.ext2_filsys, block: [*c]c.blk64_t, _: c.e2_blkcnt_t, _: c.blk64_t, _: c_int, ctx: ?*anyopaque) callconv(.c) c_int {
    const map: *Mapping = @ptrCast(@alignCast(ctx.?));
    const next = map.translate(block.*);
    if (next == block.*) return 0;
    block.* = next;
    return c.BLOCK_CHANGED;
}
fn allocNode(fs: c.ext2_filsys, _: c.blk64_t, out: [*c]c.blk64_t) callconv(.c) c.errcode_t {
    const map: *Mapping = @ptrCast(@alignCast(fs.*.priv_data.?));
    if (map.spare_used == map.spare.len) return c.EXT2_ET_BLOCK_ALLOC_FAIL;
    out.* = map.spare[map.spare_used].offset / map.block_size;
    map.spare_used += 1;
    _ = c.ext2fs_mark_block_bitmap2(fs.*.block_map, out.*);
    return 0;
}
fn remapDirectory(_: c.ext2_ino_t, _: c_int, entry: [*c]c.struct_ext2_dir_entry, _: c_int, _: c_int, _: [*c]u8, ctx: ?*anyopaque) callconv(.c) c_int {
    const map: *Mapping = @ptrCast(@alignCast(ctx.?));
    if (map.inode_map.get(entry.*.inode)) |number| {
        entry.*.inode = number;
        return c.DIRENT_CHANGED;
    }
    return 0;
}
fn recordCopy(a: std.mem.Allocator, source: []const u8) ![]align(8) u8 {
    const bytes = try a.alignedAlloc(u8, .@"8", source.len);
    @memcpy(bytes, source);
    return bytes;
}
fn readRecord(state: *State, offset: u64, size: usize) ![]align(8) u8 {
    const bytes = try state.a.alignedAlloc(u8, .@"8", size);
    errdefer state.a.free(bytes);
    try state.reader.readInto(state.io, offset, bytes);
    return bytes;
}
fn little(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
/// Changing an inode identity changes the checksum seed of its tree records.
/// Validate against the old identity, then encode the explicitly chosen new one.
fn reseedExtents(state: *State, builder: *Builder, map: *Mapping, fs: c.ext2_filsys, old: u32, number: u32, header: []const u8, depth: usize) anyerror!void {
    if (header.len < 12 or depth > 5 or little(u16, header, 0) != 0xf30a) return error.ExtInvalidExtentTree;
    const count = little(u16, header, 2);
    const level = little(u16, header, 6);
    if (count > (header.len - 12) / 12 or level > 5 - depth) return error.ExtInvalidExtentTree;
    if (level == 0) return;
    for (0..count) |i| {
        const entry = header[12 + i * 12 ..][0..12];
        const block = @as(u64, little(u32, entry, 4)) | @as(u64, little(u16, entry, 8)) << 32;
        const bytes = try readRecord(state, try std.math.mul(u64, block, fs.*.blocksize), fs.*.blocksize);
        defer state.a.free(bytes);
        const h: *c.struct_ext3_extent_header = @ptrCast(@alignCast(bytes.ptr));
        if (little(u16, bytes, 6) + 1 != level or little(u16, bytes, 4) > (bytes.len - 16) / 12) return error.ExtInvalidExtentTree;
        if (c.ext2fs_extent_block_csum_verify((try state.load()).fs, old, h) == 0) return error.ExtExtentChecksum;
        try reseedExtents(state, builder, map, fs, old, number, bytes, depth + 1);
        try (try state.load()).check(c.ext2fs_extent_block_csum_set(fs, number, h));
        try builder.stageWrite(state.io, map.translate(block) * fs.*.blocksize, bytes);
    }
}
const DirectoryBlocks = struct {
    a: std.mem.Allocator,
    blocks: std.ArrayList(u64) = .empty,
    failure: ?anyerror = null,
    fn collect(_: c.ext2_filsys, block: [*c]c.blk64_t, count: c.e2_blkcnt_t, _: c.blk64_t, _: c_int, ctx: ?*anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (count < 0 or block.* == 0) return 0;
        self.blocks.append(self.a, block.*) catch |err| {
            self.failure = err;
            return c.BLOCK_ABORT;
        };
        return 0;
    }
};
fn reseedDirectory(state: *State, builder: *Builder, map: *Mapping, fs: c.ext2_filsys, old: u32, number: u32) !void {
    const original = try state.load();
    var blocks: DirectoryBlocks = .{ .a = state.a };
    defer blocks.blocks.deinit(state.a);
    try original.check(c.ext2fs_block_iterate3(original.fs, old, c.BLOCK_FLAG_READ_ONLY, null, DirectoryBlocks.collect, &blocks));
    if (blocks.failure) |err| return err;
    for (blocks.blocks.items) |block| {
        const bytes = try readRecord(state, block * fs.*.blocksize, fs.*.blocksize);
        defer state.a.free(bytes);
        const record: *c.struct_ext2_dir_entry = @ptrCast(@alignCast(bytes.ptr));
        if (c.ext2fs_dir_block_csum_verify(original.fs, old, record) == 0) return error.ExtDirectoryChecksum;
        try original.check(c.ext2fs_dir_block_csum_set(fs, number, record));
        try builder.stageWrite(state.io, map.translate(block) * fs.*.blocksize, bytes);
    }
}
fn encode(ctx: *anyopaque, intent: s.Intent, desired: s.Geometry, placements: []const s.Placement) !mutation.MutationSet {
    const state = State.cast(ctx);
    if (intent.operation == .create) return create.encode(state.a, state.io, state.reader.target, @ptrCast(@alignCast(desired.private)), placements);
    if (intent.operation == .repair) return @import("mutate.zig").prepare(.repair, state.a, state.io, state.reader, state.snapshot, 0);
    if (desired.bytes == state.snapshot.filesystem_bytes) return .{ .target = state.reader.target };
    const g = state.desired.?;
    var builder = Builder.init(state.a, state.reader);
    defer builder.deinit();
    var map: Mapping = .{ .blocks = .init(state.a), .inode_map = .init(state.a), .spare = &.{}, .block_size = desired.allocation_size };
    defer map.blocks.deinit();
    defer map.inode_map.deinit();
    const units = try state.allocations();
    for (placements) |p| {
        if (p.id == std.math.maxInt(u64)) {
            map.spare = p.ranges;
            continue;
        }
        for (units) |u| if (u.id == p.id) {
            const from = u.sources[0];
            const to = p.ranges[0];
            if (from.offset != to.offset) {
                var offset: u64 = 0;
                while (offset < from.length) : (offset += desired.allocation_size) try map.blocks.put((from.offset + offset) / desired.allocation_size, (to.offset + offset) / desired.allocation_size);
                // Codec reads of moved indirect records resolve to their source.
                try builder.mapRelocation(state.io, from.offset, to.offset, from.length);
            }
        };
    }
    const session = try Session.openStaged(state.a, state.io, &builder);
    defer session.close();
    const fs = session.fs;
    try session.check(c.ext2fs_read_bitmaps(fs));
    const previous_groups = fs.*.group_desc_count;
    const old_desc_blocks = fs.*.desc_blocks;
    if (g.desc_blocks > old_desc_blocks) fs.*.super.*.s_reserved_gdt_blocks -= @intCast(g.desc_blocks - old_desc_blocks);
    try configure(session, fs, g);
    c.ext2fs_free_block_bitmap(fs.*.block_map);
    fs.*.block_map = null;
    c.ext2fs_free_inode_bitmap(fs.*.inode_map);
    fs.*.inode_map = null;
    try session.check(c.ext2fs_allocate_block_bitmap(fs, "planned allocations", &fs.*.block_map));
    try session.check(c.ext2fs_allocate_inode_bitmap(fs, "planned inode identities", &fs.*.inode_map));
    for (0..g.groups) |group| _ = c.ext2fs_reserve_super_and_bgd(fs, @intCast(group), fs.*.block_map);
    for (placements) |p| {
        if (p.id == std.math.maxInt(u64)) continue;
        for (p.ranges) |r| {
            var b = r.offset / fs.*.blocksize;
            while (b < try r.end() / fs.*.blocksize) : (b += 1) _ = c.ext2fs_mark_block_bitmap2(fs.*.block_map, b);
        }
        if (p.id >> 63 != 0) {
            const value = p.id & ~(@as(u64, 1) << 63);
            const group: u32 = @intCast(value / 3);
            const block = p.ranges[0].offset / fs.*.blocksize;
            switch (value % 3) {
                0 => c.ext2fs_block_bitmap_loc_set(fs, group, block),
                1 => c.ext2fs_inode_bitmap_loc_set(fs, group, block),
                2 => {
                    c.ext2fs_inode_table_loc_set(fs, group, block);
                    if (group >= previous_groups) {
                        const zeros = try state.a.alloc(u8, @as(usize, fs.*.inode_blocks_per_group) * fs.*.blocksize);
                        @memset(zeros, 0);
                        try builder.stageWrite(state.io, block * fs.*.blocksize, zeros);
                    }
                },
                else => unreachable,
            }
        }
    }
    const nodes = try state.objects();
    for (1..fs.*.super.*.s_first_ino) |number| _ = c.ext2fs_mark_inode_bitmap2(fs.*.inode_map, @intCast(number));
    for (nodes) |node| {
        if (node.number <= g.inodes) _ = c.ext2fs_mark_inode_bitmap2(fs.*.inode_map, node.number);
    }
    var next_inode: u32 = fs.*.super.*.s_first_ino;
    for (nodes) |node| if (node.number > g.inodes) {
        while (next_inode <= g.inodes and c.ext2fs_test_inode_bitmap2(fs.*.inode_map, next_inode) != 0) next_inode += 1;
        if (next_inode > g.inodes) return error.ExtNoFreeInodes;
        try map.inode_map.put(node.number, next_inode);
        _ = c.ext2fs_mark_inode_bitmap2(fs.*.inode_map, next_inode);
    };
    fs.*.priv_data = &map;
    fs.*.get_alloc_block = allocNode;
    for (nodes) |node| {
        const number = map.inode_map.get(node.number) orelse node.number;
        const inode = try recordCopy(state.a, node.inode);
        const record: *c.struct_ext2_inode = @ptrCast(@alignCast(inode.ptr));
        const acl = c.ext2fs_file_acl_block(fs, record);
        c.ext2fs_file_acl_block_set(fs, record, map.translate(acl));
        try session.check(c.ext2fs_write_inode_full(fs, number, record, @intCast(inode.len)));
        if (acl != 0 and map.translate(acl) != acl) {
            const bytes = try readRecord(state, acl * fs.*.blocksize, fs.*.blocksize);
            defer state.a.free(bytes);
            const header: *c.struct_ext2_ext_attr_header = @ptrCast(@alignCast(bytes.ptr));
            if (c.ext2fs_ext_attr_block_csum_verify((try state.load()).fs, node.number, acl, header) == 0) return error.ExtAttributeChecksum;
            try session.check(c.ext2fs_ext_attr_block_csum_set(fs, number, map.translate(acl), header));
            try builder.stageWrite(state.io, map.translate(acl) * fs.*.blocksize, bytes);
        }
        if (number != node.number and fs.*.super.*.s_feature_ro_compat & c.EXT4_FEATURE_RO_COMPAT_METADATA_CSUM != 0) {
            if (record.i_flags & c.EXT4_EXTENTS_FL != 0) try reseedExtents(state, &builder, &map, fs, node.number, number, inode[40..100], 0);
            if (node.directory) try reseedDirectory(state, &builder, &map, fs, node.number, number);
        }

        // Library iteration only rewrites explicit references. Every allocation
        // request is satisfied by the common planner's reserved node slots.
        if (record.i_mode & 0xf000 == 0x8000 or node.directory or number == c.EXT2_RESIZE_INO or number == c.EXT2_BAD_INO) try session.check(c.ext2fs_block_iterate3(fs, number, 0, null, translateBlock, &map));
        if (node.directory and map.inode_map.count() != 0) try session.check(c.ext2fs_dir_iterate2(fs, number, 0, null, remapDirectory, &map));
    }
    if (fs.*.super.*.s_feature_compat & c.EXT2_FEATURE_COMPAT_RESIZE_INODE != 0) {
        var resize_inode: c.struct_ext2_inode = undefined;
        try session.check(c.ext2fs_read_inode(fs, c.EXT2_RESIZE_INO, &resize_inode));
        const zeros = try state.a.alloc(u8, fs.*.blocksize);
        @memset(zeros, 0);
        if (resize_inode.i_block[c.EXT2_DIND_BLOCK] != 0) {
            try builder.stageWrite(state.io, @as(u64, resize_inode.i_block[c.EXT2_DIND_BLOCK]) * fs.*.blocksize, zeros);
            resize_inode.i_blocks = fs.*.blocksize / 512;
            try session.check(c.ext2fs_write_inode(fs, c.EXT2_RESIZE_INO, &resize_inode));
        }
        const first = @as(u64, fs.*.super.*.s_first_data_block) + 1 + fs.*.desc_blocks;
        for (0..fs.*.super.*.s_reserved_gdt_blocks) |index| try builder.stageWrite(state.io, (first + index) * fs.*.blocksize, zeros);
        try session.check(c.ext2fs_create_resize_inode(fs));
    }
    for (0..g.groups) |index| {
        const group: u32 = @intCast(index);
        c.ext2fs_bg_flags_clear(fs, group, c.EXT2_BG_BLOCK_UNINIT | c.EXT2_BG_INODE_UNINIT);
        c.ext2fs_bg_flags_set(fs, group, c.EXT2_BG_INODE_ZEROED);
        if (group >= previous_groups) c.ext2fs_bg_used_dirs_count_set(fs, group, 0);
    }
    if (fs.*.super.*.s_orphan_file_inum != 0) fs.*.super.*.s_orphan_file_inum = map.inode_map.get(fs.*.super.*.s_orphan_file_inum) orelse fs.*.super.*.s_orphan_file_inum;
    try session.check(c.ext2fs_calculate_summary_stats(fs, 0));
    for (0..g.groups) |index| {
        const group: u32 = @intCast(index);
        if (fs.*.super.*.s_feature_ro_compat & (c.EXT4_FEATURE_RO_COMPAT_METADATA_CSUM | c.EXT4_FEATURE_RO_COMPAT_GDT_CSUM) == 0) {
            c.ext2fs_bg_flags_clear(fs, group, 0xffff);
            c.ext2fs_bg_itable_unused_set(fs, group, 0);
        }
        var directories: u32 = 0;
        for (nodes) |node| if (node.directory and ((map.inode_map.get(node.number) orelse node.number) - 1) / fs.*.super.*.s_inodes_per_group == group) {
            directories += 1;
        };
        c.ext2fs_bg_used_dirs_count_set(fs, group, directories);
    }
    fs.*.flags |= c.EXT2_FLAG_DIRTY | c.EXT2_FLAG_CHANGED | c.EXT2_FLAG_BB_DIRTY | c.EXT2_FLAG_IB_DIRTY;
    try session.check(c.ext2fs_flush(fs));
    return builder.finish(state.io, false);
}
fn check(ctx: *anyopaque) !model.Check {
    const state = State.cast(ctx);
    return root.check(&state.format, state.a, state.io, state.reader);
}
fn verify(ctx: *anyopaque, intent: s.Intent, reader: device.Reader) !model.Check {
    const state = State.cast(ctx);
    const snapshot = try root.inspect(&state.format, state.a, state.io, reader);
    if ((intent.operation == .grow or intent.operation == .shrink) and snapshot.filesystem_bytes != intent.bytes) return .{ .consistent = false, .detail = "ext geometry mismatch", .scope = .allocation_metadata };
    try s.requireCapability(snapshot, .check);
    return root.check(&state.format, state.a, state.io, reader);
}
const OPS: s.FilesystemOps = .{ .close = close, .inspect = inspect, .enumerate_objects = object, .enumerate_allocations = allocation, .describe_geometry = geometry, .requirements = requirements, .encode_changes = encode, .check = check, .verify = verify };
