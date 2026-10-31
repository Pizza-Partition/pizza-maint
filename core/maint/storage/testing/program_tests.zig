const std = @import("std");
const storage = @import("storage");
const IO = std.testing.io;
const Machine = storage.testing.crash_model.Machine;
const model = storage.model;
const BASELINE = init: {
    var bytes: [8192]u8 = @splat(0x31);
    @memset(bytes[512..1024], 0x52);
    break :init bytes;
};
const TARGET: model.Target = .{ .identity = @splat(0x69), .capacity = BASELINE.len, .sector_size = 512 };
const UPDATED: [512]u8 = @splat(0x87);
fn program(a: std.mem.Allocator, machine: *Machine) !storage.program.Program {
    var b = storage.program.Builder.init(a, machine.disk().reader());
    try b.write(IO, .{ .offset = 0, .length = 512 }, &UPDATED, false);
    // Version 0 remains accessible after an earlier write and a cyclic swap.
    const original_a = try b.save(IO, 0, .{ .offset = 0, .length = 512 });
    const original_b = try b.save(IO, 0, .{ .offset = 512, .length = 512 });
    try b.restore(original_b, 0);
    try b.restore(original_a, 512);
    try b.move(IO, 1, .{ .offset = 0, .length = 512 }, 1024);
    try b.barrier();
    return b.finish();
}
const EXPECTED = init: {
    var bytes = BASELINE;
    @memset(bytes[0..512], 0x52);
    @memset(bytes[512..1024], 0x31);
    @memset(bytes[1024..1536], 0x87);
    break :init bytes;
};
test "versioned program executes historical sources, cyclic moves, and immutable codec" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try Machine.init(a, TARGET, &BASELINE);
    const p = try program(a, &m);
    const decoded = try storage.program.decode(a, p.encoded);
    try std.testing.expectEqualSlices(u8, &p.digest, &decoded.digest);
    try storage.program_executor.execute(a, IO, m.disk(), m.store(), decoded, null, null);
    try std.testing.expectEqualSlices(u8, &EXPECTED, m.live);
    try m.powerLoss(23, .garbage);
    try std.testing.expectEqual(.committed, try storage.program_executor.recover(a, IO, m.disk(), m.store(), null));
    try std.testing.expectEqualSlices(u8, &EXPECTED, m.live);
    const corrupt = try a.dupe(u8, p.encoded);
    corrupt[48] ^= 1;
    try std.testing.expectError(error.StorageProgramChecksum, storage.program.decode(a, corrupt));
}
test "versioned program rolls back every execution durability boundary" {
    var count_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer count_arena.deinit();
    const count_a = count_arena.allocator();
    var count = try Machine.init(count_a, TARGET, &BASELINE);
    const p = try program(count_a, &count);
    count.arm(null, .crash);
    try storage.program_executor.execute(count_a, IO, count.disk(), count.store(), p, null, null);
    const events = count.events;
    for (std.enums.values(storage.testing.crash_model.Fault)) |fault| for (std.enums.values(storage.testing.crash_model.Damage)) |damage| {
        for (1..events + 2) |event| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var m = try Machine.init(a, TARGET, &BASELINE);
            m.arm(event, fault);
            storage.program_executor.execute(a, IO, m.disk(), m.store(), p, null, null) catch |err| switch (err) {
                error.SimulatedPowerLoss, error.InputOutput, error.NoSpaceLeft => {},
                else => return err,
            };
            try m.powerLoss(event + 17, damage);
            const result = storage.program_executor.recover(a, IO, m.disk(), m.store(), null) catch |err| {
                std.debug.print("program recovery boundary={d}/{d} damage={t} error={t}\n", .{ event, events, damage, err });
                return err;
            };
            try std.testing.expectEqualSlices(u8, if (result == .committed) &EXPECTED else &BASELINE, m.live);
            try m.powerLoss(event + 31, damage);
            try std.testing.expectEqual(result, try storage.program_executor.recover(a, IO, m.disk(), m.store(), null));
        }
    };
}
test "versioned recovery survives every restore durability boundary" {
    var counting: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer counting.deinit();
    const a = counting.allocator();
    var count = try Machine.init(a, TARGET, &BASELINE);
    const p = try program(a, &count);
    // Start enough steps to require reversing data and metadata versions.
    const Reject = struct {
        fn check(_: *const anyopaque, _: std.Io, _: storage.device.Reader) !bool {
            return false;
        }
    };
    try std.testing.expectError(error.ProgramVerificationFailed, storage.program_executor.execute(a, IO, count.disk(), count.store(), p, .{ .context = &TARGET, .check = Reject.check }, null));
    try count.powerLoss(91, .garbage);
    count.arm(null, .crash);
    _ = try storage.program_executor.recover(a, IO, count.disk(), count.store(), null);
    const events = count.events;
    for (std.enums.values(storage.testing.crash_model.Damage)) |damage| for (1..events + 2) |event| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var machine = try Machine.init(scratch, TARGET, &BASELINE);
        const plan = try program(scratch, &machine);
        try std.testing.expectError(error.ProgramVerificationFailed, storage.program_executor.execute(scratch, IO, machine.disk(), machine.store(), plan, .{ .context = &TARGET, .check = Reject.check }, null));
        try machine.powerLoss(91, .garbage);
        machine.arm(event, .crash);
        _ = storage.program_executor.recover(scratch, IO, machine.disk(), machine.store(), null) catch |err| switch (err) {
            error.SimulatedPowerLoss => .unprepared,
            else => return err,
        };
        try machine.powerLoss(event + 47, damage);
        try std.testing.expectEqual(.rolled_back, try storage.program_executor.recover(scratch, IO, machine.disk(), machine.store(), null));
        try std.testing.expectEqualSlices(u8, &BASELINE, machine.live);
        try machine.powerLoss(event + 53, damage);
        try std.testing.expectEqual(.rolled_back, try storage.program_executor.recover(scratch, IO, machine.disk(), machine.store(), null));
    };
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
test "MBR layout edits preserve identity and boot code and reject logical partitions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: [8192]u8 = @splat(0);
    @memset(bytes[0..440], 0x61);
    put(u32, &bytes, 440, 0x5e14);
    put(u16, &bytes, 510, 0xaa55);
    bytes[450] = 0x83;
    put(u32, &bytes, 454, 1);
    put(u32, &bytes, 458, 5);
    bytes[466] = 0x07;
    put(u32, &bytes, 470, 6);
    put(u32, &bytes, 474, 5);
    var m = try Machine.init(a, TARGET, &bytes);
    const driver = storage.partition_table.BUILTIN;
    const layout = try driver.readLayout(a, IO, m.disk().reader());
    const entries = try a.dupe(storage.partition_table.Entry, layout.entries);
    entries[0].range.length = 8 * 512;
    entries[1].range = .{ .offset = 9 * 512, .length = 2 * 512 };
    const changes = try driver.encodeLayout(a, layout, entries);
    try std.testing.expectEqual(1, changes.writes.len);
    try std.testing.expectEqualSlices(u8, bytes[0..446], changes.writes[0].content[0..446]);
    var b = storage.program.Builder.init(a, m.disk().reader());
    try b.apply(IO, 0, changes, false);
    try storage.program_executor.execute(a, IO, m.disk(), m.store(), try b.finish(), null, null);
    const after = try driver.readLayout(a, IO, m.disk().reader());
    try std.testing.expectEqualSlices(u8, &layout.entries[1].id, &after.entries[1].id);
    try std.testing.expectEqual(entries[1].range, after.entries[1].range);
    entries[1].range.offset = 512;
    try std.testing.expectError(error.OverlappingPartitions, driver.validateLayout(layout, entries));
    m.live[450] = 0x0f;
    try std.testing.expectError(error.LogicalPartitionsUnsupported, driver.readLayout(a, IO, m.disk().reader()));
}
test "GPT updates both copies and detects CRC and mirror disagreement" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: [65536]u8 = @splat(0);
    put(u16, &bytes, 510, 0xaa55);
    bytes[450] = 0xee;
    put(u32, &bytes, 454, 1);
    put(u32, &bytes, 458, 127);
    const primary = bytes[1024 .. 1024 + 16384];
    for (0..2) |i| {
        const e = primary[i * 128 ..][0..128];
        @memset(e[0..16], 0x81);
        @memset(e[16..32], @intCast(i + 1));
        put(u64, e, 32, 34 + i * 20);
        put(u64, e, 40, 53 + i * 20);
    }
    @memcpy(bytes[95 * 512 .. 127 * 512], primary);
    for ([_]usize{ 1, 127 }) |lba| {
        const h = bytes[lba * 512 ..][0..512];
        @memcpy(h[0..8], "EFI PART");
        put(u32, h, 8, 0x10000);
        put(u32, h, 12, 92);
        put(u64, h, 24, lba);
        put(u64, h, 32, if (lba == 1) 127 else 1);
        put(u64, h, 40, 34);
        put(u64, h, 48, 94);
        @memset(h[56..72], 0x91);
        put(u64, h, 72, if (lba == 1) 2 else 95);
        put(u32, h, 80, 128);
        put(u32, h, 84, 128);
        put(u32, h, 88, std.hash.Crc32.hash(primary));
        put(u32, h, 16, std.hash.Crc32.hash(h[0..92]));
    }
    var t = TARGET;
    t.capacity = bytes.len;
    var m = try Machine.init(a, t, &bytes);
    const driver = storage.partition_table.BUILTIN;
    const layout = try driver.readLayout(a, IO, m.disk().reader());
    const entries = try a.dupe(storage.partition_table.Entry, layout.entries);
    entries[0].range.length = 30 * 512;
    entries[1].range = .{ .offset = 64 * 512, .length = 10 * 512 };
    const changes = try driver.encodeLayout(a, layout, entries);
    try std.testing.expectEqual(4, changes.writes.len);
    var b = storage.program.Builder.init(a, m.disk().reader());
    try b.apply(IO, 0, changes, false);
    const p = try b.finish();
    const Stop = struct {
        at: usize,
        fn event(ctx: *anyopaque, completed: usize, _: usize, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (completed == self.at) return error.GptInterrupted;
        }
    };
    for (1..p.steps.len + 1) |cut| for (std.enums.values(storage.testing.crash_model.Damage)) |damage| {
        var scenario: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scenario.deinit();
        const scratch = scenario.allocator();
        var machine = try Machine.init(scratch, m.target, &bytes);
        var stop: Stop = .{ .at = cut };
        try std.testing.expectError(error.GptInterrupted, storage.program_executor.execute(scratch, IO, machine.disk(), machine.store(), p, null, .{ .context = &stop, .event = Stop.event }));
        try machine.powerLoss(cut + 71, damage);
        try std.testing.expectEqual(.rolled_back, try storage.program_executor.recover(scratch, IO, machine.disk(), machine.store(), null));
        const restored = try driver.readLayout(scratch, IO, machine.disk().reader());
        try std.testing.expectEqualSlices(u8, &bytes, machine.live);
        try std.testing.expectEqual(layout.entries[0].range, restored.entries[0].range);
    };
    try storage.program_executor.execute(a, IO, m.disk(), m.store(), p, null, null);
    const after = try driver.readLayout(a, IO, m.disk().reader());
    try std.testing.expectEqual(entries[0].range, after.entries[0].range);
    try std.testing.expectEqual(entries[1].range, after.entries[1].range);
    m.live[1024 + 80] ^= 1;
    try std.testing.expectError(error.GptEntriesChecksum, driver.readLayout(a, IO, m.disk().reader()));
}

