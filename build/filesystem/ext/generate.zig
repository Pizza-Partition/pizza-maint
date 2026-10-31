//! Build-time generators for the pinned e2fsprogs templates; no shell tools.
const std = @import("std");

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    fn fmt(self: *Context, comptime format: []const u8, args: anytype) []u8 {
        return self.allocator.print(format, args) catch @panic("OOM");
    }
    fn add(self: *Context, path: []const u8, data: []const u8) void {
        self.directory.writeFile(self.io, .{ .sub_path = path, .data = data }) catch @panic("Cannot write generated e2fsprogs file");
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) return error.InvalidArguments;
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    var directory = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer directory.close(init.io);
    try directory.createDirPath(init.io, "ext2fs");
    var context: Context = .{ .allocator = a, .io = init.io, .directory = directory };
    var types = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(1024 * 1024));
    const substitutions = .{
        .{ "ASM_TYPES_HEADER", "" }, .{ "SIZEOF_INT", "4" },       .{ "SIZEOF_SHORT", "2" },
        .{ "SIZEOF_LONG", "8" },     .{ "SIZEOF_LONG_LONG", "8" }, .{ "PUBLIC_CONFIG_HEADER", "#define HAVE_SYS_TYPES_H 1\n#define SIZEOF_TIME_T 8\n#undef WORDS_BIGENDIAN" },
    };
    inline for (substitutions) |pair| types = replace(&context, types, "@" ++ pair[0] ++ "@", pair[1]);
    context.add("ext2fs/ext2_types.h", types);
    const errors = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], a, .limited(1024 * 1024));
    errorTable(&context, &context, errors);
    const header = try std.Io.Dir.cwd().readFileAlloc(init.io, args[4], a, .limited(1024 * 1024));
    const from = "#define EXT2FS_B2C(fs, blk)\t\t((blk) >> (fs)->cluster_ratio_bits)";
    if (std.mem.count(u8, header, from) != 1) return error.TranslateCMacroWorkaroundChanged;
    context.add("ext2fs/ext2fs.h", replace(&context, header, from, "#define EXT2FS_B2C(fs, block_arg) ((block_arg) >> (fs)->cluster_ratio_bits)"));
}

fn replace(b: *Context, input: []const u8, from: []const u8, to: []const u8) []u8 {
    return std.mem.replaceOwned(u8, b.allocator, input, from, to) catch @panic("OOM");
}

fn errorTable(b: *Context, files: *Context, template: []const u8) void {
    const input = replace(b, template, "@E2FSPROGS_VERSION@", "1.47.4");
    var header: std.ArrayList(u8) = .empty;
    var messages: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    var pending: ?[]const u8 = null;
    var count: u32 = 0;
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, text, "ec\t") or std.mem.startsWith(u8, text, "ec ")) {
            if (pending != null) @panic("Unexpected ext2 error table grammar");
            const comma = std.mem.indexOfScalar(u8, text, ',') orelse @panic("Invalid ext2 error code");
            pending = std.mem.trim(u8, text[2..comma], " \t");
        } else if (pending) |name| {
            if (text.len == 0 or text[0] == '#') continue;
            if (text[0] != '"' or text[text.len - 1] != '"') @panic("Unexpected ext2 message grammar");
            header.appendSlice(b.allocator, b.fmt("#define {s} ({d}L)\n", .{ name, 2133571328 + @as(u64, count) })) catch @panic("OOM");
            messages.appendSlice(b.allocator, b.fmt("{s},\n", .{text})) catch @panic("OOM");
            count += 1;
            pending = null;
        }
    }
    if (pending != null or count != 183) @panic("Pinned ext2 error table changed; audit the generator");
    _ = files.add("ext2fs/ext2_err.h", b.fmt("#include <et/com_err.h>\n{s}\nextern const struct error_table et_ext2_error_table;\nvoid initialize_ext2_error_table(void);\nvoid initialize_ext2_error_table_r(struct et_list **);\n#define ERROR_TABLE_BASE_ext2 2133571328L\n#define init_ext2_err_tbl initialize_ext2_error_table\n#define ext2_err_base ERROR_TABLE_BASE_ext2\n", .{header.items}));
    _ = files.add("ext2_err.c", b.fmt(
        \\/* Generated from the pinned e2fsprogs error table. */
        \\#include <stdlib.h>
        \\#include <et/com_err.h>
        \\#include <et/error_table.h>
        \\static const char *const messages[] = {{
        \\{s}0 }};
        \\const struct error_table et_ext2_error_table = {{ messages, 2133571328L, {d} }};
        \\void initialize_ext2_error_table_r(struct et_list **list) {{
        \\    struct et_list **tail = list, *node;
        \\    while (*tail) {{
        \\        if ((*tail)->table->msgs == messages) return;
        \\        tail = &(*tail)->next;
        \\    }}
        \\    node = malloc(sizeof(*node));
        \\    if (!node) return;
        \\    node->next = 0; node->table = &et_ext2_error_table; *tail = node;
        \\}}
        \\void initialize_ext2_error_table(void) {{ initialize_ext2_error_table_r(&_et_list); }}
        \\
    , .{ messages.items, count }));
}
