//! Common policy is exercised without linking any filesystem representation.
const std = @import("std");
const storage = @import("storage");
const semantic = storage.semantic;
const model = storage.model;
const IO = std.testing.io;
const TARGET: model.Target = .{ .identity = @splat(0x36), .capacity = 8192, .sector_size = 512 };
const Fake = struct {
    target: model.Target,
    rounds: usize = 0,
    diverge: bool = false,
    requirements_buffer: [65]semantic.Requirement = undefined,
    encoded: [512]u8 = @splat(0),
    writes: [1]storage.mutation.Write = undefined,
    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }
    fn close(_: *anyopaque) void {}
    fn inspect(ctx: *anyopaque) !model.Snapshot {
        return .{ .target = cast(ctx).target, .filesystem = .ext4, .filesystem_bytes = 8192, .block_size = 512, .generation = 0, .clean = true, .capabilities = &.{.{ .operation = .shrink, .support = .validated }} };
    }
    fn objects(_: *anyopaque, cursor: *semantic.Cursor) !?semantic.Object {
        if (cursor.index != 0) return null;
        cursor.index += 1;
        return .{ .id = 7, .kind = .metadata, .bytes = 512 };
    }
    fn allocations(_: *anyopaque, cursor: *semantic.Cursor) !?semantic.AllocationUnit {
        if (cursor.index != 0) return null;
        cursor.index += 1;
        return .{ .id = 1, .owner = 7, .sources = &.{.{ .offset = 4096, .length = 512 }}, .content_bytes = 512 };
    }
    fn geometry(ctx: *anyopaque, intent: semantic.Intent) !semantic.Geometry {
        return .{ .bytes = intent.bytes, .allocation_size = 512, .reserved = &.{.{ .offset = 0, .length = 512 }}, .private = ctx };
    }
    fn requirements(ctx: *anyopaque, _: semantic.Intent, desired: semantic.Geometry, placements: []const semantic.Placement) !semantic.Requirements {
        const self = cast(ctx);
        self.rounds += 1;
        const count = if (self.diverge) @min(self.rounds, 65) else if (placements.len == 0) @as(usize, 1) else 2;
        for (self.requirements_buffer[0..count], 0..) |*requirement, i| requirement.* = .{ .id = i + 1, .bytes = 512, .granule = 512, .alignment = 512, .bounds = .{ .offset = 512, .length = desired.bytes - 512 } };
        return .{ .units = self.requirements_buffer[0..1], .additional = self.requirements_buffer[1..count] };
    }
    fn encode(ctx: *anyopaque, _: semantic.Intent, _: semantic.Geometry, placements: []const semantic.Placement) !storage.mutation.MutationSet {
        const self = cast(ctx);
        std.mem.writeInt(u64, self.encoded[0..8], placements[0].ranges[0].offset, .little);
        self.writes[0] = .{ .range = .{ .offset = 0, .length = 512 }, .content = &self.encoded };
        return .{ .target = self.target, .writes = &self.writes };
    }
    fn check(_: *anyopaque) !model.Check {
        return .{ .consistent = true, .detail = "fake records" };
    }
    fn verify(ctx: *anyopaque, _: semantic.Intent, _: storage.device.Reader) !model.Check {
        return check(ctx);
    }
    const OPS: semantic.FilesystemOps = .{ .close = close, .inspect = inspect, .enumerate_objects = objects, .enumerate_allocations = allocations, .describe_geometry = geometry, .requirements = requirements, .encode_changes = encode, .check = check, .verify = verify };
    fn filesystem(self: *@This()) semantic.Filesystem {
        return .{ .context = self, .vtable = &OPS };
    }
};
test "common shrink allocates data and growing metadata demands through semantic vtables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var baseline: [8192]u8 = @splat(0);
    @memset(baseline[4096..4608], 0x73);
    var machine = try storage.testing.crash_model.Machine.init(a, TARGET, &baseline);
    var fake: Fake = .{ .target = TARGET };
    const prepared = try storage.algorithm.prepare(a, fake.filesystem(), .{ .operation = .shrink, .bytes = 2048 });
    try std.testing.expectEqual(3, fake.rounds);
    try std.testing.expectEqual(2, prepared.placements.len);
    try std.testing.expectEqual(512, prepared.placements[0].ranges[0].offset);
    try std.testing.expectEqual(1024, prepared.placements[1].ranges[0].offset);
    var builder = storage.program.Builder.init(a, machine.disk().reader());
    try storage.algorithm.append(a, IO, &builder, 0, prepared);
    const program = try builder.finish();
    try std.testing.expectEqualSlices(u8, &baseline, machine.live);
    try storage.program_executor.execute(a, IO, machine.disk(), machine.store(), program, null, null);
    try std.testing.expectEqualSlices(u8, baseline[4096..4608], machine.live[512..1024]);
    try std.testing.expectEqual(512, std.mem.readInt(u64, machine.live[0..8], .little));
}
test "nonconverging semantic requirements fail after 64 rounds before writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .target = .{ .identity = TARGET.identity, .capacity = 128 * 512, .sector_size = 512 }, .diverge = true };
    try std.testing.expectError(error.GeometryDidNotConverge, storage.algorithm.prepare(arena.allocator(), fake.filesystem(), .{ .operation = .shrink, .bytes = 128 * 512 }));
    try std.testing.expectEqual(64, fake.rounds);
}
