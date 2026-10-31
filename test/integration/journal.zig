const std = @import("std");
const utils = @import("utils");
const journal = @import("journal");

test "report CLI preserves a torn journal and labels interrupted steps without guessing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-report-test-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    const anchor: journal.Boundary = .{ .state = .start, .boot_id = "00000000-0000-0000-0000-000000000001", .plan_id = "test_report", .utc_unix_ns = "1792400000000000000", .home = .{ .kind = .other_device, .path = root } };
    var writer = try journal.Writer.create(a, io, dir, anchor, 1, .{});
    _ = try writer.intent(io, 1, 2, "begin");
    _ = try writer.commit(io, 1, 3, "ok");
    _ = try writer.intent(io, 2, 4, "in flight");
    // Valid note after an intent must never conceal the interrupted work.
    _ = try writer.note(io, 2, 5, "still running\x00\xff");
    const valid_bytes = writer.offset;
    writer.close(io);
    const path = try std.fs.path.join(a, &.{ root, "journal.bin" });
    const file = try dir.openFile(io, "journal.bin", .{ .mode = .read_write });
    try file.writePositionalAll(io, "torn", valid_bytes);
    file.close(io);
    const before = try utils.filesystem.hashFileSha256(a, io, path);
    const result = try std.process.run(a, io, .{ .argv = &.{ @import("test_binaries").tools, "report", path } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("", result.stderr);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, result.stdout, .{});
    try std.testing.expectEqualStrings("short_header", value.object.get("tail").?.string);
    try std.testing.expectEqualStrings("5", value.object.get("last_seq").?.string);
    try std.testing.expect(!value.object.get("completed").?.bool);
    const steps = value.object.get("steps").?.array.items;
    try std.testing.expectEqualStrings("succeeded", steps[0].object.get("state").?.string);
    try std.testing.expectEqualStrings("in_flight", steps[1].object.get("state").?.string);
    try std.testing.expectEqualStrings(before, try utils.filesystem.hashFileSha256(a, io, path));
}
