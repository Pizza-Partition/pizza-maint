//! Test-only ordinary-file device for exercising the production storage pipeline.
const std = @import("std");
const model = @import("../model.zig");
const device = @import("../device.zig");

pub const ImageDevice = struct {
    file: std.Io.File,
    target: model.Target,
    inode: std.Io.File.INode,
    writable: bool = true,

    pub fn identify(io: std.Io, path: []const u8) !model.Digest {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.PrivateImageRequired;
        return @import("utils").filesystem.imageIdentity(file);
    }

    pub fn open(io: std.Io, path: []const u8, identity: model.Digest, sector: u32) !ImageDevice {
        return openMode(io, path, identity, sector, true);
    }

    pub fn openReadOnly(io: std.Io, path: []const u8, identity: model.Digest, sector: u32) !ImageDevice {
        return openMode(io, path, identity, sector, false);
    }

    fn openMode(io: std.Io, path: []const u8, identity: model.Digest, sector: u32, writable: bool) !ImageDevice {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = if (writable) .read_write else .read_only, .allow_directory = false, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true });
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.PrivateImageRequired;
        if (!std.mem.eql(u8, &identity, &try @import("utils").filesystem.imageIdentity(file))) return error.DeviceIdentityChanged;
        const target: model.Target = .{ .identity = identity, .capacity = stat.size, .sector_size = sector };
        try target.validate();
        return .{ .file = file, .target = target, .inode = stat.inode, .writable = writable };
    }
    pub fn close(self: *ImageDevice, io: std.Io) void {
        self.file.close(io);
        self.* = undefined;
    }
    pub fn backend(self: *ImageDevice) device.Device {
        return .{ .context = self, .target = self.target, .vtable = &.{ .reader = .{ .read = readInto }, .write = write, .flush = flush, .validate = validate } };
    }
    fn cast(ctx: *const anyopaque) *const ImageDevice {
        return @ptrCast(@alignCast(ctx));
    }
    fn readInto(ctx: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self = cast(ctx);
        try validate(ctx, io, self.target);
        if (try self.file.readPositionalAll(io, bytes, offset) != bytes.len) return error.ShortDeviceRead;
    }
    fn write(ctx: *anyopaque, io: std.Io, offset: u64, bytes: []const u8) !void {
        const self = cast(ctx);
        if (!self.writable) return error.ReadOnlyDevice;
        try self.file.writePositionalAll(io, bytes, offset);
    }
    fn flush(ctx: *anyopaque, io: std.Io) !void {
        try cast(ctx).file.sync(io);
    }
    fn validate(ctx: *const anyopaque, io: std.Io, target: model.Target) !void {
        const self = cast(ctx);
        if (!target.same(self.target) or !std.mem.eql(u8, &target.identity, &try @import("utils").filesystem.imageIdentity(self.file))) return error.TransactionTargetMismatch;
        const stat = try self.file.stat(io);
        if (stat.kind != .file or stat.inode != self.inode or stat.size != target.capacity) return error.DeviceSizeChanged;
    }
};
