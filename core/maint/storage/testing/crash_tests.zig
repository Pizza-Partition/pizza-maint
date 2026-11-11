const std = @import("std");
const storage = @import("storage");
const model = storage.model;
const execution = storage.program_executor;
const fixture = storage.testing.fixture;
const simulator = storage.testing.crash_model;
const Machine = simulator.Machine;

const BASELINE = init: {
    var bytes: [64 * 1024]u8 = @splat(0x71);
    @memcpy(bytes[0..512], &fixture.OLD_A);
    @memcpy(bytes[512..1024], &fixture.OLD_B);
    break :init bytes;
};
const TARGET: model.Target = .{ .identity = fixture.IDENTITY, .capacity = BASELINE.len, .sector_size = 512 };
const REPLACEMENT: [2048]u8 = @splat(0x53);
const EXPECTED = init: {
    var bytes = BASELINE;
    @memcpy(bytes[0..512], &fixture.NEW_A);
    @memcpy(bytes[512..1024], &fixture.NEW_B);
    @memcpy(bytes[4096..6144], &REPLACEMENT);
    break :init bytes;
};
fn txn(a: std.mem.Allocator) !storage.program.Program {
    const Baseline = struct {
        fn read(_: *const anyopaque, _: std.Io, offset: u64, bytes: []u8) !void {
            @memcpy(bytes, BASELINE[@intCast(offset)..][0..bytes.len]);
        }
    };
    const reader: storage.device.Reader = .{ .context = &TARGET, .target = TARGET, .vtable = &.{ .read = Baseline.read } };
    var builder = storage.program.PhysicalProgramBuilder.init(a, reader);
    try builder.write(std.testing.io, .{ .offset = 0, .length = 512 }, &fixture.NEW_A, false);
    try builder.write(std.testing.io, .{ .offset = 512, .length = 512 }, &fixture.NEW_B, false);
    try builder.write(std.testing.io, .{ .offset = 4096, .length = 2048 }, &REPLACEMENT, false);
    return builder.finish();
}
fn verify(_: *const anyopaque, io: std.Io, reader: storage.device.Reader) !bool {
    var observed: [EXPECTED.len]u8 = undefined;
    try reader.readInto(io, 0, &observed);
    return std.mem.eql(u8, &EXPECTED, &observed);
}
const VERIFIER: execution.Verifier = .{ .context = &fixture.IDENTITY, .check = verify };
fn permitted(err: anyerror) !void {
    switch (err) {
        error.SimulatedPowerLoss, error.InputOutput, error.NoSpaceLeft => {},
        else => return err,
    }
}
fn assertRecovered(a: std.mem.Allocator, machine: *Machine) !void {
    const outcome = try execution.recover(a, std.testing.io, machine.disk(), machine.store(), null);
    try std.testing.expectEqualSlices(u8, if (outcome == .committed) &EXPECTED else &BASELINE, machine.live);
    // Power loss after recovery must preserve its result and durable marker.
    try machine.powerLoss(7001, .garbage);
    try std.testing.expectEqual(outcome, try execution.recover(a, std.testing.io, machine.disk(), machine.store(), null));
    try std.testing.expectEqualSlices(u8, if (outcome == .committed) &EXPECTED else &BASELINE, machine.live);
}

test "SQLite-style exhaustive I/O boundary crashes and one-shot or persistent I/O failures" {
    var count_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer count_arena.deinit();
    const count_a = count_arena.allocator();
    var complete = try Machine.init(count_a, TARGET, &BASELINE);
    try execution.execute(count_a, std.testing.io, complete.disk(), complete.store(), try txn(count_a), VERIFIER, null);
    const events = complete.events;
    var cases: usize = 0;
    var lost: usize = 0;
    var torn: usize = 0;
    var corrupted: usize = 0;
    var reordered: usize = 0;
    for (std.enums.values(simulator.Fault)) |fault| {
        for (std.enums.values(simulator.Damage)) |damage| {
            for (0..3) |seed| {
                for (1..events + 2) |at| {
                    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                    defer arena.deinit();
                    const a = arena.allocator();
                    var machine = try Machine.init(a, TARGET, &BASELINE);
                    machine.arm(at, fault);
                    execution.execute(a, std.testing.io, machine.disk(), machine.store(), try txn(a), VERIFIER, null) catch |err| try permitted(err);
                    try machine.powerLoss(seed + 1, damage);
                    lost += machine.lost;
                    torn += machine.torn;
                    corrupted += machine.corrupted;
                    reordered += machine.reordered;
                    assertRecovered(a, &machine) catch |err| {
                        std.debug.print("crash model fault={t} damage={t} seed={d} event={d}/{d}: {t}\n", .{ fault, damage, seed + 1, at, events, err });
                        return err;
                    };
                    cases += 1;
                }
            }
        }
    }
    try std.testing.expect(lost > 0 and torn > 0 and corrupted > 0 and reordered > 0);
    std.debug.print("SQLITE_STYLE_EXECUTE_OK events={d} cases={d} lost={d} torn={d} garbage={d} reordered={d}\n", .{ events, cases, lost, torn, corrupted, reordered });
}

fn interrupted(a: std.mem.Allocator) !Machine {
    var machine = try Machine.init(a, TARGET, &BASELINE);
    try std.testing.expectError(error.InjectedExecutionInterruption, storage.testing.executor.runProgram(a, std.testing.io, machine.disk(), machine.store(), try txn(a), &.{}, VERIFIER, .written));
    try machine.powerLoss(801, .garbage);
    return machine;
}

test "SQLite-style compound failures at every recovery I/O boundary" {
    var count_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer count_arena.deinit();
    const count_a = count_arena.allocator();
    var complete = try interrupted(count_a);
    _ = try execution.recover(count_a, std.testing.io, complete.disk(), complete.store(), null);
    const events = complete.events;
    var cases: usize = 0;
    for (std.enums.values(simulator.Fault)) |fault| {
        for (std.enums.values(simulator.Damage)) |damage| {
            for (0..3) |seed| {
                for (1..events + 2) |at| {
                    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                    defer arena.deinit();
                    const a = arena.allocator();
                    var machine = try interrupted(a);
                    machine.arm(at, fault);
                    _ = execution.recover(a, std.testing.io, machine.disk(), machine.store(), null) catch |err| blk: {
                        try permitted(err);
                        break :blk execution.Result.unprepared;
                    };
                    try machine.powerLoss(seed + 19, damage);
                    assertRecovered(a, &machine) catch |err| {
                        std.debug.print("recovery model fault={t} damage={t} seed={d} event={d}/{d}: {t}\n", .{ fault, damage, seed + 19, at, events, err });
                        return err;
                    };
                    cases += 1;
                }
            }
        }
    }
    std.debug.print("SQLITE_STYLE_RECOVERY_OK events={d} cases={d}\n", .{ events, cases });
}
