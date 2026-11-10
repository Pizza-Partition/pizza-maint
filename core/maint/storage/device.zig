//! Filesystem drivers only receive Reader. The executor owns write access.
const std = @import("std");
const model = @import("model.zig");
const Controller = @import("memory.zig").Controller;

/// Provenance for views into a shared device, including nested partitions.
pub const Region = struct { identity: model.Digest, range: model.Range };

pub const Reader = struct {
    pub const VTable = struct { read: *const fn (*const anyopaque, std.Io, u64, []u8) anyerror!void };
    context: *const anyopaque,
    target: model.Target,
    vtable: *const VTable,
    memory: ?*Controller = null,
    write_granule: u32 = 0,
    region: ?Region = null,

    pub fn location(self: Reader) Region {
        return self.region orelse .{ .identity = self.target.identity, .range = .{ .offset = 0, .length = self.target.capacity } };
    }

    pub fn aliases(self: Reader, other: Reader) bool {
        const lhs = self.location();
        const rhs = other.location();
        return std.mem.eql(u8, &lhs.identity, &rhs.identity) and lhs.range.overlaps(rhs.range);
    }

    pub fn withMemory(self: Reader, memory: *Controller) Reader {
        var copy = self;
        copy.memory = memory;
        return copy;
    }
    pub fn limits(self: Reader) @import("memory.zig").PlanningLimits {
        return if (self.memory) |budget| budget.planningLimits() else .{};
    }

    /// Stream a range digest with bounded memory, including clone guards and
    /// execution readback. No operation-specific verifier is needed.
    pub fn digest(self: Reader, io: std.Io, range: model.Range) !model.Digest {
        if (try range.end() > self.target.capacity) return error.RangeOutsideDevice;
        var buffer: [65536]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var done: u64 = 0;
        while (done < range.length) {
            const part = buffer[0..@intCast(@min(buffer.len, range.length - done))];
            try self.readInto(io, range.offset + done, part);
            hash.update(part);
            done += part.len;
        }
        return hash.finalResult();
    }

    /// Caller owns the returned bytes. A failed read releases the allocation.
    pub fn read(self: Reader, a: std.mem.Allocator, io: std.Io, range: model.Range) ![]u8 {
        const end = try range.end();
        if (end > self.target.capacity) return error.RangeOutsideDevice;
        const length = std.math.cast(usize, range.length) orelse return error.RangeOverflow;
        const bytes = try a.alloc(u8, length);
        errdefer a.free(bytes);
        try self.readInto(io, range.offset, bytes);
        return bytes;
    }

    /// Bounded streaming and C ABI bridge primitive; public reads return data.
    pub fn readInto(self: Reader, io: std.Io, offset: u64, bytes: []u8) !void {
        const end = std.math.add(u64, offset, bytes.len) catch return error.RangeOverflow;
        if (end > self.target.capacity) return error.RangeOutsideDevice;
        if (self.memory) |budget| try budget.activity(bytes.len);
        try self.vtable.read(self.context, io, offset, bytes);
    }
};

/// Borrowed write capability for the shared execution layer. The backend owns
/// its resources and must remain alive until all concurrent work is joined.
/// Disjoint reads/writes may run concurrently; flush follows completion of all
/// writes and must make those writes durable before returning successfully.
pub const Device = struct {
    pub const VTable = struct {
        reader: Reader.VTable,
        write: *const fn (*anyopaque, std.Io, u64, []const u8) anyerror!void,
        flush: *const fn (*anyopaque, std.Io) anyerror!void,
        validate: *const fn (*const anyopaque, std.Io, model.Target) anyerror!void,
    };
    context: *anyopaque,
    target: model.Target,
    /// Granted by a physical backend after exclusive acquisition and recovery
    /// admission; ordinary-file test devices do not require this capability.
    physical_write_authorized: bool = false,
    vtable: *const VTable,
    memory: ?*Controller = null,
    write_granule: u32 = 0,
    region: ?Region = null,

    pub fn reader(self: Device) Reader {
        return .{ .context = self.context, .target = self.target, .vtable = &self.vtable.reader, .memory = self.memory, .region = self.region, .write_granule = self.write_granule };
    }

    pub fn read(self: Device, a: std.mem.Allocator, io: std.Io, range: model.Range) ![]u8 {
        return self.reader().read(a, io, range);
    }

    pub fn withMemory(self: Device, memory: *Controller) Device {
        var copy = self;
        copy.memory = memory;
        return copy;
    }

    pub fn validate(self: Device, io: std.Io) !void {
        try self.target.validate();
        try self.vtable.validate(self.context, io, self.target);
    }

    pub fn authorizeMutation(self: Device) !void {
        if (self.target.kind == .physical_device and !self.physical_write_authorized)
            return error.TransactionTargetMismatch;
    }

    pub fn write(self: Device, io: std.Io, range: model.Range, bytes: []const u8) !void {
        try self.authorizeMutation();
        try range.validate(self.target.capacity, self.target.sector_size);
        if (range.length != bytes.len) return error.WriteLengthMismatch;
        try self.validate(io);
        if (self.memory) |budget| try budget.check();
        try self.vtable.write(self.context, io, range.offset, bytes);
        if (self.memory) |budget| try budget.check();
    }

    pub fn flush(self: Device, io: std.Io) !void {
        try self.validate(io);
        if (self.memory) |budget| try budget.check();
        try self.vtable.flush(self.context, io);
        if (self.memory) |budget| try budget.check();
    }
};
