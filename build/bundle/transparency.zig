//! Offline Rekor v1 inclusion verification and RFC 6962 certificate transparency.
const std = @import("std");
const encoding = @import("utils").asn1;
const schema = @import("schema.zig");
const certs = @import("utils").x509;
// RFC 6962 embedded SCT list: 1.3.6.1.4.1.11129.2.4.2.
const SCT_OID = "\x2b\x06\x01\x04\x01\xd6\x79\x02\x04\x02";

pub fn logKey(a: std.mem.Allocator, logs: []const schema.Log, id: []const u8, time: u64) !certs.Key {
    for (logs) |log| {
        const log_id = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(log.logId.keyId));
        try std.base64.standard.Decoder.decode(log_id, log.logId.keyId);
        if (!std.mem.eql(u8, log_id, id)) continue;
        if (!std.mem.eql(u8, log.hashAlgorithm, "SHA2_256")) return error.InvalidAttestation;
        try log.publicKey.validFor.validate(time);
        if (!std.mem.eql(u8, log.publicKey.keyDetails, "PKIX_ECDSA_P256_SHA_256")) return error.InvalidAttestation;
        const spki = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(log.publicKey.rawBytes));
        try std.base64.standard.Decoder.decode(spki, log.publicKey.rawBytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(spki, &digest, .{});
        if (!std.mem.eql(u8, &digest, id)) return error.InvalidAttestation;
        return certs.Key.parse(spki);
    }
    return error.UntrustedTransparencyLog;
}

pub fn rekor(a: std.mem.Allocator, logs: []const schema.Log, entry: schema.LogEntry, payload: []const u8, signature: []const u8, certificate: []const u8, now: u64) !u64 {
    if (!std.mem.eql(u8, entry.kindVersion.kind, "dsse") or !std.mem.eql(u8, entry.kindVersion.version, "0.0.1")) return error.InvalidAttestation;
    const time = try std.fmt.parseInt(u64, entry.integratedTime, 10);
    if (time > now) return error.InvalidAttestation;
    const id = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(entry.logId.keyId));
    try std.base64.standard.Decoder.decode(id, entry.logId.keyId);
    const key = try logKey(a, logs, id, time);
    const body = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(entry.canonicalizedBody));
    try std.base64.standard.Decoder.decode(body, entry.canonicalizedBody);
    // SET uses RFC 8785 canonical JSON: these four known fields, in sorted order.
    const signed = try std.json.Stringify.valueAlloc(a, .{ .body = entry.canonicalizedBody, .integratedTime = time, .logID = std.fmt.bytesToHex(id[0..32].*, .lower), .logIndex = try std.fmt.parseInt(u64, entry.logIndex, 10) }, .{});
    const timestamp_signature = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(entry.inclusionPromise.signedEntryTimestamp));
    try std.base64.standard.Decoder.decode(timestamp_signature, entry.inclusionPromise.signedEntryTimestamp);
    try key.verify(timestamp_signature, signed);
    // Bind the authenticated log body to this exact payload, signature and leaf certificate.
    const record = try std.json.parseFromSliceLeaky(schema.LogBody, a, body, .{ .ignore_unknown_fields = true, .max_value_len = 1024 * 1024 });
    if (!std.mem.eql(u8, record.kind, "dsse") or !std.mem.eql(u8, record.apiVersion, "0.0.1")) return error.InvalidAttestation;
    var payload_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &payload_digest, .{});
    if (!std.mem.eql(u8, record.spec.payloadHash.algorithm, "sha256") or !std.mem.eql(u8, record.spec.payloadHash.value, &std.fmt.bytesToHex(payload_digest, .lower))) return error.InvalidAttestation;
    if (record.spec.signatures.len != 1) return error.InvalidAttestation;
    const logged_signature = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(record.spec.signatures[0].signature));
    try std.base64.standard.Decoder.decode(logged_signature, record.spec.signatures[0].signature);
    if (!std.mem.eql(u8, logged_signature, signature)) return error.InvalidAttestation;
    const pem = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(record.spec.signatures[0].verifier));
    try std.base64.standard.Decoder.decode(pem, record.spec.signatures[0].verifier);
    const prefix = "-----BEGIN CERTIFICATE-----\n";
    const suffix = "-----END CERTIFICATE-----\n";
    if (!std.mem.startsWith(u8, pem, prefix) or !std.mem.endsWith(u8, pem, suffix)) return error.InvalidAttestation;
    const middle = pem[prefix.len .. pem.len - suffix.len];
    var compact: std.Io.Writer.Allocating = .init(a);
    for (middle) |b| if (b != '\n') try compact.writer.writeByte(b);
    const logged_certificate = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(compact.written()));
    try std.base64.standard.Decoder.decode(logged_certificate, compact.written());
    if (!std.mem.eql(u8, logged_certificate, certificate)) return error.InvalidAttestation;
    try inclusion(a, key, id, body, entry.inclusionProof);
    return time;
}

