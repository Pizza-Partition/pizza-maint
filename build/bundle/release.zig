//! Publisher policy with TUF-updated trust and native offline signature verification.
const std = @import("std");
const utils = @import("utils");
const files = @import("files.zig");
pub const TrustOptions = @import("trust.zig").Options;
pub const REPOSITORY = "Pizza-Partition/pizza-bundle";
pub const REPOSITORY_ID = "1425566562";
pub const WORKFLOW = REPOSITORY ++ "/.github/workflows/release.yml";
pub const LOCK_PATH = "config/bundle/release.json";

pub const Lock = struct {
    repository: []const u8,
    repository_id: []const u8,
    workflow: []const u8,
    tag: []const u8,
    commit: []const u8,
    asset: []const u8,
    sha256: []const u8,
    kernel_asset: []const u8,
    kernel_sha256: []const u8,
    metadata_asset: []const u8,
    metadata_sha256: []const u8,

    pub fn validate(self: Lock) !void {
        if (!std.mem.eql(u8, self.repository, REPOSITORY) or !std.mem.eql(u8, self.repository_id, REPOSITORY_ID) or !std.mem.eql(u8, self.workflow, WORKFLOW) or
            !std.mem.eql(u8, self.asset, "pizza-base-x86_64.img") or !std.mem.eql(u8, self.kernel_asset, "vmlinuz") or !std.mem.eql(u8, self.metadata_asset, "base.json") or
            !hex(self.commit, 40) or !hex(self.sha256, 64) or !hex(self.kernel_sha256, 64) or !hex(self.metadata_sha256, 64)) return error.InvalidReleaseLock;
        if (self.tag.len < 2 or self.tag[0] != 'v') return error.InvalidReleaseLock;
        for (self.tag[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "_.+-", byte) == null) return error.InvalidReleaseLock;
    }
};

fn hex(value: []const u8, size: usize) bool {
    if (value.len != size) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

pub fn readLock(a: std.mem.Allocator, io: std.Io, path: []const u8) !Lock {
    const lock = try std.json.parseFromSliceLeaky(Lock, a, try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)), .{ .ignore_unknown_fields = true });
    try lock.validate();
    return lock;
}

pub fn verifyDigest(a: std.mem.Allocator, io: std.Io, path: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, try utils.filesystem.hashFileSha256(a, io, path), expected)) {
        return error.ReleaseDigestMismatch;
    }
}

pub const Base = struct {
    format: u16,
    kind: []const u8,
    architecture: []const u8,
    profile: []const u8,
    kernel_version: []const u8,
    kernel_release: []const u8,
    initramfs: []const u8,
    kernel: []const u8,
    application_overlay: struct { init: []const u8, runtime_root: []const u8 },

    pub fn validate(self: Base) !void {
        if (self.format != 1) return error.IncompatibleBaseImage;
        const pairs = [_][2][]const u8{ .{ self.kind, "pizza-base" }, .{ self.architecture, "x86_64" }, .{ self.profile, "cpu-maint-v1" }, .{ self.kernel_version, "7.2.11" }, .{ self.kernel_release, "7.2.11-arch1-1" }, .{ self.initramfs, "pizza-base-x86_64.img" }, .{ self.kernel, "vmlinuz" }, .{ self.application_overlay.init, "/init" }, .{ self.application_overlay.runtime_root, "/opt/pizza/bundle" } };
        for (pairs) |pair| if (!std.mem.eql(u8, pair[0], pair[1])) return error.IncompatibleBaseImage;
    }
};

pub fn verify(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, root: []const u8, lock: Lock) !Base {
    return verifyWithTrust(a, io, env, root, lock, .{});
}

pub fn verifyWithTrust(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, root: []const u8, lock: Lock, options: TrustOptions) !Base {
    try lock.validate();
    try verifyDigest(a, io, try std.fs.path.join(a, &.{ root, lock.asset }), lock.sha256);
    try verifyDigest(a, io, try std.fs.path.join(a, &.{ root, lock.kernel_asset }), lock.kernel_sha256);
    try verifyDigest(a, io, try std.fs.path.join(a, &.{ root, lock.metadata_asset }), lock.metadata_sha256);
    const now = std.Io.Clock.real.now(io).toSeconds();
    if (now < 0) return error.InvalidClock;
    const trust = try @import("trust.zig").load(a, io, env, options, @intCast(now));
    try @import("sigstore.zig").verify(a, try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, "attestation.json" }), a, .limited(1024 * 1024)), trust, .{
        .repository = lock.repository,
        .repository_id = lock.repository_id,
        .workflow = lock.workflow,
        .tag = lock.tag,
        .commit = lock.commit,
    }, &.{ .{ lock.asset, lock.sha256 }, .{ lock.kernel_asset, lock.kernel_sha256 }, .{ lock.metadata_asset, lock.metadata_sha256 } }, @intCast(now));
    const base = try std.json.parseFromSliceLeaky(Base, a, try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, lock.metadata_asset }), a, .limited(1024 * 1024)), .{ .ignore_unknown_fields = true });
    try base.validate();
    return base;
}

pub fn fetch(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, lock_file: []const u8, destination: []const u8) !void {
    const lock = try readLock(a, io, lock_file);
    if (std.Io.Dir.cwd().openDir(io, destination, .{ .iterate = true })) |opened| {
        var directory = opened;
        defer directory.close(io);
        var iterator = directory.iterate();
        if (try iterator.next(io) != null) {
            _ = try verify(a, io, env, destination, lock);
            return;
        }
    } else |err| if (err != error.FileNotFound) return err;
    const output = try files.Output.init(a, io, destination, true);
    defer output.deinit(io);
    for ([_][]const u8{ lock.asset, lock.kernel_asset, lock.metadata_asset, "attestation.json" }) |name| {
        try utils.process.runInherited(io, env, &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3", "--output", try std.fs.path.join(a, &.{ output.temporary, name }), try a.print("https://github.com/{s}/releases/download/{s}/{s}", .{ REPOSITORY, lock.tag, name }) });
    }
    _ = try verify(a, io, env, output.temporary, lock);
    try std.Io.Dir.cwd().renamePreserve(output.temporary, .cwd(), output.target, io);
}