test "cancellation during undo streaming stops before destructive intent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try a.alloc(u8, 1024 * 1024);
    @memset(original, 0x31);
    const replacement = try a.alloc(u8, original.len);
    @memset(replacement, 0x92);
    var disk_target = TARGET;
    disk_target.capacity = original.len;
    var machine = try Machine.init(a, disk_target, original);
    var builder = storage.program.Builder.init(a, machine.disk().reader());
    try builder.write(IO, .{ .offset = 0, .length = original.len }, replacement, false);
    const plan = try builder.finish();
    const Stop = struct {
        fn event(_: *anyopaque, _: usize, _: usize, _: u64) !void {
            return error.MustCancelBeforeCompletion;
        }
        fn cancelled(ctx: *anyopaque) bool {
            const m: *Machine = @ptrCast(@alignCast(ctx));
            const snapshot = m.files[@backingInt(storage.recovery_store.Record.snapshots)].live;
            return m.files[@backingInt(storage.recovery_store.Record.ready)].visible and snapshot.len != 0 and snapshot[0] == 0x31;
        }
    };
    try std.testing.expectError(error.OperationCancelled, storage.program_executor.execute(a, IO, machine.disk(), machine.store(), plan, null, .{ .context = &machine, .event = Stop.event, .cancelled = Stop.cancelled }));
    try std.testing.expectEqualSlices(u8, original, machine.live);
    try std.testing.expectEqual(.rolled_back, try storage.program_executor.recover(a, IO, machine.disk(), machine.store(), null));
    try std.testing.expectEqualSlices(u8, original, machine.live);
}

