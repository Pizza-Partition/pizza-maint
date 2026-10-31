//! Shared allocation strategy. Format drivers supply constraints and encodings.
const std = @import("std");
const model = @import("model.zig");
const semantic = @import("semantic.zig");
const Space = @import("space.zig").Space;
const program = @import("program.zig");
pub const Prepared = struct { filesystem: semantic.Filesystem, intent: semantic.Intent, geometry: semantic.Geometry, placements: []const semantic.Placement };
fn unitById(units: []const semantic.AllocationUnit, id: u64) !semantic.AllocationUnit {
    for (units) |u| if (u.id == id) return u;
    return error.UnknownAllocationUnit;
}
fn fits(range: model.Range, requirement: semantic.Requirement) !bool {
    return range.offset >= requirement.bounds.offset and try range.end() <= try requirement.bounds.end() and range.offset >= requirement.alignment_origin and (range.offset - requirement.alignment_origin) % requirement.alignment == 0;
}
pub fn prepare(a: std.mem.Allocator, fs: semantic.Filesystem, intent: semantic.Intent) !Prepared {
    const snapshot = try fs.inspect();
    if (!snapshot.clean and intent.operation != .repair and intent.operation != .create) return error.UncleanFilesystem;
    var allowed = false;
    for (snapshot.capabilities) |c| if (c.operation == intent.operation and c.support == .validated) {
        allowed = true;
        break;
    };
    if (!allowed) return error.NativeOperationUnavailable;
    const geometry = try fs.describeGeometry(intent);
    if (geometry.bytes == 0 or geometry.bytes > snapshot.target.capacity) return error.InvalidResizeSize;
    var units: std.ArrayList(semantic.AllocationUnit) = .empty;
    if (intent.operation != .create and intent.operation != .repair) {
        var cursor: semantic.Cursor = .{};
        while (try fs.enumerateAllocations(&cursor)) |u| try units.append(a, u);
    }
    var placements: []const semantic.Placement = &.{};
    var known: std.ArrayList(semantic.Requirement) = .empty;
    for (0..64) |_| {
        const requirements = try fs.requirements(intent, geometry, placements);
        if (known.items.len == 0) try known.appendSlice(a, requirements.units) else {
            if (known.items.len < requirements.units.len) return error.NonmonotonicRequirements;
            for (requirements.units, 0..) |r, i| if (!std.meta.eql(r, known.items[i])) return error.NonmonotonicRequirements;
        }
        var added = false;
        for (requirements.additional) |r| {
            var existing = false;
            for (known.items) |k| if (k.id == r.id) {
                if (!std.meta.eql(k, r)) return error.NonmonotonicRequirements;
                existing = true;
                break;
            };
            if (!existing) {
                try known.append(a, r);
                added = true;
            }
        }
        if (placements.len != 0 and !added) return .{ .filesystem = fs, .intent = intent, .geometry = geometry, .placements = placements };
        var space = try Space.init(a, .{ .offset = 0, .length = geometry.bytes });
        defer space.deinit();
        for (geometry.reserved) |r| {
            if (try r.end() > geometry.bytes) return error.InvalidAllocationRequirement;
            try space.exclude(r);
        }
        const output = try a.alloc(semantic.Placement, known.items.len);
        for (known.items, output) |r, *p| {
            if (r.bounds.length == 0 or try r.bounds.end() > geometry.bytes or r.alignment_origin > r.bounds.offset) return error.InvalidAllocationRequirement;
            if (r.bytes == 0 or r.granule == 0 or r.bytes % r.granule != 0 or r.alignment == 0 or !std.math.isPowerOfTwo(r.alignment)) return error.InvalidAllocationRequirement;
            p.* = .{ .id = r.id, .ranges = try a.alloc(model.Range, std.math.cast(usize, r.bytes / r.granule) orelse return error.StorageProgramTooLarge) };
            @memset(@constCast(p.ranges), .{ .offset = 0, .length = 0 });
        }
        // Keep legal original locations first. Every moved source will be
        // captured durably before destinations are reused by the program.
        for (known.items, output) |r, *p| {
            const u = unitById(units.items, r.id) catch continue;
            if (u.generated) continue;
            for (@constCast(p.ranges), 0..) |*destination, i| {
                const source = semantic.sourceAt(u, @as(u64, i) * r.granule, r.granule) catch continue;
                if (!try fits(source, r)) continue;
                var blocked = false;
                for (space.occupied.items, 0..) |old, index| if (!(r.fixed and index < geometry.reserved.len) and old.overlaps(source)) {
                    blocked = true;
                    break;
                };
                if (blocked) continue;
                destination.* = source;
                try space.exclude(source);
            }
        }
        for (known.items, output) |r, *p| {
            const u = unitById(units.items, r.id) catch null;
            for (@constCast(p.ranges)) |*destination| if (destination.length == 0) {
                if (r.fixed or (u != null and !u.?.movable)) return error.ImmovableAllocation;
                // A bounded temporary Space shares all reservations.
                const previous = space.bounds;
                space.bounds = r.bounds;
                destination.* = try space.allocateRelative(r.granule, r.alignment, r.alignment_origin);
                space.bounds = previous;
            };
        }
        placements = output;
        if (known.items.len == 0) return .{ .filesystem = fs, .intent = intent, .geometry = geometry, .placements = placements };
    }
    return error.GeometryDidNotConverge;
}
pub fn append(a: std.mem.Allocator, io: std.Io, builder: *program.Builder, base: u64, prepared: Prepared) !void {
    const input = builder.currentVersion();
    const Copy = struct { saved: u32, destination: u64 };
    var copies: std.ArrayList(Copy) = .empty;
    var cursor: semantic.Cursor = .{};
    while (try prepared.filesystem.enumerateAllocations(&cursor)) |u| {
        if (u.generated) continue;
        for (prepared.placements) |p| if (p.id == u.id) {
            var logical: u64 = 0;
            for (p.ranges) |destination| {
                const source = try semantic.sourceAt(u, logical, destination.length);
                if (source.offset != destination.offset) {
                    const saved = try builder.save(io, input, .{ .offset = base + source.offset, .length = source.length });
                    try copies.append(a, .{ .saved = saved, .destination = base + destination.offset });
                }
                logical += destination.length;
            }
        };
    }
    for (copies.items) |copy| try builder.restore(copy.saved, copy.destination);
    const changes = try prepared.filesystem.encodeChanges(prepared.intent, prepared.geometry, prepared.placements);
    try builder.applyVersion(io, base, changes, prepared.intent.operation == .create or prepared.intent.operation == .copy, input);
}
