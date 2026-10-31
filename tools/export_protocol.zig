//! Export the storage-independent protocol package with a content manifest.
const std = @import("std");
const FILES = [_][]const u8{ "build.zig", "build.zig.zon", "README.md", "root.zig", "contract.json", "generated.zig", "generated/contract.js", "generated/contract.d.ts" };
const Entry = struct { name: []const u8, sha256: []const u8 };
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != FILES.len + 3) return error.ExpectedExportDirectoryArchiveAndProtocolFiles;
    const output = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
    defer output.close(init.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = output.writer(init.io, &buffer);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var compression = try std.compress.flate.Compress.init(&writer.interface, window, .gzip, .default);
    var tar: std.tar.Writer = .{ .underlying_writer = &compression.writer };
    try tar.writeDir("pizza-protocol", .{ .mode = 0o755 });
    tar.prefix = "pizza-protocol";
    try tar.writeDir("generated", .{ .mode = 0o755 });
    var entries: std.ArrayList(Entry) = .empty;
    for (FILES, 0..) |name, index| {
        const source = args[index + 3];
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, source, a, .limited(16 * 1024 * 1024));
        const destination = try std.fs.path.join(a, &.{ args[1], name });
        try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(destination).?);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = destination, .data = bytes });
        try tar.writeFileBytes(name, bytes, .{ .mode = 0o644 });
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        try entries.append(a, .{ .name = name, .sha256 = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) });
    }
    const manifest = try std.json.Stringify.valueAlloc(a, .{ .wire_version = @as(u16, 4), .source = "pizza-maint", .files = entries.items }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ args[1], "manifest.json" }), .data = manifest });
    try tar.writeFileBytes("manifest.json", manifest, .{ .mode = 0o644 });
    try tar.finishPedantically();
    try compression.finish();
    try writer.interface.flush();
}
