//! Ordinary maintenance application: business state and journal share one process.
const std = @import("std");
const clap = @import("clap");
const business = @import("maintenance").backend;
const proto = @import("proto");
const journal = @import("journal");
const plan_module = @import("maintenance").plan;
const tui = @import("execution_tui");
const session = @import("session");
const filesystem = @import("utils").filesystem;
var stop_requested: std.atomic.Value(bool) = .init(false);
fn requestStop(_: std.os.linux.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}
fn installStopSignals() !void {
    const linux = std.os.linux;
    const action: linux.Sigaction = .{ .handler = .{ .handler = requestStop }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .INT, .TERM }) |signal|
        if (linux.errno(linux.sigaction(signal, &action, null)) != .SUCCESS) return error.SignalSetupFailed;
}

const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--restart-session  Execute the firmware-authenticated v4 restart handoff.
    \\--session  Use the protected reboot handoff; mount its journal and execute once.
    \\--plan <str>  Validated v2 storage operation request JSON.
    \\--journal <str>  Journal to display and replay.
    \\--execute  Execute a storage request; recover an interrupted transaction before new work.
    \\--journal-home <str>  Existing trusted directory on ext4, XFS or Btrfs for new execution.
    \\--exit-after-plan  Exit when execution stops (requires execution).
    \\--no-ui  Disable interface output and keep console diagnostics.
    \\--tui  Require a libvaxis dashboard on the controlling terminal (default: auto).
    \\--no-tui  Keep line-oriented console output instead of a terminal dashboard.
    \\--tui-self-test  Draw and verify a real libvaxis terminal frame, then exit.
    \\--self-test  Verify business state and journal replay, then exit.
    \\--probe  Print read-only system memory and block-device geometry as JSON.
    \\--probe-device <str>  Read a physical device's stable identity, geometry and partitions.
    \\--storage-memory  Print detected adaptive memory budgets and fixed safety reserve.
    \\--storage-capabilities  Print filesystem driver implementation and validation status.
    \\--reboot-self-test  Verify a protected disposable VM session and journal replay.
    \\--timeout <u32>  Self-test timeout in seconds (default: 30).
    \\--test-exit  Exit unsuccessfully during startup (VM supervisor fixture).
);

