//! Protected reboot handoff and durable transition identity. No secrets use cmdline.
const std = @import("std");
const proto = @import("proto");
pub const storage = @import("session/storage.zig");
pub const REQUEST_PATH = "/etc/pizza/session.json";
pub const PLAN_PATH = "/etc/pizza/plan.json";
pub const MOUNT_PATH = "/run/pizza/journal";

pub const Home = struct {
    kind: proto.wire.Home = .other_device,
    uuid: []const u8,
    path: []const u8,

    pub fn validate(self: Home) !void {
        if (self.kind != .other_device or !hex(self.uuid, 32)) return error.InvalidJournalIdentity;
        try @import("utils").filesystem.checkPath(self.path);
        if (self.path.len > 1024) return error.InvalidJournalPath;
    }
};
pub const Request = struct {
    version: u16 = 1,
    session_id: []const u8,
    source_boot_id: []const u8,
    plan_id: []const u8,
    plan_sha256: []const u8,
    home: Home,
    no_ui: bool = false,
    test_poweroff: bool = false,

    pub fn validate(self: Request) !void {
        if (self.version != 1 or !hex(self.session_id, 32) or !hex(self.plan_sha256, 64)) return error.InvalidSession;
        if (self.source_boot_id.len != 36 or self.plan_id.len == 0 or self.plan_id.len > 64) return error.InvalidSession;
        for (self.source_boot_id, 0..) |c, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (c != '-') return error.InvalidSession;
            } else if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidSession;
        }
        for (self.plan_id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidSession;
        try self.home.validate();
        if (self.test_poweroff and !self.no_ui) return error.TestRequiresConsole;
    }
};
pub const Status = enum { staged, loaded, running, completed, failed, interrupted };
pub const Marker = struct {
    request: Request,
    status: Status,
    maintenance_boot_id: ?[]const u8 = null,
};

pub fn hex(value: []const u8, size: usize) bool {
    if (value.len != size) return false;
    for (value) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
pub fn digest(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
pub fn readProc(a: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(limit));
}
pub fn bootId(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return std.mem.trim(u8, try readProc(a, io, "/proc/sys/kernel/random/boot_id", 64), "\r\n");
}
pub fn syncDir(io: std.Io, directory: std.Io.Dir) !void {
    const file = try directory.openFile(io, ".", .{ .allow_directory = true });
    defer file.close(io);
    try file.sync(io);
}
pub fn writeExclusive(io: std.Io, directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try directory.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    try syncDir(io, directory);
}
pub fn writeMarker(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, marker: Marker, first: bool) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, marker, .{ .whitespace = .indent_2 });
    if (first) return writeExclusive(io, directory, "transition.json", bytes);
    try writeExclusive(io, directory, "transition.next", bytes);
    try directory.rename("transition.next", directory, "transition.json", io);
    try syncDir(io, directory);
}
pub fn readMarker(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !Marker {
    try storage.trustedFile(io, directory, "transition.json");
    const marker = try std.json.parseFromSliceLeaky(Marker, a, try directory.readFileAlloc(io, "transition.json", a, .limited(16 * 1024)), .{});
    try marker.request.validate();
    return marker;
}

test "handoff rejects ambiguous device identities and escaping paths" {
    const home: Home = .{ .uuid = "0123456789abcdef0123456789abcdef", .path = "pizza/session_1" };
    try home.validate();
    var invalid = home;
    invalid.path = "../root";
    try std.testing.expectError(error.UnsafePath, invalid.validate());
    invalid = home;
    invalid.uuid = "UUID=/dev/vda";
    try std.testing.expectError(error.InvalidJournalIdentity, invalid.validate());
    invalid = home;
    invalid.kind = .root_path;
    try std.testing.expectError(error.InvalidJournalIdentity, invalid.validate());
}
