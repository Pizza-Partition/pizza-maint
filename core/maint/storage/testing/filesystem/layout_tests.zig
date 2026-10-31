//! Composite transactions include real filesystems and independent checkers.
const std = @import("std");
const storage = @import("storage");
const IO = std.testing.io;
const fixtures = storage.testing.filesystems;
const Image = storage.testing.Image;
const IDENTITY = storage.testing.fixture.IDENTITY;
const Verify = struct {
    a: std.mem.Allocator,
    plan: storage.service.Plan,
    fn check(ctx: *const anyopaque, context_io: std.Io, reader: storage.device.Reader) !bool {
        const self: *const @This() = @ptrCast(@alignCast(ctx));
        return self.plan.verify(self.a, context_io, reader);
    }
};
fn execute(a: std.mem.Allocator, image: *Image, home: []const u8, name: []const u8, p: storage.service.Plan, observer: ?storage.program_executor.Observer) !void {
    const path = try std.fs.path.join(a, &.{ home, name });
    try std.Io.Dir.cwd().createDir(IO, path, .default_dir);
    var dir = try std.Io.Dir.cwd().openDir(IO, path, .{});
    defer dir.close(IO);
    var files: storage.recovery_store.Files = .{ .directory = dir };
    defer files.deinit(IO);
    const verifier: Verify = .{ .a = a, .plan = p };
    try storage.program_executor.execute(a, IO, image.backend(), files.store(), p.program, .{ .context = &verifier, .check = Verify.check }, observer);
}
fn createImage(a: std.mem.Allocator, home: []const u8, name: []const u8, bytes: u64, sector: u32) !Image {
    const path = try std.fs.path.join(a, &.{ home, name });
    const file = try std.Io.Dir.cwd().createFile(IO, path, .{ .exclusive = true });
    try file.setLength(IO, bytes);
    file.close(IO);
    return Image.open(IO, path, IDENTITY, sector);
}
fn transfer(reader: storage.device.Reader, source: storage.model.Range, destination: std.Io.File, offset: u64) !void {
    var b: [65536]u8 = undefined;
    var done: u64 = 0;
    while (done < source.length) {
        const part = b[0..@intCast(@min(b.len, source.length - done))];
        try reader.readInto(IO, source.offset + done, part);
        try destination.writePositionalAll(IO, part, offset + done);
        done += part.len;
    }
}
fn meaningful(a: std.mem.Allocator, source: storage.device.Reader, driver: storage.semantic.Driver, destination: std.Io.File, base: u64) !void {
    const fs = try driver.open(a, IO, source, false);
    defer fs.close();
    for (try storage.service.coverage(a, fs)) |range| try transfer(source, range, destination, base + range.offset);
}
fn mbr(file: std.Io.File, start: u64, length: u64, sector: u32) !void {
    var b: [512]u8 = @splat(0);
    std.mem.writeInt(u16, b[510..512], 0xaa55, .little);
    std.mem.writeInt(u32, b[440..444], 0x7162f049, .little);
    for (0..2) |index| {
        const at = 446 + index * 16;
        b[at + 4] = 0x83;
        std.mem.writeInt(u32, b[at + 8 ..][0..4], @intCast((start + index * length) / sector), .little);
        std.mem.writeInt(u32, b[at + 12 ..][0..4], @intCast(length / sector), .little);
    }
    try file.writePositionalAll(IO, &b, 0);
    try file.sync(IO);
}
const Stop = struct {
    at: usize,
    fn event(ctx: *anyopaque, completed: usize, _: usize, _: u64) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (completed == self.at) return error.CompositeInterrupted;
    }
};
fn checkPartition(a: std.mem.Allocator, home: []const u8, label: []const u8, root: storage.device.Reader, range: storage.model.Range, case: fixtures.Case, payload: []const u8) !void {
    var builder = storage.program.Builder.init(a, root);
    var view: storage.program.Builder.View = .{ .builder = &builder, .version = 0, .range = range };
    const path = try std.fs.path.join(a, &.{ home, label });
    const output = try std.Io.Dir.cwd().createFile(IO, path, .{ .exclusive = true });
    defer output.close(IO);
    try output.setLength(IO, range.length);
    try meaningful(a, view.reader(), case.driver, output, 0);
    try output.sync(IO);
    try case.fixture.check(a, IO, path);
    try case.fixture.checkPayload(a, IO, path, try a.print("{s}.payload", .{path}), payload);
}
fn runPair(a: std.mem.Allocator, left: fixtures.Case, right: fixtures.Case, initial: u64, final_left: u64, final_right: u64, interrupt: bool, sector: u32) !void {
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-layout-");
    defer std.Io.Dir.cwd().deleteTree(IO, home) catch {};
    var root = try createImage(a, home, "disk.raw", 1024 * 1024 + 2 * initial, sector);
    defer root.close(IO);
    var left_image = try createImage(a, home, "a.raw", initial, sector);
    var right_image = try createImage(a, home, "b.raw", initial, sector);
    const whole: storage.model.Range = .{ .offset = 0, .length = initial };
    const left_plan = try storage.service.filesystem(a, IO, left_image.reader(), whole, left.driver, .{ .operation = .create });
    try execute(a, &left_image, home, "create-a", left_plan, null);
    const right_plan = try storage.service.filesystem(a, IO, right_image.reader(), whole, right.driver, .{ .operation = .create });
    try execute(a, &right_image, home, "create-b", right_plan, null);
    left_image.close(IO);
    right_image.close(IO);
    const left_path = try std.fs.path.join(a, &.{ home, "a.raw" });
    const right_path = try std.fs.path.join(a, &.{ home, "b.raw" });
    const left_payload = "left partition payload";
    const right_payload = "right partition payload beyond the shrink boundary";
    // Separate directories prevent independent oracle scratch paths colliding.
    const ah = try std.fs.path.join(a, &.{ home, "left" });
    const bh = try std.fs.path.join(a, &.{ home, "right" });
    try std.Io.Dir.cwd().createDir(IO, ah, .default_dir);
    try std.Io.Dir.cwd().createDir(IO, bh, .default_dir);
    try left.fixture.seedPayload(a, IO, ah, left_path, left_payload, false);
    try right.fixture.seedPayload(a, IO, bh, right_path, right_payload, true);
    left_image = try Image.open(IO, left_path, IDENTITY, sector);
    defer left_image.close(IO);
    right_image = try Image.open(IO, right_path, IDENTITY, sector);
    defer right_image.close(IO);
    const start: u64 = 1024 * 1024;
    try meaningful(a, left_image.reader(), left.driver, root.file, start);
    try meaningful(a, right_image.reader(), right.driver, root.file, start + initial);
    try mbr(root.file, start, initial, sector);
    const original = try storage.partition_table.BUILTIN.readLayout(a, IO, root.reader());
    const desired = try a.dupe(storage.partition_table.Entry, original.entries);
    desired[0].range.length = final_left;
    desired[1].range = .{ .offset = start + final_left, .length = final_right };
    const p = try storage.service.layout(a, IO, root.reader(), desired);
    if (interrupt) {
        var stop: Stop = .{ .at = @max(1, p.program.steps.len / 2) };
        try std.testing.expectError(error.CompositeInterrupted, execute(a, &root, home, "interrupted", p, .{ .context = &stop, .event = Stop.event }));
        const directory = try std.Io.Dir.cwd().openDir(IO, try std.fs.path.join(a, &.{ home, "interrupted" }), .{});
        defer directory.close(IO);
        try std.testing.expectEqual(.rolled_back, try storage.testing.executor.recover(IO, root.backend(), directory, .{}, null));
        const recovered = try storage.partition_table.BUILTIN.readLayout(a, IO, root.reader());
        for (original.entries, recovered.entries) |before, after| try std.testing.expectEqual(before.range, after.range);
        try checkPartition(a, home, "restored-a.raw", root.reader(), original.entries[0].range, left, left_payload);
        try checkPartition(a, home, "restored-b.raw", root.reader(), original.entries[1].range, right, right_payload);
    }
    try execute(a, &root, home, "complete", p, null);
    try std.testing.expect(try p.verify(a, IO, root.reader()));
    try checkPartition(a, home, "final-a.raw", root.reader(), desired[0].range, left, left_payload);
    try checkPartition(a, home, "final-b.raw", root.reader(), desired[1].range, right, right_payload);
    if (!interrupt) {
        var usage: std.os.linux.rusage = undefined;
        if (std.os.linux.errno(std.os.linux.getrusage(0, &usage)) != .SUCCESS) return error.MemoryEvidenceUnavailable;
        std.debug.print("SPARSE_LAYOUT_OK initial_partition_bytes={d} final_a_bytes={d} final_b_bytes={d} root_bytes={d} steps={d} program_bytes={d} process_peak_rss_kib={d}\n", .{ initial, final_left, final_right, root.target.capacity, p.program.steps.len, p.program.encoded.len, usage.maxrss });
    }
}
test "composite 50-50 to 80-20 preserves all filesystem pairs and raw rollback" {
    const cases = try fixtures.cases(std.testing.allocator, storage.filesystem.BUILTIN);
    defer std.testing.allocator.free(cases);
    for (cases) |left| for (cases) |right| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        runPair(arena.allocator(), left, right, 160 * 1024 * 1024, 256 * 1024 * 1024, 64 * 1024 * 1024, true, 512) catch |err| {
            std.debug.print("composite pair {t}/{t}: {t}\n", .{ left.fixture.filesystem, right.fixture.filesystem, err });
            return err;
        };
    };
}
test "sparse composite 500 MiB plus 500 MiB becomes 800 MiB plus 200 MiB" {
    const cases = try fixtures.cases(std.testing.allocator, storage.filesystem.BUILTIN);
    defer std.testing.allocator.free(cases);
    const fat = for (cases) |case| {
        if (case.fixture.filesystem == .vfat) break case;
    } else return error.MissingFilesystemFixture;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // 1000 MiB keeps the exact 50/50 -> 80/20 ratio and MiB alignment.
    runPair(arena.allocator(), fat, fat, 500 * 1024 * 1024, 800 * 1024 * 1024, 200 * 1024 * 1024, false, 512) catch |err| {
        std.debug.print("sparse composite: {t}\n", .{err});
        return err;
    };
}

test "composite relocation and rollback use 4096-byte device sectors" {
    const cases = try fixtures.cases(std.testing.allocator, storage.filesystem.BUILTIN);
    defer std.testing.allocator.free(cases);
    const left = for (cases) |case| {
        if (case.fixture.filesystem == .ext4) break case;
    } else return error.MissingFilesystemFixture;
    const right = for (cases) |case| {
        if (case.fixture.filesystem == .btrfs) break case;
    } else return error.MissingFilesystemFixture;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try runPair(arena.allocator(), left, right, 160 * 1024 * 1024, 256 * 1024 * 1024, 64 * 1024 * 1024, true, 4096);
}
