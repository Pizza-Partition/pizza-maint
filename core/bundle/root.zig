//! Minimal runtime layout contract. Published archives are authenticated before extraction.
const std = @import("std");
const utils = @import("utils");
const filesystem = utils.filesystem;
pub const PREFIX = "/opt/pizza/bundle";

/// Joins an existing bundle-relative path to `root`, rejecting traversal and escaping symlinks.
/// Returns an allocator-owned joined path; the returned spelling is not canonicalized.
pub fn rooted(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(relative))
        return error.UnsafePath;

    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, ".."))
        return error.UnsafePath;
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    if (!filesystem.pathIsWithin(
        try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator),
        canonical,
    ))
        return error.EscapingSymlink;
    return path;
}
