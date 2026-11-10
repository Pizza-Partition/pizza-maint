//! Native NTFS 3.1 initialization. Allocation is supplied by the common planner.
const std = @import("std");
const semantic = @import("../../semantic.zig");
const model = @import("../../model.zig");
const mutation = @import("../../mutation.zig");
const c_api = @import("root.zig").c_api;
extern "c" const attrdef_ntfs3x_array: [2560]u8;
extern "c" fn init_secure_sds([*]u8) void;
pub const Geometry = struct { bytes: u64, sector: u32, cluster: u32, record: u32, clusters: u64, bitmap_bytes: u64, sizes: [13]u64, reserved: [2]model.Range };
pub fn describe(a: std.mem.Allocator, bytes: u64, sector: u32) !*Geometry {
    if (sector > 4096 or bytes < 16 * 1024 * 1024 or bytes % sector != 0) return error.NtfsInvalidCreateSize;
    const cluster: u32 = 4096;
    const record = @max(1024, sector);
    const clusters = (bytes - sector) / cluster;
    if (clusters > 64 * 1024 * 1024) return error.NtfsResourceLimit;
    const bitmap_bytes = std.mem.alignForward(u64, try std.math.divCeil(u64, clusters, 8), 8);
    const g = try a.create(Geometry);
    g.* = .{ .bytes = bytes, .sector = sector, .cluster = cluster, .record = record, .clusters = clusters, .bitmap_bytes = bitmap_bytes, .sizes = @splat(0), .reserved = .{ .{ .offset = 0, .length = 8192 }, .{ .offset = clusters * cluster, .length = bytes - clusters * cluster } } };
    g.sizes[0] = 32 * record;
    g.sizes[1] = 4 * record;
    g.sizes[2] = 2 * 1024 * 1024;
    g.sizes[4] = 2560;
    g.sizes[5] = 4096;
    g.sizes[6] = bitmap_bytes;
    g.sizes[9] = 0x400fc;
    g.sizes[10] = 65536 * 2;
    g.sizes[12] = 8;
    return g;
}
pub fn requirements(a: std.mem.Allocator, g: *const Geometry) ![]semantic.Requirement {
    var reqs: std.ArrayList(semantic.Requirement) = .empty;
    for (g.sizes, 0..) |size, index| {
        if (size == 0) continue;
        const allocated = std.mem.alignForward(u64, size, g.cluster);
        try reqs.append(a, .{ .id = index + 1, .bytes = allocated, .granule = allocated, .alignment = g.cluster, .bounds = .{ .offset = 0, .length = g.clusters * g.cluster } });
    }
    return reqs.toOwnedSlice(a);
}
fn put(comptime T: type, b: []u8, at: usize, n: T) void {
    std.mem.writeInt(T, b[at..][0..@sizeOf(T)], n, .little);
}
fn get(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}
fn zeros(a: std.mem.Allocator, length: usize) ![]u8 {
    const b = try a.alloc(u8, length);
    @memset(b, 0);
    return b;
}
fn utf16(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const b = try zeros(a, name.len * 2);
    for (name, 0..) |ch, i| put(u16, b, i * 2, ch);
    return b;
}
/// NTFS volume labels are stored as UTF-16LE in $Volume's resident name.
pub fn labelBytes(a: std.mem.Allocator, label: []const u8) ![]u8 {
    const words = try std.unicode.utf8ToUtf16LeAlloc(a, label);
    defer a.free(words);
    if (words.len > 32) return error.NtfsInvalidVolumeLabel;
    const bytes = try a.alloc(u8, words.len * 2);
    errdefer a.free(bytes);
    for (words, 0..) |word, i| {
        if (word < 32 or std.mem.indexOfScalar(u16, &.{ '\\', '/', ':', '*', '?', '"', '<', '>', '|' }, word) != null) return error.NtfsInvalidVolumeLabel;
        put(u16, bytes, i * 2, word);
    }
    return bytes;
}
fn location(placements: []const semantic.Placement, id: u64) !model.Range {
    for (placements) |p| if (p.id == id and p.ranges.len == 1) return p.ranges[0];
    return error.MissingAllocationPlacement;
}
const Attribute = struct { kind: u32, name: []const u8, bytes: []u8 };
const Record = struct {
    allocator: std.mem.Allocator,
    attributes: std.ArrayList(Attribute) = .empty,
    fn resident(self: *Record, kind: u32, name: []const u8, value: []const u8) !void {
        const offset = std.mem.alignForward(usize, 24 + name.len * 2, 8);
        const b = try zeros(self.allocator, std.mem.alignForward(usize, offset + value.len, 8));
        put(u32, b, 0, kind);
        put(u32, b, 4, @intCast(b.len));
        b[9] = @intCast(name.len);
        put(u16, b, 10, if (name.len == 0) 0 else 24);
        put(u32, b, 16, @intCast(value.len));
        put(u16, b, 20, @intCast(offset));
        @memcpy(b[24..][0 .. name.len * 2], try utf16(self.allocator, name));
        @memcpy(b[offset..][0..value.len], value);
        try self.attributes.append(self.allocator, .{ .kind = kind, .name = name, .bytes = b });
    }
    fn nonresident(self: *Record, kind: u32, name: []const u8, range: ?model.Range, allocated: u64, size: u64, initialized: u64, cluster: u32) !void {
        var pairs: [18]u8 = @splat(0);
        const count = allocated / cluster;
        var length_size: u8 = 1;
        while (length_size < 8 and count >= (@as(u64, 1) << @as(u6, @intCast(length_size * 8 - 1)))) length_size += 1;
        var offset_size: u8 = 0;
        const lcn = if (range) |r| r.offset / cluster else 0;
        if (range != null) {
            offset_size = 1;
            while (offset_size < 8 and lcn >= (@as(u64, 1) << @as(u6, @intCast(offset_size * 8 - 1)))) offset_size += 1;
        }
        pairs[0] = length_size | offset_size << 4;
        for (0..length_size) |i| pairs[1 + i] = @truncate(count >> @intCast(i * 8));
        for (0..offset_size) |i| pairs[1 + length_size + i] = @truncate(lcn >> @intCast(i * 8));
        const pairs_length = @as(usize, length_size) + offset_size + 2;
        const offset = std.mem.alignForward(usize, 64 + name.len * 2, 8);
        const b = try zeros(self.allocator, std.mem.alignForward(usize, offset + pairs_length, 8));
        put(u32, b, 0, kind);
        put(u32, b, 4, @intCast(b.len));
        b[8] = 1;
        b[9] = @intCast(name.len);
        put(u16, b, 10, if (name.len == 0) 0 else 64);
        put(u64, b, 24, count - 1);
        put(u16, b, 32, @intCast(offset));
        put(u64, b, 40, allocated);
        put(u64, b, 48, size);
        put(u64, b, 56, initialized);
        @memcpy(b[64..][0 .. name.len * 2], try utf16(self.allocator, name));
        @memcpy(b[offset..][0..pairs_length], pairs[0..pairs_length]);
        try self.attributes.append(self.allocator, .{ .kind = kind, .name = name, .bytes = b });
    }
    fn encode(self: *Record, g: *const Geometry, number: usize, used: bool) ![]u8 {
        std.mem.sort(Attribute, self.attributes.items, {}, struct {
            fn less(_: void, a: Attribute, b: Attribute) bool {
                return if (a.kind != b.kind) a.kind < b.kind else std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.less);
        const b = try zeros(self.allocator, g.record);
        @memcpy(b[0..4], "FILE");
        put(u16, b, 4, 48);
        put(u16, b, 6, @intCast(g.record / 512 + 1));
        put(u16, b, 16, @intCast(if (number == 0) 1 else number));
        put(u16, b, 18, if (used and number < 12) 1 else 0);
        const start = std.mem.alignForward(usize, 48 + (g.record / 512 + 1) * 2, 8);
        put(u16, b, 20, @intCast(start));
        put(u16, b, 22, if (!used) 0 else if (number == 5 or number == 11) 3 else if (number == 9) 9 else 1);
        put(u32, b, 28, g.record);
        put(u16, b, 40, @intCast(self.attributes.items.len));
        put(u32, b, 44, @intCast(number));
        var at = start;
        for (self.attributes.items, 0..) |attr, index| {
            if (at + attr.bytes.len + 8 > b.len) return error.NtfsMetadataReservationRequired;
            put(u16, attr.bytes, 14, @intCast(index));
            @memcpy(b[at..][0..attr.bytes.len], attr.bytes);
            at += attr.bytes.len;
        }
        put(u32, b, at, 0xffffffff);
        put(u32, b, 24, @intCast(at + 8));
        try seal(b, 512);
        return b;
    }
};
fn seal(b: []u8, sector: u32) !void {
    const at = get(u16, b, 4);
    const count = get(u16, b, 6);
    if (count != b.len / sector + 1 or @as(usize, at) + count * 2 > b.len) return error.NtfsInvalidFixup;
    put(u16, b, at, 1);
    for (1..count) |index| {
        const end = index * sector - 2;
        put(u16, b, at + index * 2, get(u16, b, end));
        put(u16, b, end, 1);
    }
}
const NAMES = [_][]const u8{ "$MFT", "$MFTMirr", "$LogFile", "$Volume", "$AttrDef", ".", "$Bitmap", "$Boot", "$BadClus", "$Secure", "$UpCase", "$Extend" };
fn fileName(a: std.mem.Allocator, index: usize, allocated: u64, size: u64) ![]u8 {
    const name = NAMES[index];
    const b = try zeros(a, 66 + name.len * 2);
    put(u64, b, 0, (@as(u64, 5) << 48) | 5);
    put(u64, b, 40, allocated);
    put(u64, b, 48, size);
    put(u32, b, 56, if (index == 5 or index == 11) 0x10000006 else if (index == 9) 0x20000006 else 6);
    b[64] = @intCast(name.len);
    b[65] = 3;
    @memcpy(b[66..], try utf16(a, name));
    return b;
}
fn indexRoot(a: std.mem.Allocator, kind: u32, collation: u32, entries: []const u8, large: bool) ![]u8 {
    const b = try zeros(a, 32 + entries.len + if (large) @as(usize, 24) else 16);
    put(u32, b, 0, kind);
    put(u32, b, 4, collation);
    put(u32, b, 8, 4096);
    b[12] = 1;
    put(u32, b, 16, 16);
    put(u32, b, 20, @intCast(b.len - 16));
    put(u32, b, 24, @intCast(b.len - 16));
    b[28] = @intFromBool(large);
    @memcpy(b[32..][0..entries.len], entries);
    const end = 32 + entries.len;
    put(u16, b, end + 8, if (large) 24 else 16);
    put(u16, b, end + 12, if (large) 3 else 2);
    return b;
}
fn securityIndex(a: std.mem.Allocator, data: []const u8, hash_index: bool) ![]u8 {
    var entries: std.ArrayList([]u8) = .empty;
    var at: usize = 0;
    while (at < 0xfc) {
        const header = data[at..][0..20];
        const length = get(u32, header, 16);
        if (length == 0) break;
        const b = try zeros(a, if (hash_index) 48 else 40);
        const offset: u16 = if (hash_index) 24 else 20;
        put(u16, b, 0, offset);
        put(u16, b, 2, 20);
        put(u16, b, 8, @intCast(b.len));
        put(u16, b, 10, if (hash_index) 8 else 4);
        if (hash_index) @memcpy(b[16..24], header[0..8]) else @memcpy(b[16..20], header[4..8]);
        @memcpy(b[offset..][0..20], header);
        try entries.append(a, b);
        at += std.mem.alignForward(usize, length, 16);
    }
    std.mem.sort([]u8, entries.items, {}, struct {
        fn less(_: void, a_: []u8, b_: []u8) bool {
            return get(u32, a_, 16) < get(u32, b_, 16);
        }
    }.less);
    var all: std.ArrayList(u8) = .empty;
    for (entries.items) |e| try all.appendSlice(a, e);
    return indexRoot(a, 0, if (hash_index) 0x12 else 0x10, all.items, false);
}
pub fn encode(a: std.mem.Allocator, io: std.Io, target: model.Target, g: *const Geometry, placements: []const semantic.Placement, partition_offset: u64, label: []const u8) !mutation.MutationSet {
    const volume_label = try labelBytes(a, label);
    defer a.free(volume_label);
    var collector: mutation.Collector = .{ .allocator = a, .target = target };
    var data: [13][]u8 = @splat(&.{});
    for (g.sizes, 0..) |size, index| if (size != 0) {
        data[index] = try zeros(a, @intCast(std.mem.alignForward(u64, size, g.cluster)));
    };
    data[12][0] = 0xff;
    data[12][1] = 0xff;
    @memset(data[2], 0xff);
    @memcpy(data[4][0..2560], &attrdef_ntfs3x_array);
    init_secure_sds(data[9].ptr);
    @memcpy(data[9][0x40000..][0..0xfc], data[9][0..0xfc]);
    const upcase = try a.alloc(u16, 65536);
    defer a.free(upcase);
    c_api.ntfs_upcase_table_build(upcase.ptr, 65536 * 2);
    @memcpy(data[10], std.mem.sliceAsBytes(upcase));
    const bitmap = data[6];
    for (0..2) |bit| bitmap[0] |= @as(u8, 1) << @intCast(bit);
    for (placements) |p| for (p.ranges) |r| {
        var bit = r.offset / g.cluster;
        while (bit < try r.end() / g.cluster) : (bit += 1) bitmap[@intCast(bit / 8)] |= @as(u8, 1) << @intCast(bit % 8);
    };
    for (@intCast(g.clusters)..bitmap.len * 8) |bit| bitmap[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
    var filename_values: [12][]u8 = undefined;
    for (&filename_values, 0..) |*value, index| {
        const allocated = if (g.sizes[index] != 0) (try location(placements, index + 1)).length else if (index == 7) @as(u64, 8192) else 0;
        const size = if (index == 0) 16 * g.record else if (index == 7) @as(u64, 8192) else if (index == 5) 0 else g.sizes[index];
        value.* = try fileName(a, index, if (index == 5) 0 else allocated, size);
    }
    const root_index = data[5];
    @memcpy(root_index[0..4], "INDX");
    put(u16, root_index, 4, 40);
    put(u16, root_index, 6, @intCast(root_index.len / 512 + 1));
    const first = std.mem.alignForward(usize, 40 + (root_index.len / 512 + 1) * 2, 8);
    put(u32, root_index, 24, @intCast(first - 24));
    put(u32, root_index, 32, @intCast(root_index.len - 24));
    var order: [12]usize = undefined;
    for (&order, 0..) |*i, n| i.* = n;
    std.mem.sort(usize, &order, {}, struct {
        fn less(_: void, x: usize, y: usize) bool {
            return std.ascii.orderIgnoreCase(NAMES[x], NAMES[y]) == .lt;
        }
    }.less);
    var at = first;
    for (order) |index| {
        const name = filename_values[index];
        const length = std.mem.alignForward(usize, 16 + name.len, 8);
        if (at + length + 16 > root_index.len) return error.NtfsMetadataReservationRequired;
        put(u64, root_index, at, (@as(u64, if (index == 0) 1 else index) << 48) | index);
        put(u16, root_index, at + 8, @intCast(length));
        put(u16, root_index, at + 10, @intCast(name.len));
        @memcpy(root_index[at + 16 ..][0..name.len], name);
        at += length;
    }
    put(u16, root_index, at + 8, 16);
    put(u16, root_index, at + 12, 2);
    put(u32, root_index, 28, @intCast(at + 16 - 24));
    try seal(root_index, 512);
    const boot = try zeros(a, 8192);
    @memcpy(boot[0..3], &@as([3]u8, .{ 0xeb, 0x52, 0x90 }));
    @memcpy(boot[3..11], "NTFS    ");
    put(u16, boot, 11, @intCast(g.sector));
    boot[13] = @intCast(g.cluster / g.sector);
    boot[21] = 0xf8;
    put(u16, boot, 24, 63);
    put(u16, boot, 26, 255);
    const hidden = partition_offset / g.sector;
    if (hidden > std.math.maxInt(u32)) return error.NtfsPartitionOffsetOverflow;
    put(u32, boot, 28, @intCast(hidden));
    boot[36] = 0x80;
    put(u64, boot, 40, g.bytes / g.sector - 1);
    put(u64, boot, 48, (try location(placements, 1)).offset / g.cluster);
    put(u64, boot, 56, (try location(placements, 2)).offset / g.cluster);
    boot[64] = @bitCast(-@as(i8, @intCast(std.math.log2_int(u32, g.record))));
    boot[68] = @bitCast(@as(i8, -12));
    std.Io.random(io, boot[72..80]);
    put(u16, boot, 510, 0xaa55);
    for (0..32) |index| {
        var record: Record = .{ .allocator = a };
        if (index < 16) {
            const info = try zeros(a, 72);
            put(u32, info, 32, 6);
            put(u32, info, 52, if (index == 5 or index == 9 or index == 11) 0x101 else 0x100);
            try record.resident(0x10, "", info);
            if (index < 12) try record.resident(0x30, "", filename_values[index]);
            switch (index) {
                0 => {
                    const r = try location(placements, 1);
                    try record.nonresident(0x80, "", r, r.length, 16 * g.record, 16 * g.record, g.cluster);
                    const bitmap_range = try location(placements, 13);
                    try record.nonresident(0xb0, "", bitmap_range, bitmap_range.length, 8, 8, g.cluster);
                },
                1, 2, 4, 6, 10 => {
                    const r = try location(placements, index + 1);
                    try record.nonresident(0x80, "", r, r.length, g.sizes[index], g.sizes[index], g.cluster);
                },
                3 => {
                    try record.resident(0x60, "", volume_label);
                    var info_: [12]u8 = @splat(0);
                    info_[8] = 3;
                    info_[9] = 1;
                    try record.resident(0x70, "", &info_);
                    try record.resident(0x80, "", &.{});
                },
                5 => {
                    const r = try location(placements, 6);
                    try record.resident(0x90, "$I30", try indexRoot(a, 0x30, 1, &.{}, true));
                    try record.nonresident(0xa0, "$I30", r, r.length, 4096, 4096, g.cluster);
                    try record.resident(0xb0, "$I30", &.{1});
                },
                7 => try record.nonresident(0x80, "", .{ .offset = 0, .length = 8192 }, 8192, 8192, 8192, g.cluster),
                8 => {
                    try record.resident(0x80, "", &.{});
                    try record.nonresident(0x80, "$Bad", null, g.clusters * g.cluster, g.clusters * g.cluster, 0, g.cluster);
                },
                9 => {
                    const r = try location(placements, 10);
                    try record.nonresident(0x80, "$SDS", r, r.length, g.sizes[9], g.sizes[9], g.cluster);
                    try record.resident(0x90, "$SDH", try securityIndex(a, data[9], true));
                    try record.resident(0x90, "$SII", try securityIndex(a, data[9], false));
                },
                11 => try record.resident(0x90, "$I30", try indexRoot(a, 0x30, 1, &.{}, false)),
                else => try record.resident(0x80, "", &.{}),
            }
        }
        const bytes = try record.encode(g, index, index < 16);
        @memcpy(data[0][index * g.record ..][0..g.record], bytes);
    }
    @memcpy(data[1][0 .. 4 * g.record], data[0][0 .. 4 * g.record]);
    for (data, 0..) |bytes, index| if (bytes.len != 0) try collector.write((try location(placements, index + 1)).offset, bytes);
    try collector.write(0, boot);
    try collector.write(g.bytes - g.sector, boot[0..g.sector]);
    const changes = try collector.finish();
    for (@constCast(changes.writes)) |*w| w.kind = .discard;
    return changes;
}
