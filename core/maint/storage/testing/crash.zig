//! Host-only destructive-process acceptance. All targets are temporary files.
pub const enable_storage_test_support = true;
const std = @import("std");
const storage = @import("storage");
const model = storage.model;
const device = storage.device;
const REGISTRY = storage.filesystem.BUILTIN;
const fixtures = storage.testing.filesystems;
const Image = storage.testing.Image;
const IDENTITY = storage.testing.fixture.IDENTITY;
const SOURCE_IDENTITY: model.Digest = @splat(0x72);
fn sourcePath(a: std.mem.Allocator, destination: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ std.fs.path.dirname(destination).?, "source", "target.raw" });
}
const tools = storage.testing.tools;

const Random = struct {
    state: u64,
    fn next(self: *Random) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state;
    }
};

// Fragment only the test backend's writes. A random SIGKILL can land between
// arbitrary byte writes, even inside a sector, without cooperative error paths.
const Writer = struct {
    image: *Image,
    random: Random,
    slow: bool,
    announced: bool = false,
    allow_announcement: bool = false,

    fn backend(self: *@This()) device.Device {
        return .{ .context = self, .target = self.image.target, .vtable = &.{ .reader = .{ .read = read }, .write = write, .flush = flush, .validate = validate } };
    }
    fn read(context: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self: *const @This() = @ptrCast(@alignCast(context));
        return self.image.reader().readInto(io, offset, bytes);
    }
    fn write(context: *anyopaque, io: std.Io, offset: u64, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        var done: usize = 0;
        while (done != bytes.len) {
            const count = if (self.slow) @min(bytes.len - done, 257 + self.random.next() % 4096) else bytes.len - done;
            try self.image.file.writePositionalAll(io, bytes[done..][0..count], offset + done);
            done += count;
            if (self.allow_announcement and !self.announced) {
                self.announced = true;
                try std.Io.File.stdout().writeStreamingAll(io, "W");
                if (self.slow) try std.Io.sleep(io, .fromNanoseconds(10_000_000), .awake);
            }
            if (self.slow) try std.Io.sleep(io, .fromNanoseconds(20000 + self.random.next() % 180000), .awake);
        }
    }
    fn flush(context: *anyopaque, io: std.Io) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.image.file.sync(io);
    }
    fn validate(context: *const anyopaque, io: std.Io, target: model.Target) !void {
        const self: *const @This() = @ptrCast(@alignCast(context));
        if (!self.image.target.same(target)) return error.TransactionTargetMismatch;
        try self.image.backend().validate(io);
    }
};

fn operation(name: []const u8, fixture: fixtures.Fixture) !storage.testing.executor.Action {
    if (std.mem.eql(u8, name, "create")) return .{ .kind = .create, .filesystem = fixture.filesystem };
    if (std.mem.eql(u8, name, "repair")) return .{ .kind = .repair };
    if (std.mem.eql(u8, name, "grow")) return .{ .kind = .grow, .target_bytes = fixture.capacity };
    if (std.mem.eql(u8, name, "shrink")) return .{ .kind = .shrink, .target_bytes = fixture.smaller_bytes };
    return error.InvalidOperation;
}

