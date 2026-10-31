//! Separate acceptance binary. Never installed as the product maintenance application.
const std = @import("std");
const maintenance = @import("maintenance");

pub fn main(init: std.process.Init) !u8 {
    if (std.os.linux.getpid() == 1) return error.ApplicationMustNotBePid1;
    return run(init) catch |err| {
        std.log.err("Maintenance fixture: {t}", .{err});
        return 1;
    };
}
fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--probe-image")) {
        if (args.len != 3) return error.InvalidFixtureArguments;
        const Image = maintenance.storage.testing.ImageDevice;
        const path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], a);
        var image = try Image.openReadOnly(init.io, path, try Image.identify(init.io, path), 512);
        defer image.close(init.io);
        const info = try maintenance.storage.probe.queryDevice(a, init.io, path, image.backend().reader());
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.json.Stringify.valueAlloc(a, info, .{ .whitespace = .indent_2 }));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return 0;
    }
    return @import("application").runWithDevices(init, maintenance.Testing.devices.PROVIDER);
}
