//! NTFS-specific evidence complements the same shared contracts as ext/FAT32.
const std = @import("std");
const storage = @import("storage");
const ntfs = storage.ntfs;
const f = ntfs.format;
const REGISTRY = storage.filesystem.BUILTIN;
const Image = storage.testing.Image;
const IDENTITY = storage.testing.fixture.IDENTITY;
const tools = storage.testing.tools;
const suite = @import("../suite.zig");
fn temporary(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-ntfs-");
}
fn create(a: std.mem.Allocator, io: std.Io, root: []const u8, sector: u32, cluster: u32) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, "target.raw" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    try file.setLength(io, 64 * 1024 * 1024);
    file.close(io);
    try tools.command(a, io, &.{ "mkntfs", "-F", "-Q", "-s", try a.print("{d}", .{sector}), "-c", try a.print("{d}", .{cluster}), path });
    return path;
}
test "NTFS sector and cluster variants have a unique adapter and preserve source bytes" {
    for ([_]struct { sector: u32, cluster: u32 }{ .{ .sector = 512, .cluster = 512 }, .{ .sector = 512, .cluster = 65536 }, .{ .sector = 1024, .cluster = 4096 }, .{ .sector = 2048, .cluster = 4096 }, .{ .sector = 4096, .cluster = 4096 } }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try temporary(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try create(a, io, root, case.sector, case.cluster);
        var image = try Image.open(io, path, IDENTITY, case.sector);
        defer image.close(io);
        const before = try tools.digest(io, image.reader());
        const snapshot = try REGISTRY.query(a, io, image.reader());
        try std.testing.expectEqual(storage.model.Filesystem.ntfs, snapshot.filesystem);
        try std.testing.expectEqual(case.cluster, snapshot.block_size);
        try std.testing.expectEqual(64 * 1024 * 1024, snapshot.filesystem_bytes);
        const checked = try REGISTRY.check(a, io, image.reader());
        if (!checked.consistent) std.debug.print("NTFS {d}/{d}: {s}\n", .{ case.sector, case.cluster, checked.detail });
        try std.testing.expect(checked.consistent);
        try std.testing.expectEqual(storage.model.CheckScope.allocation_metadata, checked.scope);
        try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    }
}
test "NTFS resizes preserve Unicode names and named streams" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try create(a, io, root, 512, 4096);
    const input = try std.fs.path.join(a, &.{ root, "payload" });
    const bytes = try a.alloc(u8, 128 * 1024 + 11);
    std.Io.random(io, bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input, .data = bytes });
    const name = "/中文文件😀.bin";
    try tools.command(a, io, &.{ "ntfscp", path, input, name });
    try tools.command(a, io, &.{ "ntfscp", "-N", "附加流", path, input, name });
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    for ([_]u64{ 32 * 1024 * 1024, 64 * 1024 * 1024 }, 0..) |size, index| {
        _ = try suite.run(a, io, &image, root, if (index == 0) "shrink" else "grow", if (index == 0) .{ .kind = .shrink, .target_bytes = size } else .{ .kind = .grow, .target_bytes = size });
        for ([_]?[]const u8{ null, "附加流" }) |stream| {
            const argv: []const []const u8 = if (stream) |s| &.{ "ntfscat", "-n", s, path, name } else &.{ "ntfscat", path, name };
            const result = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(bytes.len + 1) });
            try std.testing.expect(result.term.success());
            try std.testing.expectEqualSlices(u8, bytes, result.stdout);
        }
    }
    try std.testing.expect(!(try suite.run(a, io, &image, root, "noop", .{ .kind = .repair })).changed);
}
test "NTFS refuses dirty and hibernated volumes without changing bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try create(a, io, root, 512, 4096);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    // Build a dirty but structurally intact volume in a fixture overlay.
    var overlay = storage.mutation.Builder.init(a, image.reader());
    defer overlay.deinit();
    {
        const s = try ntfs.Session.open(a, io, overlay.reader(), &overlay);
        defer s.close();
        try s.restoreFlags(1);
        try s.finish();
    }
    const changes = try overlay.finish(io, false);
    for (changes.writes) |p| try image.file.writePositionalAll(io, p.content, p.range.offset);
    var before = try tools.digest(io, image.reader());
    try std.testing.expect(!(try REGISTRY.query(a, io, image.reader())).clean);
    try std.testing.expectError(error.UncleanFilesystem, storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), .{ .kind = .shrink, .target_bytes = 32 * 1024 * 1024 }));
    try std.testing.expectError(error.NativeOperationUnavailable, storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), .{ .kind = .repair }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    // Restore the exact original flag sectors, then create a hibernation file.
    for (changes.writes) |p| {
        const original = try a.alloc(u8, p.content.len);
        try overlay.originalReader().readInto(io, p.range.offset, original);
        try image.file.writePositionalAll(io, original, p.range.offset);
    }
    image.close(io);
    const input = try std.fs.path.join(a, &.{ root, "hiber" });
    const hiber = try a.alloc(u8, 8192);
    @memset(hiber, 0);
    @memcpy(hiber[0..4], "hibr");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input, .data = hiber });
    try tools.command(a, io, &.{ "ntfscp", path, input, "/hiberfil.sys" });
    image = try Image.open(io, path, IDENTITY, 512);
    before = try tools.digest(io, image.reader());
    try std.testing.expect(!(try REGISTRY.query(a, io, image.reader())).clean);
    try std.testing.expectError(error.UncleanFilesystem, storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), .{ .kind = .grow, .target_bytes = 64 * 1024 * 1024 }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
}
test "NTFS allocated MFT corruption is refused and C device writes cannot bypass Reader" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try create(a, io, root, 512, 4096);
    const input = try std.fs.path.join(a, &.{ root, "input" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input, .data = "an allocated ordinary user record" });
    try tools.command(a, io, &.{ "ntfscp", path, input, "/payload" });
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const before = try tools.digest(io, image.reader());
    const g = try f.load(io, image.reader());
    var offset: u64 = 0;
    {
        const s = try ntfs.Session.open(a, io, image.reader(), null);
        defer s.close();
        const ni = ntfs_pathname_to_inode(s.volume.?, null, "/payload");
        if (ni == null) return error.MissingTestFile;
        const logical = ni.*.mft_no * g.record;
        const lcn = ntfs.c.ntfs_attr_vcn_to_lcn(s.volume.?.mft_na, @intCast(logical / g.cluster));
        try std.testing.expect(lcn >= 0);
        offset = @as(u64, @intCast(lcn)) * g.cluster + logical % g.cluster;
        try s.check(ntfs.c.ntfs_inode_close(ni));
        const bytes: [512]u8 = @splat(0);
        const result = ntfs.c.ntfs_pwrite(s.volume.?.unnamed_0.dev, 0, bytes.len, &bytes);
        try std.testing.expectError(error.NtfsWriteDenied, s.check(if (result < 0) -1 else 0));
    }
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    // The ordinary user record remains allocated in $MFT:$BITMAP. It cannot
    // disappear from ownership merely because its record becomes unreadable.
    try image.file.writePositionalAll(io, "BAAD", offset);
    const corrupt = try tools.digest(io, image.reader());
    const checked = REGISTRY.check(a, io, image.reader());
    if (checked) |result| try std.testing.expect(!result.consistent) else |err| try std.testing.expect(err == error.NtfsInvalidMft);
    try std.testing.expectError(error.NtfsInvalidMft, storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), .{ .kind = .shrink, .target_bytes = 32 * 1024 * 1024 }));
    try std.testing.expectEqualSlices(u8, &corrupt, &try tools.digest(io, image.reader()));
}

