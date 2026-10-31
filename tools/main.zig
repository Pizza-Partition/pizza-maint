const std = @import("std");
const utils = @import("utils");
const clap = @import("clap");

const Command = enum {
    help,
    proto,
    report,
    doctor,
    @"fetch-bundle",
    @"verify-bundle",
    @"prepare-bundle",
    @"pack-bundle",
    @"pack-tools",
    image,
    clean,
};
const PARSERS = .{ .command = clap.parsers.enumeration(Command) };
const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>  proto, doctor, fetch-bundle, verify-bundle, prepare-bundle, pack-bundle, pack-tools, image, clean.
);

/// Dispatches engineering commands and translates argument or command failures into exit status 1.
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    const io = init.io;
    const environ = init.environ_map;
    const checkout_root = try std.process.currentPathAlloc(io, allocator);
    var iter: clap.args.SliceIterator = .{ .args = argv[1..] };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &PARAMS, PARSERS, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
        .terminating_positional = 0,
    }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return 1;
    };
    defer parsed.deinit();
    if (parsed.args.help != 0 or parsed.positionals[0] == null) {
        try help(io);
        return 0;
    }
    const command = parsed.positionals[0].?;
    dispatch(allocator, io, environ, checkout_root, command, iter.args[iter.index..]) catch |err| {
        std.log.err("{t}: {t}", .{ command, err });
        return 1;
    };
    return 0;
}

fn help(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools <command> [options]\n");
    try clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    try std.Io.File.stdout().writeStreamingAll(io, "Use zig build tools -- <command> [options].\n");
}

fn dispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    checkout_root: []const u8,
    command: Command,
    argv: []const []const u8,
) !void {
    switch (command) {
        .help => {
            if (argv.len != 0)
                return error.UnexpectedArgument;
            return help(io);
        },
        .proto => try @import("protocol.zig").generate(allocator, io, environ, argv),
        .report => {
            if (argv.len != 1) return error.ExpectedJournalPath;
            const scan = try @import("journal").readFile(allocator, io, argv[0]);
            try std.Io.File.stdout().writeStreamingAll(io, try @import("report").render(allocator, scan));
        },
        .doctor => try @import("doctor.zig").run(allocator, io, environ, argv),
        .@"fetch-bundle" => try @import("fetch_bundle.zig").run(allocator, io, environ, argv),
        .@"verify-bundle" => try @import("verify_bundle.zig").run(allocator, io, environ, argv),
        .@"prepare-bundle" => try @import(
            "prepare.zig",
        ).run(
            allocator,
            io,
            environ,
            checkout_root,
            argv,
        ),
        .@"pack-bundle" => try @import(
            "package_bundle.zig",
        ).run(
            allocator,
            io,
            environ,
            checkout_root,
            argv,
        ),
        .@"pack-tools" => try @import("package_tools.zig").run(allocator, io, environ, checkout_root, argv),
        .image => try @import("image.zig").run(allocator, io, environ, checkout_root, argv),
        .clean => try clean(allocator, io, argv),
    }
}

fn clean(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const clean_params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
    );
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &clean_params, clap.parsers.default, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
    }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return err;
    };
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools clean [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &clean_params, .{});
    }
    for ([_][]const u8{ ".zig-cache", "zig-out" }) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        try std.Io.Dir.cwd().deleteTree(io, path);
    }
}
