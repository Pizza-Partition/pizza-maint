//! Independent ntfsprogs executables create and inspect private fixtures only.
const std = @import("std");
const model = @import("../../../model.zig");
const ntfs = @import("../../../filesystem/ntfs/root.zig");
const Fixture = @import("../fixture.zig").Fixture;
const Image = @import("../../image.zig").Image;
const command = @import("../../tools.zig").command;
pub const FIXTURES = [_]Fixture{.{ .filesystem = .ntfs, .capacity = 64 * 1024 * 1024, .smaller_bytes = 32 * 1024 * 1024, .vtable = &VTABLE }};
const VTABLE: Fixture.VTable = .{ .create = create, .seed_payload = seedPayload, .check = check, .check_payload = checkPayload, .make_repairable = makeRepairable };
fn create(a: std.mem.Allocator, io: std.Io, home: []const u8, _: model.Filesystem, bytes: u64) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ home, "target.raw" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    try file.setLength(io, FIXTURES[0].capacity);
    file.close(io);
    try command(a, io, &.{ "mkntfs", "-F", "-Q", "-s", "512", "-c", "4096", path, try a.print("{d}", .{bytes / 512}) });
    try check(a, io, path);
    return path;
}
fn seedPayload(a: std.mem.Allocator, io: std.Io, home: []const u8, path: []const u8, bytes: []const u8, tail: bool) !void {
    const input = try std.fs.path.join(a, &.{ home, "payload" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input, .data = bytes });
    try command(a, io, &.{ "ntfscp", path, input, "/payload" });
    if (tail) try moveToTail(a, io, path);
}
fn check(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    // Neither checker repairs the image. This covers independent MFT/runlist
    // accounting, not the full directory/security checks of Windows chkdsk.
    // The source image retains spare capacity for later growth. ntfsfix looks
    // for the backup at the DEVICE end, so present the current volume extent
    // on a separate file, exactly as the resized partition would expose it.
    const source = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer source.close(io);
    var boot: [512]u8 = undefined;
    if (try source.readPositionalAll(io, &boot, 0) != boot.len) return error.UnexpectedEndOfFile;
    const sector = std.mem.readInt(u16, boot[11..13], .little);
    const sectors = std.mem.readInt(u64, boot[40..48], .little);
    const bytes = try std.math.mul(u64, try std.math.add(u64, sectors, 1), sector);
    const oracle = try a.print("{s}.oracle", .{path});
    const bounded = try std.Io.Dir.cwd().createFile(io, oracle, .{ .exclusive = true });
    defer std.Io.Dir.cwd().deleteFile(io, oracle) catch {};
    defer bounded.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < bytes) {
        const part = buffer[0..@intCast(@min(buffer.len, bytes - offset))];
        if (try source.readPositionalAll(io, part, offset) != part.len) return error.UnexpectedEndOfFile;
        try bounded.writePositionalAll(io, part, offset);
        offset += part.len;
    }
    try bounded.sync(io);
    try command(a, io, &.{ "ntfsfix", "-n", oracle });
    try command(a, io, &.{ "ntfsresize", "-n", "-i", "-P", oracle });
}
fn checkPayload(a: std.mem.Allocator, io: std.Io, path: []const u8, output: []const u8, bytes: []const u8) !void {
    const result = try std.process.run(a, io, .{ .argv = &.{ "ntfscat", path, "/payload" }, .stdout_limit = .limited(bytes.len + 1) });
    if (!result.term.success() or !std.mem.eql(u8, result.stdout, bytes)) return error.PayloadChanged;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = result.stdout });
}
fn makeRepairable(_: std.mem.Allocator, io: std.Io, image: *Image) !void {
    const g = try ntfs.format.load(io, image.reader());
    try image.file.writePositionalAll(io, &.{0}, g.bytes - g.sector + 510);
}

