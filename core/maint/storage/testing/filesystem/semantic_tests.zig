//! Shared semantic algorithm acceptance, checked by independent host tools.
const std = @import("std");
const storage = @import("storage");
const fixtures = storage.testing.filesystems;
const Image = storage.testing.Image;
const IDENTITY = storage.testing.fixture.IDENTITY;
const IO = std.testing.io;
const Verify = struct {
    allocator: std.mem.Allocator,
    plan: storage.service.Plan,
    fn check(ctx: *const anyopaque, context_io: std.Io, reader: storage.device.Reader) !bool {
        const self: *const @This() = @ptrCast(@alignCast(ctx));
        return self.plan.verify(self.allocator, context_io, reader);
    }
};
fn execute(a: std.mem.Allocator, image: *Image, home: []const u8, name: []const u8, p: storage.service.Plan) !void {
    const path = try std.fs.path.join(a, &.{ home, name });
    try std.Io.Dir.cwd().createDir(IO, path, .default_dir);
    var dir = try std.Io.Dir.cwd().openDir(IO, path, .{});
    defer dir.close(IO);
    var files: storage.recovery_store.Files = .{ .directory = dir };
    defer files.deinit(IO);
    const verifier: Verify = .{ .allocator = a, .plan = p };
    try storage.program_executor.execute(a, IO, image.backend(), files.store(), p.program, .{ .context = &verifier, .check = Verify.check }, null);
}
test "semantic vtables and common allocator resize every registered filesystem tail allocation" {
    const cases = try fixtures.cases(std.testing.allocator, storage.filesystem.BUILTIN);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        const driver = case.driver;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const home = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-semantic-");
        defer std.Io.Dir.cwd().deleteTree(IO, home) catch {};
        const path = try case.fixture.create(a, IO, home, case.fixture.capacity);
        const payload = "semantic relocation keeps this payload";
        try case.fixture.seedPayload(a, IO, home, path, payload, true);
        var image = try Image.open(IO, path, IDENTITY, case.fixture.sector_size);
        defer image.close(IO);
        const range: storage.model.Range = .{ .offset = 0, .length = image.target.capacity };
        const plan = try storage.service.filesystem(a, IO, image.reader(), range, driver, .{ .operation = .shrink, .bytes = case.fixture.smaller_bytes });
        try execute(a, &image, home, "shrink", plan);
        try case.fixture.check(a, IO, path);
        try case.fixture.checkPayload(a, IO, path, try std.fs.path.join(a, &.{ home, "shrunk-payload" }), payload);
        const grown = try storage.service.filesystem(a, IO, image.reader(), range, driver, .{ .operation = .grow, .bytes = case.fixture.capacity });
        try execute(a, &image, home, "grow", grown);
        try case.fixture.check(a, IO, path);
        try case.fixture.checkPayload(a, IO, path, try std.fs.path.join(a, &.{ home, "grown-payload" }), payload);
    }
}
test "native semantic formatting is accepted by independent tools" {
    const cases = try fixtures.cases(std.testing.allocator, storage.filesystem.BUILTIN);
    defer std.testing.allocator.free(cases);
    for (cases) |case| {
        const driver = case.driver;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const home = try @import("utils").filesystem.createTemporaryDirectory(a, IO, "pizza-semantic-create-");
        defer std.Io.Dir.cwd().deleteTree(IO, home) catch {};
        const path = try std.fs.path.join(a, &.{ home, "blank.raw" });
        const file = try std.Io.Dir.cwd().createFile(IO, path, .{ .exclusive = true });
        try file.setLength(IO, case.fixture.capacity);
        file.close(IO);
        var image = try Image.open(IO, path, IDENTITY, case.fixture.sector_size);
        defer image.close(IO);
        const p = try storage.service.filesystem(a, IO, image.reader(), .{ .offset = 0, .length = image.target.capacity }, driver, .{ .operation = .create });
        try execute(a, &image, home, "create", p);
        {
            const fs = try driver.open(a, IO, image.reader(), false);
            defer fs.close();
            var objects: std.AutoHashMap(u64, void) = .init(a);
            defer objects.deinit();
            var cursor: storage.semantic.Cursor = .{};
            while (try fs.enumerateObjects(&cursor)) |object| {
                const item = try objects.getOrPut(object.id);
                try std.testing.expect(!item.found_existing);
            }
            cursor = .{};
            while (try fs.enumerateAllocations(&cursor)) |unit| try std.testing.expect(objects.contains(unit.owner));
        }

        try case.fixture.check(a, IO, path);
    }
}
