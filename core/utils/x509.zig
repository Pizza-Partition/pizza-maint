//! Bounded X.509 v3 decoding and ECDSA P-256/P-384 verification.
//! Supports certificates with extensions and no unique-ID fields; this is not a full PKIX validator.
//! Parsing does not establish trust; callers choose trusted issuers and certificate policies.
const std = @import("std");
const e = @import("asn1.zig");
const Der = e.Element;
const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const P384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;

// SPKI algorithm identifiers: complete DER OIDs, including their tag and length.
// id-ecPublicKey (1.2.840.10045.2.1), prime256v1 and secp384r1 respectively.
const EC_ALGORITHM = "\x06\x07\x2a\x86\x48\xce\x3d\x02\x01";
const P256_OID = "\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07";
const P384_OID = "\x06\x05\x2b\x81\x04\x00\x22";
// Complete AlgorithmIdentifier SEQUENCEs for ecdsa-with-SHA256 / ecdsa-with-SHA384.
const SHA256_ALGO = "\x30\x0a\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x02";
const SHA384_ALGO = "\x30\x0a\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x03";

/// An EC public key borrowing its point bytes from the input SPKI buffer.
pub const Key = struct {
    // SEC1-encoded curve point.
    bytes: []const u8,
    curve: enum { p256, p384 },

    /// Parse a P-256 or P-384 key from DER SubjectPublicKeyInfo.
    /// The input buffer must outlive the returned key; point validation is deferred to verify().
    pub fn parse(spki: []const u8) !Key {
        // SubjectPublicKeyInfo ::= SEQUENCE { algorithm, subjectPublicKey BIT STRING }.
        var seq = (try Der.one(spki, 0x30)).data;
        const algo = try Der.take(&seq, 0x30);
        const bit = try Der.take(&seq, 3);
        // A BIT STRING starts with its unused-bit count; byte-aligned EC points require zero.
        if (seq.len != 0 or bit.data.len <= 1 or bit.data[0] != 0) return error.InvalidCertificate;
        if (!std.mem.startsWith(u8, algo.data, EC_ALGORITHM)) return error.InvalidCertificate;
        const curve = algo.data[EC_ALGORITHM.len..];
        // Expected uncompressed SEC1 sizes: 65 / 97 bytes, plus the unused-bit count byte.
        if (std.mem.eql(u8, curve, P256_OID) and bit.data.len == 66) return .{ .bytes = bit.data[1..], .curve = .p256 };
        if (std.mem.eql(u8, curve, P384_OID) and bit.data.len == 98) return .{ .bytes = bit.data[1..], .curve = .p384 };
        return error.UnsupportedSignatureAlgorithm;
    }
    /// Verify a DER ECDSA (r, s) signature over the original message, hashing it internally.
    pub fn verify(key: Key, signature: []const u8, message: []const u8) !void {
        switch (key.curve) {
            .p256 => try (try P256.Signature.fromDer(signature)).verify(message, try P256.PublicKey.fromSec1(key.bytes)),
            .p384 => try (try P384.Signature.fromDer(signature)).verify(message, try P384.PublicKey.fromSec1(key.bytes)),
        }
    }
};

