//! Maintenance business state and journal replay, independent of display.
const std = @import("std");
const proto = @import("proto");
const journal = @import("journal");
const plan_module = @import("executor.zig");

pub const Batch = struct { json: []const u8, last: u64, count: usize };
pub const Backend = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    plan: ?proto.Plan = null,
    journal_path: ?[]const u8 = null,
    snapshot: ?journal.Scan = null,
    observed_stat: ?std.Io.File.Stat = null,
    executor: ?*plan_module.Executor = null,
    observed_offset: ?u64 = null,
    cancelled: bool = false,
    journal_home: ?*@import("handoff").storage.Mounted = null,

    pub fn init(a: std.mem.Allocator, plan: ?proto.Plan, journal_path: ?[]const u8) Backend {
        return .{ .allocator = a, .arena = .init(a), .plan = plan, .journal_path = journal_path };
    }
    pub fn deinit(self: *Backend) void {
        self.arena.deinit();
    }
    pub fn lastSequence(self: *const Backend) u64 {
        return if (self.snapshot) |s| s.state.seq else 0;
    }

    pub fn tick(self: *Backend, io: std.Io) !void {
        if (self.executor) |executor| {
            try executor.tick(io, try journal.monotonicNow(io));
            self.plan = executor.plan;
        }
        if (self.journal_home) |home| if (self.executor) |engine| {
            if (engine.terminal()) try home.mark(self.allocator, io, if (engine.status == .succeeded) .completed else .failed);
        };
        try self.refresh(io);
    }

    pub fn execution(self: *const Backend) proto.wire.Execution {
        if (self.executor) |executor| return executor.view();
        var value: proto.wire.Execution = .{ .status = .view_only, .step_id = 0, .committed = 0, .total = if (self.plan) |plan| @intCast(plan.steps.len) else 0, .message = "Read-only journal view; execution disabled" };
        if (self.snapshot) |snapshot| {
            for (snapshot.state.steps.keys(), snapshot.state.steps.values()) |id, step| switch (step.state) {
                .succeeded => value.committed += 1,
                .failed => {
                    value.status = .failed;
                    value.step_id = id;
                },
                .in_flight => {
                    value.status = .interrupted;
                    value.step_id = id;
                },
            };
            if (snapshot.state.complete and value.committed == value.total and value.total != 0) value.status = .succeeded;
            if (snapshot.tail != .clean) value.status = .degraded;
        }
        return value;
    }
    pub fn revision(self: *const Backend) u64 {
        return if (self.executor) |executor| executor.revision else self.lastSequence();
    }

    /// Atomically replaces the reader snapshot. A busy writer is retried by the
    /// application loop; a truncated/replaced journal never rolls the replay cursor back.
    pub fn refresh(self: *Backend, io: std.Io) !void {
        if (self.executor) |executor| {
            const offset = try executor.journalOffset(io);
            if (self.observed_offset == offset) return;
            var next: std.heap.ArenaAllocator = .init(self.allocator);
            errdefer next.deinit();
            const value = try executor.snapshot(next.allocator(), io);
            self.arena.deinit();
            self.arena = next;
            self.snapshot = value;
            self.observed_offset = offset;
            return;
        }
        const path = self.journal_path orelse return;
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.JournalMustBeRegular;
        if (self.observed_stat) |old| {
            if (old.inode == stat.inode and old.size == stat.size and old.mtime.nanoseconds == stat.mtime.nanoseconds and old.ctime.nanoseconds == stat.ctime.nanoseconds) return;
        }
        var next: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer next.deinit();
        const value = try journal.readFile(next.allocator(), io, path);
        if (self.snapshot) |previous| {
            if (value.state.seq < previous.state.seq or value.valid_bytes < previous.valid_bytes) return error.JournalRegressed;
        }
        if (self.plan) |plan| if (value.state.boundary) |boundary| {
            if (!std.mem.eql(u8, plan.id, boundary.plan_id)) return error.JournalPlanMismatch;
        };
        self.arena.deinit();
        self.arena = next;
        self.snapshot = value;
        self.observed_stat = stat;
    }

    pub fn events(self: *const Backend, a: std.mem.Allocator, after: u64) !Batch {
        if (after > self.lastSequence()) return error.CursorAheadOfJournal;
        var list: std.ArrayList(proto.Event) = .empty;
        var last = after;
        if (self.snapshot) |snapshot| for (snapshot.records) |record| {
            if (record.seq <= after) continue;
            if (list.items.len == 32) break;
            var message = record.payload;
            if (!std.unicode.utf8ValidateSlice(message)) message = "[binary journal payload]";
            if (message.len > 4096) {
                message = message[0..4096];
                while (!std.unicode.utf8ValidateSlice(message)) message = message[0 .. message.len - 1];
            }
            try list.append(a, .{ .seq = try a.print("{d}", .{record.seq}), .step_id = record.step_id, .phase = std.meta.stringToEnum(proto.wire.Phase, @tagName(record.phase)).?, .message = message });
            last = record.seq;
        };
        return .{ .json = try std.json.Stringify.valueAlloc(a, list.items, .{}), .last = last, .count = list.items.len };
    }
};

pub const validatePlan = plan_module.validate;

test "backend replay bounds batches and preserves u64 sequences and damaged-tail status" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend = Backend.init(a, null, null);
    defer backend.deinit();
    var records: [35]journal.Record = undefined;
    for (&records, 0..) |*record, i| record.* = .{ .seq = 9007199254740993 + i, .monotonic_ns = i, .step_id = 1, .phase = .note, .payload = if (i == 0) "\xff" else "valid message" };
    backend.snapshot = .{ .records = &records, .state = .{ .seq = records[34].seq }, .valid_bytes = 123, .tail = .short_payload };
    const first = try backend.events(a, 0);
    try std.testing.expectEqual(32, first.count);
    const events = try std.json.parseFromSliceLeaky([]const proto.Event, a, first.json, .{});
    try std.testing.expectEqualStrings("9007199254740993", events[0].seq);
    try std.testing.expectEqualStrings("[binary journal payload]", events[0].message);
    const second = try backend.events(a, first.last);
    try std.testing.expectEqual(3, second.count);
    try std.testing.expectEqual(records[34].seq, second.last);
    try std.testing.expectEqual(0, (try backend.events(a, second.last)).count);
    try std.testing.expectEqual(.degraded, backend.execution().status);
}
