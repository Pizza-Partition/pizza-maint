//! Native FAT32 records and ownership; pinned FatFs supplies Unicode folding.
const std = @import("std");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
pub const semantic = @import("semantic.zig");
pub const format = @import("format.zig");
pub const scan = @import("scan.zig");
pub const OPERATIONS = init: {
    var caps: [std.enums.values(model.Kind).len]model.Capability = undefined;
    for (std.enums.values(model.Kind), &caps) |kind, *cap| cap.* = .{ .operation = kind, .support = .validated, .reason = .available };
    break :init caps;
};
pub fn probe(_: *const anyopaque, io: std.Io, reader: device.Reader) !bool {
    if (reader.target.capacity < 512) return false;
    var bytes: [512]u8 = undefined;
    try reader.readInto(io, 0, &bytes);
    // A valid FAT12/16 primary must not expose an obsolete FAT32 backup.
    if (format.get16(&bytes, 510) == 0xaa55 and format.get16(&bytes, 17) != 0 and format.get16(&bytes, 22) != 0) return false;
    if (format.recognizable(&bytes)) return true;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    _ = format.loadBoot(arena.allocator(), io, reader) catch |err| switch (err) {
        error.FatInvalidBoot => return false,
        else => return err,
    };
    return true;
}
pub fn inspect(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Snapshot {
    const boot = try format.loadBoot(a, io, reader);
    const g = boot.geometry;
    const caps = try a.dupe(model.Capability, &OPERATIONS);
    g.budget() catch {
        for (caps) |*cap| if (cap.operation != .query and cap.operation != .create) {
            cap.support = .unavailable;
            cap.reason = .resource_limit;
        };
    };
    var reserved: [8]u8 = undefined;
    try reader.readInto(io, g.fatOffset(g.active()), &reserved);
    const clean = !boot.recovered and format.get32(&reserved, 4) & format.CLEAN_BITS == format.CLEAN_BITS and boot.bytes[65] & 1 == 0;
    if (!clean) for (caps) |*cap| if (cap.operation == .copy or cap.operation == .grow or cap.operation == .shrink) {
        cap.support = .unavailable;
        cap.reason = .recovery_unvalidated;
    };
    return .{ .filesystem = .vfat, .target = reader.target, .generation = 0, .block_size = g.clusterBytes(), .filesystem_bytes = g.bytes(), .clean = clean, .capabilities = caps, .features = try a.dupe([]const u8, &.{ "FAT32", try a.print("sector={d};cluster={d};FATs={d};active={d}", .{ g.sector, g.clusterBytes(), g.copies, g.active() }) }) };
}

pub fn check(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Check {
    const loaded = scan.load(a, io, reader, false) catch |err| {
        if (!std.mem.startsWith(u8, @errorName(err), "Fat") or err == error.FatResourceLimit) return err;
        return .{ .consistent = false, .detail = @errorName(err) };
    };
    return .{ .consistent = true, .detail = try a.print("FAT32: {d} files/directories; {d} free clusters; complete allocation and directory chains checked", .{ loaded.graph.objects.items.len, loaded.graph.free }) };
}
