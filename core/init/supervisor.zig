//! Single PID 1 reaper. Signal handlers only set flags; all work runs in the loop.
const std = @import("std");
const linux = std.os.linux;

var received: u32 = 0;

fn handle(signal: linux.SIG) callconv(.c) void {
    _ = @atomicRmw(
        u32,
        &received,
        .Or,
        @as(u32, 1) << @intCast(@backingInt(signal) - 1),
        .monotonic,
    );
}

/// Sets up signal handlers for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGUSR1, and SIGUSR2.
pub fn installSignals() !void {
    const action: linux.Sigaction = .{
        .handler = .{ .handler = handle },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    for ([_]linux.SIG{ .CHLD, .TERM, .INT, .HUP, .USR1, .USR2 }) |signal|
        if (linux.errno(linux.sigaction(signal, &action, null)) != .SUCCESS)
            return error.SignalSetupFailed;
}

pub fn takeSignals() u32 {
    return @atomicRmw(u32, &received, .Xchg, 0, .monotonic);
}

pub const Exit = struct { pid: linux.pid_t, status: i32 };

/// Reaps any child, including orphans adopted by PID 1. Never blocks.
pub fn reap() !?Exit {
    while (true) {
        var status: i32 = 0;
        const result = linux.waitpid(-1, &status, linux.W.NOHANG);
        switch (linux.errno(result)) {
            .SUCCESS => return if (result == 0) null else .{ .pid = @intCast(result), .status = status },
            .INTR => continue,
            .CHILD => return null,
            else => return error.ReapFailed,
        }
    }
}

/// Only async-signal-safe syscalls run between fork and exec. Children inherit
/// the bundle CWD and get a small explicit environment instead of the host's.
pub fn probe() !linux.pid_t {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        const args = [_:null]?[*:0]const u8{ "bin/true", "--version" };
        const env = [_:null]?[*:0]const u8{ "PATH=/opt/pizza/bundle/bin", "HOME=/run/pizza", "TMPDIR=/tmp", "LC_ALL=C" };
        _ = linux.execve("bin/true", &args, &env);
        linux.exit(127);
    }
    return @intCast(pid);
}

/// VM-only orphan fixture. The intermediate parent exits before its child;
/// the grandchild must then be collected by the PID 1 supervisor.
pub fn orphan() !linux.pid_t {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        const child = linux.fork();
        if (linux.errno(child) != .SUCCESS) linux.exit(126);
        if (child == 0) {
            var delay: linux.timespec = .{ .sec = 1, .nsec = 0 };
            while (linux.errno(linux.nanosleep(&delay, &delay)) == .INTR) {}
            linux.exit(0);
        }
        linux.exit(0);
    }
    return @intCast(pid);
}

pub fn milliseconds() !i64 {
    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) return error.ClockFailed;
    return now.sec * 1000 + @divTrunc(now.nsec, 1000000);
}

pub fn sleep() void {
    const delay: linux.timespec = .{ .sec = 0, .nsec = 100000000 };
    _ = linux.nanosleep(&delay, null);
}

/// Last-resort hold for recursive panic or disposable VM fixtures. Production
/// shutdown failures enter recovery.zig's supervised console first.
pub fn degraded() noreturn {
    while (true) {
        while (reap() catch null) |_| {}
        _ = takeSignals();
        sleep();
    }
}

pub const ApplicationMode = enum {
    ui,
    no_ui,
    test_exit,
    backend_test,
    storage_test,
    session,
    session_test,
    restart_session,
};

/// The ordinary application owns business logic and display. This static supervisor
/// launches and reaps it; main.zig owns shutdown policy and never retries a plan.
pub fn application(mode: ApplicationMode) !linux.pid_t {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        const ui_args = [_:null]?[*:0]const u8{"bin/pizza-maint"};
        const console_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", "--no-ui" };
        const exit_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", "--test-exit" };
        const restart_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", "--restart-session" };
        const normal_session_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", "--session" };
        const test_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", "--self-test", "--no-tui", "--timeout", "90" };
        const storage_args = [_:null]?[*:0]const u8{"/pizza-storage-test"};
        const session_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", "--session", "--reboot-self-test", "--no-tui", "--timeout", "120" };
        const normal_env = [_:null]?[*:0]const u8{
            "PATH=/opt/pizza/bundle/bin", "HOME=/run/pizza",                 "TMPDIR=/tmp",                   "LC_ALL=C",
            "XDG_RUNTIME_DIR=/run/pizza", "XDG_CACHE_HOME=/run/pizza/cache", "XDG_DATA_HOME=/run/pizza/data", "XDG_CONFIG_HOME=/run/pizza/config",
        };
        _ = linux.execve(if (mode == .storage_test) "/pizza-storage-test" else "bin/pizza-maint", switch (mode) {
            .ui => &ui_args,
            .backend_test => &test_args,
            .storage_test => &storage_args,
            .session_test => &session_args,
            .no_ui => &console_args,
            .test_exit => &exit_args,
            .session => &normal_session_args,
            .restart_session => &restart_args,
        }, &normal_env);
        linux.exit(127);
    }
    return @intCast(pid);
}
