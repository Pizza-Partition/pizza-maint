//! Exercise the production executor against exclusively opened ordinary images.
const std = @import("std");
const proto = @import("proto");
const journal = @import("journal");
const execution = @import("../legacy_executor.zig");
const storage = @import("storage");
const IO = std.testing.io;
fn boundary(id: []const u8, home: []const u8) journal.Boundary {
    return .{ .state = .start, .boot_id = "00000000-0000-0000-0000-000000000019", .plan_id = id, .utc_unix_ns = "1792400000000000000", .home = .{ .kind = .other_device, .path = home } };
}
fn finish(executor: *execution.Executor) !void {
    const started = try journal.monotonicNow(IO);
    while (!executor.terminal()) {
        try executor.tick(IO, try journal.monotonicNow(IO));
        if (try journal.monotonicNow(IO) - started > 60 * std.time.ns_per_s) return error.ProductionExecutionTimedOut;
        try std.Io.sleep(IO, .fromMilliseconds(1), .awake);
    }
}
test "production v2 executor formats an image and reopens committed recovery without rerunning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-production-");
    defer std.Io.Dir.cwd().deleteTree(IO, home) catch {};
    const path = try std.fs.path.join(a, &.{ home, "disk.raw" });
    const file = try std.Io.Dir.cwd().createFile(IO, path, .{ .exclusive = true });
    try file.setLength(IO, 64 * 1024 * 1024);
    file.close(IO);
    const identity = try storage.testing.ImageDevice.identify(IO, path);
    const plan: proto.Plan = .{ .id = "real_format", .version = proto.API_VERSION, .request = .{ .operation = .create, .target = .{ .path = path, .identity = try a.dupe(u8, &std.fmt.bytesToHex(identity, .lower)), .sector_size = 512, .kind = .image }, .filesystem = .vfat } };
    const directory = try std.Io.Dir.cwd().openDir(IO, home, .{});
    defer directory.close(IO);
    var executor = try execution.Executor.start(a, IO, directory, plan, boundary(plan.id, home), 1, .{ .devices = @import("devices.zig").PROVIDER });
    try finish(&executor);
    try std.testing.expectEqual(.succeeded, executor.status);
    try std.testing.expect(executor.committed > 0 and executor.committed == executor.plan.steps.len);
    try std.testing.expect((try proto.byteCount(executor.view().completed_bytes)) > 0);
    try std.testing.expectEqualStrings(executor.view().completed_bytes, executor.view().total_bytes);
    for (executor.plan.steps) |step| try std.testing.expect(!step.simulated);
    const snapshot = (try executor.snapshot(a, IO)).?;
    try std.testing.expect(snapshot.state.complete);
    executor.close(IO);
    var image = try storage.testing.ImageDevice.openReadOnly(IO, path, identity, 512);
    try std.testing.expect((try storage.filesystem.BUILTIN.check(a, IO, image.backend().reader())).consistent);
    const before = try (image.backend().reader()).digest(IO, .{ .offset = 0, .length = image.target.capacity });
    image.close(IO);
    var recovered = try execution.Executor.start(a, IO, directory, plan, boundary(plan.id, home), 2, .{ .devices = @import("devices.zig").PROVIDER });
    try finish(&recovered);
    try std.testing.expectEqual(.succeeded, recovered.status);
    recovered.close(IO);
    var different = plan;
    different.request.?.operation = .repair;
    different.request.?.filesystem = null;
    var mismatch = try execution.Executor.start(a, IO, directory, different, boundary(plan.id, home), 3, .{ .devices = @import("devices.zig").PROVIDER });
    try finish(&mismatch);
    try std.testing.expectEqual(.failed, mismatch.status);
    try std.testing.expectEqualStrings("RecoveryRequestMismatch", mismatch.message);
    mismatch.close(IO);

    image = try storage.testing.ImageDevice.openReadOnly(IO, path, identity, 512);
    defer image.close(IO);
    try std.testing.expectEqualSlices(u8, &before, &try (image.backend().reader()).digest(IO, .{ .offset = 0, .length = image.target.capacity }));
}
test "production block provider refuses ordinary files without preparing recovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-production-gate-");
    defer std.Io.Dir.cwd().deleteTree(IO, home) catch {};
    const directory = try std.Io.Dir.cwd().openDir(IO, home, .{});
    defer directory.close(IO);
    const path = try std.fs.path.join(a, &.{ home, "not-a-device.raw" });
    try directory.writeFile(IO, .{ .sub_path = "not-a-device.raw", .data = "unchanged" });
    const plan: proto.Plan = .{ .id = "physical_gate", .version = proto.API_VERSION, .request = .{ .operation = .create, .target = .{ .path = path, .identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .sector_size = 512, .kind = .physical }, .filesystem = .vfat } };
    var executor = try execution.Executor.start(a, IO, directory, plan, boundary(plan.id, home), 1, .{});
    defer executor.close(IO);
    try finish(&executor);
    try std.testing.expectEqual(.failed, executor.status);
    try std.testing.expectEqualStrings("BlockDeviceRequired", executor.message);
    try std.testing.expectEqualStrings("unchanged", try directory.readFileAlloc(IO, "not-a-device.raw", a, .limited(32)));
    try std.testing.expectError(error.FileNotFound, directory.access(IO, "ready", .{}));
    try std.testing.expectError(error.FileNotFound, directory.access(IO, "journal.bin", .{}));
}
test "production rejects image targets before opening a path or preparing recovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-image-gate-");
    defer std.Io.Dir.cwd().deleteTree(IO, home) catch {};
    const directory = try std.Io.Dir.cwd().openDir(IO, home, .{});
    defer directory.close(IO);
    const plan: proto.Plan = .{ .id = "image_gate", .version = proto.API_VERSION, .request = .{ .operation = .create, .target = .{ .path = "/must-not-open.raw", .identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .sector_size = 512, .kind = .image }, .filesystem = .vfat } };
    var executor = try execution.Executor.start(a, IO, directory, plan, boundary(plan.id, home), 1, .{});
    defer executor.close(IO);
    try finish(&executor);
    try std.testing.expectEqual(.failed, executor.status);
    try std.testing.expectEqualStrings("ImageTargetsUnsupported", executor.message);
    for (std.enums.values(storage.recovery_store.Record)) |record|
        try std.testing.expectError(error.FileNotFound, directory.access(IO, @tagName(record), .{}));
}
test "production cancellation reaches raw recovery before the worker is joined" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-production-cancel-");
    defer std.Io.Dir.cwd().deleteTree(IO, home) catch {};
    const path = try std.fs.path.join(a, &.{ home, "disk.raw" });
    const file = try std.Io.Dir.cwd().createFile(IO, path, .{ .exclusive = true });
    try file.setLength(IO, 64 * 1024 * 1024);
    file.close(IO);
    const id = try storage.testing.ImageDevice.identify(IO, path);
    const plan: proto.Plan = .{ .id = "cancelled_format", .version = proto.API_VERSION, .request = .{ .operation = .create, .target = .{ .path = path, .identity = try a.dupe(u8, &std.fmt.bytesToHex(id, .lower)), .sector_size = 512, .kind = .image }, .filesystem = .vfat } };
    const directory = try std.Io.Dir.cwd().openDir(IO, home, .{});
    defer directory.close(IO);
    var executor = try execution.Executor.start(a, IO, directory, plan, boundary(plan.id, home), 1, .{ .devices = @import("devices.zig").PROVIDER });
    defer executor.close(IO);
    executor.cancel();
    try finish(&executor);
    try std.testing.expectEqual(.interrupted, executor.status);
    var image = try storage.testing.ImageDevice.openReadOnly(IO, path, id, 512);
    defer image.close(IO);
    const bytes = try image.backend().read(a, IO, .{ .offset = 0, .length = 65536 });
    try std.testing.expect(std.mem.allEqual(u8, bytes, 0));
}
