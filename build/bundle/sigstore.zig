//! Native, offline verifier for pizza-bundle's Sigstore v0.3 / DSSE / Rekor v1 profile.
//! Trusted verification material is supplied by the caller, independently of the artifact.
const std = @import("std");
const encoding = @import("utils").asn1;
const schema = @import("schema.zig");
const certs = @import("utils").x509;
const transparency = @import("transparency.zig");
pub const Policy = struct { repository: []const u8, repository_id: []const u8, workflow: []const u8, tag: []const u8, commit: []const u8 };
const fulcio = @import("fulcio.zig");
pub const TrustRoot = schema.TrustRoot;

pub fn verify(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    root: TrustRoot,
    policy: Policy,
    assets: []const [2][]const u8,
    now: u64,
) !void {
    // GitHub distributes JSONL. Require exactly one attestation for this fixed release profile.
    const bundle = try std.json.parseFromSliceLeaky(
        schema.Bundle,
        allocator,
        bytes,
        .{
            .ignore_unknown_fields = true,
            .max_value_len = 1024 * 1024,
        },
    );
    if (!std.mem.eql(u8, bundle.mediaType, "application/vnd.dev.sigstore.bundle.v0.3+json") and
        !std.mem.eql(u8, bundle.mediaType, "application/vnd.dev.sigstore.bundle+json;version=0.3"))
        return error.InvalidAttestation;

    const material = bundle.verificationMaterial;
    const der = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(material.certificate.rawBytes));
    try std.base64.standard.Decoder.decode(der, material.certificate.rawBytes);
    const leaf = try certs.Certificate.parse(der);

    try fulcio.leafUsage(leaf, allocator);

    const envelope = bundle.dsseEnvelope;
    const kind = envelope.payloadType;
    if (!std.mem.eql(u8, kind, "application/vnd.in-toto+json")) return error.InvalidAttestation;
    const payload = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(envelope.payload));
    try std.base64.standard.Decoder.decode(payload, envelope.payload);
    if (envelope.signatures.len != 1) return error.InvalidAttestation;
    const signature = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(envelope.signatures[0].sig));
    try std.base64.standard.Decoder.decode(signature, envelope.signatures[0].sig);
    const key = try certs.Key.parse(leaf.spki);
    if (key.curve != .p256) return error.InvalidAttestation;

    try key.verify(
        signature,
        try allocator.print("DSSEv1 {d} {s} {d} {s}", .{ kind.len, kind, payload.len, payload }),
    );
    if (material.tlogEntries.len != 1) return error.InvalidAttestation;
    const time = try transparency.rekor(allocator, root.tlogs, material.tlogEntries[0], payload, signature, der, now);
    const issuer = try verifyChain(allocator, root, leaf, time);
    try transparency.sct(allocator, root.ctlogs, leaf, issuer, now);
    try identity(allocator, leaf, policy);
    const payload_statement = try std.json.parseFromSliceLeaky(schema.Statement, allocator, payload, .{ .ignore_unknown_fields = true, .max_value_len = 1024 * 1024 });
    try verifyStatement(allocator, payload_statement, policy, assets);
}

fn verifyChain(a: std.mem.Allocator, root: schema.TrustRoot, leaf: certs.Certificate, time: u64) !certs.Certificate {
    for (root.certificateAuthorities) |authority| {
        const certificates = authority.certChain.certificates;
        if (certificates.len != 2) continue; // Current pinned public Fulcio issuer + root.
        const issuer_der = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(certificates[0].rawBytes));
        try std.base64.standard.Decoder.decode(issuer_der, certificates[0].rawBytes);
        const issuer = try certs.Certificate.parse(issuer_der);
        if (!std.mem.eql(u8, leaf.issuer, issuer.subject)) continue;
        try authority.validFor.validate(time);
        const anchor_der = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(certificates[1].rawBytes));
        try std.base64.standard.Decoder.decode(anchor_der, certificates[1].rawBytes);
        const anchor = try certs.Certificate.parse(anchor_der);
        try fulcio.verifyCertificate(anchor, anchor, time);
        try fulcio.verifyCertificate(issuer, anchor, time);
        try fulcio.verifyCertificate(leaf, issuer, time);
        return issuer;
    }
    return error.UntrustedCertificateIssuer;
}

fn identity(a: std.mem.Allocator, leaf: certs.Certificate, policy: Policy) !void {
    const repository = try a.print("https://github.com/{s}", .{policy.repository});
    const ref = try a.print("refs/tags/{s}", .{policy.tag});
    const workflow = try a.print("https://github.com/{s}@{s}", .{ policy.workflow, ref });
    const san = try encoding.Element.one(try leaf.extension("\x55\x1d\x11"), 0x30);
    if (!std.mem.eql(u8, (try encoding.Element.one(san.data, 0x86)).data, workflow)) return error.InvalidAttestation;
    try fulcio.claim(leaf, 8, "https://token.actions.githubusercontent.com");
    try fulcio.claim(leaf, 9, workflow);
    try fulcio.claim(leaf, 10, policy.commit);
    try fulcio.claim(leaf, 11, "github-hosted");
    try fulcio.claim(leaf, 12, repository);
    try fulcio.claim(leaf, 13, policy.commit);
    try fulcio.claim(leaf, 14, ref);
    try fulcio.claim(leaf, 15, policy.repository_id);
    try fulcio.claim(leaf, 18, workflow);
    try fulcio.claim(leaf, 19, policy.commit);
}

fn verifyStatement(a: std.mem.Allocator, value: schema.Statement, policy: Policy, assets: []const [2][]const u8) !void {
    if (!std.mem.eql(u8, value._type, "https://in-toto.io/Statement/v1") or !std.mem.eql(u8, value.predicateType, "https://slsa.dev/provenance/v1")) return error.InvalidAttestation;
    for (assets) |asset| {
        var count: usize = 0;
        for (value.subject) |subject| if (std.mem.eql(u8, subject.name, asset[0])) {
            if (!std.mem.eql(u8, subject.digest.sha256, asset[1])) return error.InvalidAttestation;
            count += 1;
        };
        if (count != 1) return error.AttestationSubjectMismatch;
    }
    const definition = value.predicate.buildDefinition;
    if (!std.mem.eql(u8, definition.buildType, "https://actions.github.io/buildtypes/workflow/v1")) return error.InvalidAttestation;
    const workflow = definition.externalParameters.workflow;
    if (!std.mem.eql(u8, workflow.repository, try a.print("https://github.com/{s}", .{policy.repository})) or !std.mem.eql(u8, workflow.ref, try a.print("refs/tags/{s}", .{policy.tag}))) return error.InvalidAttestation;
    const slash = std.mem.indexOf(u8, policy.workflow, "/.github/") orelse return error.InvalidAttestation;
    if (!std.mem.eql(u8, workflow.path, policy.workflow[slash + 1 ..])) return error.InvalidAttestation;
    if (!std.mem.eql(u8, value.predicate.runDetails.builder.id, try a.print("https://github.com/{s}@refs/tags/{s}", .{ policy.workflow, policy.tag }))) return error.InvalidAttestation;
}
