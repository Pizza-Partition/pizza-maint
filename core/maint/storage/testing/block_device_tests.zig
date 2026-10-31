//! Physical evidence admission without opening any host block device.
const std = @import("std");
const block = @import("storage").block_device;
const IO = std.testing.io;

test "physical identity survives node renaming and binds partition address ranges" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-block-evidence-");
    defer std.Io.Dir.cwd().deleteTree(IO, path) catch {};
    var dir = try std.Io.Dir.cwd().openDir(IO, path, .{});
    defer dir.close(IO);
    try dir.createDirPath(IO, "sys/dev/block");
    try dir.createDirPath(IO, "sys/devices/drive/queue");
    try dir.createDirPath(IO, "sys/devices/drive/part");
    const values = .{
        .{ "dev", "8:0" },                       .{ "size", "2097152" },                   .{ "serial", "physical-serial" },
        .{ "queue/logical_block_size", "4096" }, .{ "queue/physical_block_size", "4096" }, .{ "part/dev", "8:1" },
        .{ "part/partition", "1" },              .{ "part/start", "2048" },                .{ "part/size", "32768" },
    };
    inline for (values) |value| try dir.writeFile(IO, .{ .sub_path = try a.print("sys/devices/drive/{s}", .{value[0]}), .data = value[1] });
    try dir.symLink(IO, "../../devices/drive", "sys/dev/block/8:0", .{});
    try dir.symLink(IO, "../../devices/drive/part", "sys/dev/block/8:1", .{});
    var sysfs = try dir.openDir(IO, "sys/dev/block", .{});
    defer sysfs.close(IO);
    const first = try block.inspectSysfs(a, IO, sysfs, .{ .major = 8, .minor = 0 });
    const part = try block.inspectSysfs(a, IO, sysfs, .{ .major = 8, .minor = 1 });
    try std.testing.expectEqual(1024 * 1024, part.offset);
    try std.testing.expectEqual(16 * 1024 * 1024, part.capacity);
    try std.testing.expectEqual(4096, part.logical);
    try std.testing.expectEqualSlices(u8, &first.disk_identity, &part.disk_identity);
    try std.testing.expect(!std.mem.eql(u8, &first.identity, &part.identity));
    try dir.writeFile(IO, .{ .sub_path = "sys/devices/drive/dev", .data = "9:0" });
    try dir.symLink(IO, "../../devices/drive", "sys/dev/block/9:0", .{});
    const renamed = try block.inspectSysfs(a, IO, sysfs, .{ .major = 9, .minor = 0 });
    try std.testing.expectEqualSlices(u8, &first.identity, &renamed.identity);
    try dir.writeFile(IO, .{ .sub_path = "sys/devices/drive/part/start", .data = "4096" });
    const moved = try block.inspectSysfs(a, IO, sysfs, .{ .major = 8, .minor = 1 });
    try std.testing.expect(!std.mem.eql(u8, &part.identity, &moved.identity));
    try dir.writeFile(IO, .{ .sub_path = "sys/devices/drive/serial", .data = "replacement-device" });
    const replacement = try block.inspectSysfs(a, IO, sysfs, .{ .major = 9, .minor = 0 });
    try std.testing.expect(!std.mem.eql(u8, &renamed.identity, &replacement.identity));
    try dir.deleteFile(IO, "sys/devices/drive/serial");
    try std.testing.expectError(error.StableDeviceIdentityUnavailable, block.inspectSysfs(a, IO, sysfs, .{ .major = 9, .minor = 0 }));
    // USB bridges may omit readable SCSI VPD; use the nearest USB device's
    // vendor/product/serial plus interface and LUN, never a hub's identity.
    try dir.createDirPath(IO, "sys/devices/scsi0:0:0:3");
    try dir.symLink(IO, "../scsi0:0:0:3", "sys/devices/drive/device", .{});
    try dir.writeFile(IO, .{ .sub_path = "sys/devices/bInterfaceNumber", .data = "00" });
    try dir.writeFile(IO, .{ .sub_path = "sys/devices/idVendor", .data = "346d" });
    try dir.writeFile(IO, .{ .sub_path = "sys/devices/idProduct", .data = "5678" });
    try dir.writeFile(IO, .{ .sub_path = "sys/devices/serial", .data = "usb-serial" });
    const usb = try block.inspectSysfs(a, IO, sysfs, .{ .major = 9, .minor = 0 });
    try dir.deleteFile(IO, "sys/devices/serial");
    try std.testing.expectError(error.StableDeviceIdentityUnavailable, block.inspectSysfs(a, IO, sysfs, .{ .major = 9, .minor = 0 }));
    try std.testing.expect(!std.mem.eql(u8, &usb.identity, &replacement.identity));
}
test "physical mount admission checks child nodes and rejects malformed evidence" {
    const nodes: []const block.Node = &.{ .{ .major = 8, .minor = 0 }, .{ .major = 8, .minor = 1 } };
    const mounted = "42 21 8:1 / /mounted rw - ext4 /dev/renamed rw\n";
    try std.testing.expectError(error.BlockDeviceMounted, block.checkMounts(mounted, nodes));
    try block.checkMounts(mounted, &.{.{ .major = 9, .minor = 1 }});
    try std.testing.expectError(error.InvalidMountEvidence, block.checkMounts("broken", nodes));
    try std.testing.expectError(error.InvalidDeviceNumber, block.Node.parse("8:1:2"));
}
