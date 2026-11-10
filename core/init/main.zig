const std = @import("std");
const linux = std.os.linux;
const bundle = @import("bundle");
const power = @import("power");
const cmdline = @import("cmdline.zig");
const mounts = @import("mounts.zig");
const modules = @import("modules.zig");
const supervisor = @import("supervisor.zig");
const recovery = @import("recovery.zig");
const emergency = @import("emergency.zig");
var panicking: bool = false;

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(message: []const u8, return_addr: ?usize) noreturn {
    if (linux.getpid() != 1) std.debug.defaultPanic(message, return_addr);
    if (@atomicRmw(bool, &panicking, .Xchg, true, .monotonic)) {
        emergency.write("PIZZA_RECURSIVE_PANIC: PID 1 emergency hold\n");
        supervisor.degraded();
    }
    emergency.write("PIZZA_MAINT_PANIC: ");
    emergency.write(message);
    emergency.write("\n");
    recovery.run(.rescue, .{});
}

/// RAM-only PID 1. Fatal failures request controlled reboot; unsuccessful
/// shutdown enters a supervised rescue console without retrying the plan.
pub fn main(init: std.process.Init) !void {
    if (linux.getpid() != 1) return error.NotPid1;
    supervisor.installSignals() catch |err| fail(err);
    power.configure() catch |err| fail(err);
    run(init.arena.allocator(), init.io) catch |err| fail(err);
    recovery.shutdown(.reboot);
}

fn fail(err: anyerror) noreturn {
    std.log.err("PIZZA_MAINT_DEGRADED: {t}; holding for explicit recovery", .{err});
    recovery.run(.rescue, .{});
}

fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    try mounts.setup(io);
    const line = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/cmdline", allocator, .limited(16 * 1024));
    defer allocator.free(line);
    const parameters = try cmdline.parse(line);
    // These settings are parsed now; their consumers belong to later phases.
    // No nonce, full command line or session identifier is written to the console.
    std.log.info("PIZZA_MAINT_CMDLINE_READY: boot={t}", .{parameters.boot});
    if (parameters.boot == .smoke) {
        std.log.info("PIZZA_MAINT_SMOKE_READY", .{});
        try power.poweroff();
    }
    const module_count = try modules.load(allocator, io);
    if (linux.errno(linux.chdir(bundle.PREFIX)) != .SUCCESS) return error.BundleWorkingDirectoryUnavailable;
    var root = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer root.close(io);
    const fs = @import("utils").filesystem;
    const kind = try fs.filesystemType(root);
    if (kind != fs.TMPFS_MAGIC and kind != fs.RAMFS_MAGIC) return error.BundleMustBeRam;
    std.log.info("PIZZA_MAINT_BUNDLE_CWD_READY", .{});
    if (parameters.boot == .selftest) {
        if (module_count == 0) return error.TestNeedsLoadableModule;
        try selftest(io);
        return;
    }
    if (parameters.boot == .backend_test or parameters.boot == .storage_test) {
        const storage_test = parameters.boot == .storage_test;
        const app = try supervisor.application(if (storage_test) .storage_test else .backend_test);
        while (true) {
            while (try supervisor.reap()) |child| {
                if (child.pid != app) continue;
                if (child.status != 0) {
                    std.log.err("Diagnostic application wait status={d}", .{child.status});
                    return error.BackendApplicationFailed;
                }
                if (storage_test)
                    std.log.info("PIZZA_INIT_STORAGE_CHILD_READY: application completed and reaped", .{})
                else
                    std.log.info("PIZZA_INIT_BACKEND_CHILD_READY: application completed and reaped", .{});
                try power.poweroff();
            }
            supervisor.sleep();
        }
    }
    // The v4 restart path is selected by a fixed firmware namespace, never by
    // an arbitrary command-line path. Its ordinary child authenticates the pin.
    if (std.Io.Dir.cwd().access(io, "/sys/firmware/efi/efivars/PizzaSession-137310f9-bc70-4fea-8571-1a1a3fca2c38", .{})) {
        const child = try supervisor.application(.restart_session);
        while (true) {
            while (try supervisor.reap()) |exited| {
                if (exited.pid != child) continue;
                if (exited.status != 0) {
                    std.log.err("PIZZA_RESTART_FAILED: child status={d}; recovery console; boot binding retained", .{exited.status});
                    // Rebooting with the retained maintenance-first lease would
                    // silently rerun startup. Hold for diagnosis or explicit recovery.
                    recovery.run(.rescue, .{});
                }
                std.log.info("PIZZA_RESTART_RETURN_READY", .{});
                recovery.shutdown(.reboot);
            }
            if (recovery.fromSignals(supervisor.takeSignals())) |request| recovery.run(request, .{});
            supervisor.sleep();
        }
    } else |err| if (err != error.FileNotFound) return err;
    const handoff = if (std.Io.Dir.cwd().access(io, "/etc/pizza/session.json", .{})) true else |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk false;
    };
    if (parameters.plan_id != null and !handoff) return error.MissingProtectedHandoff;
    if (parameters.boot == .reboot_test and !handoff) return error.MissingProtectedHandoff;
    const acceptance = parameters.boot == .reboot_test and acceptanceFile(io);
    var memory: @import("memory.zig").Peak = .{};
    if (acceptance) {
        const file = try std.Io.Dir.cwd().openFile(io, "/sys/block/vda/ro", .{});
        defer file.close(io);
        var buffer: [16]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const readonly = try reader.interface.allocRemaining(allocator, .limited(16));
        if (!std.mem.eql(u8, std.mem.trim(u8, readonly, "\r\n"), "1")) return error.OriginalDiskMustBeReadOnly;
        std.log.info("PIZZA_ORIGINAL_READONLY_READY: original disk is read-only at block layer", .{});
    }
    if (acceptance) try memory.sample(io);
    const application = try supervisor.application(if (acceptance) .session_test else if (handoff) .session else if (parameters.kiosk == .disabled) .no_ui else .ui);
    std.log.info("PIZZA_MAINT_READY: application PID {d}; static supervisor active", .{application});
    while (true) {
        if (acceptance) try memory.sample(io);
        while (try supervisor.reap()) |child| {
            if (child.pid == application and parameters.boot == .reboot_test) {
                if (child.status != 0) return error.TransitionApplicationFailed;
                if (acceptance) try memory.report(io);
                std.log.info("PIZZA_TRANSITION_MAINTENANCE_READY: real session completed and reaped", .{});
                try power.poweroff();
            }
            if (child.pid == application) {
                std.log.err("PIZZA_INIT_APPLICATION_EXITED: status={d}; controlled reboot; no automatic plan retry", .{child.status});
                recovery.shutdown(.reboot);
            } else std.log.info("Adopted child {d} exited: {d}", .{ child.pid, child.status });
        }
        if (recovery.fromSignals(supervisor.takeSignals())) |request|
            recovery.run(request, .{});
        supervisor.sleep();
    }
}

