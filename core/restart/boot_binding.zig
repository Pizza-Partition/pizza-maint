const std = @import("std");
const storage = @import("storage");
const uefi = @import("uefi.zig");
pub const ENCODED_SIZE = @import("proto").firmware_pin.ENCODED_SIZE;
pub const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024 + 3 * storage.program.MAX_ENCODED_BYTES + 24;
pub const Binding = @import("proto").firmware_pin.FirmwarePin(MAX_PAYLOAD_BYTES);
pub fn finish(binding: Binding, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, lease: uefi.Lease, session: storage.recovery_session.RecoverySession) !void {
    if (!std.mem.eql(u8, &binding.session, &session.bundle.session) or !std.mem.eql(u8, &binding.disk_identity, &session.disk.target.identity)) return error.SessionIdentityMismatch;
    // Missing binding is only an idempotent finish after restored boot.
    if (try vars.get(a, io, .pizza_session)) |_| try binding.require(a, io, vars);
    try @import("maintenance.zig").restoreBoot(a, io, session, lease, vars);
    if (try vars.get(a, io, .pizza_session)) |_| {
        try binding.require(a, io, vars);
        try vars.set(a, io, .pizza_session, null);
    }
}
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
