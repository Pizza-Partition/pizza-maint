//! Generate a configured copy of the pinned upstream FatFs sources. Only Zig
//! build steps are used. Original copyright notices remain in every C file.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 6) return error.InvalidArguments;
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer dir.close(init.io);
    const names = [_][]const u8{ "ff.h", "ffunicode.c", "diskio.h", "ffconf.h" };
    for (names, args[2..]) |name, path| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(8 * 1024 * 1024));
        var bytes = try std.mem.replaceOwned(u8, a, raw, "\r\n", "\n");
        if (std.mem.eql(u8, name, "ffconf.h")) {
            var result: std.Io.Writer.Allocating = .init(a);
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                var words = std.mem.tokenizeAny(u8, line, " \t");
                const directive = words.next() orelse "";
                const macro = words.next() orelse "";
                const configured: ?[]const u8 = if (std.mem.eql(u8, macro, "FF_USE_MKFS")) "0" else if (std.mem.eql(u8, macro, "FF_FS_READONLY")) "1" else if (std.mem.eql(u8, macro, "FF_CODE_PAGE")) "437" else if (std.mem.eql(u8, macro, "FF_USE_LFN")) "2" else if (std.mem.eql(u8, macro, "FF_LFN_UNICODE")) "2" else if (std.mem.eql(u8, macro, "FF_LFN_BUF")) "1020" else if (std.mem.eql(u8, macro, "FF_MAX_SS")) "4096" else if (std.mem.eql(u8, macro, "FF_FS_NORTC")) "1" else if (std.mem.eql(u8, macro, "FF_FS_NOFSINFO")) "3" else null;
                if (std.mem.eql(u8, directive, "#define") and configured != null) try result.writer.print("#define {s} {s}\n", .{ macro, configured.? }) else try result.writer.print("{s}\n", .{line});
            }
            bytes = try result.toOwnedSlice();
        }
        try dir.writeFile(init.io, .{ .sub_path = name, .data = bytes });
    }
}
