//! Two independent VM boots against one disposable ext4 journal disk.
const std = @import("std");
const utils = @import("utils");
const initramfs = @import("initramfs");
const journal = @import("journal");
const clap = @import("clap");
const h = @import("harness.zig");
const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--binary <str>  Static journal fixture PID 1 (supplied by zig build test-journal).
    \\--kernel <str>  Kernel with built-in virtio/ext4 (default: KERNEL or /boot/vmlinuz-linux).
    \\--output <str>  New VM output directory outside the checkout.
    \\--timeout <u32>  Timeout per boot, seconds (default: 90).
);

pub fn run(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, checkout: []const u8, argv: []const []const u8) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var parsed = try clap.parseEx(clap.Help, &PARAMS, clap.parsers.default, &iter, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    const binary = try utils.filesystem.resolveOutputPath(a, io, checkout, parsed.args.binary orelse return error.MissingJournalFixture);
    const meta = try utils.elf.metadata(a, io, binary);
    if (meta.interp.len != 0 or meta.needed.len != 0) return error.Pid1MustBeStatic;
    const kernel = try utils.filesystem.resolveOutputPath(a, io, checkout, parsed.args.kernel orelse env.get("KERNEL") orelse "/boot/vmlinuz-linux");
    const output = if (parsed.args.output) |p| try utils.filesystem.resolveOutputPath(a, io, checkout, p) else try utils.filesystem.createTemporaryDirectory(a, io, "pizza-qemu-journal-");
    if (utils.filesystem.pathIsWithin(checkout, output)) return error.VmArtifactsMustBeOutsideCheckout;
    try std.Io.Dir.cwd().createDirPath(io, output);
    const extracted = try std.fs.path.join(a, &.{ output, "journal.bin" });
    // debugfs has its own command grammar; reject metacharacters in that argument.
    for (extracted) |c| if (std.ascii.isWhitespace(c) or c == '"' or c == '\\' or c == ';') return error.DebugfsPathUnsupported;
    _ = try utils.process.findExecutable(a, io, env, "mkfs.ext4");
    _ = try utils.process.findExecutable(a, io, env, "debugfs");
    const image = try std.fs.path.join(a, &.{ output, "journal-init.cpio.gz" });
    try initramfs.staticInit(a, io, binary, image);
    const disk = try std.fs.path.join(a, &.{ output, "journal.raw" });
    try h.noComma(disk);
    {
        const file = try std.Io.Dir.cwd().createFile(io, disk, .{ .exclusive = true });
        defer file.close(io);
        try file.setLength(io, 32 * 1024 * 1024);
    }
    _ = try utils.process.checkedOutput(a, io, env, &.{ "mkfs.ext4", "-q", "-F", "-m", "0", disk });
    inline for (.{ "write", "read" }) |mode| {
        const directory = try std.fs.path.join(a, &.{ output, mode });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        var command = try h.baseCommand(a, io, env, directory, 1024);
        try command.appendSlice(&.{ "-nic", "none", "-kernel", kernel, "-initrd", image, "-append", try a.print("console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.journal_test={s}", .{mode}), "-drive", try a.print("if=virtio,format=raw,file={s}", .{disk}), "-no-reboot" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ directory, "command.json" }), .data = try std.json.Stringify.valueAlloc(a, command.items, .{ .whitespace = .indent_2 }) });
        const serial = try h.runVm(a, io, env, command.items, directory, parsed.args.timeout orelse 90);
        const marker = if (comptime std.mem.eql(u8, mode, "write")) "PIZZA_JOURNAL_WRITE_READY" else "PIZZA_JOURNAL_RECOVERY_READY";
        if (!has(serial, marker) or !has(serial, "PIZZA_JOURNAL_UNMOUNTED") or !has(serial, "Power down") or has(serial, "PIZZA_JOURNAL_TEST_FAILED") or has(serial, "Kernel panic")) return error.JournalBootFailed;
    }
    _ = try utils.process.checkedOutput(a, io, env, &.{ "debugfs", "-R", try a.print("dump /journal.bin {s}", .{extracted}), disk });
    const recovered = try journal.readFile(a, io, extracted);
    if (recovered.tail != .clean or recovered.state.seq != 8 or recovered.state.steps.get(1).?.state != .succeeded or recovered.state.steps.get(2).?.state != .failed or recovered.state.steps.get(3).?.state != .in_flight) return error.JournalDiskRecoveryFailed;
    const result = .{ .two_boots = true, .distinct_boot_ids = true, .fsync_and_directory_sync = true, .sequence_continued = true, .succeeded = true, .failed = true, .in_flight = true, .clean_tail = true, .artifacts = output };
    const json = try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ output, "results.json" }), .data = json });
    try std.Io.File.stdout().writeStreamingAll(io, json);
}
fn has(bytes: []const u8, value: []const u8) bool {
    return std.mem.indexOf(u8, bytes, value) != null;
}
