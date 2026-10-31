//! Cooperative simulated executor. One caller owns its writer and advances it.
const std = @import("std");
const proto = @import("proto");
const journal = @import("journal");
const tui = @import("execution_tui");
pub const STEP_COUNT = 20;
pub const Options = struct {
    console: bool = true,
    delay_ms: u32 = 250,
    fail_step: ?u32 = null,
    hang_step: ?u32 = null,
    fsync_fail_step: ?u32 = null,
    short_write_step: ?u32 = null,

    pub fn validate(self: Options) !void {
        if (self.delay_ms > 60000) return error.InvalidStepDelay;
        for ([_]?u32{ self.fail_step, self.hang_step, self.fsync_fail_step, self.short_write_step }) |value| if (value) |n| {
            if (n == 0 or n > STEP_COUNT) return error.InvalidFaultStep;
        };
    }
};

pub const validate = proto.validatePlan;

pub const Executor = struct {
    writer: journal.Writer,
    plan: proto.Plan,
    boundary: journal.Boundary,
    options: Options,
    status: proto.wire.ExecutionStatus = .running,
    message: []const u8 = "Simulated execution started",
    index: usize = 0,
    pending: bool = false,
    deadline_ns: u64 = 0,
    committed: u32 = 0,
    started: u32 = 0,
    revision: u64 = 1,

    /// The application validates the selected persistent home before calling.
    /// Exclusive creation refuses every existing journal, including clean ones.
    pub fn start(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, plan: proto.Plan, boundary: journal.Boundary, now: u64, options: Options) !Executor {
        try validate(plan);
        try options.validate();
        if (!std.mem.eql(u8, plan.id, boundary.plan_id)) return error.JournalPlanMismatch;
        const writer = try journal.Writer.create(a, io, directory, boundary, now, .{
            .fsync_at = if (options.fsync_fail_step) |n| @as(u64, n) * 2 else null,
            .short_write_at = if (options.short_write_step) |n| @as(u64, n) * 2 else null,
        });
        if (options.console) tui.state(io, .running, 0, STEP_COUNT, "simulated plan; no disk operations");
        return .{ .writer = writer, .plan = plan, .boundary = boundary, .options = options };
    }
    pub fn close(self: *Executor, io: std.Io) void {
        self.writer.close(io);
    }
    pub fn terminal(self: *const Executor) bool {
        return self.status != .running and self.status != .hung;
    }
    pub fn view(self: *const Executor) proto.wire.Execution {
        return .{ .status = self.status, .step_id = if (self.index < self.plan.steps.len) self.plan.steps[self.index].id else 0, .committed = self.committed, .total = STEP_COUNT, .message = self.message };
    }

    /// At most one journal transition per tick. Delays and injected hangs never
    /// block the UI loop. Every error stops this executor permanently.
    pub fn tick(self: *Executor, io: std.Io, now: u64) !void {
        if (self.status != .running) return;
        self.advance(io, now) catch |err| {
            self.status = .degraded;
            self.message = @errorName(err);
            self.revision += 1;
            if (self.options.console) tui.state(io, self.status, self.committed, STEP_COUNT, self.message);
            return err;
        };
    }
    fn advance(self: *Executor, io: std.Io, now: u64) !void {
        if (self.index == self.plan.steps.len) {
            var end = self.boundary;
            end.state = .complete;
            _ = try self.writer.boundaryRecord(io, end, now);
            self.status = .succeeded;
            self.message = "All simulated steps completed";
            self.revision += 1;
            if (self.options.console) tui.state(io, self.status, self.committed, STEP_COUNT, self.message);
            return;
        }
        const step = self.plan.steps[self.index];
        const ordinal: u32 = @intCast(self.index + 1);
        if (!self.pending) {
            _ = try self.writer.intent(io, step.id, now, step.label);
            if (self.options.console) tui.event(io, .intent, ordinal, STEP_COUNT, step.label);
            // This is the only entry to simulated work, after durable intent.
            self.started += 1;
            self.pending = true;
            self.deadline_ns = now + @as(u64, self.options.delay_ms) * std.time.ns_per_ms;
            self.message = step.label;
            if (self.options.hang_step == ordinal) {
                self.status = .hung;
                self.message = "Injected hang; intent remains in flight";
                if (self.options.console) tui.state(io, self.status, self.committed, STEP_COUNT, self.message);
            }
        } else {
            if (now < self.deadline_ns) return;
            if (self.options.fail_step == ordinal) {
                _ = try self.writer.fail(io, step.id, now, "Injected simulated failure");
                if (self.options.console) tui.event(io, .fail, ordinal, STEP_COUNT, step.label);
                self.status = .failed;
                self.message = "Simulated step failed; plan stopped";
                if (self.options.console) tui.state(io, self.status, self.committed, STEP_COUNT, self.message);
            } else {
                _ = try self.writer.commit(io, step.id, now, step.label);
                if (self.options.console) tui.event(io, .commit, ordinal, STEP_COUNT, step.label);
                self.committed += 1;
                self.index += 1;
                self.pending = false;
            }
        }
        self.revision += 1;
    }
};

