//! Allocation-free Linux memory evidence. Never count swap as available RAM.
const std = @import("std");
pub const Snapshot = struct {
    total: u64,
    available: u64,
    effective_total: u64,
    effective_available: u64,
    cgroup_levels: u32 = 0,
    pub fn constrain(self: *Snapshot, current: u64, maximum: ?u64, high: ?u64) void {
        for ([_]?u64{ maximum, high }) |limit| if (limit) |bytes| {
            self.effective_total = @min(self.effective_total, bytes);
            self.effective_available = @min(self.effective_available, bytes -| current);
        };
        self.cgroup_levels += 1;
    }
};
pub const Source = struct {
    context: *const anyopaque,
    read_fn: *const fn (*const anyopaque, std.Io, []const u8, []u8) anyerror!?[]const u8,
    pub fn read(self: Source, io: std.Io, path: []const u8, buffer: []u8) !?[]const u8 {
        return self.read_fn(self.context, io, path, buffer);
    }
};
const SYSTEM_CONTEXT: u8 = 0;
pub const SYSTEM: Source = .{ .context = &SYSTEM_CONTEXT, .read_fn = systemRead };
fn systemRead(_: *const anyopaque, io: std.Io, path: []const u8, buffer: []u8) !?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var scratch: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &scratch);
    const length = try reader.interface.readSliceShort(buffer);
    if (length == buffer.len) return error.MemoryEvidenceTooLarge;
    return buffer[0..length];
}
pub fn fieldKiB(bytes: []const u8, key: []const u8) !?u64 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var result: ?u64 = null;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (result != null) return error.InvalidMemoryEvidence;
        var words = std.mem.tokenizeAny(u8, line[key.len..], " \t\r");
        const number = std.fmt.parseInt(u64, words.next() orelse return error.InvalidMemoryEvidence, 10) catch return error.InvalidMemoryEvidence;
        if (!std.mem.eql(u8, words.next() orelse return error.InvalidMemoryEvidence, "kB") or words.next() != null) return error.InvalidMemoryEvidence;
        result = number;
    }
    return result;
}
pub fn parseMeminfo(bytes: []const u8) !Snapshot {
    const total = std.math.mul(u64, (try fieldKiB(bytes, "MemTotal:")) orelse return error.MissingMemoryEvidence, 1024) catch return error.InvalidMemoryEvidence;
    const available = std.math.mul(u64, (try fieldKiB(bytes, "MemAvailable:")) orelse return error.MissingMemoryEvidence, 1024) catch return error.InvalidMemoryEvidence;
    if (total == 0 or available > total) return error.InvalidMemoryEvidence;
    return .{ .total = total, .available = available, .effective_total = total, .effective_available = available };
}
pub fn parseLimit(bytes: []const u8) !?u64 {
    const value = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.eql(u8, value, "max")) return null;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidMemoryEvidence;
}
fn decode(input: []const u8, buffer: []u8) ![]const u8 {
    var n: usize = 0;
    var at: usize = 0;
    while (at < input.len) {
        if (n == buffer.len) return error.MemoryEvidenceTooLarge;
        if (input[at] == '\\') {
            if (input.len - at < 4) return error.InvalidMemoryEvidence;
            buffer[n] = std.fmt.parseInt(u8, input[at + 1 ..][0..3], 8) catch return error.InvalidMemoryEvidence;
            at += 4;
        } else {
            buffer[n] = input[at];
            at += 1;
        }
        n += 1;
    }
    return buffer[0..n];
}
fn safePath(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidMemoryEvidence;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.InvalidMemoryEvidence;
}
pub fn probe(io: std.Io, source: Source) !Snapshot {
    var bytes: [65536]u8 = undefined;
    var result = try parseMeminfo((try source.read(io, "/proc/meminfo", &bytes)) orelse return error.MissingMemoryEvidence);
    const membership = (try source.read(io, "/proc/self/cgroup", &bytes)) orelse return result;
    var group_buffer: [4096]u8 = undefined;
    var group: ?[]const u8 = null;
    var rows = std.mem.splitScalar(u8, membership, '\n');
    while (rows.next()) |row| {
        if (std.mem.startsWith(u8, row, "0::")) {
            if (group != null) return error.InvalidMemoryEvidence;
            if (row.len - 3 > group_buffer.len) return error.MemoryEvidenceTooLarge;
            @memcpy(group_buffer[0 .. row.len - 3], row[3..]);
            group = group_buffer[0 .. row.len - 3];
        } else if (row.len != 0) {
            // A v1 memory controller must not be mistaken for unlimited RAM.
            var fields = std.mem.splitScalar(u8, row, ':');
            _ = fields.next();
            const controllers = fields.next() orelse return error.InvalidMemoryEvidence;
            var names = std.mem.splitScalar(u8, controllers, ',');
            while (names.next()) |name| if (std.mem.eql(u8, name, "memory")) return error.UnsupportedMemoryController;
        }
    }
    const current = group orelse return result;
    try safePath(current);
    const mounts = (try source.read(io, "/proc/self/mountinfo", &bytes)) orelse return result;
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    var root_buffer: [4096]u8 = undefined;
    var mount_buffer: [4096]u8 = undefined;
    var path_buffer: [8192]u8 = undefined;
    while (lines.next()) |line| {
        const separator = std.mem.indexOf(u8, line, " - cgroup2 ") orelse continue;
        var words = std.mem.tokenizeScalar(u8, line[0..separator], ' ');
        _ = words.next();
        _ = words.next();
        _ = words.next();
        const root = try decode(words.next() orelse return error.InvalidMemoryEvidence, &root_buffer);
        const mount = try decode(words.next() orelse return error.InvalidMemoryEvidence, &mount_buffer);
        try safePath(root);
        try safePath(mount);
        const suffix = if (std.mem.eql(u8, root, "/")) current else if (std.mem.eql(u8, root, current)) "" else if (current.len > root.len and std.mem.startsWith(u8, current, root) and current[root.len] == '/') current[root.len..] else continue;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ std.mem.trimEnd(u8, mount, "/"), suffix });
        var end = std.mem.trimEnd(u8, path, "/").len;
        while (end >= std.mem.trimEnd(u8, mount, "/").len) {
            var name_buffer: [8192]u8 = undefined;
            var value_buffer: [128]u8 = undefined;
            const usage_path = try std.fmt.bufPrint(&name_buffer, "{s}/memory.current", .{path[0..end]});
            const usage = try source.read(io, usage_path, &value_buffer);
            if (usage) |value| {
                const used = (try parseLimit(value)) orelse return error.InvalidMemoryEvidence;
                const max_path = try std.fmt.bufPrint(&name_buffer, "{s}/memory.max", .{path[0..end]});
                const max_value = try source.read(io, max_path, &value_buffer);
                const maximum = if (max_value) |v| try parseLimit(v) else null;
                const high_path = try std.fmt.bufPrint(&name_buffer, "{s}/memory.high", .{path[0..end]});
                const high_value = try source.read(io, high_path, &value_buffer);
                const high = if (high_value) |v| try parseLimit(v) else null;
                if ((max_value == null or high_value == null) and !(max_value == null and high_value == null and end == std.mem.trimEnd(u8, mount, "/").len)) return error.MissingMemoryEvidence;
                result.constrain(used, maximum, high);
            } else if (end != std.mem.trimEnd(u8, mount, "/").len) return error.MissingMemoryEvidence;
            if (end == std.mem.trimEnd(u8, mount, "/").len) break;
            end = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return error.InvalidMemoryEvidence;
        }
        return result;
    }
    return result;
}

