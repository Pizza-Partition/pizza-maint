//! Linux maintenance discovery remains independent of filesystem write ownership.
const std = @import("std");
const wire = @import("proto").wire;

pub const HostInventoryProvider = struct {
    context: ?*anyopaque = null,
    vtable: *const VTable,
    pub const VTable = struct { query: *const fn (?*anyopaque, std.mem.Allocator, std.Io) anyerror!wire.InventorySnapshot };
    pub fn query(self: HostInventoryProvider, a: std.mem.Allocator, io: std.Io) !wire.InventorySnapshot {
        return self.vtable.query(self.context, a, io);
    }
};
pub const SYSTEM: HostInventoryProvider = .{ .vtable = &.{ .query = querySystem } };
fn querySystem(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io) !wire.InventorySnapshot {
    return switch (@import("builtin").os.tag) {
        .linux => @import("linux_inventory.zig").query(a, io),
        else => error.HostPlatformUnsupported,
    };
}
pub const fingerprint = @import("snapshot.zig").fingerprint;
