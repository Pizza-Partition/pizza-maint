const std = @import("std");
fn put(comptime T: type, b: []u8, at: usize, n: T) void {
    std.mem.writeInt(T, b[at..][0..@sizeOf(T)], n, .little);
}
fn seal(header: []u8, entries: []const u8) void {
    put(u32, header, 88, std.hash.Crc32.hash(entries));
    put(u32, header, 16, 0);
    put(u32, header, 16, std.hash.Crc32.hash(header[0..92]));
}
pub fn initial(a: std.mem.Allocator, sector: u32) ![]u8 {
    return initialSize(a, sector, 512);
}
pub fn initialSize(a: std.mem.Allocator, sector: u32, sectors: u32) ![]u8 {
    if (sectors < 512) return error.FixtureTooSmall;
    const bytes = try a.alloc(u8, @as(usize, sectors) * sector);
    @memset(bytes, 0);
    put(u16, bytes, 510, 0xaa55);
    bytes[450] = 0xee;
    put(u32, bytes, 454, 1);
    put(u32, bytes, 458, sectors - 1);
    const array = bytes[2 * sector ..][0..sector];
    @memset(array[0..16], 0x11);
    @memset(array[16..32], 0x22);
    put(u64, array, 32, 64);
    put(u64, array, 40, 127);
    put(u64, array, 48, 0x102);
    put(u16, array, 56, 'A');
    @memcpy(bytes[@as(usize, sectors - 2) * sector ..][0..sector], array);
    const header = bytes[sector..][0..sector];
    @memcpy(header[0..8], "EFI PART");
    put(u32, header, 8, 0x10000);
    put(u32, header, 12, 92);
    put(u64, header, 24, 1);
    put(u64, header, 32, sectors - 1);
    put(u64, header, 40, 34);
    put(u64, header, 48, sectors - 3);
    @memset(header[56..72], 0x31);
    put(u64, header, 72, 2);
    put(u32, header, 80, sector / 128);
    put(u32, header, 84, 128);
    seal(header, array);
    const backup = bytes[@as(usize, sectors - 1) * sector ..][0..sector];
    @memcpy(backup, header);
    put(u64, backup, 24, sectors - 1);
    put(u64, backup, 32, 1);
    put(u64, backup, 72, sectors - 2);
    seal(backup, array);
    return bytes;
}
