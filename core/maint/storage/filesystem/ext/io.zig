//! libext2fs reads through Reader and writes only to an in-memory overlay.
//! The library never obtains a mutable handle to the original device.
const std = @import("std");
pub const c_api = @import("ext2fs_c");
const Reader = @import("../../device.zig").Reader;
const Builder = @import("../../mutation.zig").Builder;

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: Reader,
    fs: c_api.ext2_filsys = null,
    channel: c_api.struct_io_channel,
    name: [:0]u8,
    failure: ?anyerror = null,
    overlay: ?*Builder = null,

    pub fn open(a: std.mem.Allocator, io: std.Io, reader: Reader) !*Session {
        return openMode(a, io, reader, null);
    }

    pub fn openStaged(a: std.mem.Allocator, io: std.Io, overlay: *Builder) !*Session {
        return openMode(a, io, overlay.reader(), overlay);
    }

    fn openMode(a: std.mem.Allocator, io: std.Io, reader: Reader, overlay: ?*Builder) !*Session {
        try reader.target.validate();
        try preflight(io, reader);
        const self = try allocate(a, io, reader, overlay);
        errdefer self.close();
        const flags: c_int = c_api.EXT2_FLAG_64BITS | (if (overlay != null) @as(c_int, c_api.EXT2_FLAG_RW) else 0);
        try self.check(c_api.ext2fs_open2(self.name, null, flags, 0, 0, &manager, &self.fs));
        return self;
    }

    fn allocate(a: std.mem.Allocator, io: std.Io, reader: Reader, overlay: ?*Builder) !*Session {
        const self = try a.create(Session);
        errdefer a.destroy(self);
        const label = try a.print("pizza-reader:{x}", .{@intFromPtr(self)});
        defer a.free(label);
        const name = try a.dupeSentinel(u8, label, 0);
        errdefer a.free(name);
        self.* = .{ .allocator = a, .io = io, .reader = reader, .channel = std.mem.zeroes(c_api.struct_io_channel), .name = name, .overlay = overlay };
        self.channel.magic = c_api.EXT2_ET_MAGIC_IO_CHANNEL;
        self.channel.manager = &manager;
        self.channel.name = name.ptr;
        self.channel.block_size = 1024;
        self.channel.refcount = 1;
        self.channel.flags = c_api.CHANNEL_FLAGS_NODISCARD | c_api.CHANNEL_FLAGS_NOZEROOUT;
        self.channel.private_data = self;
        return self;
    }

    pub fn close(self: *Session) void {
        // Free directly: a read-only inspection must never flush filesystem
        // metadata as ext2fs_close() can do for dirty library state.
        if (self.fs != null) c_api.ext2fs_free(self.fs);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn check(self: *Session, result: c_api.errcode_t) !void {
        if (self.failure) |err| return err;
        if (result == 0) return;
        return switch (result) {
            c_api.EXT2_ET_BAD_MAGIC => error.ExtInvalidMagic,
            c_api.EXT2_ET_REV_TOO_HIGH => error.ExtUnsupportedRevision,
            c_api.EXT2_ET_UNSUPP_FEATURE, c_api.EXT2_ET_RO_UNSUPP_FEATURE => error.ExtUnsupportedFeature,
            c_api.EXT2_ET_UNKNOWN_CSUM => error.ExtUnsupportedChecksum,
            c_api.EXT2_ET_SB_CSUM_INVALID => error.ExtSuperblockChecksum,
            c_api.EXT2_ET_BLOCK_BITMAP_CSUM_INVALID => error.ExtBlockBitmapChecksum,
            c_api.EXT2_ET_INODE_BITMAP_CSUM_INVALID => error.ExtInodeBitmapChecksum,
            c_api.EXT2_ET_GDESC_BAD_BLOCK_MAP, c_api.EXT2_ET_GDESC_BAD_INODE_MAP, c_api.EXT2_ET_GDESC_BAD_INODE_TABLE => error.ExtInvalidDescriptor,
            c_api.EXT2_ET_CORRUPT_SUPERBLOCK, c_api.EXT2_ET_BAD_DESC_SIZE, c_api.EXT2_ET_UNEXPECTED_BLOCK_SIZE => error.ExtInvalidGeometry,
            c_api.EXT2_ET_NO_MEMORY => error.OutOfMemory,
            c_api.EXT2_ET_RO_FILSYS => error.ExtWriteDenied,
            else => error.ExtLibraryFailure,
        };
    }
};

