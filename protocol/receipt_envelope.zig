//! ESP completion receipt envelope, shared by host and maintenance.
const std = @import("std");
const Digest = [32]u8;
const digest = @import("firmware_pin.zig").digest;
pub const ReceiptEnvelope = struct { session: Digest, disk_identity: Digest, bytes: []const u8 };
/// Matching on-disk envelope is produced by pizza-maint's ESP receipt sink.
/// Checksums prove complete publication; parseCompletion still binds all five
/// identities to the host's protected pending record.
pub fn decode(bytes: []const u8) !ReceiptEnvelope {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..8], "PZRCPT01")) return error.InvalidCompletionReceiptEnvelope;
    const size = std.mem.readInt(u32, bytes[8..12], .little);
    const block = std.mem.readInt(u32, bytes[12..16], .little);
    if (block < 4096 or block > 1024 * 1024 or !std.math.isPowerOfTwo(block) or size == 0 or size > 65536 or
        bytes.len != block + std.mem.alignForward(u64, 65536, block)) return error.InvalidCompletionReceiptEnvelope;
    const header = bytes[0..block];
    const body = bytes[block..];
    return decodeParts(header, body);
}

pub fn decodeParts(header: []const u8, body: []const u8) !ReceiptEnvelope {
    if (header.len < 4096 or header.len > 1024 * 1024 or !std.math.isPowerOfTwo(header.len) or
        !std.mem.eql(u8, header[0..8], "PZRCPT01") or std.mem.readInt(u32, header[12..16], .little) != header.len or
        body.len != std.mem.alignForward(usize, 65536, header.len)) return error.InvalidCompletionReceiptEnvelope;
    const size = std.mem.readInt(u32, header[8..12], .little);
    if (size == 0 or size > 65536) return error.InvalidCompletionReceiptEnvelope;
    if (!std.mem.eql(u8, header[header.len - 32 ..], &digest(header[0 .. header.len - 32])) or
        !std.mem.eql(u8, header[80..112], &digest(body[0..size])) or
        !std.mem.allEqual(u8, header[112 .. header.len - 32], 0) or !std.mem.allEqual(u8, body[size..], 0)) return error.InvalidCompletionReceiptEnvelope;
    return .{ .session = header[16..48].*, .disk_identity = header[48..80].*, .bytes = body[0..size] };
}

pub fn encodeHeader(header: []u8, bytes: []const u8, session: Digest, disk_identity: Digest) !void {
    if (header.len < 4096 or header.len > 1024 * 1024 or !std.math.isPowerOfTwo(header.len) or bytes.len == 0 or bytes.len > 65536) return error.InvalidCompletionReceiptEnvelope;
    @memset(header, 0);
    @memcpy(header[0..8], "PZRCPT01");
    std.mem.writeInt(u32, header[8..12], @intCast(bytes.len), .little);
    std.mem.writeInt(u32, header[12..16], @intCast(header.len), .little);
    @memcpy(header[16..48], &session);
    @memcpy(header[48..80], &disk_identity);
    @memcpy(header[80..112], &digest(bytes));
    @memcpy(header[header.len - 32 ..], &digest(header[0 .. header.len - 32]));
}

test "host decodes the maintenance receipt envelope and rejects torn publication" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, 4096 + 65536);
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "PZRCPT01");
    std.mem.writeInt(u32, bytes[8..12], 2, .little);
    std.mem.writeInt(u32, bytes[12..16], 4096, .little);
    @memset(bytes[16..48], 1);
    @memset(bytes[48..80], 2);
    @memcpy(bytes[4096..4098], "{}");
    @memcpy(bytes[80..112], &digest("{}"));
    @memcpy(bytes[4064..4096], &digest(bytes[0..4064]));
    const envelope = try decode(bytes);
    try std.testing.expectEqualStrings("{}", envelope.bytes);
    try std.testing.expectEqual(@as(Digest, @splat(1)), envelope.session);
    bytes[4097] = '!';
    try std.testing.expectError(error.InvalidCompletionReceiptEnvelope, decode(bytes));
    bytes[4097] = '}';
    bytes[bytes.len - 1] = 1;
    try std.testing.expectError(error.InvalidCompletionReceiptEnvelope, decode(bytes));
    try std.testing.expectError(error.InvalidCompletionReceiptEnvelope, decode(bytes[0..4096]));
}
