//! ext-only mkfs/debugfs/fsck glue; no transaction or crash-test algorithm.
const std = @import("std");
const ext = @import("../../../filesystem/ext/root.zig");
const model = @import("../../../model.zig");
const Fixture = @import("../fixture.zig").Fixture;
const Image = @import("../../image.zig").Image;
const tools = @import("tools.zig");
const command = @import("../../tools.zig").command;

pub const FIXTURES = [_]Fixture{
    .{ .filesystem = .ext2, .capacity = 64 * 1024 * 1024, .smaller_bytes = 32 * 1024 * 1024, .vtable = &VTABLE },
    .{ .filesystem = .ext3, .capacity = 64 * 1024 * 1024, .smaller_bytes = 32 * 1024 * 1024, .vtable = &VTABLE },
    .{ .filesystem = .ext4, .capacity = 64 * 1024 * 1024, .smaller_bytes = 32 * 1024 * 1024, .vtable = &VTABLE },
};
const VTABLE: Fixture.VTable = .{ .create = create, .seed_payload = seedPayload, .check = check, .check_payload = checkPayload, .make_repairable = makeRepairable };

fn create(a: std.mem.Allocator, io: std.Io, home: []const u8, filesystem: model.Filesystem, bytes: u64) ![]const u8 {
    return tools.createSized(a, io, home, filesystem, "1024", null, bytes);
}
fn seedPayload(a: std.mem.Allocator, io: std.Io, home: []const u8, path: []const u8, bytes: []const u8, tail: bool) !void {
    const payload = try std.fs.path.join(a, &.{ home, "payload" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = payload, .data = bytes });
    try command(a, io, &.{ "debugfs", "-w", "-R", try a.print("write {s} /payload", .{payload}), path });
    if (tail) try tools.movePayloadToTail(a, io, path);
}
fn check(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try command(a, io, &.{ "e2fsck", "-fn", path });
}
fn checkPayload(a: std.mem.Allocator, io: std.Io, path: []const u8, output: []const u8, bytes: []const u8) !void {
    try command(a, io, &.{ "debugfs", "-R", try a.print("dump /payload {s}", .{output}), path });
    const observed = try std.Io.Dir.cwd().readFileAlloc(io, output, a, .limited(bytes.len + 1));
    if (!std.mem.eql(u8, bytes, observed)) return error.PayloadChanged;
}
fn makeRepairable(a: std.mem.Allocator, io: std.Io, image: *Image) !void {
    const session = try ext.Session.open(a, io, image.reader());
    defer session.close();
    const free = ext.c.ext2fs_free_blocks_count(session.fs.*.super);
    if (free == 0 or session.fs.*.super.*.s_free_inodes_count == 0) return error.InvalidRepairFixture;
    ext.c.ext2fs_free_blocks_count_set(session.fs.*.super, free - 1);
    session.fs.*.super.*.s_free_inodes_count -= 1;
    try session.check(ext.c.ext2fs_superblock_csum_set(session.fs, session.fs.*.super));
    try image.file.writePositionalAll(io, std.mem.asBytes(&session.fs.*.super.*), 1024);
}
