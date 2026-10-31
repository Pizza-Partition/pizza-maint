//! Minimal native formatter: single device, SINGLE system and mixed data /
//! metadata chunks, skinny metadata, CRC32C. No host mkfs process is invoked.
const std = @import("std");
const f = @import("format.zig");
const Builder = @import("../../mutation.zig").Builder;
const Allocator = std.mem.Allocator;
const SYSTEM = 1024 * 1024;
const MIXED = 8 * 1024 * 1024;
pub const SYSTEM_LENGTH: u64 = 4 * 1024 * 1024;
pub const MIXED_LENGTH: u64 = 16 * 1024 * 1024;
const NODE_SIZE = 4096;
const OWNERS = [_]u64{ 1, 2, 4, 5, 7, 9, 3 };
pub const Layout = struct {
    system_physical: u64,
    mixed_physical: u64,
    fn physical(self: Layout, logical: u64) u64 {
        if (logical >= MIXED and logical < MIXED + MIXED_LENGTH) return self.mixed_physical + logical - MIXED;
        if (logical >= SYSTEM and logical < SYSTEM + SYSTEM_LENGTH) return self.system_physical + logical - SYSTEM;
        unreachable;
    }
};
fn address(owner: u64) u64 {
    for (OWNERS, 0..) |o, i| if (o == owner) return if (o == 3) SYSTEM else MIXED + i * NODE_SIZE;
    unreachable;
}
fn zero(a: Allocator, comptime T: type) ![]u8 {
    const b = try a.alloc(u8, @sizeOf(T));
    @memset(b, 0);
    return b;
}
fn append(a: Allocator, list: *std.ArrayList(f.Entry), object: u64, kind: u8, offset: u64, data: []u8) !void {
    try list.append(a, .{ .key = .{ .object = object, .kind = kind, .offset = offset }, .data = data });
}
fn inode(a: Allocator, size: u64) ![]u8 {
    const T = f.c.struct_btrfs_inode_item;
    const b = try zero(a, T);
    f.put(T, "generation", b, 1);
    f.put(T, "transid", b, 1);
    f.put(T, "size", b, size);
    f.put(T, "nbytes", b, NODE_SIZE);
    f.put(T, "nlink", b, 1);
    f.put(T, "mode", b, 0o40755);
    return b;
}
fn inodeRef(a: Allocator, name: []const u8) ![]u8 {
    const T = f.c.struct_btrfs_inode_ref;
    const b = try a.alloc(u8, @sizeOf(T) + name.len);
    @memset(b, 0);
    f.put(T, "name_len", b, name.len);
    @memcpy(b[@sizeOf(T)..], name);
    return b;
}
fn makeChunk(a: Allocator, super: []const u8, physical: u64, length: u64, flags: u64) ![]u8 {
    const b = try zero(a, f.CHUNK);
    f.put(f.CHUNK, "length", b, length);
    f.put(f.CHUNK, "owner", b, 2);
    f.put(f.CHUNK, "stripe_len", b, 65536);
    f.put(f.CHUNK, "type", b, flags);
    f.put(f.CHUNK, "io_align", b, NODE_SIZE);
    f.put(f.CHUNK, "io_width", b, NODE_SIZE);
    f.put(f.CHUNK, "sector_size", b, NODE_SIZE);
    f.put(f.CHUNK, "num_stripes", b, 1);
    const s = f.field(f.CHUNK, "stripe", b);
    f.put(f.STRIPE, "devid", s, 1);
    f.put(f.STRIPE, "offset", s, physical);
    @memcpy(f.field(f.STRIPE, "dev_uuid", s), f.field(f.DEV, "uuid", f.field(f.SUPER, "dev_item", super)));
    return b;
}
pub fn create(a: Allocator, io: std.Io, overlay: *Builder, layout: Layout) !void {
    const bytes = overlay.source.target.capacity;
    if (bytes < 32 * 1024 * 1024 or bytes % NODE_SIZE != 0 or overlay.source.target.sector_size > NODE_SIZE) return error.BtrfsInvalidCreateSize;
    try overlay.stageWrite(io, 0, &@as([65536]u8, @splat(0)));
    var super: [4096]u8 = @splat(0);
    std.Io.random(io, f.field(f.SUPER, "fsid", &super));
    const dev = f.field(f.SUPER, "dev_item", &super);
    std.Io.random(io, f.field(f.DEV, "uuid", dev));
    @memcpy(f.field(f.DEV, "fsid", dev), f.field(f.SUPER, "fsid", &super));
    f.put(f.DEV, "devid", dev, 1);
    f.put(f.DEV, "total_bytes", dev, bytes);
    f.put(f.DEV, "bytes_used", dev, SYSTEM_LENGTH + MIXED_LENGTH);
    f.put(f.DEV, "io_align", dev, NODE_SIZE);
    f.put(f.DEV, "io_width", dev, NODE_SIZE);
    f.put(f.DEV, "sector_size", dev, NODE_SIZE);
    @memcpy(f.field(f.SUPER, "magic", &super), f.MAGIC);
    f.put(f.SUPER, "flags", &super, 1);
    f.put(f.SUPER, "generation", &super, 1);
    f.put(f.SUPER, "root", &super, address(1));
    f.put(f.SUPER, "chunk_root", &super, address(3));
    f.put(f.SUPER, "total_bytes", &super, bytes);
    f.put(f.SUPER, "bytes_used", &super, OWNERS.len * NODE_SIZE);
    f.put(f.SUPER, "root_dir_objectid", &super, 6);
    f.put(f.SUPER, "num_devices", &super, 1);
    f.put(f.SUPER, "sectorsize", &super, NODE_SIZE);
    f.put(f.SUPER, "nodesize", &super, NODE_SIZE);
    f.put(f.SUPER, "__unused_leafsize", &super, NODE_SIZE);
    f.put(f.SUPER, "stripesize", &super, NODE_SIZE);
    f.put(f.SUPER, "chunk_root_generation", &super, 1);
    f.put(f.SUPER, "incompat_flags", &super, (1 << 0) | (1 << 2) | (1 << 8) | (1 << 9));
    f.put(f.SUPER, "cache_generation", &super, std.math.maxInt(u64));
    f.put(f.SUPER, "uuid_tree_generation", &super, 1);
    const sys_chunk = try makeChunk(a, &super, layout.system_physical, SYSTEM_LENGTH, f.c.BTRFS_BLOCK_GROUP_SYSTEM);
    const mixed_chunk = try makeChunk(a, &super, layout.mixed_physical, MIXED_LENGTH, f.c.BTRFS_BLOCK_GROUP_DATA | f.c.BTRFS_BLOCK_GROUP_METADATA);
    const sys_array = f.field(f.SUPER, "sys_chunk_array", &super);
    (f.Key{ .object = 256, .kind = f.c.BTRFS_CHUNK_ITEM_KEY, .offset = SYSTEM }).write(sys_array);
    @memcpy(sys_array[17..][0..sys_chunk.len], sys_chunk);
    f.put(f.SUPER, "sys_chunk_array_size", &super, 17 + sys_chunk.len);
    var chunk_uuid: [16]u8 = undefined;
    var root_uuid: [16]u8 = undefined;
    std.Io.random(io, &chunk_uuid);
    std.Io.random(io, &root_uuid);
    for (OWNERS) |owner| {
        var entries: std.ArrayList(f.Entry) = .empty;
        switch (owner) {
            1 => {
                for (OWNERS) |o| {
                    if (o == 1 or o == 3) continue;
                    const b = try zero(a, f.ROOT);
                    @memcpy(f.field(f.ROOT, "inode", b), try inode(a, 3));
                    f.put(f.ROOT, "generation", b, 1);
                    f.put(f.ROOT, "generation_v2", b, 1);
                    f.put(f.ROOT, "bytenr", b, address(o));
                    f.put(f.ROOT, "bytes_used", b, NODE_SIZE);
                    f.put(f.ROOT, "refs", b, 1);
                    if (o == 5) {
                        f.put(f.ROOT, "root_dirid", b, 256);
                        f.put(f.c.struct_btrfs_inode_item, "flags", f.field(f.ROOT, "inode", b), f.c.BTRFS_INODE_ROOT_ITEM_INIT);
                        @memcpy(f.field(f.ROOT, "uuid", b), &root_uuid);
                    }
                    try append(a, &entries, o, f.c.BTRFS_ROOT_ITEM_KEY, 0, b);
                }
                try append(a, &entries, 6, f.c.BTRFS_INODE_ITEM_KEY, 0, try inode(a, 0));
                try append(a, &entries, 6, f.c.BTRFS_INODE_REF_KEY, 6, try inodeRef(a, ".."));
                try append(a, &entries, 5, f.c.BTRFS_INODE_REF_KEY, 6, try inodeRef(a, "default"));
                const T = f.c.struct_btrfs_dir_item;
                const dir = try a.alloc(u8, @sizeOf(T) + 7);
                @memset(dir, 0);
                (f.Key{ .object = 5, .kind = f.c.BTRFS_ROOT_ITEM_KEY, .offset = std.math.maxInt(u64) }).write(dir);
                f.put(T, "transid", dir, 1);
                f.put(T, "name_len", dir, 7);
                f.put(T, "type", dir, f.c.BTRFS_FT_DIR);
                @memcpy(dir[@sizeOf(T)..], "default");
                try append(a, &entries, 6, f.c.BTRFS_DIR_ITEM_KEY, f.crc(0xfffffffe, "default"), dir);
            },
            2 => {
                for (OWNERS) |o| {
                    const b = try zero(a, f.c.struct_btrfs_extent_item);
                    f.put(f.c.struct_btrfs_extent_item, "refs", b, 1);
                    f.put(f.c.struct_btrfs_extent_item, "generation", b, 1);
                    f.put(f.c.struct_btrfs_extent_item, "flags", b, f.c.BTRFS_EXTENT_FLAG_TREE_BLOCK);
                    try append(a, &entries, address(o), f.c.BTRFS_METADATA_ITEM_KEY, 0, b);
                    try append(a, &entries, address(o), f.c.BTRFS_TREE_BLOCK_REF_KEY, o, try a.alloc(u8, 0));
                }
                const T = f.c.struct_btrfs_block_group_item;
                for ([_]u64{ SYSTEM, MIXED }, [_]u64{ SYSTEM_LENGTH, MIXED_LENGTH }, [_]u64{ 1, 6 }, [_]u64{ f.c.BTRFS_BLOCK_GROUP_SYSTEM, f.c.BTRFS_BLOCK_GROUP_DATA | f.c.BTRFS_BLOCK_GROUP_METADATA }) |logical, length, count, flags| {
                    const b = try zero(a, T);
                    f.put(T, "used", b, count * NODE_SIZE);
                    f.put(T, "chunk_objectid", b, 256);
                    f.put(T, "flags", b, flags);
                    try append(a, &entries, logical, f.c.BTRFS_BLOCK_GROUP_ITEM_KEY, length, b);
                }
            },
            3 => {
                try append(a, &entries, 1, f.c.BTRFS_DEV_ITEM_KEY, 1, try a.dupe(u8, dev));
                try append(a, &entries, 256, f.c.BTRFS_CHUNK_ITEM_KEY, SYSTEM, sys_chunk);
                try append(a, &entries, 256, f.c.BTRFS_CHUNK_ITEM_KEY, MIXED, mixed_chunk);
            },
            4 => {
                const stats = try a.alloc(u8, 40);
                @memset(stats, 0);
                try append(a, &entries, 0, f.c.BTRFS_PERSISTENT_ITEM_KEY, 1, stats);
                for ([_]u64{ SYSTEM, MIXED }, [_]u64{ SYSTEM_LENGTH, MIXED_LENGTH }) |logical, length| {
                    const b = try zero(a, f.DEV_EXTENT);
                    f.put(f.DEV_EXTENT, "chunk_tree", b, 3);
                    f.put(f.DEV_EXTENT, "chunk_objectid", b, 256);
                    f.put(f.DEV_EXTENT, "chunk_offset", b, logical);
                    f.put(f.DEV_EXTENT, "length", b, length);
                    @memcpy(f.field(f.DEV_EXTENT, "chunk_tree_uuid", b), &chunk_uuid);
                    try append(a, &entries, 1, f.c.BTRFS_DEV_EXTENT_KEY, layout.physical(logical), b);
                }
            },
            5 => {
                try append(a, &entries, 256, f.c.BTRFS_INODE_ITEM_KEY, 0, try inode(a, 0));
                try append(a, &entries, 256, f.c.BTRFS_INODE_REF_KEY, 256, try inodeRef(a, ".."));
            },
            9 => {
                const b = try a.alloc(u8, 8);
                std.mem.writeInt(u64, b[0..8], 5, .little);
                try append(a, &entries, std.mem.readInt(u64, root_uuid[0..8], .little), f.c.BTRFS_UUID_KEY_SUBVOL, std.mem.readInt(u64, root_uuid[8..16], .little), b);
            },
            else => {},
        }
        std.mem.sort(f.Entry, entries.items, {}, f.Entry.less);
        var node: [NODE_SIZE]u8 = @splat(0);
        @memcpy(f.field(f.HEADER, "fsid", &node), f.field(f.SUPER, "fsid", &super));
        @memcpy(f.field(f.HEADER, "chunk_tree_uuid", &node), &chunk_uuid);
        f.put(f.HEADER, "bytenr", &node, address(owner));
        f.put(f.HEADER, "flags", &node, 1 | (@as(u64, 1) << 56));
        f.put(f.HEADER, "generation", &node, 1);
        f.put(f.HEADER, "owner", &node, owner);
        try f.pack(&node, entries.items);
        try f.seal(0, &node);
        try overlay.stageWrite(io, layout.physical(address(owner)), &node);
    }
    try @import("mutate.zig").writeSupers(io, overlay, super, bytes);
}
