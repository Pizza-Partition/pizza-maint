//! Phase 3 acceptance: boot the layered initramfs with a disposable virtio disk.
const std = @import("std");
const utils = @import("utils");
const initramfs = @import("initramfs");
const clap = @import("clap");
const h = @import("harness.zig");

const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--backend  Boot the business backend test instead of supervisor diagnostics.
    \\--storage  Verify native primitives on disposable private images; no filesystem adapters.
    \\--storage-binary <str>  Standalone static self-test (default: zig-out/bin/pizza-storage-test).
    \\--bundle <str>  Prepared full bundle (default: zig-out/runtime/bundle).
    \\--kernel-version <str>  Bundled kernel release (required).
    \\--kernel <str>  Kernel path (default: BUNDLE/vmlinuz).
    \\--output <str>  VM output directory outside the checkout.
    \\--timeout <u32>  VM timeout in seconds (default: 120).
);

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, checkout_root: []const u8, argv: []const []const u8) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var parsed = try clap.parseEx(clap.Help, &PARAMS, clap.parsers.default, &iter, .{ .allocator = allocator });
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tests maintenance [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    }
    if (parsed.args.backend != 0 and parsed.args.storage != 0) return error.ConflictingMaintenanceTests;
    const version = parsed.args.@"kernel-version" orelse return error.MissingKernelVersion;
    try utils.filesystem.checkPath(version);
    if (std.mem.indexOfScalar(u8, version, '/') != null) return error.InvalidKernelVersion;
    const kernel = try utils.filesystem.resolveOutputPath(allocator, io, checkout_root, parsed.args.kernel orelse try std.fs.path.join(allocator, &.{ parsed.args.bundle orelse "zig-out/runtime/bundle", "vmlinuz" }));
    const kernel_stat = try std.Io.Dir.cwd().statFile(io, kernel, .{});
    if (kernel_stat.kind != .file) return error.KernelMissing;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, parsed.args.bundle orelse "zig-out/runtime/bundle", allocator);
    const output = if (parsed.args.output) |path| try utils.filesystem.resolveOutputPath(allocator, io, checkout_root, path) else try utils.filesystem.createTemporaryDirectory(allocator, io, "pizza-qemu-maintenance-");
    if (utils.filesystem.pathIsWithin(checkout_root, output)) return error.VmArtifactsMustBeOutsideCheckout;
    try std.Io.Dir.cwd().createDirPath(io, output);
    const image = try std.fs.path.join(allocator, &.{ output, "maintenance.cpio.gz" });
    _ = try initramfs.build(allocator, io, environ, checkout_root, .{
        .bundle = root,
        .output = image,
        .kernel_version = version,
    });
    if (parsed.args.storage != 0) {
        const binary = try utils.filesystem.resolveOutputPath(allocator, io, checkout_root, parsed.args.@"storage-binary" orelse "zig-out/bin/pizza-storage-test");
        const metadata = try utils.elf.metadata(allocator, io, binary);
        if (metadata.interp.len != 0 or metadata.needed.len != 0) return error.StorageTestMustBeStatic;
        // Only this test image receives the harness; the production bundle stays clean.
        const layer = try initramfs.archive(allocator, &.{.{
            .name = "pizza-storage-test",
            .mode = 0o100755,
            .data = try std.Io.Dir.cwd().readFileAlloc(io, binary, allocator, .limited(128 * 1024 * 1024)),
        }});
        const output_image = try std.Io.Dir.cwd().openFile(io, image, .{ .mode = .read_write });
        defer output_image.close(io);
        try output_image.writePositionalAll(io, layer, (try output_image.stat(io)).size);
        try output_image.sync(io);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try allocator.print("{s}.pizza.json", .{image}),
            .data = try std.json.Stringify.valueAlloc(allocator, .{
                .version = @as(u16, 1),
                .development = true,
                .kernel_version = version,
                .image_sha256 = try utils.filesystem.hashFileSha256(allocator, io, image),
                .storage_test_sha256 = try utils.filesystem.hashFileSha256(allocator, io, binary),
            }, .{ .whitespace = .indent_2 }),
        });
    }
    const disk = try std.fs.path.join(allocator, &.{ output, "device.raw" });
    try h.noComma(disk);
    const file = try std.Io.Dir.cwd().createFile(io, disk, .{ .exclusive = true });
    defer file.close(io);
    try file.setLength(io, 16 * 1024 * 1024);
    var command = try h.baseCommand(allocator, io, environ, output, 4096);
    try command.appendSlice(&.{
        "-nic",    "none",                                                                                                                                                                                                                                                                                                        "-kernel", kernel,                                                                    "-initrd",    image,
        "-append", if (parsed.args.storage != 0) "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.boot=storage_test" else if (parsed.args.backend != 0) "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.boot=backend_test" else "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.boot=selftest pizza.kiosk=disable", "-drive",  try allocator.print("if=virtio,format=raw,readonly=on,file={s}", .{disk}), "-no-reboot",
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ output, "command.json" }), .data = try std.json.Stringify.valueAlloc(allocator, command.items, .{ .whitespace = .indent_2 }) });
    const serial = try h.runVm(allocator, io, environ, command.items, output, parsed.args.timeout orelse 120);
    if (parsed.args.storage != 0) {
        const result = .{
            .ram_root = has(serial, "PIZZA_MAINT_RAM_ROOT_READY"),
            .native_primitives = has(serial, "PIZZA_STORAGE_PRIMITIVES:"),
            .no_filesystem_writes = has(serial, "\"filesystem_writes\":false"),
            .application_reaped = has(serial, "PIZZA_INIT_STORAGE_CHILD_READY"),
            .powered_off = has(serial, "Power down"),
            .healthy = !has(serial, "Kernel panic") and !has(serial, "PIZZA_MAINT_DEGRADED") and !has(serial, "PIZZA_MAINT_PANIC"),
            .artifacts = output,
        };
        const json = try std.json.Stringify.valueAlloc(allocator, result, .{ .whitespace = .indent_2 });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ output, "results.json" }), .data = json });
        try std.Io.File.stdout().writeStreamingAll(io, json);
        if (!result.ram_root or !result.native_primitives or !result.no_filesystem_writes or !result.application_reaped or !result.powered_off or !result.healthy) return error.StorageBootFailed;
        return;
    }
    if (parsed.args.backend != 0) {
        const result = .{
            .ram_root = has(serial, "PIZZA_MAINT_RAM_ROOT_READY"),
            .backend_replay = has(serial, "PIZZA_BACKEND_SELFTEST_READY"),
            .application_reaped = has(serial, "PIZZA_INIT_BACKEND_CHILD_READY"),
            .powered_off = has(serial, "Power down"),
            .healthy = !has(serial, "Kernel panic") and !has(serial, "PIZZA_MAINT_DEGRADED") and !has(serial, "PIZZA_MAINT_PANIC"),
            .artifacts = output,
        };
        const json = try std.json.Stringify.valueAlloc(allocator, result, .{ .whitespace = .indent_2 });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ output, "results.json" }), .data = json });
        try std.Io.File.stdout().writeStreamingAll(io, json);
        if (!result.ram_root or !result.backend_replay or !result.application_reaped or !result.powered_off or !result.healthy) return error.BackendBootFailed;
        return;
    }
    const result = .{
        .ram_root = has(serial, "PIZZA_MAINT_RAM_ROOT_READY"),
        .mounts = has(serial, "PIZZA_MAINT_MOUNTS_READY"),
        .parameters = has(serial, "PIZZA_MAINT_CMDLINE_READY: boot=selftest"),
        .modules = has(serial, "PIZZA_MAINT_MODULES_READY"),
        .bundle_cwd = has(serial, "PIZZA_MAINT_BUNDLE_CWD_READY"),
        .device = has(serial, "PIZZA_MAINT_DEVICE_READY"),
        .dynamic_program = has(serial, "PIZZA_MAINT_DYNAMIC_PROBE_READY"),
        .reaper = has(serial, "PIZZA_MAINT_REAPER_READY"),
        .application_isolated = has(serial, "PIZZA_INIT_APPLICATION_EXIT_OBSERVED"),
        .signals = has(serial, "PIZZA_MAINT_SIGNALS_READY"),
        .persistent_supervisor = has(serial, "PIZZA_MAINT_SELFTEST_READY"),
        .powered_off = has(serial, "Power down"),
        .healthy = !has(serial, "PIZZA_MAINT_DEGRADED") and !has(serial, "PIZZA_MAINT_PANIC") and !has(serial, "Kernel panic"),
        .artifacts = output,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, result, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ output, "results.json" }), .data = json });
    try std.Io.File.stdout().writeStreamingAll(io, json);
    if (!result.ram_root or !result.mounts or !result.parameters or !result.modules or !result.bundle_cwd or !result.device or !result.dynamic_program or !result.reaper or !result.application_isolated or !result.signals or !result.persistent_supervisor or !result.powered_off or !result.healthy)
        return error.MaintenanceBootFailed;
}

fn has(serial: []const u8, marker: []const u8) bool {
    return std.mem.indexOf(u8, serial, marker) != null;
}
