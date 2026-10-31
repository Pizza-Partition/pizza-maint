//! Only RAM and kernel pseudo filesystems are mounted. No original root is opened.
const std = @import("std");
const linux = std.os.linux;
const fs = @import("utils").filesystem;

/// Refuses a disk root before creating directories or mounting anything.
pub fn setup(io: std.Io) !void {
    var root = try std.Io.Dir.cwd().openDir(io, "/", .{});
    defer root.close(io);
    try requireRam(try fs.filesystemType(root));
    std.log.info("PIZZA_MAINT_RAM_ROOT_READY", .{});
    try mount(io, "/proc", "proc", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, null);
    try mount(io, "/sys", "sysfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, null);
    if (std.Io.Dir.cwd().access(io, "/sys/firmware/efi", .{})) {
        try mount(io, "/sys/firmware/efi/efivars", "efivarfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, null);
    } else |err| if (err != error.FileNotFound) return err;
    // devtmpfs creates existing and subsequently discovered kernel device nodes.
    try mount(io, "/dev", "devtmpfs", linux.MS.NOSUID | linux.MS.NOEXEC, "mode=0755");
    try mount(io, "/dev/pts", "devpts", linux.MS.NOSUID | linux.MS.NOEXEC, "newinstance,ptmxmode=0666,mode=0620");
    try link("/proc/self/fd", "/dev/fd");
    try link("/proc/self/fd/0", "/dev/stdin");
    try link("/proc/self/fd/1", "/dev/stdout");
    try link("/proc/self/fd/2", "/dev/stderr");
    try link("pts/ptmx", "/dev/ptmx");
    try mount(io, "/dev/shm", "tmpfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, "mode=1777");
    try mount(io, "/run", "tmpfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, "mode=0755");
    try mount(io, "/tmp", "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, "mode=1777");
    try std.Io.Dir.cwd().createDir(io, "/run/pizza", .fromMode(0o700));
    std.log.info("PIZZA_MAINT_MOUNTS_READY: proc sys dev devpts shm run tmp", .{});
}

fn requireRam(kind: u64) !void {
    if (kind != fs.TMPFS_MAGIC and kind != fs.RAMFS_MAGIC) return error.RootMustBeRam;
}

fn mount(io: std.Io, path: [:0]const u8, kind: [:0]const u8, flags: u32, data: ?[:0]const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    const result = linux.mount(kind, path, kind, flags, if (data) |d| @intFromPtr(d.ptr) else 0);
    if (linux.errno(result) != .SUCCESS) {
        std.log.err("Mount {s}: {t}", .{ path, linux.errno(result) });
        return error.MountFailed;
    }
}

fn link(target: [:0]const u8, path: [:0]const u8) !void {
    switch (linux.errno(linux.unlink(path))) {
        .SUCCESS, .NOENT => {},
        else => return error.DeviceLinkFailed,
    }
    if (linux.errno(linux.symlink(target, path)) != .SUCCESS) return error.DeviceLinkFailed;
}

test "maintenance root accepts only in-memory filesystem types" {
    try requireRam(fs.TMPFS_MAGIC);
    try requireRam(fs.RAMFS_MAGIC);
    try std.testing.expectError(error.RootMustBeRam, requireRam(0xef53));
    try std.testing.expectError(error.RootMustBeRam, requireRam(0x794c7630));
}
