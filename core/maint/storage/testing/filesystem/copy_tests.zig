//! All registered formats share exactly the same clone and rollback contract.
const std = @import("std");
const storage = @import("storage");
const REGISTRY = storage.filesystem.BUILTIN;
const Image = storage.testing.Image;
const tools = storage.testing.tools;
const IDENTITY = storage.testing.fixture.IDENTITY;
const SOURCE_IDENTITY: storage.model.Digest = @splat(0x72);
fn home(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-copy-");
}
fn destination(a: std.mem.Allocator, io: std.Io, root: []const u8, capacity: u64) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, "destination.raw" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.setLength(io, capacity);
    try file.writePositionalAll(io, &@as([4096]u8, @splat(0xa5)), 0);
    try file.writePositionalAll(io, &@as([512]u8, @splat(0x5a)), capacity - 512);
    return path;
}
test "shared copy clones all formats through direct vtables and preserves source and destination tail" {
    const io = std.testing.io;
    const cases = try storage.testing.filesystems.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        try std.testing.expect(case.supports(.copy));
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try home(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const source_path = try case.fixture.create(a, io, root, case.fixture.smaller_bytes);
        const bytes = try a.alloc(u8, 128 * 1024 + 17);
        std.Io.random(io, bytes);
        try case.fixture.seedPayload(a, io, root, source_path, bytes, false);
        var source = try Image.open(io, source_path, SOURCE_IDENTITY, case.fixture.sector_size);
        defer source.close(io);
        const path = try destination(a, io, root, case.fixture.capacity);
        var target = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer target.close(io);
        const before = try tools.digest(io, source.reader());
        const original = try tools.digest(io, target.reader());
        {
            var plans: std.heap.ArenaAllocator = .init(a);
            defer plans.deinit();
            const txn = try storage.service.copy(a, io, source.reader(), target.reader(), .{ .offset = 0, .length = target.reader().target.capacity });
            try std.testing.expectEqual(case.fixture.smaller_bytes, txn.clone_range.?.length);
            try std.testing.expect(txn.program.steps[0].operation.copy.source.same(source.target));
            try std.testing.expectEqualSlices(u8, &original, &try tools.digest(io, target.reader()));
            try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, source.reader()));
        }
        const recovery = try std.fs.path.join(a, &.{ root, "recovery" });
        try std.Io.Dir.cwd().createDir(io, recovery, .default_dir);
        var dir = try std.Io.Dir.cwd().openDir(io, recovery, .{});
        defer dir.close(io);
        try std.testing.expect((try storage.testing.executor.copy(a, io, source.reader(), target.backend(), .{ .recovery_directory = dir })).changed);
        try std.testing.expectEqual(case.fixture.smaller_bytes, (try REGISTRY.query(a, io, target.reader())).filesystem_bytes);
        var left: [65536]u8 = undefined;
        var right: [65536]u8 = undefined;
        var offset: u64 = 0;
        while (offset < case.fixture.smaller_bytes) : (offset += left.len) {
            try source.reader().readInto(io, offset, &left);
            try target.reader().readInto(io, offset, &right);
            try std.testing.expectEqualSlices(u8, &left, &right);
        }
        var tail: [512]u8 = undefined;
        try target.reader().readInto(io, target.target.capacity - tail.len, &tail);
        try std.testing.expect(std.mem.allEqual(u8, &tail, 0x5a));
        try case.fixture.check(a, io, path);
        try case.fixture.checkPayload(a, io, path, try std.fs.path.join(a, &.{ root, "output" }), bytes);
        try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, source.reader()));
        try std.testing.expectEqual(storage.program_executor.Result.committed, try storage.testing.executor.recover(io, target.backend(), dir, .{}, null));
    }
}
test "shared interrupted copy preserves retained bytes without needing the source" {
    const io = std.testing.io;
    const cases = try storage.testing.filesystems.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const root = try home(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const source_path = try case.fixture.create(a, io, root, case.fixture.smaller_bytes);
        var source = try Image.open(io, source_path, SOURCE_IDENTITY, case.fixture.sector_size);
        const source_before = try tools.digest(io, source.reader());
        const path = try destination(a, io, root, case.fixture.capacity);
        var target = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer target.close(io);
        const prepared = try storage.service.copy(a, io, source.reader(), target.reader(), .{ .offset = 0, .length = target.reader().target.capacity });
        const before = try tools.programRetainedDigest(io, target.reader(), prepared.program);
        const recovery = try std.fs.path.join(a, &.{ root, "recovery" });
        try std.Io.Dir.cwd().createDir(io, recovery, .default_dir);
        var dir = try std.Io.Dir.cwd().openDir(io, recovery, .{});
        defer dir.close(io);
        try std.testing.expectError(error.InjectedExecutionInterruption, storage.testing.executor.copy(a, io, source.reader(), target.backend(), .{ .recovery_directory = dir, .fault = .written }));
        try std.testing.expectEqualSlices(u8, &source_before, &try tools.digest(io, source.reader()));
        source.close(io);
        try std.Io.Dir.cwd().deleteFile(io, source_path);
        try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.testing.executor.recover(io, target.backend(), dir, .{}, null));
        try std.testing.expectEqualSlices(u8, &before, &try tools.programRetainedDigest(io, target.reader(), prepared.program));
        try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.testing.executor.recover(io, target.backend(), dir, .{}, null));
    }
}
test "copy rejects source aliases, short destinations and incompatible sectors before writing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const case = (try storage.testing.filesystems.cases(a, REGISTRY))[0];
    const root = try home(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const source_path = try case.fixture.create(a, io, root, case.fixture.smaller_bytes);
    var source = try Image.open(io, source_path, SOURCE_IDENTITY, case.fixture.sector_size);
    defer source.close(io);
    try std.testing.expectError(error.CopyAliasesSource, storage.service.copy(a, io, source.reader(), source.reader(), .{ .offset = 0, .length = source.reader().target.capacity }));
    const path = try destination(a, io, root, 1024 * 1024);
    var target = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
    defer target.close(io);
    const before = try tools.digest(io, target.reader());
    try std.testing.expectError(error.CopyTargetTooSmall, storage.service.copy(a, io, source.reader(), target.reader(), .{ .offset = 0, .length = target.reader().target.capacity }));
    var mismatched = source.reader();
    mismatched.target.sector_size = 4096;
    try std.testing.expectError(error.InvalidCloneGeometry, storage.service.copy(a, io, mismatched, target.reader(), .{ .offset = 0, .length = target.target.capacity }));
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, target.reader()));
}
test "copy preserves source read errors and rejects a changing source before any destination write" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const case = (try storage.testing.filesystems.cases(a, REGISTRY))[0];
    const root = try home(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const source_path = try case.fixture.create(a, io, root, case.fixture.smaller_bytes);
    var source = try Image.open(io, source_path, SOURCE_IDENTITY, case.fixture.sector_size);
    defer source.close(io);
    const path = try destination(a, io, root, case.fixture.capacity);
    var target = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
    defer target.close(io);
    const Faulty = struct {
        original: storage.device.Reader,
        fail: bool,
        starts: usize = 0,
        fn read(context: *const anyopaque, inner_io: std.Io, offset: u64, bytes: []u8) !void {
            const self: *@This() = @constCast(@as(*const @This(), @ptrCast(@alignCast(context))));
            if (self.fail) return error.OriginalCloneReadError;
            try self.original.readInto(inner_io, offset, bytes);
            if (offset == 0) {
                self.starts += 1;
                bytes[0] ^= 0xff;
            }
        }
    };
    const before = try tools.digest(io, target.reader());
    const prepared = try storage.service.copy(a, io, source.reader(), target.reader(), .{ .offset = 0, .length = target.target.capacity });
    for ([_]bool{ true, false }) |fail| {
        var plans: std.heap.ArenaAllocator = .init(a);
        defer plans.deinit();
        const recovery_path = try std.fs.path.join(a, &.{ root, if (fail) "read-error" else "source-change" });
        try std.Io.Dir.cwd().createDir(io, recovery_path, .default_dir);
        var dir = try std.Io.Dir.cwd().openDir(io, recovery_path, .{});
        defer dir.close(io);
        var faulty: Faulty = .{ .original = source.reader(), .fail = fail };
        const reader: storage.device.Reader = .{ .context = &faulty, .target = source.target, .vtable = &.{ .read = Faulty.read } };
        try std.testing.expectError(if (fail) error.OriginalCloneReadError else error.CloneSourceChanged, storage.testing.executor.submit(plans.allocator(), io, target.backend(), dir, prepared, &.{reader}, null));
        try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, target.reader()));
    }
}
test "copy power-loss models preserve bytes outside the destructive target range" {
    const simulator = storage.testing.crash_model;
    const cases = try storage.testing.filesystems.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try home(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const source_path = try case.fixture.create(a, io, root, case.fixture.smaller_bytes);
        var source = try Image.open(io, source_path, SOURCE_IDENTITY, case.fixture.sector_size);
        defer source.close(io);
        const source_before = try tools.digest(io, source.reader());
        const path = try destination(a, io, root, case.fixture.capacity);
        var target = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer target.close(io);
        const baseline = try a.alloc(u8, @intCast(target.target.capacity));
        try target.reader().readInto(io, 0, baseline);
        const txn = try storage.service.copy(a, io, source.reader(), target.reader(), .{ .offset = 0, .length = target.reader().target.capacity });
        const retained = try tools.programRetainedDigest(io, target.reader(), txn.program);
        const Never = struct {
            fn check(_: *const anyopaque, _: std.Io, _: storage.device.Reader) !bool {
                return error.NoVerificationBeforeCrash;
            }
        };
        for (std.enums.values(simulator.Damage)) |damage| for (0..2) |seed| {
            var scenario: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer scenario.deinit();
            const scratch = scenario.allocator();
            var machine = try simulator.Machine.init(scratch, target.target, baseline);
            try std.testing.expectError(error.InjectedExecutionInterruption, storage.testing.executor.runProgram(scratch, io, machine.disk(), machine.store(), txn.program, &.{source.reader()}, .{ .context = &IDENTITY, .check = Never.check }, .written));
            try machine.powerLoss(seed + 131, damage);
            try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.testing.executor.recoverStore(scratch, io, machine.disk(), machine.store(), null));
            try machine.powerLoss(seed + 151, .garbage);
            try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.testing.executor.recoverStore(scratch, io, machine.disk(), machine.store(), null));
            try std.testing.expectEqualSlices(u8, &retained, &try tools.programRetainedDigest(io, machine.disk().reader(), txn.program));
        };
        try std.testing.expectEqualSlices(u8, &source_before, &try tools.digest(io, source.reader()));
    }
}
