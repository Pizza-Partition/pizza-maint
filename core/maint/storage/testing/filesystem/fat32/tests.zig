const std = @import("std");
const storage = @import("storage");
const fat = storage.fat32;
const format = fat.format;
const Image = storage.testing.Image;
const IDENTITY = storage.testing.fixture.IDENTITY;
const tools = storage.testing.tools;
const suite = @import("../suite.zig");
const REGISTRY = storage.filesystem.BUILTIN;

fn fixture(a: std.mem.Allocator) !storage.testing.filesystems.Fixture {
    for (try storage.testing.filesystems.cases(a, REGISTRY)) |case| if (case.fixture.filesystem == .vfat) return case.fixture;
    return error.MissingFat32Fixture;
}
fn temporary(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-fat32-");
}
fn variant(a: std.mem.Allocator, io: std.Io, root: []const u8, capacity: u64, sector: u32, per_cluster: u32, copies: u32) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, "target.raw" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    try file.setLength(io, capacity);
    file.close(io);
    try tools.command(a, io, &.{ "mkfs.fat", "-F", "32", "-s", try a.print("{d}", .{per_cluster}), "-S", try a.print("{d}", .{sector}), "-f", try a.print("{d}", .{copies}), path });
    return path;
}
fn pokeFat(io: std.Io, image: *Image, g: format.Geometry, copy: u32, cluster: u32, value: u32) !void {
    var bytes: [4]u8 = undefined;
    try image.reader().readInto(io, g.fatOffset(copy) + @as(u64, cluster) * 4, &bytes);
    format.put32(&bytes, 0, (format.get32(&bytes, 0) & ~format.MASK) | value);
    try image.file.writePositionalAll(io, &bytes, g.fatOffset(copy) + @as(u64, cluster) * 4);
}

test "FAT32 sector and FAT-copy geometry variants are checked without writes" {
    const Case = struct { sector: u32, copies: u32, bytes: u64 };
    for ([_]Case{ .{ .sector = 512, .copies = 1, .bytes = 128 * 1024 * 1024 }, .{ .sector = 1024, .copies = 2, .bytes = 128 * 1024 * 1024 }, .{ .sector = 2048, .copies = 2, .bytes = 256 * 1024 * 1024 }, .{ .sector = 4096, .copies = 2, .bytes = 512 * 1024 * 1024 } }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try temporary(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try variant(a, io, root, case.bytes, case.sector, 1, case.copies);
        var image = try Image.open(io, path, IDENTITY, case.sector);
        defer image.close(io);
        const before = try tools.digest(io, image.reader());
        try std.testing.expect((try REGISTRY.check(a, io, image.reader())).consistent);
        const snapshot = try REGISTRY.query(a, io, image.reader());
        try std.testing.expectEqual(case.bytes, snapshot.filesystem_bytes);
        try std.testing.expectEqual(case.sector, snapshot.block_size);
        try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
        try tools.command(a, io, &.{ "fsck.fat", "-n", path });
    }
}

test "FAT32 shrinking reclusters nested Unicode directories and fragmented files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try variant(a, io, root, 512 * 1024 * 1024, 512, 8, 2);
    const input = try std.fs.path.join(a, &.{ root, "payload" });
    const bytes = try a.alloc(u8, 43 * 1024 + 7);
    std.Io.random(io, bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input, .data = bytes });
    try tools.command(a, io, &.{ "mmd", "-i", path, "::/目录", "::/目录/第二层" });
    const name = "::/目录/第二层/Unicode 文件 测试.bin";
    try tools.command(a, io, &.{ "mcopy", "-i", path, input, name });
    // Verify the external fixture before resizing: mtools 4.0.49 truncates
    // supplementary Unicode characters, so use BMP names for its path lookup.
    const baseline = try std.fs.path.join(a, &.{ root, "baseline" });
    try tools.command(a, io, &.{ "mcopy", "-i", path, name, baseline });
    try std.testing.expectEqualSlices(u8, bytes, try std.Io.Dir.cwd().readFileAlloc(io, baseline, a, .limited(bytes.len + 1)));
    for (0..24) |index| try tools.command(a, io, &.{ "mcopy", "-i", path, input, try a.print("::/Long root filename {d}.bin", .{index}) });
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    try std.testing.expect((try REGISTRY.check(a, io, image.reader())).consistent);
    const before = try fat.scan.load(a, io, image.reader(), false);
    try std.testing.expect(before.boot.geometry.clusterBytes() == 4096);
    _ = try suite.run(a, io, &image, root, "shrink", .{ .kind = .shrink, .target_bytes = 64 * 1024 * 1024 });
    const after = try fat.scan.load(a, io, image.reader(), false);
    try std.testing.expect(after.boot.geometry.clusterBytes() < before.boot.geometry.clusterBytes());
    try tools.command(a, io, &.{ "fsck.fat", "-n", path });
    const output = try std.fs.path.join(a, &.{ root, "dump" });
    try tools.command(a, io, &.{ "mcopy", "-i", path, name, output });
    try std.testing.expectEqualSlices(u8, bytes, try std.Io.Dir.cwd().readFileAlloc(io, output, a, .limited(bytes.len + 1)));
    _ = try suite.run(a, io, &image, root, "grow", .{ .kind = .grow, .target_bytes = 512 * 1024 * 1024 });
    try tools.command(a, io, &.{ "fsck.fat", "-n", path });
    const grown_output = try std.fs.path.join(a, &.{ root, "dump-grown" });
    try tools.command(a, io, &.{ "mcopy", "-i", path, name, grown_output });
    try std.testing.expectEqualSlices(u8, bytes, try std.Io.Dir.cwd().readFileAlloc(io, grown_output, a, .limited(bytes.len + 1)));
}

