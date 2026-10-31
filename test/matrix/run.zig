const std = @import("std");
const utils = @import("utils");
const bundle = @import("bundle");
const clap = @import("clap");
const h = @import("vm").harness;

fn checkFixtures(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: std.json.Value,
) !void {
    const targets = (switch (config) {
        .object => |object| object.get("targets") orelse return error.MissingField,
        else => return error.ExpectedObject,
    });
    if (targets != .array or targets.array.items.len == 0)
        return error.EmptyMatrix;
    for (targets.array.items) |target| {
        const id = (switch ((switch (target) {
            .object => |object| object.get("id") orelse return error.MissingField,
            else => return error.ExpectedObject,
        })) {
            .string => |text| text,
            else => return error.ExpectedString,
        });
        if (id.len == 0)
            return error.UnsafeTargetIdentifier;
        for (id) |byte| {
            if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and
                std.mem.indexOfScalar(u8, "_.-", byte) == null)
            {
                return error.UnsafeTargetIdentifier;
            }
        }
        const fixture = (switch (target) {
            .object => |object| object.get("fixture") orelse return error.MissingField,
            else => return error.ExpectedObject,
        });
        const digest = (switch (target) {
            .object => |object| object.get("sha256") orelse return error.MissingField,
            else => return error.ExpectedObject,
        });
        if (fixture == .null or digest == .null) {
            std.log.err(
                "Matrix image has not been supplied: {s}",
                .{id},
            );
            return error.MatrixFixtureRequired;
        }
        const path = (switch (fixture) {
            .string => |text| text,
            else => return error.ExpectedString,
        });
        try h.noComma(path);
        if (!std.mem.eql(
            u8,
            try utils.filesystem.hashFileSha256(allocator, io, path),
            (switch (digest) {
                .string => |text| text,
                else => return error.ExpectedString,
            }),
        ))
            return error.FixtureHashMismatch;
    }
}

fn quote(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return allocator.print(
        "'{s}'",
        .{
            try std.mem.replaceOwned(u8, allocator, value, "'", "'\\''"),
        },
    );
}

fn guestScript(
    allocator: std.mem.Allocator,
    id: []const u8,
    command: []const []const u8,
) ![]const u8 {
    var words: std.array_list.Managed([]const u8) = .init(allocator);
    for (command) |item| try words.append(try quote(allocator, item));
    return allocator.print(
        "#!/bin/bash\nset -euo pipefail\nexec > /dev/ttyS0 2>&1\n" ++
            "trap 'echo PIZZA_MATRIX_FAIL:{s}; poweroff -f' ERR\n" ++
            "echo PIZZA_MATRIX_HOST_KERNEL:$(uname -r)\n" ++
            "echo PIZZA_MATRIX_HOST_GLIBC:$(getconf GNU_LIBC_VERSION || true)\n" ++
            "mkdir -p /mnt/pizza-source /run/pizza-abi\n" ++
            "mount -t 9p -o trans=virtio,version=9p2000.L,ro pizza_bundle /mnt/pizza-source\n" ++
            "mount -t tmpfs -o size=512M tmpfs /run/pizza-abi\n" ++
            "mkdir -p /run/pizza-abi/opt/pizza/bundle /run/pizza-abi/proc\n" ++
            "mount --bind /mnt/pizza-source /run/pizza-abi/opt/pizza/bundle\n" ++
            "mount -o remount,bind,ro /run/pizza-abi/opt/pizza/bundle\n" ++
            "mount -t proc proc /run/pizza-abi/proc\nchroot /run/pizza-abi {s}\n" ++
            "echo PIZZA_MATRIX_OK:{s}\n" ++
            "umount /run/pizza-abi/proc /run/pizza-abi/opt/pizza/bundle " ++
            "/run/pizza-abi /mnt/pizza-source\npoweroff -f\n",
        .{
            id,
            try std.mem.join(allocator, " ", words.items),
            id,
        },
    );
}

const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--config <str>  Pinned cloud-image fixture configuration.
    \\--bundle <str>  Local bundle directory (required for execution).
    \\--binary <str>  Local ABI checker relative path.
    \\--binary-arg <str>...  ABI checker argument; repeatable, use = for leading dashes.
    \\--timeout <u32>  VM timeout in seconds (default: 300).
    \\--check-fixtures  Verify fixture hashes without running ABI checks.
);

