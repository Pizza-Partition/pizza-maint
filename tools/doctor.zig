const std = @import("std");
const utils = @import("utils");
const clap = @import("clap");

const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--profile <str>  Dependency profile: build, qemu, image or matrix.
);

/// Checks system tools and applicable version requirements for the selected dependency profile.
/// Parses subcommand arguments and returns an error when required dependencies are unavailable.
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
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools doctor [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    }
    const profile = (parsed.args.profile orelse "build");
    const commands: []const []const u8 = if (std.mem.eql(u8, profile, "build")) &.{
        "zig",
        "node",
        "npm",
    } else if (std.mem.eql(u8, profile, "qemu")) &.{
        "qemu-system-x86_64",
        "qemu-img",
    } else if (std.mem.eql(u8, profile, "image")) &.{
        "curl",
    } else if (std.mem.eql(u8, profile, "matrix")) &.{
        "qemu-system-x86_64",
        "qemu-img",
        "cloud-localds",
    } else return error.UnknownProfile;
    var failed = false;
    for (commands) |command| {
        var name = command;
        for ([_][2][]const u8{
            .{ "zig", "ZIG" },
            .{ "node", "NODE" },
            .{ "npm", "NPM" },
        }) |override| {
            if (std.mem.eql(u8, command, override[0])) {
                name = environ.get(override[1]) orelse command;
                break;
            }
        }
        const found = utils.process.findExecutable(allocator, io, environ, name) catch {
            failed = true;
            continue;
        };
        std.log.info("{s}: {s}", .{ command, found });
    }
    if (std.mem.eql(u8, profile, "build") and !failed) {
        const actual = std.mem.trim(
            u8,
            try utils.process.checkedOutput(
                allocator,
                io,
                environ,
                &.{
                    (environ.get("ZIG") orelse "zig"),
                    "version",
                },
            ),
            " \t\r\n",
        );
        if (!std.mem.eql(
            u8,
            actual,
            std.mem.trim(
                u8,
                try std.Io.Dir.cwd().readFileAlloc(
                    io,
                    ".zigversion",
                    allocator,
                    .limited(128 * 1024 * 1024),
                ),
                " \t\r\n",
            ),
        ))
            return error.IncompatibleZig;
        const node = std.mem.trim(
            u8,
            try utils.process.checkedOutput(
                allocator,
                io,
                environ,
                &.{
                    (environ.get("NODE") orelse "node"),
                    "--version",
                },
            ),
            " \t\r\n",
        );
        var parts = std.mem.splitScalar(
            u8,
            std.mem.trimStart(u8, node, "v"),
            '.',
        );
        if (try std.fmt.parseInt(u32, parts.next() orelse "", 10) < 22) {
            return error.IncompatibleNode;
        }
    }
    if (failed)
        return error.MissingSystemDependencies;
}