test "memory evidence is strict, byte based and excludes swap" {
    const info = try parseMeminfo("MemTotal: 1048576 kB\nMemAvailable: 262144 kB\nSwapFree: 999999999 kB\n");
    try std.testing.expectEqual(1024 * 1024 * 1024, info.total);
    try std.testing.expectEqual(256 * 1024 * 1024, info.effective_available);
    try std.testing.expectError(error.InvalidMemoryEvidence, parseMeminfo("MemTotal: 1 MB\nMemAvailable: 1 kB"));
    try std.testing.expectError(error.InvalidMemoryEvidence, parseMeminfo("MemTotal: 1 kB\nMemAvailable: 2 kB"));
    try std.testing.expectError(error.InvalidMemoryEvidence, parseMeminfo("MemTotal: 1 kB\nMemTotal: 1 kB\nMemAvailable: 1 kB"));
    try std.testing.expectError(error.MissingMemoryEvidence, parseMeminfo("MemTotal: 1 kB"));
    try std.testing.expectError(error.InvalidMemoryEvidence, parseMeminfo("MemTotal: 18446744073709551615 kB\nMemAvailable: 1 kB"));
}
test "cgroup memory high and exhausted ancestor limits constrain available RAM" {
    var s = try parseMeminfo("MemTotal: 8192 kB\nMemAvailable: 4096 kB");
    s.constrain(1024 * 1024, 6 * 1024 * 1024, null);
    s.constrain(3 * 1024 * 1024, 4 * 1024 * 1024, 3 * 1024 * 1024 + 512);
    try std.testing.expectEqual(512, s.effective_available);
    s.constrain(5 * 1024 * 1024, 4 * 1024 * 1024, null);
    try std.testing.expectEqual(0, s.effective_available);
}
test "probe maps the process cgroup through escaped mount roots and walks ancestors" {
    const Fake = struct {
        fn read(_: *const anyopaque, _: std.Io, path: []const u8, _: []u8) !?[]const u8 {
            const pairs = .{
                .{ "/proc/meminfo", "MemTotal: 8388608 kB\nMemAvailable: 6291456 kB\n" },
                .{ "/proc/self/cgroup", "0::/slice/job\n" },
                .{ "/proc/self/mountinfo", "50 20 0:20 /slice /cg\\040memory rw - cgroup2 cgroup rw\n" },
                .{ "/cg memory/job/memory.current", "1073741824\n" },
                .{ "/cg memory/job/memory.max", "max\n" },
                .{ "/cg memory/job/memory.high", "max\n" },
                .{ "/cg memory/memory.current", "3221225472\n" },
                .{ "/cg memory/memory.max", "4294967296\n" },
                .{ "/cg memory/memory.high", "3758096384\n" },
            };
            inline for (pairs) |pair| if (std.mem.eql(u8, path, pair[0])) return pair[1];
            return null;
        }
    };
    const s = try probe(std.testing.io, .{ .context = &SYSTEM_CONTEXT, .read_fn = Fake.read });
    try std.testing.expectEqual(2, s.cgroup_levels);
    try std.testing.expectEqual(3758096384, s.effective_total);
    try std.testing.expectEqual(512 * 1024 * 1024, s.effective_available);
}
test "root cgroup path and absent cgroup mount do not create a double slash" {
    const Fake = struct {
        fn read(_: *const anyopaque, _: std.Io, path: []const u8, _: []u8) !?[]const u8 {
            if (std.mem.eql(u8, path, "/proc/meminfo")) return "MemTotal: 8192 kB\nMemAvailable: 4096 kB\n";
            if (std.mem.eql(u8, path, "/proc/self/cgroup")) return "0::/\n";
            if (std.mem.eql(u8, path, "/proc/self/mountinfo")) return "50 20 0:20 / /cg rw - cgroup2 cgroup rw\n";
            if (std.mem.eql(u8, path, "/cg/memory.current")) return "0";
            if (std.mem.indexOf(u8, path, "//") != null) return error.DoubleSlash;
            return null;
        }
    };
    const s = try probe(std.testing.io, .{ .context = &SYSTEM_CONTEXT, .read_fn = Fake.read });
    try std.testing.expectEqual(4096 * 1024, s.effective_available);
}
