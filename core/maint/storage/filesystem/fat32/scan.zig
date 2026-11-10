//! Allocation ownership and complete reachable-directory traversal. Never write
//! through Reader. Orphan chains are retained for a separate salvage plan.
const std = @import("std");
const Reader = @import("../../device.zig").Reader;
const format = @import("format.zig");
const fatfs = @import("fatfs_c");
pub const Object = struct { start: u32, chain: []u32, bytes: u64, directory: bool, parent: u32, relocated: []u32 = &.{} };
pub const Reference = struct { directory: usize, position: usize, cluster: u32 };
pub const Graph = struct {
    allocator: std.mem.Allocator,
    geometry: format.Geometry,
    fat: []u8,
    owners: []u32,
    objects: std.ArrayList(Object) = .empty,
    references: std.ArrayList(Reference) = .empty,
    free: u32 = 0,
    next_free: u32 = 0xffffffff,
    orphans: u32 = 0,
    directory_bytes: u64 = 0,
    pub fn value(self: Graph, cluster: u32) u32 {
        return format.get32(self.fat, @as(usize, cluster) * 4) & format.MASK;
    }
    pub fn set(self: *Graph, cluster: u32, value_: u32) void {
        const at = @as(usize, cluster) * 4;
        format.put32(self.fat, at, (format.get32(self.fat, at) & ~format.MASK) | value_);
    }
    fn claim(self: *Graph, start: u32, bytes: u64, directory: bool, parent: u32) !usize {
        if (self.objects.items.len >= 1024 * 1024) return error.FatResourceLimit;
        const index = self.objects.items.len;
        var chain: std.ArrayList(u32) = .empty;
        var cluster = start;
        while (true) {
            if (cluster < 2 or cluster >= self.geometry.clusters + 2) return error.FatInvalidCluster;
            if (self.owners[cluster] != 0) return if (self.owners[cluster] == index + 1) error.FatChainCycle else error.FatCrossLink;
            self.owners[cluster] = @intCast(index + 1);
            try chain.append(self.allocator, cluster);
            const next = self.value(cluster);
            if (format.terminal(next)) break;
            if (next == 0 or next == format.BAD) return error.FatBrokenChain;
            cluster = next;
        }
        const length = @as(u64, chain.items.len) * self.geometry.clusterBytes();
        if (!directory and (bytes == 0 or length < bytes or length - bytes >= self.geometry.clusterBytes())) return error.FatFileLength;
        if (directory) {
            self.directory_bytes += length;
            if (self.directory_bytes > 64 * 1024 * 1024) return error.FatResourceLimit;
        }
        try self.objects.append(self.allocator, .{ .start = start, .chain = try chain.toOwnedSlice(self.allocator), .bytes = if (directory) length else bytes, .directory = directory, .parent = parent });
        return index;
    }
};

const LongName = struct {
    expected: u8 = 0,
    total: u8 = 0,
    checksum: u8 = 0,
    units: [260]u16 = @splat(0xffff),
    fn piece(self: *LongName, entry: []const u8) !void {
        const ordinal = entry[0] & 31;
        if (ordinal == 0 or ordinal > 20 or entry[0] & 0xa0 != 0 or entry[12] != 0 or format.get16(entry, 26) != 0) return error.FatInvalidLongName;
        if (entry[0] & 0x40 != 0) {
            if (self.total != 0) return error.FatInvalidLongName;
            self.total = ordinal;
            self.expected = ordinal;
            self.checksum = entry[13];
            @memset(&self.units, 0xffff);
        }
        if (self.expected != ordinal or self.checksum != entry[13]) return error.FatInvalidLongName;
        const offsets = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
        for (offsets, 0..) |at, index| self.units[(@as(usize, ordinal) - 1) * 13 + index] = format.get16(entry, at);
        self.expected -= 1;
    }
    fn finish(self: *LongName, a: std.mem.Allocator, short: []const u8) !?[]const u8 {
        if (self.total == 0) return null;
        if (self.expected != 0) return error.FatInvalidLongName;
        var checksum: u8 = 0;
        for (short[0..11]) |byte| checksum = ((checksum & 1) << 7) +% (checksum >> 1) +% byte;
        if (checksum != self.checksum) return error.FatInvalidLongName;
        var name: std.ArrayList(u8) = .empty;
        var terminated = false;
        var length: usize = 0;
        var index: usize = 0;
        while (index < @as(usize, self.total) * 13) : (index += 1) {
            const unit = self.units[index];
            if (unit == 0 and !terminated) {
                terminated = true;
                continue;
            }
            if (terminated) {
                if (unit != 0xffff) return error.FatInvalidLongName;
                continue;
            }
            if (unit == 0xffff or unit < 32 or (unit < 128 and std.mem.indexOfScalar(u8, "\"*/:<>?\\|", @intCast(unit)) != null)) return error.FatInvalidLongName;
            length += 1;
            var scalar: u32 = unit;
            if (unit >= 0xd800 and unit <= 0xdbff) {
                index += 1;
                if (index >= @as(usize, self.total) * 13) return error.FatInvalidLongName;
                const low = self.units[index];
                if (low < 0xdc00 or low > 0xdfff) return error.FatInvalidLongName;
                scalar = 0x10000 + (@as(u32, unit - 0xd800) << 10) + low - 0xdc00;
                length += 1;
            } else if (unit >= 0xdc00 and unit <= 0xdfff) return error.FatInvalidLongName;
            scalar = fatfs.ff_wtoupper(scalar);
            try name.appendSlice(a, std.mem.asBytes(&scalar));
        }
        if (length == 0 or length > 255) return error.FatInvalidLongName;
        self.* = .{};
        return try name.toOwnedSlice(a);
    }
};
fn shortName(entry: []const u8) ![11]u8 {
    var result: [11]u8 = undefined;
    for (entry[0..11], 0..) |byte, index| {
        if (byte < 32 and !(index == 0 and byte == 5)) return error.FatInvalidDirectoryEntry;
        if (std.mem.indexOfScalar(u8, "\"*+,./:;<=>?[\\]|", byte) != null) return error.FatInvalidDirectoryEntry;
        result[index] = std.ascii.toUpper(byte);
    }
    if (result[0] == ' ') return error.FatInvalidDirectoryEntry;
    return result;
}

