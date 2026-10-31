//! Authenticated updater for Sigstore's top-level trusted_root.json TUF target.
//! Supports TUF 1.0, ECDSA P-256 roles and SHA-256/SHA-512 hashes. Delegated
//! targets and other algorithms are not accepted for this fixed target.
const std = @import("std");
const utils = @import("utils");
const Value = std.json.Value;
pub const METADATA_LIMIT = 1024 * 1024;
pub const TARGET_NAME = "trusted_root.json";
const ROTATION_LIMIT = 128;

/// Persisted authenticated metadata, including the chain from the shipped root.
/// Transport and storage are injected; verification never trusts target-supplied keys.
pub const State = struct {
    roots: []const []const u8 = &.{},
    timestamp: ?[]const u8 = null,
    snapshot: ?[]const u8 = null,
    targets: ?[]const u8 = null,
    target: ?[]const u8 = null,
};

const Metadata = struct {
    envelope: Value,
    signed: Value,
    version: u64,

    fn parse(a: std.mem.Allocator, bytes: []const u8, kind: []const u8) !Metadata {
        if (bytes.len > METADATA_LIMIT) return error.TufMetadataTooLarge;
        const envelope = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .max_value_len = METADATA_LIMIT });
        const signed = try field(envelope, "signed");
        if (!std.mem.eql(u8, try string(try field(signed, "_type")), kind)) return error.InvalidTufMetadata;
        const spec = try string(try field(signed, "spec_version"));
        if (!std.mem.eql(u8, spec, "1.0")) {
            if (!std.mem.startsWith(u8, spec, "1.0.") or spec.len == 4) return error.UnsupportedTufVersion;
            _ = std.fmt.parseInt(u32, spec[4..], 10) catch return error.UnsupportedTufVersion;
            for (spec[4..]) |b| if (!std.ascii.isDigit(b)) return error.UnsupportedTufVersion;
        }
        const version = try unsigned(try field(signed, "version"));
        if (version == 0) return error.InvalidTufMetadata;
        return .{ .envelope = envelope, .signed = signed, .version = version };
    }

    fn fresh(self: Metadata, now: u64) !void {
        const expires = try string(try field(self.signed, "expires"));
        // The supported repository emits whole-second UTC RFC3339 times.
        if (expires.len != 20 or try utils.time.timestamp(expires) <= now) return error.ExpiredTufMetadata;
    }
};

fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidTufMetadata;
    return value.object.get(name) orelse error.InvalidTufMetadata;
}

fn string(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidTufMetadata;
    return value.string;
}

fn unsigned(value: Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidTufMetadata;
    return @intCast(value.integer);
}

fn canonicalString(writer: *std.Io.Writer, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidTufMetadata;
    try writer.writeByte('"');
    // TUF uses OLPC canonical JSON, not RFC 8785. Only quotes and backslashes
    // are escaped, including in PEM strings containing literal newline bytes.
    for (value) |b| {
        if (b == '"' or b == '\\') try writer.writeByte('\\');
        try writer.writeByte(b);
    }
    try writer.writeByte('"');
}

fn canonicalWrite(a: std.mem.Allocator, writer: *std.Io.Writer, value: Value, depth: usize) anyerror!void {
    if (depth > 64) return error.InvalidTufMetadata;
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |v| try writer.writeAll(if (v) "true" else "false"),
        .integer => |v| try writer.print("{d}", .{v}),
        .string => |v| try canonicalString(writer, v),
        .array => |v| {
            try writer.writeByte('[');
            for (v.items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try canonicalWrite(a, writer, item, depth + 1);
            }
            try writer.writeByte(']');
        },
        .object => |v| {
            const keys = try a.dupe([]const u8, v.keys());
            defer a.free(keys);
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.lessThan(u8, lhs, rhs);
                }
            }.less);
            try writer.writeByte('{');
            for (keys, 0..) |key, i| {
                if (i != 0) try writer.writeByte(',');
                try canonicalString(writer, key);
                try writer.writeByte(':');
                try canonicalWrite(a, writer, v.get(key).?, depth + 1);
            }
            try writer.writeByte('}');
        },
        else => return error.InvalidTufMetadata, // No floats or arbitrary number strings.
    }
}

