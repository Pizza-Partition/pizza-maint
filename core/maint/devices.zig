//! Maintenance device acquisition and ownership, independent of storage algorithms.
const std = @import("std");
const proto = @import("proto");
const storage = @import("storage");

pub const Handle = struct {
    value: storage.device.Device,
    allocator: std.mem.Allocator,
    close_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io) void,
    recovery_fn: ?*const fn (*anyopaque, std.mem.Allocator, std.Io, std.Io.Dir) anyerror!storage.device.Device = null,
    refresh_fn: ?*const fn (*anyopaque) anyerror!void = null,
    whole_root: bool = true,

    pub fn backend(self: *Handle) storage.device.Device {
        return self.value;
    }
    pub fn close(self: *Handle, io: std.Io) void {
        self.close_fn(self.value.context, self.allocator, io);
        self.* = undefined;
    }
    pub fn admitRecovery(self: *Handle, io: std.Io, directory: std.Io.Dir) !void {
        if (self.recovery_fn) |check| {
            self.value = try check(self.value.context, self.allocator, io, directory);
        } else if (self.value.target.kind == .physical_device) return error.MissingRecoveryAdmission;
    }
    pub fn refreshLayout(self: *Handle) !void {
        if (self.refresh_fn) |refresh| try refresh(self.value.context);
    }
};

fn closeBlock(context: *anyopaque, a: std.mem.Allocator, io: std.Io) void {
    const block: *storage.block_device.BlockDevice = @ptrCast(@alignCast(context));
    block.close(io);
    a.destroy(block);
}
fn admitBlock(context: *anyopaque, a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !storage.device.Device {
    const block: *storage.block_device.BlockDevice = @ptrCast(@alignCast(context));
    try block.admitRecovery(a, io, directory);
    return block.backend();
}

pub const Provider = struct {
    open: *const fn (std.mem.Allocator, std.Io, proto.wire.DeviceRef, bool) anyerror!Handle = production,

    fn production(a: std.mem.Allocator, io: std.Io, target: proto.wire.DeviceRef, writable: bool) !Handle {
        if (target.kind != .physical) return error.ImageTargetsUnsupported;
        const block = try a.create(storage.block_device.BlockDevice);
        errdefer a.destroy(block);
        block.* = try storage.block_device.BlockDevice.open(a, io, target.path, try proto.hexDigest(target.identity), target.sector_size, if (writable) .write else .source);
        return .{ .value = block.backend(), .allocator = a, .close_fn = closeBlock, .recovery_fn = admitBlock, .refresh_fn = refreshBlock, .whole_root = !block.evidence.partition };
    }
};
fn refreshBlock(context: *anyopaque) !void {
    const block: *storage.block_device.BlockDevice = @ptrCast(@alignCast(context));
    try block.refreshLayout();
}
