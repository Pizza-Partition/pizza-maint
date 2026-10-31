//! Test-only acquisition of ordinary-file devices for maintenance integration tests.
const std = @import("std");
const proto = @import("proto");
const devices = @import("../devices.zig");
const ImageDevice = @import("storage").testing.ImageDevice;

pub const PROVIDER: devices.Provider = .{ .open = open };

fn open(a: std.mem.Allocator, io: std.Io, target: proto.wire.DeviceRef, writable: bool) !devices.Handle {
    if (target.kind != .image) return error.PhysicalWritesDisabled;
    const image = try a.create(ImageDevice);
    errdefer a.destroy(image);
    const identity = try proto.hexDigest(target.identity);
    image.* = if (writable) try ImageDevice.open(io, target.path, identity, target.sector_size) else try ImageDevice.openReadOnly(io, target.path, identity, target.sector_size);
    return .{ .value = image.backend(), .allocator = a, .close_fn = close };
}
fn close(context: *anyopaque, a: std.mem.Allocator, io: std.Io) void {
    const image: *ImageDevice = @ptrCast(@alignCast(context));
    image.close(io);
    a.destroy(image);
}
