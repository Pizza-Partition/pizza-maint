//! NTFS 3.x, with allocation-scoped checking/repair and common undo execution.
const std = @import("std");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
const check_errors = @import("../check_errors.zig");
pub const semantic = @import("semantic.zig");
pub const format = @import("format.zig");
pub const bridge = @import("io.zig");
pub const c_api = bridge.c_api;
pub const Session = bridge.Session;
comptime {
    _ = bridge;
}
pub const OPERATIONS = model.validatedOperations(.allocation_metadata);
pub fn probe(_: *const anyopaque, io: std.Io, reader: device.Reader) !bool {
    if (reader.target.capacity < 512) return false;
    var b: [512]u8 = undefined;
    try reader.readInto(io, 0, &b);
    return format.recognizable(&b);
}
pub fn inspect(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Snapshot {
    const g = try format.load(io, reader);
    const session = try Session.open(a, io, reader, null);
    defer session.close();
    const caps = try a.dupe(model.Capability, &OPERATIONS);
    var clean = true;
    session.health() catch |err| switch (err) {
        error.NtfsHibernated, error.NtfsJournalRecoveryRequired, error.NtfsRecoveryRequired => {
            clean = false;
        },
        else => return err,
    };
    if (!clean) for (caps) |*cap| if (cap.operation == .copy or cap.operation == .grow or cap.operation == .shrink or cap.operation == .repair) {
        cap.support = .unavailable;
        cap.reason = .recovery_unvalidated;
    };
    return .{ .filesystem = .ntfs, .target = reader.target, .generation = 0, .block_size = g.cluster, .filesystem_bytes = g.bytes, .clean = clean, .capabilities = caps, .features = try a.dupe([]const u8, &.{ "NTFS 3.x", "allocation_metadata", "offline;no-journal-replay" }) };
}

pub fn allocation(a: std.mem.Allocator, io: std.Io, reader: device.Reader) !void {
    try semantic.validate(a, io, reader, false);
}
pub fn checkBackup(io: std.Io, reader: device.Reader, g: format.Geometry) !void {
    var boot: [4096]u8 = undefined;
    var backup: [4096]u8 = undefined;
    try reader.readInto(io, 0, boot[0..g.sector]);
    try reader.readInto(io, g.bytes - g.sector, backup[0..g.sector]);
    if (std.mem.eql(u8, boot[0..g.sector], backup[0..g.sector])) return;
    if (format.parse(backup[0..g.sector], reader.target.capacity)) |other| {
        if (!std.meta.eql(g, other)) return error.NtfsAmbiguousBoot;
    } else |_| {}
    return error.NtfsBackupBoot;
}
pub fn check(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Check {
    allocation(a, io, reader) catch |err| {
        if (!check_errors.contains(check_errors.Ntfs, err)) return err;
        return .{ .consistent = false, .detail = @errorName(err), .scope = .allocation_metadata };
    };
    return .{ .consistent = true, .detail = "NTFS MFT runlists, cluster ownership, allocation bitmap, boot backup and clean journal checked", .scope = .allocation_metadata };
}