test "FAT32 repairs boot backup, FSInfo, dirty flag and a uniquely damaged FAT mirror" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const provider = try fixture(a);
    const path = try provider.create(a, io, root, provider.capacity);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const loaded = try fat.scan.load(a, io, image.reader(), false);
    const g = loaded.boot.geometry;
    try image.file.writePositionalAll(io, &.{0}, 510);
    try std.testing.expect(!(try REGISTRY.query(a, io, image.reader())).clean);
    _ = try suite.run(a, io, &image, root, "boot", .{ .kind = .repair });
    try std.testing.expect((try REGISTRY.check(a, io, image.reader())).consistent);
    try pokeFat(io, &image, g, 0, g.root, 0);
    try std.testing.expect(!(try REGISTRY.check(a, io, image.reader())).consistent);
    _ = try suite.run(a, io, &image, root, "mirror", .{ .kind = .repair });
    for (0..g.copies) |copy| try pokeFat(io, &image, g, @intCast(copy), 1, format.EOC & ~@as(u32, 0x08000000));
    _ = try suite.run(a, io, &image, root, "dirty", .{ .kind = .repair });
    try image.file.writePositionalAll(io, &.{0}, @as(u64, g.info) * g.sector);
    _ = try suite.run(a, io, &image, root, "info", .{ .kind = .repair });
    try tools.command(a, io, &.{ "fsck.fat", "-n", path });
    try std.testing.expect(!(try suite.run(a, io, &image, root, "noop", .{ .kind = .repair })).changed);
}

test "FAT32 orphan and cyclic orphan chains are salvaged without discarding bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const provider = try fixture(a);
    const path = try provider.create(a, io, root, provider.capacity);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const loaded = try fat.scan.load(a, io, image.reader(), false);
    const g = loaded.boot.geometry;
    const cluster = loaded.graph.next_free;
    const bytes = try a.alloc(u8, g.clusterBytes() * 2);
    std.Io.random(io, bytes);
    try image.file.writePositionalAll(io, bytes[0..g.clusterBytes()], try g.offset(cluster));
    try image.file.writePositionalAll(io, bytes[g.clusterBytes()..], try g.offset(cluster + 1));
    for (0..g.copies) |copy| {
        try pokeFat(io, &image, g, @intCast(copy), cluster, cluster + 1);
        try pokeFat(io, &image, g, @intCast(copy), cluster + 1, cluster);
    }
    const bad_hash = try tools.digest(io, image.reader());
    const recover_path = try std.fs.path.join(a, &.{ root, "recovery" });
    try std.Io.Dir.cwd().createDir(io, recover_path, .default_dir);
    var directory = try std.Io.Dir.cwd().openDir(io, recover_path, .{});
    defer directory.close(io);
    try std.testing.expectError(error.InjectedExecutionInterruption, storage.testing.executor.execute(a, io, image.backend(), .{ .kind = .repair }, .{ .recovery_directory = directory, .fault = .written }));
    try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.testing.executor.recover(io, image.backend(), directory, .{}, null));
    try std.testing.expectEqualSlices(u8, &bad_hash, &try tools.digest(io, image.reader()));
    _ = try suite.run(a, io, &image, root, "salvage", .{ .kind = .repair });
    try tools.command(a, io, &.{ "fsck.fat", "-n", path });
    const output = try std.fs.path.join(a, &.{ root, "orphan" });
    try tools.command(a, io, &.{ "mcopy", "-i", path, "::/FSCK0000.CHK", output });
    try std.testing.expectEqualSlices(u8, bytes, try std.Io.Dir.cwd().readFileAlloc(io, output, a, .limited(bytes.len + 1)));
}

