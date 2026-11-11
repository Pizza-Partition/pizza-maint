const std = @import("std");
const compile_policy = @import("build/compile.zig");
const bundle_steps = @import("build/bundle.zig");
const ext_build = @import("build/filesystem/ext/root.zig");
const fat_build = @import("build/filesystem/fat32/root.zig");
const ntfs_build = @import("build/filesystem/ntfs/root.zig");
const btrfs_build = @import("build/filesystem/btrfs/root.zig");
comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, required))
        @compileError("Pizza requires Zig " ++ required ++ "; current compiler is " ++ @import("builtin").zig_version_string ++ ". Select the compiler pinned in .zigversion and config/toolchain.json.");
}

/// Registers core binaries, engineering commands, format checks and test suites.
/// Host tools use the baseline Linux target; core binaries use the selected build target.
pub fn build(b: *std.Build) void {
    // Doctor, protocol generation and tests must use the compiler running this build.
    b.graph.environ_map.put("ZIG", b.graph.zig_exe) catch @panic("OOM");
    const npm = requireHostTool(b, "NPM", "npm");
    const node = requireHostTool(b, "NODE", "node");
    // TODO: Support for other OSes.
    const target = b.standardTargetOptions(
        .{
            .default_target = .{
                .cpu_arch = .x86_64,
                .cpu_model = .baseline,
                .os_tag = .linux,
                .os_version_min = .{
                    .semver = .{ .major = 4, .minor = 18, .patch = 0 },
                },
                .abi = .musl,
            },
        },
    );

    const optimize = b.standardOptimizeOption(.{});
    const dev = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-fincremental", "--watch" });
    dev.setCwd(b.path("."));
    dev.addPassthruArgs();
    b.step("dev", "Rebuild on source changes with incremental compilation (build arguments after --)").dependOn(&dev.step);
    const host_target = b.resolveTargetQuery(
        .{
            .cpu_arch = .x86_64,
            .cpu_model = .baseline,
            .os_tag = .linux,
            .os_version_min = .{
                .semver = .{ .major = 4, .minor = 18, .patch = 0 },
            },
            .abi = .musl,
        },
    );
    // 3rd parties
    const clap = b.dependency("clap", .{ .target = host_target, .optimize = .safe });
    const core_clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const core_utils = b.createModule(.{
        .root_source_file = b.path("core/utils/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils = b.addModule(
        "utils",
        .{
            .root_source_file = b.path("core/utils/root.zig"),
            .target = host_target,
            .optimize = .safe,
        },
    );
    const bundle = b.addModule("bundle", .{
        .root_source_file = b.path("core/bundle/root.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{.{ .name = "utils", .module = utils }},
    });
    const core_bundle = b.createModule(.{
        .root_source_file = b.path("core/bundle/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "utils", .module = core_utils }},
    });
    const bundle_build = b.addModule("bundle_build", .{
        .root_source_file = b.path("build/bundle/root.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "bundle", .module = bundle },
        },
    });
    const initramfs = b.addModule("initramfs", .{
        .root_source_file = b.path("core/initramfs/root.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "bundle", .module = bundle },
            .{ .name = "bundle_build", .module = bundle_build },
        },
    });
    const vm = b.addModule(
        "vm",
        .{
            .root_source_file = b.path("test/qemu/root.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "bundle_build", .module = bundle_build },
                .{ .name = "initramfs", .module = initramfs },
                .{ .name = "clap", .module = clap.module("clap") },
            },
        },
    );
    const matrix = b.addModule(
        "matrix",
        .{
            .root_source_file = b.path("test/matrix/run.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "bundle", .module = bundle },
                .{ .name = "bundle_build", .module = bundle_build },
                .{ .name = "vm", .module = vm },
                .{ .name = "clap", .module = clap.module("clap") },
            },
        },
    );
    const tool = b.addExecutable(
        .{
            .name = "pizza-tools",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("tools/main.zig"),
                    .target = host_target,
                    .optimize = .safe,
                    .imports = &.{
                        .{ .name = "utils", .module = utils },
                        .{ .name = "clap", .module = clap.module("clap") },
                        .{ .name = "bundle_build", .module = bundle_build },
                        .{ .name = "initramfs", .module = initramfs },
                    },
                    .link_libc = false,
                },
            ),
        },
    );
    compile_policy.configure(tool);
    b.installArtifact(tool);
    const runner = b.addExecutable(.{
        .name = "pizza-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "vm", .module = vm },
                .{ .name = "matrix", .module = matrix },
                .{ .name = "clap", .module = clap.module("clap") },
            },
            .link_libc = false,
        }),
    });
    compile_policy.configure(runner);
    const install_tests = b.step("test-runners", "Build and install optional test executables");
    install_tests.dependOn(&b.addInstallArtifact(runner, .{}).step);
    const tools = b.addRunArtifact(tool);
    tools.setCwd(b.path("."));
    tools.addPassthruArgs();
    b.step(
        "tools",
        "Run a native Zig infrastructure command (arguments after --)",
    ).dependOn(&tools.step);
    for ([_]bool{ false, true }) |check_format| {
        const zig_fmt = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt" });
        zig_fmt.setCwd(b.path("."));
        if (check_format) zig_fmt.addArg("--check");
        zig_fmt.addArgs(&.{ "build.zig", "build.zig.zon", "build", "core", "tools", "test", "ui" });
        const prettier = b.addSystemCommand(&.{
            node,
            "ui/node_modules/prettier/bin/prettier.cjs",
            if (check_format) "--check" else "--write",
            "--ignore-path",
            ".prettierignore",
            "**/*.{json,js,mjs,ts,css,html,yaml,yml,md}",
            ".prettierrc.json",
        });
        prettier.setCwd(b.path("."));
        prettier.step.dependOn(&zig_fmt.step);
        b.step(
            if (check_format) "fmt-check" else "fmt",
            if (check_format) "Check formatting without modifying files" else "Format Zig, JSON and docs",
        ).dependOn(&prettier.step);
    }
    const web_deps = b.addSystemCommand(
        &.{
            npm,
            "--prefix",
            "ui",
            "ci",
            "--include=dev",
            "--engine-strict",
            "--ignore-scripts",
            "--no-audit",
            "--no-fund",
        },
    );

    const deps = b.step(
        "deps",
        "Install locked developer and formatter dependencies",
    );
    deps.dependOn(&web_deps.step);
    const check = command(b, tool, &.{ "proto", "--check" });
    const protocol_export = b.addExecutable(.{ .name = "pizza-export-protocol", .root_module = b.createModule(.{ .root_source_file = b.path("tools/export_protocol.zig"), .target = host_target, .optimize = .safe }) });
    compile_policy.configure(protocol_export);
    const export_package = b.addRunArtifact(protocol_export);
    const protocol_directory = export_package.addOutputDirectoryArg("protocol");
    const protocol_archive = export_package.addOutputFileArg("pizza-protocol-4.0.1.tar.gz");
    // Track the actual inputs, excluding nested developer build caches.
    for ([_][]const u8{ "build.zig", "build.zig.zon", "README.md", "root.zig", "contract.json", "generated.zig", "generated/contract.js", "generated/contract.d.ts", "uefi.zig", "firmware_pin.zig", "receipt_envelope.zig", "inventory_fingerprint.zig", "intent_normalization.zig" }) |name|
        export_package.addFileArg(b.path(b.fmt("protocol/{s}", .{name})));
    export_package.step.dependOn(&check.step);
    const install_protocol = b.addInstallDirectory(.{ .source_dir = protocol_directory, .install_dir = .prefix, .install_subdir = "share/pizza/protocol" });
    const install_protocol_archive = b.addInstallFile(protocol_archive, "share/pizza/pizza-protocol-4.0.1.tar.gz");
    const protocol_step = b.step("protocol-package", "Export the independent v4 protocol package and fetchable archive");
    protocol_step.dependOn(&install_protocol.step);
    protocol_step.dependOn(&install_protocol_archive.step);
    const proto = b.addModule(
        "proto",
        .{
            .root_source_file = b.path("protocol/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    const power = b.addModule(
        "power",
        .{
            .root_source_file = b.path("core/init/power.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    const journal = b.createModule(.{
        .root_source_file = b.path("core/maint/journal.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{
            .{ .name = "proto", .module = b.createModule(.{ .root_source_file = b.path("protocol/root.zig"), .target = host_target, .optimize = .safe }) },
            .{ .name = "utils", .module = utils },
        },
    });
    const core_journal = b.createModule(.{
        .root_source_file = b.path("core/maint/journal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "utils", .module = core_utils } },
    });
    const core_session = sessionModule(b, target, optimize, proto, core_utils);
    vm.addImport("journal", journal);
    tool.root_module.addImport("journal", journal);
    tool.root_module.addImport("report", b.createModule(.{ .root_source_file = b.path("core/maint/report.zig"), .target = host_target, .optimize = .safe, .imports = &.{.{ .name = "journal", .module = journal }} }));
    const journal_guest = b.addExecutable(.{
        .name = "pizza-journal-guest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/qemu/journal_guest.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "journal", .module = journal },
                .{ .name = "power", .module = power },
                .{ .name = "mounts", .module = b.createModule(.{
                    .root_source_file = b.path("core/init/mounts.zig"),
                    .target = host_target,
                    .optimize = .safe,
                    .imports = &.{.{ .name = "utils", .module = utils }},
                }) },
            },
        }),
    });
    compile_policy.configure(journal_guest);
    install_tests.dependOn(&b.addInstallArtifact(journal_guest, .{}).step);
    const run_journal = command(b, runner, &.{ "journal", "--binary" });
    run_journal.addArtifactArg(journal_guest);
    run_journal.addPassthruArgs();
    b.step("test-journal", "Verify journal persistence across two QEMU boots").dependOn(&run_journal.step);

    var maintenance: *std.Build.Step.Compile = undefined;
    for ([_][2][]const u8{
        .{ "pizza-init", "core/init/main.zig" },
    }) |entry| {
        const exe = b.addExecutable(
            .{
                .name = entry[0],
                .root_module = b.createModule(
                    .{
                        .root_source_file = b.path(entry[1]),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{
                            .{ .name = "proto", .module = proto },
                        },
                        .link_libc = false,
                    },
                ),
            },
        );
        compile_policy.configure(exe);
        exe.step.dependOn(&check.step);
        exe.root_module.addImport("clap", core_clap.module("clap"));
        exe.root_module.addImport("bundle", core_bundle);
        exe.root_module.addImport("utils", core_utils);
        exe.root_module.addImport("journal", core_journal);
        exe.root_module.addImport("legacy_handoff", core_session);
        exe.root_module.addImport("initramfs_archive", b.createModule(.{ .root_source_file = b.path("core/initramfs/archive.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "utils", .module = core_utils }} }));
        if (std.mem.eql(u8, entry[0], "pizza-init")) {
            exe.root_module.addImport("power", power);
            maintenance = exe;
        }
        b.installArtifact(exe);
    }

    const recovery_support = b.createModule(.{
        .root_source_file = b.path("core/init/recovery.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{.{ .name = "power", .module = power }},
    });
    const recovery_guest = b.addExecutable(.{
        .name = "pizza-recovery-guest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/qemu/recovery_guest.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "recovery", .module = recovery_support },
                .{ .name = "power", .module = power },
                .{ .name = "mounts", .module = journal_guest.root_module.import_table.get("mounts").? },
                .{ .name = "modules", .module = b.createModule(.{
                    .root_source_file = b.path("core/init/modules.zig"),
                    .target = host_target,
                    .optimize = .safe,
                    .imports = &.{.{ .name = "utils", .module = utils }},
                }) },
            },
        }),
    });
    compile_policy.configure(recovery_guest);
    install_tests.dependOn(&b.addInstallArtifact(recovery_guest, .{}).step);
    b.step("init-recovery-guest", "Build the isolated PID 1 recovery fixture").dependOn(&b.addInstallArtifact(recovery_guest, .{}).step);
    const recovery_runner = b.addExecutable(.{ .name = "pizza-init-recovery-test", .root_module = b.createModule(.{
        .root_source_file = b.path("test/qemu/recovery.zig"),
        .target = host_target,
        .optimize = .safe,
        .link_libc = true,
        .imports = &.{ .{ .name = "utils", .module = utils }, .{ .name = "initramfs_archive", .module = b.createModule(.{
            .root_source_file = b.path("core/initramfs/archive.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{.{ .name = "utils", .module = utils }},
        }) } },
    }) });
    compile_policy.configure(recovery_runner);
    b.step("init-recovery-test-binary", "Build the Zig-only QEMU recovery supervisor").dependOn(&b.addInstallArtifact(recovery_runner, .{}).step);
    const recovery_test = b.addRunArtifact(recovery_runner);
    recovery_test.addArg("--init");
    recovery_test.addArtifactArg(maintenance);
    recovery_test.addArg("--fixture");
    recovery_test.addArtifactArg(recovery_guest);
    recovery_test.addPassthruArgs();
    b.step("test-init-recovery", "Verify controlled shutdown and rescue consoles in disposable QEMU guests").dependOn(&recovery_test.step);

    const gnu_query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .cpu_model = .baseline,
        .os_tag = .linux,
        .os_version_min = .{ .semver = .{ .major = 4, .minor = 18, .patch = 0 } },
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 },
    };
    const app_target = b.resolveTargetQuery(gnu_query);
    // Test harnesses explicitly load the one maintenance binary shipped in the bundle.
    const host_loader = app_target.result.dynamic_linker.get() orelse @panic("GNU test target needs a dynamic linker");
    const app_proto = b.createModule(.{ .root_source_file = b.path("protocol/root.zig"), .target = app_target, .optimize = optimize });
    const app_utils = b.createModule(.{ .root_source_file = b.path("core/utils/root.zig"), .target = app_target, .optimize = optimize });
    const app_session = sessionModule(b, app_target, optimize, app_proto, app_utils);
    const abi_checker = b.addExecutable(.{
        .name = "pizza-abi-check",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/matrix/abi_check.zig"),
            .target = app_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    abi_checker.root_module.linkSystemLibrary("dl", .{ .use_pkg_config = .no });
    abi_checker.root_module.addRPathSpecial("$ORIGIN/../lib");
    compile_policy.configure(abi_checker);
    const install_abi_checker = b.addInstallArtifact(abi_checker, .{});
    b.step("abi-check", "Build and install the dynamic glibc matrix probe").dependOn(&install_abi_checker.step);
    install_tests.dependOn(&install_abi_checker.step);
    const app_journal = b.createModule(.{
        .root_source_file = b.path("core/maint/journal.zig"),
        .target = app_target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "proto", .module = app_proto }, .{ .name = "utils", .module = app_utils } },
    });
    const app_ui = executionModules(b, app_target, optimize, app_proto, app_utils, app_journal, app_session);
    const application_module = b.createModule(.{
        .root_source_file = b.path("core/maint/main.zig"),
        .target = app_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "proto", .module = app_proto },
            .{ .name = "utils", .module = app_utils },
            .{ .name = "clap", .module = b.dependency("clap", .{ .target = app_target, .optimize = optimize }).module("clap") },
            .{ .name = "journal", .module = app_journal },
            .{ .name = "legacy_handoff", .module = app_session },
            .{ .name = "maintenance", .module = app_ui.maintenance },
            .{ .name = "execution_tui", .module = app_ui.tui },
        },
    });
    application_module.addImport("restart", b.createModule(.{ .root_source_file = b.path("core/restart/restart.zig"), .target = app_target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "proto", .module = app_proto }, .{ .name = "storage", .module = app_ui.storage }, .{ .name = "utils", .module = app_utils } } }));
    const application = maintenanceExecutable(b, "pizza-maint", application_module, optimize, app_ui.ext, app_ui.fat, app_ui.ntfs, app_ui.btrfs);
    application.producer.step.dependOn(&check.step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(application.binary, .bin, "pizza-maint").step);
    const fixture_module = b.createModule(.{
        .root_source_file = b.path("core/maint/testing/main.zig"),
        .target = app_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "application", .module = application_module },
            .{ .name = "maintenance", .module = app_ui.maintenance },
        },
    });
    fixture_module.addImport("proto", app_proto);
    fixture_module.addImport("storage", app_ui.storage);
    const maintenance_fixture = maintenanceExecutable(b, "pizza-maint-fixture", fixture_module, optimize, app_ui.ext, app_ui.fat, app_ui.ntfs, app_ui.btrfs);
    const install_fixture = b.addInstallFileWithDir(maintenance_fixture.binary, .bin, "pizza-maint-fixture");
    install_tests.dependOn(&install_fixture.step);
    b.step("maintenance-fixture", "Build a separate image-backed maintenance acceptance binary").dependOn(&install_fixture.step);
    const run_tui = maintenanceTestCommand(b, host_loader, application.binary, &.{"--tui-self-test"});
    b.step("test-tui", "Verify libvaxis on a real controlling terminal").dependOn(&run_tui.step);
    const storage_step = b.step("test-storage", "Verify patch transactions, undo recovery and SQLite-style crash/I/O models");
    const executor_guest = b.addExecutable(.{
        .name = "pizza-executor-guest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/qemu/executor_guest.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "journal", .module = journal },                                               .{ .name = "proto", .module = journal.import_table.get("proto").? },                                                                                        .{ .name = "utils", .module = utils }, .{ .name = "power", .module = power },
                .{ .name = "mounts", .module = journal_guest.root_module.import_table.get("mounts").? }, .{ .name = "supervisor", .module = b.createModule(.{ .root_source_file = b.path("core/init/supervisor.zig"), .target = host_target, .optimize = .safe }) },
            },
        }),
    });
    compile_policy.configure(executor_guest);
    install_tests.dependOn(&b.addInstallArtifact(executor_guest, .{}).step);
    const run_executor = command(b, runner, &.{ "executor", "--fixture" });
    run_executor.addArtifactArg(executor_guest);
    run_executor.addArg("--report-binary");
    run_executor.addArtifactArg(tool);
    run_executor.addArg("--application");
    run_executor.addFileArg(maintenance_fixture.binary);
    run_executor.addPassthruArgs();
    b.step("test-executor", "Verify live execution and persisted fault recovery in QEMU").dependOn(&run_executor.step);
    for ([_]u32{ 512, 4096 }) |sector| {
        const run_physical = command(b, runner, &.{ "executor", "--physical", "--sector-size", b.fmt("{d}", .{sector}), "--fixture" });
        run_physical.addArtifactArg(executor_guest);
        run_physical.addArg("--report-binary");
        run_physical.addArtifactArg(tool);
        run_physical.addArg("--application");
        run_physical.addFileArg(application.binary);
        run_physical.addPassthruArgs();
        b.step(if (sector == 512) "test-executor-physical" else "test-executor-physical-4kn", "Verify the production application on exclusive virtual block devices").dependOn(&run_physical.step);
    }
    const run_backend = maintenanceTestCommand(b, host_loader, application.binary, &.{ "--self-test", "--no-tui" });
    run_backend.addPassthruArgs();
    b.step("test-backend", "Verify maintenance business state and journal replay").dependOn(&run_backend.step);

    const tests = b.addTest(
        .{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("core/tests.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "proto", .module = proto },
                        .{ .name = "power", .module = power },
                        .{ .name = "utils", .module = core_utils },
                    },
                },
            ),
        },
    );
    compile_policy.configure(tests);
    tests.root_module.addImport("journal", core_journal);
    tests.root_module.addImport("legacy_handoff", core_session);
    tests.root_module.addImport("initramfs_archive", b.createModule(.{ .root_source_file = b.path("core/initramfs/archive.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "utils", .module = core_utils }} }));
    const test_ui = executionModules(b, target, optimize, proto, core_utils, core_journal, core_session);
    tests.root_module.addImport("maintenance", test_ui.maintenance);
    tests.root_module.addImport("execution_tui", test_ui.tui);
    tests.step.dependOn(&check.step);
    const test_step = b.step(
        "test",
        "Run Zig module/integration tests and frontend tests",
    );
    test_step.dependOn(&executor_guest.step);
    const run_core_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_core_tests.step);
    b.step("test-core", "Run core subsystem unit tests independently of integration harnesses").dependOn(&run_core_tests.step);
    const maintenance_test_module = b.createModule(.{
        .root_source_file = b.path("core/maint/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (test_ui.maintenance.import_table.keys(), test_ui.maintenance.import_table.values()) |name, module|
        maintenance_test_module.addImport(name, module);
    maintenance_test_module.addImport("execution_tui", test_ui.tui);
    const maintenance_tests = b.addTest(.{ .root_module = maintenance_test_module });
    compile_policy.configure(maintenance_tests);
    const run_maintenance_tests = b.addRunArtifact(maintenance_tests);
    test_step.dependOn(&run_maintenance_tests.step);
    b.step("test-maint-executor", "Verify device acquisition, execution, cancellation and recovery").dependOn(&run_maintenance_tests.step);
    // Dependency-module tests are not a storage acceptance gate on their own.
    // Give storage tests their own root so test-storage also runs hazards,
    // semantic capability gates and memory budgets, not only CLI fixtures.
    const storage_module = b.createModule(.{
        .root_source_file = b.path("core/maint/storage/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "utils", .module = core_utils }, .{ .name = "ext2fs_c", .module = test_ui.ext.bindings }, .{ .name = "fatfs_c", .module = test_ui.fat.bindings }, .{ .name = "ntfs_c", .module = test_ui.ntfs.bindings }, .{ .name = "btrfs_c", .module = test_ui.btrfs.bindings } },
    });
    const host_proto = b.createModule(.{ .root_source_file = b.path("protocol/root.zig"), .target = target, .optimize = optimize });
    const host_imports: []const std.Build.Module.Import = &.{ .{ .name = "proto", .module = host_proto }, .{ .name = "storage", .module = storage_module }, .{ .name = "utils", .module = core_utils } };
    const host_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("core/restart/tests.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = host_imports }) });
    compile_policy.configure(host_tests);
    b.step("test-session", "Verify offline compilation, recovery anchors and maintenance session safety").dependOn(&b.addRunArtifact(host_tests).step);
    const session_image = b.addExecutable(.{ .name = "pizza-session-image", .root_module = b.createModule(.{ .root_source_file = b.path("core/restart/session_image.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = host_imports }) });
    compile_policy.configure(session_image);
    b.step("session-image", "Build the explicit regular-image maintenance session harness").dependOn(&b.addInstallArtifact(session_image, .{}).step);
    const session_fixture_storage = b.createModule(.{ .root_source_file = b.path("core/maint/storage/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "utils", .module = core_utils }} });
    const session_acceptance = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/integration/maintenance_session.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "proto", .module = host_proto }, .{ .name = "storage", .module = session_fixture_storage }, .{ .name = "utils", .module = core_utils } } }) });
    const session_binary = b.addOptions();
    session_binary.addOptionPath("path", session_image.getEmittedBin());
    session_acceptance.root_module.addOptions("fixture_binary", session_binary);
    compile_policy.configure(session_acceptance);
    b.step("test-maint-session-image", "Verify cross-process maintenance acceptance and undo on disposable regular images").dependOn(&b.addRunArtifact(session_acceptance).step);
    const storage_self_test = b.addExecutable(.{
        .name = "pizza-storage-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/maint/storage/testing/main.zig"),
            .target = target,
            .optimize = optimize,
            // Primitive fixtures need no filesystem libraries or callbacks.
            .imports = &.{.{ .name = "storage", .module = b.createModule(.{
                .root_source_file = b.path("core/maint/storage/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "utils", .module = core_utils }},
            }) }},
        }),
    });
    compile_policy.configure(storage_self_test);
    const run_storage = b.addRunArtifact(storage_self_test);
    storage_step.dependOn(&run_storage.step);
    b.step("storage-test-binary", "Build the standalone storage self-test for optional VM acceptance").dependOn(&b.addInstallArtifact(storage_self_test, .{}).step);
    const storage_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("core/maint/storage/testing/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "utils", .module = core_utils }, .{ .name = "storage", .module = storage_module } },
    }) });
    compile_policy.configure(storage_tests);
    const hardware_filesystems = b.addExecutable(.{ .name = "pizza-filesystems-hardware", .root_module = b.createModule(.{
        .root_source_file = b.path("test/hardware/filesystems.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "storage", .module = storage_module }},
    }) });
    compile_policy.configure(hardware_filesystems);
    b.step("hardware-filesystems", "Build explicit-device filesystem acceptance (never runs it)").dependOn(&b.addInstallArtifact(hardware_filesystems, .{}).step);
    const matrix_fixture = b.addExecutable(.{ .name = "pizza-matrix-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("test/hardware/matrix_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    compile_policy.configure(matrix_fixture);
    const matrix_options = b.addOptions();
    matrix_options.addOptionPath("fixture", matrix_fixture.getEmittedBin());
    const matrix_test_module = b.createModule(.{
        .root_source_file = b.path("test/hardware/matrix_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "storage", .module = storage_module }, .{ .name = "utils", .module = core_utils } },
    });
    matrix_test_module.addOptions("options", matrix_options);
    const hardware_supervisor_tests = b.addTest(.{ .root_module = matrix_test_module });
    compile_policy.configure(hardware_supervisor_tests);
    const run_matrix_tests = b.addRunArtifact(hardware_supervisor_tests);
    b.step("test-hardware-supervisor", "Verify physical test supervision without accessing a disk").dependOn(&run_matrix_tests.step);
    test_step.dependOn(&run_matrix_tests.step);
    const run_storage_tests = b.addRunArtifact(storage_tests);
    b.step("test-storage-unit", "Verify storage planning and crash recovery without building the UI").dependOn(&run_storage_tests.step);
    test_step.dependOn(&run_storage_tests.step);
    run_storage.step.dependOn(&run_storage_tests.step);
    const filesystem_test_filter = b.option([]const u8, "filesystem-test-filter", "Run filesystem tests matching this name");
    const filesystem_tests = b.addTest(.{ .filters = if (filesystem_test_filter) |filter| &.{filter} else &.{}, .root_module = b.createModule(.{
        .root_source_file = b.path("core/maint/storage/testing/filesystem_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "utils", .module = core_utils }, .{ .name = "storage", .module = storage_module } },
    }) });
    compile_policy.configure(filesystem_tests);
    const run_filesystem_tests = b.addRunArtifact(filesystem_tests);
    b.step("test-filesystems", "Run shared filesystem contracts and format-specific acceptance").dependOn(&run_filesystem_tests.step);
    const crash_tests = b.addExecutable(.{ .name = "pizza-storage-crash-test", .root_module = b.createModule(.{
        .root_source_file = b.path("core/maint/storage/testing/crash.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "utils", .module = core_utils }, .{ .name = "storage", .module = storage_module } },
    }) });
    compile_policy.configure(crash_tests);
    const run_crash = b.addRunArtifact(crash_tests);
    run_crash.addPassthruArgs();
    b.step("test-storage-crash", "Random SIGKILL during registered filesystem writes and recovery").dependOn(&run_crash.step);
    const utils_tests = b.addTest(.{ .root_module = utils });
    compile_policy.configure(utils_tests);
    test_step.dependOn(&b.addRunArtifact(utils_tests).step);
    const bundle_tests = b.addTest(.{ .root_module = bundle });
    compile_policy.configure(bundle_tests);
    const run_bundle_tests = b.addRunArtifact(bundle_tests);
    run_bundle_tests.setCwd(b.path("."));
    run_bundle_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_bundle_tests.step);
    const bundle_build_tests = b.addTest(.{ .root_module = bundle_build });
    compile_policy.configure(bundle_build_tests);
    const run_bundle_build_tests = b.addRunArtifact(bundle_build_tests);
    run_bundle_build_tests.setCwd(b.path("."));
    run_bundle_build_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_bundle_build_tests.step);
    const archive_tests = b.addTest(.{ .root_module = initramfs });
    compile_policy.configure(archive_tests);
    test_step.dependOn(&b.addRunArtifact(archive_tests).step);
    for ([_][]const u8{
        "test/qemu/harness.zig",
        "core/init/memory.zig",
    }) |source| {
        const module_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = host_target,
                .optimize = .debug,
                .imports = &.{
                    .{ .name = "utils", .module = utils },
                    .{ .name = "clap", .module = clap.module("clap") },
                    .{ .name = "initramfs", .module = initramfs },
                    .{ .name = "journal", .module = journal },
                    .{ .name = "bundle_build", .module = bundle_build },
                },
            }),
        });
        compile_policy.configure(module_tests);
        test_step.dependOn(&b.addRunArtifact(module_tests).step);
    }
    const matrix_tests = b.addTest(.{ .root_module = matrix });
    compile_policy.configure(matrix_tests);
    test_step.dependOn(&b.addRunArtifact(matrix_tests).step);
    const test_binaries = b.addOptions();
    const report_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/integration/journal.zig"), .target = host_target, .optimize = .debug, .imports = &.{ .{ .name = "utils", .module = utils }, .{ .name = "journal", .module = journal } } }) });
    const report_options = b.addOptions();
    report_options.addOptionPath("tools", tool.getEmittedBin());
    report_tests.root_module.addOptions("test_binaries", report_options);
    compile_policy.configure(report_tests);
    b.step("test-report", "Verify read-only reporting of interrupted journals").dependOn(&b.addRunArtifact(report_tests).step);
    test_binaries.addOptionPath("tools", tool.getEmittedBin());
    test_binaries.addOptionPath("runner", runner.getEmittedBin());
    test_binaries.addOptionPath("application", application.binary);
    test_binaries.addOptionPath("maintenance_fixture", maintenance_fixture.binary);
    test_binaries.addOptionPath("storage_test", storage_self_test.getEmittedBin());
    test_binaries.addOption([]const u8, "application_loader", host_loader);
    test_binaries.addOptionPath("abi_checker", abi_checker.getEmittedBin());
    const integration_tests = b.addTest(
        .{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("test/tests.zig"),
                    .target = host_target,
                    .optimize = .debug,
                    .imports = &.{
                        .{ .name = "utils", .module = utils },
                        .{ .name = "vm", .module = vm },
                        .{ .name = "bundle", .module = bundle },
                        .{ .name = "bundle_build", .module = bundle_build },
                        .{ .name = "proto", .module = proto },
                    },
                },
            ),
        },
    );
    integration_tests.root_module.addImport("journal", journal);
    compile_policy.configure(integration_tests);
    integration_tests.root_module.addOptions("test_binaries", test_binaries);
    const run_integration = b.addRunArtifact(integration_tests);
    run_integration.setCwd(b.path("."));
    run_integration.step.dependOn(b.getInstallStep());
    test_step.dependOn(&runner.step);
    test_step.dependOn(&application.producer.step);
    test_step.dependOn(&run_integration.step);

    const generate = command(b, tool, &.{"proto"});
    b.step("proto", "Regenerate protocol bindings").dependOn(&generate.step);

    b.step(
        "check-proto",
        "Fail if generated contract files drift",
    ).dependOn(&check.step);

    const bundle_step = bundle_steps.add(b, tool, maintenance, application.binary);
    const all = b.step("all", "Build core and the complete bundle");
    all.dependOn(bundle_step);
    all.dependOn(b.getInstallStep());
    b.step("check", "Check protocol drift").dependOn(&check.step);
    for ([_][3][]const u8{
        .{
            "doctor",
            "doctor",
            "Check host build dependencies",
        },
        .{
            "clean",
            "clean",
            "Remove only enumerated generated outputs",
        },
    }) |entry| {
        const run = command(b, tool, &.{entry[1]});
        run.addPassthruArgs();
        b.step(entry[0], entry[2]).dependOn(&run.step);
    }
    for ([_][3][]const u8{
        .{ "test-smoke", "smoke", "Boot the static PID 1 in QEMU" },
        .{ "test-maintenance", "maintenance", "Boot the layered maintenance image in QEMU" },
        .{ "test-matrix", "matrix", "Run isolated ABI checks with supplied cloud fixtures" },
    }) |entry| {
        const run = command(b, runner, &.{entry[1]});
        if (std.mem.eql(u8, entry[0], "test-maintenance")) {
            run.addArg("--storage-binary");
            run.addArtifactArg(storage_self_test);
        }
        run.addPassthruArgs();
        if (std.mem.eql(u8, entry[0], "test-smoke"))
            run.step.dependOn(b.getInstallStep());
        b.step(entry[0], entry[2]).dependOn(&run.step);
    }
}

/// UI sources live under ui/; each target shares one business/protocol identity.
fn executionModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
    proto: *std.Build.Module,
    utils: *std.Build.Module,
    journal: *std.Build.Module,
    session: *std.Build.Module,
) struct { maintenance: *std.Build.Module, storage: *std.Build.Module, tui: *std.Build.Module, ext: ext_build.Result, fat: fat_build.Result, ntfs: ntfs_build.Result, btrfs: btrfs_build.Result } {
    const ext = ext_build.build(b, target, optimize orelse .debug);
    const fat = fat_build.build(b, target, optimize orelse .debug);
    const ntfs = ntfs_build.build(b, target, optimize orelse .debug);
    const btrfs = btrfs_build.build(b, target, optimize orelse .debug);
    const tui = b.createModule(.{
        .root_source_file = b.path("ui/execution/tui/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "proto", .module = proto },
            .{ .name = "journal", .module = journal },
            .{ .name = "vaxis", .module = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis") },
        },
    });
    const storage = b.createModule(.{ .root_source_file = b.path("core/maint/storage/root.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "utils", .module = utils }, .{ .name = "ext2fs_c", .module = ext.bindings }, .{ .name = "fatfs_c", .module = fat.bindings }, .{ .name = "ntfs_c", .module = ntfs.bindings }, .{ .name = "btrfs_c", .module = btrfs.bindings } } });
    const maintenance = b.createModule(.{
        .root_source_file = b.path("core/maint/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "storage", .module = storage },
            .{ .name = "proto", .module = proto },
            .{ .name = "utils", .module = utils },
            .{ .name = "journal", .module = journal },
            .{ .name = "legacy_handoff", .module = session },
            .{ .name = "ext2fs_c", .module = ext.bindings },
            .{ .name = "fatfs_c", .module = fat.bindings },
            .{ .name = "ntfs_c", .module = ntfs.bindings },
            .{ .name = "btrfs_c", .module = btrfs.bindings },
        },
    });
    return .{ .maintenance = maintenance, .storage = storage, .tui = tui, .ext = ext, .fat = fat, .ntfs = ntfs, .btrfs = btrfs };
}

fn command(
    b: *std.Build,
    tool: *std.Build.Step.Compile,
    args: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(tool);
    run.setCwd(b.path("."));
    run.addArgs(args);
    return run;
}

/// Link production and separate acceptance entry points with the pinned compiler.
/// Zig 0.17's Maker keeps an argv slice into a temporary Target.Query dynamic
/// linker buffer (Maker/Step/Compile.zig), emitting an empty --dynamic-linker.
/// Use the same module graph as a normal Compile step, but give the compiler a
/// stable argument for PT_INTERP. No ELF is patched.
fn maintenanceExecutable(
    b: *std.Build,
    binary_name: []const u8,
    root: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
    ext: ext_build.Result,
    fat: fat_build.Result,
    ntfs: ntfs_build.Result,
    btrfs: btrfs_build.Result,
) struct { producer: *std.Build.Step.Run, binary: std.Build.LazyPath } {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe, "build-exe", "-fincremental",    "-fno-lld",                 "-fnew-linker", "-dynamic",       "-lc",
        "--name",        binary_name, "--dynamic-linker", "lib/ld-linux-x86-64.so.2", "-rpath",       "$ORIGIN/../lib",
    });
    run.setCwd(b.path("."));
    run.addFileArg(ext.ext_archive);
    run.addFileArg(ext.error_archive);
    run.addFileArg(fat.archive);
    run.addFileArg(ntfs.archive);
    run.addFileArg(btrfs.archive);
    // Run the compiler's own cache check each time: it tracks transitive Zig
    // imports, whereas a generic Run step only hashes its explicit file inputs.
    run.has_side_effects = true;
    compile_policy.watchSources(b, run);
    run.addArg("--enable-new-dtags");
    const triple = root.resolved_target.?.query.zigTriple(b.allocator) catch @panic("OOM");
    const graph = root.getGraph();
    for (graph.modules, graph.names) |module, name| {
        run.addArgs(&.{ b.fmt("-O{s}", .{@tagName(module.optimize orelse optimize)}), "-target", triple, "-mcpu", "baseline" });
        for (module.import_table.keys(), module.import_table.values()) |alias, imported| {
            const index = std.mem.indexOfScalar(*std.Build.Module, graph.modules, imported).?;
            run.addArgs(&.{ "--dep", b.fmt("{s}={s}", .{ alias, graph.names[index] }) });
        }
        run.addPrefixedFileArg(b.fmt("-M{s}=", .{name}), module.root_source_file.?);
    }
    const binary = run.addPrefixedOutputFileArg("-femit-bin=", binary_name);
    return .{ .producer = run, .binary = binary };
}

/// Host-only test harness: explicitly load the same binary that is shipped in the bundle.
fn maintenanceTestCommand(
    b: *std.Build,
    loader: []const u8,
    application: std.Build.LazyPath,
    args: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{loader});
    run.addFileArg(application);
    run.setCwd(b.path("."));
    run.addArgs(args);
    return run;
}

fn requireHostTool(
    b: *std.Build,
    variable: []const u8,
    default: []const u8,
) []const u8 {
    const name = b.graph.environ_map.get(variable) orelse default;
    return b.findProgram(.{ .names = &.{name} }) orelse
        std.process.fatal(
            "Required host tool '{s}' is unavailable; install it and add it to PATH (or set {s}).",
            .{ name, variable },
        );
}

fn sessionModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
    proto: *std.Build.Module,
    utils: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("core/legacy_handoff.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "utils", .module = utils } },
    });
}
