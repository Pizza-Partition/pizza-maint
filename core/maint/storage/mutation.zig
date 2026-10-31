//! Format backends describe intended changes; they never construct undo logs.
const model = @import("model.zig");
const std = @import("std");
const device = @import("device.zig");
pub const MAX_RECORD_BYTES = 1024 * 1024;

pub const Read = struct { range: model.Range, expected: model.Digest };
pub const Write = struct {
    /// Device-sector-aligned byte range. Builder.stageWrite expands partial
    /// metadata updates while preserving the rest of each affected sector.
    range: model.Range,
    content: []const u8,
    /// A captured planning-time precondition, if the producer has one.
    expected: ?model.Digest = null,
    kind: enum { metadata, discard } = .metadata,
};
/// Slices belong to the producer's planning arena. The common compiler freezes
/// them into a Plan. Neither old payload bytes nor recovery records belong here.
pub const MutationSet = struct {
    target: model.Target,
    writes: []const Write = &.{},
    reads: []const Read = &.{},
};

/// Byte encodings only. The common compiler merges partial sectors against the
/// correct preceding data version, after relocations have been described.
pub const Collector = struct {
    allocator: @import("std").mem.Allocator,
    target: model.Target,
    writes: @import("std").ArrayList(Write) = .empty,
    pub fn write(self: *Collector, offset: u64, content: []const u8) !void {
        const range: model.Range = .{ .offset = offset, .length = content.len };
        if (content.len == 0 or try range.end() > self.target.capacity) return error.RangeOutsideDevice;
        try self.writes.append(self.allocator, .{ .range = range, .content = try self.allocator.dupe(u8, content) });
    }
    pub fn finish(self: *Collector) !MutationSet {
        return .{ .target = self.target, .writes = try self.writes.toOwnedSlice(self.allocator) };
    }
};

