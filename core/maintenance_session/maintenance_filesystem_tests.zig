//! Native filesystem acceptance for bootstrap shrinking a populated disk tail.
//! Ordinary memory fixture only; never discovers or opens a physical device.
const std = @import("std");
const s = @import("storage");
const w = @import("proto").wire;
const compiler = @import("maintenance_compiler.zig");
const fat = s.fat32;
const f = fat.format;
const MI_B = 1024 * 1024;
const Backing = struct {
    bytes: []u8,
    target: s.model.Target,
    fn reader(self: *const Backing) s.device.Reader {
        return .{ .context = self, .target = self.target, .vtable = &.{ .read = read } };
    }
    fn read(ctx: *const anyopaque, _: std.Io, offset: u64, out: []u8) !void {
        const self: *const Backing = @ptrCast(@alignCast(ctx));
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
    fn seed(self: *Backing, p: s.program.Program) !void {
        // Fixture creation emits only writes/barriers; never interprets a real
        // execution request and cannot grant a physical write capability.
        for (p.steps) |step| switch (step.operation) {
            .write => |write| @memcpy(self.bytes[@intCast(write.range.offset)..][0..write.content.len], write.content),
            .barrier => {},
            else => return error.UnexpectedFixtureOperation,
        };
    }
};
fn verifyPayload(a: std.mem.Allocator, io: std.Io, reader: s.device.Reader, range: s.model.Range, expected: []const u8) !void {
    var builder = s.program.Builder.init(a, reader);
    var view: s.program.Builder.View = .{ .builder = &builder, .version = 0, .range = range };
    const loaded = try fat.scan.load(a, io, view.reader(), false);
    const g = loaded.graph.geometry;
    const root = loaded.graph.objects.items[0];
    const raw = try view.reader().read(a, io, .{ .offset = try g.offset(root.chain[0]), .length = g.clusterBytes() });
    var at: usize = 0;
    while (at + 32 <= raw.len and raw[at] != 0) : (at += 32) {
        if (!std.mem.eql(u8, raw[at..][0..11], "KEEP    BIN")) continue;
        const cluster = f.first(raw[at..][0..32]);
        const actual = try view.reader().read(a, io, .{ .offset = try g.offset(cluster), .length = expected.len });
        try std.testing.expectEqualSlices(u8, expected, actual);
        return;
    }
    return error.FixtureFileLost;
}
test "tail bootstrap preserves relocated file blocks through undo or accepted cleanup" {
    for ([_]bool{ true, false }) |undo| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        var backing: Backing = .{ .bytes = try s.testing.gpt_fixture.initialSize(a, 512, 128 * MI_B / 512), .target = .{ .identity = @splat(0x37), .capacity = 128 * MI_B, .sector_size = 512 } };
        var layout = try s.partition_table.BUILTIN.readLayout(a, io, backing.reader());
        var esp = layout.entries[0];
        esp.range.length = 32 * MI_B - esp.range.offset;
        // Seed a large ESP placeholder. FAT allocation proofs are tested separately;
        // this scenario isolates native FAT data relocation and raw-tail overwrites.
        const table = try s.partition_table.BUILTIN.encodeLayout(a, layout, &.{esp});
        for (table.writes) |write| @memcpy(backing.bytes[@intCast(write.range.offset)..][0..write.content.len], write.content);
        layout = try s.partition_table.BUILTIN.readLayout(a, io, backing.reader());
        const uuid: [16]u8 = @splat(0x45);
        const data: s.partition_table.Entry = .{ .id = s.partition_table.stableId(backing.target, &uuid), .uuid = uuid, .slot = 1, .type_id = @splat(0x16), .range = .{ .offset = 32 * MI_B, .length = try layout.usable.end() - 32 * MI_B } };
        const created = try s.service.layoutWithFormats(a, io, backing.reader(), &.{ esp, data }, &.{.{ .partition_id = data.id, .driver = try s.filesystem.BUILTIN.get(.vfat) }});
        try backing.seed(created.program);
        try std.testing.expect(try created.verify(a, io, backing.reader()));
        var source = s.program.Builder.init(a, backing.reader());
        var view: s.program.Builder.View = .{ .builder = &source, .version = 0, .range = data.range };
        const native = try fat.scan.load(a, io, view.reader(), false);
        const g = native.graph.geometry;
        const cluster = g.clusters - 8;
        const file_at = data.range.offset + try g.offset(cluster);
        const payload: [512]u8 = @splat(0xb7);
        @memcpy(backing.bytes[@intCast(file_at)..][0..payload.len], &payload);
        for (0..g.copies) |copy| f.put32(backing.bytes, @intCast(data.range.offset + g.fatOffset(@intCast(copy)) + @as(u64, cluster) * 4), f.EOC);
        const root_at = data.range.offset + try g.offset(g.root);
        var pos: usize = @intCast(root_at);
        while (backing.bytes[pos] != 0) : (pos += 32) {}
        const entry = backing.bytes[pos..][0..32];
        @memcpy(entry[0..11], "KEEP    BIN");
        entry[11] = 0x20;
        f.setFirst(entry, cluster);
        f.put32(entry, 28, payload.len);
        f.makeInfo(backing.bytes[@intCast(data.range.offset + @as(u64, g.info) * g.sector)..][0..g.sector], native.graph.free - 1, 0xffffffff);
        try verifyPayload(a, io, backing.reader(), data.range, &payload);
        var machine = try s.testing.crash_model.Machine.init(a, backing.target, backing.bytes);
        const disk_id = try a.dupe(u8, &std.fmt.bytesToHex(backing.target.identity, .lower));
        var parts: [2]w.HostPartition = undefined;
        var desired: [2]w.DesiredPartition = undefined;
        for ([_]s.partition_table.Entry{ esp, data }, 0..) |p, i| {
            parts[i] = .{ .id = try a.dupe(u8, &std.fmt.bytesToHex(p.id, .lower)), .offset = try a.print("{d}", .{p.range.offset}), .length = try a.print("{d}", .{p.range.length}), .attributes = try a.print("{d}", .{p.attributes}), .name = if (i == 0) "ESP" else "Data", .encryption = .none, .protected = i == 0, .filesystem = if (i == 1) .vfat else null };
            desired[i] = .{ .id = parts[i].id, .offset = parts[i].offset, .length = parts[i].length, .attributes = parts[i].attributes.?, .name = parts[i].name, .retain_data = true, .filesystem = parts[i].filesystem };
        }
        const disks = [_]w.HostDisk{.{ .path = "/disposable", .identity = disk_id, .capacity = try a.print("{d}", .{backing.target.capacity}), .sector_size = 512, .model = "native FAT tail fixture", .partition_table = "gpt", .read_only = false, .usable_offset = try a.print("{d}", .{layout.usable.offset}), .usable_length = try a.print("{d}", .{layout.usable.length}), .partitions = &parts }};
        const inventory: w.InventorySnapshot = .{ .version = 4, .platform = .linux, .snapshot_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .disks = &disks };
        const draft: w.PlanDraft = .{ .version = 4, .snapshot_id = inventory.snapshot_id, .disk_identity = disk_id, .layout = &desired };
        const sid: s.model.Digest = @splat(0x75);
        const resources: compiler.Resources = .{ .session = sid, .maintenance_uuid = @splat(0x56), .esp = esp.range, .tail = try compiler.tailRange(layout.usable, 16 * MI_B, 4096), .control = .{ .offset = MI_B, .length = 8192 }, .bootstrap_store = .{ .session = sid, .block_size = 4096, .extents = &.{.{ .offset = 2 * MI_B, .length = 12 * MI_B }} }, .cleanup_store = .{ .session = sid, .block_size = 4096, .extents = &.{.{ .offset = 18 * MI_B, .length = 12 * MI_B }} } };
        try std.testing.expect(file_at >= resources.tail.offset);
        const compiled = try compiler.compile(a, io, machine.disk().reader(), inventory, draft, resources);
        var session = try s.maintenance_session.Session.prepare(a, io, machine.disk(), compiled.bundle);
        try session.bootstrap(io, compiled.verifier(.bootstrap), null);
        const smaller: s.model.Range = .{ .offset = data.range.offset, .length = resources.tail.offset - data.range.offset };
        try verifyPayload(a, io, machine.disk().reader(), smaller, &payload);
        try session.apply(io, compiled.verifier(.apply), null);
        // Simulate work-store use of the original source address. It is now outside
        // the live filesystem but must be restored before its old FAT is exposed.
        const overwritten: [512]u8 = @splat(0x8e);
        try machine.disk().write(io, .{ .offset = file_at, .length = overwritten.len }, &overwritten);
        try machine.disk().flush(io);
        if (undo) {
            try session.undo(io);
            try std.testing.expectEqual(.rolled_back, session.phase);
        } else {
            try session.accept(io);
            try session.cleanup(io, compiled.verifier(.cleanup), null);
            try std.testing.expectEqual(.completed, session.phase);
            try std.testing.expect(try compiled.cleanup.verify(a, io, machine.disk().reader()));
        }
        try verifyPayload(a, io, machine.disk().reader(), data.range, &payload);
        const restored = try s.partition_table.BUILTIN.readLayout(a, io, machine.disk().reader());
        try std.testing.expectEqual(2, restored.entries.len);
        for (restored.entries) |p| if (p.slot == 1) try std.testing.expectEqualDeep(data.range, p.range);
    }
}
