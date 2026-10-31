//! The recovery protocol's file operations. Keeping file sync, publication and
//! directory sync separate lets crash tests model their actual durability.
const std = @import("std");
pub const DEFAULT_BLOCK_BYTES = 4096;
pub const MAX_BLOCK_BYTES = 1024 * 1024;

pub fn validateBlockSize(bytes: u32) !void {
    if (bytes < DEFAULT_BLOCK_BYTES or bytes > MAX_BLOCK_BYTES or !std.math.isPowerOfTwo(bytes))
        return error.InvalidRecoveryBlockSize;
}
pub const Record = enum { ready, commit, restored, program, snapshots, scratch, state, retained, verified, undo };
pub const RECORD_COUNT = std.enums.values(Record).len;
pub fn name(record: Record) []const u8 {
    return @tagName(record);
}

pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        admit_program: ?*const fn (*anyopaque, @import("program.zig").Program, bool) anyerror!void = null,
        reserve: ?*const fn (*anyopaque, std.Io, Record, u64) anyerror!void = null,
        block_size: *const fn (*anyopaque, std.Io) anyerror!u32,
        exists: *const fn (*anyopaque, std.Io, Record) anyerror!bool,
        size: *const fn (*anyopaque, std.Io, Record) anyerror!u64,
        read: *const fn (*anyopaque, std.Io, Record, std.mem.Allocator, usize) anyerror![]u8,
        read_at: *const fn (*anyopaque, std.Io, Record, u64, []u8) anyerror!usize,
        create: *const fn (*anyopaque, std.Io, Record, bool) anyerror!void,
        write: *const fn (*anyopaque, std.Io, Record, []const u8) anyerror!void,
        write_at: *const fn (*anyopaque, std.Io, Record, u64, []const u8) anyerror!void,
        sync_file: *const fn (*anyopaque, std.Io, Record) anyerror!void,
        publish: *const fn (*anyopaque, std.Io, Record) anyerror!void,
        sync_directory: *const fn (*anyopaque, std.Io) anyerror!void,
    };

    /// Reserve real backing space, not merely a sparse logical file length.
    pub fn reserve(self: Store, io: std.Io, record: Record, bytes: u64) !void {
        if (bytes == 0) return;
        const reserve_fn = self.vtable.reserve orelse return error.RecoveryReservationUnsupported;
        try reserve_fn(self.context, io, record, bytes);
    }

    pub fn blockSize(self: Store, io: std.Io) !u32 {
        const bytes = try self.vtable.block_size(self.context, io);
        try validateBlockSize(bytes);
        return bytes;
    }
    pub fn size(self: Store, io: std.Io, record: Record) !u64 {
        return self.vtable.size(self.context, io, record);
    }
    pub fn readAt(self: Store, io: std.Io, record: Record, offset: u64, bytes: []u8) !usize {
        return self.vtable.read_at(self.context, io, record, offset, bytes);
    }
    pub fn exists(self: Store, io: std.Io, record: Record) !bool {
        return self.vtable.exists(self.context, io, record);
    }
    pub fn read(self: Store, io: std.Io, record: Record, a: std.mem.Allocator, max: usize) ![]u8 {
        return self.vtable.read(self.context, io, record, a, max);
    }
    pub fn create(self: Store, io: std.Io, record: Record, atomic: bool) !void {
        return self.vtable.create(self.context, io, record, atomic);
    }
    pub fn write(self: Store, io: std.Io, record: Record, bytes: []const u8) !void {
        return self.vtable.write(self.context, io, record, bytes);
    }
    pub fn writeAt(self: Store, io: std.Io, record: Record, offset: u64, bytes: []const u8) !void {
        return self.vtable.write_at(self.context, io, record, offset, bytes);
    }
    pub fn syncFile(self: Store, io: std.Io, record: Record) !void {
        return self.vtable.sync_file(self.context, io, record);
    }
    pub fn publish(self: Store, io: std.Io, record: Record) !void {
        return self.vtable.publish(self.context, io, record);
    }
    pub fn syncDirectory(self: Store, io: std.Io) !void {
        return self.vtable.sync_directory(self.context, io);
    }
};