extern "c" fn ntfs_pathname_to_inode([*c]ntfs.c.ntfs_volume, [*c]ntfs.c.ntfs_inode, [*c]const u8) [*c]ntfs.c.ntfs_inode;

test "NTFS preserves device errors and discards failed C planning sessions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try create(a, io, root, 512, 4096);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const before = try tools.digest(io, image.reader());
    const g = try f.load(io, image.reader());
    const Broken = struct {
        source: storage.device.Reader,
        offset: u64,
        fn read(context: *const anyopaque, io_: std.Io, at: u64, bytes: []u8) !void {
            const self: *const @This() = @ptrCast(@alignCast(context));
            if (at <= self.offset and at + bytes.len > self.offset) return error.OriginalNtfsReadFailure;
            return self.source.readInto(io_, at, bytes);
        }
    };
    var broken: Broken = .{ .source = image.reader(), .offset = g.mft * g.cluster };
    const reader: storage.device.Reader = .{ .context = &broken, .target = image.target, .vtable = &.{ .read = Broken.read } };
    try std.testing.expectError(error.OriginalNtfsReadFailure, ntfs.Session.open(a, io, reader, null));
    {
        var overlay = storage.mutation.Builder.init(a, image.reader());
        defer overlay.deinit();
        overlay.max_cached_bytes = 512;
        try std.testing.expectError(error.StorageReadSetTooLarge, storage.testing.executor.prepare(REGISTRY, a, io, overlay.reader(), .{ .kind = .create, .filesystem = .ntfs }));
    }
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    // Reusing upstream globals after the failed plan must create a complete
    // volume rather than retain a pointer into the previous session's arena.
    _ = try suite.run(a, io, &image, root, "create-after-error", .{ .kind = .create, .filesystem = .ntfs });
    try std.testing.expect((try REGISTRY.check(a, io, image.reader())).consistent);
}