fn canonical(a: std.mem.Allocator, value: Value) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    try canonicalWrite(a, &output.writer, value, 0);
    return output.toOwnedSlice();
}

fn verifyKey(a: std.mem.Allocator, description: Value, encoded_sig: []const u8, message: []const u8) !void {
    if (!std.mem.eql(u8, try string(try field(description, "keytype")), "ecdsa") or
        !std.mem.eql(u8, try string(try field(description, "scheme")), "ecdsa-sha2-nistp256")) return error.UnsupportedTufKey;
    const pem = try string(try field(try field(description, "keyval"), "public"));
    const prefix = "-----BEGIN PUBLIC KEY-----\n";
    const suffix = "-----END PUBLIC KEY-----";
    const trimmed = std.mem.trimEnd(u8, pem, "\r\n");
    if (!std.mem.startsWith(u8, trimmed, prefix) or !std.mem.endsWith(u8, trimmed, suffix)) return error.InvalidTufKey;
    var compact: std.Io.Writer.Allocating = .init(a);
    defer compact.deinit();
    for (trimmed[prefix.len .. trimmed.len - suffix.len]) |b| if (b != '\r' and b != '\n') try compact.writer.writeByte(b);
    const der = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(compact.written()));
    defer a.free(der);
    try std.base64.standard.Decoder.decode(der, compact.written());
    const key = try utils.x509.Key.parse(der);
    if (key.curve != .p256) return error.UnsupportedTufKey;
    if (encoded_sig.len > 144 or encoded_sig.len % 2 != 0) return error.InvalidTufSignature;
    var signature: [72]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&signature, encoded_sig);
    try key.verify(decoded, message);
}

fn verifyRole(a: std.mem.Allocator, root: Metadata, metadata: Metadata, role_name: []const u8) !void {
    const role = try field(try field(root.signed, "roles"), role_name);
    const ids = try field(role, "keyids");
    const signatures = try field(metadata.envelope, "signatures");
    const keys = try field(root.signed, "keys");
    if (ids != .array or signatures != .array or keys != .object) return error.InvalidTufMetadata;
    const threshold = try unsigned(try field(role, "threshold"));
    if (threshold == 0 or threshold > ids.array.items.len) return error.InvalidTufThreshold;
    const message = try canonical(a, metadata.signed);
    defer a.free(message);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var count: u64 = 0;
    for (signatures.array.items) |signature| {
        const id = try string(try field(signature, "keyid"));
        if (seen.contains(id)) continue;
        var allowed = false;
        for (ids.array.items) |candidate| if (std.mem.eql(u8, try string(candidate), id)) {
            allowed = true;
            break;
        };
        if (!allowed) continue;
        const key = try field(keys, id);
        verifyKey(a, key, try string(try field(signature, "sig")), message) catch continue;
        try seen.put(a, id, {});
        count += 1;
    }
    if (count < threshold) return error.InvalidTufSignatureThreshold;
}

fn loadedRoot(a: std.mem.Allocator, initial: []const u8, state: State) !Metadata {
    var root = try Metadata.parse(a, initial, "root");
    try verifyRole(a, root, root, "root");
    if (state.roots.len > ROTATION_LIMIT) return error.TufRotationLimit;
    for (state.roots) |bytes| {
        const next = try Metadata.parse(a, bytes, "root");
        if (next.version != root.version + 1) return error.TufRollback;
        try verifyRole(a, root, next, "root");
        try verifyRole(a, next, next, "root");
        root = next;
    }
    return root;
}

