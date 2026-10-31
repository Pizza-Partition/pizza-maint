//! Download and authenticate the pinned runtime release.
const std = @import("std");
const clap = @import("clap");
const bundle_build = @import("bundle_build");
const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--destination <str>  New output directory (required).
    \\--lock <str>  Runtime release lock (default: config/bundle/release.json).
);

pub fn run(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, argv: []const []const u8) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var parsed = try clap.parseEx(clap.Help, &PARAMS, clap.parsers.default, &iter, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    const destination = parsed.args.destination orelse return error.MissingDestination;
    try bundle_build.release.fetch(a, io, env, parsed.args.lock orelse bundle_build.release.LOCK_PATH, destination);
}