test "corrupt confirmed step state cannot authorize any recovery writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var machine = try Machine.init(a, TARGET, &BASELINE);
    const plan = try program(a, &machine);
    try std.testing.expectError(error.InjectedExecutionInterruption, storage.testing.executor.runProgram(a, IO, machine.disk(), machine.store(), plan, &.{}, null, .validated));
    const before = try a.dupe(u8, machine.live);
    const state = &machine.files[@backingInt(storage.recovery_store.Record.state)];
    state.live[4096] ^= 1;
    try std.testing.expectError(error.InvalidProgramProgress, storage.program_executor.recover(a, IO, machine.disk(), machine.store(), null));
    try std.testing.expectEqualSlices(u8, before, machine.live);
}

test "deferred execution survives power loss and explicit undo preserves formatting beforeimages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try Machine.init(a, TARGET, &BASELINE);
    var b = storage.program.Builder.init(a, m.disk().reader());
    try b.write(IO, .{ .offset = 0, .length = 512 }, &UPDATED, true);
    const p = try b.finish();
    const deferred = try storage.program_executor.reservation(a, p, 4096, true);
    const immediate = try storage.program_executor.reservation(a, p, 4096, false);
    try std.testing.expect(deferred.snapshots > immediate.snapshots);
    try storage.program_executor.executeDeferred(a, IO, m.disk(), m.store(), p, &.{}, null, null);
    try std.testing.expectEqualSlices(u8, &UPDATED, m.live[0..512]);
    try m.powerLoss(17, .garbage);
    try std.testing.expectEqual(.verified, try storage.program_executor.recover(a, IO, m.disk(), m.store(), null));
    try std.testing.expectEqual(.rolled_back, try storage.program_executor.undo(a, IO, m.disk(), m.store(), null));
    try std.testing.expectEqualSlices(u8, &BASELINE, m.live);
    try m.powerLoss(31, .garbage);
    try std.testing.expectEqual(.rolled_back, try storage.program_executor.recover(a, IO, m.disk(), m.store(), null));
}

