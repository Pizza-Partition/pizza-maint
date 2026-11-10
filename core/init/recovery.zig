//! Controlled shutdown and a supervised root rescue console. No allocator or log locks.
const std = @import("std");
const linux = std.os.linux;
const power = @import("power");
pub const supervisor = @import("supervisor.zig");
const emergency = @import("emergency.zig");

pub const Request = union(enum) { power: power.Action, rescue };
pub const Options = struct {
    request_power: *const fn (power.Action) power.Error!noreturn = power.request,
    full_shell: [:0]const u8 = "/opt/pizza/bundle/bin/bash",
    busybox: [:0]const u8 = "/opt/pizza/bundle/bin/busybox",
    working_directory: [:0]const u8 = "/opt/pizza/bundle",
    graceful_ticks: u16 = 100,
    forced_ticks: u16 = 20,
    sync_ticks: u16 = 150,
    sync_mounts: *const fn () anyerror!void = flushMounts,
};

pub fn signalBit(signal: linux.SIG) u32 {
    return @as(u32, 1) << @intCast(@backingInt(signal) - 1);
}

/// BusyBox's conventional init protocol; HUP explicitly opens a rescue console.
pub fn fromSignals(signals: u32) ?Request {
    if (signals & signalBit(.USR2) != 0) return .{ .power = .poweroff };
    if (signals & signalBit(.USR1) != 0) return .{ .power = .halt };
    if (signals & (signalBit(.TERM) | signalBit(.INT)) != 0) return .{ .power = .reboot };
    if (signals & signalBit(.HUP) != 0) return .rescue;
    return null;
}

pub fn shutdown(action: power.Action) noreturn {
    run(.{ .power = action }, .{});
}

pub fn run(initial: Request, options: Options) noreturn {
    if (linux.getpid() != 1) std.debug.defaultPanic("recovery requires PID 1", @returnAddress());
    supervisor.installSignals() catch |err| report("PIZZA_RECOVERY_SIGNAL_SETUP_FAILED: ", err);
    var next = initial;
    while (true) {
        switch (next) {
            .power => |action| {
                prepare(options) catch |err| {
                    report("PIZZA_SHUTDOWN_FAILED: ", err);
                    next = rescue(options);
                    continue;
                };
                emergency.write(switch (action) {
                    .reboot => "PIZZA_POWER_REQUEST: reboot\n",
                    .poweroff => "PIZZA_POWER_REQUEST: poweroff\n",
                    .halt => "PIZZA_POWER_REQUEST: halt\n",
                });
                options.request_power(action) catch |err| report("PIZZA_POWER_FAILED: ", err);
            },
            .rescue => stopChildren(options) catch |err| report("PIZZA_CHILDREN_STILL_BUSY: ", err),
        }
        next = rescue(options);
    }
}

fn report(prefix: []const u8, err: anyerror) void {
    emergency.write(prefix);
    emergency.write(@errorName(err));
    emergency.write("\n");
}

fn childrenGone() bool {
    for (0..4096) |_| {
        var status: i32 = 0;
        const result = linux.waitpid(-1, &status, linux.W.NOHANG);
        switch (linux.errno(result)) {
            .CHILD => return true,
            .SUCCESS => if (result == 0) return false,
            .INTR => {},
            else => return false,
        }
    }
    return false;
}

fn waitChildren(ticks: u16) bool {
    for (0..ticks) |_| {
        if (childrenGone()) return true;
        supervisor.sleep();
    }
    return childrenGone();
}

fn stopChildren(options: Options) !void {
    if (linux.getpid() != 1) return error.NotPid1;
    _ = linux.kill(-1, .TERM);
    if (!waitChildren(options.graceful_ticks)) {
        emergency.write("PIZZA_SHUTDOWN_FORCE_STOP: graceful timeout\n");
        _ = linux.kill(-1, .KILL);
        if (!waitChildren(options.forced_ticks)) return error.ChildrenStillRunning;
    }
    emergency.write("PIZZA_SHUTDOWN_CHILDREN_STOPPED\n");
}

/// Stop writers before flushing. A helper bounds the parent's wait for stuck IO.
pub fn prepare(options: Options) !void {
    if (linux.getpid() != 1) return error.NotPid1;
    try stopChildren(options);
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.SyncForkFailed;
    if (pid == 0) {
        options.sync_mounts() catch linux.exit(1);
        linux.exit(0);
    }
    for (0..options.sync_ticks) |_| {
        var status: i32 = 0;
        const result = linux.waitpid(@intCast(pid), &status, linux.W.NOHANG);
        switch (linux.errno(result)) {
            .SUCCESS => if (result != 0) {
                if (status != 0) return error.SyncOrUnmountFailed;
                emergency.write("PIZZA_SHUTDOWN_SYNCED\n");
                return;
            },
            .INTR => {},
            else => return error.SyncWaitFailed,
        }
        supervisor.sleep();
    }
    _ = linux.kill(@intCast(pid), .KILL);
    return error.SyncTimedOut;
}

