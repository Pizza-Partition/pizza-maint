//! Immutable, versioned physical program. No filesystem types enter its codec.
const std = @import("std");
const model = @import("model.zig");
const devices = @import("device.zig");
const mutation = @import("mutation.zig");
pub const VERSION = 7;
pub const MAX_STEPS = 16384;
pub const MAX_ENCODED_BYTES = 64 * 1024 * 1024;
pub const Guard = struct { range: model.Range, expected: model.Digest };
pub const Save = struct { source: model.Range, source_version: u32, expected: model.Digest };
pub const Restore = struct { saved_step: u32, destination: u64 };
pub const Write = struct { range: model.Range, content: []const u8, discard: bool = false };
pub const Copy = struct { source: model.Target, range: model.Range, destination: u64, expected: model.Digest };
pub const Operation = union(enum) { save: Save, restore: Restore, write: Write, barrier: void, copy: Copy };
pub const Step = struct { operation: Operation, dependencies: []const u32 = &.{} };
/// Frozen semantic authorization evidence; raw recovery never interprets it.
pub const Evidence = struct {
    range: model.Range,
    input_version: u32,
    filesystem: model.Filesystem,
    operation: model.Kind,
    checkpoint: u64,
    features_digest: model.Digest,
    capabilities_digest: model.Digest,
};
pub const Program = struct {
    request_digest: model.Digest = @splat(0),
    evidence: []const Evidence = &.{},
    target: model.Target,
    steps: []const Step,
    guards: []const Guard,
    encoded: []const u8,
    digest: model.Digest,

    pub fn targetRange(self: Program, index: usize) ?model.Range {
        return switch (self.steps[index].operation) {
            .write => |w| w.range,
            .copy => |v| .{ .offset = v.destination, .length = v.range.length },
            .restore => |r| .{ .offset = r.destination, .length = self.steps[r.saved_step].operation.save.source.length },
            else => null,
        };
    }
    pub fn validate(self: Program) !void {
        try self.target.validate();
        if (self.steps.len > MAX_STEPS or self.guards.len > MAX_STEPS or self.evidence.len > MAX_STEPS) return error.StorageProgramTooLarge;
        for (self.evidence) |e| {
            try e.range.validate(self.target.capacity, self.target.sector_size);
            if (e.input_version > self.steps.len) return error.InvalidDataVersion;
        }
        for (self.guards) |g| try g.range.validate(self.target.capacity, self.target.sector_size);
        for (self.steps, 0..) |step, i| {
            for (step.dependencies) |dep| if (dep >= i) return error.InvalidProgramDependency;
            // The canonical program is serial. A predecessor barrier protects
            // every earlier data version, including dependencies not adjacent.
            if (i != 0 and (step.dependencies.len != 1 or step.dependencies[0] != i - 1)) return error.UnorderedStorageProgram;
            if (i == 0 and step.dependencies.len != 0) return error.InvalidProgramDependency;
            switch (step.operation) {
                .save => |s| {
                    try s.source.validate(self.target.capacity, self.target.sector_size);
                    if (s.source_version > i) return error.InvalidDataVersion;
                    for (self.steps[s.source_version..i], s.source_version..) |prior, index| {
                        const target = self.targetRange(index) orelse continue;
                        if (target.overlaps(s.source) and (prior.operation == .copy or (prior.operation == .write and prior.operation.write.discard))) return error.DiscardedDataVersion;
                    }
                },
                .restore => |r| {
                    if (r.saved_step >= i or self.steps[r.saved_step].operation != .save) return error.InvalidScratchReference;
                    try self.targetRange(i).?.validate(self.target.capacity, self.target.sector_size);
                },
                .write => |w| {
                    try w.range.validate(self.target.capacity, self.target.sector_size);
                    if (w.range.length != w.content.len) return error.WriteLengthMismatch;
                },
                .copy => |v| {
                    try v.source.validate();
                    try v.range.validate(v.source.capacity, v.source.sector_size);
                    if (v.source.sector_size != self.target.sector_size) return error.InvalidCloneGeometry;
                    if (std.mem.eql(u8, &v.source.identity, &self.target.identity)) return error.CopyAliasesSource;
                    try self.targetRange(i).?.validate(self.target.capacity, self.target.sector_size);
                },
                .barrier => {},
            }
        }
    }
};

