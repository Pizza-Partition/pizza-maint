//! Native TAR/gzip packaging and Linux newc application overlays.
const std = @import("std");
const utils = @import("utils");
const bundle = @import("bundle");
const files = @import("files.zig");
const release = @import("release.zig");

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn names(a: std.mem.Allocator, io: std.Io, root: []const u8) ![][]const u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(a);
    defer walker.deinit();

    var entries: std.array_list.Managed([]const u8) = .init(a);
    try entries.append(".");
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory, .file => {},
            .sym_link => {
                var target: [std.fs.max_path_bytes]u8 = undefined;
                const count = try directory.readLink(io, entry.path, &target);
                if (std.fs.path.isAbsolute(target[0..count])) return error.EscapingSymlink;
                _ = try bundle.rooted(a, io, root, entry.path);
            },
            else => return error.InvalidApplicationFile,
        }
        try entries.append(try a.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, entries.items, {}, less);
    return entries.toOwnedSlice();
}

fn streamFile(io: std.Io, root: std.Io.Dir, name: []const u8, size: u64, writer: *std.Io.Writer) !void {
    const file = try root.openFile(io, name, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.interface.streamExact64(writer, size);
}

fn newc(a: std.mem.Allocator, io: std.Io, overlay: []const u8, writer: *std.Io.Writer) !void {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, overlay, a);
    const sorted = try names(a, io, root);
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer directory.close(io);
    var archive: utils.newc.Writer = .{ .output = writer };
    for (sorted) |name| {
        const stat = try directory.statFile(io, name, .{ .follow_symlinks = false });
        const permissions: u32 = @intCast(stat.permissions.toMode() & 0o777);
        switch (stat.kind) {
            .directory => try archive.header(name, 0o040000 | permissions, 0, 0, 0),
            .file => {
                try archive.header(name, 0o100000 | permissions, stat.size, 0, 0);
                try streamFile(io, directory, name, stat.size, writer);
                try archive.endData(stat.size);
            },
            .sym_link => {
                var target: [std.fs.max_path_bytes]u8 = undefined;
                const count = try directory.readLink(io, name, &target);
                try archive.header(name, 0o120777, count, 0, 0);
                try writer.writeAll(target[0..count]);
                try archive.endData(count);
            },
            else => return error.InvalidApplicationFile,
        }
    }
    try archive.finish();
}

pub fn layer(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, overlay: []const u8, output: []const u8) !void {
    _ = env;
    const file = try std.Io.Dir.cwd().createFile(io, output, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try newc(a, io, overlay, &writer.interface);
    try writer.interface.flush();
    try file.sync(io);
}

fn gzipLayer(a: std.mem.Allocator, io: std.Io, overlay: []const u8, output: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, output, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    var compression = try std.compress.flate.Compress.init(&writer.interface, window, .gzip, .default);
    try newc(a, io, overlay, &compression.writer);
    try compression.finish();
    try writer.interface.flush();
    try file.sync(io);
}

pub fn appendFile(io: std.Io, source: []const u8, output: []const u8) !void {
    const input = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer input.close(io);
    const destination = try std.Io.Dir.cwd().openFile(io, output, .{ .mode = .read_write });
    defer destination.close(io);
    var offset = (try destination.stat(io)).size;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        try destination.writePositionalAll(io, buffer[0..count], offset);
        offset += count;
    }
    try destination.sync(io);
}

pub fn image(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, root: []const u8, destination: []const u8) !void {
    _ = try @import("root.zig").verify(a, io, root);
    const lock = try release.readLock(a, io, try std.fs.path.join(a, &.{ root, "release.json" }));
    _ = try release.verify(a, io, env, root, lock);
    const output = try files.Output.init(a, io, destination, false);
    defer output.deinit(io);
    if (utils.filesystem.pathIsWithin(root, output.target)) return error.ImageMustBeOutsideSource;
    const compressed = try std.fs.path.join(a, &.{ output.temporary, "application.cpio.gz" });
    try gzipLayer(a, io, try std.fs.path.join(a, &.{ root, "overlay" }), compressed);
    const combined = try std.fs.path.join(a, &.{ output.temporary, "maint.img" });
    try std.Io.Dir.cwd().copyFile(try std.fs.path.join(a, &.{ root, lock.asset }), .cwd(), combined, io, .{});
    try appendFile(io, compressed, combined);
    try std.Io.Dir.cwd().renamePreserve(combined, .cwd(), output.target, io);
}

pub fn pack(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, source: []const u8, destination: []const u8) !void {
    _ = env;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, source, a);
    _ = try @import("root.zig").verify(a, io, root);
    try packTree(a, io, root, destination, null);
}

pub fn packTools(a: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, source, a);
    try packTree(a, io, root, destination, &.{ "pizza", "pizza-tools", "pizza-init" });
}

fn packTree(a: std.mem.Allocator, io: std.Io, root: []const u8, destination: []const u8, selection: ?[]const []const u8) !void {
    const output = try files.Output.init(a, io, destination, false);
    defer output.deinit(io);
    if (utils.filesystem.pathIsWithin(root, output.target)) return error.BundleArchiveMustBeOutsideSource;
    const archive_path = try std.fs.path.join(a, &.{ output.temporary, "bundle.tar.gz" });
    const file = try std.Io.Dir.cwd().createFile(io, archive_path, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    var compression = try std.compress.flate.Compress.init(&writer.interface, window, .gzip, .default);
    var tar: std.tar.Writer = .{ .underlying_writer = &compression.writer };
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer directory.close(io);
    const selected = selection orelse try names(a, io, root);
    for (selected) |name| {
        const stat = try directory.statFile(io, name, .{ .follow_symlinks = false });
        const options: std.tar.Writer.Options = .{ .mode = @intCast(stat.permissions.toMode() & 0o777), .mtime = 0 };
        switch (stat.kind) {
            .directory => try tar.writeDir(name, options),
            .file => {
                const input = try directory.openFile(io, name, .{});
                defer input.close(io);
                var input_buffer: [64 * 1024]u8 = undefined;
                var reader = input.reader(io, &input_buffer);
                try tar.writeFileStream(name, stat.size, &reader.interface, options);
            },
            .sym_link => {
                var target: [std.fs.max_path_bytes]u8 = undefined;
                const count = try directory.readLink(io, name, &target);
                try tar.writeLink(name, target[0..count], options);
            },
            else => return error.InvalidApplicationFile,
        }
    }
    try tar.finishPedantically();
    try compression.finish();
    try writer.interface.flush();
    try file.sync(io);
    try std.Io.Dir.cwd().renamePreserve(archive_path, .cwd(), output.target, io);
}
