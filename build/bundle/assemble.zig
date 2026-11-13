//! Add Pizza's own programs without unpacking the authenticated base.
const std = @import("std");
const files = @import("files.zig");
const release = @import("release.zig");
const application_contract = @import("application.zig");
pub const Options = struct {
    runtime: []const u8,
    init: []const u8,
    maintenance: []const u8,
    destination: []const u8,
    lock: []const u8 = release.LOCK_PATH,
    policy: release.RuntimePolicy = .attested_release,
};

pub fn assemble(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, options: Options) !void {
    const lock = try release.readLock(a, io, options.lock);
    try application_contract.verify(a, io, options.maintenance);
    const base = try release.verifySource(a, io, env, options.runtime, lock, options.policy);
    const output = try files.Output.init(a, io, options.destination, true);
    defer output.deinit(io);
    const root = output.temporary;
    for ([_][]const u8{ lock.asset, lock.kernel_asset, lock.metadata_asset }) |name|
        try std.Io.Dir.cwd().copyFile(try std.fs.path.join(a, &.{ options.runtime, name }), .cwd(), try std.fs.path.join(a, &.{ root, name }), io, .{});
    if (options.policy == .attested_release)
        try std.Io.Dir.cwd().copyFile(try std.fs.path.join(a, &.{ options.runtime, "attestation.json" }), .cwd(), try std.fs.path.join(a, &.{ root, "attestation.json" }), io, .{});
    try std.Io.Dir.cwd().copyFile(options.lock, .cwd(), try std.fs.path.join(a, &.{ root, "release.json" }), io, .{});
    const overlay = try std.fs.path.join(a, &.{ root, "overlay" });
    const application = try std.fs.path.join(a, &.{ overlay, "opt/pizza/bundle/bin/pizza-maint" });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(application).?);
    try std.Io.Dir.cwd().copyFile(options.init, .cwd(), try std.fs.path.join(a, &.{ overlay, "init" }), io, .{ .permissions = .fromMode(0o755) });
    try std.Io.Dir.cwd().copyFile(options.maintenance, .cwd(), application, io, .{ .permissions = .fromMode(0o755) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.json" }), .data = try a.print("{s}\n", .{try std.json.Stringify.valueAlloc(a, .{
        .format = @as(u16, 3),
        .kind = "pizza-application",
        .architecture = "x86_64",
        .profile = "cpu-maint-v1",
        .working_directory = "bundle-root",
        .layout = "base-plus-overlay",
        .kernel = .{ .version = base.kernel_version, .release = base.kernel_release, .image = "vmlinuz" },
        .components = .{ .@"pizza-init" = "overlay/init", .@"pizza-maint" = "overlay/opt/pizza/bundle/bin/pizza-maint" },
        .provenance = .{ .policy = options.policy, .repository = release.REPOSITORY, .tag = lock.tag, .commit = lock.commit, .sha256 = lock.sha256 },
    }, .{ .whitespace = .indent_2 })}) });
    try std.Io.Dir.cwd().renamePreserve(root, .cwd(), output.target, io);
}
