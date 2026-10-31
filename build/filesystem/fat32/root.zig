//! Pinned FatFs Unicode helpers only; filesystem algorithms and disk I/O are Zig.
const std = @import("std");
const compile_policy = @import("../../compile.zig");
pub const Result = struct { bindings: *std.Build.Module, archive: std.Build.LazyPath };
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Result {
    const source = b.dependency("fatfs", .{});
    const generator = b.addExecutable(.{ .name = "fatfs-sources", .root_module = b.createModule(.{ .root_source_file = b.path("build/filesystem/fat32/generate.zig"), .target = b.graph.host, .optimize = .safe }) });
    compile_policy.configure(generator);
    const run = b.addRunArtifact(generator);
    const generated = run.addOutputDirectoryArg("fatfs");
    for ([_][]const u8{ "ff.h", "ffunicode.c", "diskio.h", "ffconf.h" }) |name| run.addFileArg(source.path(b.fmt("source/{s}", .{name})));
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    module.addIncludePath(generated);
    module.addCSourceFile(.{ .file = generated.path(b, "ffunicode.c"), .flags = &.{"-std=c99"} });
    const library = b.addLibrary(.{ .name = "pizza_fat_unicode", .linkage = .static, .root_module = module });
    compile_policy.configure(library);
    const translated = b.addTranslateC(.{ .root_source_file = generated.path(b, "ff.h"), .target = target, .optimize = optimize });
    translated.addIncludePath(generated);
    const bindings = translated.createModule();
    bindings.linkLibrary(library);
    return .{ .bindings = bindings, .archive = library.getEmittedBin() };
}
