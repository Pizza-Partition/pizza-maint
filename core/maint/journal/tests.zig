const std = @import("std");
const j = @import("../journal.zig");
const storage = @import("storage.zig");

pub fn boundary() j.Boundary {
    return .{ .state = .start, .boot_id = "00000000-0000-0000-0000-000000000001", .plan_id = "plan_test", .utc_unix_ns = "1792400000000000000", .home = .{ .kind = .other_device, .path = "/mnt/journal/pizza" } };
}
fn append(a: std.mem.Allocator, output: *std.ArrayList(u8), seq: u64, ns: u64, step_id: u32, phase: j.Phase, payload: []const u8) !void {
    const record: j.Record = .{ .seq = seq, .monotonic_ns = ns, .step_id = step_id, .phase = phase, .payload = payload };
    try output.appendSlice(a, &try j.encodeHeader(record));
    try output.appendSlice(a, payload);
}
fn seed(a: std.mem.Allocator, bytes: *std.ArrayList(u8)) !void {
    try append(a, bytes, 1, 100, 0, .boundary, try std.json.Stringify.valueAlloc(a, boundary(), .{}));
}

test "journal byte layout and CRC match an independent golden vector" {
    // Golden vector generated independently with Python struct + zlib.crc32.
    const header = try j.encodeHeader(.{ .seq = 0x0102030405060708, .monotonic_ns = 0x1112131415161718, .step_id = 0x21222324, .phase = .note, .payload = "hello" });
    try std.testing.expectEqualStrings("314a5a50010040000807060504030201181716151413121124232221040000000500000078e1aa49000000000000000000000000000000000000000000000000", &std.fmt.bytesToHex(&header, .lower));
}

test "every torn byte and CRC corruption preserves the last valid prefix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    try seed(a, &bytes);
    try append(a, &bytes, 2, 101, 1, .intent, "begin");
    const prefix = bytes.items.len;
    try append(a, &bytes, 3, 102, 1, .commit, "done");
    for (prefix + 1..bytes.items.len) |length| {
        var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scratch.deinit();
        const parsed = try j.scan(scratch.allocator(), bytes.items[0..length]);
        try std.testing.expectEqual(prefix, parsed.valid_bytes);
        try std.testing.expectEqual(.in_flight, parsed.state.steps.get(1).?.state);
        try std.testing.expect(parsed.tail == .short_header or parsed.tail == .short_payload);
    }
    for (prefix..bytes.items.len) |index| {
        bytes.items[index] ^= 1;
        var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scratch.deinit();
        const parsed = try j.scan(scratch.allocator(), bytes.items);
        try std.testing.expectEqual(prefix, parsed.valid_bytes);
        try std.testing.expect(parsed.tail != .clean);
        bytes.items[index] ^= 1;
    }
    const good = try j.scan(a, bytes.items);
    try std.testing.expectEqual(.clean, good.tail);
    try std.testing.expectEqual(.succeeded, good.state.steps.get(1).?.state);
}

test "boot anchors allow clock resets and notes preserve in-flight state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    try seed(a, &bytes);
    try append(a, &bytes, 2, 200, 1, .intent, "begin");
    var next = boundary();
    next.boot_id = "00000000-0000-0000-0000-000000000002";
    next.utc_unix_ns = "1792500000000000000";
    try append(a, &bytes, 3, 1, 0, .boundary, try std.json.Stringify.valueAlloc(a, next, .{}));
    try append(a, &bytes, 4, 2, 1, .note, "reboot detected");
    const parsed = try j.scan(a, bytes.items);
    try std.testing.expectEqual(.clean, parsed.tail);
    try std.testing.expectEqual(.in_flight, parsed.state.steps.get(1).?.state);
    const prefix = bytes.items.len;
    try append(a, &bytes, 4, 3, 2, .intent, "duplicate sequence");
    const bad = try j.scan(a, bytes.items);
    try std.testing.expectEqual(.sequence, bad.tail);
    try std.testing.expectEqual(prefix, bad.valid_bytes);
}

test "CRC-valid impossible phases and unsupported versions are not accepted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    try seed(a, &bytes);
    const prefix = bytes.items.len;
    try append(a, &bytes, 2, 101, 7, .commit, "no intent");
    try std.testing.expectEqual(.invalid_transition, (try j.scan(a, bytes.items)).tail);
    bytes.shrinkRetainingCapacity(prefix);
    try append(a, &bytes, 2, 99, 1, .intent, "clock went backwards");
    try std.testing.expectEqual(.invalid_transition, (try j.scan(a, bytes.items)).tail);
    bytes.items[prefix + 4] = 2;
    try std.testing.expectEqual(.unsupported_version, (try j.scan(a, bytes.items)).tail);
}

fn fixture(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-journal-test-");
}

test "disk journal survives close and reopen, rejects a second writer, and reports mixed steps" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const path = try fixture(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var writer = try j.Writer.create(a, io, dir, boundary(), 100, .{});
    try std.testing.expectError(error.PathAlreadyExists, j.Writer.create(a, io, dir, boundary(), 100, .{}));
    var next = boundary();
    next.boot_id = "00000000-0000-0000-0000-000000000002";
    try std.testing.expectError(error.WouldBlock, j.Writer.open(a, io, dir, next, 1, .{}));
    _ = try writer.intent(io, 1, 101, "first");
    _ = try writer.commit(io, 1, 102, "ok");
    _ = try writer.intent(io, 2, 103, "second");
    _ = try writer.fail(io, 2, 104, "failed");
    _ = try writer.intent(io, 3, 105, "interrupted");
    writer.close(io);
    var reopened = try j.Writer.open(a, io, dir, next, 1, .{});
    _ = try reopened.note(io, 3, 2, "reboot");
    reopened.close(io);
    const parsed = try j.readFile(a, io, try std.fs.path.join(a, &.{ path, "journal.bin" }));
    try std.testing.expectEqual(.clean, parsed.tail);
    try std.testing.expectEqual(@as(u64, 8), parsed.state.seq);
    try std.testing.expectEqual(.succeeded, parsed.state.steps.get(1).?.state);
    try std.testing.expectEqual(.failed, parsed.state.steps.get(2).?.state);
    try std.testing.expectEqual(.in_flight, parsed.state.steps.get(3).?.state);
}

