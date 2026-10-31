//! Dynamically linked glibc probe for an explicitly unpacked matrix runtime.
const std = @import("std");

extern "c" fn gnu_get_libc_version() [*:0]const u8;
extern "c" fn fgets([*]u8, c_int, *std.c.FILE) ?[*:0]u8;
extern "c" fn ferror(*std.c.FILE) c_int;
extern "c" fn fprintf(*std.c.FILE, [*:0]const u8, ...) c_int;
extern "c" var stderr: *std.c.FILE;

comptime {
    if (@import("builtin").target.abi != .gnu or !@import("builtin").link_libc)
        @compileError("The ABI checker must dynamically link glibc.");
}

/// Reports the loaded glibc, resolves optional SONAMEs and rejects host mappings.
pub fn main(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    // The matrix invokes the bundled loader before establishing this CWD.
    var first_library: usize = 1;
    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "--bundle-root")) {
        if (std.c.chdir(argv[2]) != 0) return 7;
        first_library = 3;
    }
    var root_buffer: [4096]u8 = undefined;
    if (std.c.getcwd(&root_buffer, root_buffer.len) == null) return 7;
    const root = std.mem.sliceTo(&root_buffer, 0);
    var kernel: std.c.utsname = undefined;
    if (std.c.uname(&kernel) != 0) return 1;
    _ = std.c.printf("PIZZA_ABI_KERNEL:%s\nPIZZA_ABI_BUNDLED_GLIBC:%s\n", &kernel.release, gnu_get_libc_version());
    for (argv[first_library..]) |library| {
        // Use glibc's loader, including eager symbol resolution and local scope.
        if (std.c.dlopen(library, .{ .NOW = true }) == null) {
            _ = fprintf(stderr, "PIZZA_ABI_DLOPEN_FAILED:%s:%s\n", library.ptr, std.c.dlerror() orelse "unknown loader error");
            return 2;
        }
    }
    const maps = std.c.fopen("/proc/self/maps", "r") orelse return 3;
    defer _ = std.c.fclose(maps);
    var line: [4096]u8 = undefined;
    var mapped_files: usize = 0;
    while (fgets(&line, line.len, maps)) |text| {
        const bytes = std.mem.span(text);
        if (std.mem.indexOfScalar(u8, bytes, '/')) |start| {
            const path = bytes[start..];
            mapped_files += 1;
            if (!std.mem.startsWith(u8, path, root) or
                (root.len > 1 and (path.len <= root.len or path[root.len] != '/')))
            {
                _ = fprintf(stderr, "PIZZA_ABI_HOST_MAPPING:%s", text + start);
                return 4;
            }
        }
    }
    if (ferror(maps) != 0) return 5;
    if (mapped_files == 0) return 6;
    _ = std.c.printf("PIZZA_ABI_SELF_CONTAINED:mapped_files=%zu\n", mapped_files);
    return 0;
}