fn preflight(io: std.Io, reader: Reader) !void {
    if (reader.target.capacity < 2048) return error.ExtInvalidGeometry;
    var raw: [1024]u8 = undefined;
    try reader.readInto(io, 1024, &raw);
    if (std.mem.readInt(u16, raw[0x38..0x3A], .little) != c_api.EXT2_SUPER_MAGIC) return error.ExtInvalidMagic;
    const log = std.mem.readInt(u32, raw[0x18..0x1C], .little);
    if (log > 6) return error.ExtInvalidGeometry;
    const size: u64 = @as(u64, 1024) << @intCast(log);
    var blocks: u64 = std.mem.readInt(u32, raw[4..8], .little);
    const wide = std.mem.readInt(u32, raw[0x60..0x64], .little) & c_api.EXT4_FEATURE_INCOMPAT_64BIT != 0;
    if (wide) blocks |= @as(u64, std.mem.readInt(u32, raw[0x150..0x154], .little)) << 32;
    const first = std.mem.readInt(u32, raw[0x14..0x18], .little);
    const bpg = std.mem.readInt(u32, raw[0x20..0x24], .little);
    if (blocks <= first or blocks > reader.target.capacity / size or bpg == 0) return error.ExtInvalidGeometry;
    const groups = std.math.divCeil(u64, blocks - first, bpg) catch unreachable;
    const descriptor: u64 = if (wide) std.mem.readInt(u16, raw[0xFE..0x100], .little) else 32;
    if (descriptor < 32 or descriptor > size or groups > (64 * 1024 * 1024) / descriptor) return error.ExtScanBudgetExceeded;
}

var manager: c_api.struct_io_manager = init: {
    var value = std.mem.zeroes(c_api.struct_io_manager);
    value.magic = c_api.EXT2_ET_MAGIC_IO_MANAGER;
    value.name = "pizza-reader";
    value.open = open;
    value.close = close;
    value.set_blksize = setBlockSize;
    value.read_blk = read;
    value.read_blk64 = read64;
    value.write_blk = write;
    value.write_blk64 = write64;
    value.write_byte = writeByte;
    value.discard = denyRange;
    value.zeroout = zeroRange;
    value.flush = flush;
    break :init value;
};

fn session(channel: c_api.io_channel) *Session {
    return @ptrCast(@alignCast(channel.*.private_data.?));
}

fn open(name: [*c]const u8, flags: c_int, out: [*c]c_api.io_channel) callconv(.c) c_api.errcode_t {
    if (name == null or out == null) return c_api.EXT2_ET_BAD_DEVICE_NAME;
    const text = std.mem.span(name);
    const prefix = "pizza-reader:";
    if (!std.mem.startsWith(u8, text, prefix)) return c_api.EXT2_ET_BAD_DEVICE_NAME;
    const address = std.fmt.parseInt(usize, text[prefix.len..], 16) catch return c_api.EXT2_ET_BAD_DEVICE_NAME;
    if (address == 0 or address % @alignOf(Session) != 0) return c_api.EXT2_ET_BAD_DEVICE_NAME;
    const self: *Session = @ptrFromInt(address);
    if (flags & c_api.IO_FLAG_RW != 0 and self.overlay == null) return c_api.EXT2_ET_RO_FILSYS;
    out.* = &self.channel;
    return 0;
}

fn close(channel: c_api.io_channel) callconv(.c) c_api.errcode_t {
    if (channel.*.refcount > 0) channel.*.refcount -= 1;
    return 0;
}

fn setBlockSize(channel: c_api.io_channel, size: c_int) callconv(.c) c_api.errcode_t {
    if (size < 1024 or size > 65536 or !std.math.isPowerOfTwo(@as(u32, @intCast(size)))) return c_api.EXT2_ET_UNEXPECTED_BLOCK_SIZE;
    channel.*.block_size = size;
    return 0;
}

fn read(channel: c_api.io_channel, block: c_ulong, count: c_int, data: ?*anyopaque) callconv(.c) c_api.errcode_t {
    return read64(channel, block, count, data);
}

fn read64(channel: c_api.io_channel, block: c_ulonglong, count: c_int, data: ?*anyopaque) callconv(.c) c_api.errcode_t {
    const self = session(channel);
    readBytes(self, block, count, data) catch |err| {
        if (self.failure == null) self.failure = err;
        return c_api.EXT2_ET_SHORT_READ;
    };
    return 0;
}

