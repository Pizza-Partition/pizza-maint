//! Hard allocation boundaries plus continuously observed simulated headroom.
const std = @import("std");
const storage = @import("storage");
const memory = storage.memory;
const MiB = memory.MI_B;
const GI_B = 1024 * MiB;
const Fake = struct {
    total: u64 = 8 * GI_B,
    available: u64 = 6 * GI_B,
    floor: u64 = 512 * MiB,
    minimum: u64 = std.math.maxInt(u64),
    backing_calls: usize = 0,
    crossed: bool = false,
    fn sample(context: *const anyopaque, _: std.Io) !memory.linux.Snapshot {
        const self: *const Fake = @ptrCast(@alignCast(context));
        return .{ .total = self.total, .available = self.available, .effective_total = self.total, .effective_available = self.available };
    }
    fn probe(self: *Fake) memory.Probe {
        return .{ .context = self, .sample_fn = sample };
    }
    fn rawAlloc(context: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Fake = @ptrCast(@alignCast(context));
        const ptr = std.testing.allocator.rawAlloc(n, alignment, ra) orelse return null;
        self.backing_calls += 1;
        self.available -= std.mem.alignForward(u64, n, 4096);
        self.minimum = @min(self.minimum, self.available);
        if (self.available < self.floor) self.crossed = true;
        return ptr;
    }
    fn rawFree(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.available += std.mem.alignForward(u64, bytes.len, 4096);
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
    fn backing(self: *Fake) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = rawAlloc, .free = rawFree, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
};
test "adaptive budgets scale with available RAM and preserve separate reserves" {
    var fake: Fake = .{};
    const s = try fake.probe().sample(std.testing.io);
    const b = try memory.Budget.derive(s, .{});
    try std.testing.expectEqual(@max(512 * MiB, fake.total / 10), b.reserve);
    try std.testing.expectEqual(fake.available, b.cache_bytes + b.reserve + b.work_reserve + b.recovery_reserve);
    try std.testing.expect(b.cache_bytes > 128 * MiB);
    fake.available = 512 * MiB;
    try std.testing.expectError(error.InsufficientMemoryBudget, memory.Budget.derive(try fake.probe().sample(std.testing.io), .{}));
    try std.testing.expectError(error.InvalidMemoryPolicy, memory.Budget.derive(s, .{ .reserve_percent = 101 }));
}
test "hard allocation quota refuses before calling backing allocator" {
    var fake: Fake = .{};
    var controller = try memory.Controller.init(std.testing.io, .{ .probe = fake.probe(), .policy = .{ .cache_cap = 4096 } });
    controller.backing = fake.backing();
    const a = controller.allocator();
    const bytes = try a.alloc(u8, 4096);
    defer a.free(bytes);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try std.testing.expectEqual(1, fake.backing_calls);
    try std.testing.expectEqual(error.MemoryBudgetExceeded, controller.failure.?);
    const e = controller.evidence();
    try std.testing.expectEqual(4096, e.peak_charged);
    try std.testing.expect(e.peak_charged <= e.allocation_limit);
    try std.testing.expect(!e.violated and !fake.crossed);
}
test "external pressure denies growth without ever consuming safety reserve" {
    var fake: Fake = .{};
    var controller = try memory.Controller.init(std.testing.io, .{ .probe = fake.probe() });
    fake.floor = controller.budget.reserve;
    controller.backing = fake.backing();
    fake.available = controller.budget.reserve + controller.budget.work_reserve + controller.budget.recovery_reserve + 4096;
    const a = controller.allocator();
    const bytes = try a.alloc(u8, 4096);
    defer a.free(bytes);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try std.testing.expectEqual(1, fake.backing_calls);
    try std.testing.expect(!fake.crossed);
    try std.testing.expect(fake.minimum >= fake.floor);
    try std.testing.expect(controller.evidence().minimum_available >= fake.floor);
}
test "temporary safety breach is latched after available memory recovers" {
    var fake: Fake = .{};
    var controller = try memory.Controller.init(std.testing.io, .{ .probe = fake.probe() });
    const floor = controller.budget.reserve;
    fake.available = floor - 1;
    try std.testing.expectError(error.MemorySafetyReserveBreached, controller.check());
    fake.available = 6 * GI_B;
    try std.testing.expectError(error.MemorySafetyReserveBreached, controller.check());
    try std.testing.expect(controller.evidence().violated);
    try std.testing.expectEqual(floor - 1, controller.evidence().minimum_available);
    try std.testing.expectEqual(floor, controller.evidence().reserve);
}
test "guard accounts arena growth and returns every scratch page" {
    var fake: Fake = .{};
    var controller = try memory.Controller.init(std.testing.io, .{ .probe = fake.probe(), .policy = .{ .cache_cap = MiB } });
    controller.backing = fake.backing();
    {
        var arena: std.heap.ArenaAllocator = .init(controller.allocator());
        defer arena.deinit();
        for (0..16) |_| {
            const bytes = try arena.allocator().alloc(u8, 4096);
            @memset(bytes, 0x55);
        }
    }
    try std.testing.expectEqual(0, controller.charged);
    try std.testing.expectEqual(6 * GI_B, fake.available);
    try std.testing.expect(controller.peak > 16 * 4096);
    try std.testing.expect(controller.peak <= MiB and !fake.crossed);
}
test "same controller accounts concurrent allocation lanes" {
    var fake: Fake = .{};
    var controller = try memory.Controller.init(std.testing.io, .{ .probe = fake.probe(), .policy = .{ .cache_cap = MiB } });
    controller.backing = fake.backing();
    const Context = struct {
        controller: *memory.Controller,
        fn run(self: *@This()) anyerror!void {
            const a = self.controller.allocator();
            const bytes = try a.alloc(u8, 4096);
            defer a.free(bytes);
            @memset(bytes, 0x55);
        }
    };
    var context: Context = .{ .controller = &controller };
    const io = std.testing.io;
    var futures: [4]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (futures[0..started]) |*future| future.await(io) catch {};
    for (&futures) |*future| {
        future.* = try io.concurrent(Context.run, .{&context});
        started += 1;
    }
    var failure: ?anyerror = null;
    for (futures[0..started]) |*future| future.await(io) catch |err| {
        failure = failure orelse err;
    };
    started = 0;
    if (failure) |err| return err;
    try std.testing.expectEqual(0, controller.charged);
    try std.testing.expect(!fake.crossed and !controller.evidence().violated);
}
