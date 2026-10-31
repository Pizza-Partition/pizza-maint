//! Contracts between format mutation descriptions, device views and recovery.
const std = @import("std");
const storage = @import("storage");
const model = storage.model;
const IO = std.testing.io;
const IDENTITY: model.Digest = @splat(0x35);
const TARGET: model.Target = .{ .identity = IDENTITY, .capacity = 8192, .sector_size = 512 };

const Disk = struct {
    bytes: [8192]u8 = @splat(0x17),
    reads: usize = 0,
    writes: usize = 0,
    fail_read: bool = false,
    fn backend(self: *@This()) storage.device.Device {
        return .{ .context = self, .target = TARGET, .vtable = &.{ .reader = .{ .read = read }, .write = write, .flush = flush, .validate = validate } };
    }
    fn read(raw: *const anyopaque, _: std.Io, offset: u64, bytes: []u8) !void {
        const self: *@This() = @constCast(@as(*const @This(), @ptrCast(@alignCast(raw))));
        self.reads += 1;
        if (self.fail_read) return error.InjectedReadFailure;
        @memcpy(bytes, self.bytes[@intCast(offset)..][0..bytes.len]);
    }
    fn write(raw: *anyopaque, _: std.Io, offset: u64, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.writes += 1;
        @memcpy(self.bytes[@intCast(offset)..][0..bytes.len], bytes);
    }
    fn flush(_: *anyopaque, _: std.Io) !void {}
    fn validate(_: *const anyopaque, _: std.Io, actual: model.Target) !void {
        if (!actual.same(TARGET)) return error.TransactionTargetMismatch;
    }
};

test "mutation compiler freezes backend bytes without writing and enforces preservation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var disk: Disk = .{};
    var content: [512]u8 = @splat(0x29);
    const writes = [_]storage.mutation.Write{.{ .range = .{ .offset = 512, .length = 512 }, .content = &content }};
    const changes: storage.mutation.MutationSet = .{ .target = TARGET, .writes = &writes };
    var builder = storage.program.Builder.init(a, disk.backend().reader());
    try builder.apply(IO, 0, changes, false);
    const plan = try builder.finish();
    @memset(&content, 0x8a);
    try std.testing.expectEqualSlices(u8, &@as([512]u8, @splat(0x29)), plan.steps[0].operation.write.content);
    try std.testing.expectEqualSlices(u8, &model.digest(disk.bytes[512..1024]), &plan.guards[0].expected);
    try std.testing.expectEqual(0, disk.writes);
    var discard = writes;
    discard[0].kind = .discard;
    try std.testing.expectError(error.UnauthorizedDataDiscard, builder.apply(IO, 0, .{ .target = TARGET, .writes = &discard }, false));
    var malformed = writes;
    malformed[0].range.length = 1024;
    try std.testing.expectError(error.WriteLengthMismatch, builder.apply(IO, 0, .{ .target = TARGET, .writes = &malformed }, false));
    var merged = storage.program.Builder.init(a, disk.backend().reader());
    try merged.apply(IO, 0, .{ .target = TARGET, .writes = &.{ writes[0], writes[0] } }, false);
    try std.testing.expectEqual(1, (try merged.finish()).steps.len);
    try std.testing.expectEqual(0, disk.writes);
}

test "owned partition reads are bounded and nested aliases are detected" {
    var disk: Disk = .{};
    var left = try storage.partition.Partition.init(disk.backend(), .{ .offset = 512, .length = 4096 }, @splat(1));
    var right = try storage.partition.Partition.init(disk.backend(), .{ .offset = 4608, .length = 3584 }, @splat(2));
    var nested = try storage.partition.Partition.init(left.device(), .{ .offset = 512, .length = 1024 }, @splat(3));
    try std.testing.expect(left.reader().aliases(nested.reader()));
    try std.testing.expect(disk.backend().reader().aliases(right.reader()));
    try std.testing.expect(!left.reader().aliases(right.reader()));
    try std.testing.expectEqual(1024, nested.reader().location().range.offset);
    const change = try left.setSize(2048);
    try std.testing.expectEqual(4096, left.range.length);
    try std.testing.expectEqual(2048, change.range.length);
    var builder = storage.program.Builder.init(std.testing.allocator, nested.reader());
    var view: storage.program.Builder.View = .{ .builder = &builder, .version = 0, .range = .{ .offset = 512, .length = 512 } };
    try std.testing.expectEqual(1536, view.reader().location().range.offset);
    try std.testing.expect(view.reader().aliases(disk.backend().reader()));

    const bytes = try left.read(std.testing.allocator, IO, .{ .offset = 7, .length = 32 });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, disk.bytes[519..551], bytes);
    const count = disk.reads;
    try std.testing.expectError(error.RangeOutsideDevice, left.read(std.testing.allocator, IO, .{ .offset = 4095, .length = 2 }));
    try std.testing.expectEqual(count, disk.reads);
    try nested.device().write(IO, .{ .offset = 0, .length = 512 }, &@as([512]u8, @splat(0x46)));
    try std.testing.expectEqualSlices(u8, &@as([512]u8, @splat(0x46)), disk.bytes[1024..1536]);
    try std.testing.expectEqual(0x17, disk.bytes[1023]);
    try std.testing.expectEqual(0x17, disk.bytes[1536]);
    var physical = disk.backend();
    physical.target.kind = .physical_device;
    var protected = try storage.partition.Partition.init(physical, .{ .offset = 0, .length = 4096 }, @splat(9));
    try std.testing.expectError(error.TransactionTargetMismatch, protected.device().authorizeMutation());
    try std.testing.expectError(error.TransactionTargetMismatch, protected.device().write(IO, .{ .offset = 0, .length = 512 }, &@as([512]u8, @splat(0))));
    disk.fail_read = true;
    try std.testing.expectError(error.InjectedReadFailure, left.read(std.testing.allocator, IO, .{ .offset = 0, .length = 512 }));
    disk.fail_read = false;
    left.range.offset += 512;
    try std.testing.expectError(error.TransactionTargetMismatch, left.read(std.testing.allocator, IO, .{ .offset = 0, .length = 512 }));
}