fn sameRole(a: std.mem.Allocator, old: Metadata, new: Metadata, name: []const u8) !bool {
    // A retained key ID may change contents, so compare the authorized key objects too.
    const old_role = try field(try field(old.signed, "roles"), name);
    const new_role = try field(try field(new.signed, "roles"), name);
    const lhs = try canonical(a, old_role);
    defer a.free(lhs);
    const rhs = try canonical(a, new_role);
    defer a.free(rhs);
    if (!std.mem.eql(u8, lhs, rhs)) return false;
    const ids = try field(old_role, "keyids");
    if (ids != .array) return error.InvalidTufMetadata;
    for (ids.array.items) |id| {
        const old_key = try canonical(a, try field(try field(old.signed, "keys"), try string(id)));
        defer a.free(old_key);
        const new_key = try canonical(a, try field(try field(new.signed, "keys"), try string(id)));
        defer a.free(new_key);
        if (!std.mem.eql(u8, old_key, new_key)) return false;
    }
    return true;
}

fn rollback(a: std.mem.Allocator, current: Metadata, previous: ?[]const u8, kind: []const u8) !void {
    if (previous) |bytes| {
        const old = try Metadata.parse(a, bytes, kind);
        if (current.version < old.version) return error.TufRollback;
        if (current.version == old.version) {
            const lhs = try canonical(a, current.signed);
            defer a.free(lhs);
            const rhs = try canonical(a, old.signed);
            defer a.free(rhs);
            if (!std.mem.eql(u8, lhs, rhs)) return error.TufVersionConflict;
        }
    }
}

fn meta(parent: Metadata, name: []const u8) !Value {
    return field(try field(parent.signed, "meta"), name);
}

fn hashes(bytes: []const u8, description: Value, required: bool) !void {
    if (description != .object) return error.InvalidTufMetadata;
    if (description.object.get("length")) |length| {
        if (try unsigned(length) != bytes.len) return error.TufLengthMismatch;
    } else if (required) return error.InvalidTufMetadata;
    const values = description.object.get("hashes") orelse {
        if (required) return error.InvalidTufMetadata;
        return;
    };
    if (values != .object) return error.InvalidTufMetadata;
    var checked = false;
    inline for (.{ .{ "sha256", std.crypto.hash.sha2.Sha256 }, .{ "sha512", std.crypto.hash.sha2.Sha512 } }) |algorithm| {
        if (values.object.get(algorithm[0])) |value| {
            var digest: [algorithm[1].digest_length]u8 = undefined;
            algorithm[1].hash(bytes, &digest, .{});
            if (!std.mem.eql(u8, try string(value), &std.fmt.bytesToHex(digest, .lower))) return error.TufHashMismatch;
            checked = true;
        }
    }
    if (!checked) return error.UnsupportedTufHash;
}

fn referencedVersion(description: Value, metadata: Metadata) !void {
    if (try unsigned(try field(description, "version")) != metadata.version) return error.TufVersionMismatch;
}

fn snapshotRollback(a: std.mem.Allocator, current: Metadata, previous: ?[]const u8) !void {
    if (previous) |bytes| {
        const old = try Metadata.parse(a, bytes, "snapshot");
        const entries = try field(old.signed, "meta");
        if (entries != .object) return error.InvalidTufMetadata;
        for (entries.object.keys(), entries.object.values()) |name, description| {
            const new = try meta(current, name);
            if (try unsigned(try field(new, "version")) < try unsigned(try field(description, "version"))) return error.TufRollback;
        }
    }
}

fn metadataPath(a: std.mem.Allocator, root: Metadata, description: Value, name: []const u8) ![]const u8 {
    const consistent = try field(root.signed, "consistent_snapshot");
    if (consistent != .bool) return error.InvalidTufMetadata;
    if (consistent.bool) return a.print("{d}.{s}", .{ try unsigned(try field(description, "version")), name });
    return name;
}

