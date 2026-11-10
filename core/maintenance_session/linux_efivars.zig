//! Fixed efivarfs backend. No caller-supplied variable names, paths or GUIDs.
//! Merely building this backend does not modify the host firmware.
const std = @import("std");
const uefi = @import("uefi.zig");
const GLOBAL = uefi.GLOBAL_GUID;
// Pizza vendor namespace. Never clear flags on arbitrary firmware variables.
const PIZZA = uefi.PIZZA_GUID;
// Linux x86-64 ioctl ABI.
const FS_IOC_GETFLAGS: u32 = 0x80086601;
const FS_IOC_SETFLAGS: u32 = 0x40086602;
const FS_IMMUTABLE_FL: c_ulong = 0x10;
pub const SecureBoot = enum { enabled, disabled, unknown };
pub const Efivars = struct {
    directory: std.Io.Dir,
    writable: bool,
    pub fn open(io: std.Io, writable: bool) !Efivars {
        if (writable and std.os.linux.geteuid() != 0) return error.FirmwareRequiresRoot;
        var directory = try std.Io.Dir.cwd().openDir(io, "/sys/firmware/efi/efivars", .{});
        errdefer directory.close(io);
        if (try @import("utils").filesystem.filesystemType(directory) != @import("utils").filesystem.EFIVARFS_MAGIC) return error.EfivarfsRequired;
        return .{ .directory = directory, .writable = writable };
    }
    pub fn close(self: *Efivars, io: std.Io) void {
        self.directory.close(io);
        self.* = undefined;
    }
    pub fn variables(self: *Efivars) uefi.Variables {
        return .{ .context = self, .read = read, .write = write };
    }
    fn filename(key: uefi.Variable, buffer: []u8) ![]const u8 {
        return switch (key) {
            .boot => |slot| try std.fmt.bufPrint(buffer, "Boot{X:0>4}-" ++ GLOBAL, .{slot}),
            .order => "BootOrder-" ++ GLOBAL,
            .next => "BootNext-" ++ GLOBAL,
            .current => "BootCurrent-" ++ GLOBAL,
            .pizza_session => "PizzaSession-" ++ PIZZA,
        };
    }
    fn value(self: *Efivars, a: std.mem.Allocator, io: std.Io, name: []const u8) !?[]const u8 {
        const file = self.directory.openFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const bytes = try reader.interface.allocRemaining(a, .limited(65540));
        if (bytes.len < 4) return error.InvalidFirmwareVariable;
        // efivarfs prepends UINT32 variable attributes, little endian.
        const attributes = std.mem.readInt(u32, bytes[0..4], .little);
        if (attributes & 6 != 6 or attributes & ~@as(u32, 7) != 0) return error.UnsupportedFirmwareVariableAttributes;
        return bytes[4..];
    }
    fn read(ctx: *anyopaque, a: std.mem.Allocator, io: std.Io, key: uefi.Variable) !?[]const u8 {
        const self: *Efivars = @ptrCast(@alignCast(ctx));
        var buffer: [80]u8 = undefined;
        return self.value(a, io, try filename(key, &buffer));
    }
    fn write(ctx: *anyopaque, io: std.Io, key: uefi.Variable, bytes: ?[]const u8) !void {
        const self: *Efivars = @ptrCast(@alignCast(ctx));
        if (key == .current) return error.ReadOnlyFirmwareVariable;
        if (!self.writable or std.os.linux.geteuid() != 0) return error.FirmwareRequiresRoot;
        var buffer: [80]u8 = undefined;
        const name = try filename(key, &buffer);
        // Custom efivarfs inodes default to immutable. Unlock only our fixed
        // vendor variable, retaining its original flags on all failure paths.
        const existing = if (key == .pizza_session) self.directory.openFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        } else null;
        defer if (existing) |file| file.close(io);
        const old_flags = if (existing) |file| try unlock(file) else 0;
        var removed = false;
        errdefer if (existing) |file| if (!removed) setFlags(file, old_flags) catch {};
        if (bytes) |v| {
            if (v.len > 65536) return error.FirmwareVariableTooLarge;
            // One SetVariable operation per write, including its attributes.
            const data = try std.heap.page_allocator.alloc(u8, v.len + 4);
            defer std.heap.page_allocator.free(data);
            std.mem.writeInt(u32, data[0..4], 7, .little);
            @memcpy(data[4..], v);
            const file = try self.directory.createFile(io, name, .{ .truncate = false, .permissions = .fromMode(0o600) });
            defer file.close(io);
            const created_flags = if (key == .pizza_session and existing == null) try unlock(file) else 0;
            errdefer if (created_flags != 0) setFlags(file, created_flags) catch {};
            while (true) {
                const result = std.os.linux.write(file.handle, data.ptr, data.len);
                switch (std.os.linux.errno(result)) {
                    .SUCCESS => {
                        if (result != data.len) return error.ShortFirmwareWrite;
                        break;
                    },
                    .INTR => continue,
                    .NOSPC, .DQUOT => return error.FirmwareStorageFull,
                    .ACCES, .PERM => return error.FirmwareWriteDenied,
                    else => return error.FirmwareWriteFailed,
                }
            }
            if (created_flags != 0) try setFlags(file, created_flags);
        } else {
            self.directory.deleteFile(io, name) catch |err| if (err != error.FileNotFound) return err;
            removed = true;
        }
        if (existing) |file| if (!removed) try setFlags(file, old_flags);
    }
    pub fn secureBoot(self: *Efivars, a: std.mem.Allocator, io: std.Io) !SecureBoot {
        const secure = try self.value(a, io, "SecureBoot-" ++ GLOBAL) orelse return .unknown;
        const setup = try self.value(a, io, "SetupMode-" ++ GLOBAL) orelse return .unknown;
        if (secure.len != 1 or setup.len != 1 or secure[0] > 1 or setup[0] > 1 or (setup[0] == 1 and secure[0] == 1)) return .unknown;
        return if (secure[0] == 1) .enabled else .disabled;
    }
};

fn setFlags(file: std.Io.File, flags: c_ulong) !void {
    var value = flags;
    if (std.os.linux.errno(std.os.linux.ioctl(file.handle, FS_IOC_SETFLAGS, @intFromPtr(&value))) != .SUCCESS) return error.FirmwareVariableFlagsFailed;
}
fn unlock(file: std.Io.File) !c_ulong {
    var flags: c_ulong = 0;
    if (std.os.linux.errno(std.os.linux.ioctl(file.handle, FS_IOC_GETFLAGS, @intFromPtr(&flags))) != .SUCCESS) return error.FirmwareVariableFlagsFailed;
    if (flags & ~FS_IMMUTABLE_FL != 0) return error.UnsupportedFirmwareVariableFlags;
    if (flags & FS_IMMUTABLE_FL != 0) try setFlags(file, flags & ~FS_IMMUTABLE_FL);
    return flags;
}

test "efivar filenames are fixed and boot numbers use four uppercase hex digits" {
    var buffer: [80]u8 = undefined;
    try std.testing.expectEqualStrings("Boot00AF-" ++ GLOBAL, try Efivars.filename(.{ .boot = 0xaf }, &buffer));
    try std.testing.expectEqualStrings("PizzaSession-" ++ PIZZA, try Efivars.filename(.pizza_session, &buffer));
}
