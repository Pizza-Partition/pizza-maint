//! Memory policy acceptance uses the test executor, regular images and oracles.
const std = @import("std");
const storage = @import("storage");
const memory = storage.memory;
const MiB = memory.MI_B;
const Image = storage.testing.Image;
const tools = storage.testing.tools;
const REGISTRY = storage.filesystem.BUILTIN;
const IDENTITY = storage.testing.fixture.IDENTITY;
const SOURCE_IDENTITY: storage.model.Digest = @splat(0x72);

fn home(a: std.mem.Allocator) ![]const u8 {
    return @import("utils").filesystem.createTemporaryDirectory(a, std.testing.io, "pizza-memory-");
}
fn destination(a: std.mem.Allocator, root: []const u8, capacity: u64) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, "destination.raw" });
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .exclusive = true });
    defer file.close(std.testing.io);
    try file.setLength(std.testing.io, capacity);
    try file.writePositionalAll(std.testing.io, &@as([512]u8, @splat(0x5a)), capacity - 512);
    return path;
}
fn recovery(a: std.mem.Allocator, root: []const u8) !std.Io.Dir {
    const path = try std.fs.path.join(a, &.{ root, "recovery" });
    try std.Io.Dir.cwd().createDir(std.testing.io, path, .default_dir);
    return std.Io.Dir.cwd().openDir(std.testing.io, path, .{});
}
fn assertWithinBudget(e: memory.Evidence) !void {
    try std.testing.expect(e.checks > 1);
    try std.testing.expect(!e.violated);
    try std.testing.expect(e.minimum_available >= e.reserve);
    try std.testing.expect(e.peak_charged <= e.allocation_limit);
}

test "budgeted test executor clones a real 128 MiB volume while preserving the safety floor" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // FAT32's common fixture supports a 128 MiB volume without enlarging a
    // format-specific test limit. The memory controller is format-independent.
    const cases = try storage.testing.filesystems.cases(a, REGISTRY);
    const fixture = for (cases) |case| {
        if (case.fixture.filesystem == .vfat) break case.fixture;
    } else return error.MissingFilesystemFixture;
    const root = try home(a);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try fixture.create(a, io, root, 128 * MiB);
    const payload = try a.alloc(u8, 128 * 1024 + 17);
    std.Io.random(io, payload);
    try fixture.seedPayload(a, io, root, path, payload, false);
    var source = try Image.open(io, path, SOURCE_IDENTITY, 512);
    defer source.close(io);
    const target_path = try destination(a, root, 256 * MiB);
    var target = try Image.open(io, target_path, IDENTITY, 512);
    defer target.close(io);
    var dir = try recovery(a, root);
    defer dir.close(io);
    const before = try tools.digest(io, source.reader());
    var evidence: memory.Evidence = undefined;
    const options: storage.testing.executor.ExecutionOptions = .{ .recovery_directory = dir, .memory_options = .{ .policy = .{ .cache_cap = 32 * MiB }, .evidence = &evidence } };
    try std.testing.expect((try storage.testing.executor.copy(a, io, source.reader(), target.backend(), options)).changed);
    try assertWithinBudget(evidence);
    try std.testing.expect(evidence.checks > 100);
    try std.testing.expect(evidence.peak_charged < 32 * MiB);
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, source.reader()));
    var prefix = target.reader();
    prefix.target.capacity = source.target.capacity;
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, prefix));
    var tail: [512]u8 = undefined;
    try target.reader().readInto(io, target.target.capacity - tail.len, &tail);
    try std.testing.expect(std.mem.allEqual(u8, &tail, 0x5a));
    try fixture.check(a, io, target_path);
    try fixture.checkPayload(a, io, target_path, try std.fs.path.join(a, &.{ root, "output" }), payload);
}

test "memory denial leaves destination untouched and pressure after a write remains recoverable" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = (try storage.testing.filesystems.cases(a, REGISTRY))[0].fixture;
    const root = try home(a);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try fixture.create(a, io, root, fixture.smaller_bytes);
    var source = try Image.open(io, path, SOURCE_IDENTITY, 512);
    defer source.close(io);
    const target_path = try destination(a, root, fixture.capacity);
    var target = try Image.open(io, target_path, IDENTITY, 512);
    defer target.close(io);
    var dir = try recovery(a, root);
    defer dir.close(io);
    const before = try tools.digest(io, target.reader());
    var evidence: memory.Evidence = undefined;
    try std.testing.expectError(error.MemoryBudgetExceeded, storage.testing.executor.copy(a, io, source.reader(), target.backend(), .{ .recovery_directory = dir, .memory_options = .{ .policy = .{ .cache_cap = 4096 }, .evidence = &evidence } }));
    try assertWithinBudget(evidence);
    try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, target.reader()));
    try std.testing.expectEqual(storage.program_executor.Result.unprepared, try storage.testing.executor.recover(io, target.backend(), dir, .{}, null));
    const Pressure = struct {
        disk: storage.device.Device,
        writes: usize = 0,
        pressure: bool = false,
        fn sample(context: *const anyopaque, _: std.Io) !memory.linux.Snapshot {
            const self: *const @This() = @ptrCast(@alignCast(context));
            const total = 8 * 1024 * MiB;
            const available: u64 = if (self.pressure) total / 10 - 1 else 6 * 1024 * MiB;
            return .{ .total = total, .available = available, .effective_total = total, .effective_available = available };
        }
        fn read(context: *const anyopaque, inner_io: std.Io, offset: u64, bytes: []u8) !void {
            const self: *const @This() = @ptrCast(@alignCast(context));
            try self.disk.reader().readInto(inner_io, offset, bytes);
        }
        fn write(context: *anyopaque, inner_io: std.Io, offset: u64, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.disk.write(inner_io, .{ .offset = offset, .length = bytes.len }, bytes);
            self.writes += 1;
            self.pressure = true;
        }
        fn flush(context: *anyopaque, inner_io: std.Io) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.disk.flush(inner_io);
        }
        fn validate(context: *const anyopaque, inner_io: std.Io, _: storage.model.Target) !void {
            const self: *const @This() = @ptrCast(@alignCast(context));
            try self.disk.validate(inner_io);
        }
    };
    const prepared = try storage.service.copy(a, io, source.reader(), target.reader(), .{ .offset = 0, .length = target.reader().target.capacity });
    const retained = try tools.programRetainedDigest(io, target.reader(), prepared.program);
    var pressure: Pressure = .{ .disk = target.backend() };
    const guarded: storage.device.Device = .{ .context = &pressure, .target = target.target, .vtable = &.{ .reader = .{ .read = Pressure.read }, .write = Pressure.write, .flush = Pressure.flush, .validate = Pressure.validate } };
    try std.testing.expectError(error.MemorySafetyReserveBreached, storage.testing.executor.copy(a, io, source.reader(), guarded, .{ .recovery_directory = dir, .memory_options = .{ .probe = .{ .context = &pressure, .sample_fn = Pressure.sample }, .policy = .{ .cache_cap = 768 * MiB }, .evidence = &evidence } }));
    try std.testing.expectEqual(1, pressure.writes);
    try std.testing.expect(evidence.violated and evidence.minimum_available < evidence.reserve);
    // This injected violation is an expected rejection, never a passing
    // acceptance sample. A fresh recovery controller must preserve the undo.
    try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.testing.executor.recover(io, target.backend(), dir, .{ .evidence = &evidence }, null));
    try assertWithinBudget(evidence);
    try std.testing.expectEqualSlices(u8, &retained, &try tools.programRetainedDigest(io, target.reader(), prepared.program));
}
