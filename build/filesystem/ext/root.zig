//! Pinned C sources, generated headers, static libraries and translated Zig API.
//! Every step is declared here; no configure, make, shell or host libext2fs.
const std = @import("std");
const compile_policy = @import("../../compile.zig");

pub const Result = struct {
    bindings: *std.Build.Module,
    ext_archive: std.Build.LazyPath,
    error_archive: std.Build.LazyPath,
};

pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Result {
    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64)
        @panic("e2fsprogs configuration currently supports x86_64 Linux");
    const source = b.dependency("e2fsprogs", .{});
    const headers = b.named_lazy_paths.get("pizza-ext-headers") orelse headers: {
        const generator = b.addExecutable(.{ .name = "ext-headers", .root_module = b.createModule(.{ .root_source_file = b.path("build/filesystem/ext/generate.zig"), .target = b.graph.host, .optimize = .safe }) });
        compile_policy.configure(generator);
        const run = b.addRunArtifact(generator);
        const headers = run.addOutputDirectoryArg("ext-headers");
        run.addFileArg(source.path("lib/ext2fs/ext2_types.h.in"));
        run.addFileArg(source.path("lib/ext2fs/ext2_err.et.in"));
        run.addFileArg(source.path("lib/ext2fs/ext2fs.h"));
        b.addNamedLazyPath("pizza-ext-headers", headers);
        break :headers headers;
    };
    const config = b.addConfigHeader(.{ .include_path = "config.h" }, .{
        .CONFIG_DISABLE_LIBARCHIVE = 1,
        .CONFIG_MMP = 1,
        .ENABLE_BMAP_STATS = 1,
        .SIZEOF_INT = 4,
        .SIZEOF_LONG = 8,
        .SIZEOF_LONG_LONG = 8,
        .SIZEOF_OFF_T = 8,
        .SIZEOF_SHORT = 2,
        .SIZEOF_TIME_T = 8,
        .SIZEOF_VOID_P = 8,
        .STDC_HEADERS = 1,
        .PACKAGE = "e2fsprogs",
        .VERSION = "1.47.4",
    });
    config.addIdent("TLS", "_Thread_local");
    for (LINUX_FEATURES) |feature| config.addValue(feature, u8, 1);
    const table_headers = b.named_lazy_paths.get("pizza-ext-crc-table") orelse generated: {
        const crc_generator = b.addExecutable(.{ .name = "ext-crc-table", .root_module = b.createModule(.{ .target = b.graph.host, .optimize = .safe, .link_libc = true }) });
        compile_policy.configure(crc_generator);
        crc_generator.root_module.addCSourceFile(.{ .file = source.path("lib/ext2fs/gen_crc32ctable.c"), .flags = &.{"-std=gnu11"} });
        const table = b.addRunArtifact(crc_generator).captureStdOut(.{});
        const tables = b.addWriteFiles();
        _ = tables.addCopyFile(table, "crc32c_table.h");
        const directory = tables.getDirectory();
        b.addNamedLazyPath("pizza-ext-crc-table", directory);
        break :generated directory;
    };
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    module.addConfigHeader(config);
    module.addIncludePath(headers);
    module.addIncludePath(headers.path(b, "ext2fs"));
    module.addIncludePath(table_headers);
    module.addIncludePath(source.path("lib"));
    module.addIncludePath(source.path("lib/ext2fs"));
    module.addIncludePath(source.path("lib/et"));
    module.addCSourceFiles(.{ .root = source.path("."), .files = &SOURCES, .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-fno-strict-aliasing" } });
    module.addCSourceFile(.{ .file = headers.path(b, "ext2_err.c"), .flags = &.{"-std=gnu11"} });
    const library = b.addLibrary(.{ .name = "pizza_ext2fs", .linkage = .static, .root_module = module });
    compile_policy.configure(library);
    const errors = b.addLibrary(.{ .name = "pizza_com_err", .linkage = .static, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true }) });
    compile_policy.configure(errors);
    errors.root_module.addConfigHeader(config);
    errors.root_module.addIncludePath(source.path("lib"));
    errors.root_module.addCSourceFiles(.{ .root = source.path("lib/et"), .files = &.{ "error_message.c", "et_name.c", "init_et.c", "com_err.c", "com_right.c" }, .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE" } });
    // This is the upstream public header, with only a macro parameter renamed
    // in the generated copy to work around Zig 0.17's typedef-shadowing bug.
    const translated = b.addTranslateC(.{ .root_source_file = headers.path(b, "ext2fs/ext2fs.h"), .target = target, .optimize = optimize });
    translated.addIncludePath(headers);
    translated.addIncludePath(source.path("lib"));
    translated.addIncludePath(source.path("lib/ext2fs"));
    translated.defineCMacro("NO_INLINE_FUNCS", null);
    translated.defineCMacro("HAVE_SYS_TYPES_H", "1");
    translated.defineCMacro("HAVE_SYS_TIME_H", "1");
    const bindings = translated.createModule();
    bindings.linkLibrary(library);
    bindings.linkLibrary(errors);
    return .{ .bindings = bindings, .ext_archive = library.getEmittedBin(), .error_archive = errors.getEmittedBin() };
}

// lib/ext2fs/Makefile.in OBJS for e2fsprogs 1.47.4, plus its normal optional
// record and read-only inspection helpers. No resize2fs objects are linked.
const SOURCES = [_][]const u8{
    "lib/ext2fs/alloc.c",
    "lib/ext2fs/alloc_sb.c",
    "lib/ext2fs/alloc_stats.c",
    "lib/ext2fs/alloc_tables.c",
    "lib/ext2fs/atexit.c",
    "lib/ext2fs/badblocks.c",
    "lib/ext2fs/bb_inode.c",
    "lib/ext2fs/bitmaps.c",
    "lib/ext2fs/bitops.c",
    "lib/ext2fs/blkmap64_ba.c",
    "lib/ext2fs/blkmap64_rb.c",
    "lib/ext2fs/blknum.c",
    "lib/ext2fs/block.c",
    "lib/ext2fs/bmap.c",
    "lib/ext2fs/check_desc.c",
    "lib/ext2fs/closefs.c",
    "lib/ext2fs/crc16.c",
    "lib/ext2fs/crc32c.c",
    "lib/ext2fs/csum.c",
    "lib/ext2fs/dblist.c",
    "lib/ext2fs/dblist_dir.c",
    "lib/ext2fs/dirblock.c",
    "lib/ext2fs/dirhash.c",
    "lib/ext2fs/dir_iterate.c",
    "lib/ext2fs/expanddir.c",
    "lib/ext2fs/ext_attr.c",
    "lib/ext2fs/extent.c",
    "lib/ext2fs/fallocate.c",
    "lib/ext2fs/fileio.c",
    "lib/ext2fs/finddev.c",
    "lib/ext2fs/flushb.c",
    "lib/ext2fs/freefs.c",
    "lib/ext2fs/gen_bitmap.c",
    "lib/ext2fs/gen_bitmap64.c",
    "lib/ext2fs/get_num_dirs.c",
    "lib/ext2fs/get_pathname.c",
    "lib/ext2fs/getenv.c",
    "lib/ext2fs/getsize.c",
    "lib/ext2fs/getsectsize.c",
    "lib/ext2fs/hashmap.c",
    "lib/ext2fs/i_block.c",
    "lib/ext2fs/icount.c",
    "lib/ext2fs/ind_block.c",
    "lib/ext2fs/initialize.c",
    "lib/ext2fs/inline.c",
    "lib/ext2fs/inline_data.c",
    "lib/ext2fs/inode.c",
    "lib/ext2fs/io_manager.c",
    "lib/ext2fs/ismounted.c",
    "lib/ext2fs/link.c",
    "lib/ext2fs/llseek.c",
    "lib/ext2fs/lookup.c",
    "lib/ext2fs/mkdir.c",
    "lib/ext2fs/mkjournal.c",
    "lib/ext2fs/mmp.c",
    "lib/ext2fs/namei.c",
    "lib/ext2fs/native.c",
    "lib/ext2fs/newdir.c",
    "lib/ext2fs/nls_utf8.c",
    "lib/ext2fs/openfs.c",
    "lib/ext2fs/orphan.c",
    "lib/ext2fs/progress.c",
    "lib/ext2fs/punch.c",
    "lib/ext2fs/qcow2.c",
    "lib/ext2fs/read_bb.c",
    "lib/ext2fs/read_bb_file.c",
    "lib/ext2fs/res_gdt.c",
    "lib/ext2fs/rw_bitmaps.c",
    "lib/ext2fs/sha512.c",
    "lib/ext2fs/swapfs.c",
    "lib/ext2fs/symlink.c",
    "lib/ext2fs/undo_io.c",
    "lib/ext2fs/unix_io.c",
    "lib/ext2fs/sparse_io.c",
    "lib/ext2fs/unlink.c",
    "lib/ext2fs/valid_blk.c",
    "lib/ext2fs/version.c",
    "lib/ext2fs/rbtree.c",
    "lib/ext2fs/dupfs.c",
    "lib/ext2fs/imager.c",
    "lib/ext2fs/bb_compat.c",
    "lib/ext2fs/inode_io.c",
    "lib/ext2fs/write_bb_file.c",
};

const LINUX_FEATURES = [_][]const u8{
    "HAVE_DIRENT_H",       "HAVE_ERRNO_H",             "HAVE_FALLOCATE",       "HAVE_FCHOWN",         "HAVE_FCNTL",         "HAVE_FDATASYNC",    "HAVE_FSYNC",
    "HAVE_FUTIMES",        "HAVE_GETCWD",              "HAVE_GETDTABLESIZE",   "HAVE_GETENTROPY",     "HAVE_GETHOSTNAME",   "HAVE_GETOPT_H",     "HAVE_GETPWUID_R",
    "HAVE_GETRANDOM",      "HAVE_GETRLIMIT",           "HAVE_GETRUSAGE",       "HAVE_GNU_QSORT_R",    "HAVE_INTPTR_T",      "HAVE_INTTYPES_H",   "HAVE_JRAND48",
    "HAVE_LINUX_FALLOC_H", "HAVE_LINUX_FD_H",          "HAVE_LINUX_LOOP_H",    "HAVE_LINUX_MAJOR_H",  "HAVE_LINUX_TYPES_H", "HAVE_LLISTXATTR",   "HAVE_MALLOC_H",
    "HAVE_MBSTOWCS",       "HAVE_MEMALIGN",            "HAVE_MEMPCPY",         "HAVE_MMAP",           "HAVE_MNTENT_H",      "HAVE_MOUNT_NODEV",  "HAVE_MOUNT_NOSUID",
    "HAVE_MSYNC",          "HAVE_NANOSLEEP",           "HAVE_NETINET_IN_H",    "HAVE_NET_IF_H",       "HAVE_PATHCONF",      "HAVE_PATHS_H",      "HAVE_POSIX_FADVISE",
    "HAVE_POSIX_MEMALIGN", "HAVE_PRCTL",               "HAVE_PREAD",           "HAVE_PTHREAD",        "HAVE_PTHREAD_H",     "HAVE_PWRITE",       "HAVE_QSORT_R",
    "HAVE_RECLEN_DIRENT",  "HAVE_SECURE_GETENV",       "HAVE_SEMAPHORE_H",     "HAVE_SETJMP_H",       "HAVE_SETMNTENT",     "HAVE_SETRESGID",    "HAVE_SETRESUID",
    "HAVE_SIGNAL_H",       "HAVE_SNPRINTF",            "HAVE_SRANDOM",         "HAVE_STDARG_H",       "HAVE_STDINT_H",      "HAVE_STDIO_H",      "HAVE_STDLIB_H",
    "HAVE_STPCPY",         "HAVE_STRCASECMP",          "HAVE_STRDUP",          "HAVE_STRINGS_H",      "HAVE_STRING_H",      "HAVE_STRNLEN",      "HAVE_STRPTIME",
    "HAVE_STRTOULL",       "HAVE_STRUCT_STAT_ST_ATIM", "HAVE_SYNC_FILE_RANGE", "HAVE_SYSCONF",        "HAVE_SYS_FILE_H",    "HAVE_SYS_IOCTL_H",  "HAVE_SYS_MMAN_H",
    "HAVE_SYS_MOUNT_H",    "HAVE_SYS_PRCTL_H",         "HAVE_SYS_RANDOM_H",    "HAVE_SYS_RESOURCE_H", "HAVE_SYS_SELECT_H",  "HAVE_SYS_SOCKET_H", "HAVE_SYS_STAT_H",
    "HAVE_SYS_SYSCALL_H",  "HAVE_SYS_SYSMACROS_H",     "HAVE_SYS_TIME_H",      "HAVE_SYS_TYPES_H",    "HAVE_SYS_UN_H",      "HAVE_SYS_WAIT_H",   "HAVE_SYS_XATTR_H",
    "HAVE_TERMIOS_H",      "HAVE_TYPE_SSIZE_T",        "HAVE_UNISTD_H",        "HAVE_USLEEP",         "HAVE_UTIME",         "HAVE_UTIMES",       "HAVE_UTIME_H",
    "HAVE_VALLOC",         "HAVE_VPRINTF",             "HAVE_WCHAR_H",
};