fn worker(_: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len != 9) return error.InvalidArguments;
    var budget = try storage.memory.Controller.init(io, .{});
    var arena: std.heap.ArenaAllocator = .init(budget.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    var image = try Image.open(io, args[2], IDENTITY, try std.fmt.parseInt(u32, args[8], 10));
    defer image.close(io);
    var directory = try std.Io.Dir.cwd().openDir(io, args[3], .{});
    defer directory.close(io);
    var writer: Writer = .{ .image = &image, .random = .{ .state = try std.fmt.parseInt(u64, args[6], 10) }, .slow = std.mem.eql(u8, args[7], "slow"), .allow_announcement = true };
    if (std.mem.eql(u8, args[1], "recover")) {
        try std.Io.File.stdout().writeStreamingAll(io, "P");
        var files: storage.recovery_store.Files = .{ .directory = directory };
        defer files.deinit(io);
        const outcome = try storage.program_executor.recover(a, io, writer.backend().withMemory(&budget), files.store(), null);
        try budget.check();
        try directory.writeFile(io, .{ .sub_path = "outcome", .data = @tagName(outcome) });
        return;
    }
    const filesystem = std.meta.stringToEnum(model.Filesystem, args[5]) orelse return error.InvalidFilesystem;
    const cases = try fixtures.cases(a, REGISTRY);
    const fixture = found: {
        for (cases) |case| if (case.fixture.filesystem == filesystem) break :found case.fixture;
        return error.MissingFilesystemFixture;
    };
    var source: ?Image = null;
    defer if (source) |*opened| opened.close(io);
    const cloning = std.mem.eql(u8, args[4], "copy");
    if (cloning) source = try Image.open(io, try sourcePath(a, args[2]), SOURCE_IDENTITY, fixture.sector_size);
    const target_reader = image.reader().withMemory(&budget);
    const txn = if (source) |*opened| try storage.service.copy(a, io, opened.reader().withMemory(&budget), target_reader, .{ .offset = 0, .length = target_reader.target.capacity }) else try storage.service.filesystem(a, io, target_reader, .{ .offset = 0, .length = target_reader.target.capacity }, if (std.mem.eql(u8, args[4], "create")) driverFor(filesystem) else null, .{ .operation = (try operation(args[4], fixture)).kind, .bytes = (try operation(args[4], fixture)).target_bytes });
    if (txn.program.steps.len == 0) return error.ExpectedMutation;
    const Context = struct {
        a: std.mem.Allocator,
        plan: storage.service.Plan,
        fn check(context: *const anyopaque, inner_io: std.Io, reader: device.Reader) !bool {
            const self: *const @This() = @ptrCast(@alignCast(context));
            return self.plan.verify(self.a, inner_io, reader);
        }
    };
    const context: Context = .{ .a = a, .plan = txn };
    var files: storage.recovery_store.Files = .{ .directory = directory };
    defer files.deinit(io);
    const sources: []const device.Reader = if (source) |*opened| &.{opened.reader().withMemory(&budget)} else &.{};
    try std.Io.File.stdout().writeStreamingAll(io, "P");
    try storage.program_executor.executeWithSources(a, io, writer.backend().withMemory(&budget), files.store(), txn.program, sources, .{ .context = &context, .check = Context.check }, null);
    try budget.check();
}

fn driverFor(filesystem: model.Filesystem) storage.semantic.Driver {
    return REGISTRY.get(filesystem) catch unreachable;
}