fn readBytes(self: *Session, block: u64, count: c_int, data: ?*anyopaque) !void {
    const size: u64 = @intCast(self.channel.block_size);
    const offset = std.math.mul(u64, block, size) catch return error.RangeOverflow;
    // libext2fs uses negative count for a byte count, positive for blocks.
    const length: u64 = if (count < 0) @intCast(-@as(i64, count)) else std.math.mul(u64, @intCast(count), size) catch return error.RangeOverflow;
    if (length == 0) return;
    const pointer: [*]u8 = @ptrCast(data orelse return error.ExtInvalidIoBuffer);
    if (length > std.math.maxInt(usize)) return error.RangeOverflow;
    try self.reader.readInto(self.io, offset, pointer[0..@intCast(length)]);
}

fn write(channel: c_api.io_channel, block: c_ulong, count: c_int, data: ?*const anyopaque) callconv(.c) c_api.errcode_t {
    return write64(channel, block, count, data);
}

fn write64(channel: c_api.io_channel, block: c_ulonglong, count: c_int, data: ?*const anyopaque) callconv(.c) c_api.errcode_t {
    const self = session(channel);
    if (self.overlay == null) return denied(channel);
    const size: u64 = @intCast(channel.*.block_size);
    const offset = std.math.mul(u64, block, size) catch {
        self.failure = error.RangeOverflow;
        return c_api.EXT2_ET_SHORT_WRITE;
    };
    const length: u64 = if (count < 0) @intCast(-@as(i64, count)) else std.math.mul(u64, @intCast(count), size) catch return c_api.EXT2_ET_SHORT_WRITE;
    return writeBytes(self, offset, length, data);
}

fn writeByte(channel: c_api.io_channel, offset: c_ulong, count: c_int, data: ?*const anyopaque) callconv(.c) c_api.errcode_t {
    if (count < 0) return c_api.EXT2_ET_INVALID_ARGUMENT;
    return writeBytes(session(channel), offset, @intCast(count), data);
}

fn writeBytes(self: *Session, offset: u64, length: u64, data: ?*const anyopaque) c_api.errcode_t {
    const overlay = self.overlay orelse return denied(&self.channel);
    if (length == 0) return 0;
    const pointer: [*]const u8 = @ptrCast(data orelse return c_api.EXT2_ET_INVALID_ARGUMENT);
    if (length > std.math.maxInt(usize)) return c_api.EXT2_ET_SHORT_WRITE;
    overlay.stageWrite(self.io, offset, pointer[0..@intCast(length)]) catch |err| {
        if (self.failure == null) self.failure = err;
        return c_api.EXT2_ET_SHORT_WRITE;
    };
    return 0;
}

fn denyRange(channel: c_api.io_channel, _: c_ulonglong, _: c_ulonglong) callconv(.c) c_api.errcode_t {
    // No destructive range operation is forwarded. Staged sessions advertise
    // an unsupported acceleration so libext2fs falls back to protected writes.
    if (session(channel).overlay != null) return c_api.EXT2_ET_UNIMPLEMENTED;
    return denied(channel);
}

fn zeroRange(channel: c_api.io_channel, block: c_ulonglong, count: c_ulonglong) callconv(.c) c_api.errcode_t {
    const self = session(channel);
    if (self.overlay == null) return denied(channel);
    zeroBytes(self, block, count) catch |err| {
        if (self.failure == null) self.failure = err;
        return c_api.EXT2_ET_SHORT_WRITE;
    };
    return 0;
}

fn zeroBytes(self: *Session, block: u64, count: u64) !void {
    const size: u64 = @intCast(self.channel.block_size);
    var offset = std.math.mul(u64, block, size) catch return error.RangeOverflow;
    var left = std.math.mul(u64, count, size) catch return error.RangeOverflow;
    const end = std.math.add(u64, offset, left) catch return error.RangeOverflow;
    if (end > self.reader.target.capacity) return error.RangeOutsideDevice;
    const zeros: [64 * 1024]u8 = @splat(0);
    while (left != 0) {
        const length: usize = @intCast(@min(left, zeros.len));
        try self.overlay.?.stageWrite(self.io, offset, zeros[0..length]);
        offset += length;
        left -= length;
    }
}

fn denied(channel: c_api.io_channel) c_api.errcode_t {
    const self = session(channel);
    if (self.failure == null) self.failure = error.ExtWriteDenied;
    return c_api.EXT2_ET_RO_FILSYS;
}

fn flush(_: c_api.io_channel) callconv(.c) c_api.errcode_t {
    return 0; // Staged writes become durable only through program_executor.
}