/// Check the whole cached chain at the current time; offline mode does not bypass expiry.
pub fn offline(a: std.mem.Allocator, initial: []const u8, state: State, now: u64) ![]const u8 {
    const root = try loadedRoot(a, initial, state);
    try root.fresh(now);
    const timestamp = try Metadata.parse(a, state.timestamp orelse return error.MissingTufCache, "timestamp");
    try verifyRole(a, root, timestamp, "timestamp");
    try timestamp.fresh(now);
    const snapshot_bytes = state.snapshot orelse return error.MissingTufCache;
    try hashes(snapshot_bytes, try meta(timestamp, "snapshot.json"), false);
    const snapshot = try Metadata.parse(a, snapshot_bytes, "snapshot");
    try verifyRole(a, root, snapshot, "snapshot");
    try referencedVersion(try meta(timestamp, "snapshot.json"), snapshot);
    try snapshot.fresh(now);
    const targets_bytes = state.targets orelse return error.MissingTufCache;
    try hashes(targets_bytes, try meta(snapshot, "targets.json"), false);
    const targets = try Metadata.parse(a, targets_bytes, "targets");
    try verifyRole(a, root, targets, "targets");
    try referencedVersion(try meta(snapshot, "targets.json"), targets);
    try targets.fresh(now);
    const target = state.target orelse return error.MissingTufCache;
    try hashes(target, try field(try field(targets.signed, "targets"), TARGET_NAME), true);
    return target;
}

/// fetcher.fetch(path, limit) returns bytes or null only for HTTP 404.
/// store.save(state) must atomically persist state while holding an exclusive cache lock.
/// The caller fixes now at update start; only intermediate roots may be expired.
pub fn refresh(a: std.mem.Allocator, initial: []const u8, state: *State, now: u64, fetcher: anytype, store: anytype) ![]const u8 {
    var root = try loadedRoot(a, initial, state.*);
    while (true) {
        if (state.roots.len >= ROTATION_LIMIT) return error.TufRotationLimit;
        const bytes = (try fetcher.fetch(try a.print("{d}.root.json", .{root.version + 1}), METADATA_LIMIT)) orelse break;
        const next = try Metadata.parse(a, bytes, "root");
        if (next.version != root.version + 1) return error.TufRollback;
        try verifyRole(a, root, next, "root");
        try verifyRole(a, next, next, "root");
        if (!try sameRole(a, root, next, "timestamp") or !try sameRole(a, root, next, "snapshot")) {
            state.timestamp = null;
            state.snapshot = null;
        }
        state.roots = try std.mem.concat(a, []const u8, &.{ state.roots, &.{bytes} });
        root = next;
        try store.save(state.*); // Persist each authenticated root before proceeding.
    }
    try root.fresh(now);
    const timestamp_bytes = (try fetcher.fetch("timestamp.json", METADATA_LIMIT)) orelse return error.MissingTufMetadata;
    const timestamp = try Metadata.parse(a, timestamp_bytes, "timestamp");
    try verifyRole(a, root, timestamp, "timestamp");
    try rollback(a, timestamp, state.timestamp, "timestamp");
    const snapshot_description = try meta(timestamp, "snapshot.json");
    if (state.snapshot) |old| {
        if (try unsigned(try field(snapshot_description, "version")) < (try Metadata.parse(a, old, "snapshot")).version) return error.TufRollback;
    }
    try timestamp.fresh(now);
    state.timestamp = timestamp_bytes;
    try store.save(state.*); // Keep rollback protection even if a later download fails.
    const snapshot_bytes = (try fetcher.fetch(try metadataPath(a, root, snapshot_description, "snapshot.json"), METADATA_LIMIT)) orelse return error.MissingTufMetadata;
    try hashes(snapshot_bytes, snapshot_description, false);
    const snapshot = try Metadata.parse(a, snapshot_bytes, "snapshot");
    try verifyRole(a, root, snapshot, "snapshot");
    try referencedVersion(snapshot_description, snapshot);
    try rollback(a, snapshot, state.snapshot, "snapshot");
    try snapshotRollback(a, snapshot, state.snapshot);
    try snapshot.fresh(now);
    state.snapshot = snapshot_bytes;
    try store.save(state.*);
    const targets_description = try meta(snapshot, "targets.json");
    const targets_bytes = (try fetcher.fetch(try metadataPath(a, root, targets_description, "targets.json"), METADATA_LIMIT)) orelse return error.MissingTufMetadata;
    try hashes(targets_bytes, targets_description, false);
    const targets = try Metadata.parse(a, targets_bytes, "targets");
    try verifyRole(a, root, targets, "targets");
    try referencedVersion(targets_description, targets);
    try rollback(a, targets, state.targets, "targets");
    try targets.fresh(now);
    state.targets = targets_bytes;
    try store.save(state.*);
    const description = try field(try field(targets.signed, "targets"), TARGET_NAME);
    const length = try unsigned(try field(description, "length"));
    if (length > METADATA_LIMIT) return error.TufTargetTooLarge;
    const digest = try string(try field(try field(description, "hashes"), "sha256"));
    if (digest.len != 64) return error.InvalidTufMetadata;
    for (digest) |b| if (!std.ascii.isDigit(b) and (b < 'a' or b > 'f')) return error.InvalidTufMetadata;
    const consistent = try field(root.signed, "consistent_snapshot");
    if (consistent != .bool) return error.InvalidTufMetadata;
    const path = if (consistent.bool) try a.print("targets/{s}.{s}", .{ digest, TARGET_NAME }) else "targets/" ++ TARGET_NAME;
    const target = (try fetcher.fetch(path, @intCast(length))) orelse return error.MissingTufTarget;
    try hashes(target, description, true);
    state.target = target;
    try store.save(state.*);
    return target;
}

