//! Every libntfs device operation stays inside a locked, bounded arena session.
const std = @import("std");
pub const c_api = @import("ntfs_c");
const Reader = @import("../../device.zig").Reader;
const Builder = @import("../../mutation.zig").Builder;
const format = @import("format.zig");
extern "c" fn __errno_location() *c_int;
extern "c" fn pizza_ntfs_mount_core(c_int) ?*c_api.ntfs_volume;
extern "c" fn pizza_ntfs_close_core(*c_api.ntfs_volume) c_int;
extern "c" fn pizza_ntfs_health_core(*c_api.ntfs_volume) c_int;
extern "c" fn pizza_ntfs_restore_flags_core(*c_api.ntfs_volume, u16) c_int;
var mutex: std.Io.Mutex = .init;
var current: ?*Session = null;
pub const Session = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    reader: Reader,
    overlay: ?*Builder,
    volume: ?*c_api.ntfs_volume = null,
    failure: ?anyerror = null,
    allocated: usize = 0,
    position: i64 = 0,
    pub fn start(a: std.mem.Allocator, io: std.Io, reader: Reader, overlay: ?*Builder) !*Session {
        try reader.target.validate();
        if (reader.target.capacity > std.math.maxInt(i64)) return error.NtfsInvalidGeometry;
        try mutex.lock(io);
        errdefer mutex.unlock(io);
        const self = try a.create(Session);
        self.* = .{ .allocator = a, .arena = .init(a), .io = io, .reader = reader, .overlay = overlay };
        current = self;
        return self;
    }
    pub fn open(a: std.mem.Allocator, io: std.Io, reader: Reader, overlay: ?*Builder) !*Session {
        const g = try format.load(io, reader);
        try g.budget();
        const self = try start(a, io, reader, overlay);
        errdefer self.close();
        self.volume = pizza_ntfs_mount_core(if (overlay != null) 1 else 0);
        if (self.failure) |err| return err;
        if (self.volume == null) return error.NtfsInvalidMetadata;
        const v = self.volume.?;
        if (v.major_ver != 3 or v.minor_ver > 1) return error.NtfsUnsupportedVersion;
        if (v.mft_na.*.initialized_size < 0 or v.mft_na.*.initialized_size > 64 * 1024 * 1024) return error.NtfsResourceLimit;
        return self;
    }
    pub fn close(self: *Session) void {
        // All C allocations, including those bypassed by a core error, are
        // reclaimed together. No C handle ever owns a host file descriptor.
        if (self.volume) |v| _ = pizza_ntfs_close_core(v);
        current = null;
        const io = self.io;
        const a = self.allocator;
        self.arena.deinit();
        a.destroy(self);
        mutex.unlock(io);
    }
    pub fn finish(self: *Session) !void {
        if (self.volume) |v| {
            self.volume = null;
            try self.check(pizza_ntfs_close_core(v));
        }
        if (self.failure) |err| return err;
    }
    pub fn check(self: *Session, result: c_int) !void {
        if (self.failure) |err| return err;
        if (result != 0 and __errno_location().* == 30) return error.NtfsWriteDenied;
        if (result != 0) return error.NtfsInvalidMetadata;
    }
    pub fn health(self: *Session) !void {
        const v = self.volume.?;
        const result = pizza_ntfs_health_core(v);
        if (self.failure) |err| return err;
        if (result == -2) return error.NtfsHibernated;
        if (result != 0) return error.NtfsJournalRecoveryRequired;
        if (v.flags != 0) return error.NtfsRecoveryRequired;
    }
    pub fn restoreFlags(self: *Session, flags: u16) !void {
        try self.check(pizza_ntfs_restore_flags_core(self.volume.?, flags));
    }
};
fn fail(self: *Session, err: anyerror) c_int {
    if (self.failure == null) self.failure = err;
    __errno_location().* = 5;
    return -1;
}