pub fn scan(a: std.mem.Allocator, io: std.Io, reader: Reader, geometry: format.Geometry, fat: []u8) !Graph {
    try geometry.budget();
    if (fat.len != geometry.fatBytes()) return error.FatInvalidGeometry;
    var graph: Graph = .{ .allocator = a, .geometry = geometry, .fat = fat, .owners = try a.alloc(u32, @as(usize, geometry.clusters) + 2) };
    @memset(graph.owners, 0);
    if (graph.value(0) != (0x0fffff00 | @as(u32, geometry.media)) or graph.value(1) & 0x03ffffff != 0x03ffffff) return error.FatReservedEntry;
    for (2..@as(usize, geometry.clusters) + 2) |index| {
        const value = graph.value(@intCast(index));
        if (value == 0) {
            graph.free += 1;
            if (graph.next_free == 0xffffffff) graph.next_free = @intCast(index);
        } else if (!format.terminal(value) and value != format.BAD and (value < 2 or value >= geometry.clusters + 2)) return error.FatInvalidLink;
    }
    _ = try graph.claim(geometry.root, 0, true, 0);
    const buffer = try a.alloc(u8, geometry.clusterBytes());
    defer a.free(buffer);
    var object_index: usize = 0;
    while (object_index < graph.objects.items.len) : (object_index += 1) {
        const object = graph.objects.items[object_index];
        if (!object.directory) continue;
        var names: std.StringHashMap(void) = .init(a);
        defer names.deinit();
        var shorts: std.AutoHashMap([11]u8, void) = .init(a);
        defer shorts.deinit();
        var lfn: LongName = .{};
        var ended = false;
        var dots: u2 = 0;
        for (object.chain, 0..) |cluster, part| {
            if (ended) break;
            try reader.readInto(io, try geometry.offset(cluster), buffer);
            var within: usize = 0;
            while (within < buffer.len) : (within += 32) {
                const entry = buffer[within..][0..32];
                if (entry[0] == 0) {
                    if (lfn.total != 0) return error.FatInvalidLongName;
                    ended = true;
                    break;
                }
                if (entry[0] == 0xe5) {
                    if (lfn.total != 0) return error.FatInvalidLongName;
                    continue;
                }
                const attr = entry[11];
                if (attr == 0x0f) {
                    try lfn.piece(entry);
                    continue;
                }
                if (attr & 0xc0 != 0 or entry[12] & ~@as(u8, 0x18) != 0 or entry[13] > 199) return error.FatInvalidDirectoryEntry;
                const long_name = try lfn.finish(a, entry);
                if (long_name) |name| {
                    if ((try names.getOrPut(name)).found_existing) return error.FatDuplicateName;
                }
                const first = format.first(entry);
                const size = format.get32(entry, 28);
                const directory = attr & 0x10 != 0;
                const logical = part * buffer.len + within;
                if (std.mem.eql(u8, entry[0..11], ".          ") or std.mem.eql(u8, entry[0..11], "..         ")) {
                    if (object_index == 0 or !directory or long_name != null or size != 0 or logical > 32) return error.FatInvalidDotEntry;
                    const parent = entry[1] == '.';
                    if (first != (if (parent) object.parent else object.start) or logical != (if (parent) @as(usize, 32) else 0)) return error.FatInvalidDotEntry;
                    dots += 1;
                } else if (attr & 8 != 0) {
                    if (directory or first != 0 or size != 0 or object_index != 0 or long_name != null) return error.FatInvalidVolumeLabel;
                    continue;
                } else {
                    const name = try shortName(entry);
                    if ((try shorts.getOrPut(name)).found_existing) return error.FatDuplicateName;
                    if (directory) {
                        if (size != 0) return error.FatInvalidDirectoryEntry;
                        _ = try graph.claim(first, 0, true, if (object_index == 0) 0 else object.start);
                    } else if (first == 0) {
                        if (size != 0) return error.FatBrokenChain;
                    } else _ = try graph.claim(first, size, false, 0);
                }
                if (first != 0) try graph.references.append(a, .{ .directory = object_index, .position = logical, .cluster = first });
            }
        }
        if (lfn.total != 0) return error.FatInvalidLongName;
        if (object_index != 0 and dots != 2) return error.FatInvalidDotEntry;
    }
    for (2..@as(usize, geometry.clusters) + 2) |index| {
        if (graph.owners[index] == 0 and graph.value(@intCast(index)) != 0 and graph.value(@intCast(index)) != format.BAD) graph.orphans += 1;
    }
    return graph;
}