test "write and fsync faults poison the writer and never permit the mutation gate" {
    inline for (.{ storage.Faults{ .short_write_at = 2 }, storage.Faults{ .fsync_at = 2 } }) |fault| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const path = try fixture(a, io);
        defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        var writer = try j.Writer.create(a, io, dir, boundary(), 100, fault);
        var mutated = false;
        if (writer.intent(io, 1, 101, "begin")) |_| {
            mutated = true;
        } else |_| {}
        try std.testing.expect(!mutated);
        try std.testing.expectEqual(.degraded, writer.durability);
        try std.testing.expectError(error.JournalDegraded, writer.commit(io, 1, 102, "must not publish"));
        const size = (try writer.file.stat(io)).size;
        try std.testing.expectError(error.JournalDegraded, writer.intent(io, 2, 103, "must not start"));
        try std.testing.expectEqual(size, (try writer.file.stat(io)).size);
        writer.close(io);
        const full = try std.fs.path.join(a, &.{ path, "journal.bin" });
        const parsed = try j.readFile(a, io, full);
        try std.testing.expectEqual(if (fault.short_write_at != null) j.Tail.short_header else j.Tail.clean, parsed.tail);
        if (fault.short_write_at != null) {
            var next = boundary();
            next.boot_id = "00000000-0000-0000-0000-000000000002";
            try std.testing.expectError(error.JournalHasInvalidTail, j.Writer.open(a, io, dir, next, 1, .{}));
            try std.testing.expectEqual(size, (try std.Io.Dir.cwd().statFile(io, full, .{})).size);
        }
    }
}

test "directory durability failure is surfaced and a completion cannot hide unfinished work" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const path = try fixture(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    try std.testing.expectError(error.InjectedDirectoryFsyncFailure, j.Writer.create(a, io, dir, boundary(), 100, .{ .directory_fsync = true }));
    try std.testing.expectError(error.PathAlreadyExists, j.Writer.create(a, io, dir, boundary(), 100, .{}));
    var next = boundary();
    next.boot_id = "00000000-0000-0000-0000-000000000002";
    var writer = try j.Writer.open(a, io, dir, next, 1, .{});
    defer writer.close(io);
    _ = try writer.intent(io, 1, 2, "begin");
    next.state = .complete;
    const size = (try writer.file.stat(io)).size;
    try std.testing.expectError(error.InvalidTransition, writer.boundaryRecord(io, next, 3));
    try std.testing.expectEqual(size, (try writer.file.stat(io)).size);
    _ = try writer.commit(io, 1, 4, "ok");
    _ = try writer.boundaryRecord(io, next, 5);
    try std.testing.expectError(error.InvalidTransition, writer.intent(io, 2, 6, "too late"));
}

test "maximum sequences cannot be reused and boundary identities cannot change plans" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var bytes: std.ArrayList(u8) = .empty;
    try append(a, &bytes, std.math.maxInt(u64), 100, 0, .boundary, try std.json.Stringify.valueAlloc(a, boundary(), .{}));
    const path = try fixture(a, io);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "journal.bin", .data = bytes.items });
    var next = boundary();
    next.boot_id = "00000000-0000-0000-0000-000000000002";
    try std.testing.expectError(error.SequenceExhausted, j.Writer.open(a, io, dir, next, 1, .{}));
    const parsed = try j.readFile(a, io, try std.fs.path.join(a, &.{ path, "journal.bin" }));
    try std.testing.expectEqual(std.math.maxInt(u64), parsed.state.seq);
    try std.testing.expectEqual(bytes.items.len, parsed.valid_bytes);
    bytes.clearRetainingCapacity();
    try seed(a, &bytes);
    next.plan_id = "different_plan";
    try append(a, &bytes, 2, 1, 0, .boundary, try std.json.Stringify.valueAlloc(a, next, .{}));
    try std.testing.expectEqual(.invalid_boundary, (try j.scan(a, bytes.items)).tail);
}

test "payload limits and malformed boundary JSON stop before unsafe allocation or state changes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    try seed(a, &bytes);
    const prefix = bytes.items.len;
    try append(a, &bytes, 2, 101, 0, .boundary, "{not-json");
    try std.testing.expectEqual(.invalid_boundary, (try j.scan(a, bytes.items)).tail);
    bytes.shrinkRetainingCapacity(prefix);
    try append(a, &bytes, 2, 101, 0, .note, "");
    std.mem.writeInt(u32, bytes.items[prefix + 32 ..][0..4], j.MAX_PAYLOAD + 1, .little);
    const oversized = try j.scan(a, bytes.items);
    try std.testing.expectEqual(.oversized_payload, oversized.tail);
    try std.testing.expectEqual(prefix, oversized.valid_bytes);
    const payload = try a.alloc(u8, j.MAX_PAYLOAD + 1);
    try std.testing.expectError(error.PayloadTooLarge, j.encodeHeader(.{ .seq = 2, .monotonic_ns = 101, .step_id = 0, .phase = .note, .payload = payload }));
}
