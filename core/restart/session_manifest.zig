//! One immutable artifact contains verification policies, allocation proof,
//! saved boot lease and all three programs. Authenticate exact bytes against
//! the firmware pin BEFORE parsing JSON or loading programs. No file paths or
//! executable names from this artifact are followed by the privileged reader.
const std = @import("std");
const storage = @import("storage");
const compiler = @import("maintenance_compiler.zig");
const uefi = @import("uefi.zig");
const boot = @import("boot_binding.zig");
pub const Check = struct { filesystem: storage.model.Filesystem, range: storage.model.Range, intent: storage.semantic.Intent };
pub const Verification = struct {
    layout: ?[]const storage.partition_table.Entry,
    checks: []const Check,
    pub fn save(a: std.mem.Allocator, plan: storage.service.Plan) !Verification {
        const checks = try a.alloc(Check, plan.checks.len);
        for (checks, plan.checks) |*out, check| out.* = .{ .filesystem = check.driver.filesystem, .range = check.range, .intent = check.intent };
        return .{ .layout = plan.layout, .checks = checks };
    }
    pub fn restore(self: Verification, a: std.mem.Allocator, p: storage.program.Program) !storage.service.Plan {
        const checks = try a.alloc(storage.service.Verification, self.checks.len);
        for (checks, self.checks) |*out, check| out.* = .{ .driver = try storage.filesystem.BUILTIN.get(check.filesystem), .range = check.range, .intent = check.intent };
        return .{ .program = p, .layout = self.layout, .checks = checks };
    }
};
pub const Metadata = struct {
    version: u16 = 1,
    request_digest: ?storage.model.Digest = null,
    session: storage.model.Digest,
    approved_plan: storage.model.Digest,
    image: storage.model.Digest,
    control: storage.model.Range,
    bootstrap_store: storage.recovery_store.CapsuleDescriptor,
    apply_store: storage.recovery_store.CapsuleDescriptor,
    cleanup_store: storage.recovery_store.CapsuleDescriptor,
    protected: []const storage.model.Range,
    anchor: storage.esp_anchor.Proof,
    anchor_path: []const storage.esp_anchor.ShortName,
    lease: uefi.Lease,
    receipt_anchor: ?@import("esp_receipt.zig").Anchor = null,
    bootstrap_verification: Verification,
    apply_verification: Verification,
    cleanup_verification: Verification,
};
pub const Sealed = struct { bytes: []const u8, binding: boot.Binding };
// Implementations must sync the entire receipt and its publication metadata.
// Readback is mandatory before any firmware restoration. A sink is bound by
// the platform to an admitted, preallocated ESP extent, never a request path.
pub const ReceiptSink = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, std.Io, []const u8) anyerror!void,
    read: *const fn (*anyopaque, std.mem.Allocator, std.Io) anyerror![]const u8,
};
pub const Loaded = struct {
    metadata: Metadata,
    compiled: compiler.Compiled,
    binding: boot.Binding,

    /// Device acquisition remains the physical backend's responsibility. This
    /// only supplies authenticated provenance to its unchanged admission gate.
    pub fn admit(self: Loaded, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, disk: *storage.block_device.BlockDevice, initial: bool) !void {
        try self.binding.require(a, io, vars);
        try storage.session_admission.admitSession(disk, a, io, self.compiled.bundle, self.metadata.anchor_path, self.metadata.anchor, initial);
        if (self.metadata.receipt_anchor) |receipt_anchor| {
            try @import("esp_receipt.zig").validate(a, disk.target, self.compiled.bundle, self.metadata.anchor, receipt_anchor);
            try storage.session_admission.admitEspFile(disk, a, io, self.compiled.bundle.digest(), receipt_anchor.path, receipt_anchor.proof, self.compiled.bundle.bootstrap_store.block_size);
        }
    }
    pub fn arm(self: Loaded, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables) !void {
        try self.binding.arm(a, io, vars, self.metadata.lease);
    }
    pub fn receipt(self: Loaded, a: std.mem.Allocator, session: storage.recovery_session.RecoverySession) !@import("proto").wire.CompletionReceipt {
        if (!std.mem.eql(u8, &session.bundle.digest(), &self.compiled.bundle.digest()) or
            !std.mem.eql(u8, &session.disk.target.identity, &self.binding.disk_identity)) return error.SessionIdentityMismatch;
        const outcome: @FieldType(@import("proto").wire.CompletionReceipt, "outcome") = switch (session.phase) {
            .completed => .completed,
            .rolled_back => .rolled_back,
            .failed_bootstrap => .setup_failed,
            else => return error.MaintenanceStillOwnsBoot,
        };
        return .{ .version = @import("proto").API_VERSION, .id = try a.dupe(u8, &std.fmt.bytesToHex(self.metadata.session, .lower)), .plan_digest = try a.dupe(u8, &std.fmt.bytesToHex(self.metadata.approved_plan, .lower)), .program_digest = try a.dupe(u8, &std.fmt.bytesToHex(self.compiled.bundle.digest(), .lower)), .disk_identity = try a.dupe(u8, &std.fmt.bytesToHex(self.binding.disk_identity, .lower)), .image_digest = try a.dupe(u8, &std.fmt.bytesToHex(self.metadata.image, .lower)), .outcome = outcome, .message = (try @import("maintenance.zig").project(a, session)).message };
    }
    /// Production sink: the receipt file allocation is authenticated by the
    /// manifest and admitted independently from the recovery capsules.
    pub fn finishOnEsp(self: Loaded, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, session: storage.recovery_session.RecoverySession) !void {
        const anchor = self.metadata.receipt_anchor orelse return error.MissingReceiptAnchor;
        const value = try self.receipt(a, session);
        var sink = try @import("esp_receipt.zig").EspReceipt.open(a, io, session.disk, anchor, self.compiled.bundle.bootstrap_store.block_size, .{ .id = value.id, .plan_digest = value.plan_digest, .program_digest = value.program_digest, .disk_identity = value.disk_identity, .image_digest = value.image_digest });
        try self.finish(a, io, vars, session, sink.sink());
    }
    /// Keep the terminal receipt authenticated in firmware during the return
    /// boot. The host clears this pin only after its protected report readback.
    pub fn finishPinned(self: Loaded, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, session: storage.recovery_session.RecoverySession, request: @import("proto").Handoff.Request, request_bytes: []const u8) !void {
        const value = try self.receipt(a, session);
        const request_digest = self.metadata.request_digest orelse return error.MissingRequestProvenance;
        if (!std.mem.eql(u8, &request_digest, &storage.model.digest(request_bytes)) or !std.mem.eql(u8, request.id, value.id) or !std.mem.eql(u8, request.plan_digest, value.plan_digest) or !std.mem.eql(u8, request.image_digest, value.image_digest) or !std.mem.eql(u8, request.draft.disk_identity, value.disk_identity)) return error.SessionIdentityMismatch;
        try self.binding.require(a, io, vars);
        const anchor = self.metadata.receipt_anchor orelse return error.MissingReceiptAnchor;
        const expected: @import("proto").ReceiptIdentity = .{ .id = value.id, .plan_digest = value.plan_digest, .program_digest = value.program_digest, .disk_identity = value.disk_identity, .image_digest = value.image_digest };
        var sink = try @import("esp_receipt.zig").EspReceipt.open(a, io, session.disk, anchor, self.compiled.bundle.bootstrap_store.block_size, expected);
        const port = sink.sink();
        const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
        try port.publish(port.context, io, bytes);
        if (!std.mem.eql(u8, bytes, try port.read(port.context, a, io))) return error.CompletionReceiptReadbackMismatch;
        const terminal: @import("proto").Handoff.Terminal = .{ .request_digest = request_digest, .esp = request.esp, .receipt_digest = storage.model.digest(bytes), .expected = expected };
        try vars.set(a, io, .pizza_session, try terminal.encode(a));
        try self.metadata.lease.restore(a, io, vars);
    }
    pub fn finish(self: Loaded, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, session: storage.recovery_session.RecoverySession, sink: ReceiptSink) !void {
        const value = try self.receipt(a, session);
        const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
        const pinned = try vars.get(a, io, .pizza_session) != null;
        if (pinned) try self.binding.require(a, io, vars);
        const previous = sink.read(sink.context, a, io) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        if (!std.mem.eql(u8, bytes, previous)) {
            // An interrupted firmware restore can already have restored the
            // original BootOrder. Never rewrite an intact terminal receipt.
            if (!pinned) return error.CompletionReceiptMissingAfterBootRestore;
            try sink.publish(sink.context, io, bytes);
        }
        if (!std.mem.eql(u8, bytes, try sink.read(sink.context, a, io))) return error.CompletionReceiptReadbackMismatch;
        try @import("boot_binding.zig").finish(self.binding, a, io, vars, self.metadata.lease, session);
    }
};
pub fn seal(a: std.mem.Allocator, compiled: compiler.Compiled, anchor: storage.esp_anchor.Proof, path: []const storage.esp_anchor.ShortName, lease: uefi.Lease, image: storage.model.Digest) !Sealed {
    return sealWithReceipt(a, compiled, anchor, path, lease, image, null);
}
pub fn sealWithReceipt(a: std.mem.Allocator, compiled: compiler.Compiled, anchor: storage.esp_anchor.Proof, path: []const storage.esp_anchor.ShortName, lease: uefi.Lease, image: storage.model.Digest, receipt_anchor: ?@import("esp_receipt.zig").Anchor) !Sealed {
    return sealInternal(a, compiled, anchor, path, lease, image, receipt_anchor, null, null);
}
pub fn sealRestart(a: std.mem.Allocator, compiled: compiler.Compiled, anchor: storage.esp_anchor.Proof, path: []const storage.esp_anchor.ShortName, lease: uefi.Lease, image: storage.model.Digest, receipt_anchor: @import("esp_receipt.zig").Anchor, request_digest: storage.model.Digest) !Sealed {
    return sealInternal(a, compiled, anchor, path, lease, image, receipt_anchor, request_digest, @import("proto").Handoff.MANIFEST_BYTES);
}
fn sealInternal(a: std.mem.Allocator, compiled: compiler.Compiled, anchor: storage.esp_anchor.Proof, path: []const storage.esp_anchor.ShortName, lease: uefi.Lease, image: storage.model.Digest, receipt_anchor: ?@import("esp_receipt.zig").Anchor, request_digest: ?storage.model.Digest, reservation: ?usize) !Sealed {
    const bundle = compiled.bundle;
    try storage.session_admission.validateSessionAnchor(a, bundle.bootstrap.target, bundle, anchor);
    const metadata: Metadata = .{ .request_digest = request_digest, .session = bundle.session, .approved_plan = bundle.bootstrap.request_digest, .image = image, .control = bundle.control, .bootstrap_store = bundle.bootstrap_store, .apply_store = bundle.apply_store, .cleanup_store = bundle.cleanup_store, .protected = bundle.protected, .anchor = anchor, .anchor_path = path, .lease = lease, .receipt_anchor = receipt_anchor, .bootstrap_verification = try Verification.save(a, compiled.bootstrap), .apply_verification = try Verification.save(a, compiled.apply), .cleanup_verification = try Verification.save(a, compiled.cleanup) };
    try validate(metadata, compiled);
    const json = try std.json.Stringify.valueAlloc(a, metadata, .{});
    defer a.free(json);
    if (json.len > 4 * 1024 * 1024) return error.SessionManifestTooLarge;
    const programs = [_][]const u8{ bundle.bootstrap.encoded, bundle.apply.encoded, bundle.cleanup.encoded };
    var length: usize = 24 + json.len;
    for (programs) |p| length = try std.math.add(usize, length, p.len);
    if (length > boot.MAX_PAYLOAD_BYTES) return error.SessionManifestTooLarge;
    if (reservation) |reserved| {
        if (length > reserved) return error.SessionManifestTooLarge;
        length = reserved;
    }
    const bytes = try a.alloc(u8, length);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "PZMAN001");
    std.mem.writeInt(u32, bytes[8..12], @intCast(json.len), .little);
    @memcpy(bytes[24..][0..json.len], json);
    var offset: usize = 24 + json.len;
    for (programs, 0..) |p, i| {
        std.mem.writeInt(u32, bytes[12 + i * 4 ..][0..4], @intCast(p.len), .little);
        @memcpy(bytes[offset..][0..p.len], p);
        offset += p.len;
    }
    return .{ .bytes = bytes, .binding = try boot.Binding.init(bundle.session, bundle.bootstrap.target.identity, image, bytes) };
}
pub fn load(a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, bytes: []const u8, trusted_image_digest: storage.model.Digest) !Loaded {
    const binding = try boot.Binding.read(a, io, vars);
    try binding.check(bytes, trusted_image_digest);
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "PZMAN001")) return error.InvalidSessionManifest;
    const json_length = std.mem.readInt(u32, bytes[8..12], .little);
    if (json_length == 0 or json_length > 4 * 1024 * 1024) return error.InvalidSessionManifest;
    var total: u64 = 24 + @as(u64, json_length);
    var lengths: [3]u32 = undefined;
    for (&lengths, 0..) |*length, i| {
        length.* = std.mem.readInt(u32, bytes[12 + i * 4 ..][0..4], .little);
        if (length.* == 0 or length.* > storage.program.MAX_ENCODED_BYTES) return error.InvalidSessionManifest;
        total += length.*;
    }
    if (total > bytes.len or !std.mem.allEqual(u8, bytes[@intCast(total)..], 0)) return error.InvalidSessionManifest;
    const metadata = try std.json.parseFromSliceLeaky(Metadata, a, bytes[24..][0..json_length], .{});
    if (metadata.version != 1) return error.UnsupportedSessionManifest;
    if (!std.mem.eql(u8, &metadata.session, &binding.session) or !std.mem.eql(u8, &metadata.image, &binding.image_digest) or !std.mem.eql(u8, &metadata.anchor.disk_identity, &binding.disk_identity)) return error.SessionIdentityMismatch;
    var programs: [3]storage.program.Program = undefined;
    var offset: usize = 24 + @as(usize, json_length);
    for (&programs, lengths) |*p, length| {
        p.* = try storage.program.decode(a, bytes[offset..][0..length]);
        offset += length;
    }
    const bundle: storage.recovery_session.Bundle = .{ .session = metadata.session, .control = metadata.control, .bootstrap = programs[0], .apply = programs[1], .cleanup = programs[2], .bootstrap_store = metadata.bootstrap_store, .apply_store = metadata.apply_store, .cleanup_store = metadata.cleanup_store, .protected = metadata.protected };
    const compiled: compiler.Compiled = .{ .allocator = a, .bundle = bundle, .bootstrap = try metadata.bootstrap_verification.restore(a, programs[0]), .apply = try metadata.apply_verification.restore(a, programs[1]), .cleanup = try metadata.cleanup_verification.restore(a, programs[2]) };
    try validate(metadata, compiled);
    try storage.session_admission.validateSessionAnchor(a, programs[0].target, bundle, metadata.anchor);
    return .{ .metadata = metadata, .compiled = compiled, .binding = binding };
}
fn validate(metadata: Metadata, compiled: compiler.Compiled) !void {
    if (metadata.receipt_anchor) |receipt_anchor| try @import("esp_receipt.zig").validate(compiled.allocator, compiled.bundle.bootstrap.target, compiled.bundle, metadata.anchor, receipt_anchor);
    if (metadata.anchor_path.len == 0 or metadata.anchor_path.len > 16) return error.InvalidAnchorPath;
    for (metadata.anchor_path) |name| {
        if (name[0] == ' ' or name[0] == '.') return error.InvalidAnchorPath;
        for (name) |ch| if (!(ch >= 'A' and ch <= 'Z') and !std.ascii.isDigit(ch) and ch != ' ' and ch != '_' and ch != '-') return error.InvalidAnchorPath;
    }
    for ([_]storage.program.Program{ compiled.bundle.bootstrap, compiled.bundle.apply, compiled.bundle.cleanup }) |p| {
        if (!std.mem.eql(u8, &p.request_digest, &metadata.approved_plan)) return error.ApprovedPlanMismatch;
    }
    // Resource admission proves disjoint stores; runtime revalidates the full
    // native FAT chain, allocation fingerprint and stable hardware identity.
    if (metadata.lease.original_order.len == 0 or metadata.lease.original_order.len % 2 != 0 or metadata.lease.option.len < 12) return error.InvalidBootLease;
    if (metadata.lease.original_next) |next| if (next.len != 2) return error.InvalidBootLease;
}

test "production ESP completion requires an authenticated receipt allocation" {
    var loaded: Loaded = undefined;
    loaded.metadata.receipt_anchor = null;
    var memory: uefi.MemoryVariables = .{ .a = std.testing.allocator };
    try std.testing.expectError(error.MissingReceiptAnchor, loaded.finishOnEsp(std.testing.allocator, std.testing.io, memory.vars(), undefined));
}
