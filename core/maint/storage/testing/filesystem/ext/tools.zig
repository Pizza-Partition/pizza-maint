const std = @import("std");
const model = @import("../../../model.zig");

const command = @import("../../tools.zig").command;

pub fn create(a: std.mem.Allocator, io: std.Io, home: []const u8, filesystem: model.Filesystem, block_size: []const u8, features: ?[]const u8) ![]const u8 {
    return createSized(a, io, home, filesystem, block_size, features, 64 * 1024 * 1024);
}

pub fn createSized(a: std.mem.Allocator, io: std.Io, home: []const u8, filesystem: model.Filesystem, block_size: []const u8, features: ?[]const u8, bytes: u64) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ home, "target.raw" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    try file.setLength(io, 64 * 1024 * 1024);
    file.close(io);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "mke2fs", "-F", "-q", "-t", @tagName(filesystem), "-b", block_size, "-E", "lazy_itable_init=1" });
    if (features) |flags| try args.appendSlice(a, &.{ "-O", flags });
    try args.append(a, path);
    const block_bytes = try std.fmt.parseInt(u32, block_size, 10);
    if (bytes == 0 or bytes > 64 * 1024 * 1024 or bytes % block_bytes != 0) return error.InvalidFixtureSize;
    try args.append(a, try a.print("{d}", .{bytes / block_bytes}));
    try command(a, io, args.items);
    try command(a, io, &.{ "e2fsck", "-fn", path });
    return path;
}

const ext = @import("../../../filesystem/ext/root.zig");
const Image = @import("../../image.zig").Image;
const IDENTITY = @import("../../fixture.zig").IDENTITY;

/// Force logical block zero above the shrink boundary, for both indirect-block
/// and extent-based inodes. fsck independently verifies the fixture afterwards.
pub fn movePayloadToTail(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    return moveNamedToTail(a, io, path, "/payload");
}
pub fn moveNamedToTail(a: std.mem.Allocator, io: std.Io, path: []const u8, name: [:0]const u8) !void {
    var image = try Image.open(io, path, IDENTITY, 512);
    var original: ext.c_api.blk64_t = 0;
    var tail: ext.c_api.blk64_t = 0;
    var block_size: usize = 0;
    {
        const session = try ext.Session.open(a, io, image.reader());
        defer session.close();
        var inode: ext.c_api.ext2_ino_t = 0;
        try session.check(ext.c_api.ext2fs_namei(session.fs, ext.c_api.EXT2_ROOT_INO, ext.c_api.EXT2_ROOT_INO, name, &inode));
        try session.check(ext.c_api.ext2fs_bmap2(session.fs, inode, null, null, 0, 0, null, &original));
        try session.check(ext.c_api.ext2fs_read_bitmaps(session.fs));
        const blocks = ext.c_api.ext2fs_blocks_count(session.fs.*.super);
        try session.check(ext.c_api.ext2fs_find_first_zero_block_bitmap2(session.fs.*.block_map, blocks * 3 / 4, blocks - 1, &tail));
        block_size = session.fs.*.blocksize;
    }
    const bytes = try a.alloc(u8, block_size);
    try image.reader().readInto(io, original * block_size, bytes);
    try image.file.writePositionalAll(io, bytes, tail * block_size);
    try image.file.sync(io);
    image.close(io);
    for ([_][]const u8{
        try a.print("bmap {s} 0 {d}", .{ name, tail }),
        try a.print("freeb {d}", .{original}),
        try a.print("setb {d}", .{tail}),
    }) |request| try command(a, io, &.{ "debugfs", "-w", "-R", request, path });
    // Free space must contain different bytes, otherwise resize may copy the
    // file back onto its identical stale contents and produce no data patch.
    image = try Image.open(io, path, IDENTITY, 512);
    @memset(bytes, 0);
    try image.file.writePositionalAll(io, bytes, original * block_size);
    try image.file.sync(io);
    image.close(io);
    const corrected = try std.process.run(a, io, .{ .argv = &.{ "e2fsck", "-fy", path } });
    switch (corrected.term) {
        .exited => |code| if (code > 1) return error.ExtFixtureToolFailed,
        else => return error.ExtFixtureToolFailed,
    }
    try command(a, io, &.{ "e2fsck", "-fn", path });
    image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const session = try ext.Session.open(a, io, image.reader());
    defer session.close();
    var inode: ext.c_api.ext2_ino_t = 0;
    var observed: ext.c_api.blk64_t = 0;
    try session.check(ext.c_api.ext2fs_namei(session.fs, ext.c_api.EXT2_ROOT_INO, ext.c_api.EXT2_ROOT_INO, name, &inode));
    try session.check(ext.c_api.ext2fs_bmap2(session.fs, inode, null, null, 0, 0, null, &observed));
    try std.testing.expectEqual(tail, observed);
}
