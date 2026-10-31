//! NTFS 3.x boot geometry; no allocation occurs until these bounds are checked.
const std = @import("std");
const Reader = @import("../../device.zig").Reader;
pub fn get16(b: []const u8, p: usize) u16 {
    return std.mem.readInt(u16, b[p..][0..2], .little);
}
pub fn get64(b: []const u8, p: usize) u64 {
    return std.mem.readInt(u64, b[p..][0..8], .little);
}
pub fn put64(b: []u8, p: usize, n: u64) void {
    std.mem.writeInt(u64, b[p..][0..8], n, .little);
}
pub const Geometry = struct {
    sector: u32,
    cluster: u32,
    record: u32,
    bytes: u64,
    mft: u64,
    mirror: u64,
    pub fn budget(g: Geometry) !void {
        if (g.bytes / g.cluster > 64 * 1024 * 1024) return error.NtfsResourceLimit;
    }
};
pub fn recognizable(b: []const u8) bool {
    return b.len >= 512 and std.mem.eql(u8, b[3..11], "NTFS    ");
}
fn recordSize(raw: u8, cluster: u32) !u32 {
    const n: i8 = @bitCast(raw);
    if (n < 0) {
        if (n < -16) return error.NtfsInvalidGeometry;
        return @as(u32, 1) << @intCast(-@as(i16, n));
    }
    if (n == 0 or !std.math.isPowerOfTwo(@as(u8, @intCast(n)))) return error.NtfsInvalidGeometry;
    return std.math.mul(u32, @intCast(n), cluster) catch error.NtfsInvalidGeometry;
}
pub fn parse(b: []const u8, capacity: u64) !Geometry {
    if (!recognizable(b) or get16(b, 510) != 0xaa55 or !(b[0] == 0xe9 or b[0] == 0xeb)) return error.NtfsInvalidBoot;
    const sector: u32 = get16(b, 11);
    const spc: u32 = b[13];
    if (sector < 512 or sector > 4096 or !std.math.isPowerOfTwo(sector) or spc == 0 or spc > 128 or !std.math.isPowerOfTwo(spc) or spc * sector > 65536) return error.NtfsInvalidGeometry;
    if (get16(b, 14) != 0 or b[16] != 0 or get16(b, 17) != 0 or get16(b, 19) != 0 or get16(b, 22) != 0) return error.NtfsInvalidGeometry;
    const sectors = std.math.add(u64, get64(b, 40), 1) catch return error.NtfsInvalidGeometry;
    const bytes = std.math.mul(u64, sectors, sector) catch return error.NtfsInvalidGeometry;
    const cluster = sector * spc;
    const record = try recordSize(b[64], cluster);
    const index = try recordSize(b[68], cluster);
    const mft = get64(b, 48);
    const mirror = get64(b, 56);
    if (bytes > capacity or bytes < 1024 * 1024 or record < sector or record > 65536 or index < sector or index > 65536 or mft == mirror or mft == 0 or mirror == 0 or mft >= (sectors - 1) / spc or mirror >= (sectors - 1) / spc) return error.NtfsInvalidGeometry;
    return .{ .sector = sector, .cluster = cluster, .record = record, .bytes = bytes, .mft = mft, .mirror = mirror };
}
pub fn load(io: std.Io, reader: Reader) !Geometry {
    var boot: [512]u8 = undefined;
    try reader.readInto(io, 0, &boot);
    return parse(&boot, reader.target.capacity);
}
