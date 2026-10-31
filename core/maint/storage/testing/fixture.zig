//! Synthetic block fixtures exercise the shared transaction layer, never a filesystem.
const std = @import("std");
const model = @import("../model.zig");
const device = @import("../device.zig");
const program = @import("../program.zig");
const execution = @import("../program_executor.zig");
const recovery = @import("../recovery_store.zig");
const executor = @import("executor.zig");
const Image = @import("image.zig").Image;

pub const IDENTITY: model.Digest = @splat(0x71);
pub const OLD_A: [512]u8 = @splat(0x11);
pub const OLD_B: [512]u8 = @splat(0x22);
pub const NEW_A: [512]u8 = @splat(0x33);
pub const NEW_B: [512]u8 = @splat(0x44);
pub const Stats = struct { transactions: u32 = 0, unprepared: u32 = 0, rolled_back: u32 = 0, committed: u32 = 0, interrupted_restore: u32 = 0 };

pub fn create(a: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, "target.raw" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .read = true });
    defer file.close(io);
    try file.setLength(io, 64 * 1024);
    try file.writePositionalAll(io, &OLD_A, 0);
    try file.writePositionalAll(io, &OLD_B, 512);
    try file.sync(io);
    return path;
}

pub fn compile(a: std.mem.Allocator, io: std.Io, reader: device.Reader) !program.Program {
    var builder = program.Builder.init(a, reader);
    try builder.write(io, .{ .offset = 0, .length = 512 }, &NEW_A, false);
    try builder.write(io, .{ .offset = 512, .length = 512 }, &NEW_B, false);
    return builder.finish();
}

pub fn verify(_: *const anyopaque, io: std.Io, reader: device.Reader) !bool {
    var metadata: [1024]u8 = undefined;
    try reader.readInto(io, 0, &metadata);
    return std.mem.eql(u8, metadata[0..512], &NEW_A) and std.mem.eql(u8, metadata[512..], &NEW_B);
}

fn reject(_: *const anyopaque, _: std.Io, _: device.Reader) !bool {
    return false;
}

pub fn assertBaseline(io: std.Io, reader: device.Reader, committed: bool) !void {
    var metadata: [1024]u8 = undefined;
    try reader.readInto(io, 0, &metadata);
    if (!std.mem.eql(u8, metadata[0..512], if (committed) &NEW_A else &OLD_A) or !std.mem.eql(u8, metadata[512..], if (committed) &NEW_B else &OLD_B)) return error.FixtureMetadataMismatch;
}

pub fn run(a: std.mem.Allocator, io: std.Io) !Stats {
    const root = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-native-storage-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var stats: Stats = .{};
    for (0..9) |index| {
        const home = try a.print("{s}/case-{d}", .{ root, index });
        try std.Io.Dir.cwd().createDir(io, home, .fromMode(0o700));
        const path = try create(a, io, home);
        const log_path = try std.fs.path.join(a, &.{ home, "recovery" });
        try std.Io.Dir.cwd().createDir(io, log_path, .fromMode(0o700));
        var directory = try std.Io.Dir.cwd().openDir(io, log_path, .{ .follow_symlinks = false });
        defer directory.close(io);
        {
            var image = try Image.open(io, path, IDENTITY, 512);
            defer image.close(io);
            const plan = try compile(a, io, image.reader());
            const cuts = [_]executor.Cut{ .program, .ready, .written, .validated, .committed };
            const cut: ?executor.Cut = if (index < cuts.len) cuts[index] else if (index == 8) .written else null;
            if (index == 5) image.tear_write_at = 0;
            var failed = false;
            var files: recovery.Files = .{ .directory = directory };
            defer files.deinit(io);
            executor.runProgram(a, io, image.backend(), files.store(), plan, &.{}, .{ .context = &IDENTITY, .check = if (index == 6) reject else verify }, cut) catch |err| {
                const expected: anyerror = if (index < cuts.len or index == 8) error.InjectedExecutionInterruption else if (index == 5) error.InjectedPartialMetadata else if (index == 6) error.ProgramVerificationFailed else return err;
                if (err != expected) return err;
                failed = true;
            };
            if ((index != 7) != failed) return error.MissingTransactionFault;
        }
        // Close all target handles and rebuild the image backend from disk. The
        // recovery code has no access to the executing object's memory.
        var image = try Image.open(io, path, IDENTITY, 512);
        defer image.close(io);
        if (index == 8) {
            if (executor.recover(io, image.backend(), directory, .{}, 0)) |_| return error.MissingRestoreFault else |err| {
                if (err != error.InjectedRestoreInterruption) return err;
            }
            stats.interrupted_restore += 1;
        }
        const state = try executor.recover(io, image.backend(), directory, .{}, null);
        switch (state) {
            .unprepared => stats.unprepared += 1,
            .rolled_back => stats.rolled_back += 1,
            .committed => stats.committed += 1,
            .verified => return error.UnexpectedDeferredTransaction,
        }
        try assertBaseline(io, image.reader(), state == .committed);
        if (state == .committed and !try verify(&IDENTITY, io, image.reader())) return error.FixturePatchMismatch;
        if (try executor.recover(io, image.backend(), directory, .{}, null) != state) return error.RecoveryNotIdempotent;
        stats.transactions += 1;
    }
    return stats;
}
