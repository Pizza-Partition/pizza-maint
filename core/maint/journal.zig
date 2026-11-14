//! Append-only v1 journal. Disk fields are encoded at explicit protocol offsets.
const std = @import("std");
const proto = @import("proto");

pub const Writer = @import("journal/storage.zig").Writer;
pub const readFile = @import("journal/storage.zig").readFile;
pub const HEADER_BYTES = proto.wire.JOURNAL_HEADER_BYTES;
pub const MAGIC = proto.wire.JOURNAL_MAGIC;
pub const Phase = proto.JournalPhase;
pub const FORMAT_VERSION: u16 = 1;
pub const MAX_PAYLOAD = 64 * 1024;
pub const MAX_FILE_BYTES = 64 * 1024 * 1024;
pub const Durability = enum { durable, degraded };
const Offsets = proto.wire.JournalOffsets;

pub const Record = struct {
    seq: u64,
    monotonic_ns: u64,
    step_id: u32,
    phase: Phase,
    payload: []const u8,
};

/// UTC is a canonical decimal string to preserve nanoseconds in JSON consumers.
/// Paths describe the already-selected journal home; this module never mounts it.
pub const Boundary = struct {
    state: enum { start, complete },
    boot_id: []const u8,
    plan_id: []const u8,
    utc_unix_ns: []const u8,
    home: struct { kind: proto.wire.Home, path: []const u8, device_uuid: ?[]const u8 = null, device_path: ?[]const u8 = null },

    pub fn validate(self: Boundary) !void {
        if (self.boot_id.len != 36) return error.InvalidBoundary;
        for (self.boot_id, 0..) |c, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (c != '-') return error.InvalidBoundary;
            } else if (std.mem.indexOfScalar(u8, "0123456789abcdef", c) == null) return error.InvalidBoundary;
        }
        if (self.plan_id.len == 0 or self.plan_id.len > 64) return error.InvalidBoundary;
        for (self.plan_id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidBoundary;
        if (self.utc_unix_ns.len == 0 or (self.utc_unix_ns.len > 1 and self.utc_unix_ns[0] == '0')) return error.InvalidBoundary;
        for (self.utc_unix_ns) |c| if (!std.ascii.isDigit(c)) return error.InvalidBoundary;
        _ = std.fmt.parseInt(u64, self.utc_unix_ns, 10) catch return error.InvalidBoundary;
        if (!std.fs.path.isAbsolute(self.home.path) or self.home.path.len > 4096 or std.mem.indexOfScalar(u8, self.home.path, 0) != null)
            return error.InvalidBoundary;
        if ((self.home.device_uuid == null) != (self.home.device_path == null)) return error.InvalidBoundary;
        if (self.home.device_uuid) |uuid| {
            if (uuid.len != 32) return error.InvalidBoundary;
            if (std.mem.indexOfNone(u8, uuid, "0123456789abcdef") != null) return error.InvalidBoundary;
            try @import("utils").filesystem.checkPath(self.home.device_path.?);
        }
    }
};

pub const Anchor = struct { boundary: Boundary, monotonic_ns: u64 };

/// Samples a boot identity and UTC/monotonic pair. Sysctl proc files need a
/// streaming reader; their reported file size and positional IO are unreliable.
pub fn captureBoundary(allocator: std.mem.Allocator, io: std.Io, boundary: Boundary) !Anchor {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/sys/kernel/random/boot_id", .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(64));
    var result = boundary;
    result.boot_id = std.mem.trim(u8, bytes, "\r\n");
    const utc = std.Io.Timestamp.now(io, .real).toNanoseconds();
    if (utc < 0 or utc > std.math.maxInt(u64)) return error.ClockOutOfRange;
    result.utc_unix_ns = try allocator.print("{d}", .{utc});
    const monotonic_ns = try monotonicNow(io);
    try result.validate();
    return .{ .boundary = result, .monotonic_ns = monotonic_ns };
}

