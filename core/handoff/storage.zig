//! Explicit, independent ext4 journal media. Never formats or mounts original root.
const std = @import("std");
const linux = std.os.linux;
const session = @import("../handoff.zig");
const fs = @import("utils").filesystem;

fn stat(fd: linux.fd_t) !linux.Statx {
    var value: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true, .TYPE = true }, &value)) != .SUCCESS) return error.StorageIdentityUnavailable;
    return value;
}
pub fn trustedDirectory(io: std.Io, directory: std.Io.Dir) !void {
    _ = io;
    const value = try stat(directory.handle);
    if (!value.mask.UID or value.uid != 0 or value.mode & 0o022 != 0) return error.UntrustedDirectory;
}
pub fn trustedFile(io: std.Io, directory: std.Io.Dir, path: []const u8) !void {
    const file = try directory.openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const value = try stat(file.handle);
    if (!value.mask.UID or value.uid != 0 or value.mode & 0o077 != 0 or (try file.stat(io)).kind != .file) return error.UntrustedSessionFile;
}
/// Traverses every component using O_NOFOLLOW and checks root ownership.
pub fn openTrusted(io: std.Io, path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.AbsolutePathRequired;
    var current = try std.Io.Dir.cwd().openDir(io, "/", .{ .follow_symlinks = false });
    errdefer current.close(io);
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
        const next = try current.openDir(io, part, .{ .follow_symlinks = false });
        current.close(io);
        current = next;
        try trustedDirectory(io, current);
    }
    return current;
}

pub fn readUuid(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .block_device) return error.JournalMustBeBlockDevice;
    var block: [1024]u8 = undefined;
    if (try file.readPositionalAll(io, &block, 1024) != block.len) return error.InvalidExt4;
    return uuidFromSuperblock(a, &block);
}

fn uuidFromSuperblock(a: std.mem.Allocator, block: *const [1024]u8) ![]const u8 {
    // ext4 superblock offsets: UUID 0x68, external journal UUID 0xd0,
    // internal journal inode 0xe0, external journal device 0xe4.
    if (std.mem.readInt(u16, block[56..58], .little) != fs.EXT4_SUPER_MAGIC or std.mem.readInt(u32, block[96..100], .little) & 0x40 == 0 or std.mem.readInt(u32, block[228..232], .little) != 0 or !std.mem.allEqual(u8, block[208..224], 0)) return error.UnsupportedJournalFilesystem;
    const uuid: [16]u8 = block[104..120].*;
    if (std.mem.allEqual(u8, &uuid, 0)) return error.InvalidJournalIdentity;
    return a.dupe(u8, &std.fmt.bytesToHex(uuid, .lower));
}

fn diskParent(a: std.mem.Allocator, io: std.Io, major: u32, minor: u32) ![]const u8 {
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, try a.print("/sys/dev/block/{d}:{d}", .{ major, minor }), a);
    if (std.mem.indexOf(u8, path, "/virtual/") != null) return error.ComplexJournalDeviceUnsupported;
    if (std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ path, "partition" }), .{})) {
        return std.fs.path.dirname(path) orelse return error.StorageIdentityUnavailable;
    } else |err| if (err != error.FileNotFound) return err;
    return path;
}

/// Requires an already mounted, independently backed home; it creates no files.
pub fn select(a: std.mem.Allocator, io: std.Io, device: []const u8, home: []const u8) !session.Home {
    if (!std.fs.path.isAbsolute(device)) return error.AbsolutePathRequired;
    const node = try std.Io.Dir.cwd().realPathFileAlloc(io, device, a);
    const uuid = try readUuid(a, io, node);
    const file = try std.Io.Dir.cwd().openFile(io, node, .{});
    defer file.close(io);
    const identity = try stat(file.handle);
    const disk = try diskParent(a, io, identity.rdev_major, identity.rdev_minor);
    var root = try std.Io.Dir.cwd().openDir(io, "/", .{});
    defer root.close(io);
    const root_kind = try fs.filesystemType(root);
    if (root_kind != fs.TMPFS_MAGIC and root_kind != fs.RAMFS_MAGIC) {
        const root_id = try stat(root.handle);
        const original = diskParent(a, io, root_id.dev_major, root_id.dev_minor) catch return error.OriginalRootBackingUnknown;
        if (std.mem.eql(u8, original, disk)) return error.JournalMustUseIndependentDisk;
    }
    var directory = try openTrusted(io, home);
    defer directory.close(io);
    const actual = try stat(directory.handle);
    if (actual.dev_major != identity.rdev_major or actual.dev_minor != identity.rdev_minor or try fs.filesystemType(directory) != fs.EXT4_SUPER_MAGIC) return error.JournalDeviceHomeMismatch;
    if ((try directory.stat(io)).permissions.toMode() & 0o077 != 0) return error.JournalHomeMustBePrivate;
    if (directory.access(io, "journal.bin", .{})) return error.JournalAlreadyExists else |err| if (err != error.FileNotFound) return err;
    const relative = try relativeHome(a, try session.readProc(a, io, "/proc/self/mountinfo", 1024 * 1024), home, identity.rdev_major, identity.rdev_minor);
    const result: session.Home = .{ .uuid = uuid, .path = relative };
    try result.validate();
    return result;
}