test "executor durability gate, stop boundaries and recovery never retry uncertain work" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const steps = try a.alloc(proto.wire.Step, STEP_COUNT);
    for (steps, 0..) |*step, i| step.* = .{ .id = @intCast(i + 1), .label = "simulated", .simulated = true };
    const plan: proto.Plan = .{ .id = "executor_test", .version = proto.API_VERSION, .steps = steps };
    const cases = [_]Options{ .{ .delay_ms = 0 }, .{ .delay_ms = 0, .fail_step = 8 }, .{ .delay_ms = 0, .hang_step = 8 }, .{ .delay_ms = 0, .fsync_fail_step = 8 }, .{ .delay_ms = 0, .short_write_step = 8 } };
    for (cases, 0..) |options, case| {
        const root = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-executor-unit-");
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
        defer dir.close(io);
        const boundary: journal.Boundary = .{ .state = .start, .boot_id = "00000000-0000-0000-0000-000000000001", .plan_id = plan.id, .utc_unix_ns = "1792400000000000000", .home = .{ .kind = .other_device, .path = root } };
        var executor = try Executor.start(a, io, dir, plan, boundary, 100, options);
        for (0..100) |n| executor.tick(io, 101 + n) catch {};
        const snapshot = try executor.writer.snapshot(a, io);
        try std.testing.expectEqual(.clean, snapshot.tail);
        try std.testing.expectEqual(@as(u32, if (case == 0) 20 else 7), executor.committed);
        try std.testing.expectEqual(@as(u32, if (case == 0) 20 else if (case <= 2) 8 else 7), executor.started);
        try std.testing.expectEqual(([_]proto.wire.ExecutionStatus{ .succeeded, .failed, .hung, .degraded, .degraded })[case], executor.status);
        if (case == 0) {
            try std.testing.expect(snapshot.state.complete);
            try std.testing.expectEqual(42, snapshot.records.len);
        } else if (case == 1) {
            try std.testing.expectEqual(.failed, snapshot.state.steps.get(8).?.state);
        } else if (case == 2) {
            try std.testing.expectEqual(.in_flight, snapshot.state.steps.get(8).?.state);
        } else {
            try std.testing.expect(!snapshot.state.steps.contains(8));
            try std.testing.expectEqual(.degraded, executor.writer.durability);
        }
        try std.testing.expect(!snapshot.state.steps.contains(9) or case == 0);
        const size = (try executor.writer.file.stat(io)).size;
        for (0..10) |n| try executor.tick(io, 1000 + n);
        try std.testing.expectEqual(size, (try executor.writer.file.stat(io)).size);
        executor.close(io);
        const path = try std.fs.path.join(a, &.{ root, "journal.bin" });
        const before = try @import("utils").filesystem.hashFileSha256(a, io, path);
        try std.testing.expectError(error.PathAlreadyExists, Executor.start(a, io, dir, plan, boundary, 1000, options));
        try std.testing.expectEqualStrings(before, try @import("utils").filesystem.hashFileSha256(a, io, path));
        const recovered = try journal.readFile(a, io, path);
        if (case == 3) try std.testing.expectEqual(.in_flight, recovered.state.steps.get(8).?.state);
        if (case == 4) try std.testing.expectEqual(.short_header, recovered.tail);
    }
}
