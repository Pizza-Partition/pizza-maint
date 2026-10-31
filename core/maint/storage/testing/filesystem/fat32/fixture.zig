//! dosfstools/mtools are independent host-test oracles, never runtime fallbacks.
const std = @import("std");
const model = @import("../../../model.zig");
const fat = @import("../../../filesystem/fat32/root.zig");
const Fixture = @import("../fixture.zig").Fixture;
const Image = @import("../../image.zig").Image;
const IDENTITY = @import("../../fixture.zig").IDENTITY;
const command = @import("../../tools.zig").command;
const f = fat.format;
pub const FIXTURES = [_]Fixture{.{ .filesystem = .vfat, .capacity = 128 * 1024 * 1024, .smaller_bytes = 64 * 1024 * 1024, .vtable = &VTABLE }};
const VTABLE: Fixture.VTable = .{ .create = create, .seed_payload = seedPayload, .check = check, .check_payload = checkPayload, .make_repairable = makeRepairable };

pub fn create(a: std.mem.Allocator, io: std.Io, home: []const u8, _: model.Filesystem, bytes: u64) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ home, "target.raw" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    try file.setLength(io, FIXTURES[0].capacity);
    file.close(io);
    try command(a, io, &.{ "mkfs.fat", "-F", "32", "-s", "1", "-S", "512", path, try a.print("{d}", .{bytes / 1024}) });
    try check(a, io, path);
    return path;
}
fn seedPayload(a: std.mem.Allocator, io: std.Io, home: []const u8, path: []const u8, bytes: []const u8, tail: bool) !void {
    const input = try std.fs.path.join(a, &.{ home, "payload" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input, .data = bytes });
    try command(a, io, &.{ "mcopy", "-i", path, input, "::/payload" });
    if (tail) try movePayloadToTail(a, io, path);
}
fn check(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try command(a, io, &.{ "fsck.fat", "-n", path });
}
fn checkPayload(a: std.mem.Allocator, io: std.Io, path: []const u8, output: []const u8, bytes: []const u8) !void {
    try command(a, io, &.{ "mcopy", "-i", path, "::/payload", output });
    const observed = try std.Io.Dir.cwd().readFileAlloc(io, output, a, .limited(bytes.len + 1));
    if (!std.mem.eql(u8, bytes, observed)) return error.PayloadChanged;
}
fn makeRepairable(a: std.mem.Allocator, io: std.Io, image: *Image) !void {
    const loaded = try fat.scan.load(a, io, image.reader(), false);
    var bytes: [512]u8 = undefined;
    try image.reader().readInto(io, @as(u64, loaded.boot.geometry.info) * loaded.boot.geometry.sector, &bytes);
    f.put32(&bytes, 488, loaded.graph.free - 1);
    try image.file.writePositionalAll(io, &bytes, @as(u64, loaded.boot.geometry.info) * loaded.boot.geometry.sector);
}
pub fn movePayloadToTail(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    var loaded = try fat.scan.load(a, io, image.reader(), false);
    const g = loaded.boot.geometry;
    if (loaded.graph.objects.items.len != 2) return error.InvalidTailFixture;
    const original = loaded.graph.objects.items[1].start;
    var tail = g.clusters * 3 / 4;
    while (tail < g.clusters + 2 and loaded.graph.value(tail) != 0) tail += 1;
    if (tail >= g.clusters + 2) return error.NoTailFixtureSpace;
    const bytes = try a.alloc(u8, g.clusterBytes());
    try image.reader().readInto(io, try g.offset(original), bytes);
    try image.file.writePositionalAll(io, bytes, try g.offset(tail));
    loaded.graph.set(tail, loaded.graph.value(original));
    loaded.graph.set(original, 0);
    for (0..g.copies) |copy| try image.file.writePositionalAll(io, loaded.graph.fat, g.fatOffset(@intCast(copy)));
    var updated = false;
    for (loaded.graph.references.items) |reference| if (reference.directory == 0 and reference.cluster == original) {
        const root = loaded.graph.objects.items[0];
        const offset = try g.offset(root.chain[reference.position / g.clusterBytes()]) + reference.position % g.clusterBytes();
        var entry: [32]u8 = undefined;
        try image.reader().readInto(io, offset, &entry);
        f.setFirst(&entry, tail);
        try image.file.writePositionalAll(io, &entry, offset);
        updated = true;
    };
    if (!updated) return error.InvalidTailFixture;
    @memset(bytes, 0);
    try image.file.writePositionalAll(io, bytes, try g.offset(original));
    try image.file.sync(io);
    try check(a, io, path);
}
