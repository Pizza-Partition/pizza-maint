//! Unit-test entry point; production storage never imports test suites.
const std = @import("std");
const storage = @import("storage");

test {
    std.testing.refAllDecls(storage.model);
    std.testing.refAllDecls(storage.device);
    std.testing.refAllDecls(storage.filesystem);
    std.testing.refAllDecls(storage.testing.executor);
    std.testing.refAllDecls(storage.probe);
    std.testing.refAllDecls(storage.partition);
    std.testing.refAllDecls(storage.mutation);
    std.testing.refAllDecls(storage.space);
    std.testing.refAllDecls(storage.testing.ImageDevice);
    std.testing.refAllDecls(storage.partition_table);
    std.testing.refAllDecls(storage.program);
    std.testing.refAllDecls(storage.semantic);
    std.testing.refAllDecls(storage.algorithm);
    std.testing.refAllDecls(storage.service);
    std.testing.refAllDecls(storage.program_executor);
    _ = @import("planning_tests.zig");
    _ = @import("program_tests.zig");
    _ = @import("capsule_tests.zig");
    _ = @import("maintenance_session_tests.zig");
    _ = @import("gpt_tests.zig");
    _ = @import("semantic_contract_tests.zig");
    _ = @import("probe_tests.zig");
    _ = @import("block_device_tests.zig");
    _ = @import("tests.zig");
    _ = @import("memory_tests.zig");
}
