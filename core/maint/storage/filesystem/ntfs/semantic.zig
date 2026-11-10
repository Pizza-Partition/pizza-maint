//! Native NTFS runlist transformation behind the shared filesystem vtable.
const std = @import("std");
const semantic = @import("../../semantic.zig");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
const mutation = @import("../../mutation.zig");
const root = @import("root.zig");
const c_api = root.c_api;
const format = @import("format.zig");
const create = @import("create.zig");
const BITMAP_ID = std.math.maxInt(u64);
const Run = struct { vcn: u64, length: u64, lcn: ?u64, unit: ?u64 = null };
const Attribute = struct { record: usize, owner: u64, offset: usize, bytes: []const u8, kind: u32, runs: []Run, bitmap: bool, bad: bool };
const State = struct {
    a: std.mem.Allocator,
    io: std.Io,
    reader: device.Reader,
    snapshot: model.Snapshot,
    geometry: ?format.Geometry = null,
    session: ?*root.Session = null,
    records: []u8 = &.{},
    attributes: []Attribute = &.{},
    units: []semantic.AllocationUnit = &.{},
    desired_bytes: u64 = 0,
    loaded: bool = false,
    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }
    fn load(self: *@This(), repair: bool) !void {
        if (self.loaded) return;
        const g = try format.load(self.io, self.reader);
        self.geometry = g;
        const session = try root.Session.open(self.a, self.io, self.reader, null);
        self.session = session;
        try session.health();
        if (!repair) try root.checkBackup(self.io, self.reader, g);
        const vol = session.volume.?;
        const length = vol.mft_na.*.initialized_size;
        if (length < 12 * g.record or length > 64 * 1024 * 1024 or @rem(length, g.record) != 0) return error.NtfsResourceLimit;
        self.records = try self.a.alloc(u8, @intCast(length));
        const count = @divExact(length, g.record);
        if (c_api.ntfs_attr_mst_pread(vol.mft_na, 0, count, g.record, self.records.ptr) != count) return error.NtfsInvalidMetadata;
        var attributes: std.ArrayList(Attribute) = .empty;
        var units: std.ArrayList(semantic.AllocationUnit) = .empty;
        const clusters = (self.desired_bytes - g.sector) / g.cluster;
        for (0..@intCast(count)) |index| {
            const record = self.records[index * g.record ..][0..g.record];
            if (!std.mem.eql(u8, record[0..4], "FILE")) return error.NtfsInvalidMft;
            if (get(u16, record, 22) & 1 == 0) continue;
            const base = get(u64, record, 32);
            const owner = if (base != 0) base & 0x0000ffffffffffff else index;
            const used = get(u32, record, 24);
            var at: usize = get(u16, record, 20);
            if (at < 48 or at >= used or used > g.record) return error.NtfsInvalidAttribute;
            while (at + 8 <= used and get(u32, record, at) != 0xffffffff) {
                const size = get(u32, record, at + 4);
                if (size < 24 or size % 8 != 0 or size > used - at) return error.NtfsInvalidAttribute;
                const raw = record[at..][0..size];
                const kind = get(u32, raw, 0);
                if (raw[8] > 1) return error.NtfsInvalidAttribute;
                const bitmap = owner == 6 and kind == 0x80 and raw[9] == 0;
                const bad = owner == 8 and kind == 0x80 and nameEquals(raw, "$Bad");
                var runs: []Run = &.{};
                if (raw[8] != 0) {
                    if (size < 64) return error.NtfsInvalidAttribute;
                    const offset = get(u16, raw, 32);
                    if (offset < 64 or offset >= size) return error.NtfsInvalidAttribute;
                    runs = try decodeRuns(self.a, raw[offset..], get(u64, raw, 16), get(u64, raw, 24), g.bytes / g.cluster);
                    if (!bitmap) for (runs) |*run| if (run.lcn) |lcn| {
                        if (bad and lcn >= clusters) continue;
                        const length_clusters = if (bad) @min(run.length, clusters - lcn) else run.length;
                        if (length_clusters == 0) continue;
                        run.unit = units.items.len + 1;
                        try units.append(self.a, .{ .id = run.unit.?, .owner = owner, .sources = try self.a.dupe(model.Range, &.{.{ .offset = lcn * g.cluster, .length = length_clusters * g.cluster }}), .content_bytes = length_clusters * g.cluster, .movable = owner != 7 and !bad });
                    };
                }
                try attributes.append(self.a, .{ .record = index, .owner = owner, .offset = at, .bytes = raw, .kind = kind, .runs = runs, .bitmap = bitmap, .bad = bad });
                at += size;
            }
            if (at + 4 > used or get(u32, record, at) != 0xffffffff) return error.NtfsInvalidAttribute;
        }
        self.attributes = try attributes.toOwnedSlice(self.a);
        var bitmap_sources: std.ArrayList(model.Range) = .empty;
        var bitmap_length: u64 = 0;
        for (self.attributes) |attr| if (attr.bitmap) {
            for (attr.runs) |run| if (run.lcn) |lcn| {
                try bitmap_sources.append(self.a, .{ .offset = lcn * g.cluster, .length = run.length * g.cluster });
                bitmap_length += run.length * g.cluster;
            };
        };
        if (bitmap_sources.items.len == 0) return error.NtfsInvalidBitmap;
        try units.append(self.a, .{ .id = BITMAP_ID, .owner = 6, .sources = try bitmap_sources.toOwnedSlice(self.a), .content_bytes = bitmap_length, .generated = true });
        self.units = try units.toOwnedSlice(self.a);
        const expected = try self.a.alloc(u8, std.math.cast(usize, std.mem.alignForward(u64, try std.math.divCeil(u64, (g.bytes - g.sector) / g.cluster, 8), 8)) orelse return error.NtfsResourceLimit);
        @memset(expected, 0);
        const old_clusters = (g.bytes - g.sector) / g.cluster;
        for (self.attributes) |attr| for (attr.runs) |run| if (run.lcn) |lcn| {
            var bit = lcn;
            while (bit < lcn + run.length) : (bit += 1) {
                if (bit >= old_clusters) return error.NtfsInvalidRunlist;
                const mask = @as(u8, 1) << @as(u3, @intCast(bit % 8));
                if (expected[@intCast(bit / 8)] & mask != 0) return error.NtfsClusterCrossLink;
                expected[@intCast(bit / 8)] |= mask;
            }
        };
        for (@intCast(old_clusters)..expected.len * 8) |bit| expected[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
        const observed = try self.a.alloc(u8, expected.len);
        if (vol.lcnbmp_na.*.data_size < expected.len or c_api.ntfs_attr_pread(vol.lcnbmp_na, 0, @intCast(observed.len), observed.ptr) != observed.len) return error.NtfsInvalidBitmap;
        if (!std.mem.eql(u8, expected, observed)) return error.NtfsBitmapMismatch;
        self.loaded = true;
    }
};
fn get(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}
fn put(comptime T: type, b: []u8, at: usize, n: T) void {
    std.mem.writeInt(T, b[at..][0..@sizeOf(T)], n, .little);
}
fn nameEquals(raw: []const u8, text: []const u8) bool {
    if (raw[9] != text.len) return false;
    const at = get(u16, raw, 10);
    if (at > raw.len or text.len * 2 > raw.len - at) return false;
    for (text, 0..) |byte, i| if (get(u16, raw, at + i * 2) != byte) return false;
    return true;
}
fn decodeRuns(a: std.mem.Allocator, bytes: []const u8, first: u64, last: u64, clusters: u64) ![]Run {
    var result: std.ArrayList(Run) = .empty;
    var at: usize = 0;
    var vcn = first;
    var previous: i64 = 0;
    while (at < bytes.len and bytes[at] != 0) {
        const sizes = bytes[at];
        at += 1;
        const length_bytes = sizes & 15;
        const offset_bytes = sizes >> 4;
        if (length_bytes == 0 or length_bytes > 8 or offset_bytes > 8 or @as(usize, length_bytes) + offset_bytes > bytes.len - at) return error.NtfsInvalidRunlist;
        if (bytes[at + length_bytes - 1] & 0x80 != 0) return error.NtfsInvalidRunlist;
        var length: u64 = 0;
        for (0..length_bytes) |i| length |= @as(u64, bytes[at + i]) << @intCast(i * 8);
        at += length_bytes;
        if (length == 0 or length > std.math.maxInt(i64)) return error.NtfsInvalidRunlist;
        var lcn: ?u64 = null;
        if (offset_bytes != 0) {
            var value: u64 = if (bytes[at + offset_bytes - 1] & 0x80 != 0) std.math.maxInt(u64) else 0;
            for (0..offset_bytes) |i| {
                const mask = @as(u64, 0xff) << @intCast(i * 8);
                value = (value & ~mask) | (@as(u64, bytes[at + i]) << @intCast(i * 8));
            }
            previous = std.math.add(i64, previous, @as(i64, @bitCast(value))) catch return error.NtfsInvalidRunlist;
            if (previous < 0 or @as(u64, @intCast(previous)) >= clusters or length > clusters - @as(u64, @intCast(previous))) return error.NtfsInvalidRunlist;
            lcn = @intCast(previous);
        }
        at += offset_bytes;
        try result.append(a, .{ .vcn = vcn, .length = length, .lcn = lcn });
        vcn = std.math.add(u64, vcn, length) catch return error.NtfsInvalidRunlist;
    }
    if (at == bytes.len or vcn == 0 or vcn - 1 != last) return error.NtfsInvalidRunlist;
    return result.toOwnedSlice(a);
}
fn encodeRuns(a: std.mem.Allocator, runs: []const Run) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var previous: i64 = 0;
    for (runs) |run| {
        var length_size: u8 = 1;
        while (length_size < 8 and run.length >= (@as(u64, 1) << @as(u6, @intCast(length_size * 8 - 1)))) length_size += 1;
        var delta: i64 = 0;
        var offset_size: u8 = 0;
        if (run.lcn) |lcn| {
            delta = @as(i64, @intCast(lcn)) - previous;
            previous = @intCast(lcn);
            offset_size = 1;
            while (offset_size < 8) : (offset_size += 1) {
                const shift: u6 = @intCast(64 - offset_size * 8);
                if ((delta << shift) >> shift == delta) break;
            }
        }
        try bytes.append(a, length_size | offset_size << 4);
        for (0..length_size) |i| try bytes.append(a, @truncate(run.length >> @intCast(i * 8)));
        for (0..offset_size) |i| try bytes.append(a, @truncate(@as(u64, @bitCast(delta)) >> @intCast(i * 8)));
    }
    try bytes.append(a, 0);
    return bytes.toOwnedSlice(a);
}
const IDENTITY: u8 = 0;
pub const DRIVER: semantic.Driver = .{ .filesystem = .ntfs, .context = &IDENTITY, .operations = &root.OPERATIONS, .vtable = &.{ .probe = root.probe, .open = open } };
fn open(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader, blank: bool) !semantic.Filesystem {
    const snapshot: model.Snapshot = if (blank) .{ .filesystem = .ntfs, .target = reader.target, .generation = 0, .block_size = 4096, .filesystem_bytes = 0, .clean = true, .capabilities = &root.OPERATIONS } else try root.inspect(&IDENTITY, a, io, reader);
    const state = try a.create(State);
    state.* = .{ .a = a, .io = io, .reader = reader, .snapshot = snapshot };
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
fn object(ctx: *anyopaque, cursor: *semantic.Cursor) !?semantic.Object {
    const state = State.cast(ctx);
    if (!state.loaded) _ = try geometry(ctx, .{ .operation = .query });
    const g = state.geometry.?;
    while (cursor.index * g.record < state.records.len) {
        const index = cursor.index;
        cursor.index += 1;
        const record = state.records[index * g.record ..][0..g.record];
        if (get(u16, record, 22) & 1 == 0 or get(u64, record, 32) != 0) continue;
        var bytes: u64 = 0;
        for (state.attributes) |attribute| if (attribute.owner == index and attribute.kind == 0x80 and attribute.bytes[9] == 0) {
            bytes = @max(bytes, if (attribute.bytes[8] == 0) @as(u64, get(u32, attribute.bytes, 16)) else get(u64, attribute.bytes, 48));
        };
        return .{ .id = index, .kind = if (index < 12 and index != 5 and index != 11) .metadata else if (get(u16, record, 22) & 2 != 0) .directory else .file, .bytes = bytes };
    }
    return null;
}
fn allocation(ctx: *anyopaque, cursor: *semantic.Cursor) !?semantic.AllocationUnit {
    const state = State.cast(ctx);
    if (state.snapshot.filesystem_bytes == 0) return null;
    if (!state.loaded) _ = try geometry(ctx, .{ .operation = .query });
    if (cursor.index >= state.units.len) return null;
    const result = state.units[cursor.index];
    cursor.index += 1;
    return result;
}
fn geometry(ctx: *anyopaque, intent: semantic.Intent) !semantic.Geometry {
    const state = State.cast(ctx);
    const bytes = if (intent.operation == .grow or intent.operation == .shrink) intent.bytes else if (intent.operation == .create) state.reader.target.capacity else state.snapshot.filesystem_bytes;
    if (bytes < 16 * 1024 * 1024 or bytes > state.reader.target.capacity or bytes % state.reader.target.sector_size != 0) return error.NtfsInvalidResizeSize;
    if ((intent.operation == .grow and bytes < state.snapshot.filesystem_bytes) or (intent.operation == .shrink and bytes > state.snapshot.filesystem_bytes)) return error.NtfsInvalidResizeDirection;
    state.desired_bytes = bytes;
    if (intent.operation == .create) {
        const g = try create.describe(state.a, bytes, state.reader.target.sector_size);
        return .{ .bytes = bytes, .allocation_size = g.cluster, .private = g, .reserved = &g.reserved };
    }
    try state.load(intent.operation == .repair);
    const g = state.geometry.?;
    const clusters = (bytes - g.sector) / g.cluster;
    var reserved: std.ArrayList(model.Range) = .empty;
    try reserved.append(state.a, .{ .offset = 0, .length = std.mem.alignForward(u64, 8192, g.cluster) });
    try reserved.append(state.a, .{ .offset = clusters * g.cluster, .length = bytes - clusters * g.cluster });
    for (state.units) |unit| if (!unit.movable and unit.owner == 8) try reserved.appendSlice(state.a, unit.sources);
    return .{ .bytes = bytes, .allocation_size = g.cluster, .reserved = try reserved.toOwnedSlice(state.a), .private = &state.geometry.? };
}
fn requirements(ctx: *anyopaque, intent: semantic.Intent, desired: semantic.Geometry, _: []const semantic.Placement) !semantic.Requirements {
    const state = State.cast(ctx);
    if (intent.operation == .create) return .{ .units = &.{}, .additional = try create.requirements(state.a, @ptrCast(@alignCast(desired.private))) };
    if (intent.operation == .repair) return .{ .units = &.{} };
    const g = state.geometry.?;
    const list = try state.a.alloc(semantic.Requirement, state.units.len - 1);
    for (state.units[0 .. state.units.len - 1], list) |unit, *r| r.* = .{ .id = unit.id, .bytes = unit.content_bytes, .granule = unit.content_bytes, .alignment = g.cluster, .bounds = .{ .offset = 0, .length = (desired.bytes - g.sector) / g.cluster * g.cluster }, .fixed = !unit.movable };
    const bitmap_bytes = std.mem.alignForward(u64, try std.math.divCeil(u64, (desired.bytes - g.sector) / g.cluster, 8), 8);
    const bytes = std.mem.alignForward(u64, bitmap_bytes, g.cluster);
    return .{ .units = list, .additional = try state.a.dupe(semantic.Requirement, &.{.{ .id = BITMAP_ID, .bytes = bytes, .granule = bytes, .alignment = g.cluster, .bounds = .{ .offset = 0, .length = (desired.bytes - g.sector) / g.cluster * g.cluster } }}) };
}
fn find(placements: []const semantic.Placement, id: u64) !semantic.Placement {
    for (placements) |p| if (p.id == id) return p;
    return error.MissingAllocationPlacement;
}
fn relocated(a: std.mem.Allocator, attr: Attribute, placements: []const semantic.Placement, g: format.Geometry, bytes: u64) ![]Run {
    if (attr.bitmap) {
        const p = try find(placements, BITMAP_ID);
        const runs = try a.alloc(Run, p.ranges.len);
        var vcn: u64 = 0;
        for (runs, p.ranges) |*run, range| {
            run.* = .{ .vcn = vcn, .length = range.length / g.cluster, .lcn = range.offset / g.cluster };
            vcn += run.length;
        }
        return runs;
    }
    if (attr.bad) {
        const limit = (bytes - g.sector) / g.cluster;
        var result: std.ArrayList(Run) = .empty;
        var at: u64 = 0;
        for (attr.runs) |run| {
            if (run.vcn >= limit) break;
            var next = run;
            next.length = @min(run.length, limit - run.vcn);
            next.unit = null;
            try result.append(a, next);
            at = next.vcn + next.length;
        }
        if (at < limit) try result.append(a, .{ .vcn = at, .length = limit - at, .lcn = null });
        return result.toOwnedSlice(a);
    }
    const result = try a.dupe(Run, attr.runs);
    for (result) |*run| if (run.unit) |id| {
        const p = try find(placements, id);
        if (p.ranges.len != 1) return error.InvalidRunPlacement;
        run.lcn = p.ranges[0].offset / g.cluster;
    };
    return result;
}
fn sealRecord(raw: []u8, sector: u32) !void {
    const at = get(u16, raw, 4);
    const count = get(u16, raw, 6);
    if (count != raw.len / sector + 1 or at < 8 or @as(usize, at) + @as(usize, count) * 2 > get(u16, raw, 20)) return error.NtfsInvalidFixup;
    var sequence = get(u16, raw, at) +% 1;
    if (sequence == 0 or sequence == 0xffff) sequence = 1;
    put(u16, raw, at, sequence);
    for (1..count) |i| {
        const end = i * sector - 2;
        put(u16, raw, at + i * 2, get(u16, raw, end));
        put(u16, raw, end, sequence);
    }
}
fn writeLogical(collector: *mutation.Collector, runs: []const Run, cluster: u32, bytes: []const u8) !void {
    var done: usize = 0;
    for (runs) |run| {
        const at = run.vcn * cluster;
        if (at >= bytes.len) continue;
        const lcn = run.lcn orelse return error.NtfsSparseMetadata;
        const length: usize = @intCast(@min(run.length * cluster, bytes.len - at));
        try collector.write(lcn * cluster, bytes[@intCast(at)..][0..length]);
        done += length;
    }
    if (done != bytes.len) return error.NtfsIncompleteMetadata;
}
fn encode(ctx: *anyopaque, intent: semantic.Intent, desired: semantic.Geometry, placements: []const semantic.Placement) !mutation.MutationSet {
    const state = State.cast(ctx);
    if (intent.operation == .create) return create.encode(state.a, state.io, state.reader.target, @ptrCast(@alignCast(desired.private)), placements, intent.partition_offset, intent.label);
    if (intent.operation == .repair) {
        state.session.?.close();
        state.session = null;
        return @import("mutate.zig").prepare(.repair, state.a, state.io, state.reader, state.snapshot, 0);
    }
    const g = state.geometry.?;
    var original_boot: [512]u8 = undefined;
    try state.reader.readInto(state.io, 0, &original_boot);
    if (desired.bytes == g.bytes and get(u32, &original_boot, 28) == intent.partition_offset / g.sector) return .{ .target = state.reader.target };
    const clusters = (desired.bytes - g.sector) / g.cluster;
    const bitmap_bytes = std.mem.alignForward(u64, try std.math.divCeil(u64, clusters, 8), 8);
    const bitmap = try state.a.alloc(u8, @intCast(bitmap_bytes));
    @memset(bitmap, 0);
    for (placements) |p| for (p.ranges) |r| {
        var bit = r.offset / g.cluster;
        while (bit < try r.end() / g.cluster) : (bit += 1) bitmap[@intCast(bit / 8)] |= @as(u8, 1) << @intCast(bit % 8);
    };
    for (@intCast(clusters)..bitmap.len * 8) |bit| bitmap[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
    var collector: mutation.Collector = .{ .allocator = state.a, .target = state.reader.target };
    const records = try state.a.dupe(u8, state.records);
    var mft_runs: std.ArrayList(Run) = .empty;
    var mirror_runs: std.ArrayList(Run) = .empty;
    var boot_mft: ?u64 = null;
    var boot_mirror: ?u64 = null;
    for (0..records.len / g.record) |index| {
        const record = records[index * g.record ..][0..g.record];
        if (get(u16, record, 22) & 1 == 0) {
            try sealRecord(record, g.sector);
            continue;
        }
        const attributes = try state.a.alloc(u8, g.record);
        @memset(attributes, 0);
        var size: usize = 0;
        for (state.attributes) |attr| if (attr.record == index) {
            var raw: []u8 = undefined;
            if (attr.bytes[8] != 0) {
                const runs = try relocated(state.a, attr, placements, g, desired.bytes);
                const pairs = try encodeRuns(state.a, runs);
                const offset = get(u16, attr.bytes, 32);
                raw = try state.a.alloc(u8, std.mem.alignForward(usize, offset + pairs.len, 8));
                @memset(raw, 0);
                @memcpy(raw[0..offset], attr.bytes[0..offset]);
                @memcpy(raw[offset..][0..pairs.len], pairs);
                put(u32, raw, 4, @intCast(raw.len));
                if (attr.bitmap or attr.bad) {
                    const n = if (attr.bitmap) std.mem.alignForward(u64, bitmap_bytes, g.cluster) / g.cluster else clusters;
                    put(u64, raw, 24, n - 1);
                    put(u64, raw, 40, n * g.cluster);
                    put(u64, raw, 48, if (attr.bitmap) bitmap_bytes else n * g.cluster);
                    put(u64, raw, 56, if (attr.bitmap) bitmap_bytes else 0);
                }
                if (attr.bitmap) try writeLogical(&collector, runs, g.cluster, bitmap);
                if (attr.owner == 0 and attr.kind == 0x80 and attr.bytes[9] == 0) {
                    try mft_runs.appendSlice(state.a, runs);
                    if (runs[0].vcn == 0) boot_mft = runs[0].lcn;
                }
                if (attr.owner == 1 and attr.kind == 0x80 and attr.bytes[9] == 0) {
                    try mirror_runs.appendSlice(state.a, runs);
                    boot_mirror = runs[0].lcn;
                }
            } else {
                raw = try state.a.dupe(u8, attr.bytes);
                if (attr.owner == 6 and attr.kind == 0x30) {
                    const value = get(u16, raw, 20);
                    if (@as(usize, value) + 56 > raw.len) return error.NtfsInvalidAttribute;
                    put(u64, raw, value + 40, std.mem.alignForward(u64, bitmap_bytes, g.cluster));
                    put(u64, raw, value + 48, bitmap_bytes);
                }
            }
            if (raw.len > attributes.len - size) return error.NtfsMetadataReservationRequired;
            @memcpy(attributes[size..][0..raw.len], raw);
            size += raw.len;
        };
        const start = get(u16, record, 20);
        if (start + size + 8 > g.record) return error.NtfsMetadataReservationRequired;
        @memset(record[start..], 0);
        @memcpy(record[start..][0..size], attributes[0..size]);
        put(u32, record, start + size, 0xffffffff);
        put(u32, record, 24, @intCast(start + size + 8));
        try sealRecord(record, g.sector);
    }
    std.mem.sort(Run, mft_runs.items, {}, struct {
        fn less(_: void, a: Run, b: Run) bool {
            return a.vcn < b.vcn;
        }
    }.less);
    try writeLogical(&collector, mft_runs.items, g.cluster, records);
    const mirrored: usize = @intCast(@as(u64, @intCast(state.session.?.volume.?.mftmirr_size)) * g.record);
    if (mirrored > records.len) return error.NtfsInvalidMetadata;
    try writeLogical(&collector, mirror_runs.items, g.cluster, records[0..mirrored]);
    const boot = try state.reader.read(state.a, state.io, .{ .offset = 0, .length = g.sector });
    format.put64(boot, 40, desired.bytes / g.sector - 1);
    format.put64(boot, 48, boot_mft orelse return error.NtfsMissingMft);
    format.put64(boot, 56, boot_mirror orelse return error.NtfsMissingMirror);
    const hidden = intent.partition_offset / g.sector;
    if (hidden > std.math.maxInt(u32)) return error.NtfsPartitionOffsetOverflow;
    put(u32, boot, 28, @intCast(hidden));
    try collector.write(0, boot);
    try collector.write(desired.bytes - g.sector, boot);
    return collector.finish();
}
fn check(ctx: *anyopaque) !model.Check {
    const state = State.cast(ctx);
    if (state.session) |session| {
        session.close();
        state.session = null;
    }
    return root.check(&IDENTITY, state.a, state.io, state.reader);
}
fn verify(ctx: *anyopaque, intent: semantic.Intent, reader: device.Reader) !model.Check {
    const state = State.cast(ctx);
    if (state.session) |session| {
        session.close();
        state.session = null;
    }
    const snapshot = try root.inspect(&IDENTITY, state.a, state.io, reader);
    if ((intent.operation == .grow or intent.operation == .shrink) and snapshot.filesystem_bytes != intent.bytes) return .{ .consistent = false, .detail = "NTFS geometry mismatch", .scope = .allocation_metadata };
    if (intent.operation == .create) {
        const expected = try create.labelBytes(state.a, intent.label);
        defer state.a.free(expected);
        const g = try format.load(state.io, reader);
        var label_state: State = .{ .a = state.a, .io = state.io, .reader = reader, .desired_bytes = g.bytes, .snapshot = snapshot };
        defer if (label_state.session) |session| session.close();
        try label_state.load(false);
        const matches = for (label_state.attributes) |attr| {
            if (attr.record != 3 or attr.kind != 0x60 or attr.bytes[8] != 0) continue;
            const start = get(u16, attr.bytes, 20);
            const length = get(u32, attr.bytes, 16);
            if (start > attr.bytes.len or length > attr.bytes.len - start) return error.NtfsInvalidAttribute;
            break std.mem.eql(u8, expected, attr.bytes[start..][0..length]);
        } else false;
        if (!matches) return .{ .consistent = false, .detail = "NTFS volume label mismatch", .scope = .allocation_metadata };
    }
    try semantic.requireCapability(snapshot, .check);
    return root.check(&IDENTITY, state.a, state.io, reader);
}
const OPS: semantic.FilesystemOps = .{ .close = close, .inspect = inspect, .enumerate_objects = object, .enumerate_allocations = allocation, .describe_geometry = geometry, .requirements = requirements, .encode_changes = encode, .check = check, .verify = verify };

/// Native allocation check; libntfs supplies bounded reads and MST decoding.
pub fn validate(a: std.mem.Allocator, io: std.Io, reader: device.Reader, repair: bool) !void {
    const g = try format.load(io, reader);
    var state: State = .{ .a = a, .io = io, .reader = reader, .desired_bytes = g.bytes, .snapshot = .{ .filesystem = .ntfs, .target = reader.target, .generation = 0, .block_size = g.cluster, .filesystem_bytes = g.bytes, .clean = true } };
    defer if (state.session) |session| session.close();
    try state.load(repair);
}