test "FAT32 refuses ambiguous mirrors, live cycles, cross-links and impossible sizes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const provider = try fixture(a);
    const path = try provider.create(a, io, root, provider.capacity);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const loaded = try fat.scan.load(a, io, image.reader(), false);
    const g = loaded.boot.geometry;
    try pokeFat(io, &image, g, 0, loaded.graph.next_free, format.EOC);
    var before = try tools.digest(io, image.reader());
    try std.testing.expectError(error.FatAmbiguousTables, suite.run(a, io, &image, root, "ambiguous", .{ .kind = .repair }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    try pokeFat(io, &image, g, 0, loaded.graph.next_free, 0);
    for (0..g.copies) |copy| try pokeFat(io, &image, g, @intCast(copy), g.root, g.root);
    before = try tools.digest(io, image.reader());
    try std.testing.expectError(error.FatChainCycle, suite.run(a, io, &image, root, "cycle", .{ .kind = .repair }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    for (0..g.copies) |copy| try pokeFat(io, &image, g, @intCast(copy), g.root, format.EOC);
    var entries: [64]u8 = @splat(0);
    for (0..2) |index| {
        const entry = entries[index * 32 ..][0..32];
        @memcpy(entry[0..11], if (index == 0) "FILEA   BIN" else "FILEB   BIN");
        entry[11] = 0x20;
        format.setFirst(entry, loaded.graph.next_free);
        format.put32(entry, 28, 4);
    }
    try image.file.writePositionalAll(io, &entries, try g.offset(g.root));
    for (0..g.copies) |copy| try pokeFat(io, &image, g, @intCast(copy), loaded.graph.next_free, format.EOC);
    before = try tools.digest(io, image.reader());
    try std.testing.expectError(error.FatCrossLink, suite.run(a, io, &image, root, "crosslink", .{ .kind = .repair }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    @memset(&entries, 0);
    try image.file.writePositionalAll(io, &entries, try g.offset(g.root));
    for (0..g.copies) |copy| try pokeFat(io, &image, g, @intCast(copy), loaded.graph.next_free, 0);
    before = try tools.digest(io, image.reader());
    try std.testing.expectError(error.FatResizeTooSmall, suite.run(a, io, &image, root, "small", .{ .kind = .shrink, .target_bytes = 16 * 1024 * 1024 }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
}

test "FAT32 honors the active FAT and preserves physical bad clusters during growth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const provider = try fixture(a);
    const path = try provider.create(a, io, root, provider.smaller_bytes);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const loaded = try fat.scan.load(a, io, image.reader(), false);
    const g = loaded.boot.geometry;
    // Inactive FAT #0 is stale. Only FAT #1 is authoritative.
    var flags: [2]u8 = undefined;
    format.put16(&flags, 0, 0x81);
    try image.file.writePositionalAll(io, &flags, 40);
    try image.file.writePositionalAll(io, &flags, @as(u64, g.backup) * g.sector + 40);
    try pokeFat(io, &image, g, 0, g.root, 0);
    try std.testing.expect((try REGISTRY.check(a, io, image.reader())).consistent);
    const bad_cluster = g.clusters / 2;
    const bad_position = try g.offset(bad_cluster);
    try pokeFat(io, &image, g, 1, bad_cluster, format.BAD);
    _ = try suite.run(a, io, &image, root, "bad-info", .{ .kind = .repair });
    _ = try suite.run(a, io, &image, root, "grow", .{ .kind = .grow, .target_bytes = provider.capacity });
    const grown = try fat.scan.load(a, io, image.reader(), false);
    const ng = grown.boot.geometry;
    try std.testing.expectEqual(@as(u32, 1), ng.active());
    try std.testing.expect(!ng.mirrored());
    const relocated_bad: u32 = @intCast((bad_position - ng.dataStart()) / ng.clusterBytes() + 2);
    try std.testing.expectEqual(format.BAD, grown.graph.value(relocated_bad));
    try std.testing.expectEqual(bad_position, try ng.offset(relocated_bad));
    try tools.command(a, io, &.{ "fsck.fat", "-n", path });
    // A reported hardware error cannot be 'repaired' by clearing its bit.
    try pokeFat(io, &image, ng, 1, 1, format.EOC & ~@as(u32, 0x04000000));
    const before = try tools.digest(io, image.reader());
    try std.testing.expectError(error.FatSurfaceScanRequired, suite.run(a, io, &image, root, "hardware", .{ .kind = .repair }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
}

test "FAT32 semantic queries preserve source errors and never modify bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const provider = try fixture(a);
    const path = try provider.create(a, io, root, provider.capacity);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const before = try tools.digest(io, image.reader());
    try std.testing.expect((try REGISTRY.check(a, io, image.reader())).consistent);
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    const Broken = struct {
        fn read(_: *const anyopaque, _: std.Io, _: u64, _: []u8) !void {
            return error.OriginalFatReadFailure;
        }
    };
    var reader = image.reader();
    reader.vtable = &.{ .read = Broken.read };
    try std.testing.expectError(error.OriginalFatReadFailure, REGISTRY.query(a, io, reader));
}

test "FAT12 and FAT16 do not route to the FAT32 backend" {
    for ([_][]const u8{ "12", "16" }) |bits| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try temporary(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try std.fs.path.join(a, &.{ root, "old-fat.raw" });
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        try file.setLength(io, if (std.mem.eql(u8, bits, "12")) 2 * 1024 * 1024 else 16 * 1024 * 1024);
        file.close(io);
        try tools.command(a, io, &.{ "mkfs.fat", "-F", bits, path });
        var image = try Image.open(io, path, IDENTITY, 512);
        defer image.close(io);
        const before = try tools.digest(io, image.reader());
        try std.testing.expectError(error.FilesystemUnavailable, REGISTRY.query(a, io, image.reader()));
        try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    }
}

test "FAT32 repair requests directory growth space from the common allocator" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try temporary(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const provider = try fixture(a);
    const path = try provider.create(a, io, root, provider.capacity);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const loaded = try fat.scan.load(a, io, image.reader(), false);
    const g = loaded.boot.geometry;
    const count = g.clusterBytes() / 32 + 2;
    const payload = try a.alloc(u8, g.clusterBytes());
    @memset(payload, 0xa7);
    for (0..count) |i| {
        const cluster = loaded.graph.next_free + @as(u32, @intCast(i));
        for (0..g.copies) |copy| try pokeFat(io, &image, g, @intCast(copy), cluster, format.EOC);
        try image.file.writePositionalAll(io, payload, try g.offset(cluster));
    }
    try image.file.sync(io);
    const plan = try storage.service.filesystem(a, io, image.reader(), .{ .offset = 0, .length = image.target.capacity }, null, .{ .operation = .repair });
    const recovery = try std.fs.path.join(a, &.{ root, "recovery" });
    try std.Io.Dir.cwd().createDir(io, recovery, .default_dir);
    const directory = try std.Io.Dir.cwd().openDir(io, recovery, .{});
    defer directory.close(io);
    var files: storage.recovery_store.Files = .{ .directory = directory };
    defer files.deinit(io);
    try storage.program_executor.execute(a, io, image.backend(), files.store(), plan.program, null, null);
    try std.testing.expect(try plan.verify(a, io, image.reader()));
    const repaired = try fat.scan.load(a, io, image.reader(), false);
    try std.testing.expect(repaired.graph.objects.items[0].chain.len > loaded.graph.objects.items[0].chain.len);
    try tools.command(a, io, &.{ "fsck.fat", "-n", path });
    const output = try std.fs.path.join(a, &.{ root, "salvaged" });
    try tools.command(a, io, &.{ "mcopy", "-i", path, try a.print("::/FSCK{d:0>4}.CHK", .{count - 1}), output });
    try std.testing.expectEqualSlices(u8, payload, try std.Io.Dir.cwd().readFileAlloc(io, output, a, .limited(payload.len + 1)));
}
