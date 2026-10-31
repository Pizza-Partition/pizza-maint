const std = @import("std");
const utils = @import("utils");
const clap = @import("clap");
const vm = @import("vm");
const matrix = @import("matrix");

const Command = enum { help, smoke, maintenance, journal, executor, matrix };
const PARSERS = .{ .command = clap.parsers.enumeration(Command) };
const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>  smoke, maintenance, journal, executor, matrix.
);

/// Dispatches host smoke, transition and matrix tests, returning status 1 on argument or test errors.
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
    try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tests <command> [options]\n");
    try clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    try std.Io.File.stdout().writeStreamingAll(
        io,
        "Use zig build test-smoke, test-maintenance or test-matrix -- [options].\n",
    );
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
        .smoke => try vm.smoke.run(allocator, io, environ, checkout_root, argv),
        .journal => try vm.journal.run(allocator, io, environ, checkout_root, argv),
        .executor => try vm.executor.run(allocator, io, environ, checkout_root, argv),
        .maintenance => try vm.maintenance.run(allocator, io, environ, checkout_root, argv),
        .matrix => try matrix.run(allocator, io, environ, argv),
    }
}