fn inclusion(a: std.mem.Allocator, key: certs.Key, id: []const u8, body: []const u8, proof: schema.InclusionProof) !void {
    var index = try std.fmt.parseInt(u64, proof.logIndex, 10);
    const size = try std.fmt.parseInt(u64, proof.treeSize, 10);
    if (size == 0 or index >= size) return error.InvalidAttestation;
    var last = size - 1;
    var hash: [32]u8 = undefined;
    var leaf_hash = std.crypto.hash.sha2.Sha256.init(.{});
    leaf_hash.update(&.{0});
    leaf_hash.update(body);
    leaf_hash.final(&hash);
    if (proof.hashes.len > 64) return error.InvalidAttestation;
    for (proof.hashes) |encoded_sibling| {
        const sibling = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded_sibling));
        try std.base64.standard.Decoder.decode(sibling, encoded_sibling);
        if (sibling.len != 32 or last == 0) return error.InvalidAttestation;
        const left = index & 1 == 1 or index == last;
        var node_hash = std.crypto.hash.sha2.Sha256.init(.{});
        node_hash.update(&.{1});
        node_hash.update(if (left) sibling else &hash);
        node_hash.update(if (left) &hash else sibling);
        node_hash.final(&hash);
        if (left) while (index & 1 == 0 and index != 0) {
            index >>= 1;
            last >>= 1;
        };
        index >>= 1;
        last >>= 1;
    }
    const root_hash = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(proof.rootHash));
    try std.base64.standard.Decoder.decode(root_hash, proof.rootHash);
    if (last != 0 or index != 0 or !std.mem.eql(u8, &hash, root_hash)) return error.InvalidAttestation;
    const checkpoint = proof.checkpoint.envelope;
    const boundary = std.mem.indexOf(u8, checkpoint, "\n\n") orelse return error.InvalidCheckpoint;
    const message = checkpoint[0 .. boundary + 1];
    var lines = std.mem.splitScalar(u8, message, '\n');
    const origin = lines.next() orelse return error.InvalidCheckpoint;
    if (!std.mem.startsWith(u8, origin, "rekor.sigstore.dev - ")) return error.InvalidAttestation;
    if (try std.fmt.parseInt(u64, lines.next() orelse return error.InvalidCheckpoint, 10) != size) return error.InvalidAttestation;
    const encoded_checkpoint_hash = lines.next() orelse return error.InvalidCheckpoint;
    const checkpoint_hash = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded_checkpoint_hash));
    try std.base64.standard.Decoder.decode(checkpoint_hash, encoded_checkpoint_hash);
    if (!std.mem.eql(u8, checkpoint_hash, &hash)) return error.InvalidAttestation;
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidCheckpoint, "") or lines.next() != null) return error.InvalidAttestation;
    var notes = std.mem.splitScalar(u8, checkpoint[boundary + 2 ..], '\n');
    while (notes.next()) |line| {
        const prefix = "— rekor.sigstore.dev ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const sig = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(line[prefix.len..]));
        try std.base64.standard.Decoder.decode(sig, line[prefix.len..]);
        if (sig.len <= 4 or !std.mem.eql(u8, sig[0..4], id[0..4])) continue;
        key.verify(sig[4..], message) catch continue;
        return;
    }
    return error.InvalidCheckpointSignature;
}

pub fn sct(a: std.mem.Allocator, logs: []const schema.Log, leaf: certs.Certificate, issuer: certs.Certificate, now: u64) !void {
    const serialized = (try encoding.Element.one(try leaf.extension(SCT_OID), 4)).data;
    if (serialized.len < 4) return error.InvalidAttestation;
    if (std.mem.readInt(u16, serialized[0..2], .big) != serialized.len - 2 or std.mem.readInt(u16, serialized[2..4], .big) != serialized.len - 4) return error.InvalidAttestation;
    const data = serialized[4..];
    if (data.len < 47 or data[0] != 0) return error.InvalidAttestation;
    const milliseconds = std.mem.readInt(u64, data[33..41], .big);
    const time = milliseconds / 1000;
    if (time > now or time < leaf.before or time > leaf.after) return error.InvalidAttestation;
    const key = try logKey(a, logs, data[1..33], time);
    const extension_len = std.mem.readInt(u16, data[41..43], .big);
    if (extension_len > data.len - 47) return error.InvalidAttestation;
    const sig_offset = 43 + @as(usize, extension_len);
    if (data[sig_offset] != 4 or data[sig_offset + 1] != 3) return error.InvalidAttestation; // SHA256/ECDSA
    if (std.mem.readInt(u16, data[sig_offset + 2 ..][0..2], .big) != data.len - sig_offset - 4) return error.InvalidAttestation;
    // RFC 6962 precertificate: remove SCT extension, preserving all other signed fields.
    var extensions: std.Io.Writer.Allocating = .init(a);
    var rest = leaf.extensions.data;
    while (rest.len > 0) {
        const ext = try certs.Extension.take(&rest);
        if (!std.mem.eql(u8, ext.oid, SCT_OID)) try extensions.writer.writeAll(ext.raw);
    }
    const wrapper = try encoding.wrap(a, 0xa3, try encoding.wrap(a, 0x30, extensions.written()));
    const precert = try encoding.wrap(a, 0x30, try std.mem.concat(a, u8, &.{ leaf.tbs.data[0 .. leaf.tbs.data.len - leaf.extensions_wrapper.raw.len], wrapper }));
    var len: [3]u8 = undefined;
    std.mem.writeInt(u24, &len, @intCast(precert.len), .big);
    var issuer_key_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(issuer.spki, &issuer_key_hash, .{});
    const signed = try std.mem.concat(a, u8, &.{ &.{ 0, 0 }, data[33..41], &.{ 0, 1 }, &issuer_key_hash, &len, precert, data[41..sig_offset] });
    try key.verify(data[sig_offset + 4 ..], signed);
}
