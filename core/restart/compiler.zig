//! Offline bridge from approved v3 intents to the existing physical program.
const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;
const storage = @import("storage");
pub fn hex16(text: []const u8) ![16]u8 {
    if (text.len != 32) return error.InvalidGptUuid;
    var bytes: [16]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = std.fmt.parseInt(u8, text[i * 2 ..][0..2], 16) catch return error.InvalidGptUuid;
    return bytes;
}
pub fn compileOffline(a: std.mem.Allocator, io: std.Io, reader: storage.device.Reader, inventory: wire.InventorySnapshot, draft: wire.PlanDraft) !storage.service.Plan {
    const validated = try @import("planner.zig").validate(a, inventory, draft);
    for (validated.diagnostics) |d| if (d.severity == .@"error") return error.InvalidHostPlan;
    if (!std.mem.eql(u8, &reader.target.identity, &try proto.hexDigest(draft.disk_identity))) return error.TransactionTargetMismatch;
    const baseline = for (inventory.disks) |disk| {
        if (disk.identity) |id| if (std.mem.eql(u8, id, draft.disk_identity)) break disk;
    } else return error.DiskIdentityNotFound;
    if (try proto.byteCount(baseline.capacity) != reader.target.capacity or baseline.sector_size != reader.target.sector_size) return error.DeviceGeometryChanged;
    const table = try storage.partition_table.BUILTIN.readLayout(a, io, reader);
    if (table.kind != .gpt or table.entries.len != baseline.partitions.len) return error.PartitionTableChanged;
    for (baseline.partitions) |p| {
        const id = try proto.hexDigest(p.id);
        const old = for (table.entries) |entry| {
            if (std.mem.eql(u8, &entry.id, &id)) break entry;
        } else return error.PartitionIdentityChanged;
        if (old.range.offset != try proto.byteCount(p.offset) or old.range.length != try proto.byteCount(p.length)) return error.PartitionTableChanged;
        if (p.partition_uuid) |uuid| if (!std.mem.eql(u8, &old.uuid, &try hex16(uuid))) return error.PartitionIdentityChanged;
        if (p.type_guid) |guid| if (!std.mem.eql(u8, &old.type_id, &try hex16(guid))) return error.PartitionTableChanged;
        if (p.attributes) |attrs| if (old.attributes != try proto.byteCount(attrs)) return error.PartitionTableChanged;
    }
    var entries: std.ArrayList(storage.partition_table.Entry) = .empty;
    var formats: std.ArrayList(storage.service.Format) = .empty;
    for (draft.layout) |p| {
        const id = try proto.hexDigest(p.id);
        const old: ?storage.partition_table.Entry = for (table.entries) |entry| {
            if (std.mem.eql(u8, &entry.id, &id)) break entry;
        } else null;
        var entry: storage.partition_table.Entry = if (old) |e| e else .{ .id = id, .uuid = try hex16(p.partition_uuid orelse return error.MissingPartitionUuid), .slot = p.slot orelse try freeSlot(table, entries.items, draft.layout), .range = undefined, .type_id = try hex16(p.type_guid orelse return error.MissingPartitionType) };
        entry.range = .{ .offset = try proto.byteCount(p.offset), .length = try proto.byteCount(p.length) };
        if (old) |e| {
            if (p.slot) |slot| if (slot != e.slot) return error.PartitionIdentityChanged;
            if (p.partition_uuid) |uuid| if (!std.mem.eql(u8, &e.uuid, &try hex16(uuid))) return error.PartitionIdentityChanged;
            if (p.type_guid) |guid| if (!std.mem.eql(u8, &e.type_id, &try hex16(guid))) return error.PartitionMetadataChangeUnimplemented;
            if (try proto.byteCount(p.attributes) != e.attributes) return error.PartitionMetadataChangeUnimplemented;
        }
        if (!p.retain_data) {
            const filesystem = p.filesystem orelse return error.MissingFilesystemSelection;
            const driver = try storage.filesystem.BUILTIN.get(@fromBackingInt(@intCast(@backingInt(filesystem))));
            try formats.append(a, .{ .partition_id = id, .driver = driver, .label = p.name });
        }
        try entries.append(a, entry);
    }
    var plan = try storage.service.layoutWithFormats(a, io, reader, entries.items, formats.items);
    plan.program = try storage.program.bindRequest(a, plan.program, try proto.hexDigest(validated.digest));
    return plan;
}
fn freeSlot(table: storage.partition_table.Layout, entries: []const storage.partition_table.Entry, desired: []const wire.DesiredPartition) !u32 {
    const count = std.mem.readInt(u32, table.original[1].content[80..84], .little);
    outer: for (0..count) |i| {
        for (entries) |e| if (e.slot == i) continue :outer;
        for (desired) |p| if (p.slot) |slot| if (slot == i) continue :outer;
        return @intCast(i);
    }
    return error.GptSlotsExhausted;
}
