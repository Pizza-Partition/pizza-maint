//! FAT records and references behind the portable filesystem vtable.
const std = @import("std");
const semantic = @import("../../semantic.zig");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
const mutation = @import("../../mutation.zig");
const Builder = @import("../../mutation.zig").Builder;
const root = @import("root.zig");
const format = @import("format.zig");
const scan = @import("scan.zig");
const mutate = @import("mutate.zig");
const State = struct {
    a: std.mem.Allocator,
    io: std.Io,
    reader: device.Reader,
    snapshot: model.Snapshot,
    loaded: ?scan.Loaded = null,
    repair_mode: bool = false,
    units: ?[]semantic.AllocationUnit = null,
    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }
    fn graph(self: *@This()) !*scan.Loaded {
        if (self.loaded == null) self.loaded = try scan.load(self.a, self.io, self.reader, self.repair_mode);
        return &self.loaded.?;
    }
};
const IDENTITY: u8 = 0;
pub const DRIVER: semantic.Driver = .{ .filesystem = .vfat, .context = &IDENTITY, .operations = &root.OPERATIONS, .vtable = &.{ .probe = root.probe, .open = open } };
fn open(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader, blank: bool) !semantic.Filesystem {
    const snapshot: model.Snapshot = if (blank) .{ .filesystem = .vfat, .target = reader.target, .generation = 0, .block_size = reader.target.sector_size, .filesystem_bytes = 0, .clean = true, .capabilities = &root.OPERATIONS } else try root.inspect(&IDENTITY, a, io, reader);
    const state = try a.create(State);
    state.* = .{ .a = a, .io = io, .reader = reader, .snapshot = snapshot };
    return .{ .context = state, .vtable = &OPS };
}
fn close(ctx: *anyopaque) void {
    const state = State.cast(ctx);
    state.a.destroy(state);
}
fn inspect(ctx: *anyopaque) !model.Snapshot {
    return State.cast(ctx).snapshot;
}
fn object(ctx: *anyopaque, cursor: *semantic.Cursor) !?semantic.Object {
    const state = State.cast(ctx);
    if (state.snapshot.filesystem_bytes == 0) return null;
    const graph = &(try state.graph()).graph;
    if (cursor.index == graph.objects.items.len) {
        cursor.index += 1;
        return .{ .id = std.math.maxInt(u64), .kind = .metadata, .bytes = graph.geometry.dataStart() };
    }
    if (cursor.index > graph.objects.items.len) return null;
    const index = cursor.index;
    cursor.index += 1;
    const obj = graph.objects.items[index];
    return .{ .id = index + 1, .kind = if (obj.directory) .directory else .file, .bytes = obj.bytes };
}
fn allocation(ctx: *anyopaque, cursor: *semantic.Cursor) !?semantic.AllocationUnit {
    const state = State.cast(ctx);
    if (state.snapshot.filesystem_bytes == 0) return null;
    const graph = &(try state.graph()).graph;
    if (cursor.index == graph.objects.items.len) {
        cursor.index += 1;
        const bytes = graph.geometry.dataStart();
        return .{ .id = std.math.maxInt(u64), .owner = std.math.maxInt(u64), .content_bytes = bytes, .sources = try state.a.dupe(model.Range, &.{.{ .offset = 0, .length = bytes }}), .generated = true };
    }
    if (cursor.index > graph.objects.items.len) return null;
    const i = cursor.index;
    cursor.index += 1;
    const obj = graph.objects.items[i];
    const ranges = try state.a.alloc(model.Range, obj.chain.len);
    for (obj.chain, ranges) |cluster, *r| r.* = .{ .offset = try graph.geometry.offset(cluster), .length = graph.geometry.clusterBytes() };
    return .{ .id = i + 1, .owner = i + 1, .sources = ranges, .content_bytes = obj.bytes };
}
fn geometry(ctx: *anyopaque, intent: semantic.Intent) !semantic.Geometry {
    const state = State.cast(ctx);
    state.repair_mode = intent.operation == .repair;
    const g = try state.a.create(format.Geometry);
    if (intent.operation == .create) {
        const sector = state.reader.target.sector_size;
        var per: u32 = 1;
        while (state.reader.target.capacity / sector / per > 1024 * 1024 and per * sector < 32768) per *= 2;
        g.* = try format.layout(state.reader.target.capacity, sector, per, 32, 2, 0);
    } else {
        const old = (try state.graph()).boot.geometry;
        g.* = old;
        if (intent.operation == .grow or intent.operation == .shrink) {
            if ((intent.operation == .grow and intent.bytes < old.bytes()) or (intent.operation == .shrink and intent.bytes > old.bytes()) or intent.bytes > state.reader.target.capacity) return error.FatInvalidResizeDirection;
            var per = old.per_cluster;
            while (true) {
                g.* = format.layout(intent.bytes, old.sector, per, old.reserved, old.copies, if (per == old.per_cluster) old.fat_sectors else 0) catch |err| {
                    if (err == error.FatResizeTooSmall and per > 1) {
                        per /= 2;
                        continue;
                    }
                    return err;
                };
                break;
            }
            g.flags = old.flags;
            g.info = old.info;
            g.backup = old.backup;
            g.media = old.media;
        }
    }
    var reserved: std.ArrayList(model.Range) = .empty;
    try reserved.append(state.a, .{ .offset = 0, .length = g.dataStart() });
    if (state.snapshot.filesystem_bytes != 0) {
        const graph = &(try state.graph()).graph;
        if (intent.operation == .repair) {
            var first: ?u32 = null;
            var cluster: u32 = 2;
            while (cluster <= g.clusters + 2) : (cluster += 1) {
                const occupied = cluster < g.clusters + 2 and graph.value(cluster) != 0;
                if (occupied and first == null) first = cluster;
                if (!occupied and first != null) {
                    const begin = first.?;
                    try reserved.append(state.a, .{ .offset = try g.offset(begin), .length = @as(u64, cluster - begin) * g.clusterBytes() });
                    first = null;
                }
            }
        }
        for (2..graph.owners.len) |cluster| if (graph.value(@intCast(cluster)) == format.BAD) {
            const start = try graph.geometry.offset(@intCast(cluster));
            const end = start + graph.geometry.clusterBytes();
            if (start < g.dataStart() and end > @as(u64, g.reserved) * g.sector) return error.FatBadClusterConflict;
            if (end <= g.dataStart() or start >= g.bytes()) continue;
            const first = (start -| g.dataStart()) / g.clusterBytes();
            const last = try std.math.divCeil(u64, @min(end, g.bytes()) - g.dataStart(), g.clusterBytes());
            try reserved.append(state.a, .{ .offset = g.dataStart() + first * g.clusterBytes(), .length = (last - first) * g.clusterBytes() });
        };
    }
    return .{ .bytes = g.bytes(), .allocation_size = g.clusterBytes(), .reserved = try reserved.toOwnedSlice(state.a), .private = g };
}
fn requirements(ctx: *anyopaque, intent: semantic.Intent, desired: semantic.Geometry, _: []const semantic.Placement) !semantic.Requirements {
    const state = State.cast(ctx);
    if (intent.operation == .create) {
        const g: *const format.Geometry = @ptrCast(@alignCast(desired.private));
        return .{ .units = &.{}, .additional = try state.a.dupe(semantic.Requirement, &.{.{ .id = 1, .bytes = g.clusterBytes(), .granule = g.clusterBytes(), .alignment = g.clusterBytes(), .alignment_origin = g.dataStart(), .bounds = .{ .offset = g.dataStart(), .length = @as(u64, g.clusters) * g.clusterBytes() } }}) };
    }
    if (intent.operation == .repair) {
        const graph = &(try state.graph()).graph;
        const bytes = try mutate.repairBytes(state.a, state.io, state.reader, graph);
        if (bytes == 0) return .{ .units = &.{} };
        const g = graph.geometry;
        return .{ .units = &.{}, .additional = try state.a.dupe(semantic.Requirement, &.{.{ .id = std.math.maxInt(u64) - 1, .bytes = bytes, .granule = g.clusterBytes(), .alignment = g.clusterBytes(), .alignment_origin = g.dataStart(), .bounds = .{ .offset = g.dataStart(), .length = @as(u64, g.clusters) * g.clusterBytes() } }}) };
    }
    const g: *const format.Geometry = @ptrCast(@alignCast(desired.private));
    const graph = &(try state.graph()).graph;
    const units = try state.a.alloc(semantic.Requirement, graph.objects.items.len);
    for (graph.objects.items, units, 0..) |obj, *r, i| r.* = .{ .id = i + 1, .bytes = (try std.math.divCeil(u64, obj.bytes, g.clusterBytes())) * g.clusterBytes(), .granule = g.clusterBytes(), .alignment = g.clusterBytes(), .alignment_origin = g.dataStart(), .bounds = .{ .offset = g.dataStart(), .length = @as(u64, g.clusters) * g.clusterBytes() } };
    return .{ .units = units };
}
fn encode(ctx: *anyopaque, intent: semantic.Intent, desired: semantic.Geometry, placements: []const semantic.Placement) !mutation.MutationSet {
    const state = State.cast(ctx);
    if (intent.operation == .create) return @import("create.zig").encode(state.a, state.io, state.reader.target, @as(*const format.Geometry, @ptrCast(@alignCast(desired.private))).*, placements, intent.partition_offset);
    if (intent.operation == .repair) {
        const g: *const format.Geometry = @ptrCast(@alignCast(desired.private));
        var clusters: std.ArrayList(u32) = .empty;
        for (placements) |p| if (p.id == std.math.maxInt(u64) - 1) {
            for (p.ranges) |range| try clusters.append(state.a, @intCast((range.offset - g.dataStart()) / g.clusterBytes() + 2));
        };
        return mutate.prepareRepair(state.a, state.io, state.reader, clusters.items);
    }
    const loaded = try state.graph();
    const old = loaded.boot.geometry;
    var g = @as(*const format.Geometry, @ptrCast(@alignCast(desired.private))).*;
    if (g.bytes() == old.bytes() and format.get32(loaded.boot.bytes, 28) == intent.partition_offset / g.sector) return .{ .target = state.reader.target };
    var collector: mutation.Collector = .{ .allocator = state.a, .target = state.reader.target };
    const fat = try state.a.alloc(u8, g.fatBytes());
    @memset(fat, 0);
    format.put32(fat, 0, 0x0fffff00 | @as(u32, g.media));
    format.put32(fat, 4, loaded.graph.value(1));
    for (desired.reserved[1..]) |r| {
        var start = r.offset;
        while (start < try r.end()) : (start += g.clusterBytes()) format.put32(fat, @intCast((start - g.dataStart()) / g.clusterBytes() * 4 + 8), format.BAD);
    }
    const heads = try state.a.alloc(u32, loaded.graph.owners.len);
    @memset(heads, 0);
    for (placements) |p| {
        const obj = &loaded.graph.objects.items[p.id - 1];
        obj.relocated = try state.a.alloc(u32, p.ranges.len);
        for (p.ranges, obj.relocated) |r, *cluster| cluster.* = @intCast((r.offset - g.dataStart()) / g.clusterBytes() + 2);
        heads[obj.start] = obj.relocated[0];
        for (obj.relocated, 0..) |cluster, i| format.put32(fat, @as(usize, cluster) * 4, if (i + 1 == obj.relocated.len) format.EOC else obj.relocated[i + 1]);
    }
    g.root = loaded.graph.objects.items[0].relocated[0];
    for (loaded.graph.references.items) |ref| {
        const directory = loaded.graph.objects.items[ref.directory];
        const logical_cluster = ref.position / g.clusterBytes();
        const offset = try g.offset(directory.relocated[logical_cluster]) + ref.position % g.clusterBytes();
        // Preserve the source directory record, not whatever currently occupies
        // its future destination. No virtual filesystem mutation is required.
        const original = try old.offset(directory.chain[ref.position / old.clusterBytes()]) + ref.position % old.clusterBytes();
        var entry: [32]u8 = undefined;
        try state.reader.readInto(state.io, original, &entry);
        const head = heads[ref.cluster];
        if (head == 0) return error.FatDanglingReference;
        format.setFirst(&entry, head);
        try collector.write(offset, &entry);
    }
    const boot = try state.a.dupe(u8, loaded.boot.bytes);
    boot[13] = @intCast(g.per_cluster);
    format.put32(boot, 32, g.total);
    format.put32(boot, 36, g.fat_sectors);
    format.put32(boot, 44, g.root);
    const hidden = intent.partition_offset / g.sector;
    if (hidden > std.math.maxInt(u32)) return error.FatPartitionOffsetOverflow;
    format.put32(boot, 28, @intCast(hidden));
    const previous = try state.a.alloc(u8, old.fatBytes());
    for (0..g.copies) |copy| {
        try state.reader.readInto(state.io, old.fatOffset(@intCast(copy)), previous);
        const output = try state.a.dupe(u8, fat);
        for (0..fat.len / 4) |i| format.put32(output, i * 4, (if (i < previous.len / 4) format.get32(previous, i * 4) & ~format.MASK else 0) | (format.get32(fat, i * 4) & format.MASK));
        try collector.write(g.fatOffset(@intCast(copy)), output);
    }
    try collector.write(0, boot);
    if (g.backup != 0 and g.backup != 0xffff) try collector.write(@as(u64, g.backup) * g.sector, boot);
    var free: u32 = 0;
    var next: u32 = 0xffffffff;
    for (2..@as(usize, g.clusters) + 2) |i| if (format.get32(fat, i * 4) & format.MASK == 0) {
        free += 1;
        if (next == 0xffffffff) next = @intCast(i);
    };
    if (g.info != 0 and g.info != 0xffff) {
        const info = try state.a.alloc(u8, g.sector);
        format.makeInfo(info, free, next);
        try collector.write(@as(u64, g.info) * g.sector, info);
        if (g.backup != 0 and g.backup != 0xffff and @as(u32, g.backup) + g.info < g.reserved) try collector.write((@as(u64, g.backup) + g.info) * g.sector, info);
    }
    return collector.finish();
}
fn check(ctx: *anyopaque) !model.Check {
    const state = State.cast(ctx);
    return root.check(&IDENTITY, state.a, state.io, state.reader);
}
fn verify(ctx: *anyopaque, intent: semantic.Intent, reader: device.Reader) !model.Check {
    const state = State.cast(ctx);
    const snapshot = try root.inspect(&IDENTITY, state.a, state.io, reader);
    if ((intent.operation == .grow or intent.operation == .shrink) and snapshot.filesystem_bytes != intent.bytes) return .{ .consistent = false, .detail = "FAT geometry mismatch" };
    try semantic.requireCapability(snapshot, .check);
    return root.check(&IDENTITY, state.a, state.io, reader);
}
const OPS: semantic.FilesystemOps = .{ .close = close, .inspect = inspect, .enumerate_objects = object, .enumerate_allocations = allocation, .describe_geometry = geometry, .requirements = requirements, .encode_changes = encode, .check = check, .verify = verify };
