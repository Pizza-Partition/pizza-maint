const std = @import("std");
const s = @import("storage");
const Machine = s.testing.crash_model.Machine;
const IO = std.testing.io;
const initial = s.testing.gpt_fixture.initial;

test "GPT membership changes preserve retained identities, names and flags; undo restores both tables" {
    for ([_]u32{ 512, 4096 }) |sector| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const baseline = try initial(a, sector);
        var m = try Machine.init(a, .{ .identity = @splat(0x43), .capacity = baseline.len, .sector_size = sector }, baseline);
        const table = try s.partition_table.BUILTIN.readLayout(a, IO, m.disk().reader());
        try std.testing.expectEqual(1, table.entries.len);
        var added = table.entries[0];
        added.slot = 1;
        added.uuid = @splat(0x77);
        added.id = s.partition_table.stableId(table.target, &added.uuid);
        added.range = .{ .offset = 192 * sector, .length = 64 * sector };
        const retained = table.entries[0];
        const p = try s.service.layoutWithFormats(a, IO, m.disk().reader(), &.{ retained, added }, &.{.{ .partition_id = added.id, .driver = null }});
        try s.program_executor.executeDeferred(a, IO, m.disk(), m.store(), p.program, &.{}, null, null);
        try std.testing.expect(try p.verify(a, IO, m.disk().reader()));
        const changed = try s.partition_table.BUILTIN.readLayout(a, IO, m.disk().reader());
        try std.testing.expectEqual(2, changed.entries.len);
        try std.testing.expectEqualSlices(u8, &retained.name_utf16, &changed.entries[0].name_utf16);
        try std.testing.expectEqual(retained.attributes, changed.entries[0].attributes);
        try std.testing.expectEqual(.rolled_back, try s.program_executor.undo(a, IO, m.disk(), m.store(), null));
        try std.testing.expectEqualSlices(u8, baseline, m.live);
        // Delete and replace the old slot with an explicitly identified new one.
        const replaced = try s.service.layoutWithFormats(a, IO, m.disk().reader(), &.{added}, &.{.{ .partition_id = added.id, .driver = null }});
        try std.testing.expect(replaced.program.steps.len > 0);
    }
}

test "Windows saturated protective MBR retains strict GPT and hybrid checks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u32{ 512, 4096 }) |sector| {
        const baseline = try initial(a, sector);
        @memset(baseline[458..462], 0xff);
        var m = try Machine.init(a, .{ .identity = @splat(0x43), .capacity = baseline.len, .sector_size = sector }, baseline);
        const driver = s.partition_table.BUILTIN;
        const layout = try driver.readLayout(a, IO, m.disk().reader());
        try std.testing.expectEqual(1, layout.entries.len);
        m.live[458] = 0xfe;
        try std.testing.expectError(error.InvalidProtectiveMbr, driver.readLayout(a, IO, m.disk().reader()));
        m.live[458] = 0xff;
        m.live[466] = 7;
        try std.testing.expectError(error.HybridOrInvalidPartitionTable, driver.readLayout(a, IO, m.disk().reader()));
        m.live[466] = 0;
        m.live[sector + 16] ^= 1;
        try std.testing.expectError(error.GptHeaderChecksum, driver.readLayout(a, IO, m.disk().reader()));
    }
}
