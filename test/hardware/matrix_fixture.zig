//! Test child for the supervisor contract. Never opens a device.
const std = @import("std");
var cancelled: std.atomic.Value(bool) = .init(false);
fn stop(_: std.os.linux.SIG) callconv(.c) void {
    cancelled.store(true, .monotonic);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 8) return error.InvalidTestArguments;
    if (std.mem.eql(u8, args[2], "seed")) try std.Io.Dir.cwd().createDir(init.io, try init.arena.allocator().print("{s}/seed", .{args[3]}), .default_dir);
    if (std.mem.eql(u8, args[2], "missing-evidence")) return;
    if (std.mem.eql(u8, args[2], "fail")) std.process.exit(7);
    if (std.mem.eql(u8, args[6], "pause") and !std.mem.eql(u8, args[2], "missing-checkpoint")) {
        const linux = std.os.linux;
        const action: linux.Sigaction = .{ .handler = .{ .handler = stop }, .mask = linux.sigemptyset(), .flags = 0 };
        if (linux.errno(linux.sigaction(.INT, &action, null)) != .SUCCESS) return error.SignalSetupFailed;
        try std.Io.File.stdout().writeStreamingAll(init.io, "PIZZA_HARDWARE_CUT\n");
        while (!cancelled.load(.monotonic)) try std.Io.sleep(init.io, .fromMilliseconds(10), .awake);
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"result\":\"cancelled\"}\n");
        std.process.exit(130);
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "{\"result\":\"verified\"}\n");
}
