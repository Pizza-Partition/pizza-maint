//! Production init and fault-injected recovery in disposable QEMU guests.
//! Uses the native newc/gzip encoder and std.process; no scripting runtime.
const std = @import("std");
const utils = @import("utils");
const archive = @import("initramfs_archive");
const linux = std.os.linux;
const Dir = std.Io.Dir;
const Scenario = enum { production, persistent, reboot, halt, fallback, panic, stubborn, @"sync-timeout", unavailable };
const Result = struct { case: Scenario, passed: bool = true, serial: []const u8 };
const Options = struct { base: []const u8, kernel: []const u8, init: []const u8, fixture: []const u8, output: []const u8, timeout: u32 };
const HELP =
    \\Usage: pizza-init-recovery-test --base FILE --kernel FILE --init FILE --fixture FILE
    \\       [--output NEW_DIRECTORY] [--timeout SECONDS]
    \\Runs nine disposable VM scenarios; never attaches physical devices.
    \\The build supplies --init and --fixture. Default timeout: 90 seconds per VM.
    \\
;
fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn json(a: std.mem.Allocator, io: std.Io, path: []const u8, value: anytype) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }) });
}
fn required(text: []const u8, marker: []const u8) !void {
    if (std.mem.indexOf(u8, text, marker) == null) {
        std.log.err("Missing recovery marker: {s}", .{marker});
        return error.RecoveryMarkerMissing;
    }
}
fn exited(pid: linux.pid_t) !bool {
    var info = std.mem.zeroes(linux.siginfo_t);
    switch (linux.errno(linux.waitid(.PID, @intCast(pid), &info, linux.W.EXITED | linux.W.NOWAIT | linux.W.NOHANG, null))) {
        .SUCCESS => return info.fields.common.first.piduid.pid != 0,
        .INTR => return false,
        else => return error.ChildStatusFailed,
    }
}
fn readPending(a: std.mem.Allocator, io: std.Io, file: std.Io.File, transcript: *std.ArrayList(u8)) !void {
    var bytes: [65536]u8 = undefined;
    while (true) {
        const count = try file.readPositionalAll(io, &bytes, transcript.items.len);
        if (transcript.items.len + count > 4 * 1024 * 1024) return error.SerialLogTooLarge;
        try transcript.appendSlice(a, bytes[0..count]);
        if (count < bytes.len) return;
    }
}
fn verify(scenario: Scenario, text: []const u8) !void {
    try required(text, "PIZZA_SHUTDOWN_CHILDREN_STOPPED");
    if (scenario == .production) {
        for ([_][]const u8{ "PIZZA_INIT_APPLICATION_EXITED", "PIZZA_SHUTDOWN_SYNCED", "PIZZA_POWER_REQUEST: reboot", "Restarting system" }) |marker| try required(text, marker);
    } else {
        try required(text, if (scenario == .reboot) "Restarting system" else if (scenario == .halt) "System halted" else "Power down");
        if (scenario == .@"sync-timeout") {
            try required(text, "PIZZA_SHUTDOWN_FAILED: SyncTimedOut");
            try required(text, "PIZZA_RESCUE_SHELL: bash");
            if (std.mem.indexOf(u8, text, "PIZZA_POWER_REQUEST:") != null) return error.PowerRequestedBeforeSynchronization;
        } else {
            try required(text, "PIZZA_POWER_FAILED:");
            try required(text, if (scenario == .reboot) "PIZZA_POWER_REQUEST: reboot" else if (scenario == .halt) "PIZZA_POWER_REQUEST: halt" else "PIZZA_POWER_REQUEST: poweroff");
            try required(text, "PIZZA_SHUTDOWN_SYNCED");
        }
        if (scenario == .unavailable) {
            try required(text, "PIZZA_RESCUE_UNAVAILABLE");
            try required(text, "PIZZA_RECOVERY_TEST_PID1_ALIVE");
        } else {
            // CRLF distinguishes command output from the terminal's script echo.
            try required(text, "PIZZA_TEST_TTY_READY\r\n");
            try required(text, if (scenario == .fallback) "PIZZA_TEST_FALLBACK_READY\r\n" else "PIZZA_TEST_TOOLS_READY\r\n");
            try required(text, "PIZZA_TEST_POWER_COMMANDS_READY\r\n");
        }
        switch (scenario) {
            .fallback => try required(text, "PIZZA_RESCUE_SHELL: busybox"),
            .panic => try required(text, "PIZZA_RECOVERY_TEST_PANIC: injected PID 1 panic"),
            .stubborn => try required(text, "PIZZA_SHUTDOWN_FORCE_STOP"),
            .persistent => for ([_][]const u8{ "PIZZA_RECOVERY_TEST_CHILD_STOPPED", "PIZZA_RESCUE_EXITED", "PIZZA_TEST_UNMOUNTED\r\n" }) |marker| try required(text, marker),
            else => {},
        }
    }
    for ([_][]const u8{ "Kernel panic", "no job control", "can't access tty" }) |marker| if (std.mem.indexOf(u8, text, marker) != null) return error.BrokenRecoveryConsole;
}
fn script(a: std.mem.Allocator, scenario: Scenario, sent: usize) ![]const u8 {
    if (scenario == .persistent and sent == 0) return "printf 'PIZZA_TEST_FIRST_SHELL\\n'; exit\n";
    return a.print(
        "test $$ -ne 1 && test -t 0 && test -t 1 && printf 'PIZZA_TEST_TTY_READY\\n'; " ++
            "cd /tmp; ls / >/dev/null; test -L /sbin/reboot && test -L /sbin/poweroff && " ++
            "test -L /sbin/halt && printf 'PIZZA_TEST_POWER_COMMANDS_READY\\n'; {s}{s}{s}\n",
        .{
            if (scenario == .fallback) "/opt/pizza/bundle/bin/busybox cat /proc/1/comm >/dev/null && printf 'PIZZA_TEST_FALLBACK_READY\\n'; " else "vi --version >/dev/null && nano --version >/dev/null && man -w ls >/dev/null && printf 'PIZZA_TEST_TOOLS_READY\\n'; ",
            if (scenario == .persistent) "test ! -e /mnt/recovery/before-shutdown && printf 'PIZZA_TEST_UNMOUNTED\\n'; " else "",
            if (scenario == .@"sync-timeout") "poweroff -f" else if (scenario == .reboot) "reboot" else if (scenario == .halt) "halt" else "poweroff",
        },
    );
}
fn runCase(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, options: Options, scenario: Scenario) !Result {
    const directory = try a.print("{s}/{t}", .{ options.output, scenario });
    try Dir.cwd().createDir(io, directory, .default_dir);
    const image = try a.print("{s}/initramfs.img", .{directory});
    try Dir.cwd().copyFile(options.base, .cwd(), image, io, .{});
    const overlay = try a.print("{s}/fixture.cpio.gz", .{directory});
    const binary = if (scenario == .production) options.init else options.fixture;
    const elf = try utils.elf.metadata(a, io, binary);
    if (elf.interp.len != 0 or elf.needed.len != 0) return error.RecoveryPid1MustBeStatic;
    try archive.staticInit(a, io, binary, overlay);
    {
        const file = try Dir.cwd().openFile(io, image, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, try Dir.cwd().readFileAlloc(io, overlay, a, .limited(128 * 1024 * 1024)), (try file.stat(io)).size);
    }
    var command: std.ArrayList([]const u8) = .empty;
    try command.appendSlice(a, &.{ "qemu-system-x86_64", "-machine", "q35", "-accel", "tcg", "-cpu", "max", "-m", "4096M", "-display", "none", "-serial", "stdio", "-monitor", "none", "-nic", "none", "-kernel", options.kernel, "-initrd", image, "-append", if (scenario == .production) "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.kiosk=disable" else try a.print("console=ttyS0 loglevel=4 panic=1 rdinit=/init recovery.case={t}", .{scenario}), "-no-reboot" });
    const disk = try a.print("{s}/disposable.raw", .{directory});
    if (scenario == .persistent) {
        try @import("harness.zig").noComma(disk);
        const file = try Dir.cwd().createFile(io, disk, .{ .exclusive = true });
        try file.setLength(io, 32 * 1024 * 1024);
        file.close(io);
        _ = try utils.process.checkedOutput(a, io, env, &.{ "mkfs.ext4", "-q", "-F", disk });
        try command.appendSlice(a, &.{ "-drive", try a.print("file={s},format=raw,if=virtio", .{disk}) });
    }
    try json(a, io, try a.print("{s}/command.json", .{directory}), command.items);
    const serial_path = try a.print("{s}/serial.log", .{directory});
    const serial = try Dir.cwd().createFile(io, serial_path, .{ .exclusive = true, .read = true });
    defer serial.close(io);
    errdefer std.log.err("Recovery case {t} failed; serial log: {s}", .{ scenario, serial_path });
    var child = try std.process.spawn(io, .{ .argv = command.items, .environ_map = env, .stdin = .pipe, .stdout = .{ .file = serial }, .stderr = .{ .file = serial } });
    defer child.kill(io);
    var transcript: std.ArrayList(u8) = .empty;
    const start = std.Io.Clock.awake.now(io);
    var sent: usize = 0;
    var halted = false;
    while (true) {
        try readPending(a, io, serial, &transcript);
        if (scenario == .halt and std.mem.indexOf(u8, transcript.items, "System halted") != null) {
            // HLT leaves QEMU alive. Stop only this owned VM after observing
            // the guest kernel marker; verify all shutdown evidence below.
            halted = true;
            child.kill(io);
            break;
        }
        if (try exited(child.id.?)) break;
        if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= @as(u64, options.timeout) * 1000) return error.RecoveryVmTimedOut;
        if (scenario != .production and scenario != .unavailable and sent < @as(usize, if (scenario == .persistent) 2 else 1) and std.mem.count(u8, transcript.items, "pizza-rescue# ") > sent) {
            try child.stdin.?.writeStreamingAll(io, try script(a, scenario, sent));
            sent += 1;
        }
        try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    }
    if (!halted and !(try child.wait(io)).success()) return error.RecoveryVmFailed;
    try readPending(a, io, serial, &transcript);
    try verify(scenario, transcript.items);
    if (scenario == .persistent) {
        _ = try utils.process.checkedOutput(a, io, env, &.{ "e2fsck", "-fn", disk });
        const bytes = try utils.process.checkedOutput(a, io, env, &.{ "debugfs", "-R", "cat /before-shutdown", disk });
        if (!equal(bytes, "durable recovery fixture\n")) return error.ShutdownDidNotPersistData;
    }
    const result: Result = .{ .case = scenario, .serial = serial_path };
    try json(a, io, try a.print("{s}/result.json", .{directory}), result);
    try std.Io.File.stdout().writeStreamingAll(io, try a.print("PASS: {t}\n", .{scenario}));
    return result;
}
pub fn main(init: std.process.Init) !void {
    const a, const io = .{ init.arena.allocator(), init.io };
    const args = try init.minimal.args.toSlice(a);
    var paths: [5]?[]const u8 = @splat(null);
    const names = [_][]const u8{ "--base", "--kernel", "--init", "--fixture", "--output" };
    var timeout: u32 = 90;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (equal(arg, "--help") or equal(arg, "-h")) return std.Io.File.stdout().writeStreamingAll(io, HELP);
        index += 1;
        if (index == args.len) return error.MissingRecoveryOptionValue;
        if (equal(arg, "--timeout")) {
            timeout = try std.fmt.parseInt(u32, args[index], 10);
            if (timeout == 0) return error.InvalidRecoveryTimeout;
        } else {
            const field = for (names, 0..) |name, n| {
                if (equal(arg, name)) break n;
            } else return error.UnknownRecoveryOption;
            if (paths[field] != null) return error.DuplicateRecoveryOption;
            paths[field] = args[index];
        }
    }
    for (paths[0..4]) |*path| {
        path.* = try Dir.cwd().realPathFileAlloc(io, path.* orelse return error.MissingRecoveryInput, a);
        if ((try Dir.cwd().statFile(io, path.*.?, .{})).kind != .file) return error.RecoveryInputMustBeFile;
    }
    const output = if (paths[4]) |path| blk: {
        const cwd = try Dir.cwd().realPathFileAlloc(io, ".", a);
        const absolute = try std.fs.path.resolve(a, &.{ cwd, path });
        if (std.fs.path.dirname(absolute)) |parent| try Dir.cwd().createDirPath(io, parent);
        try Dir.cwd().createDir(io, absolute, .default_dir);
        break :blk absolute;
    } else try utils.filesystem.createTemporaryDirectory(a, io, "pizza-init-recovery-");
    const options: Options = .{ .base = paths[0].?, .kernel = paths[1].?, .init = paths[2].?, .fixture = paths[3].?, .output = output, .timeout = timeout };
    var results: [std.enums.values(Scenario).len]Result = undefined;
    for (std.enums.values(Scenario), &results) |scenario, *result| {
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const value = try runCase(arena.allocator(), io, init.environ_map, options, scenario);
        result.* = .{ .case = value.case, .serial = try a.dupe(u8, value.serial) };
    }
    try json(a, io, try a.print("{s}/results.json", .{output}), results);
    try std.Io.File.stdout().writeStreamingAll(io, try a.print("PASS: {d} recovery scenarios; artifacts: {s}\n", .{ results.len, output }));
}