fn selftest(io: std.Io) !void {
    // This disk is a disposable QEMU fixture. Merely stat it; never open it for IO.
    const deadline = try supervisor.milliseconds() + 10000;
    while (true) {
        const device = std.Io.Dir.cwd().statFile(io, "/dev/vda", .{}) catch |err| {
            if (err != error.FileNotFound) return err;
            if (try supervisor.milliseconds() >= deadline) return error.TestBlockDeviceMissing;
            supervisor.sleep();
            continue;
        };
        if (device.kind != .block_device) return error.TestBlockDeviceMissing;
        break;
    }
    std.log.info("PIZZA_MAINT_DEVICE_READY: /dev/vda", .{});
    const probe = try supervisor.probe();
    const parent = try supervisor.orphan();
    const application = try supervisor.application(.test_exit);
    var application_done = false;
    var probe_done = false;
    var parent_done = false;
    var orphan_done = false;
    var signals: u32 = 0;
    const requested_signals: u32 = (@as(u32, 1) << (@backingInt(linux.SIG.TERM) - 1)) | (@as(u32, 1) << (@backingInt(linux.SIG.INT) - 1));
    if (linux.errno(linux.kill(linux.getpid(), .TERM)) != .SUCCESS or linux.errno(linux.kill(linux.getpid(), .INT)) != .SUCCESS)
        return error.TestSignalFailed;
    const start = try supervisor.milliseconds();
    while (true) {
        while (try supervisor.reap()) |child| {
            if (child.pid == application) {
                if (child.status != (17 << 8)) return error.TestApplicationDidNotFailAsExpected;
                application_done = true;
                std.log.info("PIZZA_INIT_APPLICATION_EXIT_OBSERVED: failed child reaped; PID 1 remains alive", .{});
                continue;
            }
            if (child.status != 0) return error.TestChildFailed;
            if (child.pid == probe) {
                probe_done = true;
                std.log.info("PIZZA_MAINT_DYNAMIC_PROBE_READY", .{});
            } else if (child.pid == parent) {
                parent_done = true;
            } else {
                orphan_done = true;
            }
        }
        signals |= supervisor.takeSignals();
        const elapsed = try supervisor.milliseconds() - start;
        if (application_done and probe_done and parent_done and orphan_done and signals & requested_signals == requested_signals and elapsed >= 3000) break;
        if (elapsed > 10000) return error.TestChildrenTimedOut;
        supervisor.sleep();
    }
    std.log.info("PIZZA_MAINT_REAPER_READY: child and adopted orphan collected", .{});
    std.log.info("PIZZA_MAINT_SIGNALS_READY: TERM and INT handled", .{});
    std.log.info("PIZZA_MAINT_SELFTEST_READY: supervisor alive for at least 3 seconds", .{});
    try power.poweroff();
}

fn acceptanceFile(io: std.Io) bool {
    std.Io.Dir.cwd().access(io, "/etc/pizza/acceptance", .{}) catch return false;
    return true;
}
