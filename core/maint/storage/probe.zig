//! Read-only system, block-device and filesystem capability discovery.
const std = @import("std");
const model = @import("model.zig");
const filesystems = @import("filesystem/root.zig");
const memory = @import("memory.zig");

pub const BlockDevice = struct {
    name: []const u8,
    path: []const u8,
    device_number: ?[]const u8,
    capacity_bytes: ?u64,
    logical_block_size: ?u32,
    physical_block_size: ?u32,
    partition_number: ?u32,
    read_only: ?bool,
    removable: ?bool,
    rotational: ?bool,
    model: ?[]const u8,
};

pub const System = struct {
    architecture: []const u8,
    kernel_release: ?[]const u8,
    cpu_online: ?[]const u8,
    memory: memory.linux.Snapshot,
    block_devices: []const BlockDevice,
};

/// Use a caller-owned arena for returned strings and slices. No device node is opened.
pub fn querySystem(a: std.mem.Allocator, io: std.Io) !System {
    var directory = try std.Io.Dir.cwd().openDir(io, "/sys/class/block", .{ .iterate = true });
    defer directory.close(io);
    return .{
        .architecture = @tagName(@import("builtin").cpu.arch),
        .kernel_release = try text(a, io, .cwd(), "/proc/sys/kernel/osrelease"),
        .cpu_online = try text(a, io, .cwd(), "/sys/devices/system/cpu/online"),
        .memory = try memory.SYSTEM.sample(io),
        .block_devices = try blockDevices(a, io, directory),
    };
}

