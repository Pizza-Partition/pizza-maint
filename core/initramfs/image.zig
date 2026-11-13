const std = @import("std");
const utils = @import("utils");
const bundle = @import("bundle");
const bundle_build = @import("bundle_build");
const initramfs = @import("root.zig");

pub const Options = struct {
    bundle: []const u8,
    output: []const u8,
    kernel_version: ?[]const u8 = null,
    dry_run: bool = false,
    runtime_policy: bundle_build.release.RuntimePolicy = .attested_release,
};

/// Authenticate the prebuilt base and append Pizza's application layer.
pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    checkout_root: []const u8,
    options: Options,
) ![]const []const u8 {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, options.bundle, allocator);
    const output = try utils.filesystem.resolveOutputPath(allocator, io, checkout_root, options.output);
    const manifest = (try bundle_build.verify(allocator, io, root)).manifest;
    const components = manifest.object.get("components").?.object;
    const pid1 = try bundle.rooted(allocator, io, root, components.get("pizza-init").?.string);
    const pid1_meta = try utils.elf.metadata(allocator, io, pid1);
    if (pid1_meta.interp.len != 0 or pid1_meta.needed.len != 0) return error.Pid1MustBeStatic;
    const kernel = manifest.object.get("kernel") orelse return error.MissingKernelInventory;
    if (kernel != .object) return error.ExpectedObject;
    const release = kernel.object.get("release") orelse return error.MissingField;
    if (release != .string or !std.mem.eql(u8, release.string, "7.2.11-arch1-1")) return error.KernelModulesVersionMismatch;
    if (options.kernel_version) |selected| if (!std.mem.eql(u8, selected, release.string)) return error.KernelModulesVersionMismatch;
    const command = try allocator.dupe([]const u8, if (options.runtime_policy == .local_candidate)
        &.{ "pizza-tools", "image", "--candidate-runtime", "--bundle", root, "--output", output }
    else
        &.{ "pizza-tools", "image", "--bundle", root, "--output", output });
    if (options.dry_run) return command;
    try bundle_build.image(allocator, io, environ, root, output, options.runtime_policy);
    const image = try std.Io.Dir.cwd().openFile(io, output, .{ .mode = .read_write });
    defer image.close(io);
    // Preserve the existing unprivileged /dev/console archive helper.
    try image.writePositionalAll(io, try initramfs.console(allocator), (try image.stat(io)).size);
    try image.sync(io);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try allocator.print("{s}.pizza.json", .{output}),
        .data = try std.json.Stringify.valueAlloc(allocator, .{
            .version = @as(u16, 1),
            .development = false,
            .kernel_version = release.string,
            .image_sha256 = try utils.filesystem.hashFileSha256(allocator, io, output),
        }, .{ .whitespace = .indent_2 }),
    });
    return command;
}
