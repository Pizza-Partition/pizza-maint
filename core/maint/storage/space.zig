//! Shared first-fit placement. Original allocations stay excluded throughout a
//! transaction, even after their planned relocation, to preserve rollback data.
const std = @import("std");
const Range = @import("model.zig").Range;

pub const Space = struct {
    allocator: std.mem.Allocator,
    bounds: Range,
    occupied: std.ArrayList(Range) = .empty,

    pub fn init(a: std.mem.Allocator, bounds: Range) !Space {
        if (bounds.length == 0) return error.NoPlacementSpace;
        _ = try bounds.end();
        return .{ .allocator = a, .bounds = bounds };
    }

    pub fn deinit(self: *Space) void {
        self.occupied.deinit(self.allocator);
        self.* = undefined;
    }

    /// Existing allocations may cross the target bounds; the intersecting part
    /// still blocks placement. Overlapping exclusions are harmless.
    pub fn exclude(self: *Space, range: Range) !void {
        if (range.length == 0) return error.EmptyAllocation;
        _ = try range.end();
        if (range.overlaps(self.bounds)) try self.occupied.append(self.allocator, range);
    }

    pub fn allocate(self: *Space, length: u64, alignment: u32) !Range {
        return self.allocateRelative(length, alignment, 0);
    }
    pub fn allocateRelative(self: *Space, length: u64, alignment: u32, origin: u64) !Range {
        if (length == 0) return error.EmptyAllocation;
        if (origin > self.bounds.offset) return error.InvalidAllocationAlignment;
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAllocationAlignment;
        const end = try self.bounds.end();
        var cursor = try std.math.add(u64, origin, try alignedOffset(self.bounds.offset - origin, alignment));
        while (cursor <= end and length <= end - cursor) {
            const candidate: Range = .{ .offset = cursor, .length = length };
            var next = cursor;
            for (self.occupied.items) |used| if (candidate.overlaps(used)) {
                next = @max(next, try used.end());
            };
            if (next == cursor) {
                try self.occupied.append(self.allocator, candidate);
                return candidate;
            }
            cursor = try std.math.add(u64, origin, try alignedOffset(next - origin, alignment));
        }
        return error.NoPlacementSpace;
    }

    fn alignedOffset(value: u64, alignment: u32) !u64 {
        const padding = (alignment - value % alignment) % alignment;
        return std.math.add(u64, value, padding) catch error.RangeOverflow;
    }
};
