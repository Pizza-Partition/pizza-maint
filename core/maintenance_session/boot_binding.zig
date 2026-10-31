//! Root-owned firmware pin for an immutable, fully persisted session manifest.
//! This provides integrity relative to firmware state, not authentication against
//! another privileged OS or replacement for Secure Boot image verification.
const std = @import("std");
const s = @import("storage");
const uefi = @import("uefi.zig");
pub const ENCODED_SIZE = 144;
pub const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024 + 3 * s.program.MAX_ENCODED_BYTES + 24;
pub const Binding = struct {
    session: s.model.Digest,
    payload_digest: s.model.Digest,
    payload_bytes: u64,
    disk_identity: s.model.Digest,
    image_digest: s.model.Digest,

    pub fn init(session: s.model.Digest, disk_identity: s.model.Digest, image_digest: s.model.Digest, payload: []const u8) !Binding {
        const result: Binding = .{ .session = session, .disk_identity = disk_identity, .image_digest = image_digest, .payload_digest = s.model.digest(payload), .payload_bytes = payload.len };
        try result.validate();
        return result;
    }
    fn validate(self: Binding) !void {
        if (self.payload_bytes == 0 or self.payload_bytes > MAX_PAYLOAD_BYTES or std.mem.allEqual(u8, &self.session, 0) or std.mem.allEqual(u8, &self.disk_identity, 0) or std.mem.allEqual(u8, &self.image_digest, 0)) return error.InvalidBootBinding;
    }
    pub fn encode(self: Binding) ![ENCODED_SIZE]u8 {
        try self.validate();
        var bytes: [ENCODED_SIZE]u8 = undefined;
        @memcpy(bytes[0..8], "PZBIND01");
        @memcpy(bytes[8..40], &self.session);
        @memcpy(bytes[40..72], &self.payload_digest);
        std.mem.writeInt(u64, bytes[72..80], self.payload_bytes, .little);
        @memcpy(bytes[80..112], &self.disk_identity);
        @memcpy(bytes[112..144], &self.image_digest);
        return bytes;
    }
    pub fn decode(bytes: []const u8) !Binding {
        if (bytes.len != ENCODED_SIZE or !std.mem.eql(u8, bytes[0..8], "PZBIND01")) return error.InvalidBootBinding;
        const result: Binding = .{ .session = bytes[8..40].*, .payload_digest = bytes[40..72].*, .payload_bytes = std.mem.readInt(u64, bytes[72..80], .little), .disk_identity = bytes[80..112].*, .image_digest = bytes[112..144].* };
        try result.validate();
        return result;
    }
    pub fn read(a: std.mem.Allocator, io: std.Io, vars: uefi.Variables) !Binding {
        return decode(try vars.get(a, io, .pizza_session) orelse return error.MissingBootBinding);
    }
    pub fn check(self: Binding, payload: []const u8, trusted_image_digest: s.model.Digest) !void {
        try self.validate();
        if (payload.len != self.payload_bytes or !std.mem.eql(u8, &self.payload_digest, &s.model.digest(payload))) return error.SessionManifestChanged;
        if (!std.mem.eql(u8, &self.image_digest, &trusted_image_digest)) return error.MaintenanceImageChanged;
    }
    /// Caller has already synced/read back all manifest bytes, boot image and
    /// the saved lease. Never replaces an outstanding (even malformed) binding.
    pub fn install(self: Binding, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables) !void {
        const bytes = try self.encode();
        if (try vars.get(a, io, .pizza_session)) |existing| {
            if (!std.mem.eql(u8, existing, &bytes)) return error.AnotherMaintenanceSessionExists;
        } else try vars.set(a, io, .pizza_session, &bytes);
    }
    pub fn require(self: Binding, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables) !void {
        const bytes = try self.encode();
        const existing = try vars.get(a, io, .pizza_session) orelse return error.MissingBootBinding;
        if (!std.mem.eql(u8, existing, &bytes)) return error.BootBindingChanged;
    }
    pub fn arm(self: Binding, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, lease: uefi.Lease) !void {
        try self.require(a, io, vars);
        try lease.arm(a, io, vars);
    }
    /// Clear only after durable terminal status AND boot restoration. The next
    /// call can finish a restore interrupted between any firmware operations.
    pub fn finish(self: Binding, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, lease: uefi.Lease, session: s.maintenance_session.Session) !void {
        if (!std.mem.eql(u8, &self.session, &session.bundle.session) or !std.mem.eql(u8, &self.disk_identity, &session.disk.target.identity)) return error.SessionIdentityMismatch;
        // Missing binding is only an idempotent finish after restored boot.
        if (try vars.get(a, io, .pizza_session)) |_| try self.require(a, io, vars);
        try @import("maintenance.zig").restoreBoot(a, io, session, lease, vars);
        if (try vars.get(a, io, .pizza_session)) |_| {
            try self.require(a, io, vars);
            try vars.set(a, io, .pizza_session, null);
        }
    }
};

test "firmware pin rejects changed bytes, changed image, another session and malformed state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var memory: uefi.MemoryVariables = .{ .a = a };
    const binding = try Binding.init(@splat(1), @splat(2), @splat(3), "manifest");
    try binding.install(a, io, memory.vars());
    try binding.install(a, io, memory.vars());
    try binding.check("manifest", @splat(3));
    try std.testing.expectError(error.SessionManifestChanged, binding.check("manifesT", @splat(3)));
    try std.testing.expectError(error.MaintenanceImageChanged, binding.check("manifest", @splat(4)));
    const other = try Binding.init(@splat(9), @splat(2), @splat(3), "manifest");
    try std.testing.expectError(error.AnotherMaintenanceSessionExists, other.install(a, io, memory.vars()));
    try std.testing.expectError(error.BootBindingChanged, other.require(a, io, memory.vars()));
    memory.binding = "broken";
    try std.testing.expectError(error.InvalidBootBinding, Binding.read(a, io, memory.vars()));
    try std.testing.expectError(error.AnotherMaintenanceSessionExists, binding.install(a, io, memory.vars()));
}

test "binding installation and boot arming recover after each acknowledged firmware write" {
    for (1..5) |cut| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        var memory: uefi.MemoryVariables = .{ .a = a };
        const option = try uefi.loadOption(a, 1, 2048, 100, @splat(3), "\\EFI\\Pizza\\session.efi");
        const lease = try uefi.Lease.capture(a, io, memory.vars(), 0x5049, option);
        const binding = try Binding.init(@splat(1), @splat(2), @splat(3), "manifest");
        try std.testing.expectError(error.MissingBootBinding, binding.arm(a, io, memory.vars(), lease));
        try std.testing.expectEqual(0, memory.writes);
        memory.fail_after = cut;
        binding.install(a, io, memory.vars()) catch |err| if (err != error.SimulatedFirmwareInterruption) return err;
        binding.arm(a, io, memory.vars(), lease) catch |err| if (err != error.SimulatedFirmwareInterruption) return err;
        memory.fail_after = null;
        try binding.install(a, io, memory.vars());
        try binding.arm(a, io, memory.vars(), lease);
        try binding.require(a, io, memory.vars());
        try std.testing.expectEqualSlices(u8, &.{ 0x49, 0x50, 1, 0, 2, 0 }, memory.order.?);
    }
}
