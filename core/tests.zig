const std = @import("std");
const proto = @import("proto");

test "all subsystem boundaries compile" {
    std.testing.refAllDecls(@import("init/cmdline.zig"));
    std.testing.refAllDecls(@import("init/memory.zig"));
    std.testing.refAllDecls(@import("init/mounts.zig"));
    std.testing.refAllDecls(@import("init/modules.zig"));
    std.testing.refAllDecls(@import("init/supervisor.zig"));
    std.testing.refAllDecls(@import("init/recovery.zig"));
    std.testing.refAllDecls(@import("journal"));
    std.testing.refAllDecls(@import("maintenance").backend);
    std.testing.refAllDecls(@import("maintenance").plan);
    _ = @import("maintenance").Testing.execution_tests;
    _ = @import("maintenance").Testing.simulated_plan;
    std.testing.refAllDecls(@import("maintenance").storage);
    std.testing.refAllDecls(@import("execution_tui"));
    std.testing.refAllDecls(proto);
}
