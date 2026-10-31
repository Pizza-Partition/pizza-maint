//! The pinned public libbtrfs library and the actual on-disk UAPI, without
//! mounting, host development packages, configure, make, or shell scripts.
const std = @import("std");
const compile_policy = @import("../../compile.zig");
pub const Result = struct { bindings: *std.Build.Module, archive: std.Build.LazyPath };
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Result {
    const source = b.dependency("btrfs", .{});
    const config = b.addConfigHeader(.{ .include_path = "config.h" }, .{ .BTRFS_FLAT_INCLUDES = 1, .HAVE_CONFIG_H = 1 });
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    module.addConfigHeader(config);
    module.addIncludePath(source.path("."));
    module.addIncludePath(source.path("libbtrfs"));
    module.addCSourceFiles(.{ .root = source.path("."), .files = &.{ "kernel-lib/rbtree.c", "libbtrfs/send-stream.c", "libbtrfs/send-utils.c", "libbtrfs/crc32c.c" }, .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-DBTRFS_FLAT_INCLUDES=1", "-fno-strict-aliasing", "-Wno-address-of-packed-member" } });
    const library = b.addLibrary(.{ .name = "pizza_btrfs", .linkage = .static, .root_module = module });
    compile_policy.configure(library);
    const ondisk = b.addTranslateC(.{ .root_source_file = source.path("kernel-shared/uapi/btrfs_tree.h"), .target = target, .optimize = optimize });
    ondisk.addIncludePath(source.path("."));
    const checksum = b.addTranslateC(.{ .root_source_file = source.path("libbtrfs/crc32c.h"), .target = target, .optimize = optimize });
    const bindings = b.createModule(.{ .root_source_file = b.path("build/filesystem/btrfs/bindings.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ondisk", .module = ondisk.createModule() }, .{ .name = "checksum", .module = checksum.createModule() } } });
    bindings.linkLibrary(library);
    return .{ .bindings = bindings, .archive = library.getEmittedBin() };
}