pub fn monotonicNow(io: std.Io) !u64 {
    const time = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    if (time < 0 or time > std.math.maxInt(u64)) return error.ClockOutOfRange;
    return @intCast(time);
}

pub const StepState = enum { in_flight, succeeded, failed };
pub const Step = struct { state: StepState, seq: u64 };
pub const Tail = enum { clean, short_header, short_payload, invalid_header, unsupported_version, oversized_payload, checksum, sequence, invalid_transition, invalid_boundary };

/// State spans boot boundaries. Notes never hide an unfinished intent.
/// A v1 step executes once; retries require a separate plan/journal.
pub const State = struct {
    steps: std.AutoArrayHashMapUnmanaged(u32, Step) = .empty,
    seq: u64 = 0,
    monotonic_ns: u64 = 0,
    boundary: ?Boundary = null,
    complete: bool = false,

    pub fn apply(self: *State, allocator: std.mem.Allocator, record: Record) !void {
        if (record.seq == 0 or record.seq <= self.seq) return error.InvalidSequence;
        if (self.complete) return error.InvalidTransition;
        var boundary: ?Boundary = null;
        if (record.phase == .boundary) {
            if (record.step_id != 0) return error.InvalidBoundary;
            const b = std.json.parseFromSliceLeaky(Boundary, allocator, record.payload, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidBoundary,
            };
            try b.validate();
            if (self.boundary) |previous| {
                if (!std.mem.eql(u8, previous.plan_id, b.plan_id) or previous.home.kind != b.home.kind or !std.mem.eql(u8, previous.home.path, b.home.path)) return error.InvalidBoundary;
                if (b.state == .start and std.mem.eql(u8, previous.boot_id, b.boot_id)) return error.InvalidBoundary;
                if (b.state == .complete and !std.mem.eql(u8, previous.boot_id, b.boot_id)) return error.InvalidBoundary;
            } else if (b.state != .start) return error.InvalidBoundary;
            if (b.state == .complete) for (self.steps.values()) |step| {
                if (step.state == .in_flight) return error.InvalidTransition;
            };
            boundary = b;
        } else if (self.boundary == null) return error.InvalidBoundary;
        if (self.seq != 0 and record.monotonic_ns < self.monotonic_ns and !(boundary != null and boundary.?.state == .start)) return error.InvalidTransition;
        switch (record.phase) {
            .intent => {
                if (record.step_id == 0 or self.steps.contains(record.step_id)) return error.InvalidTransition;
                try self.steps.put(allocator, record.step_id, .{ .state = .in_flight, .seq = record.seq });
            },
            .commit, .fail => {
                const step = self.steps.getPtr(record.step_id) orelse return error.InvalidTransition;
                if (step.state != .in_flight) return error.InvalidTransition;
                step.* = .{ .state = if (record.phase == .commit) .succeeded else .failed, .seq = record.seq };
            },
            .note, .boundary => {},
        }
        self.seq = record.seq;
        self.monotonic_ns = record.monotonic_ns;
        if (boundary) |b| {
            self.boundary = b;
            self.complete = b.state == .complete;
        }
    }
};

pub const Scan = struct {
    records: []const Record,
    state: State,
    valid_bytes: usize,
    tail: Tail,
};

