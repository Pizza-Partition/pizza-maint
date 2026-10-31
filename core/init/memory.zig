//! VM acceptance measurements. RSS sums count shared pages once per process;
//! MemTotal-MemAvailable also includes the RAM filesystem and kernel allocations.
const std = @import("std");

pub const Peak = struct {
    rss_kib: u64 = 0,
    used_kib: u64 = 0,
    samples: u64 = 0,
    total_kib: u64 = 0,
    reserve_kib: u64 = 0,
    minimum_available_kib: u64 = std.math.maxInt(u64),
    reserve_breached: bool = false,

    pub fn observe(self: *Peak, total_kib: u64, available_kib: u64) !void {
        if (total_kib == 0 or available_kib > total_kib) return error.InvalidMemoryEvidence;
        if (self.total_kib == 0) {
            self.total_kib = total_kib;
            self.reserve_kib = @max(512 * 1024, total_kib / 10);
        } else if (self.total_kib != total_kib) return error.MemoryEvidenceChanged;
        self.minimum_available_kib = @min(self.minimum_available_kib, available_kib);
        if (available_kib < self.reserve_kib) self.reserve_breached = true;
        if (self.reserve_breached) return error.MemorySafetyReserveBreached;
    }

    pub fn sample(self: *Peak, io: std.Io) !void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var proc = try std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true });
        defer proc.close(io);
        var iterator = proc.iterate();
        var rss: u64 = 0;
        while (try iterator.next(io)) |entry| {
            _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;
            const path = try a.print("{s}/status", .{entry.name});
            const file = proc.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue, // A process exited during this sample.
                else => return err,
            };
            defer file.close(io);
            var buffer: [4096]u8 = undefined;
            var reader = file.readerStreaming(io, &buffer);
            const bytes = reader.interface.allocRemaining(a, .limited(64 * 1024)) catch |err| switch (err) {
                error.ReadFailed => continue,
                else => return err,
            };
            rss += (try field(bytes, "VmRSS:")) orelse 0;
        }
        const file = try proc.openFile(io, "meminfo", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const info = try reader.interface.allocRemaining(a, .limited(64 * 1024));
        const total = (try field(info, "MemTotal:")) orelse return error.MissingMemoryEvidence;
        const available = (try field(info, "MemAvailable:")) orelse return error.MissingMemoryEvidence;
        if (available > total or rss == 0) return error.InvalidMemoryEvidence;
        try self.observe(total, available);
        self.rss_kib = @max(self.rss_kib, rss);
        self.used_kib = @max(self.used_kib, total - available);
        self.samples += 1;
    }

    pub fn report(self: Peak, io: std.Io) !void {
        if (self.samples == 0 or self.rss_kib == 0 or self.used_kib == 0) return error.MissingMemoryEvidence;
        if (self.reserve_breached or self.minimum_available_kib < self.reserve_kib) return error.MemorySafetyReserveBreached;
        var buffer: [768]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "PIZZA_MEMORY_JSON:{{\"peak_rss_kib\":{d},\"peak_used_kib\":{d},\"samples\":{d},\"sample_interval_ms\":100,\"memory_total_kib\":{d},\"safety_reserve_kib\":{d},\"minimum_available_kib\":{d},\"reserve_breached\":false}}\n", .{ self.rss_kib, self.used_kib, self.samples, self.total_kib, self.reserve_kib, self.minimum_available_kib });
        try std.Io.File.stdout().writeStreamingAll(io, bytes);
    }
};

fn field(bytes: []const u8, key: []const u8) !?u64 {
    return @import("utils").memory.fieldKiB(bytes, key);
}

test "memory fields require exact names and KiB units" {
    try std.testing.expectEqual(@as(?u64, 123), try field("VmRSS: 123 kB\n", "VmRSS:"));
    try std.testing.expectEqual(@as(?u64, null), try field("VmRSSOther: 123 kB\n", "VmRSS:"));
    try std.testing.expectError(error.InvalidMemoryEvidence, field("MemTotal: 123 MB\n", "MemTotal:"));
}

test "memory acceptance latches even a transient reserve breach" {
    var peak: Peak = .{};
    try peak.observe(4 * 1024 * 1024, 3 * 1024 * 1024);
    try std.testing.expectEqual(512 * 1024, peak.reserve_kib);
    try std.testing.expectError(error.MemorySafetyReserveBreached, peak.observe(4 * 1024 * 1024, 512 * 1024 - 1));
    try std.testing.expectError(error.MemorySafetyReserveBreached, peak.observe(4 * 1024 * 1024, 3 * 1024 * 1024));
    try std.testing.expectEqual(512 * 1024 - 1, peak.minimum_available_kib);
}
