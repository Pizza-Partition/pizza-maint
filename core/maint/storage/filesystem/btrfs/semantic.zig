//! Physical chunk constraints and metadata encodings, never placement policy.
const std = @import("std");
const semantic = @import("../../semantic.zig");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
const mutation = @import("../../mutation.zig");
const Builder = @import("../../mutation.zig").Builder;
const root = @import("root.zig");
const format = @import("format.zig");
const scan = @import("scan.zig");
const create = @import("create.zig");
const State = struct {
    a: std.mem.Allocator,
    io: std.Io,
    reader: device.Reader,
    snapshot: model.Snapshot,
    loaded: ?scan.Graph = null,
    repair_mode: bool = false,
    units: ?[]semantic.AllocationUnit = null,
    objects: ?[]semantic.Object = null,
    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }
    fn graph(self: *@This()) !*scan.Graph {
        if (self.loaded == null) self.loaded = try scan.load(self.a, self.io, self.reader, !self.repair_mode);
        return &self.loaded.?;
    }
    fn allocations(self: *@This()) ![]semantic.AllocationUnit {
        if (self.units) |units| return units;
        var units: std.ArrayList(semantic.AllocationUnit) = .empty;
        const g = try self.graph();
        for (g.chunks, 0..) |chunk, ci| for (chunk.stripes) |stripe| {
            var movable = true;
            for (format.MIRRORS) |position| if (stripe.physical < position + 65536 and position < stripe.physical + chunk.length) {
                movable = false;
            };
            const sources = try self.a.dupe(model.Range, &.{.{ .offset = stripe.physical, .length = chunk.length }});
            try units.append(self.a, .{ .id = units.items.len + 1, .owner = ci + 1, .sources = sources, .content_bytes = chunk.length, .group = ci + 1, .movable = movable });
        };
        self.units = try units.toOwnedSlice(self.a);
        return self.units.?;
    }
};
const IDENTITY: u8 = 0;
pub const DRIVER: semantic.Driver = .{ .filesystem = .btrfs, .context = &IDENTITY, .operations = &root.OPERATIONS, .vtable = &.{ .probe = root.probe, .open = open } };
fn open(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader, blank: bool) !semantic.Filesystem {
    const state = try a.create(State);
    state.* = .{ .a = a, .io = io, .reader = reader, .snapshot = if (blank) .{ .filesystem = .btrfs, .target = reader.target, .generation = 0, .block_size = 4096, .filesystem_bytes = 0, .clean = true, .capabilities = &root.OPERATIONS } else try root.inspect(&IDENTITY, a, io, reader) };
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
    if (state.objects == null) {
        var objects: std.ArrayList(semantic.Object) = .empty;
        const g = try state.graph();
        for (g.chunks, 0..) |chunk, i| try objects.append(state.a, .{ .id = i + 1, .kind = .metadata, .bytes = chunk.length });
        for (g.trees.items) |tree| {
            const is_files = tree.owner == 5 or (tree.owner >= 256 and tree.owner < (@as(u64, 1) << 63));
            if (!is_files) continue;
            for (tree.leaves) |logical| for ((try g.node(logical)).entries) |entry| {
                if (entry.key.kind != format.c_api.BTRFS_INODE_ITEM_KEY) continue;
                const inode = entry.data;
                if (inode.len < @sizeOf(format.c_api.struct_btrfs_inode_item)) return error.BtrfsInvalidInode;
                const kind = if (format.get(format.c_api.struct_btrfs_inode_item, "mode", inode) & 0xf000 == 0x4000) @FieldType(semantic.Object, "kind").directory else @FieldType(semantic.Object, "kind").file;
                // IDs are local to this filesystem instance, separate from chunk owners.
                try objects.append(state.a, .{ .id = objects.items.len + 1, .kind = kind, .bytes = format.get(format.c_api.struct_btrfs_inode_item, "size", inode) });
            };
        }
        state.objects = try objects.toOwnedSlice(state.a);
    }
    const objects = state.objects.?;
    if (cursor.index >= objects.len) return null;
    const result = objects[cursor.index];
    cursor.index += 1;
    return result;
}
fn allocation(ctx: *anyopaque, cursor: *semantic.Cursor) !?semantic.AllocationUnit {
    const state = State.cast(ctx);
    if (state.snapshot.filesystem_bytes == 0) return null;
    const units = try state.allocations();
    if (cursor.index >= units.len) return null;
    const result = units[cursor.index];
    cursor.index += 1;
    return result;
}
fn geometry(ctx: *anyopaque, intent: semantic.Intent) !semantic.Geometry {
    const state = State.cast(ctx);
    state.repair_mode = intent.operation == .repair;
    const bytes = if (intent.operation == .grow or intent.operation == .shrink) intent.bytes else if (intent.operation == .create) state.reader.target.capacity else state.snapshot.filesystem_bytes;
    if (bytes > state.reader.target.capacity or bytes < 32 * 1024 * 1024 or bytes % state.snapshot.block_size != 0) return error.BtrfsInvalidResizeSize;
    if ((intent.operation == .grow and bytes < state.snapshot.filesystem_bytes) or (intent.operation == .shrink and bytes > state.snapshot.filesystem_bytes)) return error.BtrfsInvalidResizeDirection;
    if (intent.operation != .create and bytes < format.get(format.DEV, "bytes_used", (try state.graph()).geometry.dev())) return error.BtrfsInvalidResizeSize;
    var reserved: std.ArrayList(model.Range) = .empty;
    try reserved.append(state.a, .{ .offset = 0, .length = 1024 * 1024 });
    for (format.MIRRORS) |offset| if (offset < bytes) try reserved.append(state.a, .{ .offset = offset, .length = @min(65536, bytes - offset) });
    return .{ .bytes = bytes, .allocation_size = 65536, .private = &IDENTITY, .reserved = try reserved.toOwnedSlice(state.a) };
}
fn requirements(ctx: *anyopaque, intent: semantic.Intent, desired: semantic.Geometry, _: []const semantic.Placement) !semantic.Requirements {
    const state = State.cast(ctx);
    if (intent.operation == .create) {
        const reqs = try state.a.alloc(semantic.Requirement, 2);
        for (reqs, [_]u64{ create.SYSTEM_LENGTH, create.MIXED_LENGTH }, 0..) |*r, length, i| r.* = .{ .id = i + 1, .bytes = length, .granule = length, .alignment = 65536, .bounds = .{ .offset = 1024 * 1024, .length = desired.bytes - 1024 * 1024 } };
        return .{ .units = &.{}, .additional = reqs };
    }
    if (intent.operation == .repair) return .{ .units = &.{} };
    const units = try state.allocations();
    const reqs = try state.a.alloc(semantic.Requirement, units.len);
    for (units, reqs) |u, *r| {
        // A chunk is one contiguous placement. Only its start, not its size,
        // must have the format's 64 KiB alignment.
        r.* = .{ .id = u.id, .bytes = u.content_bytes, .granule = @intCast(u.content_bytes), .alignment = 65536, .bounds = .{ .offset = 1024 * 1024, .length = desired.bytes - 1024 * 1024 }, .fixed = !u.movable };
    }
    return .{ .units = reqs };
}
fn encode(ctx: *anyopaque, intent: semantic.Intent, desired: semantic.Geometry, placements: []const semantic.Placement) !mutation.MutationSet {
    const state = State.cast(ctx);
    if (intent.operation == .create) {
        var layout: create.Layout = undefined;
        for ([_]u64{ 1, 2 }) |id| {
            const p = for (placements) |p| {
                if (p.id == id) break p;
            } else return error.MissingAllocationPlacement;
            if (p.ranges.len != 1 or p.ranges[0].length != (if (id == 1) create.SYSTEM_LENGTH else create.MIXED_LENGTH)) return error.InvalidChunkPlacement;
            if (id == 1) layout.system_physical = p.ranges[0].offset else layout.mixed_physical = p.ranges[0].offset;
        }
        var builder = Builder.init(state.a, state.reader);
        defer builder.deinit();
        try create.create(state.a, state.io, &builder, layout);
        _ = try scan.load(state.a, state.io, builder.reader(), true);
        return builder.finish(state.io, true);
    }
    if (intent.operation == .repair) return root.mutate.prepare(.repair, state.a, state.io, state.reader, state.snapshot, 0);
    const g = try state.graph();
    if (desired.bytes == g.geometry.bytes()) return .{ .target = state.reader.target };
    var id: u64 = 1;
    for (g.chunks) |*chunk| for (chunk.stripes, 0..) |*stripe, i| {
        const previous = stripe.physical;
        const p = for (placements) |p| {
            if (p.id == id) break p;
        } else return error.MissingAllocationPlacement;
        id += 1;
        if (p.ranges.len != 1 or p.ranges[0].length != chunk.length) return error.InvalidChunkPlacement;
        const dest = p.ranges[0].offset;
        if (dest == previous) continue;
        for ((try g.tree(4)).leaves) |logical| for ((try g.node(logical)).entries) |*entry| if (entry.key.kind == format.c_api.BTRFS_DEV_EXTENT_KEY and entry.key.offset == previous) {
            entry.key.offset = dest;
        };
        stripe.physical = dest;
        format.put(format.STRIPE, "offset", chunk.raw[@offsetOf(format.CHUNK, "stripe") + i * @sizeOf(format.STRIPE) ..], dest);
    };
    var builder = Builder.init(state.a, state.reader);
    defer builder.deinit();
    try root.mutate.rewrite(state.a, state.io, &builder, g, desired.bytes);
    return builder.finish(state.io, false);
}
fn check(ctx: *anyopaque) !model.Check {
    const state = State.cast(ctx);
    return root.check(&IDENTITY, state.a, state.io, state.reader);
}
fn verify(ctx: *anyopaque, intent: semantic.Intent, reader: device.Reader) !model.Check {
    const state = State.cast(ctx);
    const snapshot = try root.inspect(&IDENTITY, state.a, state.io, reader);
    if ((intent.operation == .grow or intent.operation == .shrink) and snapshot.filesystem_bytes != intent.bytes) return .{ .consistent = false, .detail = "Btrfs geometry mismatch", .scope = .allocation_metadata };
    try semantic.requireCapability(snapshot, .check);
    return root.check(&IDENTITY, state.a, state.io, reader);
}
const OPS: semantic.FilesystemOps = .{ .close = close, .inspect = inspect, .enumerate_objects = object, .enumerate_allocations = allocation, .describe_geometry = geometry, .requirements = requirements, .encode_changes = encode, .check = check, .verify = verify };
