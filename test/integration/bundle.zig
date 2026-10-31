const std = @import("std");
const bundle = @import("bundle");
const utils = @import("utils");
const bundle_build = @import("bundle_build");
const binaries = @import("test_binaries");

test "maintenance is linked for the bundle and runs after moving its working directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try bundle_build.application.verify(a, io, binaries.application);
    try std.testing.expectError(error.ApplicationInterpreterMismatch, bundle_build.application.verify(a, io, binaries.abi_checker));
    const meta = try utils.elf.metadata(a, io, binaries.application);
    try std.testing.expectEqualStrings("lib/ld-linux-x86-64.so.2", meta.interp[0]);
    try std.testing.expectEqualStrings("$ORIGIN/../lib", meta.runpath[0]);
    const directory = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-linked-application-");
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const original = try std.fs.path.join(a, &.{ directory, "original" });
    const moved = try std.fs.path.join(a, &.{ directory, "moved" });
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ original, "bin" }));
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ original, "lib" }));
    try std.Io.Dir.cwd().copyFile(binaries.application, .cwd(), try std.fs.path.join(a, &.{ original, "bin/pizza-maint" }), io, .{ .permissions = .fromMode(0o755) });
    // A host-loader fixture tests the kernel's relative PT_INTERP resolution.
    // The complete runtime dependency closure is tested by pizza-bundle's CI.
    try std.Io.Dir.cwd().copyFile(binaries.application_loader, .cwd(), try std.fs.path.join(a, &.{ original, "lib/ld-linux-x86-64.so.2" }), io, .{ .permissions = .fromMode(0o755) });
    for ([_][]const u8{ original, moved }, 0..) |root, i| {
        if (i == 1) try std.Io.Dir.cwd().renamePreserve(original, .cwd(), moved, io);
        const result = try std.process.run(a, io, .{
            .argv = &.{ "bin/pizza-maint", "--help" },
            .cwd = .{ .path = root },
        });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout, "Usage: pizza-maint"));
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "bundle paths reject traversal and symlinks escaping the staging directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-runtime-path-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "file" }), .data = "fixture" });
    _ = try bundle.rooted(a, io, root, "file");
    try std.testing.expectError(error.UnsafePath, bundle.rooted(a, io, root, "../file"));
    try std.testing.expectError(error.UnsafePath, bundle.rooted(a, io, root, "/etc/passwd"));
    try std.Io.Dir.cwd().symLink(io, "/etc/passwd", try std.fs.path.join(a, &.{ root, "escape" }), .{});
    try std.testing.expectError(error.EscapingSymlink, bundle.rooted(a, io, root, "escape"));
}
