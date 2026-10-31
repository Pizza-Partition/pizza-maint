//! Offline Btrfs: native SINGLE/DUP mapping engine, common durable undo plans.
const std = @import("std");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
pub const semantic = @import("semantic.zig");
pub const format = @import("format.zig");
pub const scan = @import("scan.zig");
pub const mutate = @import("mutate.zig");
pub const OPERATIONS = init: {
    var caps: [std.enums.values(model.Kind).len]model.Capability = undefined;
    for (std.enums.values(model.Kind), &caps) |kind, *cap| cap.* = .{ .operation = kind, .support = .validated, .reason = .available, .scope = if (kind == .check or kind == .repair) .allocation_metadata else .filesystem };
    break :init caps;
};
pub fn probe(_: *const anyopaque, io: std.Io, reader: device.Reader) !bool {
    if (reader.target.capacity < format.MIRRORS[0] + 4096) return false;
    var b: [4096]u8 = undefined;
    try reader.readInto(io, format.MIRRORS[0], &b);
    return format.recognizable(&b);
}
pub fn inspect(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Snapshot {
    const g = try format.load(io, reader);
    const caps = try a.dupe(model.Capability, &OPERATIONS);
    g.supported() catch |err| {
        for (caps) |*cap| if (cap.operation != .query) {
            cap.support = .unavailable;
            cap.reason = if (err == error.BtrfsRecoveryRequired) .recovery_unvalidated else .feature_unsupported;
        };
    };
    return .{ .filesystem = .btrfs, .target = reader.target, .generation = g.value("generation"), .block_size = @intCast(g.sector()), .filesystem_bytes = g.bytes(), .clean = g.clean(), .capabilities = caps, .features = try a.dupe([]const u8, &.{ "Btrfs", "offline;single-device;SINGLE/DUP", "allocation_metadata;mirror-repair" }) };
}

pub fn check(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Check {
    _ = scan.load(a, io, reader, true) catch |err| {
        if (!std.mem.startsWith(u8, @errorName(err), "Btrfs") or err == error.BtrfsResourceLimit) return err;
        return .{ .consistent = false, .detail = @errorName(err), .scope = .allocation_metadata };
    };
    return .{ .consistent = true, .detail = "Btrfs metadata checksums, parent generations, chunk/device mappings, block-group allocation and super mirrors checked", .scope = .allocation_metadata };
}
