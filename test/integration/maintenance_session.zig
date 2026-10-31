//! Cross-process acceptance uses ordinary disposable files only, never /dev.
const std = @import("std");
const s = @import("storage");
const proto = @import("proto");
const w = proto.wire;
const BINARY = @import("fixture_binary").path;
fn invoke(a: std.mem.Allocator, io: std.Io, args: []const []const u8, success: bool) ![]const u8 {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{BINARY}, args });
    const result = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(8 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    const ok = result.term == .exited and result.term.exited == 0;
    if (success and !ok) {
        std.debug.print("{s}\n", .{result.stderr});
        return error.ChildFailed;
    }
    if (!success and ok) return error.ExpectedChildFailure;
    return std.mem.trim(u8, result.stdout, " \r\n");
}
fn action(a: std.mem.Allocator, io: std.Io, image: []const u8, manifest: []const u8, name: []const u8, expected: w.SessionPhase) !void {
    const result = try std.json.parseFromSliceLeaky(w.MaintenanceSession, a, try invoke(a, io, &.{ name, manifest, image }, true), .{});
    try std.testing.expectEqual(proto.API_VERSION, result.version);
    try std.testing.expectEqual(expected, result.phase);
}
fn scenario(undo: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-session-test-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const image = try std.fs.path.join(a, &.{ home, "disk.img" });
    const bytes = try s.testing.gpt_fixture.initial(a, 4096);
    for ([_]usize{ 2, 510 }) |at| std.mem.writeInt(u64, bytes[at * 4096 + 40 ..][0..8], 319, .little);
    for ([_]usize{ 1, 511 }) |at| {
        const h = bytes[at * 4096 ..][0..4096];
        const entries = if (at == 1) bytes[2 * 4096 ..][0..4096] else bytes[510 * 4096 ..][0..4096];
        std.mem.writeInt(u32, h[88..92], std.hash.Crc32.hash(entries), .little);
        std.mem.writeInt(u32, h[16..20], 0, .little);
        std.mem.writeInt(u32, h[16..20], std.hash.Crc32.hash(h[0..92]), .little);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = image, .data = bytes });
    const identity = try invoke(a, io, &.{ "identify", image }, true);
    const id = try proto.hexDigest(identity);
    var memory = try s.testing.crash_model.Machine.init(a, .{ .identity = id, .capacity = bytes.len, .sector_size = 4096 }, bytes);
    const layout = try s.partition_table.BUILTIN.readLayout(a, io, memory.disk().reader());
    const esp = layout.entries[0];
    const part_id = try a.dupe(u8, &std.fmt.bytesToHex(esp.id, .lower));
    const part: w.HostPartition = .{ .id = part_id, .offset = "262144", .length = "1048576", .name = "ESP", .encryption = .none, .protected = true, .attributes = try a.print("{d}", .{esp.attributes}) };
    const disks = [_]w.HostDisk{.{ .path = "/disposable/image", .identity = identity, .capacity = "2097152", .sector_size = 4096, .model = "acceptance fixture", .read_only = false, .partition_table = "gpt", .usable_offset = "139264", .usable_length = "1949696", .partitions = &.{part} }};
    const inventory: w.InventorySnapshot = .{ .version = proto.API_VERSION, .snapshot_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .platform = .linux, .disks = &disks };
    const draft: w.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = inventory.snapshot_id, .disk_identity = identity, .layout = &.{.{ .id = part_id, .offset = part.offset, .length = part.length, .name = "ESP", .attributes = part.attributes.? }} };
    const capsule_session: s.model.Digest = @splat(0x93);
    const request = .{ .version = @as(u16, 1), .inventory = inventory, .draft = draft, .resources = .{ .session = capsule_session, .maintenance_uuid = @as([16]u8, @splat(0x48)), .tail = s.model.Range{ .offset = 384 * 4096, .length = 126 * 4096 }, .esp = esp.range, .control = s.model.Range{ .offset = esp.range.offset, .length = 8192 }, .bootstrap_store = s.recovery_store.CapsuleDescriptor{ .session = capsule_session, .block_size = 4096, .extents = &.{.{ .offset = 68 * 4096, .length = 96 * 4096 }} }, .cleanup_store = s.recovery_store.CapsuleDescriptor{ .session = capsule_session, .block_size = 4096, .extents = &.{.{ .offset = 192 * 4096, .length = 96 * 4096 }} } } };
    const path = try std.fs.path.join(a, &.{ home, "request.json" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.json.Stringify.valueAlloc(a, request, .{}) });
    const manifest = try invoke(a, io, &.{ "compile", path, image }, true);
    try action(a, io, image, manifest, "prepare", .prepared);
    try action(a, io, image, manifest, "bootstrap", .bootstrapping);
    try action(a, io, image, manifest, "apply", .verified);
    try action(a, io, image, manifest, "status", .verified);
    try action(a, io, image, manifest, "recover", .verified);
    if (undo) {
        try action(a, io, image, manifest, "undo", .rolled_back);
        try action(a, io, image, manifest, "recover", .rolled_back);
    } else {
        try action(a, io, image, manifest, "accept", .accepted);
        _ = try invoke(a, io, &.{ "undo", manifest, image }, false);
        try action(a, io, image, manifest, "cleanup", .completed);
        try action(a, io, image, manifest, "recover", .completed);
    }
    const actual = try std.Io.Dir.cwd().readFileAlloc(io, image, a, .limited(4 * 1024 * 1024));
    for ([_]usize{ 0, 1, 2, 510, 511 }) |sector| try std.testing.expectEqualSlices(u8, bytes[sector * 4096 ..][0..4096], actual[sector * 4096 ..][0..4096]);
    const alias = try std.fs.path.join(a, &.{ home, "alias.img" });
    try std.Io.Dir.cwd().symLink(io, image, alias, .{});
    _ = try invoke(a, io, &.{ "identify", alias }, false);
}
test "maintenance undo survives separate process invocations" {
    try scenario(true);
}
test "maintenance acceptance closes undo and cleanup restores exact final GPT" {
    try scenario(false);
}