test "acceptance is durable and disallows undo; changed verified bytes fail closed" {
    for ([_]bool{ false, true }) |change| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var m = try Machine.init(a, TARGET, &BASELINE);
        const p = try program(a, &m);
        try storage.program_executor.executeDeferred(a, IO, m.disk(), m.store(), p, &.{}, null, null);
        if (change) {
            m.live[0] ^= 1;
            try std.testing.expectError(error.InvalidProgramMarker, storage.program_executor.accept(a, IO, m.disk(), m.store()));
            try std.testing.expectError(error.InvalidProgramMarker, storage.program_executor.undo(a, IO, m.disk(), m.store(), null));
        } else {
            try storage.program_executor.accept(a, IO, m.disk(), m.store());
            try storage.program_executor.accept(a, IO, m.disk(), m.store());
            try m.powerLoss(9, .garbage);
            try std.testing.expectEqual(.committed, try storage.program_executor.recover(a, IO, m.disk(), m.store(), null));
            try std.testing.expectError(error.TransactionAlreadyAccepted, storage.program_executor.undo(a, IO, m.disk(), m.store(), null));
            try std.testing.expectEqualSlices(u8, &EXPECTED, m.live);
        }
    }
}

test "deferred execution durability cuts leave original or verified reversible result" {
    var count_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer count_arena.deinit();
    const ca = count_arena.allocator();
    var count = try Machine.init(ca, TARGET, &BASELINE);
    const p = try program(ca, &count);
    count.arm(null, .crash);
    try storage.program_executor.executeDeferred(ca, IO, count.disk(), count.store(), p, &.{}, null, null);
    for (1..count.events + 2) |event| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var m = try Machine.init(a, TARGET, &BASELINE);
        m.arm(event, .crash);
        storage.program_executor.executeDeferred(a, IO, m.disk(), m.store(), p, &.{}, null, null) catch |err| switch (err) {
            error.SimulatedPowerLoss => {},
            else => return err,
        };
        try m.powerLoss(event, .garbage);
        const result = try storage.program_executor.recover(a, IO, m.disk(), m.store(), null);
        switch (result) {
            .verified => {
                try std.testing.expectEqualSlices(u8, &EXPECTED, m.live);
                _ = try storage.program_executor.undo(a, IO, m.disk(), m.store(), null);
            },
            .unprepared, .rolled_back => {},
            .committed => return error.PrematureAcceptance,
        }
        try std.testing.expectEqualSlices(u8, &BASELINE, m.live);
    }
}

test "explicit deferred undo is restartable at every durability cut" {
    var count_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer count_arena.deinit();
    const ca = count_arena.allocator();
    var count = try Machine.init(ca, TARGET, &BASELINE);
    const p = try program(ca, &count);
    try storage.program_executor.executeDeferred(ca, IO, count.disk(), count.store(), p, &.{}, null, null);
    count.arm(null, .crash);
    _ = try storage.program_executor.undo(ca, IO, count.disk(), count.store(), null);
    for (1..count.events + 2) |event| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var m = try Machine.init(a, TARGET, &BASELINE);
        try storage.program_executor.executeDeferred(a, IO, m.disk(), m.store(), p, &.{}, null, null);
        m.arm(event, .crash);
        _ = storage.program_executor.undo(a, IO, m.disk(), m.store(), null) catch |err| switch (err) {
            error.SimulatedPowerLoss => storage.program_executor.Result.unprepared,
            else => return err,
        };
        try m.powerLoss(event, .garbage);
        const result = try storage.program_executor.recover(a, IO, m.disk(), m.store(), null);
        if (result == .verified) _ = try storage.program_executor.undo(a, IO, m.disk(), m.store(), null) else try std.testing.expectEqual(.rolled_back, result);
        try std.testing.expectEqualSlices(u8, &BASELINE, m.live);
    }
}
