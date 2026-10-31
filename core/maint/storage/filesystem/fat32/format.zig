//! Microsoft FAT32 on-disk codec. All offsets are volume-relative bytes.
const std = @import("std");
const Reader = @import("../../device.zig").Reader;
pub const MIN_CLUSTERS = 65525;
pub const MAX_CLUSTERS = 16 * 1024 * 1024;
pub const MASK: u32 = 0x0fffffff;
pub const BAD: u32 = 0x0ffffff7;
pub const EOC: u32 = 0x0fffffff;
pub const CLEAN_BITS: u32 = 0x0c000000;
pub fn get16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}
pub fn get32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub fn put16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}
pub fn put32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
pub fn first(entry: []const u8) u32 {
    return (@as(u32, get16(entry, 20)) << 16) | get16(entry, 26);
}
pub fn setFirst(entry: []u8, cluster: u32) void {
    put16(entry, 20, @intCast(cluster >> 16));
    put16(entry, 26, @truncate(cluster));
}
pub fn terminal(value: u32) bool {
    return value >= 0x0ffffff8;
}

pub const Geometry = struct {
    sector: u32,
    per_cluster: u32,
    reserved: u32,
    copies: u32,
    fat_sectors: u32,
    total: u32,
    clusters: u32,
    root: u32,
    info: u16,
    backup: u16,
    flags: u16,
    media: u8,
    pub fn bytes(self: Geometry) u64 {
        return @as(u64, self.total) * self.sector;
    }
    pub fn clusterBytes(self: Geometry) u32 {
        return self.sector * self.per_cluster;
    }
    pub fn dataStart(self: Geometry) u64 {
        return (@as(u64, self.reserved) + @as(u64, self.copies) * self.fat_sectors) * self.sector;
    }
    pub fn fatBytes(self: Geometry) usize {
        return @as(usize, self.fat_sectors) * self.sector;
    }
    pub fn fatOffset(self: Geometry, copy: u32) u64 {
        return (@as(u64, self.reserved) + @as(u64, copy) * self.fat_sectors) * self.sector;
    }
    pub fn offset(self: Geometry, cluster: u32) !u64 {
        if (cluster < 2 or cluster >= self.clusters + 2) return error.FatInvalidCluster;
        return self.dataStart() + @as(u64, cluster - 2) * self.clusterBytes();
    }
    pub fn mirrored(self: Geometry) bool {
        return self.flags & 0x80 == 0;
    }
    pub fn active(self: Geometry) u32 {
        return if (self.mirrored()) 0 else self.flags & 0x0f;
    }
    pub fn budget(self: Geometry) !void {
        if (self.clusters > MAX_CLUSTERS or self.fatBytes() > 64 * 1024 * 1024) return error.FatResourceLimit;
    }
};

pub fn recognizable(raw: []const u8) bool {
    return raw.len >= 512 and (raw[0] == 0xe9 or (raw[0] == 0xeb and raw[2] == 0x90)) and
        raw[16] >= 1 and raw[16] <= 4 and get16(raw, 17) == 0 and get16(raw, 22) == 0 and get32(raw, 36) != 0 and get16(raw, 510) == 0xaa55;
}
pub fn parse(raw: []const u8, capacity: u64) !Geometry {
    if (!recognizable(raw)) return error.FatInvalidBoot;
    const sector = get16(raw, 11);
    const per_cluster = raw[13];
    if (sector < 512 or sector > 4096 or !std.math.isPowerOfTwo(sector) or per_cluster == 0 or per_cluster > 128 or !std.math.isPowerOfTwo(per_cluster)) return error.FatInvalidGeometry;
    if (@as(u32, sector) * per_cluster > 32768) return error.FatUnsupportedClusterSize;
    if (get16(raw, 42) != 0 or get16(raw, 40) & ~@as(u16, 0x008f) != 0) return error.FatUnsupportedVersion;
    const reserved = get16(raw, 14);
    const copies = raw[16];
    const fat_sectors = get32(raw, 36);
    const total = get32(raw, 32);
    if (reserved == 0 or copies == 0 or copies > 4 or fat_sectors == 0 or total == 0 or get16(raw, 19) != 0 or @as(u64, total) * sector > capacity) return error.FatInvalidGeometry;
    const data = @as(u64, reserved) + @as(u64, copies) * fat_sectors;
    if (data >= total) return error.FatInvalidGeometry;
    const clusters: u32 = @intCast((total - data) / per_cluster);
    if (clusters < MIN_CLUSTERS or clusters + 1 >= 0x0ffffff0) return error.FatNotFat32;
    if ((@as(u64, clusters) + 2) * 4 > @as(u64, fat_sectors) * sector) return error.FatInvalidGeometry;
    const root = get32(raw, 44);
    const info = get16(raw, 48);
    const backup = get16(raw, 50);
    if (root < 2 or root >= clusters + 2 or (info != 0 and info != 0xffff and info >= reserved) or (backup != 0 and backup != 0xffff and (backup >= reserved or backup == info))) return error.FatInvalidGeometry;
    const flags = get16(raw, 40);
    if (flags & 0x80 != 0 and flags & 15 >= copies) return error.FatInvalidActiveTable;
    if (raw[21] != 0xf0 and raw[21] < 0xf8) return error.FatInvalidMedia;
    return .{ .sector = sector, .per_cluster = per_cluster, .reserved = reserved, .copies = copies, .fat_sectors = fat_sectors, .total = total, .clusters = clusters, .root = root, .info = info, .backup = backup, .flags = flags, .media = raw[21] };
}

