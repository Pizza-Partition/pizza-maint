//! Fixed-extent recovery storage. No mounted filesystem or allocation changes.
//! The descriptor must come from an authenticated, offline-verified extent map.
const std = @import("std");
const model = @import("model.zig");
const device = @import("device.zig");
const recovery = @import("recovery_store.zig");
const Record = recovery.Record;
const COUNT = recovery.RECORD_COUNT;
const Slot = struct { offset: u64 = 0, capacity: u64 = 0, length: u64 = 0, exists: bool = false };
pub const Descriptor = struct {
    session: model.Digest,
    extents: []const model.Range,
    block_size: u32,
};
pub const RawCapsule = struct {
    disk: device.Device,
    descriptor: Descriptor,
    slots: [COUNT]Slot = @splat(.{}),
    sequence: u64 = 0,
    active: usize = 1,
    capacity: u64,
    allocator: std.mem.Allocator,

    pub fn required(limits: [COUNT]u64, block: u32) !u64 {
        try recovery.validateBlockSize(block);
        var bytes: u64 = @as(u64, block) * 2;
        for (limits) |n| bytes = try std.math.add(u64, bytes, try aligned(n, block));
        return bytes;
    }
    pub fn limitsFor(r: @import("program_executor.zig").Reservation, block: u32) [COUNT]u64 {
        var limits: [COUNT]u64 = @splat(block);
        limits[@backingInt(Record.program)] = r.program;
        limits[@backingInt(Record.snapshots)] = r.snapshots;
        limits[@backingInt(Record.scratch)] = r.scratch;
        limits[@backingInt(Record.state)] = r.state;
        return limits;
    }
    fn base(a: std.mem.Allocator, disk: device.Device, desc: Descriptor) !RawCapsule {
        try recovery.validateBlockSize(desc.block_size);
        if (desc.block_size < disk.target.sector_size or desc.extents.len == 0 or desc.extents.len > 16384) return error.InvalidCapsuleGeometry;
        var capacity: u64 = 0;
        for (desc.extents, 0..) |r, i| {
            try r.validate(disk.target.capacity, desc.block_size);
            for (desc.extents[0..i]) |other| if (r.overlaps(other)) return error.OverlappingCapsuleExtents;
            capacity = try std.math.add(u64, capacity, r.length);
        }
        if (capacity < @as(u64, desc.block_size) * 2) return error.CapsuleTooSmall;
        return .{ .disk = disk, .descriptor = desc, .capacity = capacity, .allocator = a };
    }
    /// Explicitly initializes previously reserved space; never used as recovery fallback.
    pub fn format(a: std.mem.Allocator, io: std.Io, disk: device.Device, desc: Descriptor, limits: [COUNT]u64) !RawCapsule {
        var self = try base(a, disk, desc);
        const head = try a.alloc(u8, desc.block_size);
        defer a.free(head);
        for (0..2) |i| {
            try self.readLogical(io, @as(u64, i) * desc.block_size, head);
            if (std.mem.eql(u8, head[0..8], "PZCAP001")) return error.CapsuleAlreadyExists;
        }
        if (try required(limits, desc.block_size) > self.capacity) return error.CapsuleTooSmall;
        var offset: u64 = @as(u64, desc.block_size) * 2;
        for (&self.slots, limits) |*slot, n| {
            slot.* = .{ .offset = offset, .capacity = try aligned(n, desc.block_size) };
            offset = try std.math.add(u64, offset, slot.capacity);
        }
        try self.sync(io);
        try self.sync(io);
        return self;
    }
    pub fn open(a: std.mem.Allocator, io: std.Io, disk: device.Device, desc: Descriptor) !RawCapsule {
        var self = try base(a, disk, desc);
        const bytes = try a.alloc(u8, desc.block_size);
        defer a.free(bytes);
        var found = false;
        for (0..2) |index| {
            try self.readLogical(io, @as(u64, index) * desc.block_size, bytes);
            var candidate = self;
            candidate.decode(bytes) catch continue;
            if (!found or candidate.sequence > self.sequence) {
                self.slots = candidate.slots;
                self.sequence = candidate.sequence;
                self.active = index;
                found = true;
            }
        }
        if (!found) return error.InvalidCapsuleHeaders;
        return self;
    }
    pub fn store(self: *RawCapsule) recovery.Store {
        return .{ .context = self, .vtable = &VTABLE };
    }
    pub fn protects(self: RawCapsule, p: @import("program.zig").Program) !void {
        if (!self.disk.target.same(p.target)) return error.TransactionTargetMismatch;
        for (p.steps, 0..) |_, i| if (p.targetRange(i)) |r| {
            for (self.descriptor.extents) |excluded| if (r.overlaps(excluded)) return error.ProgramOverwritesRecovery;
        };
    }
    fn mapDigest(self: RawCapsule) model.Digest {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(&self.disk.target.identity);
        for (self.descriptor.extents) |r| {
            var b: [16]u8 = undefined;
            put(&b, 0, r.offset);
            put(&b, 8, r.length);
            h.update(&b);
        }
        return h.finalResult();
    }
    fn decode(self: *RawCapsule, bytes: []const u8) !void {
        if (!std.mem.eql(u8, bytes[0..8], "PZCAP001") or get(bytes, 8) != self.descriptor.block_size or !std.mem.eql(u8, bytes[24..56], &self.disk.target.identity) or !std.mem.eql(u8, bytes[56..88], &self.descriptor.session) or !std.mem.eql(u8, bytes[88..120], &self.mapDigest()) or !std.mem.eql(u8, bytes[bytes.len - 32 ..], &model.digest(bytes[0 .. bytes.len - 32]))) return error.InvalidCapsuleHeader;
        self.sequence = get(bytes, 16);
        if (self.sequence == 0) return error.InvalidCapsuleHeader;
        var end: u64 = @as(u64, self.descriptor.block_size) * 2;
        for (&self.slots, 0..) |*slot, i| {
            const at = 128 + i * 32;
            slot.* = .{ .offset = get(bytes, at), .capacity = get(bytes, at + 8), .length = get(bytes, at + 16), .exists = bytes[at + 24] == 1 };
            if (bytes[at + 24] > 1 or slot.offset != end or slot.capacity % self.descriptor.block_size != 0 or slot.length > slot.capacity) return error.InvalidCapsuleHeader;
            end = try std.math.add(u64, end, slot.capacity);
            if (end > self.capacity) return error.InvalidCapsuleHeader;
        }
    }
    fn sync(self: *RawCapsule, io: std.Io) !void {
        // Data always becomes durable before a control head publishes its size/name.
        try self.disk.flush(io);
        const b = try self.allocator.alloc(u8, self.descriptor.block_size);
        defer self.allocator.free(b);
        @memset(b, 0);
        @memcpy(b[0..8], "PZCAP001");
        put(b, 8, self.descriptor.block_size);
        const sequence = try std.math.add(u64, self.sequence, 1);
        put(b, 16, sequence);
        @memcpy(b[24..56], &self.disk.target.identity);
        @memcpy(b[56..88], &self.descriptor.session);
        @memcpy(b[88..120], &self.mapDigest());
        for (self.slots, 0..) |slot, i| {
            const at = 128 + i * 32;
            put(b, at, slot.offset);
            put(b, at + 8, slot.capacity);
            put(b, at + 16, slot.length);
            b[at + 24] = @intFromBool(slot.exists);
        }
        @memcpy(b[b.len - 32 ..], &model.digest(b[0 .. b.len - 32]));
        const next = 1 - self.active;
        try self.writeLogical(io, @as(u64, next) * self.descriptor.block_size, b);
        try self.disk.flush(io);
        const check = try self.allocator.alloc(u8, b.len);
        defer self.allocator.free(check);
        try self.readLogical(io, @as(u64, next) * self.descriptor.block_size, check);
        if (!std.mem.eql(u8, b, check)) return error.CapsulePublicationMismatch;
        self.sequence = sequence;
        self.active = next;
    }
    fn readLogical(self: RawCapsule, io: std.Io, offset: u64, bytes: []u8) !void {
        if (try std.math.add(u64, offset, bytes.len) > self.capacity) return error.CapsuleRangeOverflow;
        var skip = offset;
        var done: usize = 0;
        for (self.descriptor.extents) |r| {
            if (skip >= r.length) {
                skip -= r.length;
                continue;
            }
            const n: usize = @intCast(@min(r.length - skip, bytes.len - done));
            try self.disk.reader().readInto(io, r.offset + skip, bytes[done..][0..n]);
            done += n;
            skip = 0;
            if (done == bytes.len) return;
        }
    }
    fn writeLogical(self: RawCapsule, io: std.Io, offset: u64, bytes: []const u8) !void {
        if (try std.math.add(u64, offset, bytes.len) > self.capacity) return error.CapsuleRangeOverflow;
        // The physical device writer accepts sectors. Read/modify/write partial sectors
        // only inside the capsule; all record and control areas have separate blocks.
        const sector = self.disk.target.sector_size;
        const buffer = try self.allocator.alloc(u8, sector);
        defer self.allocator.free(buffer);
        var done: usize = 0;
        while (done < bytes.len) {
            const at = offset + done;
            if (at % sector == 0 and bytes.len - done >= sector) {
                var skip = at;
                for (self.descriptor.extents) |r| {
                    if (skip >= r.length) {
                        skip -= r.length;
                        continue;
                    }
                    const available = @min(r.length - skip, @min(bytes.len - done, 65536));
                    const n: usize = @intCast(available / sector * sector);
                    try self.disk.write(io, .{ .offset = r.offset + skip, .length = n }, bytes[done..][0..n]);
                    done += n;
                    break;
                }
                continue;
            }
            const start = at / sector * sector;
            const in_sector: usize = @intCast(at - start);
            const n = @min(bytes.len - done, sector - in_sector);
            try self.readLogical(io, start, buffer);
            @memcpy(buffer[in_sector..][0..n], bytes[done..][0..n]);
            var skip = start;
            for (self.descriptor.extents) |r| {
                if (skip >= r.length) {
                    skip -= r.length;
                    continue;
                }
                try self.disk.write(io, .{ .offset = r.offset + skip, .length = sector }, buffer);
                break;
            }
            done += n;
        }
    }
    fn cast(ctx: *anyopaque) *RawCapsule {
        return @ptrCast(@alignCast(ctx));
    }
    fn recordSlot(self: *RawCapsule, r: Record) *Slot {
        return &self.slots[@backingInt(r)];
    }
    fn reserve(ctx: *anyopaque, io: std.Io, r: Record, n: u64) !void {
        const self = cast(ctx);
        const s = self.recordSlot(r);
        if (!s.exists or n > s.capacity) return error.CapsuleCapacityExceeded;
        s.length = n;
        if (r == .state) {
            const zero = try self.allocator.alloc(u8, self.descriptor.block_size);
            defer self.allocator.free(zero);
            @memset(zero, 0);
            var at: u64 = 0;
            while (at < n) : (at += zero.len) try self.writeLogical(io, s.offset + at, zero[0..@intCast(@min(zero.len, n - at))]);
        }
    }
    fn blockSize(ctx: *anyopaque, _: std.Io) !u32 {
        return cast(ctx).descriptor.block_size;
    }
    fn exists(ctx: *anyopaque, _: std.Io, r: Record) !bool {
        return cast(ctx).recordSlot(r).exists;
    }
    fn size(ctx: *anyopaque, _: std.Io, r: Record) !u64 {
        const s = cast(ctx).recordSlot(r);
        if (!s.exists) return error.FileNotFound;
        return s.length;
    }
    fn create(ctx: *anyopaque, _: std.Io, r: Record, _: bool) !void {
        const s = cast(ctx).recordSlot(r);
        if (s.exists) return error.PathAlreadyExists;
        s.exists = true;
        s.length = 0;
    }
    fn readAt(ctx: *anyopaque, io: std.Io, r: Record, offset: u64, bytes: []u8) !usize {
        const self = cast(ctx);
        const s = self.recordSlot(r);
        if (!s.exists) return error.FileNotFound;
        const n: usize = @intCast(@min(bytes.len, s.length - @min(offset, s.length)));
        try self.readLogical(io, s.offset + @min(offset, s.length), bytes[0..n]);
        return n;
    }
    fn read(ctx: *anyopaque, io: std.Io, r: Record, a: std.mem.Allocator, max: usize) ![]u8 {
        const n = try size(ctx, io, r);
        if (n > max) return error.RecoveryRecordTooLarge;
        const bytes = try a.alloc(u8, @intCast(n));
        errdefer a.free(bytes);
        _ = try readAt(ctx, io, r, 0, bytes);
        return bytes;
    }
    fn writeAt(ctx: *anyopaque, io: std.Io, r: Record, offset: u64, bytes: []const u8) !void {
        const self = cast(ctx);
        const s = self.recordSlot(r);
        const end = try std.math.add(u64, offset, bytes.len);
        if (!s.exists or end > s.capacity) return error.CapsuleCapacityExceeded;
        try self.writeLogical(io, s.offset + offset, bytes);
        s.length = @max(s.length, end);
    }
    fn write(ctx: *anyopaque, io: std.Io, r: Record, bytes: []const u8) !void {
        return writeAt(ctx, io, r, try size(ctx, io, r), bytes);
    }
    fn syncFile(ctx: *anyopaque, io: std.Io, _: Record) !void {
        try cast(ctx).disk.flush(io);
    }
    fn publish(ctx: *anyopaque, io: std.Io, _: Record) !void {
        try cast(ctx).sync(io);
    }
    fn syncDirectory(ctx: *anyopaque, io: std.Io) !void {
        try cast(ctx).sync(io);
    }
    fn admitProgram(ctx: *anyopaque, p: @import("program.zig").Program, retained: bool) !void {
        const self = cast(ctx);
        try self.protects(p);
        const r = try @import("program_executor.zig").reservation(self.allocator, p, self.descriptor.block_size, retained);
        const needed = limitsFor(r, self.descriptor.block_size);
        for (needed, self.slots) |n, s| if (n > s.capacity) return error.CapsuleCapacityExceeded;
    }
    const VTABLE: recovery.Store.VTable = .{ .admit_program = admitProgram, .reserve = reserve, .block_size = blockSize, .exists = exists, .size = size, .read = read, .read_at = readAt, .create = create, .write = write, .write_at = writeAt, .sync_file = syncFile, .publish = publish, .sync_directory = syncDirectory };
};
fn aligned(n: u64, block: u32) !u64 {
    return (try std.math.add(u64, n, block - 1)) / block * block;
}
fn put(b: []u8, at: usize, n: u64) void {
    std.mem.writeInt(u64, b[at..][0..8], n, .little);
}
fn get(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}
