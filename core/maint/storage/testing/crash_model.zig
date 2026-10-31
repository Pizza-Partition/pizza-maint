//! SQLite-style volatile/durable VFS model for target bytes AND recovery files.
//! Successful sync is a persistence barrier. An unsynced recovery-file write
//! can damage its ENTIRE reported block, including unchanged, previously synced
//! bytes sharing that block. Names need a separate directory sync.
const std = @import("std");
const device = @import("../device.zig");
const model = @import("../model.zig");
const recovery = @import("../recovery_store.zig");

pub const Fault = enum { crash, io_once, io_sticky, full_once, full_sticky };
pub const Damage = enum { drop, reorder, tear, garbage };
const Write = struct { offset: usize, bytes: []u8 };
const File = struct {
    live: []u8 = &.{},
    stable: []u8 = &.{},
    created: bool = false,
    visible: bool = false,
    stable_visible: bool = false,
    dirty_start: ?usize = null,
    dirty_end: usize = 0,
};
pub const Machine = struct {
    allocator: std.mem.Allocator,
    target: model.Target,
    live: []u8,
    stable: []u8,
    pending: std.ArrayList(Write) = .empty,
    files: [recovery.RECORD_COUNT]File = @splat(.{}),
    log_block_bytes: u32 = recovery.DEFAULT_BLOCK_BYTES,
    events: usize = 0,
    fail_at: ?usize = null,
    fault: Fault = .crash,
    faulted: bool = false,
    powered_off: bool = false,
    seed: u64 = 1,
    lost: usize = 0,
    torn: usize = 0,
    corrupted: usize = 0,
    reordered: usize = 0,

    pub fn init(a: std.mem.Allocator, target: model.Target, baseline: []const u8) !Machine {
        if (baseline.len != target.capacity) return error.ModelGeometryMismatch;
        return .{ .allocator = a, .target = target, .live = try a.dupe(u8, baseline), .stable = try a.dupe(u8, baseline) };
    }
    /// Allocate each scenario in an arena, then discard it like a dead process.
    pub fn disk(self: *Machine) device.Device {
        return .{ .context = self, .target = self.target, .vtable = &.{ .reader = .{ .read = diskRead }, .write = diskWrite, .flush = diskSync, .validate = diskValidate } };
    }
    pub fn store(self: *Machine) recovery.Store {
        return .{ .context = self, .vtable = &VTABLE };
    }
    pub fn arm(self: *Machine, at: ?usize, fault: Fault) void {
        self.events = 0;
        self.fail_at = at;
        self.fault = fault;
        self.faulted = false;
        self.powered_off = false;
    }
    fn next(self: *Machine) u64 {
        self.seed = self.seed *% 6364136223846793005 +% 1442695040888963407;
        return self.seed;
    }
    fn tick(self: *Machine) !void {
        if (self.powered_off) return error.SimulatedPowerLoss;
        self.events += 1;
        if (self.fail_at) |at| if (self.events == at or (self.faulted and (self.fault == .io_sticky or self.fault == .full_sticky))) {
            self.faulted = true;
            switch (self.fault) {
                .crash => {
                    self.powered_off = true;
                    return error.SimulatedPowerLoss;
                },
                .io_once, .io_sticky => return error.InputOutput,
                .full_once, .full_sticky => return error.NoSpaceLeft,
            }
        };
    }
    fn cast(context: *anyopaque) *Machine {
        return @ptrCast(@alignCast(context));
    }
    fn constCast(context: *const anyopaque) *Machine {
        return @constCast(@as(*const Machine, @ptrCast(@alignCast(context))));
    }
    fn diskRead(context: *const anyopaque, _: std.Io, offset: u64, bytes: []u8) !void {
        const self = constCast(context);
        try self.tick();
        @memcpy(bytes, self.live[@intCast(offset)..][0..bytes.len]);
    }
    fn diskWrite(context: *anyopaque, _: std.Io, offset: u64, bytes: []const u8) !void {
        const self = cast(context);
        // Every sector boundary is also an enumerable crash/I/O-error point.
        var done: usize = 0;
        while (done < bytes.len) {
            try self.tick();
            const slice = bytes[done..][0..@min(bytes.len - done, self.target.sector_size)];
            try self.pending.append(self.allocator, .{ .offset = @intCast(offset + done), .bytes = try self.allocator.dupe(u8, slice) });
            @memcpy(self.live[@intCast(offset + done)..][0..slice.len], slice);
            done += slice.len;
        }
        try self.tick();
    }
    fn diskSync(context: *anyopaque, _: std.Io) !void {
        const self = cast(context);
        try self.tick();
        @memcpy(self.stable, self.live);
        self.pending.clearRetainingCapacity();
        try self.tick();
    }
    fn diskValidate(context: *const anyopaque, _: std.Io, target: model.Target) !void {
        const self = constCast(context);
        try self.tick();
        if (!self.target.same(target)) return error.ModelGeometryMismatch;
    }
    fn exists(context: *anyopaque, _: std.Io, record: recovery.Record) !bool {
        const self = cast(context);
        try self.tick();
        return self.files[@backingInt(record)].visible;
    }
    fn blockSize(context: *anyopaque, _: std.Io) !u32 {
        const self = cast(context);
        try self.tick();
        return self.log_block_bytes;
    }
    fn size(context: *anyopaque, _: std.Io, record: recovery.Record) !u64 {
        const self = cast(context);
        try self.tick();
        const file = self.files[@backingInt(record)];
        if (!file.visible) return error.FileNotFound;
        return file.live.len;
    }
    fn readAt(context: *anyopaque, _: std.Io, record: recovery.Record, offset: u64, bytes: []u8) !usize {
        const self = cast(context);
        try self.tick();
        const file = self.files[@backingInt(record)];
        if (!file.visible) return error.FileNotFound;
        const start: usize = @intCast(@min(offset, file.live.len));
        const length = @min(bytes.len, file.live.len - start);
        @memcpy(bytes[0..length], file.live[start..][0..length]);
        return length;
    }
    fn dirty(self: *Machine, file: *File, start: usize, end: usize) void {
        const block: usize = self.log_block_bytes;
        const first = start / block * block;
        file.dirty_start = @min(file.dirty_start orelse first, first);
        file.dirty_end = @max(file.dirty_end, std.mem.alignForward(usize, end, block));
    }
    fn read(context: *anyopaque, _: std.Io, record: recovery.Record, a: std.mem.Allocator, max: usize) ![]u8 {
        const self = cast(context);
        try self.tick();
        const file = self.files[@backingInt(record)];
        if (!file.visible) return error.FileNotFound;
        if (file.live.len > max) return error.RecoveryRecordTooLarge;
        return a.dupe(u8, file.live);
    }
    fn create(context: *anyopaque, _: std.Io, record: recovery.Record, atomic: bool) !void {
        const self = cast(context);
        try self.tick();
        const file = &self.files[@backingInt(record)];
        if (file.created) return error.PathAlreadyExists;
        file.* = .{ .created = true, .visible = !atomic };
        try self.tick();
    }
    fn write(context: *anyopaque, _: std.Io, record: recovery.Record, bytes: []const u8) !void {
        const self = cast(context);
        const file = &self.files[@backingInt(record)];
        const live = try self.allocator.alloc(u8, bytes.len);
        var done: usize = 0;
        while (done < bytes.len) {
            try self.tick();
            const end = @min(bytes.len, done + 512);
            @memcpy(live[done..end], bytes[done..end]);
            file.live = live[0..end];
            self.dirty(file, done, end);
            done = end;
        }
        try self.tick();
    }
    fn syncFile(context: *anyopaque, _: std.Io, record: recovery.Record) !void {
        const self = cast(context);
        try self.tick();
        const file = &self.files[@backingInt(record)];
        file.stable = try self.allocator.dupe(u8, file.live);
        file.dirty_start = null;
        file.dirty_end = 0;
        try self.tick();
    }
    fn writeAt(context: *anyopaque, _: std.Io, record: recovery.Record, offset: u64, bytes: []const u8) !void {
        const self = cast(context);
        const file = &self.files[@backingInt(record)];
        const start: usize = @intCast(offset);
        const live = try self.allocator.alloc(u8, @max(file.live.len, start + bytes.len));
        @memset(live, 0);
        @memcpy(live[0..file.live.len], file.live);
        var done: usize = 0;
        while (done < bytes.len) {
            try self.tick();
            const end = @min(bytes.len, done + 512);
            @memcpy(live[start + done .. start + end], bytes[done..end]);
            file.live = live;
            self.dirty(file, start + done, start + end);
            done = end;
        }
        try self.tick();
    }
    fn publish(context: *anyopaque, _: std.Io, record: recovery.Record) !void {
        const self = cast(context);
        try self.tick();
        self.files[@backingInt(record)].visible = true;
        try self.tick();
    }
    fn syncDirectory(context: *anyopaque, _: std.Io) !void {
        const self = cast(context);
        try self.tick();
        for (&self.files) |*file| file.stable_visible = file.visible;
        try self.tick();
    }
    fn reserve(context: *anyopaque, io: std.Io, record: recovery.Record, bytes: u64) !void {
        const self = cast(context);
        const empty = try self.allocator.alloc(u8, std.math.cast(usize, bytes) orelse return error.NoSpaceLeft);
        @memset(empty, 0);
        try write(context, io, record, empty);
        try syncFile(context, io, record);
    }
    const VTABLE: recovery.Store.VTable = .{ .reserve = reserve, .block_size = blockSize, .exists = exists, .size = size, .read = read, .read_at = readAt, .create = create, .write = write, .write_at = writeAt, .sync_file = syncFile, .publish = publish, .sync_directory = syncDirectory };

    /// Forget process state and unprotected cache. Synced bytes are protected
    /// only if no pending write shares their block. Unsynced names may disappear.
    pub fn powerLoss(self: *Machine, seed: u64, damage: Damage) !void {
        self.seed = seed;
        if (damage != .drop) {
            // Shuffle pending writes before choosing which reach stable media.
            var remaining = self.pending.items.len;
            while (remaining > 1) : (remaining -= 1) {
                const pick: usize = @intCast(self.next() % remaining);
                std.mem.swap(Write, &self.pending.items[pick], &self.pending.items[remaining - 1]);
                self.reordered += 1;
            }
        }
        for (self.pending.items) |pending| {
            if (damage == .drop or self.next() % 3 == 0) {
                self.lost += 1;
                continue;
            }
            const output = self.stable[pending.offset..][0..pending.bytes.len];
            switch (damage) {
                .drop => unreachable,
                .reorder => @memcpy(output, pending.bytes),
                .tear => {
                    const length: usize = @intCast(1 + self.next() % pending.bytes.len);
                    @memcpy(output[0..length], pending.bytes[0..length]);
                    self.torn += 1;
                },
                .garbage => {
                    for (output) |*byte| byte.* = @truncate(self.next() >> 32);
                    self.corrupted += 1;
                },
            }
        }
        self.pending.clearRetainingCapacity();
        @memcpy(self.live, self.stable);
        for (&self.files) |*file| {
            var bytes = file.stable;
            if (file.dirty_start) |start| if (damage != .drop and file.visible) {
                bytes = try self.allocator.dupe(u8, file.live);
                const end = @min(file.dirty_end, bytes.len);
                switch (damage) {
                    .drop => unreachable,
                    .reorder => {}, // The pending file write may survive intact.
                    .tear => {
                        const cut = start + @as(usize, @intCast(self.next() % (end - start)));
                        for (bytes[cut..end], cut..) |*byte, i| byte.* = if (i < file.stable.len) file.stable[i] else @truncate(self.next() >> 32);
                    },
                    .garbage => {
                        for (bytes[start..end]) |*byte| byte.* = @truncate(self.next() >> 32);
                        self.corrupted += 1;
                    },
                }
            };
            const visible = file.stable_visible or (file.visible and self.next() % 2 == 0);
            file.* = .{ .created = visible, .visible = visible, .stable_visible = visible, .stable = bytes, .live = bytes };
        }
        self.arm(null, .crash);
    }
};