/// Mutable record copies and relocation views used only by format encoders.
pub const Builder = struct {
    const Entry = struct { before: []u8, base: ?[]u8 = null, after: ?[]u8 = null };
    allocator: std.mem.Allocator,
    source: device.Reader,
    entries: std.AutoHashMap(u64, Entry),
    relocated: std.AutoHashMap(u64, u64),
    written_bytes: u64 = 0,
    max_cached_bytes: u64 = @as(@import("memory.zig").PlanningLimits, .{}).read_bytes,

    pub fn init(a: std.mem.Allocator, source: device.Reader) Builder {
        return .{ .allocator = a, .source = source, .entries = .init(a), .relocated = .init(a), .max_cached_bytes = source.limits().read_bytes };
    }

    pub fn deinit(self: *Builder) void {
        var values = self.entries.valueIterator();
        while (values.next()) |entry| {
            self.allocator.free(entry.before);
            if (entry.base) |bytes| self.allocator.free(bytes);
            if (entry.after) |bytes| self.allocator.free(bytes);
        }
        self.entries.deinit();
        self.relocated.deinit();
        self.* = undefined;
    }

    pub fn reader(self: *Builder) device.Reader {
        return .{ .context = self, .target = self.source.target, .vtable = &.{ .read = read }, .memory = self.source.memory, .region = self.source.region };
    }

    /// Immutable source version for relocation, even after overlapping staged
    /// writes. These reads join the same execution-time read guards.
    pub fn originalReader(self: *Builder) device.Reader {
        return .{ .context = self, .target = self.source.target, .vtable = &.{ .read = readOriginal }, .memory = self.source.memory, .region = self.source.region };
    }

    fn readOriginal(context: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self: *Builder = @constCast(@as(*const Builder, @ptrCast(@alignCast(context))));
        var done: usize = 0;
        const size = self.source.target.sector_size;
        while (done < bytes.len) {
            const position = offset + done;
            const within: usize = @intCast(position % size);
            const count = @min(size - within, bytes.len - done);
            const cached = try self.getEntry(io, position / size);
            @memcpy(bytes[done..][0..count], cached.before[within..][0..count]);
            done += count;
        }
    }

    fn getEntry(self: *Builder, io: std.Io, index: u64) !*Entry {
        const size = self.source.target.sector_size;
        try self.cacheOriginal(io, index);
        if (self.relocated.get(index)) |origin| {
            if (self.entries.get(index).?.base == null) {
                const base = try self.allocator.alloc(u8, size);
                errdefer self.allocator.free(base);
                try self.readOriginalSector(io, origin, base);
                // Capturing the origin may grow and relocate the hash map.
                self.entries.getPtr(index).?.base = base;
            }
        }
        return self.entries.getPtr(index).?;
    }

    fn cacheOriginal(self: *Builder, io: std.Io, index: u64) !void {
        if (self.entries.contains(index)) return;
        const size = self.source.target.sector_size;
        if ((self.entries.count() + 1) * @as(u64, size) > self.max_cached_bytes) return error.StorageReadSetTooLarge;
        const bytes = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(bytes);
        try self.source.readInto(io, index * size, bytes);
        try self.entries.put(index, .{ .before = bytes });
    }

    fn read(context: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self: *Builder = @constCast(@as(*const Builder, @ptrCast(@alignCast(context))));
        var done: usize = 0;
        const size = self.source.target.sector_size;
        while (done < bytes.len) {
            const position = offset + done;
            const within: usize = @intCast(position % size);
            const count = @min(size - within, bytes.len - done);
            const cached = try self.getEntry(io, position / size);
            @memcpy(bytes[done..][0..count], (cached.after orelse (cached.base orelse cached.before))[within..][0..count]);
            done += count;
        }
    }

    /// C libraries may write arbitrary byte ranges. Protect whole device
    /// sectors, including bytes outside a partial write, before changing them.
    pub fn stageWrite(self: *Builder, io: std.Io, offset: u64, bytes: []const u8) !void {
        const end = std.math.add(u64, offset, bytes.len) catch return error.RangeOverflow;
        if (end > self.source.target.capacity) return error.RangeOutsideDevice;
        var done: usize = 0;
        const size = self.source.target.sector_size;
        while (done < bytes.len) {
            const position = offset + done;
            const within: usize = @intCast(position % size);
            const count = @min(size - within, bytes.len - done);
            const cached = try self.getEntry(io, position / size);
            if (cached.after == null) {
                if (self.written_bytes + size > self.source.limits().encoded_bytes) return error.StorageTransactionTooLarge;
                cached.after = try self.allocator.dupe(u8, cached.base orelse cached.before);
                self.written_bytes += size;
            }
            @memcpy(cached.after.?[within..][0..count], bytes[done..][0..count]);
            done += count;
        }
    }

    fn readOriginalSector(self: *Builder, io: std.Io, index: u64, bytes: []u8) !void {
        try self.cacheOriginal(io, index);
        @memcpy(bytes, self.entries.get(index).?.before);
    }

    /// Make relocated records readable to the codec. The common planner owns
    /// the physical move; this only maps destinations to original source bytes.
    pub fn mapRelocation(self: *Builder, io: std.Io, source: u64, destination: u64, length: u64) !void {
        const size = self.source.target.sector_size;
        try (model.Range{ .offset = source, .length = length }).validate(self.source.target.capacity, size);
        try (model.Range{ .offset = destination, .length = length }).validate(self.source.target.capacity, size);
        if (source == destination) return;
        const count: usize = @intCast(length / size);
        for (0..count) |i| {
            const origin = source / size + i;
            const index = destination / size + i;
            try self.relocated.put(index, origin);
            if (self.entries.getPtr(index)) |entry| {
                if (entry.base) |bytes| self.allocator.free(bytes);
                entry.base = null;
                if (entry.after) |bytes| {
                    self.allocator.free(bytes);
                    self.written_bytes -= size;
                }
                entry.after = null;
                const base = try self.allocator.alloc(u8, size);
                errdefer self.allocator.free(base);
                try self.readOriginalSector(io, origin, base);
                self.entries.getPtr(index).?.base = base;
            }
        }
    }

    /// Coalesce changed sectors into patches and original reads into guards.
    /// Captured before-images remain authoritative even if the source changes
    /// during planning; execution rejects that stale input before writing.
    pub fn finish(self: *Builder, _: std.Io, discard: bool) !MutationSet {
        const a = self.allocator;
        const keys = try a.alloc(u64, self.entries.count());
        defer a.free(keys);
        var iterator = self.entries.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |key| : (index += 1) keys[index] = key.*;
        std.mem.sort(u64, keys, {}, std.sort.asc(u64));
        var reads: std.ArrayList(Read) = .empty;
        var writes: std.ArrayList(Write) = .empty;
        const size = self.source.target.sector_size;
        index = 0;
        while (index < keys.len) {
            const start = index;
            index += 1;
            while (index < keys.len and keys[index] == keys[index - 1] + 1 and (index - start + 1) * size <= MAX_RECORD_BYTES) : (index += 1) {}
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            for (keys[start..index]) |key| hash.update(self.entries.get(key).?.before);
            try reads.append(
                a,
                .{
                    .range = .{ .offset = keys[start] * size, .length = (index - start) * size },
                    .expected = hash.finalResult(),
                },
            );
        }
        index = 0;
        while (index < keys.len) {
            const first = self.entries.get(keys[index]).?;
            if (first.after == null or std.mem.eql(u8, first.base orelse first.before, first.after.?)) {
                index += 1;
                continue;
            }
            const start = index;
            index += 1;
            while (index < keys.len and keys[index] == keys[index - 1] + 1 and (index - start + 1) * size <= MAX_RECORD_BYTES) : (index += 1) {
                const next = self.entries.get(keys[index]).?;
                if (next.after == null or std.mem.eql(u8, next.base orelse next.before, next.after.?)) break;
            }
            const bytes = try a.alloc(u8, (index - start) * size);
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            for (keys[start..index], 0..) |key, part| {
                const cached = self.entries.get(key).?;
                hash.update(cached.before);
                @memcpy(bytes[part * size ..][0..size], cached.after.?);
            }
            try writes.append(a, .{ .range = .{ .offset = keys[start] * size, .length = bytes.len }, .expected = hash.finalResult(), .content = bytes, .kind = if (discard) .discard else .metadata });
        }
        return .{ .target = self.source.target, .reads = try reads.toOwnedSlice(a), .writes = try writes.toOwnedSlice(a) };
    }
};
