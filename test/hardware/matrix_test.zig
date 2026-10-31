//! Supervisor process and evidence contract; these tests perform no block I/O.
const std = @import("std");
const matrix = @import("matrix.zig");
const utils = @import("utils");
const options = @import("options");
comptime {
    std.testing.refAllDecls(@import("storage").ntfs);
}

test "physical matrix owns child signals, retains evidence and refuses incomplete retries" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try utils.filesystem.createTemporaryDirectory(allocator, io, "pizza-matrix-test-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var runner: matrix.Run = .{ .allocator = allocator, .io = io, .root = root, .binary = options.fixture, .device = "/never-open-this-device", .target = .{ .identity = @splat('1'), .capacity = 128 * 1024 * 1024, .sector_size = 512 } };
    try runner.step(.ext4, "success", "ok", .none, null);
    try runner.step(.ext4, "success", "ok", .none, null); // No second spawn or log replacement.
    try std.testing.expectEqual(1, runner.results.items.len);
    try runner.step(.ext4, "seed", "seed", .none, null);
    try runner.step(.ext4, "cancelled", "ok", .cancel, null);
    try runner.step(.ext4, "killed", "ok", .kill, null);
    try runner.step(.ext4, "recover-1", "recover", .none, "killed");
    try runner.step(.ext4, "recover-2", "recover", .none, "killed");
    try std.testing.expectEqual(6, runner.results.items.len);
    try std.testing.expectEqualStrings(runner.results.items[3].home, runner.results.items[5].home);
    try std.testing.expectError(error.HardwareCaseFailed, runner.step(.ext4, "failure", "fail", .none, null));
    try std.testing.expectError(error.UnrecordedCaseRequiresRecovery, runner.step(.ext4, "failure", "ok", .none, null));
    try std.testing.expectError(error.HardwareCaseFailed, runner.step(.ext4, "missing-cut", "missing-checkpoint", .kill, null));
    try std.testing.expectError(error.MissingChildEvidence, runner.step(.ext4, "missing-json", "missing-evidence", .none, null));
    try std.testing.expectEqual(6, runner.results.items.len);
}
