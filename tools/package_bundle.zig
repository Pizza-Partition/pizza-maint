const std = @import("std");
const bundle_build = @import("bundle_build");
const clap = @import("clap");

const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--bundle <str>  Local bundle directory (required).
    \\--output <str>  New release tar.gz outside the source bundle (required).
);

/// Parses command-line options and delegates release packaging to the bundle module.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    _: []const u8,
    argv: []const []const u8,
) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &PARAMS, clap.parsers.default, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
    }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return err;
    };
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(
            io,
            "Usage: pizza-tools pack-bundle [options]\n",
        );
        return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    }
    const root = parsed.args.bundle orelse return error.MissingBundle;
    const output = parsed.args.output orelse return error.MissingOutput;
    try bundle_build.pack(allocator, io, environ, root, output);
}
