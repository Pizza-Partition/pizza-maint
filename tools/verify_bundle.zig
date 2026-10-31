const std = @import("std");
const clap = @import("clap");

const bundle_build = @import("bundle_build");
const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--offline  Verify using an unexpired authenticated TUF cache, without network.
    \\--trust-cache <str>  Sigstore TUF cache directory (default: user cache).
    \\--bundle <str>  Release download directory containing base image, kernel, metadata and attestation (required).
);

/// Parses subcommand arguments, authenticates the downloaded base assets.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
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
            "Usage: pizza-tools verify-bundle [options]\n",
        );
        return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    }
    const runtime = parsed.args.bundle orelse return error.MissingBundle;
    const lock = try bundle_build.release.readLock(allocator, io, bundle_build.release.LOCK_PATH);
    _ = try bundle_build.release.verifyWithTrust(allocator, io, environ, runtime, lock, .{
        .offline = parsed.args.offline != 0,
        .cache = parsed.args.@"trust-cache",
    });
}
