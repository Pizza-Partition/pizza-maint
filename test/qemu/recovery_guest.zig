//! Disposable PID 1 fixture. Failure injection is absent from the production CLI.
const std = @import("std");
const linux = std.os.linux;
const recovery = @import("recovery");
const supervisor = recovery.supervisor;
const power = @import("power");
var options: recovery.Options = .{};
var stop: bool = false;
var reboot_refused: bool = false;

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(message: []const u8, _: ?usize) noreturn {
    output("PIZZA_RECOVERY_TEST_PANIC: ");
    output(message);
    output("\n");
    recovery.run(.{ .power = .reboot }, options);
}

fn output(bytes: []const u8) void {
    _ = linux.write(2, bytes.ptr, bytes.len);
}
fn childSignal(_: linux.SIG) callconv(.c) void {
    @atomicStore(bool, &stop, true, .monotonic);
}
fn failedPower(action: power.Action) power.Error!noreturn {
    if (action != .reboot or reboot_refused) return power.request(action);
    reboot_refused = true;
    output("PIZZA_RECOVERY_TEST_REBOOT_REFUSED\n");
    return error.PowerOperationFailed;
}
fn noConsolePower(action: power.Action) power.Error!noreturn {
    if (action != .reboot) return power.request(action);
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.PowerOperationFailed;
    if (pid == 0) {
        for (0..30) |_| supervisor.sleep();
        output("PIZZA_RECOVERY_TEST_PID1_ALIVE\n");
        _ = linux.kill(1, .USR2);
        linux.exit(0);
    }
    return error.PowerOperationFailed;
}
fn stuckSync() anyerror!void {
    while (true) supervisor.sleep();
}

fn startChild(stubborn: bool) !void {
    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe(&pipe)) != .SUCCESS) return error.PipeFailed;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.close(pipe[0]);
        const action: linux.Sigaction = .{
            .handler = .{ .handler = if (stubborn) linux.SIG.IGN else childSignal },
            .mask = linux.sigemptyset(),
            .flags = 0,
        };
        _ = linux.sigaction(.TERM, &action, null);
        _ = linux.write(pipe[1], "r", 1);
        _ = linux.close(pipe[1]);
        while (!@atomicLoad(bool, &stop, .monotonic)) supervisor.sleep();
        output("PIZZA_RECOVERY_TEST_CHILD_STOPPED\n");
        linux.exit(0);
    }
    _ = linux.close(pipe[1]);
    var ready: [1]u8 = undefined;
    if (linux.read(pipe[0], &ready, 1) != 1) return error.ChildNotReady;
    _ = linux.close(pipe[0]);
}

pub fn main(init: std.process.Init) !void {
    if (linux.getpid() != 1) return error.NotPid1;
    try supervisor.installSignals();
    try power.configure();
    try @import("mounts").setup(init.io);
    _ = try @import("modules").load(init.arena.allocator(), init.io);
    const line = try std.Io.Dir.cwd().readFileAlloc(init.io, "/proc/cmdline", init.arena.allocator(), .limited(16384));
    options = .{ .request_power = failedPower, .graceful_ticks = 5, .forced_ticks = 10, .sync_ticks = 50 };
    if (std.mem.indexOf(u8, line, "recovery.case=fallback") != null) options.full_shell = "/missing-bash";
    if (std.mem.indexOf(u8, line, "recovery.case=unavailable") != null) {
        options.busybox = "/missing-busybox";
        options.request_power = noConsolePower;
    }
    if (std.mem.indexOf(u8, line, "recovery.case=sync-timeout") != null) {
        options.sync_mounts = stuckSync;
        options.sync_ticks = 3;
    }
    if (std.mem.indexOf(u8, line, "recovery.case=persistent") != null) {
        try std.Io.Dir.cwd().createDir(init.io, "/mnt", .fromMode(0o755));
        try std.Io.Dir.cwd().createDir(init.io, "/mnt/recovery", .fromMode(0o755));
        if (linux.errno(linux.mount("/dev/vda", "/mnt/recovery", "ext4", 0, 0)) != .SUCCESS) return error.TestMountFailed;
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "/mnt/recovery/before-shutdown", .data = "durable recovery fixture\n" });
        output("PIZZA_RECOVERY_TEST_PERSISTENT_MOUNTED\n");
    }
    if (std.mem.indexOf(u8, line, "recovery.case=panic") != null) @panic("injected PID 1 panic");
    try startChild(std.mem.indexOf(u8, line, "recovery.case=stubborn") != null);
    recovery.run(.{ .power = .reboot }, options);
}
