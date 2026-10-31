const std = @import("std");
const journal = @import("../journal.zig");

/// Explicit fault injection for the VM fault suite. Defaults always use real IO.
pub const Faults = struct {
    short_write_at: ?u64 = null,
    fsync_at: ?u64 = null,
    directory_fsync: bool = false,
};

/// Owns its file and an exclusive nonblocking advisory lock until close.
/// One caller serializes appends. A failed write/fsync permanently degrades this
/// handle: no later append can acknowledge or reuse an uncertain sequence.
/// `durable` means fsync acknowledged the writes. The caller must independently
/// validate persistent backing and durably establish the home directory itself.
pub const Writer = struct {
    file: std.Io.File,
    arena: std.heap.ArenaAllocator,
    state: journal.State = .{},
    offset: u64 = 0,
    durability: journal.Durability = .durable,
    faults: Faults = .{},

    /// The caller supplies an existing, trusted directory on its selected media.
    /// Creates only journal.bin, exclusively, and fsyncs both record and directory.
    /// Failures preserve any created file for diagnosis; they never overwrite it.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, boundary: journal.Boundary, monotonic_ns: u64, faults: Faults) !Writer {
        if (boundary.state != .start) return error.InvalidBoundary;
        try boundary.validate();
        const file = try directory.createFile(io, "journal.bin", .{ .read = true, .truncate = false, .exclusive = true, .permissions = .fromMode(0o600), .lock = .exclusive, .lock_nonblocking = true });
        var self: Writer = .{ .file = file, .arena = .init(allocator), .faults = faults };
        errdefer self.close(io);
        _ = try self.boundaryRecord(io, boundary, monotonic_ns);
        try syncDirectory(io, directory, faults);
        return self;
    }

    /// Reopens a clean journal and durably adds the new boot's UTC anchor.
    /// Torn/corrupt tails are readable but never truncated or resumed implicitly.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, boundary: journal.Boundary, monotonic_ns: u64, faults: Faults) !Writer {
        if (boundary.state != .start) return error.InvalidBoundary;
        try boundary.validate();
        const file = try directory.openFile(io, "journal.bin", .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true });
        var self: Writer = .{ .file = file, .arena = .init(allocator), .faults = faults };
        errdefer self.close(io);
        const parsed = try readFrom(self.arena.allocator(), io, file);
        if (parsed.tail != .clean) return error.JournalHasInvalidTail;
        if (parsed.records.len == 0) return error.MissingBoundary;
        self.state = parsed.state;
        self.offset = parsed.valid_bytes;
        _ = try self.boundaryRecord(io, boundary, monotonic_ns);
        try syncDirectory(io, directory, faults);
        return self;
    }

    pub fn close(self: *Writer, io: std.Io) void {
        self.file.close(io);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Same-thread UI snapshots use this already-locked descriptor and include
    /// only the prefix whose fsync succeeded. Never reacquire our own lock.
    pub fn snapshot(self: *const Writer, a: std.mem.Allocator, io: std.Io) !journal.Scan {
        const bytes = try a.alloc(u8, @intCast(self.offset));
        if (try self.file.readPositionalAll(io, bytes, 0) != bytes.len) return error.JournalChangedDuringRead;
        return journal.scan(a, bytes);
    }

    /// Returns only after intent bytes have reached fsync. The executor must wait
    /// for this success before beginning its mutation, and stop on every error.
    pub fn intent(self: *Writer, io: std.Io, step_id: u32, monotonic_ns: u64, payload: []const u8) !u64 {
        return self.append(io, step_id, .intent, monotonic_ns, payload);
    }
    pub fn commit(self: *Writer, io: std.Io, step_id: u32, monotonic_ns: u64, payload: []const u8) !u64 {
        return self.append(io, step_id, .commit, monotonic_ns, payload);
    }
    pub fn fail(self: *Writer, io: std.Io, step_id: u32, monotonic_ns: u64, payload: []const u8) !u64 {
        return self.append(io, step_id, .fail, monotonic_ns, payload);
    }
    pub fn note(self: *Writer, io: std.Io, step_id: u32, monotonic_ns: u64, payload: []const u8) !u64 {
        return self.append(io, step_id, .note, monotonic_ns, payload);
    }
    pub fn boundaryRecord(self: *Writer, io: std.Io, boundary: journal.Boundary, monotonic_ns: u64) !u64 {
        try boundary.validate();
        const payload = try std.json.Stringify.valueAlloc(self.arena.allocator(), boundary, .{});
        return self.append(io, 0, .boundary, monotonic_ns, payload);
    }

    fn append(self: *Writer, io: std.Io, step_id: u32, phase: journal.Phase, monotonic_ns: u64, payload: []const u8) !u64 {
        if (self.durability != .durable) return error.JournalDegraded;
        const seq = std.math.add(u64, self.state.seq, 1) catch return error.SequenceExhausted;
        const record: journal.Record = .{ .seq = seq, .monotonic_ns = monotonic_ns, .step_id = step_id, .phase = phase, .payload = payload };
        const header = try journal.encodeHeader(record);
        const end = self.offset + journal.HEADER_BYTES + payload.len;
        if (end > journal.MAX_FILE_BYTES) return error.JournalTooLarge;
        try self.state.apply(self.arena.allocator(), record);
        // From this point onward, bytes or durability may be uncertain. Poison
        // the handle on every IO error, including cancellation.
        errdefer self.durability = .degraded;
        if (self.faults.short_write_at == seq) {
            try self.file.writePositionalAll(io, header[0..17], self.offset);
            return error.InjectedShortWrite;
        }
        try self.file.writePositionalAll(io, &header, self.offset);
        try self.file.writePositionalAll(io, payload, self.offset + journal.HEADER_BYTES);
        if (self.faults.fsync_at == seq) return error.InjectedFsyncFailure;
        try self.file.sync(io);
        self.offset = end;
        return seq;
    }
};

fn syncDirectory(io: std.Io, directory: std.Io.Dir, faults: Faults) !void {
    // Dir.openDir uses O_PATH by default on Linux; open a readable descriptor
    // explicitly so directory fsync cannot fail with EBADF.
    const parent = try directory.openFile(io, ".", .{ .allow_directory = true });
    defer parent.close(io);
    if (faults.directory_fsync) return error.InjectedDirectoryFsyncFailure;
    try parent.sync(io);
}

/// Reads a stable snapshot under a shared advisory lock. Uses the caller's arena
/// for bytes and indexes; report/scan never change or repair journal contents.
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !journal.Scan {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false, .lock = .shared, .lock_nonblocking = true });
    defer file.close(io);
    return readFrom(allocator, io, file);
}

fn readFrom(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !journal.Scan {
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.JournalMustBeRegular;
    if (stat.size > journal.MAX_FILE_BYTES) return error.JournalTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.JournalChangedDuringRead;
    return journal.scan(allocator, bytes);
}
