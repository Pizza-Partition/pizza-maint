const std = @import("std");
const wire = @import("proto").wire;
const planner = @import("planner.zig");
const ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const PARTS = [_]wire.HostPartition{
    .{ .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .offset = "1048576", .length = "1048576", .name = "Archive", .filesystem = .xfs, .encryption = .none },
    .{ .id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .offset = "3145728", .length = "1048576", .name = "Data", .filesystem = .ext4, .encryption = .none, .capabilities = &.{.{ .operation = .resize, .backend = .host, .support = .unavailable, .reason = "host_only_limit" }} },
};
const INVENTORY: wire.InventorySnapshot = .{ .version = 4, .snapshot_id = ID, .platform = .linux, .disks = &.{.{ .identity = ID, .path = "/fixture", .capacity = "16777216", .sector_size = 512, .model = "fixture", .read_only = false, .partition_table = "gpt", .usable_offset = "1048576", .usable_length = "14680064", .partitions = &PARTS }} };
fn retained(p: wire.HostPartition) wire.DesiredPartition {
    return .{ .id = p.id, .offset = p.offset, .length = p.length, .name = p.name, .filesystem = p.filesystem };
}
fn has(result: wire.ValidatedPlan, code: []const u8) bool {
    for (result.diagnostics) |d| if (std.mem.eql(u8, d.code, code)) return true;
    return false;
}
test "maintenance accepts an untouched XFS neighbor but rejects moving XFS" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var layout = [_]wire.DesiredPartition{ retained(PARTS[0]), retained(PARTS[1]) };
    layout[1].offset = "4194304";
    var draft: wire.PlanDraft = .{ .version = 4, .snapshot_id = ID, .disk_identity = ID, .intents = &.{.{ .kind = .move, .partition_id = PARTS[1].id, .offset = layout[1].offset }}, .layout = &layout };
    const result = try planner.validate(a, INVENTORY, draft);
    for (result.diagnostics) |d| try std.testing.expect(d.severity != .@"error");
    layout[0].offset = "2097152";
    draft.intents = &.{ .{ .kind = .move, .partition_id = PARTS[0].id, .offset = layout[0].offset }, .{ .kind = .move, .partition_id = PARTS[1].id, .offset = layout[1].offset } };
    try std.testing.expect(has(try planner.validate(a, INVENTORY, draft), "maintenance_filesystem_unavailable"));
}
test "maintenance rejects unavailable labels and binds NTFS format labels to approval" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var layout = [_]wire.DesiredPartition{ retained(PARTS[0]), retained(PARTS[1]) };
    layout[1].retain_data = false;
    layout[1].name = "New label";
    var intents = [_]wire.PlanIntent{.{ .kind = .format, .partition_id = PARTS[1].id, .filesystem = .ext4, .label = layout[1].name }};
    const intent = &intents[0];
    var draft: wire.PlanDraft = .{ .version = 4, .snapshot_id = ID, .disk_identity = ID, .intents = &intents, .layout = &layout };
    try std.testing.expect(has(try planner.validate(a, INVENTORY, draft), "maintenance_label_unavailable"));
    layout[1].filesystem = .ntfs;
    intent.filesystem = .ntfs;
    const result = try planner.validate(a, INVENTORY, draft);
    for (result.diagnostics) |d| try std.testing.expect(d.severity != .@"error");
    intent.label = "Different";
    try std.testing.expect(has(try planner.validate(a, INVENTORY, draft), "intent_layout_mismatch"));
    layout[1].retain_data = true;
    draft.intents = &.{.{ .kind = .label, .partition_id = PARTS[1].id, .label = layout[1].name }};
    try std.testing.expect(has(try planner.validate(a, INVENTORY, draft), "maintenance_label_unavailable"));
}