/// Allocates record/state indexes; payloads borrow `bytes`. Stops at the first
/// invalid record without resynchronizing or modifying the source journal.
pub fn scan(allocator: std.mem.Allocator, bytes: []const u8) !Scan {
    if (bytes.len > MAX_FILE_BYTES) return error.JournalTooLarge;
    var records: std.ArrayList(Record) = .empty;
    var state: State = .{};
    var position: usize = 0;
    var tail: Tail = .clean;
    while (position < bytes.len) {
        const remaining = bytes[position..];
        if (remaining.len < HEADER_BYTES) {
            tail = .short_header;
            break;
        }
        const header: *const [HEADER_BYTES]u8 = remaining[0..HEADER_BYTES];
        if (get(u32, header, Offsets.MAGIC) != MAGIC or get(u16, header, Offsets.HEADER_BYTES) != HEADER_BYTES) {
            tail = .invalid_header;
            break;
        }
        if (get(u16, header, Offsets.VERSION) != FORMAT_VERSION) {
            tail = .unsupported_version;
            break;
        }
        if (!std.mem.allEqual(u8, header[29..32], 0) or !std.mem.allEqual(u8, header[40..], 0)) {
            tail = .invalid_header;
            break;
        }
        const phase = std.enums.fromInt(Phase, header[Offsets.PHASE]) orelse {
            tail = .invalid_header;
            break;
        };
        const length = get(u32, header, Offsets.PAYLOAD_LEN);
        if (length > MAX_PAYLOAD) {
            tail = .oversized_payload;
            break;
        }
        if (remaining.len - HEADER_BYTES < length) {
            tail = .short_payload;
            break;
        }
        const payload = remaining[HEADER_BYTES..][0..length];
        if (checksum(header.*, payload) != get(u32, header, Offsets.CRC32)) {
            tail = .checksum;
            break;
        }
        const record: Record = .{ .seq = get(u64, header, Offsets.SEQ), .monotonic_ns = get(u64, header, Offsets.MONOTONIC_NS), .step_id = get(u32, header, Offsets.STEP_ID), .phase = phase, .payload = payload };
        state.apply(allocator, record) catch |err| switch (err) {
            error.InvalidSequence => {
                tail = .sequence;
                break;
            },
            error.InvalidTransition => {
                tail = .invalid_transition;
                break;
            },
            error.InvalidBoundary => {
                tail = .invalid_boundary;
                break;
            },
            else => return err,
        };
        try records.append(allocator, record);
        position += HEADER_BYTES + length;
    }
    return .{ .records = try records.toOwnedSlice(allocator), .state = state, .valid_bytes = position, .tail = tail };
}

/// All reserved bytes are zero and CRC-32/ISO-HDLC covers header plus payload.
pub fn encodeHeader(record: Record) ![HEADER_BYTES]u8 {
    if (record.payload.len > MAX_PAYLOAD) return error.PayloadTooLarge;
    var header: [HEADER_BYTES]u8 = @splat(0);
    put(u32, &header, Offsets.MAGIC, MAGIC);
    put(u16, &header, Offsets.VERSION, FORMAT_VERSION);
    put(u16, &header, Offsets.HEADER_BYTES, HEADER_BYTES);
    put(u64, &header, Offsets.SEQ, record.seq);
    put(u64, &header, Offsets.MONOTONIC_NS, record.monotonic_ns);
    put(u32, &header, Offsets.STEP_ID, record.step_id);
    header[Offsets.PHASE] = @backingInt(record.phase);
    put(u32, &header, Offsets.PAYLOAD_LEN, @intCast(record.payload.len));
    put(u32, &header, Offsets.CRC32, checksum(header, record.payload));
    return header;
}

fn checksum(header: [HEADER_BYTES]u8, payload: []const u8) u32 {
    var clean = header;
    @memset(clean[Offsets.CRC32..][0..4], 0);
    var crc = std.hash.Crc32.init();
    crc.update(&clean);
    crc.update(payload);
    return crc.final();
}

fn get(comptime T: type, header: *const [HEADER_BYTES]u8, offset: usize) T {
    return std.mem.readInt(T, header[offset..][0..@sizeOf(T)], .little);
}
fn put(comptime T: type, header: *[HEADER_BYTES]u8, offset: usize, value: T) void {
    std.mem.writeInt(T, header[offset..][0..@sizeOf(T)], value, .little);
}

test {
    _ = @import("journal/tests.zig");
    _ = @import("journal/storage.zig");
}