/// Persist caller-created ancestor directories without syncing the original root.
pub fn syncParents(io: std.Io, home: []const u8) !void {
    var directory = try openTrusted(io, home);
    defer directory.close(io);
    const identity = try stat(directory.handle);
    try session.syncDir(io, directory);
    var path = std.fs.path.dirname(home);
    while (path) |parent| {
        if (std.mem.eql(u8, parent, "/")) break;
        var ancestor = try openTrusted(io, parent);
        defer ancestor.close(io);
        const actual = try stat(ancestor.handle);
        if (actual.dev_major != identity.dev_major or actual.dev_minor != identity.dev_minor) break;
        try session.syncDir(io, ancestor);
        path = std.fs.path.dirname(parent);
    }
}

fn relativeHome(a: std.mem.Allocator, mounts: []const u8, home: []const u8, major: u32, minor: u32) ![]const u8 {
    var selected: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    const identity = try a.print("{d}:{d}", .{ major, minor });
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next();
        _ = fields.next();
        const dev = fields.next() orelse continue;
        const subroot = fields.next() orelse continue;
        const point = fields.next() orelse continue;
        const options = fields.next() orelse continue;
        if (!std.mem.eql(u8, dev, identity) or !std.mem.eql(u8, subroot, "/") or std.mem.indexOfScalar(u8, point, '\\') != null) continue;
        if (!fs.pathIsWithin(point, home) or std.mem.eql(u8, point, home)) continue;
        var opts = std.mem.splitScalar(u8, options, ',');
        var writable = false;
        while (opts.next()) |opt| if (std.mem.eql(u8, opt, "rw")) {
            writable = true;
        };
        if (!writable) return error.JournalMountedReadOnly;
        if (selected == null or point.len > selected.?.len) selected = point;
    }
    const point = selected orelse return error.JournalMountNotFound;
    return a.dupe(u8, home[point.len + 1 ..]);
}

pub fn findDevice(a: std.mem.Allocator, io: std.Io, uuid: []const u8) ![]const u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, "/sys/class/block", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var selected: ?[]const u8 = null;
    while (try iterator.next(io)) |entry| {
        const path = try a.print("/dev/{s}", .{entry.name});
        const actual = readUuid(a, io, path) catch |err| switch (err) {
            error.UnsupportedJournalFilesystem, error.JournalMustBeBlockDevice => continue,
            else => return err,
        };
        if (!std.mem.eql(u8, actual, uuid)) continue;
        if (selected != null) return error.DuplicateJournalUuid;
        selected = path;
    }
    return selected orelse return error.JournalDeviceNotFound;
}

pub const Mounted = struct {
    directory: std.Io.Dir,
    path: []const u8,
    marker: session.Marker,

    pub fn close(self: *Mounted, io: std.Io) void {
        self.directory.close(io);
        if (linux.errno(linux.umount2(session.MOUNT_PATH, 0)) != .SUCCESS) std.log.err("Journal unmount failed; do not remove media", .{});
    }
    pub fn mark(self: *Mounted, a: std.mem.Allocator, io: std.Io, status: session.Status) !void {
        if (self.marker.status == status) return;
        var value = self.marker;
        value.status = status;
        try session.writeMarker(a, io, self.directory, value, false);
        self.marker = value;
    }
};

