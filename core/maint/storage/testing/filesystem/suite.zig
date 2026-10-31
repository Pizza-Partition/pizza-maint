//! Shared behavioral acceptance for every registered filesystem backend.
//! Format knowledge belongs exclusively to Fixture providers and their oracles.
const std = @import("std");
const storage = @import("storage");
const model = storage.model;
const REGISTRY = storage.filesystem.BUILTIN;
const executor = storage.testing.executor;
const Image = storage.testing.Image;
const IDENTITY = storage.testing.fixture.IDENTITY;
const fixtures = storage.testing.filesystems;
const tools = storage.testing.tools;

pub fn run(a: std.mem.Allocator, io: std.Io, image: *Image, home: []const u8, name: []const u8, operation: storage.testing.executor.Action) !executor.Result {
    const path = try std.fs.path.join(a, &.{ home, name });
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    return storage.testing.executor.execute(a, io, image.backend(), operation, .{ .recovery_directory = directory });
}
fn makeHome(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-filesystem-");
}

test "every registered filesystem has an independent fixture and missing providers fail" {
    const cases = try fixtures.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    try std.testing.expectEqual(REGISTRY.drivers.len, cases.len);
    try std.testing.expectError(error.MissingFilesystemFixture, fixtures.collect(std.testing.allocator, REGISTRY, &.{}));
}

test "shared filesystem query and check preserve every image byte" {
    const cases = try fixtures.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try makeHome(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try case.fixture.create(a, io, root, case.fixture.capacity);
        var image = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer image.close(io);
        const before = try tools.digest(io, image.reader());
        const snapshot = try REGISTRY.query(a, io, image.reader());
        try std.testing.expectEqual(case.fixture.filesystem, snapshot.filesystem);
        try std.testing.expectEqual(case.fixture.capacity, snapshot.filesystem_bytes);
        if (case.supports(.check)) try std.testing.expect((try REGISTRY.check(a, io, image.reader())).consistent);
        try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
    }
}

test "shared filesystem create is accepted by an independent checker" {
    const cases = try fixtures.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        if (!case.supports(.create)) continue;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try makeHome(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try std.fs.path.join(a, &.{ root, "target.raw" });
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        try file.setLength(io, case.fixture.capacity);
        file.close(io);
        var image = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer image.close(io);
        try std.testing.expect((try run(a, io, &image, root, "create", .{ .kind = .create, .filesystem = case.fixture.filesystem })).changed);
        try std.testing.expectEqual(case.fixture.filesystem, (try REGISTRY.query(a, io, image.reader())).filesystem);
        try case.fixture.check(a, io, path);
    }
}

test "shared filesystem resizing preserves tail file content and requested geometry" {
    const cases = try fixtures.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        if (!case.supports(.grow) and !case.supports(.shrink)) continue;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try makeHome(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try case.fixture.create(a, io, root, if (case.supports(.shrink)) case.fixture.capacity else case.fixture.smaller_bytes);
        const bytes = try a.alloc(u8, 1024 * 1024);
        std.Io.random(io, bytes);
        try case.fixture.seedPayload(a, io, root, path, bytes, case.supports(.shrink));
        var image = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer image.close(io);
        for ([_]model.Kind{ .shrink, .grow }) |kind| {
            if (!case.supports(kind)) continue;
            const size = if (kind == .shrink) case.fixture.smaller_bytes else case.fixture.capacity;
            const operation: storage.testing.executor.Action = if (kind == .shrink) .{ .kind = .shrink, .target_bytes = size } else .{ .kind = .grow, .target_bytes = size };
            if (kind == .shrink) {
                const prepared = try storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), operation);
                var relocated: u64 = 0;
                for (prepared.program.steps) |step| if (step.operation == .save) {
                    relocated += step.operation.save.source.length;
                };
                // Every provider placed at least part of this file past the boundary.
                // Its bytes must be represented by moves, never undo payload.
                try std.testing.expect(relocated > 0);
                for (prepared.program.steps) |step| if (step.operation == .write) {
                    try std.testing.expect(std.mem.indexOf(u8, step.operation.write.content, bytes[0..512]) == null);
                };
            }
            _ = try run(a, io, &image, root, @tagName(kind), operation);
            try std.testing.expectEqual(size, (try REGISTRY.query(a, io, image.reader())).filesystem_bytes);
            try case.fixture.check(a, io, path);
            try case.fixture.checkPayload(a, io, path, try std.fs.path.join(a, &.{ root, try a.print("dump-{t}", .{kind}) }), bytes);
        }
    }
}

test "shared filesystem repair fixes a provider-defined recoverable inconsistency" {
    const cases = try fixtures.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        if (!case.supports(.repair)) continue;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try makeHome(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try case.fixture.create(a, io, root, case.fixture.capacity);
        var image = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer image.close(io);
        try case.fixture.makeRepairable(a, io, &image);
        if (case.supports(.check)) try std.testing.expect(!(try REGISTRY.check(a, io, image.reader())).consistent);
        try std.testing.expect((try run(a, io, &image, root, "repair", .{ .kind = .repair })).changed);
        try case.fixture.check(a, io, path);
        if (case.supports(.check)) try std.testing.expect((try REGISTRY.check(a, io, image.reader())).consistent);
    }
}