/// Borrowed views into the original certificate DER; the input must outlive this value.
pub const Certificate = struct {
    raw: []const u8,
    parsed: std.crypto.Certificate.Parsed,
    // Original TBSCertificate TLV, including tag and length, covered by the CA signature.
    tbs: Der,
    // Preserve encoded names for exact issuer/subject matching, without DN normalization.
    issuer: []const u8,
    subject: []const u8,
    spki: []const u8,
    algorithm: []const u8,
    signature: []const u8,
    // Inclusive validity bounds, expressed as Unix seconds.
    before: u64,
    after: u64,
    extensions: Der,
    // Original [3] wrapper, retained to reconstruct the precertificate for SCT verification.
    extensions_wrapper: Der,

    /// Decode the supported v3 layout without verifying its signature, validity or identity.
    pub fn parse(raw: []const u8) !Certificate {
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }.
        var top = (try Der.one(raw, 0x30)).data;
        const tbs = try Der.take(&top, 0x30);
        const algorithm = try Der.take(&top, 0x30);
        const signature = try Der.take(&top, 3);
        if (top.len != 0 or signature.data.len <= 1 or signature.data[0] != 0) return error.InvalidCertificate;
        var body = tbs.data;
        // [0] EXPLICIT INTEGER 2 denotes X.509 v3; other versions are unsupported.
        if (!std.mem.eql(u8, (try Der.take(&body, 0xa0)).data, "\x02\x01\x02")) return error.InvalidCertificate;
        const serial = try Der.take(&body, 2);
        if (serial.data.len == 0 or serial.data.len > 20 or serial.data[0] & 128 != 0) return error.InvalidCertificate;
        // The signed algorithm identifier must match the outer one byte for byte.
        const inner_algorithm = try Der.take(&body, 0x30);
        if (!std.mem.eql(u8, inner_algorithm.raw, algorithm.raw)) return error.InvalidCertificate;
        if (!std.mem.eql(u8, algorithm.raw, SHA256_ALGO) and !std.mem.eql(u8, algorithm.raw, SHA384_ALGO)) return error.InvalidCertificate;
        const issuer = try Der.take(&body, 0x30);
        // Validity contains exactly notBefore and notAfter, with no trailing fields.
        var validity = (try Der.take(&body, 0x30)).data;
        const before = try Der.read(validity);
        _ = try @import("time.zig").certificateTime(before.tag, before.data);
        validity = validity[before.raw.len..];
        const after = try Der.read(validity);
        _ = try @import("time.zig").certificateTime(after.tag, after.data);
        if (after.raw.len != validity.len) return error.InvalidCertificate;
        const subject = try Der.take(&body, 0x30);
        try validateName(issuer.data);
        try validateName(subject.data);
        const spki = try Der.take(&body, 0x30);
        _ = try Key.parse(spki.raw);
        // This decoder requires [3] EXPLICIT Extensions immediately after SPKI,
        // so optional issuerUniqueID / subjectUniqueID fields are not accepted.
        const wrapper = try Der.take(&body, 0xa3);
        if (body.len != 0) return error.InvalidCertificate;
        const extensions = try Der.one(wrapper.data, 0x30);
        var extension_bytes = extensions.data;
        while (extension_bytes.len != 0) _ = try Extension.take(&extension_bytes);
        // std.crypto.Certificate currently assumes structurally bounded fields.
        // The standard Decoder preflight above makes malformed/truncated input safe.
        const parsed = try (std.crypto.Certificate{ .buffer = raw, .index = 0 }).parse();
        return .{ .raw = raw, .parsed = parsed, .tbs = tbs, .issuer = issuer.raw, .subject = subject.raw, .spki = spki.raw, .algorithm = algorithm.raw, .signature = signature.data[1..], .before = parsed.validity.not_before, .after = parsed.validity.not_after, .extensions = extensions, .extensions_wrapper = wrapper };
    }
    /// Verify the signature, issuer name and validity at time (Unix seconds).
    /// The caller is responsible for trusting issuer and authenticating time.
    pub fn verify(cert: Certificate, issuer: Certificate, time: u64) !void {
        try cert.parsed.verify(issuer.parsed, std.math.cast(i64, time) orelse return error.InvalidCertificateTime);
    }
    /// Return the extnValue OCTET STRING contents for an OID, rejecting duplicate matches.
    /// The returned bytes still contain the extension-specific encoding.
    pub fn extension(cert: Certificate, wanted: []const u8) ![]const u8 {
        var rest = cert.extensions.data;
        var found: ?[]const u8 = null;
        while (rest.len > 0) {
            const ext = try Extension.take(&rest);
            if (std.mem.eql(u8, ext.oid, wanted)) {
                if (found != null) return error.DuplicateExtension;
                found = ext.data;
            }
        }
        return found orelse error.MissingCertificateExtension;
    }
};
/// A parsed extension borrowing its byte slices from the input certificate.
pub const Extension = struct {
    raw: []const u8,
    oid: []const u8,
    data: []const u8,
    critical: bool,
    /// Parse the next extension and advance rest past its encoded bytes.
    pub fn take(rest: *[]const u8) !Extension {
        // Extension ::= SEQUENCE { extnID OBJECT IDENTIFIER,
        // critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }.
        const ext = try Der.take(rest, 0x30);
        var body = ext.data;
        const oid = try Der.take(&body, 6);
        var critical = false;
        // An omitted flag means false; an encoded flag must be DER TRUE (0xff).
        if (body.len > 0 and body[0] == 1) {
            const flag = try Der.take(&body, 1);
            if (!std.mem.eql(u8, flag.data, "\xff")) return error.InvalidCertificate;
            critical = true;
        }
        const data = try Der.take(&body, 4);
        if (body.len != 0) return error.InvalidCertificate;
        return .{ .raw = ext.raw, .oid = oid.data, .data = data.data, .critical = critical };
    }
};

// Validate the containers traversed internally by std.crypto.Certificate.parse.
// This uses the standard DER Decoder through Element, including parent bounds.
fn validateName(bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        var rdn = (try Der.take(&rest, 0x31)).data;
        while (rdn.len > 0) {
            var attribute = (try Der.take(&rdn, 0x30)).data;
            _ = try Der.take(&attribute, 6);
            const value = try Der.read(attribute);
            if (value.raw.len != attribute.len) return error.InvalidCertificate;
        }
    }
}