/// Runs the local bundle checker in isolated roots across checksum-pinned QEMU cloud fixtures.
/// Parses subcommand arguments and records per-target results; --check-fixtures checks inputs only.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
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
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tests matrix [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    }
    const config = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        try std.Io.Dir.cwd().readFileAlloc(
            io,
            (parsed.args.config orelse "test/matrix/targets.json"),
            allocator,
            .limited(128 * 1024 * 1024),
        ),
        .{ .allocate = .alloc_always },
    );
    try checkFixtures(allocator, io, config);
    if (parsed.args.@"check-fixtures" != 0) {
        std.log.info(
            "Cloud-image fixtures match their pinned SHA-256. ABI tests have not run.",
            .{},
        );
        return;
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        (parsed.args.bundle orelse return error.MissingBundle),
        allocator,
    );
    // Compatibility tests use an explicitly unpacked producer runtime fixture.
    // Production application packages contain an opaque base image instead.
    const runtime = try std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(allocator, &.{ root, "runtime.json" }), allocator, .limited(1024 * 1024)), .{});
    if (runtime != .object) return error.ExpectedObject;
    const binary = (parsed.args.binary orelse "bin/pizza-abi-check");
    const components = runtime.object.get("components") orelse return error.MissingComponent;
    if (components != .object) return error.ExpectedObject;
    const loader_relative = switch (components.object.get("dynamic-loader") orelse return error.MissingComponent) {
        .string => |value| value,
        else => return error.ExpectedString,
    };
    const binary_stat = std.Io.Dir.cwd().statFile(io, try bundle.rooted(allocator, io, root, binary), .{}) catch return error.BundledAbiCheckBinaryMissing;
    if (binary_stat.kind != .file) {
        return error.BundledAbiCheckBinaryMissing;
    }
    try h.noComma(root);
    const output = try utils.filesystem.createTemporaryDirectory(
        allocator,
        io,
        "pizza-abi-matrix-",
    );
    var results = std.json.Value{
        .array = std.json.Array.init(allocator),
    };
    for (((switch (config) {
        .object => |object| object.get("targets") orelse return error.MissingField,
        else => return error.ExpectedObject,
    })).array.items, 0..) |target, index| {
        const id = (switch ((switch (target) {
            .object => |object| object.get("id") orelse return error.MissingField,
            else => return error.ExpectedObject,
        })) {
            .string => |text| text,
            else => return error.ExpectedString,
        });
        const directory = try std.fs.path.join(
            allocator,
            &.{
                output,
                try allocator.print("{d}", .{index}),
            },
        );
        try std.Io.Dir.cwd().createDirPath(io, directory);
        const overlay = try std.fs.path.join(
            allocator,
            &.{ directory, "guest.qcow2" },
        );
        try utils.process.runInherited(
            io,
            environ,
            &.{
                "qemu-img",
                "create",
                "-f",
                "qcow2",
                "-F",
                "qcow2",
                "-b",
                try std.Io.Dir.cwd().realPathFileAlloc(
                    io,
                    (switch ((switch (target) {
                        .object => |object| object.get("fixture") orelse return error.MissingField,
                        else => return error.ExpectedObject,
                    })) {
                        .string => |text| text,
                        else => return error.ExpectedString,
                    }),
                    allocator,
                ),
                overlay,
            },
        );
        var command: std.array_list.Managed([]const u8) = .init(allocator);
        // Bootstrap without a shell inside the isolated root. The checker establishes
        // the bundle-root CWD before loading plugins or starting child processes.
        const loader = try std.fs.path.join(allocator, &.{ bundle.PREFIX, loader_relative });
        try command.append(loader);
        try command.append(
            try std.fs.path.join(
                allocator,
                &.{ bundle.PREFIX, binary },
            ),
        );
        try command.appendSlice(&.{ "--bundle-root", bundle.PREFIX });
        try command.appendSlice(parsed.args.@"binary-arg");
        const userdata = .{
            .write_files = .{
                .{
                    .path = "/usr/local/sbin/pizza-abi-check",
                    .permissions = "0700",
                    .content = try guestScript(allocator, id, command.items),
                },
            },
            .runcmd = .{.{"/usr/local/sbin/pizza-abi-check"}},
        };
        const user_file = try std.fs.path.join(
            allocator,
            &.{ directory, "user-data" },
        );
        const meta_file = try std.fs.path.join(
            allocator,
            &.{ directory, "meta-data" },
        );
        const seed = try std.fs.path.join(allocator, &.{ directory, "seed.img" });
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = user_file,
            .data = try allocator.print(
                "#cloud-config\n{s}\n",
                .{
                    try std.json.Stringify.valueAlloc(
                        allocator,
                        userdata,
                        .{ .whitespace = .indent_2 },
                    ),
                },
            ),
        });
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = meta_file,
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                .{
                    .@"instance-id" = try allocator.print("pizza-{d}", .{index}),
                    .@"local-hostname" = "pizza-abi",
                },
                .{ .whitespace = .indent_2 },
            ),
        });
        try utils.process.runInherited(
            io,
            environ,
            &.{
                "cloud-localds",
                seed,
                user_file,
                meta_file,
            },
        );
        var qemu = try h.baseCommand(allocator, io, environ, directory, 2048);
        try qemu.appendSlice(
            &.{
                "-nic",
                "none",
                "-no-reboot",
                "-drive",
                try allocator.print(
                    "if=virtio,format=qcow2,file={s}",
                    .{overlay},
                ),
                "-drive",
                try allocator.print(
                    "if=virtio,format=raw,readonly=on,file={s}",
                    .{seed},
                ),
                "-virtfs",
                try allocator.print(
                    "local,path={s},mount_tag=pizza_bundle,security_model=none,readonly=on",
                    .{root},
                ),
            },
        );
        const log = try h.runVm(
            allocator,
            io,
            environ,
            qemu.items,
            directory,
            parsed.args.timeout orelse 300,
        );
        const passed = std.mem.indexOf(
            u8,
            log,
            try allocator.print("PIZZA_MATRIX_OK:{s}", .{id}),
        ) != null and std.mem.indexOf(u8, log, "PIZZA_MATRIX_FAIL:") == null;
        var evidence = std.json.Value{
            .array = std.json.Array.init(allocator),
        };
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "PIZZA_MATRIX_") != null) {
                try evidence.array.append(.{ .string = line });
            }
        }
        var result = std.json.Value{ .object = .{} };
        try result.object.put(
            allocator,
            "target",
            std.json.Value{ .string = id },
        );
        var abi_command = std.json.Value{
            .array = std.json.Array.init(allocator),
        };
        for (command.items) |item| try abi_command.array.append(
            std.json.Value{ .string = item },
        );
        try result.object.put(allocator, "abi_command", abi_command);
        try result.object.put(
            allocator,
            "passed",
            .{ .bool = passed },
        );
        try result.object.put(allocator, "evidence", evidence);
        try result.object.put(
            allocator,
            "full_transition",
            std.json.Value{ .string = "not-run" },
        );
        try result.object.put(
            allocator,
            "serial",
            std.json.Value{
                .string = try std.fs.path.join(
                    allocator,
                    &.{ directory, "serial.log" },
                ),
            },
        );
        try results.array.append(result);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(
                allocator,
                &.{ output, "results.json" },
            ),
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                results,
                .{ .whitespace = .indent_2 },
            ),
        });
        if (!passed)
            return error.AbiCheckFailed;
    }
    std.log.info(
        "Isolated ABI checks passed: {s}; full transition is a separate phase-7 test",
        .{output},
    );
}

test "matrix command preserves repeated checker arguments including leading dashes" {
    var iter: clap.args.SliceIterator = .{ .args = &.{
        "--binary-arg=--version",
        "--binary-arg",
        "second value",
        "--binary-arg=",
        "--timeout=42",
    } };
    var parsed = try clap.parseEx(clap.Help, &PARAMS, clap.parsers.default, &iter, .{
        .allocator = std.testing.allocator,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, 42), parsed.args.timeout);
    const expected = [_][]const u8{ "--version", "second value", "" };
    try std.testing.expectEqual(expected.len, parsed.args.@"binary-arg".len);
    for (expected, parsed.args.@"binary-arg") |a, b| try std.testing.expectEqualStrings(a, b);
}
