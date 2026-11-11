//! Same-disk recovery admission. The block driver enforces the resulting allowlist.
const std = @import("std");
const model = @import("model.zig");
const block_device = @import("block_device.zig");
fn rangeWithin(r: model.Range, allowed: []const model.Range) bool {
    const end = r.end() catch return false;
    if (r.length == 0) return false;
    for (allowed) |other| if (other.offset <= r.offset and (other.end() catch continue) >= end) return true;
    return false;
}
pub fn validateSessionAnchor(a: std.mem.Allocator, target: model.Target, bundle: @import("recovery_session.zig").Bundle, proof: @import("esp_anchor.zig").Proof) !void {
    try bundle.validate(a, target);
    if (!std.mem.eql(u8, &target.identity, &proof.disk_identity)) return error.RecoveryBackingChanged;
    if (!rangeWithin(proof.esp, bundle.protected)) return error.EspNotProtected;
    if (!rangeWithin(bundle.control, proof.extents)) return error.SessionControlOutsideAnchor;
    for ([_]@import("recovery_store.zig").CapsuleDescriptor{ bundle.bootstrap_store, bundle.cleanup_store }) |d| {
        for (d.extents) |r| if (!rangeWithin(r, proof.extents)) return error.RecoveryCapsuleOutsideAnchor;
    }
    for (bundle.apply_store.extents) |r| if (r.overlaps(proof.esp)) return error.WorkStoreOverlapsEsp;
}
pub fn admitSession(self: *block_device.BlockDevice, a: std.mem.Allocator, io: std.Io, bundle: @import("recovery_session.zig").Bundle, path: []const @import("esp_anchor.zig").ShortName, proof: @import("esp_anchor.zig").Proof, initial: bool) !void {
    if (self.mode != .write or self.evidence.partition or self.recovery_directory != null or self.session_digest != null) return error.InvalidSessionAdmission;
    try block_device.requireUnused(a, io, self.evidence);
    if (bundle.bootstrap_store.block_size < self.evidence.physical) return error.RecoveryBlockTooSmall;
    const reader = self.backend().reader();
    const actual = try @import("esp_anchor.zig").revalidate(a, io, reader, path, bundle.bootstrap_store.block_size, proof, false);
    if (initial) {
        // A torn first session header changes reserved ESP bytes but cannot
        // change any planned target byte. Require the complete initial read
        // guards before allowing preparation to resume; prepare() also
        // refuses any existing capsule header.
        for (bundle.bootstrap.guards) |guard| {
            if (!std.mem.eql(u8, &try reader.digest(io, guard.range), &guard.expected)) return error.PlanningReadChanged;
        }
        const table = try @import("partition_table.zig").BUILTIN.readLayout(a, io, reader);
        if (table.kind != .gpt) return error.GptRequiredForSameDiskRecovery;
        const esp_type = [_]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
        const found = for (table.entries) |e| {
            if (std.meta.eql(e.range, actual.esp) and std.mem.eql(u8, &e.type_id, &esp_type)) break true;
        } else false;
        if (!found) return error.EspPartitionChanged;
    } else {
        // GPT publication itself can have been interrupted. Recovery uses
        // the authenticated initial ESP address plus unchanged FAT chain,
        // and requires a valid durable session header before admission.
        _ = try @import("recovery_session.zig").RecoverySession.open(a, io, self.backend(), bundle);
    }
    try validateSessionAnchor(a, self.target, bundle, actual);
    var writes: std.ArrayList(model.Range) = .empty;
    const allocator = self.arena.allocator();
    try writes.append(allocator, bundle.control);
    for ([_]@import("recovery_store.zig").CapsuleDescriptor{ bundle.bootstrap_store, bundle.apply_store, bundle.cleanup_store }) |d| try writes.appendSlice(allocator, d.extents);
    for ([_]@import("program.zig").Program{ bundle.bootstrap, bundle.apply, bundle.cleanup }) |p| {
        for (p.steps, 0..) |_, i| if (p.targetRange(i)) |r| try writes.append(allocator, r);
    }
    self.session_writes = try writes.toOwnedSlice(allocator);
    self.preparation_digest = null;
    self.session_digest = bundle.digest();
    self.session_esp = actual.esp;
}
pub fn admitPreparationFile(self: *block_device.BlockDevice, a: std.mem.Allocator, io: std.Io, request: model.Digest, path: []const @import("esp_anchor.zig").ShortName, proof: @import("esp_anchor.zig").Proof, block: u32) !void {
    if (self.mode != .write or self.evidence.partition or self.session_digest != null or self.preparation_digest != null or self.recovery_directory != null or block < self.evidence.physical or !std.mem.eql(u8, &proof.disk_identity, &self.target.identity)) return error.InvalidSessionAdmission;
    try block_device.requireUnused(a, io, self.evidence);
    const actual = try @import("esp_anchor.zig").revalidate(a, io, self.backend().reader(), path, block, proof, false);
    const table = try @import("partition_table.zig").BUILTIN.readLayout(a, io, self.backend().reader());
    const esp_type = [_]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
    const found = for (table.entries) |entry| {
        if (std.meta.eql(entry.range, actual.esp) and std.mem.eql(u8, &entry.type_id, &esp_type)) break true;
    } else false;
    if (table.kind != .gpt or !found) return error.EspPartitionChanged;
    self.session_writes = try self.arena.allocator().dupe(model.Range, actual.extents);
    self.preparation_digest = request;
}
pub fn admitEspFile(self: *block_device.BlockDevice, a: std.mem.Allocator, io: std.Io, session: model.Digest, path: []const @import("esp_anchor.zig").ShortName, proof: @import("esp_anchor.zig").Proof, block: u32) !void {
    const current = self.session_digest orelse return error.InvalidSessionAdmission;
    if (self.mode != .write or !std.mem.eql(u8, &session, &current) or
        !std.mem.eql(u8, &proof.disk_identity, &self.target.identity) or
        !std.meta.eql(self.session_esp orelse return error.InvalidSessionAdmission, proof.esp) or block < self.evidence.physical) return error.InvalidSessionAdmission;
    try block_device.requireUnused(a, io, self.evidence);
    const actual = try @import("esp_anchor.zig").revalidate(a, io, self.backend().reader(), path, block, proof, false);
    for (actual.extents) |r| {
        if (!rangeWithin(r, &.{proof.esp})) return error.RecoveryAnchorOutsideEsp;
        for (self.session_writes) |other| if (r.overlaps(other)) return error.EspFileOverlapsSession;
    }
    self.session_writes = try std.mem.concat(self.arena.allocator(), model.Range, &.{ self.session_writes, actual.extents });
}