/// Reads Linux sysfs attributes from a borrowed /sys/class/block directory.
/// Allocate results in a caller-owned arena. Missing attributes remain null;
/// malformed evidence is an error.
pub fn blockDevices(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) ![]const BlockDevice {
    var entries: std.array_list.Managed(BlockDevice) = .init(a);
    errdefer entries.deinit();
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        // A device can disappear after enumeration (hot unplug).
        var node = directory.openDir(io, entry.name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer node.close(io);
        const partition = try number(u32, a, io, node, "partition");
        const sectors = try number(u64, a, io, node, "size");
        try entries.append(.{
            .name = try a.dupe(u8, entry.name),
            .path = try a.print("/dev/{s}", .{entry.name}),
            .device_number = try text(a, io, node, "dev"),
            // Linux sysfs size always counts 512-byte sectors, even on 4Kn media.
            .capacity_bytes = if (sectors) |n| std.math.mul(u64, n, 512) catch return error.InvalidBlockDeviceEvidence else null,
            .logical_block_size = try queueNumber(u32, a, io, node, partition, "logical_block_size"),
            .physical_block_size = try queueNumber(u32, a, io, node, partition, "physical_block_size"),
            .partition_number = partition,
            .read_only = try boolean(a, io, node, "ro"),
            .removable = try boolean(a, io, node, "removable"),
            .rotational = if (try queueNumber(u8, a, io, node, partition, "rotational")) |n| try flag(n) else null,
            .model = try text(a, io, node, "device/model"),
        });
    }
    std.mem.sort(BlockDevice, entries.items, {}, struct {
        fn lessThan(_: void, lhs: BlockDevice, rhs: BlockDevice) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);
    return entries.toOwnedSlice();
}

fn text(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8) !?[]const u8 {
    const file = directory.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    // procfs files may advertise size zero while still containing data.
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const bytes = try reader.interface.allocRemaining(a, .limited(4096));
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn number(comptime T: type, a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8) !?T {
    const value = (try text(a, io, directory, path)) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch return error.InvalidBlockDeviceEvidence;
}

fn queueNumber(comptime T: type, a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, partition: ?u32, name: []const u8) !?T {
    if (try number(T, a, io, directory, try a.print("queue/{s}", .{name}))) |value| return value;
    if (partition == null) return null;
    return number(T, a, io, directory, try a.print("../queue/{s}", .{name}));
}

fn flag(value: u8) !bool {
    return switch (value) {
        0 => false,
        1 => true,
        else => error.InvalidBlockDeviceEvidence,
    };
}

fn boolean(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8) !?bool {
    return if (try number(u8, a, io, directory, path)) |value| try flag(value) else null;
}

pub fn printSystem(a: std.mem.Allocator, io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, try querySystem(a, io), .{ .whitespace = .indent_2 }));
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

pub fn printMemory(io: std.Io) !void {
    var controller = try memory.Controller.init(io, .{});
    var buffer: [1024]u8 = undefined;
    const b = controller.budget;
    const limits = controller.planningLimits();
    const bytes = try std.fmt.bufPrint(
        &buffer,
        "{{\"total_bytes\":{d},\"available_bytes\":{d},\"safety_reserve_bytes\":{d},\"work_reserve_bytes\":{d},\"recovery_reserve_bytes\":{d},\"cache_budget_bytes\":{d},\"encoding_limit_bytes\":{d},\"read_limit_bytes\":{d}}}\n",
        .{
            b.total,
            b.available,
            b.reserve,
            b.work_reserve,
            b.recovery_reserve,
            b.cache_bytes,
            limits.encoded_bytes,
            limits.read_bytes,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}
pub fn printCapabilities(a: std.mem.Allocator, io: std.Io) !void {
    const Entry = struct { filesystem: model.Filesystem, operations: []const model.Capability };
    const formats = std.enums.values(model.Filesystem);
    const entries = try a.alloc(Entry, formats.len);
    for (formats, entries) |fs, *entry| {
        const capabilities = try a.alloc(model.Capability, std.enums.values(model.Kind).len);
        for (std.enums.values(model.Kind), capabilities) |kind, *capability| capability.* = .{ .operation = kind };
        for (filesystems.BUILTIN.drivers) |driver| {
            if (driver.filesystem != fs) continue;
            for (capabilities) |*capability| {
                for (driver.operations) |actual| if (actual.operation == capability.operation) {
                    capability.* = actual;
                    break;
                };
            }
        }
        entry.* = .{ .filesystem = fs, .operations = capabilities };
    }
    try std.Io.File.stdout().writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, .{
        .implementation = "pizza-native",
        .registered_filesystems = filesystems.BUILTIN.drivers.len,

        .production_physical_writes = true,
        .filesystems = entries,
    }, .{ .whitespace = .indent_2 }));
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

pub const FilesystemInfo = struct { filesystem: model.Filesystem, bytes: []const u8, block_size: u32, clean: bool, usage: model.Usage = .{}, capabilities: []const model.Capability = &.{} };
pub const PartitionInfo = struct { partition_id: []const u8, offset: []const u8, length: []const u8, type_id: []const u8, attributes: []const u8, filesystem: ?FilesystemInfo, filesystem_error: ?[]const u8 = null };
pub const DeviceInfo = struct {
    path: []const u8,
    identity: []const u8,
    capacity: []const u8,
    sector_size: u32,
    physical_block_size: ?u32 = null,
    kind: []const u8,
    partition_table: ?[]const u8,
    partition_table_error: ?[]const u8,
    partitions: []const PartitionInfo,
    filesystem: ?FilesystemInfo,
    filesystem_error: ?[]const u8 = null,
};
fn filesystemInfo(a: std.mem.Allocator, io: std.Io, reader: @import("device.zig").Reader) !?FilesystemInfo {
    const snapshot = filesystems.BUILTIN.query(a, io, reader) catch |err| switch (err) {
        error.FilesystemUnavailable, error.AmbiguousFilesystem => return null,
        else => return err,
    };
    return .{ .filesystem = snapshot.filesystem, .bytes = try a.print("{d}", .{snapshot.filesystem_bytes}), .block_size = snapshot.block_size, .clean = snapshot.clean, .usage = snapshot.usage, .capabilities = snapshot.capabilities };
}
/// Query stable partition IDs needed to construct layout requests. Errors in a
/// partition table are reported as evidence; no fallback layout is invented.
pub fn queryDevice(a: std.mem.Allocator, io: std.Io, path: []const u8, reader: @import("device.zig").Reader) !DeviceInfo {
    try reader.target.validate();
    var table_error: ?[]const u8 = null;
    const layout = @import("partition_table.zig").BUILTIN.readLayout(a, io, reader) catch |err| blk: {
        table_error = @errorName(err);
        break :blk null;
    };
    var partitions: std.ArrayList(PartitionInfo) = .empty;
    if (layout) |table| {
        var builder = @import("program.zig").PhysicalProgramBuilder.init(a, reader);
        for (table.entries) |entry| {
            var view: @import("program.zig").PhysicalProgramBuilder.View = .{ .builder = &builder, .version = 0, .range = entry.range };
            var filesystem_error: ?[]const u8 = null;
            const filesystem = filesystemInfo(a, io, view.reader()) catch |err| blk: {
                filesystem_error = @errorName(err);
                break :blk null;
            };
            try partitions.append(a, .{ .partition_id = try a.dupe(u8, &std.fmt.bytesToHex(entry.id, .lower)), .offset = try a.print("{d}", .{entry.range.offset}), .length = try a.print("{d}", .{entry.range.length}), .type_id = try a.dupe(u8, &std.fmt.bytesToHex(entry.type_id, .lower)), .attributes = try a.print("{d}", .{entry.attributes}), .filesystem = filesystem, .filesystem_error = filesystem_error });
        }
    }
    var filesystem_error: ?[]const u8 = null;
    const filesystem = if (partitions.items.len != 0) null else filesystemInfo(a, io, reader) catch |err| blk: {
        filesystem_error = @errorName(err);
        break :blk null;
    };
    return .{ .path = path, .identity = try a.dupe(u8, &std.fmt.bytesToHex(reader.target.identity, .lower)), .capacity = try a.print("{d}", .{reader.target.capacity}), .sector_size = reader.target.sector_size, .kind = if (reader.target.kind == .private_image) "image" else "physical", .partition_table = if (layout) |table| @tagName(table.kind) else null, .partition_table_error = table_error, .partitions = try partitions.toOwnedSlice(a), .filesystem = filesystem, .filesystem_error = filesystem_error };
}
