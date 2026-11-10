//! Full bundle, live backend execution and five persisted fault outcomes across boots.
const std = @import("std");
const utils = @import("utils");
const initramfs = @import("initramfs");
const journal = @import("journal");
const clap = @import("clap");
const harness = @import("harness.zig");
const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--physical  Use exclusively claimed virtio block devices and the production application.
    \\--sector-size <u32>  Physical test logical sector size (512 or 4096).
    \\--fixture <str>  Static executor fixture PID 1 (supplied by zig build).
    \\--application <str>  Maintenance entry point supplied by the build.
    \\--report-binary <str>  Maintenance journal tool (supplied by zig build).
    \\--bundle <str>  Current prepared full bundle (default: zig-out/runtime/bundle).
    \\--kernel-version <str>  Bundled kernel release.
    \\--kernel <str>  Kernel path (default: BUNDLE/vmlinuz).
    \\--output <str>  New output directory outside the checkout.
    \\--timeout <u32>  Timeout per boot in seconds (default: 180).
);
pub fn run(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, checkout: []const u8, argv: []const []const u8) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var parsed = try clap.parseEx(clap.Help, &PARAMS, clap.parsers.default, &iter, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    const physical = parsed.args.physical != 0;
    const sector = parsed.args.@"sector-size" orelse 512;
    if (sector != 512 and sector != 4096) return error.InvalidSectorSize;
    const fixture = parsed.args.fixture orelse return error.MissingExecutorFixture;
    const application_binary = parsed.args.application orelse return error.MissingMaintenanceFixture;
    const report = parsed.args.@"report-binary" orelse return error.MissingReportBinary;
    const version = parsed.args.@"kernel-version" orelse return error.MissingKernelVersion;
    try utils.filesystem.checkPath(version);
    if (std.mem.indexOfScalar(u8, version, '/') != null) return error.InvalidKernelVersion;
    const meta = try utils.elf.metadata(a, io, fixture);
    if (meta.interp.len != 0 or meta.needed.len != 0) return error.Pid1MustBeStatic;
    const kernel = try utils.filesystem.resolveOutputPath(a, io, checkout, parsed.args.kernel orelse try std.fs.path.join(a, &.{ parsed.args.bundle orelse "zig-out/runtime/bundle", "vmlinuz" }));
    const output = if (parsed.args.output) |p| try utils.filesystem.resolveOutputPath(a, io, checkout, p) else try utils.filesystem.createTemporaryDirectory(a, io, "pizza-qemu-executor-");
    if (utils.filesystem.pathIsWithin(checkout, output)) return error.VmArtifactsMustBeOutsideCheckout;
    // debugfs -R has its own command grammar.
    for (output) |c| if (std.ascii.isWhitespace(c) or c == '"' or c == '\\' or c == ';') return error.DebugfsPathUnsupported;
    try std.Io.Dir.cwd().createDirPath(io, output);
    const base = try std.fs.path.join(a, &.{ output, "bundle.cpio.gz" });
    _ = try initramfs.build(a, io, env, checkout, .{ .bundle = parsed.args.bundle orelse "zig-out/runtime/bundle", .output = base, .kernel_version = version });
    const overlay = try std.fs.path.join(a, &.{ output, "fixture.cpio.gz" });
    try initramfs.staticInit(a, io, fixture, overlay);
    const image = try std.fs.path.join(a, &.{ output, "executor.cpio.gz" });
    try std.Io.Dir.cwd().copyFile(base, .cwd(), image, io, .{});
    {
        const file = try std.Io.Dir.cwd().openFile(io, image, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, try std.Io.Dir.cwd().readFileAlloc(io, overlay, a, .limited(32 * 1024 * 1024)), (try file.stat(io)).size);
        // Only this disposable VM image uses the test entry point. The bundle
        // and the installed production binary remain unchanged.
        const application_overlay = try initramfs.archive(a, &.{
            .{ .name = "opt", .mode = 0o040755 },
            .{ .name = "opt/pizza", .mode = 0o040755 },
            .{ .name = "opt/pizza/bundle", .mode = 0o040755 },
            .{ .name = "opt/pizza/bundle/bin", .mode = 0o040755 },
            .{ .name = "opt/pizza/bundle/bin/pizza-maint", .mode = 0o100755, .data = try std.Io.Dir.cwd().readFileAlloc(io, application_binary, a, .limited(128 * 1024 * 1024)) },
        });
        try file.writePositionalAll(io, application_overlay, (try file.stat(io)).size);
    }
    const disk = try std.fs.path.join(a, &.{ output, "journal.raw" });
    try harness.noComma(disk);
    {
        const file = try std.Io.Dir.cwd().createFile(io, disk, .{ .exclusive = true });
        defer file.close(io);
        try file.setLength(io, 2 * 1024 * 1024 * 1024);
    }
    _ = try utils.process.checkedOutput(a, io, env, &.{ "mkfs.ext4", "-q", "-F", "-m", "0", disk });
    const physical_names = [_][]const u8{ "source", "success", "identity", "killed", "journal", "source_removed", "cancelled", "independent" };
    if (physical) for (physical_names) |name| {
        const file = try std.Io.Dir.cwd().createFile(io, try a.print("{s}/target-{s}.raw", .{ output, name }), .{ .exclusive = true });
        defer file.close(io);
        const large = std.mem.eql(u8, name, "source") or std.mem.eql(u8, name, "killed") or std.mem.eql(u8, name, "source_removed") or std.mem.eql(u8, name, "cancelled");
        try file.setLength(io, @as(u64, if (large) 256 else 64) * 1024 * 1024);
    };
    if (physical) {
        const path = try a.print("{s}/target-independent.raw", .{output});
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        var mbr: [512]u8 = @splat(0);
        std.mem.writeInt(u16, mbr[510..512], 0xaa55, .little);
        for ([_]u32{ 1048576, 33554432 }, 0..) |start, i| {
            const entry = mbr[446 + i * 16 ..][0..16];
            entry[4] = 0x83;
            std.mem.writeInt(u32, entry[8..12], @divExact(start, sector), .little);
            std.mem.writeInt(u32, entry[12..16], @divExact(@as(u32, if (i == 0) 16777216 else 33554432), sector), .little);
        }
        try file.writePositionalAll(io, &mbr, 0);
        try file.sync(io);
        _ = try utils.process.checkedOutput(a, io, env, &.{ "mkfs.ext4", "-q", "-F", "-b", "4096", "-m", "0", "-E", "offset=33554432", path, "8192" });
    }
    var serials: [2][]const u8 = undefined;
    for ([_][]const u8{ "write", "read" }, 0..) |mode, index| {
        const directory = try std.fs.path.join(a, &.{ output, mode });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        var command = try harness.baseCommand(a, io, env, directory, 4096);
        try command.appendSlice(&.{ "-nic", "none", "-kernel", kernel, "-initrd", image, "-append", try a.print("console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.executor_test={s} pizza.physical_test={d}", .{ mode, if (physical) sector else @as(u32, 0) }), "-drive", try a.print("if=none,id=recovery,format=raw,file={s}", .{disk}), "-device", "virtio-blk-pci,drive=recovery,serial=pz-recovery", "-no-reboot" });
        if (physical) for (physical_names, 0..) |name, disk_index| {
            if (index == 1 and std.mem.eql(u8, name, "source")) continue;
            try command.appendSlice(&.{ "-drive", try a.print("if=none,id=test{d},format=raw,file={s}/target-{s}.raw", .{ disk_index, output, name }), "-device", try a.print("virtio-blk-pci,drive=test{d},serial=pz-{s},logical_block_size={d},physical_block_size={d}", .{ disk_index, name, sector, sector }) });
        };
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ directory, "command.json" }), .data = try std.json.Stringify.valueAlloc(a, command.items, .{ .whitespace = .indent_2 }) });
        const serial = try harness.runVm(a, io, env, command.items, directory, parsed.args.timeout orelse 180);
        serials[index] = serial;
        if (!has(serial, try a.print("PIZZA_EXECUTOR_READY: {s}", .{mode})) or !has(serial, "PIZZA_EXECUTOR_UNMOUNTED") or !has(serial, "Power down") or has(serial, "PIZZA_EXECUTOR_TEST_FAILED") or has(serial, "Kernel panic")) return error.ExecutorBootFailed;
    }
    if (!has(serials[0], "PIZZA_EXECUTOR_CANCELLED: recovered_before_exit")) return error.CancellationNotTested;
    if (!has(serials[0], "PIZZA_EXECUTOR_IDENTITY_GUARD: before_target_writes")) return error.IdentityGuardBypassed;
    if (physical and !has(serials[0], "PIZZA_PHYSICAL_ADMISSION_READY")) return error.PhysicalAdmissionNotTested;
    if (!has(serials[0], "PIZZA_PLAN_STATE succeeded committed=")) return error.LiveExecutionBackendFailed;
    const names = [_][]const u8{ "success", "identity", "killed", "journal", "source_removed", "cancelled" };
    for (names, 0..) |name, index| {
        if (index == 1) continue;
        const extracted = try a.print("{s}/{s}.journal.bin", .{ output, name });
        _ = try utils.process.checkedOutput(a, io, env, &.{ "debugfs", "-R", try a.print("dump /{s}/journal.bin {s}", .{ name, extracted }), disk });
        const value = try journal.readFile(a, io, extracted);
        if (index == 0 and (!value.state.complete or value.state.steps.count() == 0)) return error.BadSuccess;
        if (index == 1 and value.state.steps.count() != 0) return error.IdentityGuardBypassed;
        if (index == 3 and value.tail == .clean) return error.BadTornTail;
        const before = try utils.filesystem.hashFileSha256(a, io, extracted);
        const json = try utils.process.checkedOutput(a, io, env, &.{ report, "report", extracted });
        _ = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}/{s}.report.json", .{ output, name }), .data = json });
        if (!std.mem.eql(u8, before, try utils.filesystem.hashFileSha256(a, io, extracted))) return error.ReportChangedJournal;
    }
    if (physical) {
        for ([_][]const u8{ "success", "journal" }) |name| {
            const path = try a.print("{s}/target-{s}.raw", .{ output, name });
            const check = if (sector == 4096) try utils.process.checkedOutput(a, io, env, &.{ "e2fsck", "-f", "-n", path }) else try utils.process.checkedOutput(a, io, env, &.{ "fsck.fat", "-n", path });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}/{s}.fsck.txt", .{ output, name }), .data = check });
        }
    }
    const result = .{ .physical_devices = physical, .logical_sector_size = sector, .live_backend_execution = true, .real_storage_steps = true, .identity_guard = true, .sigkill_interrupted = true, .cancelled_and_recovered = true, .recovery_without_clone_source = true, .torn_tail = true, .two_boots = true, .no_automatic_retry = true, .read_only_report = true, .artifacts = output };
    const json = try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ output, "results.json" }), .data = json });
    try std.Io.File.stdout().writeStreamingAll(io, json);
}
fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}