pub const PhysicalProgramBuilder = struct {
    allocator: std.mem.Allocator,
    reader: devices.Reader,
    steps: std.ArrayList(Step) = .empty,
    guards: std.ArrayList(Guard) = .empty,
    evidence: std.ArrayList(Evidence) = .empty,
    pub fn init(a: std.mem.Allocator, reader: devices.Reader) PhysicalProgramBuilder {
        return .{ .allocator = a, .reader = reader };
    }
    pub fn attest(self: *PhysicalProgramBuilder, range: model.Range, snapshot: model.Snapshot, operation: model.Kind) !void {
        if (self.evidence.items.len == MAX_STEPS) return error.StorageProgramTooLarge;
        const features = try std.json.Stringify.valueAlloc(self.allocator, snapshot.features, .{});
        defer self.allocator.free(features);
        const capabilities = try std.json.Stringify.valueAlloc(self.allocator, snapshot.capabilities, .{});
        defer self.allocator.free(capabilities);
        try self.evidence.append(self.allocator, .{ .range = range, .input_version = self.currentVersion(), .filesystem = snapshot.filesystem, .operation = operation, .checkpoint = snapshot.generation, .features_digest = model.digest(features), .capabilities_digest = model.digest(capabilities) });
    }
    pub fn currentVersion(self: *const PhysicalProgramBuilder) u32 {
        return @intCast(self.steps.items.len);
    }
    fn append(self: *PhysicalProgramBuilder, operation: Operation) !u32 {
        if (self.steps.items.len == MAX_STEPS) return error.StorageProgramTooLarge;
        const id = self.currentVersion();
        const deps = if (id == 0) &.{} else try self.allocator.dupe(u32, &.{id - 1});
        try self.steps.append(self.allocator, .{ .operation = operation, .dependencies = deps });
        return id;
    }
    pub fn guard(self: *PhysicalProgramBuilder, io: std.Io, range: model.Range) !void {
        for (self.guards.items) |g| if (std.meta.eql(g.range, range)) return;
        if (self.guards.items.len == MAX_STEPS) return error.StorageProgramTooLarge;
        try range.validate(self.reader.target.capacity, self.reader.target.sector_size);
        try self.guards.append(self.allocator, .{ .range = range, .expected = try (self.reader).digest(io, range) });
    }
    pub fn write(self: *PhysicalProgramBuilder, io: std.Io, range: model.Range, bytes: []const u8, discard: bool) !void {
        try range.validate(self.reader.target.capacity, self.reader.target.sector_size);
        if (range.length != bytes.len) return error.WriteLengthMismatch;
        const granule = @max(self.reader.target.sector_size, self.reader.write_granule);
        if (range.offset % granule != 0 or range.length % granule != 0) {
            const start = range.offset / granule * granule;
            const end = std.mem.alignForward(u64, try range.end(), granule);
            if (end > self.reader.target.capacity) return error.UnalignedPhysicalWrite;
            const padded: model.Range = .{ .offset = start, .length = end - start };
            const content = try self.allocator.alloc(u8, @intCast(padded.length));
            defer self.allocator.free(content);
            try self.readVersion(io, self.currentVersion(), padded, content);
            @memcpy(content[@intCast(range.offset - start)..][0..bytes.len], bytes);
            // Neighbors sharing the physical sector always require before-images.
            return self.write(io, padded, content, false);
        }
        try self.guard(io, range);
        _ = try self.append(.{ .write = .{ .range = range, .content = try self.allocator.dupe(u8, bytes), .discard = discard } });
    }
    pub fn save(self: *PhysicalProgramBuilder, io: std.Io, source_version: u32, source: model.Range) !u32 {
        if (source_version > self.steps.items.len) return error.InvalidDataVersion;
        try self.guard(io, source);
        return self.append(.{ .save = .{ .source = source, .source_version = source_version, .expected = try self.hashVersion(io, source_version, source) } });
    }
    pub fn restore(self: *PhysicalProgramBuilder, saved: u32, destination: u64) !void {
        if (saved >= self.steps.items.len or self.steps.items[saved].operation != .save) return error.InvalidScratchReference;
        _ = try self.append(.{ .restore = .{ .saved_step = saved, .destination = destination } });
    }
    pub fn move(self: *PhysicalProgramBuilder, io: std.Io, source_version: u32, source: model.Range, destination: u64) !void {
        try self.guard(io, .{ .offset = destination, .length = source.length });
        const saved = try self.save(io, source_version, source);
        try self.restore(saved, destination);
    }
    pub fn copy(self: *PhysicalProgramBuilder, io: std.Io, source: devices.Reader, range: model.Range, destination: u64) !model.Digest {
        if (std.mem.eql(u8, &source.location().identity, &self.reader.location().identity)) return error.CopyAliasesSource;
        try range.validate(source.target.capacity, source.target.sector_size);
        const expected = try (source).digest(io, range);
        _ = try self.append(.{ .copy = .{ .source = source.target, .range = range, .destination = destination, .expected = expected } });
        return expected;
    }
    pub fn barrier(self: *PhysicalProgramBuilder) !void {
        _ = try self.append(.{ .barrier = {} });
    }
    /// All sources in a MutationSet name its input version. Capturing sources
    /// first makes cycles and self-overlap explicit and safe.
    pub fn apply(self: *PhysicalProgramBuilder, io: std.Io, base: u64, changes: mutation.MutationSet, allow_discard: bool) !void {
        return self.applyVersion(io, base, changes, allow_discard, self.currentVersion());
    }
    pub fn applyVersion(self: *PhysicalProgramBuilder, io: std.Io, base: u64, changes: mutation.MutationSet, allow_discard: bool, input: u32) !void {
        if (input > self.currentVersion()) return error.InvalidDataVersion;
        try changes.target.validate();
        const scope: model.Range = .{ .offset = base, .length = changes.target.capacity };
        try scope.validate(self.reader.target.capacity, self.reader.target.sector_size);
        var view: View = .{ .builder = self, .version = input, .range = scope };
        if (!changes.target.same(view.reader().target)) return error.FilesystemProgramMismatch;

        for (changes.reads) |g| {
            const range: model.Range = .{ .offset = try std.math.add(u64, base, g.range.offset), .length = g.range.length };
            if (!std.mem.eql(u8, &try self.hashVersion(io, input, range), &g.expected)) return error.PlanningReadChanged;
            try self.guard(io, range);
        }
        var sectors: std.AutoHashMap(u64, []u8) = .init(self.allocator);
        defer sectors.deinit();
        const sector = self.reader.target.sector_size;
        var discard_mode: ?bool = null;
        for (changes.writes) |w| {
            if (w.kind == .discard and !allow_discard) return error.UnauthorizedDataDiscard;
            const discard = w.kind == .discard;
            if (discard_mode) |previous| {
                if (previous != discard) return error.MixedDiscardSectorWrites;
            } else discard_mode = discard;
            const offset = try std.math.add(u64, base, w.range.offset);
            const range: model.Range = .{ .offset = offset, .length = w.range.length };
            if (range.length == 0 or range.length != w.content.len or try range.end() > self.reader.target.capacity) return error.WriteLengthMismatch;
            if (w.expected) |expected| if (!std.mem.eql(u8, &try self.hashVersion(io, input, range), &expected)) return error.PlanningReadChanged;
            var done: usize = 0;
            while (done < w.content.len) {
                const at = offset + done;
                const block = at / sector * sector;
                const result = try sectors.getOrPut(block);
                if (!result.found_existing) {
                    const bytes = try self.allocator.alloc(u8, sector);
                    try self.readVersion(io, self.currentVersion(), .{ .offset = block, .length = sector }, bytes);
                    result.value_ptr.* = bytes;
                }
                const within: usize = @intCast(at - block);
                const length = @min(w.content.len - done, sector - within);
                @memcpy(result.value_ptr.*[within..][0..length], w.content[done..][0..length]);
                done += length;
            }
        }
        const keys = try self.allocator.alloc(u64, sectors.count());
        var iterator = sectors.keyIterator();
        var count: usize = 0;
        while (iterator.next()) |key| : (count += 1) keys[count] = key.*;
        std.mem.sort(u64, keys, {}, std.sort.asc(u64));
        var i: usize = 0;
        while (i < keys.len) {
            const start = i;
            i += 1;
            while (i < keys.len and keys[i] == keys[i - 1] + sector and (i - start) * sector < 65536) : (i += 1) {}
            const bytes = try self.allocator.alloc(u8, (i - start) * sector);
            for (keys[start..i], 0..) |key, n| @memcpy(bytes[n * sector ..][0..sector], sectors.get(key).?);
            try self.write(io, .{ .offset = keys[start], .length = bytes.len }, bytes, discard_mode orelse false);
        }
    }
    pub fn readVersion(self: *const PhysicalProgramBuilder, io: std.Io, at_version: u32, range: model.Range, out: []u8) anyerror!void {
        if (at_version > self.steps.items.len or range.length != out.len) return error.InvalidDataVersion;
        try self.reader.readInto(io, range.offset, out);
        for (self.steps.items[0..at_version]) |step| {
            const target: model.Range = switch (step.operation) {
                .write => |w| w.range,
                .copy => |v| .{ .offset = v.destination, .length = v.range.length },
                .restore => |r| .{ .offset = r.destination, .length = self.steps.items[r.saved_step].operation.save.source.length },
                else => continue,
            };
            if (!target.overlaps(range)) continue;
            const start = @max(target.offset, range.offset);
            const end = @min(try target.end(), try range.end());
            const dst = out[@intCast(start - range.offset)..][0..@intCast(end - start)];
            switch (step.operation) {
                .write => |w| @memcpy(dst, w.content[@intCast(start - target.offset)..][0..dst.len]),
                .copy => return error.ExternalDataVersionUnavailable,
                .restore => |r| {
                    const source = self.steps.items[r.saved_step].operation.save;
                    try self.readVersion(io, source.source_version, .{ .offset = source.source.offset + start - target.offset, .length = dst.len }, dst);
                },
                else => unreachable,
            }
        }
    }
    pub fn hashVersion(self: *const PhysicalProgramBuilder, io: std.Io, v: u32, range: model.Range) !model.Digest {
        var buffer: [65536]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        while (offset < range.length) {
            const part = buffer[0..@intCast(@min(buffer.len, range.length - offset))];
            try self.readVersion(io, v, .{ .offset = range.offset + offset, .length = part.len }, part);
            hash.update(part);
            offset += part.len;
        }
        return hash.finalResult();
    }
    pub fn finish(self: *PhysicalProgramBuilder) !Program {
        var result: Program = .{ .evidence = try self.evidence.toOwnedSlice(self.allocator), .target = self.reader.target, .steps = try self.steps.toOwnedSlice(self.allocator), .guards = try self.guards.toOwnedSlice(self.allocator), .encoded = &.{}, .digest = undefined };
        try result.validate();
        result.encoded = try encode(self.allocator, result);
        result.digest = result.encoded[result.encoded.len - 32 ..][0..32].*;
        return result;
    }
    /// A bounded reader of a selected plan version, for metadata queries only.
    pub const View = struct {
        builder: *const PhysicalProgramBuilder,
        version: u32,
        range: model.Range,
        pub fn reader(self: *const View) devices.Reader {
            var target = self.builder.reader.target;
            target.capacity = self.range.length;
            if (self.range.offset != 0 or self.range.length != self.builder.reader.target.capacity) {
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                hash.update("pizza-program-view-v1");
                hash.update(&self.builder.reader.target.identity);
                var bounds: [16]u8 = undefined;
                std.mem.writeInt(u64, bounds[0..8], self.range.offset, .little);
                std.mem.writeInt(u64, bounds[8..16], self.range.length, .little);
                hash.update(&bounds);
                target.identity = hash.finalResult();
            }

            const parent = self.builder.reader.location();
            return .{ .context = self, .target = target, .vtable = &.{ .read = readInto }, .memory = self.builder.reader.memory, .region = .{ .identity = parent.identity, .range = .{ .offset = parent.range.offset + self.range.offset, .length = self.range.length } } };
        }
        fn readInto(ctx: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
            const self: *const View = @ptrCast(@alignCast(ctx));
            if (offset > self.range.length or bytes.len > self.range.length - offset) return error.RangeOutsideDevice;
            try self.builder.readVersion(io, self.version, .{ .offset = self.range.offset + offset, .length = bytes.len }, bytes);
        }
    };
};

