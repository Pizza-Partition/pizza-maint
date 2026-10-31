//! Pinned libntfs-3g read/codec primitives, built entirely by Zig.
const std = @import("std");
const compile_policy = @import("../../compile.zig");
pub const Result = struct { bindings: *std.Build.Module, archive: std.Build.LazyPath };
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Result {
    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) @panic("NTFS configuration requires x86_64 Linux");
    const source = b.dependency("ntfs3g", .{});
    const generator = b.addExecutable(.{ .name = "ntfs-sources", .root_module = b.createModule(.{ .root_source_file = b.path("build/filesystem/ntfs/generate.zig"), .target = b.graph.host, .optimize = .safe }) });
    compile_policy.configure(generator);
    const run = b.addRunArtifact(generator);
    const generated = run.addOutputDirectoryArg("ntfs");
    const config = b.addConfigHeader(.{ .include_path = "config.h" }, .{ .VERSION = "2026.9.28", .PACKAGE = "ntfs-3g", .PACKAGE_VERSION = "2026.9.28", .STDC_HEADERS = 1, .WORDS_LITTLEENDIAN = 1, ._FILE_OFFSET_BITS = 64, .DISABLE_PLUGINS = 1 });
    for (FEATURES) |feature| config.addValue(feature, u8, 1);
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    module.addConfigHeader(config);
    module.addIncludePath(source.path("include/ntfs-3g"));
    module.addIncludePath(source.path("ntfsprogs"));
    module.addIncludePath(generated);
    module.addCSourceFiles(.{ .root = source.path("libntfs-3g"), .files = &SOURCES, .flags = &FLAGS });
    for ([_][]const u8{ "attrdef.c", "sd.c" }) |name| module.addCSourceFile(.{ .file = source.path(b.fmt("ntfsprogs/{s}", .{name})), .flags = &FLAGS });

    module.addCSourceFile(.{ .file = generated.path(b, "runtime.c"), .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-DHAVE_CONFIG_H" } });
    const library = b.addLibrary(.{ .name = "pizza_ntfs", .linkage = .static, .root_module = module });
    compile_policy.configure(library);
    const translated = b.addTranslateC(.{ .root_source_file = source.path("include/ntfs-3g/volume.h"), .target = target, .optimize = optimize });
    translated.addConfigHeader(config);
    translated.addIncludePath(source.path("include/ntfs-3g"));
    translated.defineCMacro("HAVE_CONFIG_H", "1");
    const bindings = translated.createModule();
    bindings.linkLibrary(library);
    return .{ .bindings = bindings, .archive = library.getEmittedBin() };
}
const FLAGS = [_][]const u8{ "-std=gnu11", "-D_GNU_SOURCE", "-DHAVE_CONFIG_H", "-fno-strict-aliasing", "-Wno-address-of-packed-member", "-Dmalloc=pizza_ntfs_malloc", "-Dcalloc=pizza_ntfs_calloc", "-Drealloc=pizza_ntfs_realloc", "-Dfree=pizza_ntfs_free", "-Dstrdup=pizza_ntfs_strdup", "-Dexit=pizza_ntfs_exit" };
const SOURCES = [_][]const u8{ "acls.c", "attrib.c", "attrlist.c", "bitmap.c", "bootsect.c", "cache.c", "collate.c", "compat.c", "compress.c", "debug.c", "device.c", "dir.c", "ea.c", "efs.c", "index.c", "inode.c", "ioctl.c", "lcnalloc.c", "logfile.c", "logging.c", "mft.c", "misc.c", "mst.c", "object_id.c", "realpath.c", "reparse.c", "runlist.c", "security.c", "unistr.c", "volume.c", "xattrs.c" };
const FEATURES = [_][]const u8{ "HAVE_DAEMON", "HAVE_REALPATH", "HAVE_BYTESWAP_H", "HAVE_CLOCK_GETTIME", "HAVE_CTYPE_H", "HAVE_ENDIAN_H", "HAVE_ERRNO_H", "HAVE_FCNTL_H", "HAVE_FFS", "HAVE_GETOPT_H", "HAVE_GETOPT_LONG", "HAVE_GETTIMEOFDAY", "HAVE_INTTYPES_H", "HAVE_LIMITS_H", "HAVE_LINUX_FS_H", "HAVE_LINUX_HDREG_H", "HAVE_LOCALE_H", "HAVE_MALLOC_H", "HAVE_LIBGEN_H", "MAJOR_IN_SYSMACROS", "HAVE_MEMCPY", "HAVE_MEMMOVE", "HAVE_MEMSET", "HAVE_RANDOM", "HAVE_SNPRINTF", "HAVE_STDARG_H", "HAVE_STDBOOL_H", "HAVE_STDDEF_H", "HAVE_STDINT_H", "HAVE_STDIO_H", "HAVE_STDLIB_H", "HAVE_STRCASECMP", "HAVE_STRCHR", "HAVE_STRDUP", "HAVE_STRERROR", "HAVE_STRFTIME", "HAVE_STRINGS_H", "HAVE_STRING_H", "HAVE_STRNLEN", "HAVE_STRSEP", "HAVE_STRTOL", "HAVE_STRTOUL", "HAVE_STRUCT_STAT_ST_BLOCKS", "HAVE_STRUCT_STAT_ST_RDEV", "HAVE_SYSCONF", "HAVE_SYS_IOCTL_H", "HAVE_SYS_PARAM_H", "HAVE_SYS_STAT_H", "HAVE_SYS_TYPES_H", "HAVE_TIME_H", "HAVE_UNISTD_H", "HAVE_VPRINTF", "HAVE_WCHAR_H", "HAVE__BOOL" };
