const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("pizza_protocol", .{ .root_source_file = b.path("root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = module });
    tests.incremental = true;
    switch (target.result.os.tag) {
        .windows => tests.use_lld = false, // Zig's Coff.zig linker.
        .linux => {
            tests.use_lld = false;
            tests.use_new_linker = true; // Zig's Elf2.zig linker.
        },
        else => {},
    }
    b.step("test", "Verify the protocol package independently").dependOn(&b.addRunArtifact(tests).step);
}