/// Read the final state of an immutable program without writing the device.
/// This allows a later maintenance phase to compile against its predecessor.
/// External clone data is intentionally unavailable to this preview.
pub const Preview = struct {
    base: devices.Reader,
    plan: Program,
    pub fn init(base: devices.Reader, plan: Program) !Preview {
        if (!base.target.same(plan.target)) return error.TransactionTargetMismatch;
        try plan.validate();
        return .{ .base = base, .plan = plan };
    }
    pub fn reader(self: *const Preview) devices.Reader {
        var r = self.base;
        r.context = self;
        r.vtable = &.{ .read = read };
        return r;
    }
    fn read(ctx: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self: *const Preview = @ptrCast(@alignCast(ctx));
        var builder = PhysicalProgramBuilder.init(std.heap.page_allocator, self.base);
        // Borrowed only by readVersion; no list mutation or allocation occurs.
        builder.steps.items = @constCast(self.plan.steps);
        builder.steps.capacity = self.plan.steps.len;
        return builder.readVersion(io, @intCast(self.plan.steps.len), .{ .offset = offset, .length = bytes.len }, bytes);
    }
};

fn number(list: *std.ArrayList(u8), a: std.mem.Allocator, n: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, n, .little);
    try list.appendSlice(a, &b);
}
fn rangeBytes(list: *std.ArrayList(u8), a: std.mem.Allocator, r: model.Range) !void {
    try number(list, a, r.offset);
    try number(list, a, r.length);
}
pub fn encode(a: std.mem.Allocator, p: Program) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "PZPROG07");
    try out.appendSlice(a, &p.target.identity);
    try out.appendSlice(a, &p.request_digest);
    for ([_]u64{ p.target.capacity, p.target.sector_size, @backingInt(p.target.kind), p.steps.len, p.guards.len, p.evidence.len }) |n| try number(&out, a, n);
    for (p.evidence) |e| {
        try rangeBytes(&out, a, e.range);
        for ([_]u64{ e.input_version, @backingInt(e.filesystem), @backingInt(e.operation), e.checkpoint }) |n| try number(&out, a, n);
        try out.appendSlice(a, &e.features_digest);
        try out.appendSlice(a, &e.capabilities_digest);
    }
    for (p.guards) |g| {
        try rangeBytes(&out, a, g.range);
        try out.appendSlice(a, &g.expected);
    }
    for (p.steps) |s| {
        try number(&out, a, @backingInt(s.operation));
        try number(&out, a, s.dependencies.len);
        for (s.dependencies) |dep| try number(&out, a, dep);
        switch (s.operation) {
            .save => |v| {
                try rangeBytes(&out, a, v.source);
                try number(&out, a, v.source_version);
                try out.appendSlice(a, &v.expected);
            },
            .restore => |v| {
                try number(&out, a, v.saved_step);
                try number(&out, a, v.destination);
            },
            .write => |v| {
                try rangeBytes(&out, a, v.range);
                try number(&out, a, @intFromBool(v.discard));
                try out.appendSlice(a, v.content);
            },
            .copy => |v| {
                try out.appendSlice(a, &v.source.identity);
                try number(&out, a, v.source.capacity);
                try number(&out, a, v.source.sector_size);
                try number(&out, a, @backingInt(v.source.kind));
                try rangeBytes(&out, a, v.range);
                try number(&out, a, v.destination);
                try out.appendSlice(a, &v.expected);
            },
            .barrier => {},
        }
        if (out.items.len > MAX_ENCODED_BYTES - 32) return error.StorageProgramTooLarge;
    }
    try out.appendSlice(a, &model.digest(out.items));
    return out.toOwnedSlice(a);
}
const Decoder = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Decoder, length: u64) ![]const u8 {
        if (length > self.bytes.len - self.at) return error.InvalidStorageProgram;
        const n: usize = @intCast(length);
        const result = self.bytes[self.at..][0..n];
        self.at += n;
        return result;
    }
    fn num(self: *Decoder) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }
    fn small(self: *Decoder) !u32 {
        return std.math.cast(u32, try self.num()) orelse error.InvalidStorageProgram;
    }
    fn range(self: *Decoder) !model.Range {
        return .{ .offset = try self.num(), .length = try self.num() };
    }
};
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Program {
    if (bytes.len < 152 or bytes.len > MAX_ENCODED_BYTES) return error.InvalidStorageProgram;
    const hash = model.digest(bytes[0 .. bytes.len - 32]);
    if (!std.mem.eql(u8, &hash, bytes[bytes.len - 32 ..])) return error.StorageProgramChecksum;
    var d: Decoder = .{ .bytes = bytes[0 .. bytes.len - 32] };
    if (!std.mem.eql(u8, try d.take(8), "PZPROG07")) return error.UnsupportedStorageProgram;
    const identity = (try d.take(32))[0..32].*;
    const request_digest = (try d.take(32))[0..32].*;
    const capacity = try d.num();
    const sector = try d.small();
    const kind = std.enums.fromInt(@FieldType(model.Target, "kind"), try d.num()) orelse return error.InvalidStorageProgram;
    const count = try d.small();
    const guards_count = try d.small();
    const evidence_count = try d.small();
    if (count > MAX_STEPS or guards_count > MAX_STEPS or evidence_count > MAX_STEPS) return error.StorageProgramTooLarge;
    const evidence = try a.alloc(Evidence, evidence_count);
    for (evidence) |*e| e.* = .{
        .range = try d.range(),
        .input_version = try d.small(),
        .filesystem = std.enums.fromInt(model.Filesystem, try d.num()) orelse return error.InvalidStorageProgram,
        .operation = std.enums.fromInt(model.Kind, try d.num()) orelse return error.InvalidStorageProgram,
        .checkpoint = try d.num(),
        .features_digest = (try d.take(32))[0..32].*,
        .capabilities_digest = (try d.take(32))[0..32].*,
    };
    const guards = try a.alloc(Guard, guards_count);
    for (guards) |*g| g.* = .{ .range = try d.range(), .expected = (try d.take(32))[0..32].* };
    const steps = try a.alloc(Step, count);
    for (steps) |*s| {
        const tag = try d.num();
        const n = try d.small();
        if (n > 1) return error.InvalidProgramDependency;
        const deps = try a.alloc(u32, n);
        for (deps) |*dep| dep.* = try d.small();
        const op: Operation = switch (tag) {
            0 => .{ .save = .{ .source = try d.range(), .source_version = try d.small(), .expected = (try d.take(32))[0..32].* } },
            1 => .{ .restore = .{ .saved_step = try d.small(), .destination = try d.num() } },
            2 => blk: {
                const r = try d.range();
                const discard = try d.num();
                if (discard > 1) return error.InvalidStorageProgram;
                break :blk .{ .write = .{ .range = r, .discard = discard == 1, .content = try d.take(r.length) } };
            },
            3 => .{ .barrier = {} },
            4 => blk: {
                const source_identity = (try d.take(32))[0..32].*;
                const source_capacity = try d.num();
                const source_sector = try d.small();
                const source_kind = std.enums.fromInt(@FieldType(model.Target, "kind"), try d.num()) orelse return error.InvalidStorageProgram;
                break :blk .{ .copy = .{ .source = .{ .identity = source_identity, .capacity = source_capacity, .sector_size = source_sector, .kind = source_kind }, .range = try d.range(), .destination = try d.num(), .expected = (try d.take(32))[0..32].* } };
            },
            else => return error.UnsupportedStorageInstruction,
        };
        s.* = .{ .operation = op, .dependencies = deps };
    }
    if (d.at != d.bytes.len) return error.InvalidStorageProgram;
    const result: Program = .{ .evidence = evidence, .request_digest = request_digest, .target = .{ .identity = identity, .capacity = capacity, .sector_size = sector, .kind = kind }, .steps = steps, .guards = guards, .encoded = bytes, .digest = hash };
    try result.validate();
    return result;
}

/// Freeze the request binding into the same authenticated execution bytes.
pub fn bindRequest(a: std.mem.Allocator, p: Program, digest: model.Digest) !Program {
    var bound = p;
    bound.request_digest = digest;
    return decode(a, try encode(a, bound));
}
