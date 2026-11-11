//! Shared data-version barrier and intent folding rules.
const std = @import("std");
const wire = @import("generated.zig");
pub fn optimize(a: std.mem.Allocator, input: []const wire.PlanIntent) ![]const wire.PlanIntent {
    if (input.len > 16384) return error.PlanTooLarge;
    var out: std.ArrayList(wire.PlanIntent) = .empty;
    for (input) |intent| {
        var handled = false;
        if (intent.kind == .resize or intent.kind == .move or intent.kind == .label or intent.kind == .delete) {
            var j = out.items.len;
            while (j != 0) {
                j -= 1;
                const old = &out.items[j];
                if (old.kind == .barrier or old.kind == .copy or old.kind == .format or old.kind == .delete) break;
                if (!std.mem.eql(u8, old.partition_id, intent.partition_id)) continue;
                if (old.kind == .create and intent.kind != .move) {
                    if (intent.kind == .delete) {
                        _ = out.orderedRemove(j);
                    } else {
                        if (intent.length) |n| old.length = n;
                        if (intent.offset) |n| old.offset = n;
                        if (intent.label) |label| old.label = label;
                    }
                    handled = true;
                } else if (old.kind == intent.kind) {
                    old.* = intent;
                    handled = true;
                }
                break;
            }
        }
        if (!handled) try out.append(a, intent);
    }
    return out.toOwnedSlice(a);
}
test "normalization respects data-version barriers and cancels unused creations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const output = try optimize(a, &.{ .{ .kind = .resize, .partition_id = "a", .length = "1024" }, .{ .kind = .resize, .partition_id = "a", .length = "2048" }, .{ .kind = .copy, .partition_id = "b", .source_id = "a" }, .{ .kind = .resize, .partition_id = "a", .length = "4096" }, .{ .kind = .create, .partition_id = "new", .length = "512" }, .{ .kind = .resize, .partition_id = "new", .length = "1024" }, .{ .kind = .delete, .partition_id = "new" } });
    try std.testing.expectEqual(3, output.len);
    try std.testing.expectEqualStrings("2048", output[0].length.?);
    try std.testing.expectEqual(.copy, output[1].kind);
    try std.testing.expectEqualStrings("4096", output[2].length.?);
}
