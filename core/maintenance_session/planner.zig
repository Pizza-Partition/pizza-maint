//! Pure, deterministic intent normalization and host-side structural validation.
//! This does not grant write capability; offline compilation owns feasibility.
const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn original(disk: wire.HostDisk, id: []const u8) ?wire.HostPartition {
    for (disk.partitions) |p| if (eq(p.id, id)) return p;
    return null;
}
fn has(intents: []const wire.PlanIntent, id: []const u8, kind: wire.IntentKind) bool {
    for (intents) |i| if (eq(i.partition_id, id) and i.kind == kind) return true;
    return false;
}
fn diagnostic(a: std.mem.Allocator, list: *std.ArrayList(wire.Diagnostic), code: []const u8, message: []const u8, id: ?[]const u8) !void {
    try list.append(a, .{ .code = code, .message = message, .partition_id = id, .severity = .@"error" });
}
pub fn optimize(a: std.mem.Allocator, input: []const wire.PlanIntent) ![]const wire.PlanIntent {
    if (input.len > 16384) return error.PlanTooLarge;
    var out: std.ArrayList(wire.PlanIntent) = .empty;
    for (input) |intent| {
        var handled = false;
        if (intent.kind == .resize or intent.kind == .move or intent.kind == .label or intent.kind == .delete) {
            var j = out.items.len;
            while (j != 0) {
                j -= 1;
                const old = &out.items[j];
                if (old.kind == .barrier or old.kind == .copy or old.kind == .format or old.kind == .delete) break;
                if (!eq(old.partition_id, intent.partition_id)) continue;
                if (old.kind == .create and intent.kind != .move) {
                    if (intent.kind == .delete) {
                        _ = out.orderedRemove(j);
                    } else {
                        if (intent.length) |n| old.length = n;
                        if (intent.offset) |n| old.offset = n;
                        if (intent.label) |label| old.label = label;
                    }
                    handled = true;
                } else if (old.kind == intent.kind) {
                    old.* = intent;
                    handled = true;
                }
                break;
            }
        }
        if (!handled) try out.append(a, intent);
    }
    return out.toOwnedSlice(a);
}
pub fn validate(a: std.mem.Allocator, inventory: wire.InventorySnapshot, draft: wire.PlanDraft) !wire.ValidatedPlan {
    if (draft.version != 4 or inventory.version != 4) return error.UnsupportedProtocolVersion;
    _ = try proto.hexDigest(draft.snapshot_id);
    _ = try proto.hexDigest(draft.disk_identity);
    if (draft.layout.len > 4096 or draft.intents.len > 16384) return error.PlanTooLarge;
    var diags: std.ArrayList(wire.Diagnostic) = .empty;
    if (!eq(inventory.snapshot_id, draft.snapshot_id)) try diagnostic(a, &diags, "stale_inventory", "Disk geometry changed; refresh the inventory before preparing.", null);
    const disk = for (inventory.disks) |d| {
        if (d.identity) |id| if (eq(id, draft.disk_identity)) break d;
    } else return error.DiskIdentityNotFound;
    if (disk.read_only) try diagnostic(a, &diags, "read_only", "The disk is read-only.", null);
    if (!eq(disk.partition_table orelse "", "gpt")) try diagnostic(a, &diags, "gpt_required", "Execution requires a validated GPT partition table.", null);
    const capacity = try proto.byteCount(disk.capacity);
    if (disk.sector_size < 512 or !std.math.isPowerOfTwo(disk.sector_size)) return error.InvalidSectorSize;
    const usable_start = if (disk.usable_offset) |n| try proto.byteCount(n) else 0;
    const usable_length = if (disk.usable_length) |n| try proto.byteCount(n) else 0;
    const usable_end = try std.math.add(u64, usable_start, usable_length);
    if (usable_length == 0 or usable_end > capacity) try diagnostic(a, &diags, "unknown_usable_range", "GPT usable bounds could not be established.", null);
    for (draft.intents) |intent| {
        if (intent.partition_id.len == 0 or intent.partition_id.len > 128) return error.InvalidPartitionIdentity;
        if (intent.offset) |n| _ = try proto.byteCount(n);
        if (intent.length) |n| if (try proto.byteCount(n) == 0) return error.InvalidByteCount;
        if (intent.kind == .copy or intent.kind == .label) try diagnostic(a, &diags, "intent_not_supported", "This host operation does not yet have a validated compiler.", intent.partition_id);
    }
    var destroyed: std.ArrayList([]const u8) = .empty;
    for (draft.layout, 0..) |p, i| {
        const start = try proto.byteCount(p.offset);
        const length = try proto.byteCount(p.length);
        const end = try std.math.add(u64, start, length);
        if (length == 0 or start % disk.sector_size != 0 or length % disk.sector_size != 0 or start < usable_start or end > usable_end) try diagnostic(a, &diags, "invalid_partition_range", "Partition must fit the usable disk area and align to logical sectors.", p.id);
        for (draft.layout[0..i]) |other| {
            if (eq(other.id, p.id) or (other.slot != null and p.slot != null and other.slot.? == p.slot.?)) try diagnostic(a, &diags, "duplicate_partition", "Partition identity or slot is duplicated.", p.id);
            const os = try proto.byteCount(other.offset);
            const oe = try std.math.add(u64, os, try proto.byteCount(other.length));
            if (start < oe and os < end) try diagnostic(a, &diags, "overlapping_partitions", "Partition ranges overlap.", p.id);
        }
        if (original(disk, p.id)) |old| {
            const geometry_changed = !eq(old.offset, p.offset) or !eq(old.length, p.length);
            const changed = geometry_changed or old.filesystem != p.filesystem or !p.retain_data or !eq(old.name, p.name);
            if (changed and (old.protected or old.encryption != .none)) try diagnostic(a, &diags, "protected_partition", "Boot anchors and encrypted or unidentified volumes cannot be changed.", p.id);
            if (geometry_changed and !has(draft.intents, p.id, .resize) and !has(draft.intents, p.id, .move)) try diagnostic(a, &diags, "missing_geometry_intent", "Geometry changes need an explicit resize or move intent.", p.id);
            if (!eq(old.name, p.name)) try diagnostic(a, &diags, "label_mutation_unimplemented", "Changing an existing filesystem label is unavailable.", p.id);
            if (old.filesystem != p.filesystem or !p.retain_data) {
                if (p.retain_data or !has(draft.intents, p.id, .format)) try diagnostic(a, &diags, "format_confirmation_required", "Filesystem replacement must explicitly discard existing contents.", p.id);
                try destroyed.append(a, p.id);
            }
            if (changed) {
                for (old.capabilities) |cap| if (cap.support == .unavailable and ((cap.operation == .resize and geometry_changed) or (cap.operation == .format and !p.retain_data))) try diagnostic(a, &diags, cap.reason, "The filesystem backend does not permit this operation.", p.id);
            }
        } else {
            if (p.retain_data or !has(draft.intents, p.id, .create)) try diagnostic(a, &diags, "invalid_new_partition", "New partitions need a create intent and cannot claim retained data.", p.id);
            if (p.partition_uuid == null or p.type_guid == null) try diagnostic(a, &diags, "missing_gpt_identity", "New partitions require GPT type and partition UUIDs.", p.id);
        }
        if (p.filesystem) |f| switch (f) {
            .ext2, .ext3, .ext4, .ntfs, .vfat, .btrfs => {},
            else => try diagnostic(a, &diags, "filesystem_unavailable", "The requested filesystem has no validated backend.", p.id),
        };
    }
    for (disk.partitions) |old| {
        const found = for (draft.layout) |p| {
            if (eq(p.id, old.id)) break true;
        } else false;
        if (!found) {
            if (old.protected or old.encryption != .none) try diagnostic(a, &diags, "protected_partition", "This partition cannot be deleted.", old.id);
            if (!has(draft.intents, old.id, .delete)) try diagnostic(a, &diags, "delete_confirmation_required", "Deleting an existing partition needs an explicit delete intent.", old.id);
            try destroyed.append(a, old.id);
        }
    }
    const normalized = try optimize(a, draft.intents);
    for (normalized) |intent| {
        if (intent.kind == .barrier) continue;
        const desired: ?wire.DesiredPartition = for (draft.layout) |p| {
            if (eq(p.id, intent.partition_id)) break p;
        } else null;
        if (intent.kind == .delete) {
            if (desired != null) try diagnostic(a, &diags, "contradictory_delete", "A deleted partition is still present in the final layout.", intent.partition_id);
            continue;
        }
        const p = desired orelse {
            try diagnostic(a, &diags, "missing_intent_target", "An operation references a partition absent from the final layout.", intent.partition_id);
            continue;
        };
        var mismatch = false;
        switch (intent.kind) {
            .create => mismatch = intent.offset == null or intent.length == null or intent.filesystem == null or intent.filesystem != p.filesystem or p.retain_data,
            .resize => mismatch = intent.length == null,
            .move => mismatch = intent.offset == null,
            .format => mismatch = intent.filesystem == null or intent.filesystem != p.filesystem or p.retain_data,
            else => {},
        }
        if (intent.offset) |n| if (!eq(n, p.offset)) {
            mismatch = true;
        };
        if (intent.length) |n| if (!eq(n, p.length)) {
            mismatch = true;
        };
        if (mismatch) try diagnostic(a, &diags, "intent_layout_mismatch", "Reviewed operation parameters disagree with the final layout.", p.id);
    }
    const body = try std.json.Stringify.valueAlloc(a, .{ .draft = draft, .operations = normalized }, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
    try diags.append(a, .{ .code = "offline_validation_required", .severity = .info, .message = "Filesystem feasibility, bootstrap and cleanup reservations must be verified offline before any target write." });
    return .{ .version = 4, .digest = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower)), .executable = false, .offline_validation_required = true, .diagnostics = try diags.toOwnedSlice(a), .operations = normalized, .destructive_partitions = try destroyed.toOwnedSlice(a), .draft = draft };
}

test "normalization respects data-version barriers and cancels unused creations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const output = try optimize(a, &.{ .{ .kind = .resize, .partition_id = "a", .length = "1024" }, .{ .kind = .resize, .partition_id = "a", .length = "2048" }, .{ .kind = .copy, .partition_id = "b", .source_id = "a" }, .{ .kind = .resize, .partition_id = "a", .length = "4096" }, .{ .kind = .create, .partition_id = "new", .length = "512" }, .{ .kind = .resize, .partition_id = "new", .length = "1024" }, .{ .kind = .delete, .partition_id = "new" } });
    try std.testing.expectEqual(3, output.len);
    try std.testing.expectEqualStrings("2048", output[0].length.?);
    try std.testing.expectEqual(.copy, output[1].kind);
    try std.testing.expectEqualStrings("4096", output[2].length.?);
}
