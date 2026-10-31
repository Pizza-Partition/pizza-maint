//! Fulcio identity claims and the code-signing leaf policy accepted by pizza-bundle.
const std = @import("std");
const x509 = @import("utils").x509;
const Der = @import("utils").asn1.Element;

/// Preserve the supported issuer curve/hash pairs while delegating verification to std.
pub fn verifyCertificate(cert: x509.Certificate, issuer: x509.Certificate, time: u64) !void {
    const key = try x509.Key.parse(issuer.spki);
    const expected: std.crypto.Certificate.Algorithm = switch (key.curve) {
        .p256 => .ecdsa_with_SHA256,
        .p384 => .ecdsa_with_SHA384,
    };
    if (cert.parsed.signature_algorithm != expected) return error.UnsupportedSignatureAlgorithm;
    try cert.verify(issuer, time);
}

/// Match a Fulcio identity claim at 1.3.6.1.4.1.57264.1.<id> as a DER UTF8String.
pub fn claim(cert: x509.Certificate, id: u8, expected: []const u8) !void {
    // The caller uses the one-byte suffixes 8 through 19, not legacy raw-string claims.
    const oid = "\x2b\x06\x01\x04\x01\x83\xbf\x30\x01" ++ [1]u8{id};
    const text = try Der.one(try cert.extension(oid), 0x0c);
    if (!std.mem.eql(u8, text.data, expected)) return error.CertificateIdentityMismatch;
}
/// Enforce the supported leaf extension profile; chain and identity checks are separate.
pub fn leafUsage(cert: x509.Certificate, a: std.mem.Allocator) !void {
    // Pin the supported Fulcio leaf profile. Unknown critical constraints fail closed.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var rest = cert.extensions.data;
    while (rest.len > 0) {
        const ext = try x509.Extension.take(&rest);
        const result = try seen.getOrPut(a, ext.oid);
        if (result.found_existing) return error.DuplicateExtension;
        // Supported critical OIDs: Key Usage, SAN, Basic Constraints and EKU.
        // SAN contents are checked later by sigstore.identity().
        if (ext.critical and !std.mem.eql(u8, ext.oid, "\x55\x1d\x0f") and !std.mem.eql(u8, ext.oid, "\x55\x1d\x11") and !std.mem.eql(u8, ext.oid, "\x55\x1d\x13") and !std.mem.eql(u8, ext.oid, "\x55\x1d\x25")) return error.UnsupportedCriticalExtension;
    }
    // Key Usage (2.5.29.15): BIT STRING with only digitalSignature set.
    if (!std.mem.eql(u8, try cert.extension("\x55\x1d\x0f"), "\x03\x02\x07\x80")) return error.InvalidAttestation;
    // EKU (2.5.29.37): exactly id-kp-codeSigning (1.3.6.1.5.5.7.3.3).
    if (!std.mem.eql(u8, try cert.extension("\x55\x1d\x25"), "\x30\x0a\x06\x08\x2b\x06\x01\x05\x05\x07\x03\x03")) return error.InvalidAttestation;
    // Basic Constraints (2.5.29.19) may be absent; accepted encodings express CA=false
    // with no path length, either through an empty SEQUENCE or an explicit false value.
    if (cert.extension("\x55\x1d\x13")) |constraints| {
        if (!std.mem.eql(u8, constraints, "\x30\x00") and !std.mem.eql(u8, constraints, "\x30\x03\x01\x01\x00")) return error.InvalidAttestation;
    } else |err| if (err != error.MissingCertificateExtension) return err;
}
