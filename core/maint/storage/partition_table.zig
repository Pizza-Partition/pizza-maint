//! Partition-table codecs. Geometry is an intent; encoding never writes a disk.
const std = @import("std");
const model = @import("model.zig");
const Reader = @import("device.zig").Reader;
const mutation = @import("mutation.zig");
const Crc = std.hash.Crc32;

pub const Kind = enum { gpt, mbr };

pub const Entry = struct {
    id: model.Digest,
    slot: u32,
    range: model.Range,
    type_id: [16]u8,
    attributes: u64 = 0,
    uuid: [16]u8 = @splat(0),
    name_utf16: [72]u8 = @splat(0),
};

pub const Layout = struct {
    kind: Kind,
    target: model.Target,
    usable: model.Range,
    entries: []const Entry,
    /// Original records retain names, boot code, disk IDs and vendor fields.
    original: []const mutation.Write,
    digest: model.Digest,
    gpt_entry_size: u32 = 0,
};

pub const Driver = struct {
    context: *const anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        read_layout: *const fn (*const anyopaque, std.mem.Allocator, std.Io, Reader) anyerror!Layout,
        validate_layout: *const fn (*const anyopaque, Layout, []const Entry) anyerror!void,
        encode_layout: *const fn (*const anyopaque, std.mem.Allocator, Layout, []const Entry) anyerror!mutation.MutationSet,
    };

    pub fn readLayout(self: Driver, a: std.mem.Allocator, io: std.Io, reader: Reader) !Layout {
        return self.vtable.read_layout(self.context, a, io, reader);
    }

    pub fn validateLayout(self: Driver, layout: Layout, entries: []const Entry) !void {
        return self.vtable.validate_layout(self.context, layout, entries);
    }

    pub fn encodeLayout(self: Driver, a: std.mem.Allocator, layout: Layout, entries: []const Entry) !mutation.MutationSet {
        try self.validateLayout(layout, entries);
        return self.vtable.encode_layout(self.context, a, layout, entries);
    }
};
const CONTEXT: u8 = 0;
pub const BUILTIN: Driver = .{ .context = &CONTEXT, .vtable = &.{ .read_layout = readLayout, .validate_layout = validateLayout, .encode_layout = encodeLayout } };
fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
pub fn stableId(target: model.Target, bytes: []const u8) model.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-partition-identity-v2");
    hash.update(&target.identity);
    hash.update(bytes);
    return hash.finalResult();
}
fn record(a: std.mem.Allocator, io: std.Io, reader: Reader, offset: u64, length: u64) !mutation.Write {
    const range: model.Range = .{ .offset = offset, .length = length };
    return .{ .range = range, .content = try reader.read(a, io, range) };
}
fn header(bytes: []const u8, here: u64, there: u64, sectors: u64) !void {
    if (bytes.len < 512 or !std.mem.eql(u8, bytes[0..8], "EFI PART") or get(u32, bytes, 8) != 0x10000 or get(u32, bytes, 20) != 0) return error.InvalidGptHeader;
    const size = get(u32, bytes, 12);
    if (size < 92 or size > bytes.len or get(u64, bytes, 24) != here or get(u64, bytes, 32) != there or there >= sectors) return error.InvalidGptHeader;
    var hash = Crc.init();
    hash.update(bytes[0..16]);
    hash.update(&.{ 0, 0, 0, 0 });
    hash.update(bytes[20..size]);
    if (hash.final() != get(u32, bytes, 16)) return error.GptHeaderChecksum;
}
fn readLayout(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: Reader) !Layout {
    try reader.target.validate();
    const sector = reader.target.sector_size;
    const sectors = reader.target.capacity / sector;
    if (sectors < 4) return error.InvalidPartitionTable;
    const mbr = try record(a, io, reader, 0, sector);
    if (get(u16, mbr.content, 510) != 0xaa55) return error.InvalidMbrSignature;
    var protective: usize = 0;
    var used: usize = 0;
    for (0..4) |slot| {
        const entry = mbr.content[446 + slot * 16 ..][0..16];
        if (entry[4] != 0) used += 1;
        if (entry[4] == 0xee) {
            protective += 1;
            // Windows also emits the saturated length on disks below 2 TiB.
            // It is only a protective marker; GPT copies and device bounds below
            // remain authoritative for all partition geometry and writes.
            const length = get(u32, entry, 12);
            if (get(u32, entry, 8) != 1 or (length != @min(sectors - 1, std.math.maxInt(u32)) and length != std.math.maxInt(u32)) or entry[0] != 0) return error.InvalidProtectiveMbr;
        }
    }
    const first_header = try record(a, io, reader, sector, sector);
    const has_gpt = std.mem.eql(u8, first_header.content[0..8], "EFI PART");
    if (protective != 0 or has_gpt) {
        if (protective != 1 or used != 1 or !has_gpt) return error.HybridOrInvalidPartitionTable;
        const backup_header = try record(a, io, reader, reader.target.capacity - sector, sector);
        const p = first_header.content;
        const b = backup_header.content;
        try header(p, 1, sectors - 1, sectors);
        try header(b, sectors - 1, 1, sectors);
        if (!std.mem.eql(u8, p[40..72], b[40..72]) or !std.mem.eql(u8, p[80..92], b[80..92])) return error.ConflictingGptCopies;
        const count = get(u32, p, 80);
        const width = get(u32, p, 84);
        if (count == 0 or count > 4096 or width < 128 or width > 4096 or width % 128 != 0) return error.UnsupportedGptGeometry;
        const length = @as(u64, count) * width;
        const padded = std.mem.alignForward(u64, length, sector);
        const first = get(u64, p, 40);
        const last = get(u64, p, 48);
        const pa = get(u64, p, 72);
        const ba = get(u64, b, 72);
        if (first > last or last >= sectors - 1 or pa < 2 or pa >= first or padded / sector > first - pa or ba <= last or ba >= sectors - 1 or padded / sector > sectors - 1 - ba) return error.InvalidGptGeometry;
        const primary = try record(a, io, reader, pa * sector, padded);
        const backup = try record(a, io, reader, ba * sector, padded);
        if (Crc.hash(primary.content[0..@intCast(length)]) != get(u32, p, 88) or !std.mem.eql(u8, primary.content[0..@intCast(length)], backup.content[0..@intCast(length)])) return error.GptEntriesChecksum;
        var entries: std.ArrayList(Entry) = .empty;
        for (0..count) |slot| {
            const raw = primary.content[slot * width ..][0..width];
            if (std.mem.allEqual(u8, raw[0..16], 0)) continue;
            if (std.mem.allEqual(u8, raw[16..32], 0)) return error.MissingPartitionIdentity;
            const start = get(u64, raw, 32);
            const end = get(u64, raw, 40);
            if (start > end or start < first or end > last) return error.InvalidPartitionRange;
            try entries.append(a, .{ .id = stableId(reader.target, raw[16..32]), .slot = @intCast(slot), .range = .{ .offset = start * sector, .length = (end - start + 1) * sector }, .type_id = raw[0..16].*, .attributes = get(u64, raw, 48), .uuid = raw[16..32].*, .name_utf16 = raw[56..128].* });
        }
        const records = try a.dupe(mutation.Write, &.{ backup, backup_header, primary, first_header, mbr });
        const layout = makeLayout(.gpt, reader.target, .{ .offset = first * sector, .length = (last - first + 1) * sector }, try entries.toOwnedSlice(a), records, width);
        try validateLayout(&CONTEXT, layout, layout.entries);
        return layout;
    }
    var entries: std.ArrayList(Entry) = .empty;
    for (0..4) |slot| {
        const raw = mbr.content[446 + slot * 16 ..][0..16];
        if (raw[4] == 0) {
            if (!std.mem.allEqual(u8, raw, 0)) return error.InvalidMbrEntry;
            continue;
        }
        if (raw[4] == 0x05 or raw[4] == 0x0f or raw[4] == 0x85) return error.LogicalPartitionsUnsupported;
        if ((raw[0] != 0 and raw[0] != 0x80) or get(u32, raw, 8) == 0 or get(u32, raw, 12) == 0) return error.InvalidMbrEntry;
        var key: [8]u8 = undefined;
        @memcpy(key[0..4], mbr.content[440..444]);
        put(u32, &key, 4, @intCast(slot));
        var type_id: [16]u8 = @splat(0);
        type_id[0] = raw[4];
        try entries.append(a, .{ .id = stableId(reader.target, &key), .slot = @intCast(slot), .range = .{ .offset = @as(u64, get(u32, raw, 8)) * sector, .length = @as(u64, get(u32, raw, 12)) * sector }, .type_id = type_id, .attributes = raw[0] });
    }
    const layout = makeLayout(.mbr, reader.target, .{ .offset = sector, .length = reader.target.capacity - sector }, try entries.toOwnedSlice(a), try a.dupe(mutation.Write, &.{mbr}), 0);
    try validateLayout(&CONTEXT, layout, layout.entries);
    return layout;
}
fn makeLayout(kind: Kind, target: model.Target, usable: model.Range, entries: []const Entry, original: []const mutation.Write, width: u32) Layout {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&target.identity);
    for (original) |r| {
        var offset: [8]u8 = undefined;
        put(u64, &offset, 0, r.range.offset);
        hash.update(&offset);
        hash.update(r.content);
    }
    return .{ .kind = kind, .target = target, .usable = usable, .entries = entries, .original = original, .digest = hash.finalResult(), .gpt_entry_size = width };
}
fn validateLayout(_: *const anyopaque, layout: Layout, entries: []const Entry) !void {
    try layout.target.validate();
    try layout.usable.validate(layout.target.capacity, layout.target.sector_size);
    if (layout.kind == .mbr and entries.len != layout.entries.len) return error.PartitionMembershipChanged;
    for (entries, 0..) |entry, i| {
        try entry.range.validate(layout.target.capacity, layout.target.sector_size);
        if (entry.range.offset < layout.usable.offset or try entry.range.end() > try layout.usable.end()) return error.PartitionOutsideUsableArea;
        if (layout.kind == .gpt) {
            const slots = get(u32, layout.original[1].content, 80);
            if (entry.slot >= slots or std.mem.allEqual(u8, &entry.type_id, 0) or std.mem.allEqual(u8, &entry.uuid, 0) or !std.mem.eql(u8, &entry.id, &stableId(layout.target, &entry.uuid))) return error.InvalidPartitionIdentity;
        }
        var found = layout.kind == .gpt;
        for (layout.entries) |old| if (old.slot == entry.slot and std.mem.eql(u8, &old.id, &entry.id) and std.mem.eql(u8, &old.type_id, &entry.type_id) and old.attributes == entry.attributes) {
            found = true;
            break;
        };
        if (!found) return error.PartitionIdentityChanged;
        if (layout.kind == .mbr and (try entry.range.end() / layout.target.sector_size > @as(u64, std.math.maxInt(u32)) + 1 or entry.range.length / layout.target.sector_size > std.math.maxInt(u32))) return error.MbrAddressOverflow;
        for (entries[0..i]) |other| {
            if (entry.slot == other.slot or std.mem.eql(u8, &entry.id, &other.id)) return error.DuplicatePartitionIdentity;
            if (entry.range.overlaps(other.range)) return error.OverlappingPartitions;
        }
    }
}
fn sealHeader(bytes: []u8, entries_crc: u32) void {
    put(u32, bytes, 88, entries_crc);
    put(u32, bytes, 16, 0);
    put(u32, bytes, 16, Crc.hash(bytes[0..get(u32, bytes, 12)]));
}
fn encodeLayout(_: *const anyopaque, a: std.mem.Allocator, layout: Layout, entries: []const Entry) !mutation.MutationSet {
    var writes: std.ArrayList(mutation.Write) = .empty;
    const sector = layout.target.sector_size;
    for (layout.original, 0..) |old, index| {
        const bytes = try a.dupe(u8, old.content);
        if (layout.kind == .mbr) {
            for (entries) |entry| {
                const raw = bytes[446 + entry.slot * 16 ..][0..16];
                @memcpy(raw[1..4], &@as([3]u8, .{ 0xfe, 0xff, 0xff }));
                @memcpy(raw[5..8], &@as([3]u8, .{ 0xfe, 0xff, 0xff }));
                put(u32, raw, 8, @intCast(entry.range.offset / sector));
                put(u32, raw, 12, @intCast(entry.range.length / sector));
            }
        } else if (index == 0 or index == 2) {
            try encodeGptEntries(layout, entries, bytes);
        } else if (index == 1 or index == 3) {
            // The preceding record is the matching entry array, even if its
            // bytes did not change and therefore were omitted from writes.
            const array = try a.dupe(u8, layout.original[index - 1].content);
            try encodeGptEntries(layout, entries, array);
            sealHeader(bytes, Crc.hash(array[0 .. @as(usize, get(u32, bytes, 80)) * layout.gpt_entry_size]));
        }
        if (!std.mem.eql(u8, bytes, old.content)) try writes.append(a, .{ .range = old.range, .content = bytes, .expected = model.digest(old.content) });
    }
    return .{ .target = layout.target, .writes = try writes.toOwnedSlice(a) };
}

fn encodeGptEntries(layout: Layout, entries: []const Entry, bytes: []u8) !void {
    const width = layout.gpt_entry_size;
    const slots = get(u32, layout.original[1].content, 80);
    for (0..slots) |i| {
        const raw = bytes[i * width ..][0..width];
        const entry = for (entries) |e| {
            if (e.slot == i) break e;
        } else {
            @memset(raw, 0);
            continue;
        };
        if (!std.mem.eql(u8, raw[16..32], &entry.uuid)) @memset(raw, 0);
        @memcpy(raw[0..16], &entry.type_id);
        @memcpy(raw[16..32], &entry.uuid);
        put(u64, raw, 32, entry.range.offset / layout.target.sector_size);
        put(u64, raw, 40, try entry.range.end() / layout.target.sector_size - 1);
        put(u64, raw, 48, entry.attributes);
        @memcpy(raw[56..128], &entry.name_utf16);
    }
}
