const std = @import("std");

/// Resolves a path relative to the checkout, canonicalizing its nearest existing ancestor.
/// Returns an allocator-owned path; callers must check containment separately.
pub fn resolveOutputPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    checkout_root: []const u8,
    name: []const u8,
) ![]const u8 {
    const lexical = try std.fs.path.resolve(allocator, &.{ checkout_root, name });
    var parent: []const u8 = lexical;
    while (true) {
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator) catch |err| switch (err) {
            error.FileNotFound => {
                parent = std.fs.path.dirname(parent) orelse return err;
                continue;
            },
            else => return err,
        };
        if (parent.len == lexical.len)
            return canonical;
        return std.fs.path.join(
            allocator,
            &.{ canonical, std.mem.trimStart(u8, lexical[parent.len..], "/") },
        );
    }
}

/// Creates a randomly named directory under /tmp using the supplied prefix.
/// The returned path uses `allocator`; the caller is responsible for removing the directory.
pub fn createTemporaryDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []const u8,
) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.Io.random(io, &bytes);
    const name = try allocator.print(
        "/tmp/{s}{s}",
        .{ prefix, std.fmt.bytesToHex(bytes, .lower) },
    );
    try std.Io.Dir.cwd().createDir(io, name, .default_dir);
    return name;
}

/// Streams a file into SHA-256 and returns an allocator-owned lowercase hexadecimal digest.
pub fn hashFileSha256(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, name, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0)
            break;
        hasher.update(buffer[0..count]);
    }
    return allocator.dupe(
        u8,
        &std.fmt.bytesToHex(hasher.finalResult(), .lower),
    );
}

/// Checks equality or a directory-boundary prefix on already normalized paths.
/// This lexical check does not resolve symlinks.
pub fn pathIsWithin(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path))
        return true;
    return std.mem.startsWith(u8, path, root) and
        path.len > root.len and path[root.len] == '/';
}

pub fn checkPath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part|
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.UnsafePath;
}

/// Returns the Linux filesystem magic for an open directory on our x86-64 target.
pub fn filesystemType(directory: std.Io.Dir) !u64 {
    if (@import("builtin").cpu.arch != .x86_64 or @import("builtin").os.tag != .linux)
        @compileError("filesystemType requires the Linux x86-64 statfs ABI");
    return @bitCast((try statFilesystem(directory.handle)).kind);
}
/// VFS filesystem identity remains stable when device numbers change at boot.
pub fn filesystemIdentity(file: std.Io.File) ![2]u32 {
    const stat = try statFilesystem(file.handle);
    return .{ @bitCast(stat.fsid[0]), @bitCast(stat.fsid[1]) };
}
fn statFilesystem(handle: std.Io.File.Handle) !Statfs {
    var stat: Statfs = undefined;
    const linux = std.os.linux;
    if (linux.errno(linux.syscall2(.fstatfs, @intCast(handle), @intFromPtr(&stat))) != .SUCCESS) return error.FilesystemCheckFailed;
    return stat;
}
const Statfs = extern struct {
    kind: i64,
    block_size: i64,
    blocks: u64,
    blocks_free: u64,
    blocks_available: u64,
    files: u64,
    files_free: u64,
    fsid: [2]i32,
    name_length: i64,
    fragment_size: i64,
    flags: i64,
    spare: [4]i64,
};

pub const TMPFS_MAGIC = 0x01021994;
pub const RAMFS_MAGIC = 0x858458f6;

/// Stable identity of an ordinary image across maintenance boots.
pub fn imageIdentity(file: std.Io.File) ![32]u8 {
    if (@import("builtin").os.tag != .linux) return error.ImageIdentityUnavailable;
    const linux = std.os.linux;
    var stat: linux.Statx = undefined;
    var requested = linux.STATX.BASIC_STATS;
    requested.BTIME = true;
    if (linux.errno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, requested, &stat)) != .SUCCESS) return error.ImageIdentityUnavailable;
    var fields: [32]u8 = @splat(0);
    const fsid = try filesystemIdentity(file);
    std.mem.writeInt(u32, fields[0..4], fsid[0], .little);
    std.mem.writeInt(u32, fields[4..8], fsid[1], .little);
    std.mem.writeInt(u64, fields[8..16], stat.ino, .little);
    if (stat.mask.BTIME) {
        std.mem.writeInt(i64, fields[16..24], stat.btime.sec, .little);
        std.mem.writeInt(u32, fields[24..28], stat.btime.nsec, .little);
    }
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-image-identity-v1");
    hash.update(&fields);
    return hash.finalResult();
}

pub const Space = struct { total_bytes: u64, free_bytes: u64, available_bytes: u64 };
/// Mounted-volume statistics are advisory, never evidence of a shrink boundary.
pub fn space(directory: std.Io.Dir) !Space {
    const value = try statFilesystem(directory.handle);
    if (value.block_size <= 0) return error.InvalidFilesystemGeometry;
    const size: u64 = @intCast(value.block_size);
    return .{ .total_bytes = try std.math.mul(u64, value.blocks, size), .free_bytes = try std.math.mul(u64, value.blocks_free, size), .available_bytes = try std.math.mul(u64, value.blocks_available, size) };
}