pub const Files = struct {
    directory: std.Io.Dir,
    /// A policy floor, not a claim about the hardware's power-loss radius.
    minimum_block_bytes: u32 = DEFAULT_BLOCK_BYTES,
    slots: [RECORD_COUNT]Slot = @splat(.none),
    const Slot = union(enum) { none, file: std.Io.File, atomic: std.Io.File.Atomic };
    pub fn store(self: *Files) Store {
        return .{ .context = self, .vtable = &VTABLE };
    }
    pub fn deinit(self: *Files, io: std.Io) void {
        for (&self.slots) |*slot| switch (slot.*) {
            .none => {},
            .file => |file| file.close(io),
            .atomic => |*atomic| atomic.deinit(io),
        };
        self.* = undefined;
    }
    fn cast(context: *anyopaque) *Files {
        return @ptrCast(@alignCast(context));
    }
    fn blockSize(context: *anyopaque, io: std.Io) !u32 {
        const self = cast(context);
        var bytes = @max(self.minimum_block_bytes, (try self.directory.stat(io)).block_size);
        // A file's st_blksize is an I/O hint. When sysfs identifies its backing
        // device, also honor the reported physical block size. Some filesystems
        // (e.g. multi-device Btrfs) use synthetic device IDs, so this is best effort.
        if (@import("builtin").os.tag == .linux) {
            const linux = std.os.linux;
            var stat: linux.Statx = undefined;
            if (linux.errno(linux.statx(self.directory.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat)) == .SUCCESS) {
                var path_buffer: [160]u8 = undefined;
                for ([_][]const u8{ "queue/physical_block_size", "../queue/physical_block_size" }) |suffix| {
                    const path = try std.fmt.bufPrint(&path_buffer, "/sys/dev/block/{d}:{d}/{s}", .{ stat.dev_major, stat.dev_minor, suffix });
                    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
                        error.FileNotFound, error.AccessDenied => continue,
                        else => return err,
                    };
                    defer file.close(io);
                    var buffer: [32]u8 = undefined;
                    const length = try file.readPositionalAll(io, &buffer, 0);
                    bytes = @max(bytes, try std.fmt.parseInt(u32, std.mem.trim(u8, buffer[0..length], " \r\n\t"), 10));
                    break;
                }
            }
        }
        try validateBlockSize(bytes);
        return bytes;
    }
    fn size(context: *anyopaque, io: std.Io, record: Record) !u64 {
        const file = try cast(context).directory.openFile(io, name(record), .{ .follow_symlinks = false });
        defer file.close(io);
        return (try file.stat(io)).size;
    }
    fn readAt(context: *anyopaque, io: std.Io, record: Record, offset: u64, bytes: []u8) !usize {
        const file = try cast(context).directory.openFile(io, name(record), .{ .follow_symlinks = false });
        defer file.close(io);
        return file.readPositionalAll(io, bytes, offset);
    }
    fn exists(context: *anyopaque, io: std.Io, record: Record) !bool {
        const file = cast(context).directory.openFile(io, name(record), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        file.close(io);
        return true;
    }
    fn read(context: *anyopaque, io: std.Io, record: Record, a: std.mem.Allocator, max: usize) ![]u8 {
        const file = try cast(context).directory.openFile(io, name(record), .{ .follow_symlinks = false });
        defer file.close(io);
        const length = (try file.stat(io)).size;
        if (length > max) return error.RecoveryRecordTooLarge;
        const bytes = try a.alloc(u8, @intCast(length));
        errdefer a.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.ShortRecoveryRead;
        return bytes;
    }
    fn create(context: *anyopaque, io: std.Io, record: Record, atomic: bool) !void {
        const self = cast(context);
        const slot = &self.slots[@backingInt(record)];
        if (slot.* != .none) return error.RecoveryDirectoryInUse;
        slot.* = if (atomic) .{ .atomic = try self.directory.createFileAtomic(io, name(record), .{ .permissions = .fromMode(0o600) }) } else .{ .file = try self.directory.createFile(io, name(record), .{ .exclusive = true, .permissions = .fromMode(0o600) }) };
    }
    fn openedFile(context: *anyopaque, record: Record) std.Io.File {
        return switch (cast(context).slots[@backingInt(record)]) {
            .file => |value| value,
            .atomic => |value| value.file,
            .none => unreachable,
        };
    }
    fn reserve(context: *anyopaque, io: std.Io, record: Record, bytes: u64) !void {
        if (bytes > std.math.maxInt(i64)) return error.RecoveryRecordTooLarge;
        const file = openedFile(context, record);
        if (@import("builtin").os.tag == .linux) {
            const linux = std.os.linux;
            switch (linux.errno(linux.fallocate(file.handle, 0, 0, @intCast(bytes)))) {
                .SUCCESS => {},
                .NOSPC, .DQUOT => return error.NoSpaceLeft,
                .OPNOTSUPP, .NOSYS => return error.RecoveryReservationUnsupported,
                else => return error.RecoveryReservationFailed,
            }
        } else return error.RecoveryReservationUnsupported;
        try file.sync(io);
    }
    fn write(context: *anyopaque, io: std.Io, record: Record, bytes: []const u8) !void {
        try openedFile(context, record).writePositionalAll(io, bytes, 0);
    }
    fn writeAt(context: *anyopaque, io: std.Io, record: Record, offset: u64, bytes: []const u8) !void {
        const self = cast(context);
        const slot = &self.slots[@backingInt(record)];
        if (slot.* == .none) slot.* = .{ .file = try self.directory.openFile(io, name(record), .{ .mode = .read_write, .follow_symlinks = false }) };
        try openedFile(context, record).writePositionalAll(io, bytes, offset);
    }
    fn syncFile(context: *anyopaque, io: std.Io, record: Record) !void {
        try openedFile(context, record).sync(io);
    }
    fn publish(context: *anyopaque, io: std.Io, record: Record) !void {
        try cast(context).slots[@backingInt(record)].atomic.link(io);
    }
    fn syncDirectory(context: *anyopaque, io: std.Io) !void {
        const directory_file = try cast(context).directory.openFile(io, ".", .{ .allow_directory = true });
        defer directory_file.close(io);
        try directory_file.sync(io);
    }
    const VTABLE: Store.VTable = .{ .reserve = reserve, .block_size = blockSize, .exists = exists, .size = size, .read = read, .read_at = readAt, .create = create, .write = write, .write_at = writeAt, .sync_file = syncFile, .publish = publish, .sync_directory = syncDirectory };
};

pub const RawCapsule = @import("raw_capsule.zig").RawCapsule;
pub const CapsuleDescriptor = @import("raw_capsule.zig").Descriptor;
