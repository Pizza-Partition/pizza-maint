//! Sysfs fixtures distinguish hardware geometry from filesystem block sizes.
const std = @import("std");
const probe = @import("storage").probe;
const IO = std.testing.io;

test "probe reports 4Kn capacity in bytes and inherits a partition's queue geometry" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-probe-");
    defer std.Io.Dir.cwd().deleteTree(IO, path) catch {};
    var root = try std.Io.Dir.cwd().openDir(IO, path, .{});
    defer root.close(IO);
    try root.createDirPath(IO, "class");
    try root.createDirPath(IO, "devices/disk/queue");
    try root.createDirPath(IO, "devices/disk/disk1");
    try root.createDirPath(IO, "devices/disk/device");
    const attributes = .{
        .{ "size", "32768\n" },
        .{ "dev", "8:0\n" },
        .{ "ro", "0\n" },
        .{ "removable", "1\n" },
        .{ "queue/logical_block_size", "4096\n" },
        .{ "queue/physical_block_size", "4096\n" },
        .{ "queue/rotational", "0\n" },
        .{ "device/model", " Test Disk \n" },
        .{ "disk1/partition", "1\n" },
        .{ "disk1/size", "8192\n" },
        .{ "disk1/ro", "1\n" },
    };
    inline for (attributes) |attribute| try root.writeFile(IO, .{
        .sub_path = try a.print("devices/disk/{s}", .{attribute[0]}),
        .data = attribute[1],
    });
    try root.symLink(IO, "../devices/disk", "class/disk", .{});
    try root.symLink(IO, "../devices/disk/disk1", "class/disk1", .{});
    try root.createDirPath(IO, "class/missing");
    var class = try root.openDir(IO, "class", .{ .iterate = true });
    defer class.close(IO);
    const devices = try probe.blockDevices(a, IO, class);
    try std.testing.expectEqual(3, devices.len);
    const disk = devices[0];
    try std.testing.expectEqualStrings("disk", disk.name);
    try std.testing.expectEqualStrings("/dev/disk", disk.path);
    try std.testing.expectEqualStrings("8:0", disk.device_number.?);
    try std.testing.expectEqual(16 * 1024 * 1024, disk.capacity_bytes.?);
    try std.testing.expectEqual(4096, disk.logical_block_size.?);
    try std.testing.expectEqual(4096, disk.physical_block_size.?);
    try std.testing.expect(!disk.read_only.? and disk.removable.? and !disk.rotational.?);
    try std.testing.expectEqualStrings("Test Disk", disk.model.?);
    const partition = devices[1];
    try std.testing.expectEqualStrings("disk1", partition.name);
    try std.testing.expectEqual(4 * 1024 * 1024, partition.capacity_bytes.?);
    try std.testing.expectEqual(4096, partition.logical_block_size.?);
    try std.testing.expectEqual(4096, partition.physical_block_size.?);
    try std.testing.expectEqual(1, partition.partition_number.?);
    try std.testing.expect(partition.read_only.?);
    try std.testing.expect(devices[2].capacity_bytes == null and devices[2].logical_block_size == null);
    inline for (attributes) |attribute| try std.testing.expectEqualStrings(attribute[1], try root.readFileAlloc(IO, try a.print("devices/disk/{s}", .{attribute[0]}), a, .limited(4096)));
    // 512e media must preserve the distinction between logical and physical I/O.
    try root.writeFile(IO, .{ .sub_path = "devices/disk/queue/logical_block_size", .data = "512\n" });
    const emulated = try probe.blockDevices(a, IO, class);
    try std.testing.expectEqual(512, emulated[0].logical_block_size.?);
    try std.testing.expectEqual(4096, emulated[0].physical_block_size.?);
    try std.testing.expectEqual(16 * 1024 * 1024, emulated[0].capacity_bytes.?);
}

test "probe rejects capacity overflow and invalid boolean evidence" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-probe-invalid-");
    defer std.Io.Dir.cwd().deleteTree(IO, path) catch {};
    var root = try std.Io.Dir.cwd().openDir(IO, path, .{ .iterate = true });
    defer root.close(IO);
    try root.createDirPath(IO, "disk");
    try root.writeFile(IO, .{ .sub_path = "disk/size", .data = "18446744073709551615\n" });
    try std.testing.expectError(error.InvalidBlockDeviceEvidence, probe.blockDevices(a, IO, root));
    try root.writeFile(IO, .{ .sub_path = "disk/size", .data = "8\n" });
    try root.writeFile(IO, .{ .sub_path = "disk/ro", .data = "2\n" });
    try std.testing.expectError(error.InvalidBlockDeviceEvidence, probe.blockDevices(a, IO, root));
}
