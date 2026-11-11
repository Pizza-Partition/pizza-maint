const std = @import("std");
const storage = @import("storage");
const ms = storage.recovery_session;
const Machine = storage.testing.crash_model.Machine;
const IO = std.testing.io;
const Fixture = struct {
    machine: *Machine,
    bundle: ms.Bundle,
    fn init(a: std.mem.Allocator, sector: u32) !Fixture {
        const bytes = try a.alloc(u8, 1024 * 1024);
        @memset(bytes, 0);
        const m = try a.create(Machine);
        m.* = try Machine.init(a, .{ .identity = @splat(0x67), .capacity = bytes.len, .sector_size = sector }, bytes);
        const content = try a.alloc(u8, sector);
        var boot = storage.program.PhysicalProgramBuilder.init(a, m.disk().reader());
        @memset(content, 0x11);
        try boot.write(IO, .{ .offset = 0, .length = sector }, content, false);
        // Preserve original source bytes that the future raw work-store header
        // will reuse. This exercises rollback of a predecessor whose completed
        // footprint has legitimately changed in the dependent phase.
        @memset(content, 0);
        try boot.write(IO, .{ .offset = 524288, .length = sector }, content, false);
        const bp = try boot.finish();
        @memset(m.live[0..sector], 0x11);
        var apply = storage.program.PhysicalProgramBuilder.init(a, m.disk().reader());
        @memset(content, 0x22);
        try apply.write(IO, .{ .offset = 0, .length = sector }, content, false);
        @memset(content, 0x44);
        try apply.write(IO, .{ .offset = 8192, .length = sector }, content, true);
        const ap = try apply.finish();
        @memset(m.live[0..sector], 0x22);
        @memset(m.live[8192..][0..sector], 0x44);
        var clean = storage.program.PhysicalProgramBuilder.init(a, m.disk().reader());
        @memset(content, 0x33);
        try clean.write(IO, .{ .offset = 0, .length = sector }, content, false);
        const cp = try clean.finish();
        @memset(m.live, 0);
        const id: storage.model.Digest = @splat(0x39);
        return .{ .machine = m, .bundle = .{
            .session = id,
            .control = .{ .offset = 32768, .length = 8192 },
            .bootstrap = bp,
            .apply = ap,
            .cleanup = cp,
            .bootstrap_store = .{ .session = id, .block_size = 4096, .extents = &.{.{ .offset = 65536, .length = 196608 }} },
            .apply_store = .{ .session = id, .block_size = 4096, .extents = &.{.{ .offset = 524288, .length = 196608 }} },
            .cleanup_store = .{ .session = id, .block_size = 4096, .extents = &.{.{ .offset = 786432, .length = 196608 }} },
        } };
    }
    fn prepare(self: Fixture, a: std.mem.Allocator) !ms.RecoverySession {
        return ms.RecoverySession.prepare(a, IO, self.machine.disk(), self.bundle);
    }
    fn reopen(self: Fixture, a: std.mem.Allocator) !ms.RecoverySession {
        return ms.RecoverySession.open(a, IO, self.machine.disk(), self.bundle);
    }
};

test "maintenance waits for explicit acceptance and undoes user changes before bootstrap" {
    for ([_]u32{ 512, 4096 }) |sector| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try Fixture.init(a, sector);
        var session = try f.prepare(a);
        try session.bootstrap(IO, null, null);
        try std.testing.expectEqual(.initialized, session.phase);
        try session.apply(IO, null, null);
        try std.testing.expectEqual(.verified, session.phase);
        try f.machine.powerLoss(1, .garbage);
        session = try f.reopen(a);
        try session.recover(IO);
        try std.testing.expectEqual(.verified, session.phase);
        try std.testing.expectError(error.InvalidSessionTransition, session.apply(IO, null, null));
        try session.undo(IO);
        try std.testing.expectEqual(.rolled_back, session.phase);
        try std.testing.expect(std.mem.allEqual(u8, f.machine.live[0..32768], 0));
    }
}
test "acceptance closes undo and cleanup reaches the exact final state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, 512);
    var session = try f.prepare(a);
    try session.bootstrap(IO, null, null);
    try session.apply(IO, null, null);
    try session.accept(IO);
    try std.testing.expectError(error.InvalidSessionTransition, session.undo(IO));
    try session.cleanup(IO, null, null);
    try f.machine.powerLoss(2, .tear);
    session = try f.reopen(a);
    try session.recover(IO);
    try std.testing.expectEqual(.completed, session.phase);
    try std.testing.expect(std.mem.allEqual(u8, f.machine.live[0..512], 0x33));
    try std.testing.expect(std.mem.allEqual(u8, f.machine.live[8192..8704], 0x44));
    var wrong = f.bundle;
    wrong.session = @splat(0x98);
    try std.testing.expectError(error.SessionIdentityMismatch, ms.RecoverySession.open(a, IO, f.machine.disk(), wrong));
}
fn failVerify(_: *const anyopaque, _: std.Io, _: storage.device.Reader) !bool {
    return false;
}
test "failed cleanup restores the accepted layout and stays in maintenance" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, 512);
    var session = try f.prepare(a);
    try session.bootstrap(IO, null, null);
    try session.apply(IO, null, null);
    try session.accept(IO);
    try std.testing.expectError(error.ProgramVerificationFailed, session.cleanup(IO, .{ .context = f.machine, .check = failVerify }, null));
    session = try f.reopen(a);
    try session.recover(IO);
    try std.testing.expectEqual(.failed_cleanup, session.phase);
    try std.testing.expect(std.mem.allEqual(u8, f.machine.live[0..512], 0x22));
    try std.testing.expectError(error.InvalidSessionTransition, session.undo(IO));
}
test "maintenance preflight rejects overlap and insufficient recovery before writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, 512);
    var bad = f.bundle;
    bad.apply_store.extents = f.bundle.bootstrap_store.extents;
    try std.testing.expectError(error.OverlappingSessionStorage, ms.RecoverySession.prepare(a, IO, f.machine.disk(), bad));
    bad = f.bundle;
    bad.cleanup_store.extents = &.{.{ .offset = 786432, .length = 8192 }};
    try std.testing.expectError(error.CapsuleTooSmall, ms.RecoverySession.prepare(a, IO, f.machine.disk(), bad));
    try std.testing.expect(std.mem.allEqual(u8, f.machine.live, 0));
}

