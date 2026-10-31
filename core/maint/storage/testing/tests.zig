//! Device admission, raw recovery and semantic planning contracts.
const std = @import("std");
const storage = @import("storage");
const model = storage.model;
const device = storage.device;
const Image = storage.testing.Image;
const fixture = storage.testing.fixture;
const executor = storage.testing.executor;
const execution = storage.program_executor;
fn submit(a: std.mem.Allocator, io: std.Io, disk: device.Device, dir: std.Io.Dir, program: storage.program.Program, verifier: ?execution.Verifier, fault: ?executor.Cut) !void {
    var files: storage.recovery_store.Files = .{ .directory = dir };
    defer files.deinit(io);
    try executor.runProgram(a, io, disk, files.store(), program, &.{}, verifier, fault);
}

test "physical execution requires explicit capability and recovery binds device kind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-physical-gate-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var directory = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer directory.close(io);
    var image = try Image.open(io, try fixture.create(a, io, home), fixture.IDENTITY, 512);
    defer image.close(io);
    image.target.kind = .physical_device;
    const plan = try fixture.compile(a, io, image.reader());
    const verifier: execution.Verifier = .{ .context = &fixture.IDENTITY, .check = fixture.verify };
    try std.testing.expectError(error.TransactionTargetMismatch, submit(a, io, image.backend(), directory, plan, verifier, null));
    try fixture.assertBaseline(io, image.reader(), false);
    try std.testing.expectError(error.FileNotFound, directory.openFile(io, "program", .{}));
    var allowed = image.backend();
    allowed.physical_write_authorized = true;
    try std.testing.expectError(error.InjectedExecutionInterruption, submit(a, io, allowed, directory, plan, verifier, .validated));
    try std.testing.expectError(error.TransactionTargetMismatch, executor.recover(io, image.backend(), directory, .{}, null));
    image.target.kind = .private_image;
    try std.testing.expectError(error.TransactionTargetMismatch, executor.recover(io, image.backend(), directory, .{}, null));
    image.target.kind = .physical_device;
    try std.testing.expectEqual(.rolled_back, try executor.recover(io, allowed, directory, .{}, null));
    try fixture.assertBaseline(io, image.reader(), false);
    try std.testing.expectEqual(.rolled_back, try executor.recover(io, allowed, directory, .{}, null));
}
test "durable block fixtures recover in a fresh process context and survive restoration interruption" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const stats = try fixture.run(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(9, stats.transactions);
    try std.testing.expectEqual(1, stats.unprepared);
    try std.testing.expectEqual(6, stats.rolled_back);
    try std.testing.expectEqual(2, stats.committed);
    try std.testing.expectEqual(1, stats.interrupted_restore);
}
test "recovery rejects corrupt programs and changed identities before writing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-corrupt-program-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var directory = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer directory.close(io);
    var image = try Image.open(io, try fixture.create(a, io, home), fixture.IDENTITY, 512);
    defer image.close(io);
    const plan = try fixture.compile(a, io, image.reader());
    image.tear_write_at = 0;
    try std.testing.expectError(error.InjectedPartialMetadata, submit(a, io, image.backend(), directory, plan, null, null));
    var before: [1024]u8 = undefined;
    try image.reader().readInto(io, 0, &before);
    image.target.identity[0] ^= 1;
    try std.testing.expectError(error.TransactionTargetMismatch, executor.recover(io, image.backend(), directory, .{}, null));
    image.target.identity[0] ^= 1;
    const log = try directory.openFile(io, "program", .{ .mode = .read_write });
    defer log.close(io);
    try log.writePositionalAll(io, &.{0xff}, 160);
    try log.sync(io);
    try std.testing.expectError(error.StorageProgramChecksum, executor.recover(io, image.backend(), directory, .{}, null));
    var after: [1024]u8 = undefined;
    try image.reader().readInto(io, 0, &after);
    try std.testing.expectEqualSlices(u8, &before, &after);
}
test "device flush failures and changed geometry remain recoverable" {
    const Memory = struct {
        bytes: [1024]u8 = undefined,
        capacity: u64 = 1024,
        flushes: usize = 0,
        fn read(ctx: *const anyopaque, _: std.Io, offset: u64, bytes: []u8) !void {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            @memcpy(bytes, self.bytes[@intCast(offset)..][0..bytes.len]);
        }
        fn write(ctx: *anyopaque, _: std.Io, offset: u64, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.bytes[@intCast(offset)..][0..bytes.len], bytes);
        }
        fn flush(ctx: *anyopaque, _: std.Io) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.flushes += 1;
            if (self.flushes == 1) return error.InjectedDeviceFlush;
        }
        fn validate(ctx: *const anyopaque, _: std.Io, target: model.Target) !void {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (self.capacity != target.capacity) return error.DeviceSizeChanged;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-flush-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var directory = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer directory.close(io);
    var memory: Memory = .{};
    @memcpy(memory.bytes[0..512], &fixture.OLD_A);
    @memcpy(memory.bytes[512..], &fixture.OLD_B);
    const disk: device.Device = .{ .context = &memory, .target = .{ .identity = fixture.IDENTITY, .capacity = 1024, .sector_size = 512 }, .vtable = &.{ .reader = .{ .read = Memory.read }, .write = Memory.write, .flush = Memory.flush, .validate = Memory.validate } };
    const plan = try fixture.compile(a, io, disk.reader());
    try std.testing.expectError(error.InjectedDeviceFlush, submit(a, io, disk, directory, plan, null, null));
    try std.testing.expectEqualSlices(u8, &fixture.NEW_A, memory.bytes[0..512]);
    try std.testing.expectEqualSlices(u8, &fixture.OLD_B, memory.bytes[512..]);
    memory.capacity = 512;
    try std.testing.expectError(error.DeviceSizeChanged, executor.recover(io, disk, directory, .{}, null));
    memory.capacity = 1024;
    try std.testing.expectEqual(.rolled_back, try executor.recover(io, disk, directory, .{}, null));
    try fixture.assertBaseline(io, disk.reader(), false);
}

