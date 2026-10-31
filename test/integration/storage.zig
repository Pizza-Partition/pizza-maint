const std = @import("std");
const binaries = @import("test_binaries");

test "system probe exposes live block geometry and memory without executing a plan" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const output = try std.process.run(a, io, .{ .argv = &.{ binaries.application_loader, binaries.application, "--probe" } });
    try std.testing.expect(output.term.success());
    const result = try std.json.parseFromSliceLeaky(struct {
        architecture: []const u8,
        kernel_release: ?[]const u8,
        memory: struct { total: u64, available: u64, effective_total: u64, effective_available: u64 },
        block_devices: []const struct { name: []const u8, capacity_bytes: ?u64, logical_block_size: ?u32, physical_block_size: ?u32 },
    }, a, output.stdout, .{ .ignore_unknown_fields = true });
    try std.testing.expect(result.architecture.len > 0 and result.kernel_release.?.len > 0);
    try std.testing.expect(result.memory.total > 0 and result.memory.available <= result.memory.total);
    try std.testing.expect(result.memory.effective_total <= result.memory.total);
    try std.testing.expect(result.memory.effective_available <= result.memory.available);
    for (result.block_devices) |disk| {
        const size = try std.Io.Dir.cwd().readFileAlloc(io, try a.print("/sys/class/block/{s}/size", .{disk.name}), a, .limited(4096));
        const sectors = try std.fmt.parseInt(u64, std.mem.trim(u8, size, " \t\r\n"), 10);
        try std.testing.expectEqual(try std.math.mul(u64, sectors, 512), disk.capacity_bytes.?);
        if (disk.logical_block_size) |bytes| try std.testing.expect(bytes >= 512 and std.math.isPowerOfTwo(bytes));
        if (disk.physical_block_size) |bytes| try std.testing.expect(bytes >= 512 and std.math.isPowerOfTwo(bytes));
    }
}

test "memory diagnostic exposes an adaptive budget with separate safety and work reserves" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run = try std.process.run(a, std.testing.io, .{ .argv = &.{ binaries.application_loader, binaries.application, "--storage-memory" } });
    try std.testing.expect(run.term.success());
    const b = try std.json.parseFromSliceLeaky(struct {
        total_bytes: u64,
        available_bytes: u64,
        safety_reserve_bytes: u64,
        work_reserve_bytes: u64,
        recovery_reserve_bytes: u64,
        cache_budget_bytes: u64,
        encoding_limit_bytes: u64,
        read_limit_bytes: u64,
    }, a, run.stdout, .{});
    try std.testing.expectEqual(@max(512 * 1024 * 1024, b.total_bytes / 10), b.safety_reserve_bytes);
    try std.testing.expectEqual(b.available_bytes, b.safety_reserve_bytes + b.work_reserve_bytes + b.recovery_reserve_bytes + b.cache_budget_bytes);
    try std.testing.expect(b.encoding_limit_bytes <= b.cache_budget_bytes / 6);
    try std.testing.expect(b.read_limit_bytes <= b.encoding_limit_bytes * 2);
}

test "native probe distinguishes primitive recovery from filesystem write support" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const capabilities = try std.process.run(a, io, .{ .argv = &.{ binaries.application_loader, binaries.application, "--storage-capabilities" } });
    try std.testing.expect(capabilities.term.success());
    const Capability = struct { operation: []const u8, support: []const u8, reason: []const u8, scope: []const u8 };
    const value = try std.json.parseFromSliceLeaky(struct {
        implementation: []const u8,
        registered_filesystems: usize,
        production_physical_writes: bool,
        filesystems: []const struct { filesystem: []const u8, operations: []const Capability },
    }, a, capabilities.stdout, .{});
    try std.testing.expectEqualStrings("pizza-native", value.implementation);
    try std.testing.expectEqual(6, value.registered_filesystems);
    try std.testing.expect(value.production_physical_writes);
    try std.testing.expectEqual(11, value.filesystems.len);
    for (value.filesystems) |fs| {
        try std.testing.expectEqual(7, fs.operations.len);
        for (fs.operations) |op| {
            const is_ext = std.mem.startsWith(u8, fs.filesystem, "ext");
            const is_ntfs = std.mem.eql(u8, fs.filesystem, "ntfs");
            const is_btrfs = std.mem.eql(u8, fs.filesystem, "btrfs");
            const available = is_ext or is_ntfs or is_btrfs or std.mem.eql(u8, fs.filesystem, "vfat");
            try std.testing.expectEqualStrings(if (available) "validated" else "planned", op.support);
            try std.testing.expectEqualStrings(if (!available) "driver_missing" else "available", op.reason);
            const metadata_only = (is_ext or is_ntfs or is_btrfs) and (std.mem.eql(u8, op.operation, "check") or std.mem.eql(u8, op.operation, "repair"));
            try std.testing.expectEqualStrings(if (metadata_only) "allocation_metadata" else "filesystem", op.scope);
        }
    }
    const run = try std.process.run(a, io, .{ .argv = &.{binaries.storage_test} });
    if (!run.term.success()) std.debug.print("native storage self-test: {s}\n", .{run.stderr});
    try std.testing.expect(run.term.success());
    const prefix = "PIZZA_STORAGE_PRIMITIVES:";
    try std.testing.expect(std.mem.startsWith(u8, run.stdout, prefix));
    const result = try std.json.parseFromSliceLeaky(struct {
        test_name: []const u8,
        scope: []const u8,
        filesystem_writes: bool,
        persistent_recovery_qualified: bool,
        results: struct { transactions: u32, unprepared: u32, rolled_back: u32, committed: u32, interrupted_restore: u32 },
    }, a, std.mem.trim(u8, run.stdout[prefix.len..], "\n"), .{});
    try std.testing.expectEqualStrings("private_image_primitives", result.scope);
    try std.testing.expect(!result.filesystem_writes and !result.persistent_recovery_qualified);
    try std.testing.expectEqual(9, result.results.transactions);
    try std.testing.expectEqual(6, result.results.rolled_back);
    try std.testing.expectEqual(2, result.results.committed);
    try std.testing.expectEqual(1, result.results.interrupted_restore);
}
