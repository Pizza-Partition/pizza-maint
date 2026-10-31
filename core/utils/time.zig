//! UTC timestamp adapters backed by std.crypto.Certificate.parseTime.
const std = @import("std");
pub fn timestamp(bytes: []const u8) !u64 {
    // Trust-root RFC3339 timestamps only; discard fractional precision conservatively.
    if (bytes.len < 20 or bytes[4] != '-' or bytes[7] != '-' or bytes[10] != 'T' or bytes[13] != ':' or bytes[16] != ':' or bytes[bytes.len - 1] != 'Z') return error.InvalidTimestamp;
    var content: [15]u8 = undefined;
    var n: usize = 0;
    for (bytes[0..19]) |b| if (std.ascii.isDigit(b)) {
        content[n] = b;
        n += 1;
    };
    if (n != 14) return error.InvalidTimestamp;
    content[14] = 'Z';
    return certificateTime(0x18, &content);
}
pub fn certificateTime(tag: u8, bytes: []const u8) !u64 {
    if ((tag != 0x17 or bytes.len != 13) and (tag != 0x18 or bytes.len != 15)) return error.InvalidTimestamp;
    if (bytes[bytes.len - 1] != 'Z') return error.InvalidTimestamp;
    for (bytes[0 .. bytes.len - 1]) |b| if (!std.ascii.isDigit(b)) return error.InvalidTimestamp;
    return std.crypto.Certificate.parseTime(.{ .buffer = bytes, .index = 0 }, .{ .identifier = @bitCast(tag), .slice = .{ .start = 0, .end = @intCast(bytes.len) } });
}