const TestStore = struct {
    writes: usize = 0,
    saved: State = .{},

    pub fn save(self: *TestStore, state: State) !void {
        self.writes += 1;
        self.saved = state;
    }
};

const TestRepository = struct {
    a: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    fail_path: ?[]const u8 = null,
    now: u64 = 1792540800,

    fn init(a: std.mem.Allocator) !TestRepository {
        var self = TestRepository{ .a = a };
        for ([_][]const u8{ "10.root.json", "11.root.json", "12.root.json", "13.root.json", "14.root.json", "15.root.json", "16.root.json", "timestamp.json", "166.snapshot.json", "14.targets.json" }) |name| {
            try self.files.put(a, name, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ "test/fixtures/sigstore/tuf", name }), a, .limited(METADATA_LIMIT)));
        }
        const target = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fixtures/sigstore/trusted_root.json", a, .limited(METADATA_LIMIT));
        try self.files.put(a, "targets/6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66.trusted_root.json", target);
        return self;
    }

    pub fn fetch(self: *TestRepository, path: []const u8, limit: usize) !?[]const u8 {
        if (self.fail_path) |name| if (std.mem.eql(u8, name, path)) return error.TestNetworkFailure;
        const bytes = self.files.get(path) orelse return null;
        if (bytes.len > limit) return error.TufDownloadTooLarge;
        return bytes;
    }

    fn initial(self: TestRepository) []const u8 {
        return self.files.get("10.root.json").?;
    }
};

test "TUF authenticates the public Sigstore target through six root rotations and works offline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repository = try TestRepository.init(a);
    var store: TestStore = .{};
    var state: State = .{};
    const result = try refresh(a, repository.initial(), &state, repository.now, &repository, &store);
    try std.testing.expectEqual(@as(usize, 6), state.roots.len);
    try std.testing.expectEqualStrings(result, try offline(a, repository.initial(), state, repository.now));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result, &digest, .{});
    try std.testing.expectEqualStrings("6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66", &std.fmt.bytesToHex(digest, .lower));
    _ = try refresh(a, repository.initial(), &state, repository.now, &repository, &store);
    try std.testing.expectEqual(@as(usize, 6), state.roots.len);
    try std.testing.expectError(error.ExpiredTufMetadata, offline(a, repository.initial(), state, try utils.time.timestamp("2026-10-28T00:00:00Z")));
    try std.testing.expectError(error.MissingTufCache, offline(a, repository.files.get("16.root.json").?, .{}, repository.now));
}

fn testChange(a: std.mem.Allocator, bytes: []const u8, path: []const []const u8, value: Value) ![]const u8 {
    var document = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
    var current = &document;
    for (path[0 .. path.len - 1]) |key| current = current.object.getPtr(key) orelse return error.MissingTestField;
    try current.object.put(a, path[path.len - 1], value);
    return std.json.Stringify.valueAlloc(a, document, .{});
}