test "built-in registry refuses unrecognized media" {
    const Context = struct {
        fn read(_: *const anyopaque, _: std.Io, _: u64, bytes: []u8) !void {
            @memset(bytes, 0);
        }
    };
    const reader: device.Reader = .{ .context = &fixture.IDENTITY, .target = .{ .identity = fixture.IDENTITY, .capacity = 65536, .sector_size = 512 }, .vtable = &.{ .read = Context.read } };
    try std.testing.expectError(error.FilesystemUnavailable, storage.testing.executor.prepare(storage.filesystem.BUILTIN, std.testing.allocator, std.testing.io, reader, .{ .kind = .shrink, .target_bytes = 32768 }));
}

test "filesystem planning gates capabilities, dirty snapshots and mismatched output" {
    const State = struct {
        allocator: std.mem.Allocator = undefined,
        reader: device.Reader = undefined,
        support: model.Support = .planned,
        clean: bool = true,
        mismatch: bool = false,
        probe_match: bool = true,
        probes: u32 = 0,
        calls: u32 = 0,
        capabilities: [std.enums.values(model.Kind).len]model.Capability = undefined,
        fn probe(context: *const anyopaque, _: std.Io, _: device.Reader) !bool {
            const self: *@This() = @constCast(@as(*const @This(), @ptrCast(@alignCast(context))));
            self.probes += 1;
            return self.probe_match;
        }
        fn inspect(context: *const anyopaque, _: std.mem.Allocator, _: std.Io, reader: device.Reader) !model.Snapshot {
            const self: *const @This() = @ptrCast(@alignCast(context));
            return .{ .filesystem = .ext4, .target = reader.target, .generation = 0, .block_size = 4096, .filesystem_bytes = reader.target.capacity, .clean = self.clean };
        }
        fn changes(a: std.mem.Allocator, reader: device.Reader) !storage.mutation.MutationSet {
            const writes = try a.dupe(storage.mutation.Write, &.{
                .{ .range = .{ .offset = 0, .length = 512 }, .content = &fixture.NEW_A },
                .{ .range = .{ .offset = 512, .length = 512 }, .content = &fixture.NEW_B },
            });
            return .{ .target = reader.target, .writes = writes };
        }
        fn shrink(context: *const anyopaque, a: std.mem.Allocator, _: std.Io, reader: device.Reader, _: model.Snapshot, _: u64) !storage.mutation.MutationSet {
            const self: *@This() = @constCast(@as(*const @This(), @ptrCast(@alignCast(context))));
            self.calls += 1;
            var result = try changes(a, reader);
            if (self.mismatch) result.target.capacity -= 512;
            return result;
        }
        fn read(_: *const anyopaque, _: std.Io, offset: u64, bytes: []u8) !void {
            for (bytes, 0..) |*byte, index| {
                const at = offset + index;
                byte.* = if (at < 512) fixture.OLD_A[@intCast(at)] else if (at < 1024) fixture.OLD_B[@intCast(at - 512)] else 0;
            }
        }
        fn fsOpen(ctx: *const anyopaque, a: std.mem.Allocator, _: std.Io, reader: device.Reader, _: bool) !storage.semantic.Filesystem {
            const self: *@This() = @constCast(@as(*const @This(), @ptrCast(@alignCast(ctx))));
            self.allocator = a;
            self.reader = reader;
            return .{ .context = self, .vtable = &FS_OPS };
        }
        fn fsClose(_: *anyopaque) void {}
        fn fsInspect(ctx: *anyopaque) !model.Snapshot {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var result = try inspect(self, self.allocator, std.testing.io, self.reader);
            for (std.enums.values(model.Kind), &self.capabilities) |kind, *cap| cap.* = .{ .operation = kind, .support = self.support };
            result.capabilities = &self.capabilities;
            return result;
        }
        fn fsObject(_: *anyopaque, _: *storage.semantic.Cursor) !?storage.semantic.Object {
            return null;
        }
        fn fsUnit(_: *anyopaque, _: *storage.semantic.Cursor) !?storage.semantic.AllocationUnit {
            return null;
        }
        fn fsGeometry(ctx: *anyopaque, intent: storage.semantic.Intent) !storage.semantic.Geometry {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return .{ .bytes = if (intent.bytes == 0) self.reader.target.capacity else intent.bytes, .allocation_size = 512, .private = ctx };
        }
        fn fsRequirements(_: *anyopaque, _: storage.semantic.Intent, _: storage.semantic.Geometry, _: []const storage.semantic.Placement) !storage.semantic.Requirements {
            return .{ .units = &.{} };
        }
        fn fsEncode(ctx: *anyopaque, intent: storage.semantic.Intent, _: storage.semantic.Geometry, _: []const storage.semantic.Placement) !storage.mutation.MutationSet {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (intent.operation == .create) return changes(self.allocator, self.reader);
            return shrink(self, self.allocator, std.testing.io, self.reader, try fsInspect(ctx), intent.bytes);
        }
        fn fsCheck(_: *anyopaque) !model.Check {
            return .{ .consistent = true, .detail = "fake semantic driver" };
        }
        fn fsVerify(_: *anyopaque, _: storage.semantic.Intent, _: device.Reader) !model.Check {
            return .{ .consistent = true, .detail = "fake semantic driver" };
        }
        const FS_OPS: storage.semantic.FilesystemOps = .{ .close = fsClose, .inspect = fsInspect, .enumerate_objects = fsObject, .enumerate_allocations = fsUnit, .describe_geometry = fsGeometry, .requirements = fsRequirements, .encode_changes = fsEncode, .check = fsCheck, .verify = fsVerify };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{};
    const driver: storage.semantic.Driver = .{ .filesystem = .ext4, .context = &state, .operations = &storage.ext.OPERATIONS, .vtable = &.{ .probe = State.probe, .open = State.fsOpen } };
    const registry: storage.filesystem.Registry = .{ .drivers = &.{driver} };
    const reader: device.Reader = .{ .context = &state, .target = .{ .identity = fixture.IDENTITY, .capacity = 65536, .sector_size = 512 }, .vtable = &.{ .read = State.read } };
    const operation: storage.testing.executor.Action = .{ .kind = .shrink, .target_bytes = 32768 };
    var wrong_driver = driver;
    wrong_driver.filesystem = .ntfs;
    try std.testing.expectError(error.FilesystemIdentityMismatch, wrong_driver.open(arena.allocator(), std.testing.io, reader, false));
    try std.testing.expectError(error.NativeOperationUnavailable, storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, operation));
    try std.testing.expectEqual(0, state.calls);
    state.support = .validated;
    state.clean = false;
    try std.testing.expectError(error.UncleanFilesystem, storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, operation));
    try std.testing.expectEqual(0, state.calls);
    state.clean = true;
    _ = try storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, operation);
    try std.testing.expectEqual(1, state.calls);
    state.mismatch = true;
    try std.testing.expectError(error.FilesystemProgramMismatch, storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, operation));
    state.mismatch = false;
    state.probe_match = false;
    try std.testing.expectError(error.FilesystemUnavailable, storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, operation));
    const probes = state.probes;
    state.clean = false;
    const created = try storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, .{ .kind = .create, .filesystem = .ext4 });
    try std.testing.expectEqual(model.Filesystem.ext4, created.checks[0].driver.filesystem);
    try std.testing.expectEqual(probes, state.probes);
    try std.testing.expectError(error.FilesystemUnavailable, storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, .{ .kind = .create, .filesystem = .vfat }));
    try std.testing.expectError(error.ReadOnlyOperationHasNoMutationPlan, storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, .{ .kind = .query }));
    try std.testing.expectError(error.ReadOnlyOperationHasNoMutationPlan, storage.testing.executor.prepare(registry, arena.allocator(), std.testing.io, reader, .{ .kind = .check }));
    try std.testing.expectEqual(probes, state.probes);
    state.probe_match = true;
    const ambiguous: storage.filesystem.Registry = .{ .drivers = &.{ driver, driver } };
    try std.testing.expectError(error.AmbiguousFilesystem, ambiguous.detect(std.testing.io, reader));
    try std.testing.expectError(error.AmbiguousFilesystem, storage.testing.executor.prepare(ambiguous, arena.allocator(), std.testing.io, reader, operation));
    try std.testing.expectError(error.DuplicateFilesystemDriver, storage.testing.executor.prepare(ambiguous, arena.allocator(), std.testing.io, reader, .{ .kind = .create, .filesystem = .ext4 }));
}

