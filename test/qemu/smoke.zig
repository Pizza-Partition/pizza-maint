const std = @import("std");
const utils = @import("utils");
const initramfs = @import("initramfs");
const clap = @import("clap");
const h = @import("harness.zig");

const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--kernel <str>  Host kernel path (default: KERNEL or /boot/vmlinuz-linux).
    \\--binary <str>  Static PID 1 executable.
    \\--output <str>  VM output directory outside the checkout.
    \\--timeout <u32>  VM timeout in seconds (default: 90).
);

/// Parses subcommand arguments and boots a static maintenance PID 1 under QEMU/OVMF.
/// Requires the readiness and poweroff markers, then writes a JSON report; this checks smoke boot only.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    checkout_root: []const u8,
    argv: []const []const u8,
) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &PARAMS, clap.parsers.default, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
    }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return err;
    };
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tests smoke [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    }
    const kernel = try utils.filesystem.resolveOutputPath(
        allocator,
        io,
        checkout_root,
        parsed.args.kernel orelse environ.get("KERNEL") orelse "/boot/vmlinuz-linux",
    );
    const binary = try utils.filesystem.resolveOutputPath(
        allocator,
        io,
        checkout_root,
        (parsed.args.binary orelse "zig-out/bin/pizza-init"),
    );
    const kernel_stat = std.Io.Dir.cwd().statFile(io, kernel, .{}) catch return error.KernelOrStaticBinaryMissing;
    const binary_stat = std.Io.Dir.cwd().statFile(io, binary, .{}) catch return error.KernelOrStaticBinaryMissing;
    if (kernel_stat.kind != .file or binary_stat.kind != .file) {
        return error.KernelOrStaticBinaryMissing;
    }
    const meta = try utils.elf.metadata(allocator, io, binary);
    if (meta.interp.len > 0 or meta.needed.len > 0)
        return error.Pid1MustBeStatic;
    const output = if (parsed.args.output) |path| try utils.filesystem.resolveOutputPath(allocator, io, checkout_root, path) else try utils.filesystem.createTemporaryDirectory(allocator, io, "pizza-qemu-smoke-");
    if (utils.filesystem.pathIsWithin(checkout_root, output))
        return error.VmArtifactsMustBeOutsideCheckout;
    try std.Io.Dir.cwd().createDirPath(io, output);
    const initrd = try std.fs.path.join(
        allocator,
        &.{ output, "smoke.cpio.gz" },
    );
    try initramfs.staticInit(allocator, io, binary, initrd);
    var command = try h.baseCommand(allocator, io, environ, output, 1024);
    try command.appendSlice(
        &.{
            "-nic",
            "none",
            "-kernel",
            kernel,
            "-initrd",
            initrd,
            "-append",
            "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.boot=smoke",
            "-no-reboot",
        },
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(
            allocator,
            &.{ output, "command.json" },
        ),
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            command.items,
            .{ .whitespace = .indent_2 },
        ),
    });
    const serial = try h.runVm(
        allocator,
        io,
        environ,
        command.items,
        output,
        parsed.args.timeout orelse 90,
    );
    const result = .{
        .static_zig_pid1 = true,
        .marker = std.mem.indexOf(u8, serial, "PIZZA_MAINT_SMOKE_READY") != null,
        .powered_off = std.mem.indexOf(u8, serial, "Power down") != null,
        .artifacts = output,
    };
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(
            allocator,
            &.{ output, "results.json" },
        ),
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            result,
            .{ .whitespace = .indent_2 },
        ),
    });
    try std.Io.File.stdout().writeStreamingAll(
        io,
        try std.json.Stringify.valueAlloc(
            allocator,
            result,
            .{ .whitespace = .indent_2 },
        ),
    );
    if (!result.marker or !result.powered_off)
        return error.SmokeBootFailed;
}
