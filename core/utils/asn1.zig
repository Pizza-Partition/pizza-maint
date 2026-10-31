//! Borrowed ASN.1 views and framing adapters over the standard DER codecs.
//! Length/tag decoding and DER encoding are entirely provided by std.crypto.codecs.
const std = @import("std");
const asn1 = std.crypto.codecs.asn1;

pub const Element = struct {
    tag: u8,
    raw: []const u8,
    data: []const u8,

    pub fn read(bytes: []const u8) !Element {
        var decoder: asn1.der.Decoder = .{ .bytes = bytes };
        const element = try decoder.element(.{});
        if (@backingInt(element.tag.number) >= 31) return error.UnsupportedAsn1Tag;
        var encoded_tag: [asn1.Tag.max_encoded_len]u8 = undefined;
        const tag = element.tag.encodeToSlice(&encoded_tag);
        return .{ .tag = tag[0], .raw = bytes[0..element.slice.end], .data = decoder.view(element) };
    }

    pub fn one(bytes: []const u8, expected: u8) !Element {
        const element = try read(bytes);
        if (element.raw.len != bytes.len or element.tag != expected) return error.InvalidAsn1Structure;
        return element;
    }

    pub fn take(bytes: *[]const u8, expected: u8) !Element {
        const element = try read(bytes.*);
        if (element.tag != expected) return error.InvalidAsn1Structure;
        bytes.* = bytes.*[element.raw.len..];
        return element;
    }
};

pub fn wrap(a: std.mem.Allocator, encoded_tag: u8, bytes: []const u8) ![]const u8 {
    var tag_reader: std.Io.Reader = .fixed(&.{encoded_tag});
    const tag = try asn1.Tag.decode(&tag_reader);
    var encoder = asn1.der.Encoder.init(a);
    defer encoder.deinit();
    try encoder.tagBytes(tag, bytes);
    return encoder.buffer.toOwnedSlice();
}