pub fn main(init: std.process.Init) !u8 {
    if (std.os.linux.getpid() == 1) return error.ApplicationMustNotBePid1;
    return runWithDevices(init, .{}) catch |err| {
        std.log.err("Maintenance application: {t}", .{err});
        return 1;
    };
}
/// Alternate device factories are supplied by separately built test entry points.
pub fn runWithDevices(init: std.process.Init, devices: @import("maintenance").devices.Provider) !u8 {
    const a = init.arena.allocator();
    var parsed = try clap.parse(clap.Help, &PARAMS, clap.parsers.default, init.minimal.args, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: pizza-maint [options]\n");
        try clap.helpToFile(init.io, .stdout(), clap.Help, &PARAMS, .{});
        return 0;
    }
    if (parsed.args.@"restart-session" != 0) {
        if ((try init.minimal.args.toSlice(a)).len != 2) return error.SessionConflictsWithOverrides;
        try @import("restart").run(a, init.io);
        return 0;
    }
    if (parsed.args.@"probe-device") |path| {
        if ((try init.minimal.args.toSlice(a)).len != 3) return error.ConflictingProbeOptions;
        const storage = @import("maintenance").storage;
        var block = try storage.block_device.BlockDevice.open(a, init.io, path, null, null, .probe);
        defer block.close(init.io);
        var info = try storage.probe.queryDevice(a, init.io, path, block.backend().reader());
        info.physical_block_size = block.evidence.physical;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.json.Stringify.valueAlloc(a, info, .{ .whitespace = .indent_2 }));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return 0;
    }
    if (parsed.args.probe != 0 or parsed.args.@"storage-memory" != 0 or parsed.args.@"storage-capabilities" != 0) {
        const argv = try init.minimal.args.toSlice(a);
        if (argv.len != 2) return error.ConflictingProbeOptions;
        const probe = @import("maintenance").storage.probe;
        if (parsed.args.probe != 0)
            try probe.printSystem(a, init.io)
        else if (parsed.args.@"storage-memory" != 0)
            try probe.printMemory(init.io)
        else
            try probe.printCapabilities(a, init.io);
        return 0;
    }
    var startup_budget = try @import("maintenance").storage.memory.Controller.init(init.io, .{});
    const acceptance = parsed.args.@"reboot-self-test" != 0;
    if (acceptance) {
        if (parsed.args.session == 0 or parsed.args.@"no-tui" == 0) return error.AcceptanceNeedsProtectedSession;
        try std.Io.Dir.cwd().access(init.io, "/etc/pizza/acceptance", .{});
    }
    const self_test = parsed.args.@"self-test" != 0 or acceptance;
    var request: ?session.Request = null;
    if (parsed.args.session != 0) {
        if (parsed.args.execute != 0 or parsed.args.plan != null or parsed.args.journal != null or parsed.args.@"journal-home" != null or parsed.args.@"self-test" != 0 or parsed.args.@"test-exit" != 0) return error.SessionConflictsWithOverrides;
        var protected = try session.storage.openTrusted(init.io, "/etc/pizza");
        defer protected.close(init.io);
        try session.storage.trustedFile(init.io, protected, "session.json");
        try session.storage.trustedFile(init.io, protected, "plan.json");
        request = try std.json.parseFromSliceLeaky(session.Request, a, try protected.readFileAlloc(init.io, "session.json", a, .limited(16 * 1024)), .{});
        try request.?.validate();
        if (acceptance and !request.?.test_poweroff) return error.AcceptanceNeedsProtectedSession;
        const bytes = try protected.readFileAlloc(init.io, "plan.json", a, .limited(1024 * 1024));
        if (!std.mem.eql(u8, request.?.plan_sha256, try session.digest(a, bytes))) return error.HandoffPlanChanged;
    }
    const no_ui = (parsed.args.@"no-ui" != 0 or (if (request) |r| r.no_ui else false));
    const exit_after_plan = parsed.args.@"exit-after-plan" != 0 or (if (request) |r| r.test_poweroff else false);
    if (parsed.args.@"test-exit" != 0) return 17;
    if (parsed.args.tui != 0 and (parsed.args.@"no-tui" != 0 or no_ui)) return error.ConflictingTerminalOptions;
    if (parsed.args.@"tui-self-test" != 0 and (parsed.args.execute != 0 or parsed.args.@"self-test" != 0 or parsed.args.@"no-tui" != 0 or no_ui)) return error.ConflictingSelfTests;
    const force_tui = parsed.args.tui != 0 or parsed.args.@"tui-self-test" != 0;
    const dashboard = if (!no_ui and parsed.args.@"no-tui" == 0 and (parsed.args.@"self-test" == 0 or force_tui)) tui.Dashboard.open(a, init.io, init.environ_map, force_tui) catch |err| blk: {
        if (force_tui) return err;
        std.log.warn("Terminal dashboard unavailable: {t}; using console lines", .{err});
        break :blk null;
    } else null;
    defer if (dashboard) |value| value.close();
    if (parsed.args.@"tui-self-test" != 0) {
        const value = dashboard orelse return error.NoInteractiveTerminal;
        try value.selfTest();
        value.close();
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"libvaxis\":true,\"frame_verified\":true,\"progress\":\"7/20\"}\n");
        return 0;
    }
    const executing = parsed.args.execute != 0 or request != null;
    if (exit_after_plan and !executing) return error.ExitAfterPlanNeedsExecution;
    const execution_options: plan_module.Options = .{ .devices = devices, .console = dashboard == null };
    if (executing) try installStopSignals();
    try execution_options.validate();
    if (!executing and (parsed.args.@"journal-home" != null or parsed.args.@"exit-after-plan" != 0)) return error.ExecutionOptionNeedsExecute;
    if (executing and parsed.args.journal != null) return error.ExecutionConflictsWithReadOnlyJournal;
    var plan: ?proto.Plan = null;
    if (parsed.args.plan orelse if (request != null) @as(?[]const u8, session.PLAN_PATH) else null) |path| {
        plan = try std.json.parseFromSliceLeaky(proto.Plan, a, try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(1024 * 1024)), .{});
        try business.validatePlan(plan.?);
    }
    if (request) |r| if (plan == null or !std.mem.eql(u8, r.plan_id, plan.?.id)) return error.HandoffPlanMismatch;
    var persistent: ?session.storage.Mounted = null;
    defer if (persistent) |*home| {
        if (home.marker.status == .running) home.mark(a, init.io, .interrupted) catch |err| std.log.err("Session finalization: {t}", .{err});
        home.close(init.io);
    };
    if (request) |r| persistent = try session.storage.mount(a, init.io, r);
    var journal_path = parsed.args.journal;
    var executor: ?*plan_module.Executor = null;
    defer if (executor) |value| value.close(init.io);
    if (executing) {
        const actual_plan = plan orelse return error.MissingExecutionPlan;
        const home = try std.Io.Dir.cwd().realPathFileAlloc(init.io, (if (persistent) |home| home.path else parsed.args.@"journal-home" orelse return error.MissingJournalHome), a);
        var directory = try std.Io.Dir.cwd().openDir(init.io, home, .{ .follow_symlinks = false });
        defer directory.close(init.io);
        const kind = try @import("utils").filesystem.filesystemType(directory);
        if (kind != filesystem.EXT4_SUPER_MAGIC and kind != filesystem.XFS_SUPER_MAGIC and kind != filesystem.BTRFS_SUPER_MAGIC) return error.JournalHomeMustBePersistent;
        const anchor = try journal.captureBoundary(a, init.io, .{ .state = .start, .boot_id = "", .utc_unix_ns = "", .plan_id = actual_plan.id, .home = .{ .kind = .other_device, .path = home, .device_uuid = if (request) |r| r.home.uuid else null, .device_path = if (request) |r| r.home.path else null } });
        const value = try a.create(plan_module.Executor);
        value.* = try plan_module.Executor.start(a, init.io, directory, actual_plan, anchor.boundary, anchor.monotonic_ns, execution_options);
        executor = value;
        journal_path = try std.fs.path.join(a, &.{ home, "journal.bin" });
    }
    var fixture: ?[]const u8 = null;
    defer if (fixture) |path| std.Io.Dir.cwd().deleteTree(init.io, path) catch {};
    if (parsed.args.@"self-test" != 0 and journal_path == null and !executing) {
        fixture = try @import("utils").filesystem.createTemporaryDirectory(a, init.io, "pizza-backend-fixture-");
        var directory = try std.Io.Dir.cwd().openDir(init.io, fixture.?, .{});
        defer directory.close(init.io);
        const steps = try a.alloc(proto.wire.Step, 20);
        for (steps, 0..) |*step, index| step.* = .{ .id = @intCast(index + 1), .label = "Backend diagnostic", .simulated = true };
        plan = .{ .id = "backend_selftest", .version = proto.API_VERSION, .steps = steps };
        const anchor = try journal.captureBoundary(a, init.io, .{ .state = .start, .boot_id = "", .utc_unix_ns = "", .plan_id = plan.?.id, .home = .{ .kind = .root_path, .path = fixture.? } });
        var writer = try journal.Writer.create(a, init.io, directory, anchor.boundary, anchor.monotonic_ns, .{});
        defer writer.close(init.io);
        _ = try writer.intent(init.io, 1, try journal.monotonicNow(init.io), "backend fixture intent");
        _ = try writer.commit(init.io, 1, try journal.monotonicNow(init.io), "backend fixture commit");
        _ = try writer.intent(init.io, 2, try journal.monotonicNow(init.io), "unfinished fixture step");
        for (0..130) |_| _ = try writer.note(init.io, 2, try journal.monotonicNow(init.io), "native replay fixture");
        journal_path = try std.fs.path.join(a, &.{ fixture.?, "journal.bin" });
    }
    var backend = business.Backend.init(a, plan, journal_path);
    backend.executor = executor;
    if (persistent) |*home| backend.journal_home = home;
    backend.dashboard = dashboard;
    defer backend.deinit();
    try backend.refresh(init.io);
    const started = try journal.monotonicNow(init.io);
    std.log.info("PIZZA_MEMORY_BUDGET: cache={d} reserve={d} work={d} recovery={d}", .{ startup_budget.budget.cache_bytes, startup_budget.budget.reserve, startup_budget.budget.work_reserve, startup_budget.budget.recovery_reserve });
    std.log.info("PIZZA_MAINT_BACKEND_READY: execute={}", .{executing});
    while (true) {
        if (stop_requested.load(.monotonic)) {
            backend.cancelled = true;
            if (executor) |value| value.cancel();
        }
        try startup_budget.check();
        backend.tick(init.io) catch |err| if (err != error.WouldBlock) std.log.err("Journal view: {t}", .{err});
        if (backend.cancelled and (if (executor) |value| value.terminal() else true)) return 130;
        if (self_test and (if (executor) |value| value.terminal() else true)) {
            const evidence = try replayEvidence(a, &backend);
            if (acceptance) {
                try std.Io.File.stdout().writeStreamingAll(init.io, try a.print("PIZZA_BACKEND_ACCEPTANCE_JSON:{s}\n", .{evidence}));
            } else {
                try std.Io.File.stdout().writeStreamingAll(init.io, try a.print("PIZZA_BACKEND_SELFTEST_READY:{s}\n", .{evidence}));
            }
            return if (executor) |value| (if (value.status == .succeeded) @as(u8, 0) else 1) else 0;
        }
        if (self_test and try journal.monotonicNow(init.io) - started > @as(u64, parsed.args.timeout orelse 30) * std.time.ns_per_s) return error.BackendSelfTestTimedOut;
        if (exit_after_plan and executor.?.terminal()) return if (executor.?.status == .succeeded) 0 else 1;
        try std.Io.sleep(init.io, .fromMilliseconds(if (executing) 10 else if (backend.dashboard != null) 50 else 1000), .awake);
    }
}

/// Validate batched backend replay and report only facts observed without a GUI.
fn replayEvidence(a: std.mem.Allocator, backend: *const business.Backend) ![]const u8 {
    var after: u64 = 0;
    var commits: std.ArrayList([]const u8) = .empty;
    while (true) {
        const batch = try backend.events(a, after);
        const events = try std.json.parseFromSliceLeaky([]const proto.Event, a, batch.json, .{});
        if (events.len == 0) break;
        for (events) |event| {
            const seq = try std.fmt.parseInt(u64, event.seq, 10);
            if (seq != after + 1) return error.NonMonotonicReplay;
            after = seq;
            if (event.phase == .commit) try commits.append(a, event.seq);
        }
        if (batch.last != after) return error.ReplayCursorMismatch;
    }
    if (after != backend.lastSequence()) return error.IncompleteReplay;
    return std.json.Stringify.valueAlloc(a, .{ .backend_replay_correct = true, .step_events = commits.items.len, .event_sequences = commits.items, .execution = backend.execution(), .last_seq = after }, .{});
}
