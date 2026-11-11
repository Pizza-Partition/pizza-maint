//! Host btrfs-progs is an independent test oracle, never a production backend.
const std = @import("std");
const model = @import("../../../model.zig");
const btrfs = @import("../../../filesystem/btrfs/root.zig");
const format = btrfs.format;
const Fixture = @import("../fixture.zig").Fixture;
const Image = @import("../../image.zig").Image;
const command = @import("../../tools.zig").command;
pub const FIXTURES = [_]Fixture{.{ .filesystem = .btrfs, .capacity = 128 * 1024 * 1024, .smaller_bytes = 64 * 1024 * 1024, .vtable = &VTABLE }};
const VTABLE: Fixture.VTable = .{ .create = create, .seed_payload = seedPayload, .check = check, .check_payload = checkPayload, .make_repairable = makeRepairable };
fn create(a: std.mem.Allocator, io: std.Io, home: []const u8, _: model.Filesystem, bytes: u64) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ home, "target.raw" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    try file.setLength(io, FIXTURES[0].capacity);
    file.close(io);
    try mkfs(a, io, path, bytes, null, "single", "crc32c", "^free-space-tree,^block-group-tree");
    return path;
}
pub fn mkfs(a: std.mem.Allocator, io: std.Io, path: []const u8, bytes: u64, root: ?[]const u8, profile: []const u8, checksum: []const u8, features: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "mkfs.btrfs", "-f", "-q", "-M", "-d", profile, "-m", profile, "-n", "4096", "-s", "4096", "--csum", checksum, "-O", features, "-b", try a.print("{d}", .{bytes}) });
    if (root) |dir| try argv.appendSlice(a, &.{ "-r", dir });
    try argv.append(a, path);
    try command(a, io, argv.items);
}
fn seedPayload(a: std.mem.Allocator, io: std.Io, home: []const u8, path: []const u8, bytes: []const u8, tail: bool) !void {
    const dir = try std.fs.path.join(a, &.{ home, "input" });
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "payload" }), .data = bytes });
    var image = try Image.open(io, path, @import("../../fixture.zig").IDENTITY, 512);
    const g = try format.load(io, image.reader());
    image.close(io);
    try mkfs(a, io, path, g.bytes(), dir, "single", "crc32c", "^free-space-tree,^block-group-tree");
    if (tail) try moveToTail(a, io, path);
}
fn check(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try command(a, io, &.{ "btrfs", "check", "--readonly", "--check-data-csum", path });
}
fn checkPayload(a: std.mem.Allocator, io: std.Io, path: []const u8, output: []const u8, bytes: []const u8) !void {
    const dir = try a.print("{s}.dir", .{output});
    try std.Io.Dir.cwd().createDir(io, dir, .default_dir);
    try command(a, io, &.{ "btrfs", "restore", path, dir });
    const found = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "payload" }), a, .limited(bytes.len + 1));
    if (!std.mem.eql(u8, found, bytes)) return error.PayloadChanged;
}
fn makeRepairable(_: std.mem.Allocator, io: std.Io, image: *Image) !void {
    var byte: [1]u8 = undefined;
    try image.reader().readInto(io, format.MIRRORS[1], &byte);
    byte[0] ^= 0xff;
    try image.file.writePositionalAll(io, &byte, format.MIRRORS[1]);
}
/// Test only: put the entire chunk containing file extents beyond the shrink
/// boundary, then poison its released source so stale mappings cannot pass.
pub fn moveToTail(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    return moveChunk(a, io, path, format.c_api.BTRFS_BLOCK_GROUP_DATA);
}
pub fn moveSystemToTail(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    return moveChunk(a, io, path, format.c_api.BTRFS_BLOCK_GROUP_SYSTEM);
}
fn moveChunk(a: std.mem.Allocator, io: std.Io, path: []const u8, flags: u64) !void {
    var image = try Image.open(io, path, @import("../../fixture.zig").IDENTITY, 512);
    defer image.close(io);
    var overlay = @import("../../../mutation.zig").MutationBuilder.init(a, image.reader());
    defer overlay.deinit();
    var graph = try btrfs.scan.load(a, io, overlay.reader(), true);
    var moved = false;
    for (graph.chunks) |*chunk| {
        if (chunk.flags & flags == 0) continue;
        if (chunk.length * chunk.stripes.len > 24 * 1024 * 1024) return error.InvalidBtrfsTailFixture;
        var end = graph.geometry.bytes() - 1024 * 1024;
        for (chunk.stripes, 0..) |*source, index| {
            const previous = source.physical;
            const dest = std.mem.alignBackward(u64, end - chunk.length, 65536);
            end = dest;
            if (dest < FIXTURES[0].smaller_bytes) return error.InvalidBtrfsTailFixture;
            for (graph.chunks) |other| for (other.stripes) |stripe| if (dest < stripe.physical + other.length and stripe.physical < dest + chunk.length) return error.InvalidBtrfsTailFixture;
            const buffer = try a.alloc(u8, 65536);
            const zeros: [65536]u8 = @splat(0);
            var cursor: u64 = 0;
            while (cursor < chunk.length) : (cursor += buffer.len) {
                try overlay.originalReader().readInto(io, previous + cursor, buffer);
                try overlay.stageWrite(io, dest + cursor, buffer);
                try overlay.stageWrite(io, previous + cursor, &zeros);
            }
            for ((try graph.tree(4)).leaves) |logical| for ((try graph.node(logical)).entries) |*entry| if (entry.key.kind == format.c_api.BTRFS_DEV_EXTENT_KEY and entry.key.offset == previous) {
                entry.key.offset = dest;
            };
            source.physical = dest;
            format.put(format.STRIPE, "offset", chunk.raw[@offsetOf(format.CHUNK, "stripe") + index * @sizeOf(format.STRIPE) ..], dest);
        }
        moved = true;
        break;
    }
    if (!moved) return error.InvalidBtrfsTailFixture;
    try btrfs.mutate.rewrite(a, io, &overlay, &graph, graph.geometry.bytes());
    const changes = try overlay.finish(io, false);
    for (changes.writes) |patch| try image.file.writePositionalAll(io, patch.content, patch.range.offset);
    try image.file.sync(io);
    try check(a, io, path);
}
