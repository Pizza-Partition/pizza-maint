//! One admission corpus, run by both consumers against their actual wire types.
const std = @import("std");
pub fn run(comptime proto: type) !void {
    const wire = proto.wire;
    const common = @import("plan_validation.zig").For(proto);
    const ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const C = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const Mutation = enum { unchanged, stale, read_only, overlap, unaligned, duplicate, missing_move, intent_mismatch, protected_delete, unconfirmed_format, invalid_label, invalid_sector, missing_target };
    const cases = [_]struct { mutation: Mutation, code: ?[]const u8 = null, failure: ?anyerror = null }{
        .{ .mutation = .unchanged },
        .{ .mutation = .stale, .code = "stale_inventory" },
        .{ .mutation = .read_only, .code = "read_only" },
        .{ .mutation = .overlap, .code = "overlapping_partitions" },
        .{ .mutation = .unaligned, .code = "invalid_partition_range" },
        .{ .mutation = .duplicate, .code = "duplicate_partition" },
        .{ .mutation = .missing_move, .code = "missing_geometry_intent" },
        .{ .mutation = .intent_mismatch, .code = "intent_layout_mismatch" },
        .{ .mutation = .protected_delete, .code = "protected_partition" },
        .{ .mutation = .unconfirmed_format, .code = "format_confirmation_required" },
        .{ .mutation = .invalid_label, .failure = error.InvalidLabel },
        .{ .mutation = .invalid_sector, .failure = error.InvalidSectorSize },
        .{ .mutation = .missing_target, .code = "missing_intent_target" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var parts = [_]wire.HostPartition{
            .{ .id = B, .offset = "1048576", .length = "1048576", .name = "First", .filesystem = .ext4, .encryption = .none },
            .{ .id = C, .offset = "4194304", .length = "1048576", .name = "Second", .filesystem = .ext4, .encryption = .none },
        };
        var disks = [_]wire.HostDisk{.{ .identity = ID, .path = "/fixture", .model = "fixture", .capacity = "16777216", .sector_size = 512, .read_only = false, .partition_table = "gpt", .usable_offset = "1048576", .usable_length = "14680064", .partitions = &parts }};
        var inventory: wire.InventorySnapshot = .{ .version = proto.API_VERSION, .snapshot_id = ID, .platform = .linux, .disks = &disks };
        var layout = [_]wire.DesiredPartition{
            .{ .id = B, .offset = parts[0].offset, .length = parts[0].length, .name = parts[0].name, .filesystem = .ext4 },
            .{ .id = C, .offset = parts[1].offset, .length = parts[1].length, .name = parts[1].name, .filesystem = .ext4 },
        };
        var draft: wire.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = ID, .disk_identity = ID, .layout = &layout, .intents = &.{} };
        switch (case.mutation) {
            .unchanged => {},
            .stale => inventory.snapshot_id = B,
            .read_only => disks[0].read_only = true,
            .overlap => layout[1].offset = parts[0].offset,
            .unaligned => layout[1].length = "1048577",
            .duplicate => layout[1].id = B,
            .missing_move => layout[1].offset = "5242880",
            .intent_mismatch => draft.intents = &.{.{ .kind = .resize, .partition_id = C, .length = "2097152" }},
            .protected_delete => {
                parts[1].protected = true;
                draft.layout = layout[0..1];
            },
            .unconfirmed_format => layout[1].retain_data = false,
            .invalid_label => layout[1].name = "bad\x00label",
            .invalid_sector => disks[0].sector_size = 513,
            .missing_target => draft.intents = &.{.{ .kind = .resize, .partition_id = ID, .length = "512" }},
        }
        if (case.failure) |failure| {
            try std.testing.expectError(failure, common.validate(arena.allocator(), inventory, draft));
            continue;
        }
        const result = try common.validate(arena.allocator(), inventory, draft);
        if (case.code) |code| {
            var found = false;
            for (result.diagnostics.items) |d| if (std.mem.eql(u8, code, d.code)) {
                found = true;
            };
            if (!found) std.debug.print("Missing {s} for {t}\n", .{ code, case.mutation });
            try std.testing.expect(found);
        } else try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    }
}