fn active(dev: [*c]c_api.struct_ntfs_device) ?*Session {
    if (current == null or dev == null) return null;
    return current;
}
fn openDevice(dev: [*c]c_api.struct_ntfs_device, flags: c_int) callconv(.c) c_int {
    const self = active(dev) orelse return -1;
    if (self.overlay == null and flags & 3 != 0) return fail(self, error.NtfsWriteDenied);
    dev.*.d_private = self;
    dev.*.d_state = 1 | (if (flags & 3 == 0) @as(c_ulong, 2) else 0);
    self.position = 0;
    return 0;
}
fn closeDevice(dev: [*c]c_api.struct_ntfs_device) callconv(.c) c_int {
    dev.*.d_state = 0;
    return 0;
}
fn seek(dev: [*c]c_api.struct_ntfs_device, offset: i64, whence: c_int) callconv(.c) i64 {
    const self = active(dev) orelse return -1;
    const base: i64 = switch (whence) {
        0 => 0,
        1 => self.position,
        2 => @intCast(self.reader.target.capacity),
        else => return fail(self, error.NtfsInvalidSeek),
    };
    const end = std.math.add(i64, base, offset) catch return fail(self, error.RangeOverflow);
    if (end < 0 or end > self.reader.target.capacity) return fail(self, error.RangeOutsideDevice);
    self.position = end;
    return end;
}
fn pread(dev: [*c]c_api.struct_ntfs_device, data: ?*anyopaque, count: i64, offset: i64) callconv(.c) i64 {
    const self = active(dev) orelse return -1;
    if (data == null or count < 0 or offset < 0) return fail(self, error.NtfsInvalidIo);
    // End-of-device reads are permitted while detecting capacity; a short read
    // must never be used by the format scanner as proof of complete metadata.
    if (offset >= self.reader.target.capacity) return 0;
    const length: usize = @intCast(@min(@as(u64, @intCast(count)), self.reader.target.capacity - @as(u64, @intCast(offset))));
    self.reader.readInto(self.io, @intCast(offset), @as([*]u8, @ptrCast(data.?))[0..length]) catch |err| return fail(self, err);
    return @intCast(length);
}
fn pwrite(dev: [*c]c_api.struct_ntfs_device, data: ?*const anyopaque, count: i64, offset: i64) callconv(.c) i64 {
    const self = active(dev) orelse return -1;
    const overlay = self.overlay orelse return fail(self, error.NtfsWriteDenied);
    if (data == null or count < 0 or offset < 0) return fail(self, error.NtfsInvalidIo);
    overlay.stageWrite(self.io, @intCast(offset), @as([*]const u8, @ptrCast(data.?))[0..@intCast(count)]) catch |err| return fail(self, err);
    return count;
}
fn read(dev: [*c]c_api.struct_ntfs_device, data: ?*anyopaque, count: i64) callconv(.c) i64 {
    const self = active(dev) orelse return -1;
    const n = pread(dev, data, count, self.position);
    if (n > 0) self.position += n;
    return n;
}
fn write(dev: [*c]c_api.struct_ntfs_device, data: ?*const anyopaque, count: i64) callconv(.c) i64 {
    const self = active(dev) orelse return -1;
    const n = pwrite(dev, data, count, self.position);
    if (n > 0) self.position += n;
    return n;
}
fn sync(_: [*c]c_api.struct_ntfs_device) callconv(.c) c_int {
    return 0;
}
// stat and ioctl are described in C to use the target's exact libc layouts.
extern "c" fn pizza_ntfs_stat([*c]c_api.struct_ntfs_device, ?*c_api.struct_stat) c_int;
extern "c" fn pizza_ntfs_ioctl([*c]c_api.struct_ntfs_device, c_ulong, ?*anyopaque) c_int;
export var ntfs_device_unix_io_ops: c_api.struct_ntfs_device_operations = .{ .open = openDevice, .close = closeDevice, .seek = seek, .read = read, .write = write, .pread = pread, .pwrite = pwrite, .sync = sync, .stat = pizza_ntfs_stat, .ioctl = pizza_ntfs_ioctl };
export fn pizza_ntfs_capacity() callconv(.c) u64 {
    return if (current) |s| s.reader.target.capacity else 0;
}
export fn pizza_ntfs_sector() callconv(.c) u32 {
    return if (current) |s| s.reader.target.sector_size else 512;
}
// Private C allocation ABI: no allocation survives the session, including
// local variables skipped by the C-only setjmp error boundary.
export fn pizza_ntfs_malloc(size: usize) callconv(.c) ?*anyopaque {
    const self = current orelse return null;
    const charge = std.math.add(usize, size, 31) catch {
        _ = fail(self, error.OutOfMemory);
        return null;
    };
    if (charge > 256 * 1024 * 1024 -| self.allocated) {
        _ = fail(self, error.NtfsResourceLimit);
        return null;
    }
    const length = std.math.add(usize, size, 16) catch {
        _ = fail(self, error.OutOfMemory);
        return null;
    };
    const bytes = self.arena.allocator().alignedAlloc(u8, .@"16", length) catch {
        _ = fail(self, error.OutOfMemory);
        return null;
    };
    @as(*usize, @ptrCast(bytes.ptr)).* = size;
    self.allocated += charge;
    return bytes.ptr + 16;
}
export fn pizza_ntfs_calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const length = std.math.mul(usize, count, size) catch {
        if (current) |self| _ = fail(self, error.OutOfMemory);
        return null;
    };
    const p = pizza_ntfs_malloc(length) orelse return null;
    @memset(@as([*]u8, @ptrCast(p))[0..length], 0);
    return p;
}
export fn pizza_ntfs_free(_: ?*anyopaque) callconv(.c) void {}
export fn pizza_ntfs_realloc(old: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const p = pizza_ntfs_malloc(size) orelse return null;
    if (old) |ptr| {
        const bytes: [*]u8 = @ptrCast(ptr);
        const len = @as(*align(1) const usize, @ptrCast(bytes - 16)).*;
        @memcpy(@as([*]u8, @ptrCast(p))[0..@min(size, len)], bytes[0..@min(size, len)]);
    }
    return p;
}
export fn pizza_ntfs_strdup(text: [*c]const u8) callconv(.c) ?[*:0]u8 {
    if (text == null) return null;
    const bytes = std.mem.span(text);
    const p = pizza_ntfs_malloc(bytes.len + 1) orelse return null;
    const out: [*]u8 = @ptrCast(p);
    @memcpy(out[0..bytes.len], bytes);
    out[bytes.len] = 0;
    return out[0..bytes.len :0].ptr;
}