pub const Boot = struct { geometry: Geometry, bytes: []u8, recovered: bool = false };
pub fn loadBoot(a: std.mem.Allocator, io: std.Io, reader: Reader) !Boot {
    if (reader.target.capacity < 512) return error.FatInvalidBoot;
    var raw: [512]u8 = undefined;
    try reader.readInto(io, 0, &raw);
    if (parse(&raw, reader.target.capacity)) |geometry| {
        const bytes = try a.alloc(u8, geometry.sector);
        errdefer a.free(bytes);
        try reader.readInto(io, 0, bytes);
        return .{ .geometry = geometry, .bytes = bytes };
    } else |_| {}
    var found: ?Geometry = null;
    for ([_]u32{ 512, 1024, 2048, 4096 }) |sector| {
        const backup: u32 = if (get16(&raw, 50) > 0 and get16(&raw, 50) != 0xffff) get16(&raw, 50) else 6;
        for ([_]u32{ backup, 6 }) |location| {
            const offset = @as(u64, sector) * location;
            if (offset + 512 > reader.target.capacity) continue;
            var candidate: [512]u8 = undefined;
            try reader.readInto(io, offset, &candidate);
            const geometry = parse(&candidate, reader.target.capacity) catch continue;
            if (geometry.sector != sector or geometry.backup != location) continue;
            if (found) |previous| {
                if (!std.meta.eql(previous, geometry)) return error.FatAmbiguousBoot;
            } else {
                found = geometry;
            }
        }
    }
    const geometry = found orelse return error.FatInvalidBoot;
    const bytes = try a.alloc(u8, geometry.sector);
    errdefer a.free(bytes);
    try reader.readInto(io, @as(u64, geometry.backup) * geometry.sector, bytes);
    return .{ .geometry = geometry, .bytes = bytes, .recovered = true };
}

pub fn layout(bytes: u64, sector: u32, per_cluster: u32, reserved: u32, copies: u32, minimum_fat: u32) !Geometry {
    if (sector < 512 or sector > 4096 or !std.math.isPowerOfTwo(sector) or bytes % sector != 0 or bytes / sector > std.math.maxInt(u32)) return error.FatInvalidResizeSize;
    const total: u32 = @intCast(bytes / sector);
    if (total <= reserved) return error.FatResizeTooSmall;
    const denominator = @as(u64, per_cluster) * sector + copies * 4;
    const estimate = try std.math.divCeil(u64, (@as(u64, total - reserved) + 2 * per_cluster) * 4, denominator);
    const fat_sectors: u32 = @intCast(@max(minimum_fat, estimate));
    const data = @as(u64, reserved) + @as(u64, copies) * fat_sectors;
    if (data >= total) return error.FatResizeTooSmall;
    const clusters: u32 = @intCast((total - data) / per_cluster);
    if (clusters < MIN_CLUSTERS + 16) return error.FatResizeTooSmall;
    const geometry: Geometry = .{ .sector = sector, .per_cluster = per_cluster, .reserved = reserved, .copies = copies, .fat_sectors = fat_sectors, .total = total, .clusters = clusters, .root = 2, .info = 1, .backup = 6, .flags = 0, .media = 0xf8 };
    if ((@as(u64, clusters) + 2) * 4 > geometry.fatBytes()) return error.FatInvalidGeometry;
    try geometry.budget();
    return geometry;
}

pub fn infoValid(bytes: []const u8) bool {
    return get32(bytes, 0) == 0x41615252 and get32(bytes, 484) == 0x61417272 and get32(bytes, 508) == 0xaa550000;
}
pub fn makeInfo(bytes: []u8, free: u32, next: u32) void {
    @memset(bytes, 0);
    put32(bytes, 0, 0x41615252);
    put32(bytes, 484, 0x61417272);
    put32(bytes, 488, free);
    put32(bytes, 492, next);
    put32(bytes, 508, 0xaa550000);
}