test "TUF rejects metadata tampering, target substitution, missing metadata and network failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "11.root.json", "timestamp.json", "166.snapshot.json", "14.targets.json" }) |name| {
        var repository = try TestRepository.init(a);
        try repository.files.put(a, name, try testChange(a, repository.files.get(name).?, &.{ "signed", "expires" }, .{ .string = "2099-01-01T00:00:00Z" }));
        var state: State = .{};
        var store: TestStore = .{};
        try std.testing.expectError(error.InvalidTufSignatureThreshold, refresh(a, repository.initial(), &state, repository.now, &repository, &store));
    }
    var repository = try TestRepository.init(a);
    const target_path = "targets/6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66.trusted_root.json";
    const forged = try a.dupe(u8, repository.files.get(target_path).?);
    forged[forged.len / 2] ^= 1;
    try repository.files.put(a, target_path, forged);
    var state: State = .{};
    var store: TestStore = .{};
    try std.testing.expectError(error.TufHashMismatch, refresh(a, repository.initial(), &state, repository.now, &repository, &store));
    try std.testing.expect(state.target == null);
    repository.fail_path = "timestamp.json";
    try std.testing.expectError(error.TestNetworkFailure, refresh(a, repository.initial(), &state, repository.now, &repository, &store));
    repository.fail_path = null;
    _ = repository.files.remove("166.snapshot.json");
    try std.testing.expectError(error.MissingTufMetadata, refresh(a, repository.initial(), &state, repository.now, &repository, &store));
}

const TestSigner = struct {
    id: []const u8,
    pair: std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair,

    fn init(id: []const u8, seed: u8) !TestSigner {
        return .{ .id = id, .pair = try std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generateDeterministic(@splat(seed)) };
    }

    fn description(self: TestSigner, a: std.mem.Allocator) !Value {
        const point = self.pair.public_key.toUncompressedSec1();
        const der = try std.mem.concat(a, u8, &.{ "\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00", &point });
        const encoded = std.base64.standard.Encoder.encode(try a.alloc(u8, std.base64.standard.Encoder.calcSize(der.len)), der);
        return testValue(a, .{ .keytype = "ecdsa", .scheme = "ecdsa-sha2-nistp256", .keyval = .{ .public = try a.print("-----BEGIN PUBLIC KEY-----\n{s}\n-----END PUBLIC KEY-----\n", .{encoded}) } });
    }
};

fn testValue(a: std.mem.Allocator, value: anytype) !Value {
    return std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{});
}

fn testSigned(a: std.mem.Allocator, value: Value, signers: []const TestSigner) ![]const u8 {
    const message = try canonical(a, value);
    const signatures = try a.alloc(struct { keyid: []const u8, sig: []const u8 }, signers.len);
    for (signers, signatures) |signer, *result| {
        const signature = try signer.pair.sign(message, null);
        var der: [std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature.der_encoded_length_max]u8 = undefined;
        const encoded = signature.toDer(&der);
        const hex = try a.alloc(u8, encoded.len * 2);
        const alphabet = "0123456789abcdef";
        for (encoded, 0..) |b, i| {
            hex[2 * i] = alphabet[b >> 4];
            hex[2 * i + 1] = alphabet[b & 15];
        }
        result.* = .{ .keyid = signer.id, .sig = hex };
    }
    return std.json.Stringify.valueAlloc(a, .{ .signed = value, .signatures = signatures }, .{});
}

fn testRoot(a: std.mem.Allocator, version: u64, keys: []const TestSigner, threshold: usize, signers: []const TestSigner) ![]const u8 {
    var key_map: std.json.ObjectMap = .empty;
    const ids = try a.alloc([]const u8, keys.len);
    for (keys, ids) |key, *id| {
        id.* = key.id;
        try key_map.put(a, key.id, try key.description(a));
    }
    const role = .{ .keyids = ids, .threshold = threshold };
    return testSigned(a, try testValue(a, .{
        ._type = "root",
        .spec_version = "1.0",
        .version = version,
        .expires = "2099-01-01T00:00:00Z",
        .consistent_snapshot = true,
        .keys = Value{ .object = key_map },
        .roles = .{ .root = role, .timestamp = role, .snapshot = role, .targets = role },
    }), signers);
}