/// Only the ordinary maintenance application mounts the explicitly handed-off UUID.
pub fn mount(a: std.mem.Allocator, io: std.Io, request: session.Request) !Mounted {
    try request.validate();
    const boot = try session.bootId(a, io);
    if (std.mem.eql(u8, boot, request.source_boot_id)) return error.HandoffRequiresNewBoot;
    var root = try std.Io.Dir.cwd().openDir(io, "/", .{});
    defer root.close(io);
    const root_kind = try fs.filesystemType(root);
    if (root_kind != fs.TMPFS_MAGIC and root_kind != fs.RAMFS_MAGIC) return error.MaintenanceMustUseRamRoot;
    const deadline = std.Io.Timestamp.now(io, .awake).nanoseconds + 10 * std.time.ns_per_s;
    const device = while (true) {
        if (findDevice(a, io, request.home.uuid)) |found| break found else |err| {
            if (err != error.JournalDeviceNotFound or std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline) return err;
            try std.Io.sleep(io, .fromMilliseconds(100), .awake);
        }
    };
    try std.Io.Dir.cwd().createDir(io, session.MOUNT_PATH, .fromMode(0o700));
    const result = linux.mount(try a.dupeSentinel(u8, device, 0), session.MOUNT_PATH, "ext4", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.JournalMountFailed;
    errdefer _ = linux.umount2(session.MOUNT_PATH, 0);
    const path = try std.fs.path.join(a, &.{ session.MOUNT_PATH, request.home.path });
    var home = try openTrusted(io, path);
    errdefer home.close(io);
    if ((try home.stat(io)).permissions.toMode() & 0o077 != 0) return error.JournalHomeMustBePrivate;
    if (try fs.filesystemType(home) != fs.EXT4_SUPER_MAGIC) return error.JournalHomeMustBePersistent;
    const marker = try session.readMarker(a, io, home);
    const expected = try std.json.Stringify.valueAlloc(a, request, .{});
    if (marker.status != .loaded or !std.mem.eql(u8, expected, try std.json.Stringify.valueAlloc(a, marker.request, .{}))) return error.StaleOrMismatchedTransition;
    try trustedFile(io, home, "plan.json");
    const saved_plan = try home.readFileAlloc(io, "plan.json", a, .limited(1024 * 1024));
    if (!std.mem.eql(u8, request.plan_sha256, try session.digest(a, saved_plan))) return error.DurablePlanChanged;
    if (home.access(io, "journal.bin", .{})) return error.JournalAlreadyExists else |err| if (err != error.FileNotFound) return err;
    var active: Mounted = .{ .directory = home, .path = path, .marker = marker };
    active.marker.maintenance_boot_id = boot;
    try active.mark(a, io, .running);
    std.log.info("PIZZA_JOURNAL_HOME_READY: independent ext4 media; durable execution enabled", .{});
    return active;
}

test "journal relative path follows the actual whole-filesystem mount" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mounts = "1 0 8:16 / /journal rw,nosuid - ext4 /dev/sdb rw\n2 1 8:16 /pizza /alias rw - ext4 /dev/sdb rw\n";
    try std.testing.expectEqualStrings("pizza/session", try relativeHome(a, mounts, "/journal/pizza/session", 8, 16));
    try std.testing.expectError(error.JournalMountNotFound, relativeHome(a, mounts, "/alias/session", 8, 16));
    try std.testing.expectError(error.JournalMountedReadOnly, relativeHome(a, "1 0 8:16 / /journal ro - ext4 /dev/sdb ro", "/journal/pizza/session", 8, 16));
}

test "internal ext4 journal is accepted, external journal backing is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var block: [1024]u8 = @splat(0);
    std.mem.writeInt(u16, block[56..58], fs.EXT4_SUPER_MAGIC, .little);
    std.mem.writeInt(u32, block[96..100], 0x40, .little);
    std.mem.writeInt(u32, block[224..228], 8, .little);
    @memset(block[104..120], 0x12);
    try std.testing.expectEqualStrings("12121212121212121212121212121212", try uuidFromSuperblock(a, &block));
    block[208] = 1;
    try std.testing.expectError(error.UnsupportedJournalFilesystem, uuidFromSuperblock(a, &block));
}