const Action = enum { bootstrap, apply, undo, accept, cleanup };
fn stage(a: std.mem.Allocator, f: Fixture, action: Action) !ms.RecoverySession {
    var session = try f.prepare(a);
    if (action == .bootstrap) return session;
    try session.bootstrap(IO, null, null);
    if (action == .apply) return session;
    try session.apply(IO, null, null);
    if (action == .cleanup) try session.accept(IO);
    return session;
}
fn perform(session: *ms.RecoverySession, action: Action) !void {
    switch (action) {
        .bootstrap => try session.bootstrap(IO, null, null),
        .apply => try session.apply(IO, null, null),
        .undo => try session.undo(IO),
        .accept => try session.accept(IO),
        .cleanup => try session.cleanup(IO, null, null),
    }
}
test "maintenance recovers every durability cut without replaying requests" {
    for (std.enums.values(Action)) |action| {
        var measure: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer measure.deinit();
        const mf = try Fixture.init(measure.allocator(), 4096);
        var msess = try stage(measure.allocator(), mf, action);
        mf.machine.arm(null, .crash);
        try perform(&msess, action);
        const count = mf.machine.events;
        for (1..count + 1) |cut| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const f = try Fixture.init(a, 4096);
            var session = try stage(a, f, action);
            f.machine.arm(cut, .crash);
            perform(&session, action) catch |err| if (err != error.SimulatedPowerLoss) return err;
            try f.machine.powerLoss(cut, switch (cut % 4) {
                0 => .drop,
                1 => .tear,
                2 => .garbage,
                else => .reorder,
            });
            session = try f.reopen(a);
            try session.recover(IO);
            switch (session.phase) {
                .prepared, .failed_bootstrap, .rolled_back => {
                    try std.testing.expect(std.mem.allEqual(u8, f.machine.live[0..32768], 0));
                    try std.testing.expect(std.mem.allEqual(u8, f.machine.live[524288..][0..4096], 0));
                },
                .initialized => try std.testing.expect(std.mem.allEqual(u8, f.machine.live[0..4096], 0x11)),
                .verified, .accepted, .failed_cleanup => try std.testing.expect(std.mem.allEqual(u8, f.machine.live[0..4096], 0x22)),
                .completed => try std.testing.expect(std.mem.allEqual(u8, f.machine.live[0..4096], 0x33)),
                else => return error.UnfinishedSessionRecovery,
            }
            const sequence = session.sequence;
            try session.recover(IO);
            try std.testing.expectEqual(sequence, session.sequence);
        }
    }
}

test "preparation resumes every torn control and capsule initialization without erasing an existing transaction" {
    var measure: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer measure.deinit();
    const initial = try Fixture.init(measure.allocator(), 4096);
    initial.machine.arm(null, .crash);
    _ = try initial.prepare(measure.allocator());
    const count = initial.machine.events;
    for (1..count + 1) |cut| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try Fixture.init(a, 4096);
        f.machine.arm(cut, .crash);
        _ = f.prepare(a) catch |err| blk: {
            if (err != error.SimulatedPowerLoss) return err;
            break :blk null;
        };
        try f.machine.powerLoss(cut, switch (cut % 4) {
            0 => .drop,
            1 => .tear,
            2 => .garbage,
            else => .reorder,
        });
        var resumed = f.reopen(a) catch |err| blk: {
            if (err != error.InvalidSessionHeaders) return err;
            break :blk try f.prepare(a);
        };
        try resumed.recover(IO);
        try std.testing.expectEqual(.prepared, resumed.phase);
        try std.testing.expect(std.mem.allEqual(u8, f.machine.live[0..32768], 0));
        try resumed.bootstrap(IO, null, null);
        try resumed.apply(IO, null, null);
        try std.testing.expectEqual(.verified, resumed.phase);
        // Neither header being valid is never permission to erase existing logs.
        @memset(f.machine.live[32768..40960], 0xa5);
        try std.testing.expectError(error.InvalidSessionHeaders, f.prepare(a));
    }
}

test "failed cleanup retries only the cleanup transaction" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, 4096);
    var session = try f.prepare(a);
    try session.bootstrap(IO, null, null);
    try session.apply(IO, null, null);
    try session.accept(IO);
    var unused: u8 = 0;
    try std.testing.expectError(error.ProgramVerificationFailed, session.cleanup(IO, .{ .context = &unused, .check = failVerify }, null));
    try session.recover(IO);
    try std.testing.expectEqual(.failed_cleanup, session.phase);
    try session.cleanup(IO, null, null);
    try std.testing.expectEqual(.completed, session.phase);
}