fn volatileFilesystem(kind: []const u8) bool {
    const kinds = [_][]const u8{
        "rootfs", "ramfs",     "tmpfs",       "devtmpfs", "proc",     "sysfs",  "devpts",
        "cgroup", "cgroup2",   "securityfs",  "debugfs",  "tracefs",  "pstore", "efivarfs",
        "mqueue", "hugetlbfs", "binfmt_misc", "fusectl",  "configfs",
    };
    for (kinds) |value| if (std.mem.eql(u8, kind, value)) return true;
    return false;
}

fn decodePath(encoded: []const u8, output: []u8) ![:0]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < encoded.len) {
        if (n + 1 >= output.len) return error.MountPathTooLong;
        if (encoded[i] == '\\') {
            if (i + 3 >= encoded.len) return error.InvalidMountPath;
            const value = std.fmt.parseInt(u8, encoded[i + 1 ..][0..3], 8) catch return error.InvalidMountPath;
            if (value == 0) return error.InvalidMountPath;
            output[n] = value;
            i += 4;
        } else {
            output[n] = encoded[i];
            i += 1;
        }
        n += 1;
    }
    output[n] = 0;
    return output[0..n :0];
}

fn flushMounts() !void {
    const opened = linux.open("/proc/self/mounts", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.MountTableUnavailable;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var buffer: [64 * 1024]u8 = undefined;
    var length: usize = 0;
    var eof = false;
    for (0..128) |_| {
        if (length == buffer.len) return error.MountTableTooLarge;
        const count = linux.read(fd, buffer[length..].ptr, buffer.len - length);
        switch (linux.errno(count)) {
            .SUCCESS => {
                if (count == 0) {
                    eof = true;
                    break;
                }
                length += count;
            },
            .INTR => {},
            else => return error.MountTableReadFailed,
        }
    }
    if (!eof) return error.MountTableReadFailed;
    defer linux.sync();
    // Reverse mount order handles children before parents. Busy/unsupported
    // layouts fail into rescue instead of using lazy or forced unmounts.
    var lines = std.mem.splitBackwardsScalar(u8, buffer[0..length], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse return error.InvalidMountTable;
        const encoded = fields.next() orelse return error.InvalidMountTable;
        const kind = fields.next() orelse return error.InvalidMountTable;
        if (volatileFilesystem(kind)) continue;
        var path_buffer: [4096]u8 = undefined;
        const path = try decodePath(encoded, &path_buffer);
        const file = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(file) != .SUCCESS) return error.MountOpenFailed;
        const result = linux.syncfs(@intCast(file));
        _ = linux.close(@intCast(file));
        if (linux.errno(result) != .SUCCESS) return error.MountSyncFailed;
        if (linux.errno(linux.umount2(path.ptr, 0)) != .SUCCESS) return error.MountUnmountFailed;
    }
    linux.sync();
}

fn ensurePseudo(directory: [*:0]const u8, probe: [*:0]const u8, kind: [*:0]const u8) void {
    const file = linux.open(probe, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(file) == .SUCCESS) {
        _ = linux.close(@intCast(file));
        return;
    }
    _ = linux.mkdir(directory, 0o755);
    _ = linux.mount(kind, directory, kind, linux.MS.NOSUID, 0);
}