extern "c" fn ntfs_pathname_to_inode([*c]ntfs.c_api.ntfs_volume, [*c]ntfs.c_api.ntfs_inode, [*c]const u8) [*c]ntfs.c_api.ntfs_inode;
extern "c" fn ntfs_bitmap_set_run([*c]ntfs.c_api.ntfs_attr, i64, i64) c_int;
extern "c" fn ntfs_bitmap_clear_run([*c]ntfs.c_api.ntfs_attr, i64, i64) c_int;
fn moveToTail(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const c_api = ntfs.c_api;
    var image = try Image.open(io, path, @import("../../fixture.zig").IDENTITY, 512);
    defer image.close(io);
    var overlay = @import("../../../mutation.zig").Builder.init(a, image.reader());
    defer overlay.deinit();
    {
        const session = try ntfs.Session.open(a, io, overlay.reader(), &overlay);
        defer session.close();
        const v = session.volume.?;
        const ni = ntfs_pathname_to_inode(v, null, "/payload");
        if (ni == null) return error.InvalidTailFixture;
        const na = c_api.ntfs_attr_open(ni, c_api.AT_DATA, null, 0);
        if (na == null) return error.InvalidTailFixture;
        if (na.*.state & (@as(c_ulong, 1) << c_api.NA_NonResident) == 0) try session.check(c_api.ntfs_attr_force_non_resident(na));
        try session.check(c_api.ntfs_attr_map_whole_runlist(na));
        const count = @divExact(na.*.allocated_size, v.cluster_size);
        const bitmap = try a.alloc(u8, @intCast(@divFloor(v.nr_clusters + 7, 8)));
        if (c_api.ntfs_attr_pread(v.lcnbmp_na, 0, @intCast(bitmap.len), bitmap.ptr) != bitmap.len) return error.InvalidTailFixture;
        const tail = @divFloor(v.nr_clusters * 3, 4);
        if (tail + count > v.nr_clusters) return error.InvalidTailFixture;
        for (@as(usize, @intCast(tail))..@as(usize, @intCast(tail + count))) |cluster| if (bitmap[cluster / 8] & (@as(u8, 1) << @intCast(cluster % 8)) != 0) return error.InvalidTailFixture;
        var items: usize = 0;
        while (na.*.rl[items].length != 0) : (items += 1) {}
        const old = try a.dupe(c_api.runlist_element, na.*.rl[0..items]);
        const buffer = try a.alloc(u8, v.cluster_size);
        var logical: i64 = 0;
        for (old) |run| {
            if (run.lcn < 0) return error.InvalidTailFixture;
            for (0..@intCast(run.length)) |part| {
                try overlay.reader().readInto(io, @as(u64, @intCast(run.lcn + @as(i64, @intCast(part)))) * v.cluster_size, buffer);
                try overlay.stageWrite(io, @as(u64, @intCast(tail + logical)) * v.cluster_size, buffer);
                logical += 1;
            }
        }
        try session.check(ntfs_bitmap_set_run(v.lcnbmp_na, tail, count));
        for (old) |run| try session.check(ntfs_bitmap_clear_run(v.lcnbmp_na, run.lcn, run.length));
        // Poison the released source: a broken resize that merely points back
        // to the old location must not pass by reading leftover payload bytes.
        @memset(buffer, 0);
        for (old) |run| for (0..@intCast(run.length)) |part| {
            try overlay.stageWrite(io, @as(u64, @intCast(run.lcn + @as(i64, @intCast(part)))) * v.cluster_size, buffer);
        };
        na.*.rl[0] = .{ .vcn = 0, .lcn = tail, .length = count };
        na.*.rl[1] = .{ .vcn = count, .lcn = -3, .length = 0 };
        try session.check(c_api.ntfs_attr_update_mapping_pairs(na, 0));
        c_api.ntfs_attr_close(na);
        try session.check(c_api.ntfs_inode_close(ni));
        try session.finish();
    }
    const changes = try overlay.finish(io, false);
    for (changes.writes) |patch| try image.file.writePositionalAll(io, patch.content, patch.range.offset);
    try image.file.sync(io);
    try check(a, io, path);
}