test "TUF root rotation requires distinct old and new threshold signatures and sequential versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old_a = try TestSigner.init("old-a", 1);
    const old_b = try TestSigner.init("old-b", 2);
    const new = try TestSigner.init("new", 3);
    const initial = try testRoot(a, 1, &.{ old_a, old_b }, 2, &.{ old_a, old_b });
    const valid = try testRoot(a, 2, &.{new}, 1, &.{ old_a, old_b, new });
    _ = try loadedRoot(a, initial, .{ .roots = &.{valid} });
    const duplicate = try testRoot(a, 2, &.{new}, 1, &.{ old_a, old_a, new });
    try std.testing.expectError(error.InvalidTufSignatureThreshold, loadedRoot(a, initial, .{ .roots = &.{duplicate} }));
    const no_new = try testRoot(a, 2, &.{new}, 1, &.{ old_a, old_b });
    try std.testing.expectError(error.InvalidTufSignatureThreshold, loadedRoot(a, initial, .{ .roots = &.{no_new} }));
    const no_old = try testRoot(a, 2, &.{new}, 1, &.{new});
    try std.testing.expectError(error.InvalidTufSignatureThreshold, loadedRoot(a, initial, .{ .roots = &.{no_old} }));
    const skipped = try testRoot(a, 3, &.{new}, 1, &.{ old_a, old_b, new });
    try std.testing.expectError(error.TufRollback, loadedRoot(a, initial, .{ .roots = &.{skipped} }));
}

test "TUF rejects authenticated rollback, inconsistent parent versions and removed snapshot entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signer = try TestSigner.init("test", 4);
    const root = try Metadata.parse(a, try testRoot(a, 1, &.{signer}, 1, &.{signer}), "root");
    const old_bytes = try testSigned(a, try testValue(a, .{ ._type = "timestamp", .spec_version = "1.0", .version = 4, .expires = "2099-01-01T00:00:00Z" }), &.{signer});
    const new_bytes = try testSigned(a, try testValue(a, .{ ._type = "timestamp", .spec_version = "1.0", .version = 3, .expires = "2099-01-01T00:00:00Z" }), &.{signer});
    const metadata = try Metadata.parse(a, new_bytes, "timestamp");
    try verifyRole(a, root, metadata, "timestamp");
    try std.testing.expectError(error.TufRollback, rollback(a, metadata, old_bytes, "timestamp"));
    try std.testing.expectError(error.TufVersionMismatch, referencedVersion(try testValue(a, .{ .version = 4 }), metadata));
    const changed = try testChange(a, old_bytes, &.{ "signed", "expires" }, .{ .string = "2098-01-01T00:00:00Z" });
    try std.testing.expectError(error.TufVersionConflict, rollback(a, try Metadata.parse(a, changed, "timestamp"), old_bytes, "timestamp"));
    const previous = try testSigned(a, try testValue(a, .{ ._type = "snapshot", .spec_version = "1.0", .version = 1, .meta = .{ .@"targets.json" = .{ .version = 4 } } }), &.{signer});
    const missing = try testSigned(a, try testValue(a, .{ ._type = "snapshot", .spec_version = "1.0", .version = 2, .meta = .{} }), &.{signer});
    try std.testing.expectError(error.InvalidTufMetadata, snapshotRollback(a, try Metadata.parse(a, missing, "snapshot"), previous));
    try std.testing.expectError(error.TufLengthMismatch, hashes("abc", try testValue(a, .{ .length = 4 }), true));
}

test "TUF OLPC canonicalization sorts recursively and preserves PEM newline bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(Value, a, "{\"z\":\"a\\nb\\\\\\\"\",\"a\":[1,true,null]}", .{});
    try std.testing.expectEqualStrings("{\"a\":[1,true,null],\"z\":\"a\nb\\\\\\\"\"}", try canonical(a, value));
    try std.testing.expectError(error.InvalidTufMetadata, canonical(a, .{ .float = 1.5 }));
}
