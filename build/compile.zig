//! Shared policy for Zig binaries, test runners, generators and C archives.
const std = @import("std");

pub fn configure(compile: *std.Build.Step.Compile) void {
    compile.incremental = true;
    switch (compile.rootModuleTarget().os.tag) {
        .windows => compile.use_lld = false, // Zig's Coff.zig linker.
        .linux => {
            compile.use_lld = false;
            compile.use_new_linker = true; // Zig's Elf2.zig linker.
        },
        else => {},
    }
}

/// Direct build-exe commands do not report transitive imports to the build runner.
/// Track their source trees explicitly so --watch also rebuilds these commands.
pub fn watchSources(b: *std.Build, run: *std.Build.Step.Run) void {
    const io = b.graph.io;
    for ([_][]const u8{ "core", "protocol", "ui/execution/tui" }) |tree| {
        b.dependOnDirectoryContents(b.path(tree));
        var dir = b.root.openDir(io, tree, .{ .iterate = true }) catch @panic("cannot open source directory");
        defer dir.close(io);
        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch @panic("cannot walk source directory")) |entry| {
            const path = b.path(b.pathJoin(&.{ tree, entry.path }));
            switch (entry.kind) {
                .directory => b.dependOnDirectoryContents(path),
                .file => run.addFileInput(path),
                else => {},
            }
        }
    }
}