test "staging captures original partial sectors and rejects stale reads outside its writes" {
    const Builder = storage.mutation.Builder;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-staging-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const path = try fixture.create(a, io, home);
    var image = try Image.open(io, path, fixture.IDENTITY, 512);
    defer image.close(io);
    var directory = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer directory.close(io);
    var overlay = Builder.init(a, image.reader());
    defer overlay.deinit();
    var before: [1536]u8 = undefined;
    try image.reader().readInto(io, 0, &before);
    var consumed: [512]u8 = undefined;
    try overlay.reader().readInto(io, 1024, &consumed);
    try overlay.stageWrite(io, 7, "partial");
    var staged: [512]u8 = undefined;
    try overlay.reader().readInto(io, 0, &staged);
    try std.testing.expectEqualSlices(u8, before[0..7], staged[0..7]);
    try std.testing.expectEqualStrings("partial", staged[7..14]);
    try std.testing.expectEqualSlices(u8, before[14..512], staged[14..]);
    // Relocation may read a source after another staged move overwrote it.
    // Both a cached sector and a newly cached sector must retain their source
    // versions across partial writes crossing a sector boundary.
    try overlay.stageWrite(io, 500, &@as([32]u8, @splat(0xa5)));
    var source: [600]u8 = undefined;
    try overlay.originalReader().readInto(io, 7, &source);
    try std.testing.expectEqualSlices(u8, before[7..607], &source);
    var relocated: [32]u8 = undefined;
    try overlay.reader().readInto(io, 500, &relocated);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xa5)), &relocated);
    const changes = try overlay.finish(io, false);
    var builder = storage.program.Builder.init(a, image.reader());
    try builder.apply(io, 0, changes, false);
    const plan = try builder.finish();
    var original: [1536]u8 = undefined;
    try image.reader().readInto(io, 0, &original);
    try std.testing.expectEqualSlices(u8, &before, &original);
    // The library used this input but never wrote it; patch-only preconditions
    // would miss the change and could commit a plan calculated from stale data.
    try image.file.writePositionalAll(io, &.{consumed[0] ^ 1}, 1024);
    try std.testing.expectError(error.PlanningReadChanged, submit(a, io, image.backend(), directory, plan, null, null));
    try std.testing.expectError(error.FileNotFound, directory.openFile(io, "program", .{}));
    var after: [512]u8 = undefined;
    try image.reader().readInto(io, 0, &after);
    try std.testing.expectEqualSlices(u8, before[0..512], &after);
    // Resource exhaustion also remains entirely inside the temporary overlay.
    overlay.max_cached_bytes = 1024;
    try std.testing.expectError(error.StorageReadSetTooLarge, overlay.stageWrite(io, 2048, "denied"));
}

test {
    _ = @import("crash_tests.zig");
}
