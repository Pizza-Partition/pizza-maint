//! Firmware pin codec and variable operations. No storage or OS dependencies.
const std = @import("std");
pub const ENCODED_SIZE = 144;
pub fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
pub fn FirmwarePin(comptime max_payload_bytes: u64) type {
    return struct {
        const Binding = @This();
        session: [32]u8,
        payload_digest: [32]u8,
        payload_bytes: u64,
        disk_identity: [32]u8,
        image_digest: [32]u8,

        pub fn init(session: [32]u8, disk_identity: [32]u8, image_digest: [32]u8, payload: []const u8) !Binding {
            const result: Binding = .{ .session = session, .disk_identity = disk_identity, .image_digest = image_digest, .payload_digest = digest(payload), .payload_bytes = payload.len };
            try result.validate();
            return result;
        }
        fn validate(self: Binding) !void {
            if (self.payload_bytes == 0 or self.payload_bytes > max_payload_bytes or std.mem.allEqual(u8, &self.session, 0) or std.mem.allEqual(u8, &self.disk_identity, 0) or std.mem.allEqual(u8, &self.image_digest, 0)) return error.InvalidBootBinding;
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
        pub fn read(a: std.mem.Allocator, io: std.Io, vars: anytype) !Binding {
            return decode(try vars.get(a, io, .pizza_session) orelse return error.MissingBootBinding);
        }
        pub fn check(self: Binding, payload: []const u8, trusted_image_digest: [32]u8) !void {
            try self.validate();
            if (payload.len != self.payload_bytes or !std.mem.eql(u8, &self.payload_digest, &digest(payload))) return error.SessionManifestChanged;
            if (!std.mem.eql(u8, &self.image_digest, &trusted_image_digest)) return error.MaintenanceImageChanged;
        }
        /// Caller has already synced/read back all manifest bytes, boot image and
        /// the saved lease. Never replaces an outstanding (even malformed) binding.
        pub fn install(self: Binding, a: std.mem.Allocator, io: std.Io, vars: anytype) !void {
            const bytes = try self.encode();
            if (try vars.get(a, io, .pizza_session)) |existing| {
                if (!std.mem.eql(u8, existing, &bytes)) return error.AnotherMaintenanceSessionExists;
            } else try vars.set(a, io, .pizza_session, &bytes);
        }
        pub fn require(self: Binding, a: std.mem.Allocator, io: std.Io, vars: anytype) !void {
            const bytes = try self.encode();
            const existing = try vars.get(a, io, .pizza_session) orelse return error.MissingBootBinding;
            if (!std.mem.eql(u8, existing, &bytes)) return error.BootBindingChanged;
        }
        pub fn arm(self: Binding, a: std.mem.Allocator, io: std.Io, vars: anytype, lease: anytype) !void {
            try self.require(a, io, vars);
            try lease.arm(a, io, vars);
        }
    };
}
