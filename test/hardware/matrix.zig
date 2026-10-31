//! Offline physical acceptance owner. Children use the same binary and production
//! BlockDevice admission; only this process injects signals into its own children.
const std = @import("std");
const storage = @import("storage");
const linux = std.os.linux;
const Fs = std.Io.Dir;
const Filesystem = storage.model.Filesystem;
const Fault = enum { none, cancel, kill };
const Fixture = struct { filesystem: Filesystem, capacity: u64, smaller_bytes: u64, sector_size: u32 };
const Target = struct { identity: [64]u8, capacity: u64, sector_size: u32 };
const Manifest = struct { version: u32 = 1, target: Target, fixtures: []const Fixture, binary_sha256: [64]u8, empty_device_asserted: bool = true };
const Record = struct { filesystem: Filesystem, label: []const u8, action: []const u8, fault: Fault, home: []const u8, returncode: i32, checkpoint_observed: bool };

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn json(a: std.mem.Allocator, io: std.Io, value: anytype) !void {
    if (@import("builtin").is_test) return;
    try std.Io.File.stdout().writeStreamingAll(io, try a.print("{s}\n", .{try std.json.Stringify.valueAlloc(a, value, .{})}));
}
fn exists(io: std.Io, path: []const u8) !bool {
    Fs.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
fn atomicJson(a: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8, value: anytype) !void {
    var dir = try Fs.cwd().openDir(io, root, .{ .follow_symlinks = false });
    defer dir.close(io);
    const temporary = try a.print("{s}.next", .{name});
    const file = try dir.createFile(io, temporary, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }));
    try file.sync(io);
    try dir.rename(temporary, dir, name, io);
    const directory_file = try dir.openFile(io, ".", .{ .allow_directory = true });
    defer directory_file.close(io);
    try directory_file.sync(io);
}
fn readJson(comptime T: type, a: std.mem.Allocator, io: std.Io, path: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, try Fs.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)), .{});
}
fn hashFile(io: std.Io, path: []const u8) ![64]u8 {
    const file = try Fs.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(io, &bytes, offset);
        hash.update(bytes[0..count]);
        if (count < bytes.len) break;
        offset += count;
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}
fn exited(pid: linux.pid_t) !bool {
    var info = std.mem.zeroes(linux.siginfo_t);
    switch (linux.errno(linux.waitid(.PID, @intCast(pid), &info, linux.W.EXITED | linux.W.NOWAIT | linux.W.NOHANG, null))) {
        .SUCCESS => return info.fields.common.first.piduid.pid != 0,
        .INTR => return false,
        else => return error.ChildStatusFailed,
    }
}
pub const Run = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    binary: []const u8,
    device: []const u8,
    target: Target,
    results: std.ArrayList(Record) = .empty,

    fn find(self: *@This(), format: Filesystem, label: []const u8) ?Record {
        for (self.results.items) |record| if (record.filesystem == format and equal(record.label, label)) return record;
        return null;
    }
    pub fn step(self: *@This(), format: Filesystem, label: []const u8, action: []const u8, fault: Fault, recovery_of: ?[]const u8) !void {
        if (self.find(format, label) != null) return;
        const a, const io = .{ self.allocator, self.io };
        const home = try a.print("{s}/{t}", .{ self.root, format });
        if (!try exists(io, home)) try Fs.cwd().createDir(io, home, .fromMode(0o700));
        const cases = try a.print("{s}/cases", .{home});
        if (!try exists(io, cases)) try Fs.cwd().createDir(io, cases, .fromMode(0o700));
        const directory = if (recovery_of) |original| (self.find(format, original) orelse return error.MissingInterruptedCase).home else try a.print("{s}/{s}", .{ cases, label });
        if (recovery_of == null) {
            if (try exists(io, directory)) {
                if (!@import("builtin").is_test) std.log.warn("Unrecorded case retained at {s}; recover it before retrying", .{directory});
                return error.UnrecordedCaseRequiresRecovery;
            }
            try Fs.cwd().createDir(io, directory, .fromMode(0o700));
        }
        try json(a, io, .{ .start = label, .filesystem = format, .action = action, .fault = fault });
        const output_path = try a.print("{s}/{s}.stdout", .{ directory, label });
        const error_path = try a.print("{s}/{s}.stderr", .{ directory, label });
        const output = try Fs.cwd().createFile(io, output_path, .{ .exclusive = true, .read = true });
        defer output.close(io);
        const errors = try Fs.cwd().createFile(io, error_path, .{ .exclusive = true });
        defer errors.close(io);
        try atomicJson(a, io, directory, try a.print("{s}.request.json", .{label}), .{ .device = self.device, .target = self.target, .filesystem = format, .action = action, .fault = fault });
        var child = try std.process.spawn(io, .{
            .argv = &.{ self.binary, @tagName(format), action, home, directory, &self.target.identity, if (fault == .none) "none" else "pause", self.device },
            .stdin = .ignore,
            .stdout = .{ .file = output },
            .stderr = .{ .file = errors },
        });
        defer child.kill(io);
        var observed = false;
        var done = false;
        for (0..60000) |_| {
            var bytes: [16384]u8 = undefined;
            const count = try output.readPositionalAll(io, &bytes, 0);
            if (!observed and std.mem.indexOf(u8, bytes[0..count], "PIZZA_HARDWARE_CUT\n") != null) {
                if (fault == .none) return error.UnexpectedFaultCheckpoint;
                observed = true;
                if (linux.errno(linux.kill(child.id.?, if (fault == .kill) .KILL else .INT)) != .SUCCESS) return error.ChildSignalFailed;
            }
            if (try exited(child.id.?)) {
                done = true;
                break;
            }
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
        if (!done) return error.HardwareCaseTimedOut;
        const term = try child.wait(io);
        const code: i32 = switch (term) {
            .exited => |code| code,
            .signal => |signal| -@as(i32, @intCast(@backingInt(signal))),
            else => return error.UnexpectedChildStatus,
        };
        const record: Record = .{ .filesystem = format, .label = label, .action = action, .fault = fault, .home = directory, .returncode = code, .checkpoint_observed = observed };
        try atomicJson(a, io, directory, try a.print("{s}.exit.json", .{label}), record);
        const expected: i32 = switch (fault) {
            .none => 0,
            .cancel => 130,
            .kill => -9,
        };
        if (code != expected or (fault != .none and !observed)) {
            if (!@import("builtin").is_test) std.log.warn("Case {t}/{s} failed ({d}); inspect {s}; recovery records retained", .{ format, label, code, error_path });
            return error.HardwareCaseFailed;
        }
        // A successful exit must include structured verification evidence.
        if (fault != .kill) {
            var bytes: [16384]u8 = undefined;
            const count = try output.readPositionalAll(io, &bytes, 0);
            var lines = std.mem.splitScalar(u8, bytes[0..count], '\n');
            var evidence = false;
            while (lines.next()) |line| if (line.len > 0 and line[0] == '{') {
                _ = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
                evidence = true;
            };
            if (!evidence) return error.MissingChildEvidence;
        }
        try self.results.append(a, record);
        try atomicJson(a, io, self.root, "results.json", self.results.items);
        try json(a, io, .{ .passed = label, .filesystem = format, .returncode = code });
    }
    fn filesystem(self: *@This(), format: Filesystem) !void {
        const Step = struct { label: []const u8, action: []const u8, fault: Fault = .none, recovery_of: ?[]const u8 = null };
        const steps = [_]Step{
            .{ .label = "create", .action = "create" },
            .{ .label = "oracle-created", .action = "oracle-empty" },
            .{ .label = "seed", .action = "seed" },
            .{ .label = "query-check", .action = "query-check" },
            .{ .label = "oracle-seeded", .action = "oracle" },
            .{ .label = "corrupt", .action = "corrupt" },
            .{ .label = "repair", .action = "repair" },
            .{ .label = "oracle-repaired", .action = "oracle" },
            .{ .label = "cancel-shrink", .action = "shrink", .fault = .cancel },
            .{ .label = "recover-cancel-1", .action = "recover", .recovery_of = "cancel-shrink" },
            .{ .label = "recover-cancel-2", .action = "recover", .recovery_of = "cancel-shrink" },
            .{ .label = "oracle-cancelled", .action = "oracle" },
            .{ .label = "kill-shrink", .action = "shrink", .fault = .kill },
            .{ .label = "kill-recovery", .action = "recover", .fault = .kill, .recovery_of = "kill-shrink" },
            .{ .label = "recover-killed-1", .action = "recover", .recovery_of = "kill-shrink" },
            .{ .label = "recover-killed-2", .action = "recover", .recovery_of = "kill-shrink" },
            .{ .label = "oracle-recovered", .action = "oracle" },
            .{ .label = "shrink", .action = "shrink" },
            .{ .label = "oracle-shrunk", .action = "oracle" },
            .{ .label = "grow", .action = "grow" },
            .{ .label = "oracle-grown", .action = "oracle" },
            .{ .label = "copy-alias-rejected", .action = "copy-alias" },
            .{ .label = "kill-copy", .action = "copy", .fault = .kill },
            .{ .label = "recover-copy-1", .action = "recover", .recovery_of = "kill-copy" },
            .{ .label = "recover-copy-2", .action = "recover", .recovery_of = "kill-copy" },
            .{ .label = "copy", .action = "copy" },
            .{ .label = "oracle-copied", .action = "oracle" },
            .{ .label = "query-check-final", .action = "query-check" },
        };
        for (steps) |step_| try self.step(format, step_.label, step_.action, step_.fault, step_.recovery_of);
    }
};
const HELP =
    \\Usage: pizza-filesystems-hardware --device /dev/DEVICE [--journal-home /absolute/new/home --run [--resume]]
    \\Without --run: read-only device and registered-fixture preflight.
    \\--run asserts the selected device/partition is empty and disposable. Its first
    \\128 MiB are overwritten sequentially with ext2/ext3/ext4/FAT32/NTFS/Btrfs.
    \\Recovery files and read-only clone fixtures require another physical disk.
    \\Targets must be unmounted, at least 128 MiB, and have 512-byte logical sectors.
    \\Targets containing hardware partitions are refused. No hardware identity is compiled in.
    \\--resume binds the saved identity, geometry and executable; skips passed cases.
    \\A failed case retains recovery records and stops the matrix before the next format.
    \\
