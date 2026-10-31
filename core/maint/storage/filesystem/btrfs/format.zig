//! Serialization uses the pinned upstream on-disk definitions, never native
//! aligned struct pointers into untrusted bytes.
const std = @import("std");
const Reader = @import("../../device.zig").Reader;
pub const c = @import("btrfs_c").format;
pub const SUPER = c.struct_btrfs_super_block;
pub const HEADER = c.struct_btrfs_header;
pub const ITEM = c.struct_btrfs_item;
pub const PTR = c.struct_btrfs_key_ptr;
pub const CHUNK = c.struct_btrfs_chunk;
pub const STRIPE = c.struct_btrfs_stripe;
pub const DEV = c.struct_btrfs_dev_item;
pub const ROOT = c.struct_btrfs_root_item;
pub const DEV_EXTENT = c.struct_btrfs_dev_extent;
pub const MIRRORS = [_]u64{ 64 * 1024, 64 * 1024 * 1024, 256 * 1024 * 1024 * 1024 };
pub const HEADER_SIZE = @sizeOf(HEADER);
pub const SUPER_SIZE = @sizeOf(SUPER);
pub const MAGIC = "_BHRfS_M";
pub const MAX_METADATA = 32 * 1024 * 1024;
pub fn get(comptime T: type, comptime name: []const u8, b: []const u8) u64 {
    const F = @TypeOf(@field(@as(T, undefined), name));
    const at = @offsetOf(T, name);
    return std.mem.readInt(F, b[at..][0..@sizeOf(F)], .little);
}
pub fn put(comptime T: type, comptime name: []const u8, b: []u8, value: u64) void {
    const F = @TypeOf(@field(@as(T, undefined), name));
    const at = @offsetOf(T, name);
    std.mem.writeInt(F, b[at..][0..@sizeOf(F)], @intCast(value), .little);
}
pub fn field(comptime T: type, comptime name: []const u8, b: anytype) if (@typeInfo(@TypeOf(b)).pointer.attrs.@"const") []const u8 else []u8 {
    const F = @TypeOf(@field(@as(T, undefined), name));
    return b[@offsetOf(T, name)..][0..@sizeOf(F)];
}
extern "c" fn __crc32c_le(u32, [*]const u8, u32) u32;
pub fn crc(seed: u32, data: []const u8) u32 {
    return __crc32c_le(seed, data.ptr, @intCast(data.len));
}
pub fn digest(kind: u64, bytes: []const u8) ![32]u8 {
    var result: [32]u8 = @splat(0);
    switch (kind) {
        0 => std.mem.writeInt(u32, result[0..4], ~crc(0xffffffff, bytes), .little),
        1 => std.mem.writeInt(u64, result[0..8], std.hash.XxHash64.hash(0, bytes), .little),
        2 => std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{}),
        3 => std.crypto.hash.blake2.Blake2b256.hash(bytes, &result, .{}),
        else => return error.BtrfsUnsupportedChecksum,
    }
    return result;
}
pub fn seal(kind: u64, b: []u8) !void {
    @memcpy(b[0..32], &try digest(kind, b[32..]));
}
pub fn checksum(kind: u64, b: []const u8) !void {
    if (!std.mem.eql(u8, b[0..32], &try digest(kind, b[32..]))) return error.BtrfsChecksum;
}
pub const Key = struct {
    object: u64,
    kind: u8,
    offset: u64,
    pub fn read(b: []const u8) Key {
        return .{ .object = std.mem.readInt(u64, b[0..8], .little), .kind = b[8], .offset = std.mem.readInt(u64, b[9..17], .little) };
    }
    pub fn write(k: Key, b: []u8) void {
        std.mem.writeInt(u64, b[0..8], k.object, .little);
        b[8] = k.kind;
        std.mem.writeInt(u64, b[9..17], k.offset, .little);
    }
    pub fn less(_: void, x: Key, y: Key) bool {
        if (x.object != y.object) return x.object < y.object;
        if (x.kind != y.kind) return x.kind < y.kind;
        return x.offset < y.offset;
    }
};
pub const Entry = struct {
    key: Key,
    data: []u8,
    pub fn less(_: void, x: Entry, y: Entry) bool {
        return Key.less({}, x.key, y.key);
    }
};
pub fn items(a: std.mem.Allocator, b: []const u8) ![]Entry {
    const count = get(HEADER, "nritems", b);
    if (count > (b.len - HEADER_SIZE) / @sizeOf(ITEM)) return error.BtrfsInvalidNode;
    const result = try a.alloc(Entry, @intCast(count));
    var end: usize = b.len;
    for (result, 0..) |*entry, i| {
        const item = b[HEADER_SIZE + i * @sizeOf(ITEM) ..][0..@sizeOf(ITEM)];
        const off = get(ITEM, "offset", item) + HEADER_SIZE;
        const size = get(ITEM, "size", item);
        if (off < HEADER_SIZE + count * @sizeOf(ITEM) or off > end or size != end - off) return error.BtrfsInvalidNode;
        entry.* = .{ .key = Key.read(item), .data = try a.dupe(u8, b[@intCast(off)..@intCast(end)]) };
        if (i != 0 and !Key.less({}, result[i - 1].key, entry.key)) return error.BtrfsKeyOrder;
        end = @intCast(off);
    }
    return result;
}
pub fn pack(b: []u8, entries: []const Entry) !void {
    @memset(b[HEADER_SIZE..], 0);
    var end = b.len;
    for (entries, 0..) |entry, i| {
        if (i != 0 and !Entry.less({}, entries[i - 1], entry)) return error.BtrfsKeyOrder;
        if (end < entry.data.len + HEADER_SIZE + entries.len * @sizeOf(ITEM)) return error.BtrfsResourceLimit;
        end -= entry.data.len;
        @memcpy(b[end..][0..entry.data.len], entry.data);
        const item = b[HEADER_SIZE + i * @sizeOf(ITEM) ..][0..@sizeOf(ITEM)];
        entry.key.write(item);
        put(ITEM, "offset", item, end - HEADER_SIZE);
        put(ITEM, "size", item, entry.data.len);
    }
    put(HEADER, "nritems", b, entries.len);
}
pub const Geometry = struct {
    super: [4096]u8,
    pub fn value(g: *const Geometry, comptime name: []const u8) u64 {
        return get(SUPER, name, &g.super);
    }
    pub fn bytes(g: *const Geometry) u64 {
        return g.value("total_bytes");
    }
    pub fn nodeSize(g: *const Geometry) usize {
        return @intCast(g.value("nodesize"));
    }
    pub fn sector(g: *const Geometry) u64 {
        return g.value("sectorsize");
    }
    pub fn dev(g: *const Geometry) []const u8 {
        return field(SUPER, "dev_item", &g.super);
    }
    pub fn fsid(g: *const Geometry) []const u8 {
        return if (g.value("incompat_flags") & (1 << 10) != 0) field(SUPER, "metadata_uuid", &g.super) else field(SUPER, "fsid", &g.super);
    }
    pub fn clean(g: *const Geometry) bool {
        return g.value("log_root") == 0 and g.value("flags") & ~@as(u64, 1) == 0;
    }
    pub fn supported(g: *const Geometry) !void {
        // Do not treat future optional RO features as writable by default.
        const incompat: u64 = 0x7ff & ~@as(u64, 1 << 7);
        if (g.value("incompat_flags") & ~incompat != 0 or g.value("compat_ro_flags") & ~@as(u64, 0xb) != 0 or g.value("compat_flags") != 0 or g.value("num_devices") != 1 or g.value("remap_root") != 0) return error.BtrfsUnsupportedFeatures;
        if (!g.clean()) return error.BtrfsRecoveryRequired;
    }
};
pub fn recognizable(b: []const u8) bool {
    return std.mem.eql(u8, field(SUPER, "magic", b), MAGIC);
}
pub fn parse(b: [4096]u8, capacity: u64, position: u64) !Geometry {
    if (!recognizable(&b) or get(SUPER, "bytenr", &b) != position) return error.BtrfsInvalidSuper;
    try checksum(get(SUPER, "csum_type", &b), &b);
    const g: Geometry = .{ .super = b };
    const s = g.sector();
    const n = g.nodeSize();
    if (s < 4096 or s > 65536 or !std.math.isPowerOfTwo(s) or n < s or n > 65536 or !std.math.isPowerOfTwo(n) or g.bytes() > capacity or g.bytes() < 32 * 1024 * 1024 or g.bytes() % s != 0 or g.value("bytes_used") > g.bytes() or g.value("generation") == 0 or g.value("root_level") >= 8 or g.value("chunk_root_level") >= 8 or g.value("sys_chunk_array_size") > 2048 or g.value("sys_chunk_array_size") == 0 or get(DEV, "devid", g.dev()) == 0 or get(DEV, "total_bytes", g.dev()) != g.bytes() or get(DEV, "bytes_used", g.dev()) > g.bytes()) return error.BtrfsInvalidSuper;
    return g;
}
pub fn load(io: std.Io, reader: Reader) !Geometry {
    if (reader.target.capacity < MIRRORS[0] + 4096) return error.BtrfsInvalidSuper;
    var b: [4096]u8 = undefined;
    try reader.readInto(io, MIRRORS[0], &b);
    return parse(b, reader.target.capacity, MIRRORS[0]);
}
pub fn checkMirrors(io: std.Io, reader: Reader, g: *const Geometry) !void {
    for (MIRRORS[1..]) |offset| {
        if (offset + 4096 > g.bytes()) continue;
        var b: [4096]u8 = undefined;
        try reader.readInto(io, offset, &b);
        var other = try parse(b, reader.target.capacity, offset);
        put(SUPER, "bytenr", &other.super, MIRRORS[0]);
        try seal(g.value("csum_type"), &other.super);
        if (!std.mem.eql(u8, &g.super, &other.super)) return error.BtrfsAmbiguousSuper;
    }
}
