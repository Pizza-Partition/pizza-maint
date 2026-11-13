//! Shared first-fit placement. Original allocations stay excluded throughout a
//! transaction, even after their planned relocation, to preserve rollback data.
const std = @import("std");
const Range = @import("model.zig").Range;

pub const Space = struct {
    allocator: std.mem.Allocator,
    bounds: Range,
    occupied: std.ArrayList(Range) = .empty,
    // Keep admission order in occupied: fixed filesystem allocations distinguish
    // the initial reserved entries. Placement uses a separate merged index.
    blocked: std.ArrayList(Range) = .empty,

    pub fn init(a: std.mem.Allocator, bounds: Range) !Space {
        if (bounds.length == 0) return error.NoPlacementSpace;
        _ = try bounds.end();
        return .{ .allocator = a, .bounds = bounds };
    }

    pub fn deinit(self: *Space) void {
        self.occupied.deinit(self.allocator);
        self.blocked.deinit(self.allocator);
        self.* = undefined;
    }

    /// Existing allocations may cross the target bounds; the intersecting part
    /// still blocks placement. Overlapping exclusions are harmless.
    pub fn exclude(self: *Space, range: Range) !void {
        if (range.length == 0) return error.EmptyAllocation;
        var end = try range.end();
        if (!range.overlaps(self.bounds)) return;
        try self.occupied.append(self.allocator, range);
        var low: usize = 0;
        var high = self.blocked.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (try self.blocked.items[mid].end() < range.offset) low = mid + 1 else high = mid;
        }
        var start = range.offset;
        var last = low;
        while (last < self.blocked.items.len and self.blocked.items[last].offset <= end) : (last += 1) {
            start = @min(start, self.blocked.items[last].offset);
            end = @max(end, try self.blocked.items[last].end());
        }
        try self.blocked.replaceRange(self.allocator, low, last - low, &.{.{ .offset = start, .length = end - start }});
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
        // Scan each occupied interval at most once. Adjacent small allocations
        // coalesce, rather than restarting from the disk origin for every block.
        for (self.blocked.items) |used| {
            if (cursor > end or length > end - cursor) return error.NoPlacementSpace;
            const used_end = try used.end();
            if (used_end <= cursor) continue;
            if (used.offset >= cursor and length <= used.offset - cursor) break;
            cursor = try std.math.add(u64, origin, try alignedOffset(used_end - origin, alignment));
        }
        if (cursor > end or length > end - cursor) return error.NoPlacementSpace;
        const candidate: Range = .{ .offset = cursor, .length = length };
        try self.exclude(candidate);
        return candidate;
    }

    fn alignedOffset(value: u64, alignment: u32) !u64 {
        const padding = (alignment - value % alignment) % alignment;
        return std.math.add(u64, value, padding) catch error.RangeOverflow;
    }
};
