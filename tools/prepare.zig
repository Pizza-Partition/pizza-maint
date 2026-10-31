const std = @import("std");
const clap = @import("clap");

const bundle_build = @import("bundle_build");

const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--runtime <str>  Verified release download directory (required).
    \\--init <str>  Static pizza-init PID 1 binary (required).
    \\--maintenance <str>  Maintenance binary linked for the bundle (required).
    \\--destination <str>  New bundle directory (required).
);

/// Parses command-line options and delegates bundle preparation to the bundle module.
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
            "Usage: pizza-tools prepare-bundle [options]\n",
        );
        return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    }

    const runtime = parsed.args.runtime orelse return error.MissingRuntime;
    const init_binary = parsed.args.init orelse return error.MissingInitBinary;
    const maintenance = parsed.args.maintenance orelse return error.MissingMaintenanceBinary;
    const destination = parsed.args.destination orelse return error.MissingDestination;
    try bundle_build.assemble(allocator, io, environ, .{ .runtime = runtime, .init = init_binary, .maintenance = maintenance, .destination = destination });
}