// /dev/console itself cannot always become a controlling terminal. Resolve
// the active kernel console and acquire it directly, without a cttyhack binary.
fn openConsole() !linux.fd_t {
    var name: [128]u8 = undefined;
    const opened = linux.open("/sys/class/tty/console/active", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.ConsoleUnavailable;
    const fd: linux.fd_t = @intCast(opened);
    const n = linux.read(fd, &name, name.len);
    _ = linux.close(fd);
    if (linux.errno(n) != .SUCCESS or n == 0 or n == name.len) return error.ConsoleUnavailable;
    var tokens = std.mem.tokenizeAny(u8, name[0..n], " \t\r\n");
    var last: []const u8 = "";
    while (tokens.next()) |token| last = token;
    if (!std.mem.startsWith(u8, last, "tty") or last.len > 64) return error.InvalidConsole;
    for (last) |ch| if (!std.ascii.isAlphanumeric(ch)) return error.InvalidConsole;
    var path: [70]u8 = undefined;
    @memcpy(path[0..5], "/dev/");
    @memcpy(path[5..][0..last.len], last);
    path[5 + last.len] = 0;
    const console = linux.open(@ptrCast(&path), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    if (linux.errno(console) != .SUCCESS) return error.ConsoleUnavailable;
    return @intCast(console);
}

fn startShell(fallback: bool, options: Options) !linux.pid_t {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ShellForkFailed;
    if (pid != 0) return @intCast(pid);
    if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(127);
    var empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    const console = openConsole() catch linux.exit(127);
    if (linux.errno(linux.ioctl(console, linux.T.IOCSCTTY, 1)) != .SUCCESS) linux.exit(127);
    const group = linux.getpid();
    if (linux.errno(linux.tcsetpgrp(console, &group)) != .SUCCESS) linux.exit(127);
    for (0..3) |number|
        if (linux.errno(linux.dup2(@intCast(console), @intCast(number))) != .SUCCESS) linux.exit(127);
    if (console > 2) _ = linux.close(@intCast(console));
    // Bundled ELF interpreters use lib/... relative to the bundle directory.
    if (linux.errno(linux.chdir(options.working_directory)) != .SUCCESS) linux.exit(127);
    const env = [_:null]?[*:0]const u8{
        "PATH=/usr/sbin:/usr/bin:/sbin:/bin:/opt/pizza/bundle/bin", "HOME=/",             "LC_ALL=C",
        "TERM=linux",                                               "HISTFILE=/dev/null", "PS1=pizza-rescue# ",
    };
    const full = [_:null]?[*:0]const u8{ options.full_shell, "--noprofile", "--norc", "-i" };
    const minimal = [_:null]?[*:0]const u8{ options.busybox, "sh", "-i" };
    _ = linux.execve(if (fallback) options.busybox else options.full_shell, if (fallback) &minimal else &full, &env);
    linux.exit(127);
}

fn awaitRequest() Request {
    while (true) {
        while (supervisor.reap() catch null) |_| {}
        if (fromSignals(supervisor.takeSignals())) |request| return request;
        supervisor.sleep();
    }
}

fn rescue(options: Options) Request {
    ensurePseudo("/proc", "/proc/self/mounts", "proc");
    ensurePseudo("/sys", "/sys/class/tty/console/active", "sysfs");
    ensurePseudo("/dev", "/dev/null", "devtmpfs");
    var fallback = false;
    while (true) {
        emergency.write(if (fallback) "PIZZA_RESCUE_SHELL: busybox\n" else "PIZZA_RESCUE_SHELL: bash\n");
        const pid = startShell(fallback, options) catch {
            if (!fallback) {
                fallback = true;
                continue;
            }
            emergency.write("PIZZA_RESCUE_UNAVAILABLE: PID 1 waiting for power/rescue requests\n");
            return awaitRequest();
        };
        var status: ?i32 = null;
        while (status == null) {
            while (supervisor.reap() catch null) |child| if (child.pid == pid) {
                status = child.status;
            };
            if (fromSignals(supervisor.takeSignals())) |request| return request;
            if (status == null) supervisor.sleep();
        }
        const failed = status.? == (127 << 8) or status.? == (126 << 8) or status.? & 0x7f != 0;
        if (failed and fallback) {
            emergency.write("PIZZA_RESCUE_UNAVAILABLE: PID 1 waiting for power/rescue requests\n");
            return awaitRequest();
        }
        fallback = failed;
        emergency.write("PIZZA_RESCUE_EXITED: respawning console\n");
        for (0..10) |_| supervisor.sleep();
    }
}

test "conventional power signals and explicit rescue request" {
    try std.testing.expectEqual(power.Action.reboot, fromSignals(signalBit(.TERM)).?.power);
    try std.testing.expectEqual(power.Action.reboot, fromSignals(signalBit(.INT)).?.power);
    try std.testing.expectEqual(power.Action.halt, fromSignals(signalBit(.USR1)).?.power);
    try std.testing.expectEqual(power.Action.poweroff, fromSignals(signalBit(.USR2) | signalBit(.TERM)).?.power);
    try std.testing.expect(fromSignals(signalBit(.HUP)).? == .rescue);
    try std.testing.expect(fromSignals(signalBit(.CHLD)) == null);
    try std.testing.expectError(error.NotPid1, prepare(.{}));
}

test "mount paths decode kernel escaping without truncation" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/mnt/a b\\c", try decodePath("/mnt/a\\040b\\134c", &buffer));
    try std.testing.expectError(error.InvalidMountPath, decodePath("/mnt/\\000", &buffer));
    try std.testing.expectError(error.InvalidMountPath, decodePath("/mnt/\\xx1", &buffer));
    try std.testing.expectError(error.MountPathTooLong, decodePath("/mnt/long", buffer[0..4]));
    try std.testing.expect(volatileFilesystem("tmpfs"));
    try std.testing.expect(!volatileFilesystem("ext4"));
}
