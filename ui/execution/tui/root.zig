//! libvaxis execution dashboard, with line output for serial and non-TTY consoles.
const std = @import("std");
const proto = @import("proto");

pub fn event(io: std.Io, phase: proto.JournalPhase, step: u32, total: u32, label: []const u8) void {
    var buffer: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "PIZZA_PLAN_EVENT {d}/{d} {t}: {s}\n", .{ step, total, phase, label }) catch return;
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
}
pub fn state(io: std.Io, status: proto.wire.ExecutionStatus, committed: u32, total: u32, message: []const u8) void {
    var buffer: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "PIZZA_PLAN_STATE {t} committed={d}/{d}: {s}\n", .{ status, committed, total, message }) catch return;
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
}

const vaxis = @import("vaxis");
const journal = @import("journal");
const Input = union(enum) { key_press: vaxis.Key, winsize: vaxis.Winsize };
pub const Action = enum { keep, detach, interrupt };

/// Ordinary-process terminal UI. Vaxis owns terminal parsing and screen diffs;
/// the application keeps ownership of execution and the journal on its own loop.
pub const Dashboard = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tty_buffer: [4096]u8 = undefined,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Input),
    frame: std.heap.ArenaAllocator,
    active: bool = false,
    dirty: bool = true,
    last_revision: ?u64 = null,

    pub fn open(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, force: bool) !?*Dashboard {
        if (!force and (!try std.Io.File.stdout().isTty(io) or std.mem.eql(u8, env.get("TERM") orelse "dumb", "dumb"))) return null;
        const self = try a.create(Dashboard);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .io = io, .tty = undefined, .vx = undefined, .loop = undefined, .frame = .init(a) };
        errdefer self.frame.deinit();
        self.tty = try vaxis.Tty.init(io, &self.tty_buffer);
        errdefer self.tty.deinit();
        self.vx = try vaxis.init(io, a, env, .{});
        errdefer self.vx.deinit(a, self.tty.writer());
        self.loop = .init(io, &self.tty, &self.vx);
        try self.loop.start();
        errdefer self.loop.stop();
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), .fromMilliseconds(100));
        try self.resize(try self.tty.getWinsize());
        self.active = true;
        return self;
    }
    pub fn close(self: *Dashboard) void {
        if (!self.active) return;
        self.loop.stop();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.frame.deinit();
        self.active = false;
    }
    fn resize(self: *Dashboard, raw: vaxis.Winsize) !void {
        var size = raw;
        size.rows = @min(if (raw.rows == 0) @as(u16, 24) else raw.rows, 200);
        size.cols = @min(if (raw.cols == 0) @as(u16, 80) else raw.cols, 300);
        try self.vx.resize(self.allocator, self.tty.writer(), size);
        self.dirty = true;
    }
    pub fn poll(self: *Dashboard) !Action {
        while (try self.loop.tryEvent()) |input| switch (input) {
            .winsize => |size| try self.resize(size),
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) return .interrupt;
                if (key.matches('q', .{})) return .detach;
            },
        };
        return .keep;
    }
    pub fn draw(self: *Dashboard, value: proto.wire.Execution, plan: ?proto.Plan, snapshot: ?journal.Scan, revision: u64) !void {
        if (!self.dirty and self.last_revision == revision) return;
        const win = self.vx.window();
        // Vaxis's previous screen owns its bytes. Clear borrowed current cells
        // before releasing our previous frame's formatted strings.
        win.clear();
        _ = self.frame.reset(.retain_capacity);
        const a = self.frame.allocator();
        _ = win.print(&.{.{ .text = "Pizza maintenance", .style = .{ .bold = true, .fg = .{ .index = 6 } } }}, .{});
        _ = win.print(&.{.{ .text = try a.print("{t}  step={d}  {d}/{d} confirmed", .{ value.status, value.step_id, value.committed, value.total }), .style = .{ .fg = .{ .index = if (value.status == .degraded or value.status == .failed or value.status == .interrupted) 1 else 2 } } }}, .{ .row_offset = 2, .wrap = .none });
        var bar: [40]u8 = @splat('-');
        const filled: usize = if (value.total == 0) 0 else @min(40, @as(usize, value.committed) * 40 / value.total);
        @memset(bar[0..filled], '#');
        _ = win.print(&.{.{ .text = try a.print("[{s}]", .{bar}) }}, .{ .row_offset = 3, .wrap = .none });
        _ = win.print(&.{.{ .text = try a.print("Bytes: {s}/{s}", .{ value.completed_bytes, value.total_bytes }) }}, .{ .row_offset = 4, .wrap = .none });
        _ = win.print(&.{.{ .text = try a.dupe(u8, value.message) }}, .{ .row_offset = 5, .wrap = .word });
        if (plan) |actual| {
            for (actual.steps, 0..) |step, i| {
                if (8 + i >= win.height) break;
                const status_text = if (snapshot) |scan| (if (scan.state.steps.get(step.id)) |s| @tagName(s.state) else "pending") else "pending";
                _ = win.print(&.{.{ .text = try a.print("{d: >2}. {s}: {s}", .{ i + 1, status_text, step.label }) }}, .{ .row_offset = @intCast(8 + i), .wrap = .none });
            }
        }
        if (win.height > 0) _ = win.print(&.{.{ .text = "q: hide TUI (plan continues) | Ctrl+C: cancel and restore" }}, .{ .row_offset = win.height - 1, .wrap = .none });
        try self.vx.render(self.tty.writer());
        try self.tty.writer().flush();
        self.last_revision = revision;
        self.dirty = false;
    }
    pub fn selfTest(self: *Dashboard) !void {
        try self.draw(.{ .status = .running, .step_id = 8, .committed = 7, .total = 20, .message = "libvaxis terminal self-test" }, null, null, 1);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        for (self.vx.screen.buf) |cell| try text.appendSlice(self.allocator, cell.char.grapheme);
        if (std.mem.indexOf(u8, text.items, "Pizza maintenance") == null or std.mem.indexOf(u8, text.items, "7/20 confirmed") == null) return error.TerminalFrameMismatch;
    }
};
