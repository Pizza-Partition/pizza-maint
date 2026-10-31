//! Application descriptor checks; upstream correctness is tested by pizza-bundle CI.
const std = @import("std");
const utils = @import("utils");
const bundle = @import("bundle");
pub const Verified = struct { manifest: std.json.Value };

/// Reads the local application layout. This is not a publisher authentication check.
pub fn verify(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !Verified {
    const meta = try std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(allocator, &.{ root, "manifest.json" }), allocator, .limited(1024 * 1024)), .{});
    if (meta != .object) return error.ExpectedObject;
    if (try utils.json.unsigned(meta.object.get("format") orelse return error.MissingField) != 3) return error.UnsupportedManifest;
    for ([_][2][]const u8{ .{ "kind", "pizza-application" }, .{ "layout", "base-plus-overlay" }, .{ "profile", "cpu-maint-v1" }, .{ "architecture", "x86_64" }, .{ "working_directory", "bundle-root" } }) |field| {
        const value = meta.object.get(field[0]) orelse return error.MissingField;
        if (value != .string or !std.mem.eql(u8, value.string, field[1])) return error.IncompatibleRuntime;
    }
    const components = meta.object.get("components") orelse return error.MissingField;
    if (components != .object) return error.ExpectedObject;
    for ([_][]const u8{ "pizza-init", "pizza-maint" }) |name| {
        const relative = components.object.get(name) orelse return error.MissingComponent;
        if (relative != .string) return error.ExpectedString;
        _ = try bundle.rooted(allocator, io, root, relative.string);
    }
    return .{ .manifest = meta };
}

pub const release = @import("release.zig");
pub const assemble = @import("assemble.zig").assemble;
pub const AssembleOptions = @import("assemble.zig").Options;
pub const application = @import("application.zig");
pub const packTools = @import("archive.zig").packTools;
pub const pack = @import("archive.zig").pack;
pub const image = @import("archive.zig").image;

test {
    std.testing.refAllDecls(@import("tests.zig"));
    _ = application;
}
