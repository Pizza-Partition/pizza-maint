const std = @import("std");
const wire = @import("generated.zig");
pub fn fingerprint(a: std.mem.Allocator, snapshot: wire.InventorySnapshot) ![]const u8 {
    const disks = try a.dupe(wire.HostDisk, snapshot.disks);
    for (disks) |*disk| {
        disk.diagnostics = &.{};
        disk.partitions = try a.dupe(wire.HostPartition, disk.partitions);
        for (@constCast(disk.partitions)) |*part| {
            part.used_bytes = null;
            part.free_bytes = null;
            part.mountpoints = &.{};
        }
    }
    const bytes = try std.json.Stringify.valueAlloc(a, disks, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
