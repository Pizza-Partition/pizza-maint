//! Explicit ordinary-image acceptance harness. Block devices and symlinks are
//! rejected by ImageDevice; this is deliberately separate from the root helper.
pub const enable_storage_test_support = true;
const std = @import("std");
const storage = @import("storage");
const maintenance = @import("maintenance.zig");
const compiler = @import("maintenance_compiler.zig");
const proto = @import("proto");
comptime {
    // Storage's linked native NTFS archive uses this Zig allocation/I/O ABI.
    _ = storage.ntfs.bridge;
}
pub const Manifest = struct {
    version: u16,
    session: []const u8,
    control: storage.model.Range,
    bootstrap_store: storage.recovery_store.CapsuleDescriptor,
    apply_store: storage.recovery_store.CapsuleDescriptor,
    cleanup_store: storage.recovery_store.CapsuleDescriptor,
    protected: []const storage.model.Range = &.{},
    bootstrap_program: []const u8,
    apply_program: []const u8,
    cleanup_program: []const u8,
    bootstrap_verification: Verification,
    apply_verification: Verification,
    cleanup_verification: Verification,
};
const Verification = @import("session_manifest.zig").Verification;
pub const CompileRequest = struct { version: u16, inventory: proto.wire.InventorySnapshot, draft: proto.wire.PlanDraft, resources: compiler.Resources };
pub fn compile(a: std.mem.Allocator, io: std.Io, request_path: []const u8, image_path: []const u8) ![]const u8 {
    const request = try std.json.parseFromSliceLeaky(CompileRequest, a, try std.Io.Dir.cwd().readFileAlloc(io, request_path, a, .limited(4 * 1024 * 1024)), .{});
    if (request.version != 1) return error.UnsupportedSessionManifest;
    const identity = try proto.hexDigest(request.draft.disk_identity);
    const disk = for (request.inventory.disks) |d| {
        if (d.identity) |id| if (std.mem.eql(u8, id, request.draft.disk_identity)) break d;
    } else return error.DiskIdentityNotFound;
    var image = try storage.testing.ImageDevice.openReadOnly(io, image_path, identity, disk.sector_size);
    defer image.close(io);
    const result = try compiler.compile(a, io, image.backend().reader(), request.inventory, request.draft, request.resources);
    const output = try a.print("{s}.compiled", .{request_path});
    try std.Io.Dir.cwd().createDir(io, output, .fromMode(0o700));
    var dir = try std.Io.Dir.cwd().openDir(io, output, .{});
    defer dir.close(io);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, output, a);
    const plans = [_]storage.program.Program{ result.bundle.bootstrap, result.bundle.apply, result.bundle.cleanup };
    const names = [_][]const u8{ "bootstrap.pzp", "apply.pzp", "cleanup.pzp" };
    for (plans, names) |p, name| try write(io, dir, name, p.encoded);
    const manifest: Manifest = .{
        .version = 1,
        .session = try a.dupe(u8, &std.fmt.bytesToHex(result.bundle.session, .lower)),
        .control = result.bundle.control,
        .bootstrap_store = result.bundle.bootstrap_store,
        .apply_store = result.bundle.apply_store,
        .cleanup_store = result.bundle.cleanup_store,
        .protected = result.bundle.protected,
        .bootstrap_program = try std.fs.path.join(a, &.{ absolute, names[0] }),
        .apply_program = try std.fs.path.join(a, &.{ absolute, names[1] }),
        .cleanup_program = try std.fs.path.join(a, &.{ absolute, names[2] }),
        .bootstrap_verification = try Verification.save(a, result.bootstrap),
        .apply_verification = try Verification.save(a, result.apply),
        .cleanup_verification = try Verification.save(a, result.cleanup),
    };
    try write(io, dir, "manifest.json", try std.json.Stringify.valueAlloc(a, manifest, .{ .whitespace = .indent_2 }));
    const directory_file = try dir.openFile(io, ".", .{ .allow_directory = true });
    defer directory_file.close(io);
    try directory_file.sync(io);
    return std.fs.path.join(a, &.{ absolute, "manifest.json" });
}
fn write(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}
fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !storage.program.Program {
    return storage.program.decode(a, try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(storage.program.MAX_ENCODED_BYTES)));
}
pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 3 and std.mem.eql(u8, args[1], "identify")) {
        const identity = try storage.testing.ImageDevice.identify(io, args[2]);
        try std.Io.File.stdout().writeStreamingAll(io, try a.print("{s}\n", .{std.fmt.bytesToHex(identity, .lower)}));
        return 0;
    }
    if (args.len != 4) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-session-image identify disposable.img\npizza-session-image compile request.json disposable.img\npizza-session-image <prepare|bootstrap|apply|status|recover|undo|accept|cleanup> manifest.json disposable.img\n");
        return 2;
    }
    if (std.mem.eql(u8, args[1], "compile")) {
        try std.Io.File.stdout().writeStreamingAll(io, try a.print("{s}\n", .{try compile(a, io, args[2], args[3])}));
        return 0;
    }
    const action = std.meta.stringToEnum(maintenance.Action, args[1]) orelse return error.UnknownMaintenanceAction;
    const manifest = try std.json.parseFromSliceLeaky(Manifest, a, try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(4 * 1024 * 1024)), .{});
    if (manifest.version != 1) return error.UnsupportedSessionManifest;
    const bundle: storage.recovery_session.Bundle = .{ .session = try @import("proto").hexDigest(manifest.session), .control = manifest.control, .bootstrap = try load(a, io, manifest.bootstrap_program), .apply = try load(a, io, manifest.apply_program), .cleanup = try load(a, io, manifest.cleanup_program), .bootstrap_store = manifest.bootstrap_store, .apply_store = manifest.apply_store, .cleanup_store = manifest.cleanup_store, .protected = manifest.protected };
    var image = if (action == .status) try storage.testing.ImageDevice.openReadOnly(io, args[3], bundle.bootstrap.target.identity, bundle.bootstrap.target.sector_size) else try storage.testing.ImageDevice.open(io, args[3], bundle.bootstrap.target.identity, bundle.bootstrap.target.sector_size);
    defer image.close(io);
    const compiled: compiler.Compiled = .{ .bundle = bundle, .allocator = a, .bootstrap = try manifest.bootstrap_verification.restore(a, bundle.bootstrap), .apply = try manifest.apply_verification.restore(a, bundle.apply), .cleanup = try manifest.cleanup_verification.restore(a, bundle.cleanup) };
    const verifier: ?storage.program_executor.Verifier = switch (action) {
        .bootstrap => compiled.verifier(.bootstrap),
        .apply => compiled.verifier(.apply),
        .cleanup => compiled.verifier(.cleanup),
        else => null,
    };
    const result = try maintenance.run(a, io, image.backend(), bundle, action, verifier, null);
    try std.Io.File.stdout().writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }));
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    return 0;
}