fn exists(io: std.Io, directory: std.Io.Dir, name: []const u8) !bool {
    const file = directory.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

fn launch(io: std.Io, argv: []const []const u8, phase: u64, random: *Random) !bool {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe });
    defer child.kill(io);
    var buffer: [32]u8 = undefined;
    var output = child.stdout.?.reader(io, &buffer);
    if (phase != 0) {
        if (try output.interface.takeByte() != 'P') return error.MissingPlanHandshake;
    }
    if (phase == 2) {
        const first_write = output.interface.takeByte() catch |err| {
            // Explicit create/copy discard has no old destination bytes to
            // restore, so recovery can finish without a target write.
            if (err == error.EndOfStream and std.mem.eql(u8, argv[1], "recover")) {
                if (!(try child.wait(io)).success()) return error.CrashWorkerFailed;
                return false;
            }
            return err;
        };
        if (first_write != 'W') return error.MissingWriteHandshake;
    }
    if (phase != 3) {
        // Metadata-only recovery may finish within the old 8 ms delay. Kill
        // immediately after its first real write to require an actual restore
        // interruption even when the journal contains only a few sectors.
        if (!(phase == 2 and std.mem.eql(u8, argv[1], "recover")))
            try std.Io.sleep(io, .fromNanoseconds(random.next() % 8_000_000), .awake);
        const code = std.os.linux.kill(child.id.?, .KILL);
        if (std.os.linux.errno(code) != .SUCCESS) return error.ChildKillFailed;
    }
    const term = try child.wait(io);
    if (term == .signal and term.signal == .KILL) return true;
    if (!term.success()) return error.CrashWorkerFailed;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len > 1 and (std.mem.eql(u8, args[1], "write") or std.mem.eql(u8, args[1], "recover"))) return worker(a, io, args);
    var seed: u64 = undefined;
    std.Io.random(io, std.mem.asBytes(&seed));
    var requested_rounds: ?usize = null;
    var requested_filesystem: ?model.Filesystem = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 == args.len) return error.InvalidArguments;
        if (std.mem.eql(u8, args[index], "--seed")) {
            seed = try std.fmt.parseInt(u64, args[index + 1], 0);
        } else if (std.mem.eql(u8, args[index], "--rounds")) {
            requested_rounds = try std.fmt.parseInt(usize, args[index + 1], 10);
        } else if (std.mem.eql(u8, args[index], "--filesystem")) {
            requested_filesystem = std.meta.stringToEnum(model.Filesystem, args[index + 1]) orelse return error.InvalidFilesystem;
        } else return error.InvalidArguments;
    }
    const cases = try fixtures.cases(a, REGISTRY);
    const Trial = struct { case: fixtures.Case, kind: model.Kind };
    var trials: std.ArrayList(Trial) = .empty;
    for (cases) |case| for ([_]model.Kind{ .create, .repair, .grow, .shrink, .copy }) |kind| {
        if (requested_filesystem) |filesystem| if (case.fixture.filesystem != filesystem) continue;
        if (case.supports(kind)) try trials.append(a, .{ .case = case, .kind = kind });
    };
    if (trials.items.len == 0) return error.NoWritableFilesystemCases;
    const minimum = trials.items.len * 4;
    const rounds = requested_rounds orelse minimum;
    if (rounds < minimum or rounds > 10000) return error.InvalidRounds;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-storage-sigkill-");
    // Preserve failed artifacts with the seed and round in the diagnostics.
    std.debug.print("filesystem SIGKILL seed={d} rounds={d} artifacts={s}\n", .{ seed, rounds, home });
    var random: Random = .{ .state = seed };
    var killed: usize = 0;
    var restore_killed: usize = 0;
    var commits: usize = 0;
    var rollbacks: usize = 0;
    var unprepared: usize = 0;
    var write_kills: usize = 0;
    for (0..rounds) |round| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const case_home = try std.fs.path.join(scratch, &.{ home, try scratch.print("round-{d}", .{round}) });
        try std.Io.Dir.cwd().createDir(io, case_home, .default_dir);
        const trial = trials.items[round % trials.items.len];
        const fixture = trial.case.fixture;
        const filesystem = fixture.filesystem;
        const op = @tagName(trial.kind);
        const phase = (round / trials.items.len) % 4;
        if (round % trials.items.len == 0) std.debug.print("  round={d}/{d} phase={d}\n", .{ round, rounds, phase });
        errdefer std.debug.print("FAILED round={d} fs={t} op={s} phase={d} artifacts={s}\n", .{ round, filesystem, op, phase, case_home });
        const cloning = trial.kind == .copy;
        const bytes = try scratch.alloc(u8, 128 * 1024);
        for (bytes) |*byte| byte.* = @truncate(random.next() >> 32);
        var source_before: ?model.Digest = null;
        const path = if (cloning) try std.fs.path.join(scratch, &.{ case_home, "target.raw" }) else try fixture.create(scratch, io, case_home, if (trial.kind == .grow) fixture.smaller_bytes else fixture.capacity);
        if (cloning) {
            const source_home = try std.fs.path.join(scratch, &.{ case_home, "source" });
            try std.Io.Dir.cwd().createDir(io, source_home, .default_dir);
            const source_path = try fixture.create(scratch, io, source_home, fixture.smaller_bytes);
            try fixture.seedPayload(scratch, io, source_home, source_path, bytes, false);
            var source = try Image.open(io, source_path, SOURCE_IDENTITY, fixture.sector_size);
            defer source.close(io);
            source_before = try tools.digest(io, source.reader());
            const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
            defer file.close(io);
            try file.setLength(io, fixture.capacity);
            try file.writePositionalAll(io, bytes, 0);
        } else try fixture.seedPayload(scratch, io, case_home, path, bytes, trial.kind == .shrink);
        var image = try Image.open(io, path, IDENTITY, fixture.sector_size);
        if (trial.kind == .repair) try fixture.makeRepairable(scratch, io, &image);
        const prepared = if (cloning) blk: {
            const source_path = try sourcePath(scratch, path);
            var source = try Image.open(io, source_path, SOURCE_IDENTITY, fixture.sector_size);
            defer source.close(io);
            break :blk try storage.service.copy(scratch, io, source.reader(), image.reader(), .{ .offset = 0, .length = image.target.capacity });
        } else try storage.service.filesystem(scratch, io, image.reader(), .{ .offset = 0, .length = image.target.capacity }, if (trial.kind == .create) driverFor(filesystem) else null, .{ .operation = trial.kind, .bytes = (try operation(op, fixture)).target_bytes });
        const before = try tools.programRetainedDigest(io, image.reader(), prepared.program);
        image.close(io);
        // This parent-owned file survives every child death; it carries no
        // advisory lock, so the child can obtain its normal exclusive lock.
        const held = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer held.close(io);
        const recovery = try std.fs.path.join(scratch, &.{ case_home, "recovery" });
        try std.Io.Dir.cwd().createDir(io, recovery, .default_dir);
        var directory = try std.Io.Dir.cwd().openDir(io, recovery, .{});
        defer directory.close(io);
        const child_seed = try scratch.print("{d}", .{random.next()});
        var argv = [_][]const u8{ args[0], "write", path, recovery, op, @tagName(filesystem), child_seed, "slow", try scratch.print("{d}", .{fixture.sector_size}) };
        const was_killed = try launch(io, &argv, phase, &random);
        if (was_killed) {
            killed += 1;
            if (phase == 2) write_kills += 1;
        }
        argv[1] = "recover";
        if (try exists(io, directory, "ready") and !try exists(io, directory, "commit")) {
            // Stop after at least one restore fragment, then again at a random
            // elapsed time. Reopen in another fresh process for final recovery.
            if (try launch(io, &argv, 2, &random)) restore_killed += 1;
        }
        argv[7] = "fast";
        try tools.command(scratch, io, &argv);
        const outcome = try directory.readFileAlloc(io, "outcome", scratch, .limited(32));
        {
            image = try Image.open(io, path, IDENTITY, fixture.sector_size);
            defer image.close(io);
            const committed = std.mem.eql(u8, outcome, "committed");
            if (committed) commits += 1 else {
                if (std.mem.eql(u8, outcome, "rolled_back")) rollbacks += 1 else if (std.mem.eql(u8, outcome, "unprepared")) unprepared += 1 else return error.InvalidRecoveryOutcome;
                if (!std.mem.eql(u8, &before, &try tools.programRetainedDigest(io, image.reader(), prepared.program))) return error.RollbackMeaningfulBytesDiffer;
            }
            // A rolled-back repair correctly restores the original bad counters.
            // Repair those in a separate transaction before the independent fsck.
            if (!committed and std.mem.eql(u8, op, "repair")) {
                const repair_path = try std.fs.path.join(scratch, &.{ case_home, "repair-after-rollback" });
                try std.Io.Dir.cwd().createDir(io, repair_path, .default_dir);
                var repair_directory = try std.Io.Dir.cwd().openDir(io, repair_path, .{});
                defer repair_directory.close(io);
                _ = try storage.testing.executor.execute(scratch, io, image.backend(), .{ .kind = .repair }, .{ .recovery_directory = repair_directory });
            }
            if (committed or (!cloning and trial.kind != .create)) {
                try fixture.check(scratch, io, path);
                if (!committed or !std.mem.eql(u8, op, "create")) {
                    const dump = try std.fs.path.join(scratch, &.{ case_home, "dump" });
                    try fixture.checkPayload(scratch, io, path, dump, bytes);
                }
            }
            if (cloning) {
                const source_path = try sourcePath(scratch, path);
                var source = try Image.open(io, source_path, SOURCE_IDENTITY, fixture.sector_size);
                defer source.close(io);
                if (!std.mem.eql(u8, &source_before.?, &try tools.digest(io, source.reader()))) return error.CloneSourceChanged;
                try fixture.check(scratch, io, source_path);
                try fixture.checkPayload(scratch, io, source_path, try std.fs.path.join(scratch, &.{ case_home, "source-dump" }), bytes);
            }
        }
        // Verify repeated recovery reports the same durable outcome.
        try tools.command(scratch, io, &argv);
        const again = try directory.readFileAlloc(io, "outcome", scratch, .limited(32));
        if (!std.mem.eql(u8, outcome, again)) return error.RecoveryNotIdempotent;
    }
    if (write_kills == 0 or restore_killed == 0 or commits == 0 or rollbacks == 0 or unprepared == 0) {
        std.debug.print("MISSING_CRASH_COVERAGE write_kills={d} restore_killed={d} committed={d} rolled_back={d} unprepared={d}\n", .{ write_kills, restore_killed, commits, rollbacks, unprepared });
        return error.InsufficientCrashCoverage;
    }
    std.debug.print("FILESYSTEM_SIGKILL_OK seed={d} rounds={d} killed={d} write_kills={d} restore_killed={d} committed={d} rolled_back={d} unprepared={d}\n", .{ seed, rounds, killed, write_kills, restore_killed, commits, rollbacks, unprepared });
    try std.Io.Dir.cwd().deleteTree(io, home);
}
