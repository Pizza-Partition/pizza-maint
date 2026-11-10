const std = @import("std");
const storage = @import("storage");
const btrfs = storage.btrfs;
const format = btrfs.format;
const REGISTRY = storage.filesystem.BUILTIN;
const Image = storage.testing.Image;
const IDENTITY = storage.testing.fixture.IDENTITY;
const tools = storage.testing.tools;
const fixture = storage.testing.btrfs_fixture;
const suite = @import("../suite.zig");
fn temporary(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-btrfs-");
}
fn file(a: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, "target.raw" });
    const fd = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    try fd.setLength(io, 512 * 1024 * 1024);
    fd.close(io);
    return path;
}
fn consistent(a: std.mem.Allocator, io: std.Io, image: *Image) !void {
    const result = try REGISTRY.check(a, io, image.reader());
    if (!result.consistent) std.debug.print("Btrfs check: {s}\n", .{result.detail});
    try std.testing.expect(result.consistent);
    try std.testing.expectEqual(storage.model.CheckScope.allocation_metadata, result.scope);
}
test "Btrfs SINGLE/DUP and all four checksum algorithms resize offline" {
    for ([_][]const u8{ "single", "dup" }) |profile| for ([_][]const u8{ "crc32c", "xxhash", "sha256", "blake2" }) |checksum| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try temporary(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try file(a, io, root);
        try fixture.mkfs(a, io, path, 512 * 1024 * 1024, null, profile, checksum, "^free-space-tree,^block-group-tree");
        try fixture.moveSystemToTail(a, io, path);
        var image = try Image.open(io, path, IDENTITY, 512);
        defer image.close(io);
        try consistent(a, io, &image);
        _ = try suite.run(a, io, &image, root, "shrink", .{ .kind = .shrink, .target_bytes = 384 * 1024 * 1024 });
        try fixture.FIXTURES[0].check(a, io, path);
        _ = try suite.run(a, io, &image, root, "grow", .{ .kind = .grow, .target_bytes = 512 * 1024 * 1024 });
        try fixture.FIXTURES[0].check(a, io, path);
    };
}
test "Btrfs ordinary non-mixed layout with free-space and block-group trees" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try file(a, io, root);
    try tools.command(a, io, &.{ "mkfs.btrfs", "-f", "-q", "-O", "free-space-tree,block-group-tree", path });
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    try consistent(a, io, &image);
    _ = try suite.run(a, io, &image, root, "shrink", .{ .kind = .shrink, .target_bytes = 384 * 1024 * 1024 });
    try fixture.FIXTURES[0].check(a, io, path);
}
test "Btrfs corrupt metadata rejects a mutation before any source write" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try fixture.FIXTURES[0].create(a, io, root, fixture.FIXTURES[0].smaller_bytes);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const graph = try btrfs.scan.load(a, io, image.reader(), true);
    const physical = try graph.physical(graph.geometry.value("root"), graph.geometry.nodeSize());
    var byte: [1]u8 = undefined;
    try image.reader().readInto(io, physical, &byte);
    byte[0] ^= 0xff;
    try image.file.writePositionalAll(io, &byte, physical);
    const before = try tools.digest(io, image.reader());
    try std.testing.expect(!(try REGISTRY.check(a, io, image.reader())).consistent);
    try std.testing.expectError(error.BtrfsChecksum, storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), .{ .kind = .grow, .target_bytes = fixture.FIXTURES[0].capacity }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
}
test "Btrfs unknown features and dirty log do not expose mutation capability" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try fixture.FIXTURES[0].create(a, io, root, fixture.FIXTURES[0].capacity);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const original = try format.load(io, image.reader());
    for (0..2) |case| {
        var b = original.super;
        if (case == 0) format.put(format.SUPER, "incompat_flags", &b, original.value("incompat_flags") | (@as(u64, 1) << 63)) else format.put(format.SUPER, "log_root", &b, 4096);
        try format.seal(original.value("csum_type"), &b);
        try image.file.writePositionalAll(io, &b, format.MIRRORS[0]);
        const snapshot = try REGISTRY.query(a, io, image.reader());
        for (snapshot.capabilities) |cap| if (cap.operation != .query) try std.testing.expectEqual(storage.model.Support.unavailable, cap.support);
        const before = try tools.digest(io, image.reader());
        _ = storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), .{ .kind = .shrink, .target_bytes = fixture.FIXTURES[0].smaller_bytes }) catch {};
        try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    }
}
test "Btrfs conflicting valid super mirrors cannot be silently repaired" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try fixture.FIXTURES[0].create(a, io, root, fixture.FIXTURES[0].capacity);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const g = try format.load(io, image.reader());
    var b = g.super;
    format.put(format.SUPER, "bytenr", &b, format.MIRRORS[1]);
    format.put(format.SUPER, "generation", &b, g.value("generation") + 1);
    try format.seal(g.value("csum_type"), &b);
    try image.file.writePositionalAll(io, &b, format.MIRRORS[1]);
    const before = try tools.digest(io, image.reader());
    try std.testing.expectError(error.BtrfsAmbiguousSuper, storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), .{ .kind = .repair }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
}
test "Btrfs relocation preserves compressed Unicode subvolumes and multi-level trees" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try fixture.FIXTURES[0].create(a, io, root, fixture.FIXTURES[0].capacity);
    const input = try std.fs.path.join(a, &.{ root, "input" });
    const subvol = try std.fs.path.join(a, &.{ input, "只读子卷" });
    try std.Io.Dir.cwd().createDirPath(io, subvol);
    const payload = try a.alloc(u8, 256 * 1024);
    for (payload, 0..) |*byte, i| byte.* = @intCast(i % 53);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ input, "payload" }), .data = payload });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ subvol, "中文文件😀" }), .data = payload });
    for (0..180) |i| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}/entry-{d}", .{ input, i }), .data = "Btrfs metadata traversal fixture" });
    try tools.command(a, io, &.{ "mkfs.btrfs", "-f", "-q", "-M", "-d", "single", "-m", "single", "-n", "4096", "-s", "4096", "-O", "^free-space-tree,^block-group-tree", "-r", input, "--subvol", "ro:只读子卷", "--compress", "zstd", path });
    try fixture.moveToTail(a, io, path);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const graph = try btrfs.scan.load(a, io, image.reader(), true);
    var multilevel = false;
    var iterator = graph.nodes.valueIterator();
    while (iterator.next()) |node| if (format.get(format.HEADER, "level", node.bytes) != 0) {
        multilevel = true;
    };
    try std.testing.expect(multilevel);
    _ = try suite.run(a, io, &image, root, "shrink", .{ .kind = .shrink, .target_bytes = fixture.FIXTURES[0].smaller_bytes });
    try fixture.FIXTURES[0].check(a, io, path);
    const output = try std.fs.path.join(a, &.{ root, "restored" });
    try std.Io.Dir.cwd().createDir(io, output, .default_dir);
    try tools.command(a, io, &.{ "btrfs", "restore", "-s", path, output });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ output, "只读子卷", "中文文件😀" }), a, .limited(payload.len + 1));
    try std.testing.expectEqualSlices(u8, payload, bytes);
    const entries = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ output, "entry-179" }), a, .limited(1024));
    try std.testing.expectEqualStrings("Btrfs metadata traversal fixture", entries);
}
test "Btrfs valid checksum does not hide an invalid parent generation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try fixture.FIXTURES[0].create(a, io, root, fixture.FIXTURES[0].capacity);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    var graph = try btrfs.scan.load(a, io, image.reader(), true);
    const node = try graph.node(graph.geometry.value("root"));
    format.put(format.HEADER, "generation", node.bytes, graph.geometry.value("generation") + 1);
    try format.seal(graph.geometry.value("csum_type"), node.bytes);
    try image.file.writePositionalAll(io, node.bytes, try graph.physical(node.logical, node.bytes.len));
    const before = try tools.digest(io, image.reader());
    const result = try REGISTRY.check(a, io, image.reader());
    try std.testing.expect(!result.consistent);
    try std.testing.expectEqualStrings("BtrfsParentMismatch", result.detail);
    try std.testing.expectError(error.BtrfsParentMismatch, storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), .{ .kind = .repair }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
}
