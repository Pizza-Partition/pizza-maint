const std = @import("std");
const clap = @import("clap");

const initramfs = @import("initramfs");
const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--bundle <str>  Local bundle directory (required).
    \\--output <str>  Initramfs output path (required).
    \\--kernel-version <str>  Kernel release (default: the bundled 7.2.11 kernel).
    \\--uki-output <str>  Also assemble a block-aligned x86-64 UKI.
    \\--ukify <str>  systemd ukify executable (default: ukify).
    \\--stub <str>  Explicit x86-64 systemd EFI stub.
    \\--dry-run  Print the layer assembly command without creating the image.
);

/// Parses command-line options and delegates image creation to the initramfs module.
/// Prints the validated layer assembly command for --dry-run.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    checkout_root: []const u8,
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
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools image [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    }
    const command = try initramfs.build(allocator, io, environ, checkout_root, .{
        .bundle = parsed.args.bundle orelse return error.MissingBundle,
        .output = parsed.args.output orelse return error.MissingOutput,
        .kernel_version = parsed.args.@"kernel-version",
        .dry_run = parsed.args.@"dry-run" != 0,
    });
    if (parsed.args.@"uki-output") |output| {
        if (parsed.args.@"dry-run" == 0) try buildUki(allocator, io, environ, parsed.args.bundle.?, parsed.args.output.?, output, parsed.args.ukify orelse "ukify", parsed.args.stub orelse "/usr/lib/systemd/boot/efi/linuxx64.efi.stub");
    }
    if (parsed.args.@"dry-run" != 0)
        try std.Io.File.stdout().writeStreamingAll(
            io,
            try std.json.Stringify.valueAlloc(
                allocator,
                command,
                .{ .whitespace = .indent_2 },
            ),
        );
}

/// ukify owns PE/COFF assembly. Validate the embedded payloads and align the
/// resulting file for native FAT allocation proofs; no boot variables are touched.
fn buildUki(a: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, directory: []const u8, initrd: []const u8, output: []const u8, ukify: []const u8, stub: []const u8) !void {
    const utils = @import("utils");
    const lock = try std.json.parseFromSliceLeaky(struct { version: []const u8, url: []const u8, archive_sha256: []const u8, member: []const u8, sha256: []const u8 }, a, @embedFile("efi-stub.json"), .{});
    const stub_digest = try utils.filesystem.hashFileSha256(a, io, stub);
    if (!std.mem.eql(u8, stub_digest, lock.sha256)) return error.EfiStubDigestMismatch;
    const kernel = try std.fs.path.join(a, &.{ directory, "vmlinuz" });
    const tool = try utils.process.findExecutable(a, io, environ, ukify);
    _ = try utils.process.checkedOutput(a, io, environ, &.{ tool, "build", "--linux", kernel, "--initrd", initrd, "--cmdline", "console=ttyS0,115200n8 console=tty0 rdinit=/init pizza.kiosk=disable", "--os-release", "ID=pizza\nNAME=\"Pizza Maintenance\"\nVERSION_ID=4\n", "--uname", "7.2.11-arch1-1", "--stub", stub, "--output", output });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, output, a, .limited(512 * 1024 * 1024));
    const linux_bytes = try std.Io.Dir.cwd().readFileAlloc(io, kernel, a, .limited(64 * 1024 * 1024));
    const initrd_bytes = try std.Io.Dir.cwd().readFileAlloc(io, initrd, a, .limited(512 * 1024 * 1024));
    try validateUki(bytes, linux_bytes, initrd_bytes);
    const file = try std.Io.Dir.cwd().openFile(io, output, .{ .mode = .read_write });
    defer file.close(io);
    const padding = std.mem.alignForward(usize, bytes.len, 4096) - bytes.len;
    const zero: [4096]u8 = @splat(0);
    try file.writePositionalAll(io, zero[0..padding], bytes.len);
    try file.sync(io);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}.pizza.json", .{output}), .data = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u16, 1), .kind = "x86_64-uki", .signed = false, .image_sha256 = try utils.filesystem.hashFileSha256(a, io, output), .stub_sha256 = stub_digest, .kernel_sha256 = try utils.filesystem.hashFileSha256(a, io, kernel), .initrd_sha256 = try utils.filesystem.hashFileSha256(a, io, initrd) }, .{ .whitespace = .indent_2 }) });
}
fn validateUki(bytes: []const u8, kernel: []const u8, initrd: []const u8) !void {
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..2], "MZ")) return error.InvalidUki;
    const pe = std.mem.readInt(u32, bytes[60..64], .little);
    if (pe > bytes.len or bytes.len - pe < 24 or !std.mem.eql(u8, bytes[pe..][0..6], &.{ 'P', 'E', 0, 0, 0x64, 0x86 })) return error.InvalidUki;
    const count = std.mem.readInt(u16, bytes[pe + 6 ..][0..2], .little);
    const optional = std.mem.readInt(u16, bytes[pe + 20 ..][0..2], .little);
    const start = @as(usize, pe) + 24 + optional;
    if (count == 0 or count > 96 or optional < 70 or start > bytes.len or count * 40 > bytes.len - start or std.mem.readInt(u16, bytes[pe + 24 ..][0..2], .little) != 0x20b or std.mem.readInt(u16, bytes[pe + 24 + 68 ..][0..2], .little) != 10) return error.InvalidUki;
    var have_kernel = false;
    var have_initrd = false;
    var have_cmdline = false;
    for (0..count) |i| {
        const section = bytes[start + i * 40 ..][0..40];
        const size = std.mem.readInt(u32, section[8..12], .little);
        const raw_size = std.mem.readInt(u32, section[16..20], .little);
        const offset = std.mem.readInt(u32, section[20..24], .little);
        if (offset > bytes.len or raw_size > bytes.len - offset) return error.InvalidUki;
        const contents = bytes[offset..][0..@min(size, raw_size)];
        const name = std.mem.sliceTo(section[0..8], 0);
        if (std.mem.eql(u8, name, ".linux")) {
            if (have_kernel or !std.mem.eql(u8, contents, kernel)) return error.InvalidUki;
            have_kernel = true;
        }
        if (std.mem.eql(u8, name, ".initrd")) {
            if (have_initrd or !std.mem.eql(u8, contents, initrd)) return error.InvalidUki;
            have_initrd = true;
        }
        if (std.mem.eql(u8, name, ".cmdline")) {
            if (have_cmdline or contents.len == 0 or std.mem.indexOf(u8, contents, "rdinit=/init") == null) return error.InvalidUki;
            have_cmdline = true;
        }
    }
    if (!have_kernel or !have_initrd or !have_cmdline) return error.InvalidUki;
}
