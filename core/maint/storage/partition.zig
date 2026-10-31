//! A borrowed, bounded partition view. Changing its bounds never edits a
//! partition table: table changes must themselves be planned and journaled.
const std = @import("std");
const model = @import("model.zig");
const devices = @import("device.zig");

pub const Partition = struct {
    backing: devices.Device,
    range: model.Range,
    target: model.Target,
    id: model.Digest,

    /// Keep the returned object at a stable address while its borrowed reader
    /// or device is in use. All offsets exposed by those handles are relative.
    pub fn init(backing: devices.Device, range: model.Range, id: model.Digest) !Partition {
        try backing.target.validate();
        try range.validate(backing.target.capacity, backing.target.sector_size);
        if (std.mem.allEqual(u8, &id, 0)) return error.MissingDeviceIdentity;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("pizza-partition-view-v1");
        hash.update(&backing.target.identity);
        hash.update(&id);
        var geometry: [16]u8 = undefined;
        std.mem.writeInt(u64, geometry[0..8], range.offset, .little);
        std.mem.writeInt(u64, geometry[8..16], range.length, .little);
        hash.update(&geometry);
        return .{
            .backing = backing,
            .range = range,
            .id = id,
            .target = .{ .identity = hash.finalResult(), .capacity = range.length, .sector_size = backing.target.sector_size, .kind = backing.target.kind },
        };
    }

    pub const Change = struct { partition_id: model.Digest, range: model.Range };
    /// Return a planning request while keeping this view and its identity fixed.
    pub fn setRange(self: *const Partition, range: model.Range) !Change {
        try range.validate(self.backing.target.capacity, self.backing.target.sector_size);
        return .{ .partition_id = self.id, .range = range };
    }
    pub fn setSize(self: *const Partition, bytes: u64) !Change {
        return self.setRange(.{ .offset = self.range.offset, .length = bytes });
    }
    pub fn deviceRange(self: *const Partition, range: model.Range) !model.Range {
        try range.validate(self.range.length, self.backing.target.sector_size);
        return .{ .offset = try std.math.add(u64, self.range.offset, range.offset), .length = range.length };
    }

    pub fn reader(self: *const Partition) devices.Reader {
        return .{ .context = self, .target = self.target, .vtable = &.{ .read = readInto }, .memory = self.backing.memory, .region = self.region() };
    }

    pub fn read(self: *const Partition, a: std.mem.Allocator, io: std.Io, range: model.Range) ![]u8 {
        return self.reader().read(a, io, range);
    }

    pub fn device(self: *Partition) devices.Device {
        return .{
            .context = self,
            .target = self.target,
            .physical_write_authorized = self.backing.physical_write_authorized,
            .vtable = &.{ .reader = .{ .read = readInto }, .write = write, .flush = flush, .validate = validate },
            .memory = self.backing.memory,
            .region = self.region(),
        };
    }

    fn region(self: *const Partition) devices.Region {
        const parent = self.backing.reader().location();
        return .{ .identity = parent.identity, .range = .{ .offset = parent.range.offset + self.range.offset, .length = self.range.length } };
    }

    fn cast(context: *const anyopaque) *const Partition {
        return @ptrCast(@alignCast(context));
    }

    fn readInto(context: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self = cast(context);
        try validate(context, io, self.target);
        try self.backing.reader().readInto(io, self.range.offset + offset, bytes);
    }

    fn write(context: *anyopaque, io: std.Io, offset: u64, bytes: []const u8) !void {
        const self = cast(context);
        try self.backing.write(io, .{ .offset = self.range.offset + offset, .length = bytes.len }, bytes);
    }

    fn flush(context: *anyopaque, io: std.Io) !void {
        try cast(context).backing.flush(io);
    }

    fn validate(context: *const anyopaque, io: std.Io, target: model.Target) !void {
        const self = cast(context);
        const current = try init(self.backing, self.range, self.id);
        if (!target.same(self.target) or !current.target.same(self.target)) return error.TransactionTargetMismatch;
        try self.backing.validate(io);
    }
};
