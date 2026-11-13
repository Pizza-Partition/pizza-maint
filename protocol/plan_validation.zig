//! Pure plan admission shared by the desktop and maintenance planners.
//! No filesystem probes, host scheduling, device handles or OS dependencies.
const std = @import("std");
pub fn For(comptime proto: type) type {
    return struct {
        const wire = proto.wire;
        pub const Result = struct {
            disk: wire.HostDisk,
            diagnostics: std.ArrayList(wire.Diagnostic),
            destructive_partitions: std.ArrayList([]const u8),
            operations: []const wire.PlanIntent,
            digest: []const u8,
        };
        /// Domain admission limits, shared by editing and validation.
        pub const Limits = struct {
            pub const PARTITIONS = 4096;
            pub const INTENTS = 16384;
            pub const LABEL_BYTES = 1024;
            pub const MINIMUM_SECTOR_BYTES = 512;
        };
        pub fn original(disk: wire.HostDisk, id: []const u8) ?wire.HostPartition {
            for (disk.partitions) |p| if (std.mem.eql(u8, p.id, id)) return p;
            return null;
        }
        pub fn has(intents: []const wire.PlanIntent, id: []const u8, kind: wire.IntentKind) bool {
            for (intents) |i| if (std.mem.eql(u8, i.partition_id, id) and i.kind == kind) return true;
            return false;
        }
        pub fn formatLabel(intents: []const wire.PlanIntent, partition: wire.DesiredPartition) bool {
            if (partition.retain_data) return false;
            for (intents) |intent| {
                if (intent.kind == .format and std.mem.eql(u8, intent.partition_id, partition.id)) {
                    if (intent.label) |label| if (std.mem.eql(u8, label, partition.name)) return true;
                }
            }
            return false;
        }
        pub fn diagnostic(a: std.mem.Allocator, list: *std.ArrayList(wire.Diagnostic), code: []const u8, message: []const u8, id: ?[]const u8) !void {
            try list.append(a, .{ .code = code, .message = message, .partition_id = id, .severity = .@"error" });
        }
        pub const optimize = proto.intent_normalization.optimize;
        pub fn guid(text: []const u8) ![16]u8 {
            if (text.len != 32) return error.InvalidGuid;
            for (text) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return error.InvalidGuid;
            var bytes: [16]u8 = undefined;
            var any: u8 = 0;
            for (&bytes, 0..) |*b, i| {
                b.* = std.fmt.parseInt(u8, text[2 * i ..][0..2], 16) catch return error.InvalidGuid;
                any |= b.*;
            }
            if (any == 0) return error.InvalidGuid;
            return bytes;
        }

        pub fn partitionIdentity(a: std.mem.Allocator, disk: []const u8, uuid: []const u8) ![]const u8 {
            const d = try proto.hexDigest(disk);
            const u = try guid(uuid);
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update("pizza-partition-identity-v2");
            hash.update(&d);
            hash.update(&u);
            var result: [32]u8 = undefined;
            hash.final(&result);
            return a.dupe(u8, &std.fmt.bytesToHex(result, .lower));
        }

        pub fn validate(a: std.mem.Allocator, inventory: wire.InventorySnapshot, draft: wire.PlanDraft) !Result {
            if (draft.version != proto.API_VERSION or inventory.version != proto.API_VERSION) return error.UnsupportedProtocolVersion;
            _ = try proto.hexDigest(draft.snapshot_id);
            _ = try proto.hexDigest(draft.disk_identity);
            if (draft.layout.len > Limits.PARTITIONS or draft.intents.len > Limits.INTENTS) return error.PlanTooLarge;
            var diags: std.ArrayList(wire.Diagnostic) = .empty;
            if (!std.mem.eql(u8, inventory.snapshot_id, draft.snapshot_id)) try diagnostic(a, &diags, "stale_inventory", "Disk geometry changed; refresh the inventory before preparing.", null);
            const disk = for (inventory.disks) |d| {
                if (d.identity) |id| if (std.mem.eql(u8, id, draft.disk_identity)) break d;
            } else return error.DiskIdentityNotFound;
            if (disk.read_only) try diagnostic(a, &diags, "read_only", "The disk is read-only.", null);
            if (!std.mem.eql(u8, disk.partition_table orelse "", "gpt")) try diagnostic(a, &diags, "gpt_required", "Execution requires a validated GPT partition table.", null);
            const capacity = try proto.byteCount(disk.capacity);
            if (disk.sector_size < Limits.MINIMUM_SECTOR_BYTES or !std.math.isPowerOfTwo(disk.sector_size)) return error.InvalidSectorSize;
            const usable_start = if (disk.usable_offset) |n| try proto.byteCount(n) else 0;
            const usable_length = if (disk.usable_length) |n| try proto.byteCount(n) else 0;
            const usable_end = try std.math.add(u64, usable_start, usable_length);
            if (usable_length == 0 or usable_end > capacity) try diagnostic(a, &diags, "unknown_usable_range", "GPT usable bounds could not be established.", null);
            for (draft.intents) |intent| {
                if (intent.partition_id.len == 0 or intent.partition_id.len > 128) return error.InvalidPartitionIdentity;
                if (intent.offset) |n| _ = try proto.byteCount(n);
                if (intent.length) |n| if (try proto.byteCount(n) == 0) return error.InvalidByteCount;
                if (intent.kind == .copy) try diagnostic(a, &diags, "intent_not_supported", "This host operation does not yet have a validated compiler.", intent.partition_id);
            }
            var destroyed: std.ArrayList([]const u8) = .empty;
            for (draft.layout, 0..) |p, i| {
                if (p.name.len > Limits.LABEL_BYTES or !std.unicode.utf8ValidateSlice(p.name) or std.mem.indexOfScalar(u8, p.name, 0) != null) return error.InvalidLabel;
                const start = try proto.byteCount(p.offset);
                const length = try proto.byteCount(p.length);
                const end = try std.math.add(u64, start, length);
                if (length == 0 or start % disk.sector_size != 0 or length % disk.sector_size != 0 or start < usable_start or end > usable_end) try diagnostic(a, &diags, "invalid_partition_range", "Partition must fit the usable disk area and align to logical sectors.", p.id);
                for (draft.layout[0..i]) |other| {
                    if (std.mem.eql(u8, other.id, p.id) or (other.slot != null and p.slot != null and other.slot.? == p.slot.?)) try diagnostic(a, &diags, "duplicate_partition", "Partition identity or slot is duplicated.", p.id);
                    const os = try proto.byteCount(other.offset);
                    const oe = try std.math.add(u64, os, try proto.byteCount(other.length));
                    if (start < oe and os < end) try diagnostic(a, &diags, "overlapping_partitions", "Partition ranges overlap.", p.id);
                }
                if (original(disk, p.id)) |old| {
                    const geometry_changed = !std.mem.eql(u8, old.offset, p.offset) or !std.mem.eql(u8, old.length, p.length);
                    const changed = geometry_changed or old.filesystem != p.filesystem or !p.retain_data or !std.mem.eql(u8, old.name, p.name);
                    if (changed and (old.protected or old.encryption != .none)) try diagnostic(a, &diags, "protected_partition", "Boot anchors and encrypted or unidentified volumes cannot be changed.", p.id);
                    if (geometry_changed and !has(draft.intents, p.id, .resize) and !has(draft.intents, p.id, .move)) try diagnostic(a, &diags, "missing_geometry_intent", "Geometry changes need an explicit resize or move intent.", p.id);
                    if (!std.mem.eql(u8, old.name, p.name) and !has(draft.intents, p.id, .label) and !formatLabel(draft.intents, p)) try diagnostic(a, &diags, "missing_label_intent", "Label changes require a label intent or an explicit format label.", p.id);
                    if (old.filesystem != p.filesystem or !p.retain_data) {
                        if (p.retain_data or !has(draft.intents, p.id, .format)) try diagnostic(a, &diags, "format_confirmation_required", "Filesystem replacement must explicitly discard existing contents.", p.id);
                        try destroyed.append(a, p.id);
                    }
                    if (changed) {
                        for (old.capabilities) |cap| if (cap.backend == .maintenance and cap.support == .unavailable and ((cap.operation == .resize and geometry_changed) or (cap.operation == .format and !p.retain_data))) try diagnostic(a, &diags, cap.reason, "The filesystem backend does not permit this operation.", p.id);
                    }
                } else {
                    if (p.retain_data or !has(draft.intents, p.id, .create)) try diagnostic(a, &diags, "invalid_new_partition", "New partitions need a create intent and cannot claim retained data.", p.id);
                    if (p.partition_uuid == null or p.type_guid == null) try diagnostic(a, &diags, "missing_gpt_identity", "New partitions require GPT type and partition UUIDs.", p.id);
                    if (p.partition_uuid) |uuid| {
                        const computed = partitionIdentity(a, draft.disk_identity, uuid) catch "";
                        if (!std.mem.eql(u8, computed, p.id)) try diagnostic(a, &diags, "invalid_partition_identity", "New partition identity must match its disk and GPT UUID.", p.id);
                    }
                    if (p.type_guid) |type_id| {
                        _ = guid(type_id) catch {
                            try diagnostic(a, &diags, "invalid_type_guid", "New partition type must be a nonzero GPT GUID in raw byte order.", p.id);
                            continue;
                        };
                    }
                }
            }
            for (disk.partitions) |old| {
                const found = for (draft.layout) |p| {
                    if (std.mem.eql(u8, p.id, old.id)) break true;
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
                    if (std.mem.eql(u8, p.id, intent.partition_id)) break p;
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
                    .create => mismatch = original(disk, p.id) != null or intent.offset == null or intent.length == null or intent.filesystem == null or intent.filesystem != p.filesystem or p.retain_data,
                    .resize => mismatch = intent.length == null,
                    .move => mismatch = intent.offset == null,
                    .format => mismatch = intent.filesystem == null or intent.filesystem != p.filesystem or p.retain_data,
                    else => {},
                }
                if (intent.label) |label| if (!std.mem.eql(u8, label, p.name)) {
                    mismatch = true;
                };
                if (intent.offset) |n| if (!std.mem.eql(u8, n, p.offset)) {
                    mismatch = true;
                };
                if (intent.length) |n| if (!std.mem.eql(u8, n, p.length)) {
                    mismatch = true;
                };
                if (mismatch) try diagnostic(a, &diags, "intent_layout_mismatch", "Reviewed operation parameters disagree with the final layout.", p.id);
            }
            const bytes = try std.json.Stringify.valueAlloc(a, .{ .draft = draft, .operations = normalized }, .{});
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
            return .{ .disk = disk, .diagnostics = diags, .destructive_partitions = destroyed, .operations = normalized, .digest = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) };
        }
        pub fn admitMaintenance(a: std.mem.Allocator, diags: *std.ArrayList(wire.Diagnostic), disk: wire.HostDisk, draft: wire.PlanDraft) !void {
            for (draft.intents) |intent| if (intent.kind == .label) {
                try diagnostic(a, diags, "maintenance_label_unavailable", "Maintenance cannot execute a label operation. Apply it separately on the host.", intent.partition_id);
            };
            for (draft.layout) |p| {
                const old = original(disk, p.id);
                if (p.retain_data) {
                    if (old) |prior| if (!std.mem.eql(u8, prior.name, p.name)) try diagnostic(a, diags, "maintenance_label_unavailable", "Maintenance cannot change a retained filesystem label. Apply the label separately on the host.", p.id);
                } else if (p.name.len != 0 and p.filesystem != .ntfs) {
                    try diagnostic(a, diags, "maintenance_label_unavailable", "Maintenance cannot create this filesystem label. Use an empty label or apply the format separately on the host.", p.id);
                }
                const needs_backend = old == null or !p.retain_data or (if (old) |prior| !std.mem.eql(u8, prior.offset, p.offset) or !std.mem.eql(u8, prior.length, p.length) or prior.filesystem != p.filesystem else false);
                if (needs_backend) if (p.filesystem) |fs| switch (fs) {
                    .ext2, .ext3, .ext4, .ntfs, .vfat, .btrfs => {},
                    else => try diagnostic(a, diags, "maintenance_filesystem_unavailable", "This filesystem has no validated maintenance backend.", p.id),
                };
            }
        }
    };
}