;
pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const a, const io = .{ init.arena.allocator(), init.io };
    var device: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var execute = false;
    var resuming = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (equal(arg, "--help") or equal(arg, "-h")) return std.Io.File.stdout().writeStreamingAll(io, HELP);
        if (equal(arg, "--run")) {
            execute = true;
            continue;
        }
        if (equal(arg, "--resume")) {
            resuming = true;
            continue;
        }
        if (equal(arg, "--device") or equal(arg, "--journal-home")) {
            index += 1;
            if (index == args.len or !std.fs.path.isAbsolute(args[index])) return error.AbsoluteOptionPathRequired;
            if (equal(arg, "--device")) {
                if (device != null) return error.DuplicateOption;
                device = args[index];
            } else {
                if (root != null) return error.DuplicateOption;
                root = args[index];
            }
        } else return error.UnknownHardwareOption;
    }
    const path = device orelse {
        try std.Io.File.stderr().writeStreamingAll(io, HELP);
        return error.MissingDevice;
    };
    if (resuming and !execute) return error.ResumeRequiresRun;
    var block = try storage.block_device.BlockDevice.open(a, io, path, null, null, .probe);
    const target: Target = .{ .identity = std.fmt.bytesToHex(block.target.identity, .lower), .capacity = block.target.capacity, .sector_size = block.target.sector_size };
    var info = try storage.probe.queryDevice(a, io, path, block.backend().reader());
    info.physical_block_size = block.evidence.physical;
    block.close(io);
    const cases = try storage.testing.filesystems.cases(a, storage.filesystem.BUILTIN);
    const fixtures = try a.alloc(Fixture, cases.len);
    for (cases, fixtures) |case, *fixture| fixture.* = .{ .filesystem = case.fixture.filesystem, .capacity = case.fixture.capacity, .smaller_bytes = case.fixture.smaller_bytes, .sector_size = case.fixture.sector_size };
    try json(a, io, .{ .target = info, .fixtures = fixtures, .read_only = !execute });
    for (fixtures) |fixture| {
        if (target.capacity < fixture.capacity) return error.HardwareTargetTooSmall;
        if (target.sector_size != fixture.sector_size) return error.UnsupportedHardwareFixtureSectorSize;
    }
    const home = root orelse {
        if (!execute) return;
        return error.MissingJournalHome;
    };
    if (!execute) return;
    if (!resuming and (info.partitions.len != 0 or
        (info.filesystem == null and info.partition_table_error != null and !equal(info.partition_table_error.?, "InvalidMbrSignature")))) return error.PartitionedOrUnrecognizedTarget;
    if (!resuming) try Fs.cwd().createDir(io, home, .fromMode(0o700));
    var dir = try Fs.cwd().openDir(io, home, .{ .follow_symlinks = false });
    defer dir.close(io);
    if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0) return error.RecoveryHomeMustBePrivate;
    const lock = try dir.createFile(io, "matrix.lock", .{ .read = true, .truncate = false });
    defer lock.close(io);
    if (linux.errno(linux.flock(lock.handle, 2 | 4)) != .SUCCESS) return error.HardwareMatrixAlreadyRunning;
    const binary = try a.print("{s}/pizza-filesystems-hardware", .{home});
    const manifest_path = try a.print("{s}/manifest.json", .{home});
    if (resuming) {
        const manifest = try readJson(Manifest, a, io, manifest_path);
        if (manifest.version != 1 or !std.meta.eql(target, manifest.target) or !std.meta.eql(try hashFile(io, binary), manifest.binary_sha256)) return error.HardwareManifestChanged;
        const current = try std.json.Stringify.valueAlloc(a, fixtures, .{});
        const saved = try std.json.Stringify.valueAlloc(a, manifest.fixtures, .{});
        if (!equal(current, saved)) return error.HardwareFixtureContractChanged;
    } else {
        const current = try Fs.cwd().realPathFileAlloc(io, "/proc/self/exe", a);
        try Fs.cwd().copyFile(current, dir, "pizza-filesystems-hardware", io, .{});
        const file = try dir.openFile(io, "pizza-filesystems-hardware", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o700));
        try file.sync(io);
        try atomicJson(a, io, home, "manifest.json", Manifest{ .target = target, .fixtures = fixtures, .binary_sha256 = try hashFile(io, binary) });
    }
    var runner: Run = .{ .allocator = a, .io = io, .root = home, .binary = binary, .device = path, .target = target };
    const results_path = try a.print("{s}/results.json", .{home});
    if (resuming and try exists(io, results_path)) try runner.results.appendSlice(a, try readJson([]Record, a, io, results_path));
    // Production exclusivity and independent-recovery admission precede even
    // fixture initialization. Filesystem targets remain bounded partition views.
    try runner.step(.vfat, "admit", "admit", .none, null);
    try runner.step(.vfat, "initialize", "erase", .none, null);
    for (fixtures) |fixture| try runner.filesystem(fixture.filesystem);
    const last = fixtures[fixtures.len - 1].filesystem;
    try runner.step(last, "final-create", "create", .none, null);
    try runner.step(last, "final-oracle", "oracle-empty", .none, null);
    const report = .{ .target = target, .formats_completed = fixtures, .cases_passed = runner.results.items.len, .final_empty_filesystem = last, .hardware_power_removal_tested = false };
    try atomicJson(a, io, home, "report.json", report);
    try json(a, io, report);
}
