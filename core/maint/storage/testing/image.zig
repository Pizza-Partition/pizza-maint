//! Disposable regular-file backend for storage tests and explicit diagnostics.
const std = @import("std");
const model = @import("../model.zig");
const device = @import("../device.zig");

pub const Image = struct {
    file: std.Io.File,
    target: model.Target,
    /// Simulate power loss halfway through a write at this offset. Configure
    /// before execution; recovery reopens a fresh backend without this fault.
    tear_write_at: ?u64 = null,

    pub fn open(io: std.Io, path: []const u8, identity: model.Digest, sector_size: u32) !Image {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true });
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.PrivateImageRequired;
        const target: model.Target = .{ .identity = identity, .capacity = stat.size, .sector_size = sector_size };
        try target.validate();
        return .{ .file = file, .target = target };
    }

    pub fn close(self: *Image, io: std.Io) void {
        self.file.close(io);
        self.* = undefined;
    }

    pub fn backend(self: *Image) device.Device {
        return .{ .context = self, .target = self.target, .vtable = &.{ .reader = .{ .read = read }, .write = write, .flush = flush, .validate = validate } };
    }

    pub fn reader(self: *const Image) device.Reader {
        return .{ .context = self, .target = self.target, .vtable = &.{ .read = read } };
    }

    fn read(context: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self: *const Image = @ptrCast(@alignCast(context));
        if (try self.file.readPositionalAll(io, bytes, offset) != bytes.len) return error.ShortDeviceRead;
    }

    fn validate(context: *const anyopaque, io: std.Io, target: model.Target) !void {
        const self: *const Image = @ptrCast(@alignCast(context));
        if (!self.target.same(target)) return error.TransactionTargetMismatch;
        if ((try self.file.stat(io)).size != target.capacity) return error.DeviceSizeChanged;
    }

    fn write(context: *anyopaque, io: std.Io, offset: u64, bytes: []const u8) !void {
        const self: *Image = @ptrCast(@alignCast(context));
        if (self.tear_write_at == offset) {
            try self.file.writePositionalAll(io, bytes[0 .. bytes.len / 2], offset);
            try self.file.sync(io);
            return error.InjectedPartialMetadata;
        }
        try self.file.writePositionalAll(io, bytes, offset);
    }

    fn flush(context: *anyopaque, io: std.Io) !void {
        const self: *Image = @ptrCast(@alignCast(context));
        try self.file.sync(io);
    }
};