fn resizeOperation(case: fixtures.Case) ?storage.testing.executor.Action {
    if (case.supports(.shrink)) return .{ .kind = .shrink, .target_bytes = case.fixture.smaller_bytes };
    if (case.supports(.grow)) return .{ .kind = .grow, .target_bytes = case.fixture.capacity };
    return null;
}

test "shared filesystem interrupted writes restore exact bytes without a filesystem session" {
    const cases = try fixtures.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        const operation = resizeOperation(case) orelse continue;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try makeHome(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try case.fixture.create(a, io, root, if (operation.kind == .shrink) case.fixture.capacity else case.fixture.smaller_bytes);
        const data = "data moved from the tail must survive a partial transaction";
        try case.fixture.seedPayload(a, io, root, path, data, operation.kind == .shrink);
        var image = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer image.close(io);
        const before = try tools.digest(io, image.reader());
        const txn = try storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), operation);
        const retained = try tools.programRetainedDigest(io, image.reader(), txn.program);
        try std.testing.expect(txn.program.steps.len > 0);
        const fault_offset = for (txn.program.steps, 0..) |_, step| {
            if (txn.program.targetRange(step)) |range| break range.offset;
        } else return error.ExpectedTargetWrite;
        try std.testing.expectEqualSlices(u8, &before, &try tools.digest(io, image.reader()));
        for ([_]?storage.testing.executor.Cut{ .ready, .step, .written, .validated, null }, 0..) |cut, index| {
            const recovery_path = try std.fs.path.join(a, &.{ root, try a.print("recovery-{d}", .{index}) });
            try std.Io.Dir.cwd().createDir(io, recovery_path, .default_dir);
            var directory = try std.Io.Dir.cwd().openDir(io, recovery_path, .{});
            defer directory.close(io);
            if (cut == null) image.tear_write_at = fault_offset;
            try std.testing.expectError(if (cut == null) error.InjectedPartialMetadata else error.InjectedExecutionInterruption, storage.testing.executor.execute(a, io, image.backend(), operation, .{ .recovery_directory = directory, .fault = cut }));
            image.close(io);
            image = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
            if (cut == .written) try std.testing.expectError(error.InjectedRestoreInterruption, storage.testing.executor.recover(io, image.backend(), directory, .{}, 0));
            try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.testing.executor.recover(io, image.backend(), directory, .{}, null));
            try std.testing.expectEqualSlices(u8, &retained, &try tools.programRetainedDigest(io, image.reader(), txn.program));
            try case.fixture.check(a, io, path);
        }
    }
}

test "shared filesystem SQLite-style power loss and repeated recovery damage" {
    const simulator = storage.testing.crash_model;
    const cases = try fixtures.cases(std.testing.allocator, REGISTRY);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        const operation = resizeOperation(case) orelse continue;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try makeHome(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const path = try case.fixture.create(a, io, root, if (operation.kind == .shrink) case.fixture.capacity else case.fixture.smaller_bytes);
        const data = try a.alloc(u8, 4096);
        std.Io.random(io, data);
        try case.fixture.seedPayload(a, io, root, path, data, operation.kind == .shrink);
        var image = try Image.open(io, path, IDENTITY, case.fixture.sector_size);
        defer image.close(io);
        const baseline = try a.alloc(u8, @intCast(image.target.capacity));
        try image.reader().readInto(io, 0, baseline);
        const txn = try storage.testing.executor.prepare(REGISTRY, a, io, image.reader(), operation);
        const retained = try tools.programRetainedDigest(io, image.reader(), txn.program);
        const Context = struct {
            fn check(_: *const anyopaque, _: std.Io, _: storage.device.Reader) !bool {
                return error.VerifierMustNotRunBeforeCrash;
            }
        };
        for (std.enums.values(simulator.Damage)) |damage| {
            for (0..2) |seed| {
                var scenario: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer scenario.deinit();
                const scratch = scenario.allocator();
                var machine = try simulator.Machine.init(scratch, image.target, baseline);
                try std.testing.expectError(error.InjectedExecutionInterruption, storage.testing.executor.runProgram(scratch, io, machine.disk(), machine.store(), txn.program, &.{}, .{ .context = &IDENTITY, .check = Context.check }, .written));
                try machine.powerLoss(seed + 41, damage);
                try std.testing.expectError(error.InjectedRestoreInterruption, storage.testing.executor.recoverStore(scratch, io, machine.disk(), machine.store(), 0));
                try machine.powerLoss(seed + 97, .garbage);
                try std.testing.expectEqual(storage.program_executor.Result.rolled_back, try storage.testing.executor.recoverStore(scratch, io, machine.disk(), machine.store(), null));
                try std.testing.expectEqualSlices(u8, &retained, &try tools.programRetainedDigest(io, machine.disk().reader(), txn.program));
                try image.file.writePositionalAll(io, machine.stable, 0);
                try image.file.sync(io);
                try case.fixture.check(scratch, io, path);
                try case.fixture.checkPayload(scratch, io, path, try std.fs.path.join(scratch, &.{ root, try scratch.print("dump-{t}-{d}", .{ damage, seed }) }), data);
            }
        }
    }
}
