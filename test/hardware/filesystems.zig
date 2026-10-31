//! Explicit-device acceptance. Uses production acquisition, semantic planning and
//! recovery; small image fixtures are independent inputs/oracles, never targets.
const std = @import("std");
const storage = @import("storage");
const execution = storage.program_executor;
const tools = storage.testing.tools;
var cancelled: std.atomic.Value(bool) = .init(false);

fn stop(_: std.os.linux.SIG) callconv(.c) void {
    cancelled.store(true, .monotonic);
}
fn signals() !void {
    const linux = std.os.linux;
    const action: linux.Sigaction = .{ .handler = .{ .handler = stop }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .INT, .TERM }) |signal| if (linux.errno(linux.sigaction(signal, &action, null)) != .SUCCESS) return error.SignalSetupFailed;
}
fn json(a: std.mem.Allocator, io: std.Io, value: anytype) !void {
    try std.Io.File.stdout().writeStreamingAll(io, try a.print("{s}\n", .{try std.json.Stringify.valueAlloc(a, value, .{})}));
}
fn fileJson(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, value: anytype) !void {
    const file = try dir.createFile(io, name, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, value, .{}));
    try file.sync(io);
}
fn dump(io: std.Io, reader: storage.device.Reader, destination: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, destination, .{ .exclusive = true });
    defer file.close(io);
    var bytes: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.target.capacity) {
        const part = bytes[0..@intCast(@min(bytes.len, reader.target.capacity - offset))];
        try reader.readInto(io, offset, part);
        try file.writePositionalAll(io, part, offset);
        offset += part.len;
    }
    try file.sync(io);
}
fn load(io: std.Io, disk: storage.device.Device, source: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer file.close(io);
    if ((try file.stat(io)).size != disk.target.capacity) return error.FixtureSizeMismatch;
    var bytes: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (offset < disk.target.capacity) {
        const part = bytes[0..@intCast(@min(bytes.len, disk.target.capacity - offset))];
        if (try file.readPositionalAll(io, part, offset) != part.len) return error.ShortFixtureRead;
        try disk.write(io, .{ .offset = offset, .length = part.len }, part);
        offset += part.len;
    }
    try disk.flush(io);
}
const Observation = struct {
    io: std.Io,
    fault: []const u8,
    fired: bool = false,
    clone: bool = false,
    fn pause(self: *@This()) !void {
        if (self.fired) return;
        self.fired = true;
        try std.Io.File.stdout().writeStreamingAll(self.io, "PIZZA_HARDWARE_CUT\n");
        for (0..6000) |_| {
            if (cancelled.load(.monotonic)) return;
            try std.Io.sleep(self.io, .fromMilliseconds(10), .awake);
        }
        return error.SupervisorDidNotInterrupt;
    }
    fn event(ctx: *anyopaque, _: usize, _: usize, bytes: u64) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (bytes > 0 and !std.mem.eql(u8, self.fault, "none")) try self.pause();
    }
    fn progress(ctx: *anyopaque, _: usize, done: u64, _: u64) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.clone and done >= 65536 and !std.mem.eql(u8, self.fault, "none")) try self.pause();
    }
    fn isCancelled(_: *anyopaque) bool {
        return cancelled.load(.monotonic);
    }
    fn observer(self: *@This()) execution.Observer {
        return .{ .context = self, .event = event, .progress = progress, .cancelled = isCancelled };
    }
};
const Verification = struct {
    allocator: std.mem.Allocator,
    plan: storage.service.Plan,
    fn check(ctx: *const anyopaque, io: std.Io, reader: storage.device.Reader) !bool {
        const self: *const @This() = @ptrCast(@alignCast(ctx));
        return self.plan.verify(self.allocator, io, reader);
    }
};
fn retained(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, disk: storage.device.Device, files: *storage.recovery_store.Files) !void {
    const bytes = try dir.readFileAlloc(io, "baseline.json", a, .limited(4096));
    const baseline = try std.json.parseFromSliceLeaky(struct { retained: [64]u8, source: ?[64]u8 }, a, bytes, .{});
    const plan = try storage.program.decode(a, try files.store().read(io, .program, a, storage.program.MAX_ENCODED_BYTES));
    if (!std.mem.eql(u8, &baseline.retained, &std.fmt.bytesToHex(try tools.programRetainedDigest(io, disk.reader(), plan), .lower))) return error.RollbackBytesChanged;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 1 or std.mem.startsWith(u8, args[1], "-")) return @import("matrix.zig").run(init, args);
    // format action fixture-home case-home identity fault device
    if (args.len != 8) return error.InvalidHardwareArguments;
    const format = std.meta.stringToEnum(storage.model.Filesystem, args[1]) orelse return error.UnknownFilesystem;
    const action = args[2];
    var expected: storage.model.Digest = undefined;
    if (args[5].len != 64) return error.InvalidDeviceIdentity;
    _ = try std.fmt.hexToBytes(&expected, args[5]);
    var budget = try storage.memory.Controller.init(io, .{});
    var arena: std.heap.ArenaAllocator = .init(budget.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const cases = try storage.testing.filesystems.cases(a, storage.filesystem.BUILTIN);
    const case = for (cases) |item| {
        if (item.fixture.filesystem == format) break item;
    } else return error.MissingFilesystemFixture;
    if (case.fixture.capacity > 128 * 1024 * 1024) return error.HardwareFixtureTooLarge;
    var directory = try std.Io.Dir.cwd().openDir(io, args[4], .{ .follow_symlinks = false });
    defer directory.close(io);
    var block = try storage.block_device.BlockDevice.open(a, io, args[7], expected, case.fixture.sector_size, .write);
    defer block.close(io);
    if (block.target.capacity < case.fixture.capacity) return error.HardwareTargetTooSmall;
    try block.admitRecovery(a, io, directory);
    var view = try storage.partition.Partition.init(block.backend().withMemory(&budget), .{ .offset = 0, .length = case.fixture.capacity }, @splat(0x71));
    const disk = view.device();
    if (std.mem.eql(u8, action, "admit")) return json(a, io, .{ .result = "admitted_without_writes", .target = block.target });
    const fixture_path = try a.print("{s}/seed/target.raw", .{args[3]});
    const payload_path = try a.print("{s}/payload.bin", .{args[3]});
    if (std.mem.eql(u8, action, "erase")) {
        if (format != .vfat) return error.InvalidCleanupFormat;
        const zeros: [65536]u8 = @splat(0);
        for ([_]storage.device.Device{disk}) |target| {
            var offset: u64 = 0;
            while (offset < target.target.capacity) : (offset += zeros.len) try target.write(io, .{ .offset = offset, .length = zeros.len }, &zeros);
            try target.flush(io);
        }
        return json(a, io, .{ .result = "test_extent_erased" });
    }
    if (std.mem.eql(u8, action, "seed")) {
        const home = try a.print("{s}/seed", .{args[3]});
        try std.Io.Dir.cwd().createDir(io, home, .default_dir);
        const image = try case.fixture.create(a, io, home, case.fixture.capacity);
        const payload = try a.alloc(u8, 1024 * 1024);
        std.Io.random(io, payload);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = payload_path, .data = payload });
        try case.fixture.seedPayload(a, io, home, image, payload, true);
        try case.fixture.check(a, io, image);
        try load(io, disk, image);
        return json(a, io, .{ .result = "seeded", .bytes = disk.target.capacity, .payload_sha256 = std.fmt.bytesToHex(storage.model.digest(payload), .lower) });
    }
    if (std.mem.eql(u8, action, "oracle") or std.mem.eql(u8, action, "oracle-empty") or std.mem.eql(u8, action, "corrupt")) {
        const image_path = try a.print("{s}/readback.raw", .{args[4]});
        try dump(io, disk.reader(), image_path);
        defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
        if (std.mem.eql(u8, action, "corrupt")) {
            var image = try storage.testing.Image.open(io, image_path, @splat(0x37), 512);
            defer image.close(io);
            try case.fixture.makeRepairable(a, io, &image);
            try load(io, disk, image_path);
            if ((try storage.filesystem.BUILTIN.check(a, io, disk.reader())).consistent) return error.CorruptionNotDetected;
            return json(a, io, .{ .result = "repairable_corruption_detected" });
        }
        try case.fixture.check(a, io, image_path);
        if (std.mem.eql(u8, action, "oracle")) {
            const payload = try std.Io.Dir.cwd().readFileAlloc(io, payload_path, a, .limited(1024 * 1024 + 1));
            try case.fixture.checkPayload(a, io, image_path, try a.print("{s}/extracted", .{args[4]}), payload);
        }
        return json(a, io, .{ .result = "independent_check_passed", .payload_checked = std.mem.eql(u8, action, "oracle") });
    }
    if (std.mem.eql(u8, action, "query-check")) {
        const before = try tools.digest(io, disk.reader());
        const snapshot = try storage.filesystem.BUILTIN.query(a, io, disk.reader());
        const check = try storage.filesystem.BUILTIN.check(a, io, disk.reader());
        if (!check.consistent or snapshot.filesystem != format) return error.FilesystemCheckFailed;
        if (!std.mem.eql(u8, &before, &try tools.digest(io, disk.reader()))) return error.ReadonlyOperationChangedBytes;
        return json(a, io, .{ .result = "query_check_preserved_all_bytes", .snapshot = snapshot, .check = check });
    }
    if (std.mem.eql(u8, action, "copy-alias")) {
        const before = try tools.digest(io, disk.reader());
        if (storage.service.copy(a, io, disk.reader(), disk.reader(), .{ .offset = 0, .length = disk.target.capacity })) |_| {
            return error.SameDiskCopyAccepted;
        } else |err| if (err != error.CopyAliasesSource) return err;
        const after = try tools.digest(io, disk.reader());
        if (!std.mem.eql(u8, &before, &after)) return error.RefusalChangedTarget;
        return json(a, io, .{ .result = "same_disk_copy_refused_without_writes" });
    }
    var files: storage.recovery_store.Files = .{ .directory = directory };
    defer files.deinit(io);
    var observation: Observation = .{ .io = io, .fault = args[6], .clone = std.mem.eql(u8, action, "copy") };
    try signals();
    if (std.mem.eql(u8, action, "recover")) {
        const result = try execution.recover(a, io, disk, files.store(), observation.observer());
        if (result != .rolled_back) return error.UnexpectedRecoveryResult;
        try retained(a, io, directory, disk, &files);
        return json(a, io, .{ .result = "rolled_back", .retained_bytes_equal = true, .clone_source_provided = false });
    }
    var clone_source: ?storage.testing.ImageDevice = null;
    defer if (clone_source) |*image| image.close(io);
    const source_reader = if (std.mem.eql(u8, action, "copy")) blk: {
        clone_source = try storage.testing.ImageDevice.openReadOnly(io, fixture_path, try storage.testing.ImageDevice.identify(io, fixture_path), 512);
        break :blk clone_source.?.backend().reader().withMemory(&budget);
    } else null;
    const source_before = if (source_reader) |reader| try tools.digest(io, reader) else null;
    const plan = if (std.mem.eql(u8, action, "copy")) try storage.service.copy(a, io, source_reader.?, disk.reader(), .{ .offset = 0, .length = disk.target.capacity }) else blk: {
        const operation = std.meta.stringToEnum(storage.model.Kind, action) orelse return error.UnknownHardwareOperation;
        if (operation != .create and operation != .repair and operation != .shrink and operation != .grow) return error.UnknownHardwareOperation;
        const bytes = if (operation == .shrink) case.fixture.smaller_bytes else case.fixture.capacity;
        break :blk try storage.service.filesystem(a, io, disk.reader(), .{ .offset = 0, .length = disk.target.capacity }, case.driver, .{ .operation = operation, .bytes = bytes });
    };
    var relocated: u64 = 0;
    for (plan.program.steps) |step| if (step.operation == .save) {
        relocated += step.operation.save.source.length;
    };
    if (std.mem.eql(u8, action, "shrink") and relocated == 0) return error.TailRelocationMissing;
    try fileJson(a, io, directory, "baseline.json", .{ .retained = std.fmt.bytesToHex(try tools.programRetainedDigest(io, disk.reader(), plan.program), .lower), .source = if (source_before) |hash| std.fmt.bytesToHex(hash, .lower) else null });
    const verifier: Verification = .{ .allocator = a, .plan = plan };
    execution.executeWithSources(a, io, disk, files.store(), plan.program, if (std.mem.eql(u8, action, "copy")) &.{source_reader.?} else &.{}, .{ .context = &verifier, .check = Verification.check }, observation.observer()) catch |err| {
        if (err != error.OperationCancelled) return err;
        if (try execution.recover(a, io, disk, files.store(), null) != .rolled_back) return error.UnexpectedRecoveryResult;
        try retained(a, io, directory, disk, &files);
        try json(a, io, .{ .result = "cancelled_and_recovered", .retained_bytes_equal = true });
        std.process.exit(130);
    };
    if (source_reader) |reader| {
        if (!std.mem.eql(u8, &source_before.?, &try tools.digest(io, reader))) return error.CloneSourceChanged;
    }
    const snapshot = try storage.filesystem.BUILTIN.query(a, io, disk.reader());
    if ((std.mem.eql(u8, action, "shrink") and snapshot.filesystem_bytes != case.fixture.smaller_bytes) or (!std.mem.eql(u8, action, "shrink") and snapshot.filesystem_bytes != case.fixture.capacity)) return error.UnexpectedFilesystemSize;
    try json(a, io, .{ .result = "committed", .steps = plan.program.steps.len, .relocated_bytes = relocated, .source_unchanged = if (source_reader != null) @as(?bool, true) else null, .snapshot = snapshot, .memory = budget.evidence() });
}