pub const Loaded = struct { boot: format.Boot, graph: Graph, copies_differ: bool, backup_bad: bool, info_bad: bool, dirty: bool };
pub fn load(a: std.mem.Allocator, io: std.Io, reader: Reader, allow_repair: bool) !Loaded {
    const boot = try format.loadBoot(a, io, reader);
    const g = boot.geometry;
    try g.budget();
    var selected: ?Graph = null;
    var differs = false;
    var first_error: ?anyerror = null;
    // A mismatching mirror is repairable only when a unique coherent graph
    // exists. Never choose FAT #0 merely because it happens to come first.
    const count = if (g.mirrored()) g.copies else 1;
    for (0..count) |copy_index| {
        const copy: u32 = if (g.mirrored()) @intCast(copy_index) else g.active();
        const fat = try a.alloc(u8, g.fatBytes());
        try reader.readInto(io, g.fatOffset(copy), fat);
        var candidate_arena: std.heap.ArenaAllocator = .init(a);
        defer candidate_arena.deinit();
        const candidate = scan(candidate_arena.allocator(), io, reader, g, fat) catch |err| {
            switch (err) {
                error.FatInvalidCluster, error.FatChainCycle, error.FatCrossLink, error.FatBrokenChain, error.FatFileLength, error.FatReservedEntry, error.FatInvalidLink, error.FatInvalidLongName, error.FatInvalidDirectoryEntry, error.FatDuplicateName, error.FatInvalidDotEntry, error.FatInvalidVolumeLabel => {},
                else => return err,
            }
            if (first_error == null) first_error = err;
            differs = true;
            a.free(fat);
            continue;
        };
        _ = candidate;
        if (selected) |previous| {
            var same = true;
            for (0..@as(usize, g.clusters) + 2) |index| if ((format.get32(previous.fat, index * 4) & format.MASK) != (format.get32(fat, index * 4) & format.MASK)) {
                same = false;
                break;
            };
            if (!same) return error.FatAmbiguousTables;
            a.free(fat);
        } else selected = try scan(a, io, reader, g, fat);
    }
    const graph = selected orelse return first_error orelse error.FatInvalidTable;
    var backup_bad = boot.recovered;
    if (g.backup != 0 and g.backup != 0xffff) {
        const backup = try a.alloc(u8, g.sector);
        defer a.free(backup);
        try reader.readInto(io, @as(u64, g.backup) * g.sector, backup);
        if (!std.mem.eql(u8, backup, boot.bytes) or format.get16(backup, 510) != 0xaa55) backup_bad = true;
        if (format.parse(backup, reader.target.capacity)) |other| {
            if (!std.meta.eql(g, other)) return error.FatAmbiguousBoot;
        } else |_| {}
    }
    var info_bad = false;
    if (g.info != 0 and g.info != 0xffff) {
        const info = try a.alloc(u8, g.sector);
        defer a.free(info);
        try reader.readInto(io, @as(u64, g.info) * g.sector, info);
        const free = format.get32(info, 488);
        const next = format.get32(info, 492);
        info_bad = !format.infoValid(info) or (free != 0xffffffff and free != graph.free) or (next != 0xffffffff and (next < 2 or next >= g.clusters + 2));
    }
    const dirty = graph.value(1) & format.CLEAN_BITS != format.CLEAN_BITS or boot.bytes[65] & 1 != 0;
    if (!allow_repair) {
        if (differs) return error.FatTablesDiffer;
        if (backup_bad) return error.FatBackupBoot;
        if (info_bad) return error.FatFsInfo;
        if (dirty) return error.FatDirtyVolume;
        if (graph.orphans != 0) return error.FatOrphanChain;
    }
    return .{ .boot = boot, .graph = graph, .copies_differ = differs, .backup_bad = backup_bad, .info_bad = info_bad, .dirty = dirty };
}
