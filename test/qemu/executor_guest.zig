//! Disposable VM PID 1; only /dev/vda, supplied by the test runner, is mounted.
const std = @import("std");
const linux = std.os.linux;
const journal = @import("journal");
const proto = @import("proto");
const supervisor = @import("supervisor");
const power = @import("power");
const utils = @import("utils");
var physical = false;
var test_sector: u32 = 512;
const NAMES = [_][]const u8{ "success", "identity", "killed", "journal", "source_removed", "cancelled" };

pub fn main(init: std.process.Init) !void {
    if (linux.getpid() != 1) return error.NotPid1;
    supervisor.installSignals() catch {};
    run(init.arena.allocator(), init.io) catch |err| std.log.err("PIZZA_EXECUTOR_TEST_FAILED: {t}", .{err});
    power.poweroff() catch {};
    supervisor.degraded();
}
fn spawn(a: std.mem.Allocator, argv: []const []const u8) !linux.pid_t {
    const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| args[i] = (try a.dupeSentinel(u8, arg, 0)).ptr;
    const env = [_:null]?[*:0]const u8{ "PATH=/opt/pizza/bundle/bin", "HOME=/run/pizza", "TMPDIR=/tmp", "LC_ALL=C", "XDG_RUNTIME_DIR=/run/pizza", "XDG_CACHE_HOME=/run/pizza/cache" };
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.execve("bin/pizza-maint", args.ptr, &env);
        linux.exit(127);
    }
    return @intCast(pid);
}
fn wait(pid: linux.pid_t, kill_after_ms: i64) !i32 {
    const start = try supervisor.milliseconds();
    var killed = false;
    while (true) {
        while (try supervisor.reap()) |child| if (child.pid == pid) return child.status;
        if (!killed and try supervisor.milliseconds() - start > kill_after_ms) {
            if (linux.errno(linux.kill(pid, .KILL)) != .SUCCESS) return error.ChildKillFailed;
            killed = true;
        }
        if (try supervisor.milliseconds() - start > kill_after_ms + 5000) return error.ChildTimedOut;
        supervisor.sleep();
    }
}
fn exists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
fn image(a: std.mem.Allocator, io: std.Io, path: []const u8, capacity: u64) !proto.wire.DeviceRef {
    if (physical) {
        const label = if (std.mem.endsWith(u8, path, "/source.raw")) "source" else blk: {
            for (NAMES) |name| if (std.mem.indexOf(u8, path, try a.print("/{s}/target.raw", .{name})) != null) break :blk name;
            return error.UnknownPhysicalFixture;
        };
        const node = try a.print("/dev/pizza-{s}", .{label});
        const result = try std.process.run(a, io, .{ .argv = &.{ "bin/pizza-maint", "--probe-device", node } });
        if (!result.term.success()) return error.PhysicalProbeFailed;
        const info = try std.json.parseFromSliceLeaky(struct { identity: []const u8, capacity: []const u8, sector_size: u32 }, a, result.stdout, .{ .ignore_unknown_fields = true });
        if (try proto.byteCount(info.capacity) != capacity or info.sector_size != test_sector) return error.PhysicalFixtureGeometry;
        return .{ .path = node, .identity = info.identity, .sector_size = info.sector_size, .kind = .physical };
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.setLength(io, capacity);
    try file.sync(io);
    return .{ .path = path, .identity = try a.dupe(u8, &std.fmt.bytesToHex(try utils.filesystem.imageIdentity(file), .lower)), .sector_size = 512, .kind = .image };
}
fn execute(a: std.mem.Allocator, io: std.Io, plan_path: []const u8, home: []const u8, fault: enum { none, kill, cancel }) !i32 {
    const pid = try spawn(a, &.{ "bin/pizza-maint", "--execute", "--plan", plan_path, "--journal-home", home, "--no-ui", "--exit-after-plan" });
    if (fault != .none) {
        const start = try supervisor.milliseconds();
        const state_path = try a.print("{s}/state", .{home});
        while (true) {
            const file = std.Io.Dir.cwd().openFile(io, state_path, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (file) |opened| {
                var bytes: [8]u8 = undefined;
                const count = try opened.readPositionalAll(io, &bytes, 0);
                opened.close(io);
                // This is only the kill trigger. Raw recovery validates the
                // complete record and current version after the next boot.
                if (count == 8 and std.mem.startsWith(u8, &bytes, "PZSTATE")) break;
            }
            if (try supervisor.milliseconds() - start > 60000) return error.MissingDurableIntent;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        if (linux.errno(linux.kill(pid, if (fault == .cancel) .INT else .KILL)) != .SUCCESS) return error.ChildKillFailed;
    }
    return wait(pid, 75000);
}
fn run(a: std.mem.Allocator, io: std.Io) !void {
    try @import("mounts").setup(io);
    try std.Io.Dir.cwd().createDirPath(io, "/journal");
    if (linux.errno(linux.mount("/dev/vda", "/journal", "ext4", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, 0)) != .SUCCESS) return error.TestJournalMountFailed;
    if (linux.errno(linux.chdir("/opt/pizza/bundle")) != .SUCCESS) return error.BundleWorkingDirectoryUnavailable;
    const command = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/cmdline", a, .limited(16384));
    const reading = std.mem.indexOf(u8, command, "pizza.executor_test=read") != null;
    if (!reading and std.mem.indexOf(u8, command, "pizza.executor_test=write") == null) return error.MissingMode;
    physical = std.mem.indexOf(u8, command, "pizza.physical_test=512") != null or std.mem.indexOf(u8, command, "pizza.physical_test=4096") != null;
    test_sector = if (std.mem.indexOf(u8, command, "pizza.physical_test=4096") != null) 4096 else 512;
    if (physical) {
        var sysfs = try std.Io.Dir.cwd().openDir(io, "/sys/class/block", .{ .iterate = true });
        defer sysfs.close(io);
        var it = sysfs.iterate();
        while (try it.next(io)) |entry| {
            const serial = sysfs.readFileAlloc(io, try a.print("{s}/serial", .{entry.name}), a, .limited(4096)) catch continue;
            const trimmed = std.mem.trim(u8, serial, " \r\n");
            if (!std.mem.startsWith(u8, trimmed, "pz-")) continue;
            try std.Io.Dir.cwd().symLink(io, try a.print("/dev/{s}", .{entry.name}), try a.print("/dev/pizza-{s}", .{trimmed[3..]}), .{});
            if (std.mem.eql(u8, trimmed, "pz-independent")) {
                for ([_]u32{ 1, 2 }) |part| try std.Io.Dir.cwd().symLink(io, try a.print("/dev/{s}{d}", .{ entry.name, part }), try a.print("/dev/pizza-independent{d}", .{part}), .{});
            }
        }
        // Acquiring the mounted recovery device must fail before preparing undo.
        if (!reading) {
            const busy = try std.process.run(a, io, .{ .argv = &.{ "bin/pizza-maint", "--probe-device", "/dev/vda" } });
            if (!busy.term.success()) return error.RecoveryProbeFailed;
            const info = try std.json.parseFromSliceLeaky(struct { identity: []const u8 }, a, busy.stdout, .{ .ignore_unknown_fields = true });
            try std.Io.Dir.cwd().createDir(io, "/journal/busy", .fromMode(0o700));
            const request: proto.Plan = .{ .id = "busy", .version = proto.API_VERSION, .request = .{ .operation = .create, .filesystem = .vfat, .target = .{ .path = "/dev/vda", .identity = info.identity, .sector_size = 512, .kind = .physical } } };
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/journal/busy/request.json", .data = try std.json.Stringify.valueAlloc(a, request, .{}) });
            if (try execute(a, io, "/journal/busy/request.json", "/journal/busy", .none) != 256 or try exists(io, "/journal/busy/ready")) return error.MountedDeviceAccepted;
            try std.Io.Dir.cwd().createDirPath(io, "/same-recovery");
            if (linux.errno(linux.mount("/dev/pizza-independent2", "/same-recovery", "ext4", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, 0)) != .SUCCESS) return error.TestRecoveryMountFailed;
            try std.Io.Dir.cwd().createDir(io, "/same-recovery/job", .fromMode(0o700));
            const probe = try std.process.run(a, io, .{ .argv = &.{ "bin/pizza-maint", "--probe-device", "/dev/pizza-independent1" } });
            if (!probe.term.success()) return error.PartitionProbeFailed;
            const part = try std.json.parseFromSliceLeaky(struct { identity: []const u8 }, a, probe.stdout, .{ .ignore_unknown_fields = true });
            var same = request;
            same.id = "same_disk_recovery";
            same.request.?.target = .{ .path = "/dev/pizza-independent1", .identity = part.identity, .sector_size = test_sector, .kind = .physical };
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/journal/same-request.json", .data = try std.json.Stringify.valueAlloc(a, same, .{}) });
            if (try execute(a, io, "/journal/same-request.json", "/same-recovery/job", .none) != 256 or try exists(io, "/same-recovery/job/journal.bin") or try exists(io, "/same-recovery/job/ready")) return error.SameDiskRecoveryAccepted;
            if (linux.errno(linux.umount2("/same-recovery", 0)) != .SUCCESS) return error.TestUnmountFailed;
            std.log.info("PIZZA_PHYSICAL_ADMISSION_READY: mounted_target_and_same_disk_recovery_rejected", .{});
        }
    }
    var source: ?proto.wire.DeviceRef = null;
    if (!reading) {
        try std.Io.Dir.cwd().createDir(io, "/journal/source_job", .fromMode(0o700));
        source = try image(a, io, "/journal/source.raw", 256 * 1024 * 1024);
        const plan: proto.Plan = .{ .id = "source_format", .version = proto.API_VERSION, .request = .{ .operation = .create, .filesystem = if (test_sector == 4096) .ext4 else .vfat, .target = source.? } };
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/journal/source_plan.json", .data = try std.json.Stringify.valueAlloc(a, plan, .{}) });
        if (try execute(a, io, "/journal/source_plan.json", "/journal/source_job", .none) != 0) return error.SourceFormatFailed;
    }
    for (NAMES, 0..) |name, index| {
        const home = try a.print("/journal/{s}", .{name});
        const plan_path = try a.print("{s}/request.json", .{home});
        const path = try a.print("{s}/journal.bin", .{home});
        if (!reading) {
            try std.Io.Dir.cwd().createDir(io, home, .fromMode(0o700));
            var target = try image(a, io, try a.print("{s}/target.raw", .{home}), if (index == 2 or index == 4 or index == 5) 256 * 1024 * 1024 else 64 * 1024 * 1024);
            if (index == 1) target.identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            const copying = index == 2 or index == 4 or index == 5;
            const plan: proto.Plan = .{ .id = name, .version = proto.API_VERSION, .request = .{ .operation = if (copying) .copy else .create, .filesystem = if (copying) null else if (test_sector == 4096) .ext4 else .vfat, .source = if (copying) source else null, .target = target } };
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = plan_path, .data = try std.json.Stringify.valueAlloc(a, plan, .{}) });
        }
        const status = try execute(a, io, plan_path, home, if (reading) .none else if (index == 5) .cancel else if (index == 2 or index == 4) .kill else .none);
        const expected: i32 = if (!reading and index == 5) 33280 else if (!reading and (index == 2 or index == 4)) 9 else if (index == 1 or (reading and (index == 2 or index == 4 or index == 5))) 256 else 0;
        if (status != expected) return error.UnexpectedApplicationExit;
        if (!reading and index == 5) {
            if (!try exists(io, try a.print("{s}/restored", .{home}))) return error.CancellationRecoveryMissing;
            std.log.info("PIZZA_EXECUTOR_CANCELLED: recovered_before_exit", .{});
        }
        if (!reading and index == 3) {
            const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
            try file.setLength(io, (try file.stat(io)).size - 1);
            try file.sync(io);
            file.close(io);
        }
        if (index == 1) {
            if (try exists(io, path) or try exists(io, try a.print("{s}/ready", .{home}))) return error.IdentityGuardWroteJournal;
            std.log.info("PIZZA_EXECUTOR_IDENTITY_GUARD: before_target_writes", .{});
            continue;
        }
        const scan = try journal.readFile(a, io, path);
        if (index == 0 and (!scan.state.complete or scan.state.steps.count() == 0)) return error.BadSuccess;
        if (index == 1 and scan.state.steps.count() != 0) return error.IdentityGuardBypassed;
        if (index == 2 or index == 4 or index == 5) {
            if (try exists(io, try a.print("{s}/commit", .{home}))) return error.InterruptionTooLate;
            if (reading and !try exists(io, try a.print("{s}/restored", .{home}))) return error.RawRecoveryMissing;
        }
        if (index == 3 and scan.tail == .clean) return error.TornJournalNotDetected;
        std.log.info("PIZZA_EXECUTOR_CASE_READY: {s}; recovery={}", .{ name, reading });
    }
    if (!reading and !physical) try std.Io.Dir.cwd().deleteFile(io, "/journal/source.raw");
    if (linux.errno(linux.umount2("/journal", 0)) != .SUCCESS) return error.TestUnmountFailed;
    std.log.info("PIZZA_EXECUTOR_UNMOUNTED", .{});
    std.log.info("PIZZA_EXECUTOR_READY: {s}", .{if (reading) "read" else "write"});
}