test "direct mutations restore the post-move baseline before reversing relocation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var baseline: [8192]u8 = @splat(0);
    @memset(baseline[0..512], 0x34);
    var machine = try storage.testing.crash_model.Machine.init(a, TARGET, &baseline);
    var builder = storage.program.Builder.init(a, machine.disk().reader());
    try builder.move(IO, 0, .{ .offset = 0, .length = 512 }, 2048);
    try builder.write(IO, .{ .offset = 2048, .length = 512 }, &@as([512]u8, @splat(0xaa)), false);
    const program = try builder.finish();
    try std.testing.expectError(error.InjectedExecutionInterruption, storage.testing.executor.runProgram(a, IO, machine.disk(), machine.store(), program, &.{}, null, .validated));
    try machine.powerLoss(71, .tear);
    try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.program_executor.recover(a, IO, machine.disk(), machine.store(), null));
    const restored = try machine.disk().read(a, IO, .{ .offset = 0, .length = 512 });
    try std.testing.expectEqualSlices(u8, baseline[0..512], restored);
    try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.program_executor.recover(a, IO, machine.disk(), machine.store(), null));
}

test "placement preserves original reservations and rejects exhausted or invalid geometry" {
    var space = try storage.space.Space.init(std.testing.allocator, .{ .offset = 512, .length = 4096 });
    defer space.deinit();
    try space.exclude(.{ .offset = 0, .length = 1024 });
    try space.exclude(.{ .offset = 3072, .length = 4096 });
    const first = try space.allocate(512, 1024);
    try std.testing.expectEqual(1024, first.offset);
    const second = try space.allocate(1024, 1024);
    try std.testing.expectEqual(2048, second.offset);
    try std.testing.expectError(error.NoPlacementSpace, space.allocate(1024, 512));
    try std.testing.expectError(error.InvalidAllocationAlignment, space.allocate(512, 3));
    try std.testing.expectError(error.EmptyAllocation, space.allocate(0, 512));
}

test "physical compiler rejects mutations for a different device or partition view" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var disk: Disk = .{};
    var builder = storage.program.Builder.init(arena.allocator(), disk.backend().reader());
    var other = TARGET;
    other.identity = @splat(0x94);
    try std.testing.expectError(error.FilesystemProgramMismatch, builder.apply(IO, 0, .{ .target = other }, false));
    var left: storage.program.Builder.View = .{ .builder = &builder, .version = 0, .range = .{ .offset = 512, .length = 2048 } };
    var right: storage.program.Builder.View = .{ .builder = &builder, .version = 0, .range = .{ .offset = 4096, .length = 2048 } };
    try std.testing.expect(!left.reader().target.same(right.reader().target));
    try std.testing.expectError(error.FilesystemProgramMismatch, builder.apply(IO, 4096, .{ .target = left.reader().target }, false));
}

test "record relocation views preserve original provenance across overlapping mappings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var disk: Disk = .{};
    @memset(disk.bytes[0..512], 0x31);
    @memset(disk.bytes[512..1024], 0x52);
    var records = storage.mutation.Builder.init(a, disk.backend().reader());
    defer records.deinit();
    try records.mapRelocation(IO, 0, 512, 512);
    try records.mapRelocation(IO, 512, 1024, 512);
    var bytes: [512]u8 = undefined;
    try records.reader().readInto(IO, 512, &bytes);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0x31));
    try records.reader().readInto(IO, 1024, &bytes);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0x52));
    try records.stageWrite(IO, 1031, "record");
    const changes = try records.finish(IO, false);
    try std.testing.expectEqual(1, changes.writes.len);
    try std.testing.expectEqual(1024, changes.writes[0].range.offset);
    try std.testing.expectEqualStrings("record", changes.writes[0].content[7..13]);
    try std.testing.expect(std.mem.allEqual(u8, changes.writes[0].content[13..], 0x52));
    try std.testing.expectEqual(0, disk.writes);
}
