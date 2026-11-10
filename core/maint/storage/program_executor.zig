//! Serial physical execution and raw recovery; no filesystem imports.
const std = @import("std");
const model = @import("model.zig");
const device = @import("device.zig");
const programs = @import("program.zig");
const recovery = @import("recovery_store.zig");
pub const Result = enum { unprepared, rolled_back, committed, verified };
pub const Observer = struct {
    context: *anyopaque,
    event: *const fn (*anyopaque, usize, usize, u64) anyerror!void,
    cancelled: ?*const fn (*anyopaque) bool = null,
    progress: ?*const fn (*anyopaque, usize, u64, u64) anyerror!void = null,
};
pub const Verifier = struct {
    context: *const anyopaque,
    check: *const fn (*const anyopaque, std.Io, device.Reader) anyerror!bool,
};
const Slots = struct {
    snapshots: []u64,
    scratch: []u64,
    snapshot_bytes: u64,
    scratch_bytes: u64,
    state_bytes: u64,
    block: u32,
    fn init(a: std.mem.Allocator, p: programs.Program, block: u32, retained: bool) !Slots {
        try recovery.validateBlockSize(block);
        const snapshots = try a.alloc(u64, p.steps.len);
        const scratch = try a.alloc(u64, p.steps.len);
        var old_bytes: u64 = 0;
        var saved_bytes: u64 = 0;
        for (p.steps, 0..) |step, i| {
            snapshots[i] = old_bytes;
            scratch[i] = saved_bytes;
            if (p.targetRange(i)) |r| {
                const discard = !retained and discarded(step.operation);
                if (!discard) old_bytes = try addAligned(old_bytes, r.length, block);
            }
            if (step.operation == .save) saved_bytes = try addAligned(saved_bytes, step.operation.save.source.length, block);
        }
        return .{ .snapshots = snapshots, .scratch = scratch, .snapshot_bytes = old_bytes, .scratch_bytes = saved_bytes, .state_bytes = @as(u64, p.steps.len) * 3 * block, .block = block };
    }
    fn addAligned(n: u64, length: u64, block: u32) !u64 {
        const aligned = try std.math.add(u64, length, block - 1);
        return std.math.add(u64, n, aligned / block * block);
    }
};
fn streamHash(io: std.Io, store: recovery.Store, record: recovery.Record, offset: u64, length: u64, observer: ?Observer) !model.Digest {
    var b: [65536]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var done: u64 = 0;
    while (done < length) {
        try checkCancelled(observer);
        const part = b[0..@intCast(@min(b.len, length - done))];
        if (try store.readAt(io, record, offset + done, part) != part.len) return error.ShortRecoveryRead;
        hash.update(part);
        done += part.len;
    }
    return hash.finalResult();
}
fn put(comptime T: type, b: []u8, at: usize, n: T) void {
    std.mem.writeInt(T, b[at..][0..@sizeOf(T)], n, .little);
}
fn get(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}
fn stateOffset(slots: Slots, step: usize, phase: u64) u64 {
    return (@as(u64, step) * 3 + phase) * slots.block;
}
fn saveState(io: std.Io, store: recovery.Store, p: programs.Program, slots: Slots, step: usize, phase: u64, payload_hash: model.Digest, buffer: []u8) !void {
    @memset(buffer, 0);
    @memcpy(buffer[0..8], "PZSTATE6");
    @memcpy(buffer[8..40], &p.digest);
    put(u64, buffer, 40, step);
    put(u64, buffer, 48, phase);
    @memcpy(buffer[56..88], &payload_hash);
    @memcpy(buffer[buffer.len - 32 ..], &model.digest(buffer[0 .. buffer.len - 32]));
    try store.writeAt(io, .state, stateOffset(slots, step, phase), buffer);
    try store.syncFile(io, .state);
}
const State = union(enum) { empty, invalid, valid: model.Digest };
fn loadState(io: std.Io, store: recovery.Store, p: programs.Program, slots: Slots, step: usize, phase: u64, buffer: []u8) !State {
    if (try store.readAt(io, .state, stateOffset(slots, step, phase), buffer) != buffer.len) return error.ShortRecoveryRead;
    if (std.mem.allEqual(u8, buffer, 0)) return .empty;
    if (!std.mem.eql(u8, buffer[0..8], "PZSTATE6") or !std.mem.eql(u8, buffer[8..40], &p.digest) or get(u64, buffer, 40) != step or get(u64, buffer, 48) != phase or !std.mem.eql(u8, buffer[buffer.len - 32 ..], &model.digest(buffer[0 .. buffer.len - 32])) or !std.mem.allEqual(u8, buffer[88 .. buffer.len - 32], 0)) return .invalid;
    return .{ .valid = buffer[56..88].* };
}
fn marker(io: std.Io, store: recovery.Store, record: recovery.Record, digest: model.Digest, block: []u8) !void {
    @memset(block, 0);
    @memcpy(block[0..8], "PZMARK06");
    put(u64, block, 8, @backingInt(record));
    @memcpy(block[16..48], &digest);
    @memcpy(block[block.len - 32 ..], &model.digest(block[0 .. block.len - 32]));
    try store.create(io, record, true);
    try store.write(io, record, block);
    try store.syncFile(io, record);
    try store.publish(io, record);
    try store.syncDirectory(io);
}
fn checkMarker(io: std.Io, store: recovery.Store, record: recovery.Record, digest: model.Digest, block: []u8) !bool {
    if (!try store.exists(io, record)) return false;
    if (try store.size(io, record) != block.len or try store.readAt(io, record, 0, block) != block.len) return error.InvalidProgramMarker;
    if (!std.mem.eql(u8, block[0..8], "PZMARK06") or get(u64, block, 8) != @backingInt(record) or !std.mem.eql(u8, block[16..48], &digest) or !std.mem.allEqual(u8, block[48 .. block.len - 32], 0) or !std.mem.eql(u8, block[block.len - 32 ..], &model.digest(block[0 .. block.len - 32]))) return error.InvalidProgramMarker;
    return true;
}
fn discarded(op: programs.Operation) bool {
    return op == .copy or (op == .write and op.write.discard);
}
fn sourceReader(readers: []const device.Reader, target: model.Target) !device.Reader {
    for (readers) |reader| if (reader.target.same(target)) return reader;
    return error.MissingCloneSource;
}
fn historical(io: std.Io, disk: device.Device, store: recovery.Store, p: programs.Program, slots: Slots, current: usize, version: u32, range: model.Range, bytes: []u8) !void {
    try disk.reader().readInto(io, range.offset, bytes);
    var i = current;
    while (i > version) {
        i -= 1;
        const target = p.targetRange(i) orelse continue;
        if (!target.overlaps(range)) continue;
        if (discarded(p.steps[i].operation)) return error.DiscardedDataVersion;
        const start = @max(target.offset, range.offset);
        const end = @min(try target.end(), try range.end());
        const part = bytes[@intCast(start - range.offset)..][0..@intCast(end - start)];
        if (try store.readAt(io, .snapshots, slots.snapshots[i] + start - target.offset, part) != part.len) return error.ShortRecoveryRead;
    }
}
fn snapshot(io: std.Io, disk: device.Device, store: recovery.Store, slot: u64, range: model.Range, observer: ?Observer) !model.Digest {
    var b: [65536]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var done: u64 = 0;
    while (done < range.length) {
        try checkCancelled(observer);
        const part = b[0..@intCast(@min(b.len, range.length - done))];
        try disk.reader().readInto(io, range.offset + done, part);
        hash.update(part);
        try store.writeAt(io, .snapshots, slot + done, part);
        done += part.len;
    }
    try store.syncFile(io, .snapshots);
    const digest = hash.finalResult();
    if (!std.mem.eql(u8, &digest, &try streamHash(io, store, .snapshots, slot, range.length, observer))) return error.RecoveryReadbackMismatch;
    return digest;
}
fn restoreBytes(io: std.Io, disk: device.Device, store: recovery.Store, record: recovery.Record, offset: u64, range: model.Range, observer: ?Observer, step: usize) !void {
    var b: [65536]u8 = undefined;
    var done: u64 = 0;
    while (done < range.length) {
        const part = b[0..@intCast(@min(b.len, range.length - done))];
        if (try store.readAt(io, record, offset + done, part) != part.len) return error.ShortRecoveryRead;
        try disk.write(io, .{ .offset = range.offset + done, .length = part.len }, part);
        done += part.len;
        try report(observer, step, done, range.length);
    }
    try disk.flush(io);
}

/// Leaves an interrupted transaction recoverable. Call recover after any error;
/// observers may fail or request cancellation without bypassing durable intent.
pub fn execute(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, p: programs.Program, verifier: ?Verifier, observer: ?Observer) !void {
    return executeWithSources(a, io, disk, store, p, &.{}, verifier, observer);
}
pub fn executeWithSources(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, incoming: programs.Program, sources: []const device.Reader, verifier: ?Verifier, observer: ?Observer) !void {
    return executeOptions(a, io, disk, store, incoming, sources, verifier, observer, false);
}

/// Retains every overwritten byte, including formatting and clone destinations.
/// A verified transaction remains reversible until accept() is made durable.
pub fn executeDeferred(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, incoming: programs.Program, sources: []const device.Reader, verifier: ?Verifier, observer: ?Observer) !void {
    return executeOptions(a, io, disk, store, incoming, sources, verifier, observer, true);
}
fn executeOptions(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, incoming: programs.Program, sources: []const device.Reader, verifier: ?Verifier, observer: ?Observer, retained: bool) !void {
    try disk.authorizeMutation();
    try disk.validate(io);
    try checkCancelled(observer);
    const p = try programs.decode(a, incoming.encoded);
    if (!std.mem.eql(u8, &p.digest, &incoming.digest)) return error.StorageProgramChecksum;
    try p.validate();
    if (!p.target.same(disk.target)) return error.TransactionTargetMismatch;
    const granule = @max(disk.target.sector_size, disk.write_granule);
    for (p.steps, 0..) |_, index| if (p.targetRange(index)) |range| {
        if (range.offset % granule != 0 or range.length % granule != 0) return error.UnalignedPhysicalWrite;
    };
    if (!std.mem.eql(u8, &p.digest, &model.digest(p.encoded[0 .. p.encoded.len - 32]))) return error.StorageProgramChecksum;
    if (store.vtable.admit_program) |admit| try admit(store.context, p, retained);
    for (std.enums.values(recovery.Record)) |r| if (try store.exists(io, r)) return error.RecoveryDirectoryInUse;
    for (p.guards) |g| if (!std.mem.eql(u8, &try readerHash(io, disk.reader(), g.range, observer), &g.expected)) return error.PlanningReadChanged;
    for (p.steps) |step| if (step.operation == .copy) {
        const v = step.operation.copy;
        const source = try sourceReader(sources, v.source);
        if (!std.mem.eql(u8, &v.expected, &try readerHash(io, source, v.range, observer))) return error.CloneSourceChanged;
    };
    const slots = try Slots.init(a, p, try store.blockSize(io), retained);
    const block = try a.alloc(u8, slots.block);
    defer a.free(block);
    for ([_]recovery.Record{ .snapshots, .scratch, .state }) |r| {
        try store.create(io, r, false);
        const size = switch (r) {
            .snapshots => slots.snapshot_bytes,
            .scratch => slots.scratch_bytes,
            .state => slots.state_bytes,
            else => unreachable,
        };
        try store.reserve(io, r, size);
    }
    try store.create(io, .program, true);
    try store.write(io, .program, p.encoded);
    try store.syncFile(io, .program);
    try store.publish(io, .program);
    try store.syncDirectory(io);
    if (retained) try marker(io, store, .retained, p.digest, block);
    try marker(io, store, .ready, p.digest, block);
    for (p.steps, 0..) |step, i| {
        if (observer) |o| if (o.cancelled) |cancelled| if (cancelled(o.context)) return error.OperationCancelled;
        var previous: model.Digest = @splat(0);
        if (p.targetRange(i)) |range| {
            if (retained or !discarded(step.operation)) previous = try snapshot(io, disk, store, slots.snapshots[i], range, observer);
        }
        try checkCancelled(observer);
        try saveState(io, store, p, slots, i, 0, previous, block);
        var output: model.Digest = @splat(0);
        switch (step.operation) {
            .save => |s| {
                var b: [65536]u8 = undefined;
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                var done: u64 = 0;
                while (done < s.source.length) {
                    const part = b[0..@intCast(@min(b.len, s.source.length - done))];
                    try historical(io, disk, store, p, slots, i, s.source_version, .{ .offset = s.source.offset + done, .length = part.len }, part);
                    hash.update(part);
                    try store.writeAt(io, .scratch, slots.scratch[i] + done, part);
                    done += part.len;
                    try report(observer, i, done, s.source.length);
                }
                output = hash.finalResult();
                if (!std.mem.eql(u8, &output, &s.expected)) return error.MoveSourceChanged;
                try store.syncFile(io, .scratch);
                if (!std.mem.eql(u8, &output, &try streamHash(io, store, .scratch, slots.scratch[i], s.source.length, observer))) return error.RecoveryReadbackMismatch;
            },
            .restore => |r| {
                output = p.steps[r.saved_step].operation.save.expected;
                const range = p.targetRange(i).?;
                if (!std.mem.eql(u8, &output, &try streamHash(io, store, .scratch, slots.scratch[r.saved_step], range.length, observer))) return error.ScratchChecksumMismatch;
                try restoreBytes(io, disk, store, .scratch, slots.scratch[r.saved_step], range, observer, i);
            },
            .write => |w| {
                var done: usize = 0;
                while (done < w.content.len) {
                    const part = w.content[done..][0..@min(65536, w.content.len - done)];
                    try disk.write(io, .{ .offset = w.range.offset + done, .length = part.len }, part);
                    done += part.len;
                    try report(observer, i, done, w.range.length);
                }
                try disk.flush(io);
                output = model.digest(w.content);
            },
            .copy => |v| {
                const source = try sourceReader(sources, v.source);
                var b: [65536]u8 = undefined;
                var done: u64 = 0;
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                while (done < v.range.length) {
                    const part = b[0..@intCast(@min(b.len, v.range.length - done))];
                    try source.readInto(io, v.range.offset + done, part);
                    hash.update(part);
                    try disk.write(io, .{ .offset = v.destination + done, .length = part.len }, part);
                    done += part.len;
                    try report(observer, i, done, v.range.length);
                }
                output = hash.finalResult();
                if (!std.mem.eql(u8, &output, &v.expected)) return error.CloneSourceChanged;
                try disk.flush(io);
            },
            .barrier => try disk.flush(io),
        }
        if (p.targetRange(i)) |range| if (!std.mem.eql(u8, &output, &try readerHash(io, disk.reader(), range, observer))) return error.ProgramWriteVerificationFailed;
        try saveState(io, store, p, slots, i, 1, output, block);
        if (observer) |o| try o.event(o.context, i + 1, p.steps.len, if (p.targetRange(i)) |r| r.length else 0);
    }
    if (verifier) |v| if (!try v.check(v.context, io, disk.reader())) return error.ProgramVerificationFailed;
    try disk.flush(io);
    try checkCancelled(observer);
    if (retained)
        try marker(io, store, .verified, try finalDigest(a, io, disk.reader(), p), block)
    else
        try marker(io, store, .commit, p.digest, block);
}

pub fn recover(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, observer: ?Observer) !Result {
    return recoverOptions(a, io, disk, store, observer, false);
}
fn recoverOptions(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, observer: ?Observer, replaced_by_dependent: bool) !Result {
    try disk.authorizeMutation();
    try disk.validate(io);
    if (!try store.exists(io, .ready)) {
        if (try store.exists(io, .commit) or try store.exists(io, .restored) or try store.exists(io, .verified) or try store.exists(io, .undo)) return error.InvalidRecoverySequence;
        return .unprepared;
    }
    const bytes = try store.read(io, .program, a, programs.MAX_ENCODED_BYTES);
    const p = try programs.decode(a, bytes);
    if (!p.target.same(disk.target)) return error.TransactionTargetMismatch;
    const granule = @max(disk.target.sector_size, disk.write_granule);
    for (p.steps, 0..) |_, index| if (p.targetRange(index)) |range| {
        if (range.offset % granule != 0 or range.length % granule != 0) return error.UnalignedPhysicalWrite;
    };
    const retained = try checkMarker(io, store, .retained, p.digest, try a.alloc(u8, try store.blockSize(io)));
    if (store.vtable.admit_program) |admit| try admit(store.context, p, retained);
    const slots = try Slots.init(a, p, try store.blockSize(io), retained);
    const block = try a.alloc(u8, slots.block);
    if (!try checkMarker(io, store, .ready, p.digest, block)) return error.InvalidProgramMarker;
    if (try store.size(io, .snapshots) != slots.snapshot_bytes or try store.size(io, .scratch) != slots.scratch_bytes or try store.size(io, .state) != slots.state_bytes) return error.InvalidRecoveryLength;
    const committed = try checkMarker(io, store, .commit, p.digest, block);
    const restored = try checkMarker(io, store, .restored, p.digest, block);
    const undoing = try checkMarker(io, store, .undo, p.digest, block);
    const verified = try store.exists(io, .verified);
    if ((committed and (restored or undoing)) or ((verified or undoing) and !retained)) return error.InvalidRecoverySequence;
    var started: usize = 0;
    var unfinished = false;
    var stopped = false;
    for (p.steps, 0..) |step, i| {
        const intent = try loadState(io, store, p, slots, i, 0, block);
        const done = try loadState(io, store, p, slots, i, 1, block);
        const undone = try loadState(io, store, p, slots, i, 2, block);
        if (intent != .valid) {
            if (done != .empty or undone != .empty) return error.InvalidProgramProgress;
            stopped = true;
            continue;
        }
        if (stopped or unfinished) return error.InvalidProgramProgress;
        started = i + 1;
        unfinished = done != .valid;
        if (done == .valid) {
            const expected: model.Digest = switch (step.operation) {
                .save => |s| s.expected,
                .restore => |r| p.steps[r.saved_step].operation.save.expected,
                .write => |w| model.digest(w.content),
                .copy => |v| v.expected,
                .barrier => @splat(0),
            };
            if (!std.mem.eql(u8, &done.valid, &expected)) return error.InvalidProgramProgress;
        }
        if (p.targetRange(i)) |range| {
            if (retained or !discarded(step.operation)) {
                if (!std.mem.eql(u8, &intent.valid, &try streamHash(io, store, .snapshots, slots.snapshots[i], range.length, null))) return error.RecoveryReadbackMismatch;
            }
        }
    }
    if (committed) {
        if (started != p.steps.len or unfinished) return error.InvalidRecoverySequence;
        try store.syncDirectory(io);
        return .committed;
    }
    if (restored) {
        try store.syncDirectory(io);
        return .rolled_back;
    }
    if (verified and !undoing) {
        if (started != p.steps.len or unfinished) return error.InvalidRecoverySequence;
        if (replaced_by_dependent) {
            // A durable dependent transaction may have reused part of this
            // completed footprint. Only rollback may ignore its current bytes;
            // ready/progress and EVERY before-image were still checked above.
            if (try store.readAt(io, .verified, 0, block) != block.len) return error.ShortRecoveryRead;
            const recorded = block[16..48].*;
            if (!try checkMarker(io, store, .verified, recorded, block)) return error.InvalidProgramMarker;
        } else if (!try checkMarker(io, store, .verified, try finalDigest(a, io, disk.reader(), p), block)) return error.InvalidProgramMarker;
        return .verified;
    }
    var i = started;
    while (i > 0) {
        i -= 1;
        const undone = try loadState(io, store, p, slots, i, 2, block);
        if (undone == .valid) {
            if (!std.mem.eql(u8, &undone.valid, &p.digest)) return error.InvalidProgramProgress;
            continue;
        }
        const step = p.steps[i];
        if (p.targetRange(i)) |range| {
            if (retained or !discarded(step.operation)) {
                const before = try loadState(io, store, p, slots, i, 0, block);
                try restoreBytes(io, disk, store, .snapshots, slots.snapshots[i], range, null, i);
                if (!std.mem.eql(u8, &before.valid, &try (disk.reader()).digest(io, range))) return error.ProgramWriteVerificationFailed;
            }
        }
        try saveState(io, store, p, slots, i, 2, p.digest, block);
        if (observer) |o| try o.event(o.context, started - i, started, if (p.targetRange(i)) |r| r.length else 0);
    }
    try disk.flush(io);
    try marker(io, store, .restored, p.digest, block);
    return .rolled_back;
}

fn checkCancelled(observer: ?Observer) !void {
    if (observer) |o| if (o.cancelled) |cancelled| if (cancelled(o.context)) return error.OperationCancelled;
}
fn readerHash(io: std.Io, reader: device.Reader, range: model.Range, observer: ?Observer) !model.Digest {
    var buffer: [65536]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var done: u64 = 0;
    while (done < range.length) {
        try checkCancelled(observer);
        const part = buffer[0..@intCast(@min(buffer.len, range.length - done))];
        try reader.readInto(io, range.offset + done, part);
        hash.update(part);
        done += part.len;
    }
    return hash.finalResult();
}
fn report(observer: ?Observer, step: usize, done: u64, total: u64) !void {
    if (observer) |o| {
        if (o.cancelled) |cancelled| if (cancelled(o.context)) return error.OperationCancelled;
        if (o.progress) |progress| try progress(o.context, step, done, total);
    }
}

/// Fingerprint the final write footprint, merging overlapping historical writes.
/// Unrelated bytes outside this footprint do not make acceptance expensive.
fn finalDigest(a: std.mem.Allocator, io: std.Io, reader: device.Reader, p: programs.Program) !model.Digest {
    var ranges: std.ArrayList(model.Range) = .empty;
    defer ranges.deinit(a);
    for (p.steps, 0..) |_, i| if (p.targetRange(i)) |r| try ranges.append(a, r);
    std.mem.sort(model.Range, ranges.items, {}, struct {
        fn less(_: void, x: model.Range, y: model.Range) bool {
            return x.offset < y.offset;
        }
    }.less);
    var count: usize = 0;
    for (ranges.items) |r| {
        if (count != 0 and r.offset <= try ranges.items[count - 1].end()) {
            const prev = &ranges.items[count - 1];
            prev.length = @max(try prev.end(), try r.end()) - prev.offset;
        } else {
            ranges.items[count] = r;
            count += 1;
        }
    }
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-verified-footprint-v1");
    hash.update(&p.digest);
    for (ranges.items[0..count]) |r| {
        var encoded: [16]u8 = undefined;
        put(u64, &encoded, 0, r.offset);
        put(u64, &encoded, 8, r.length);
        hash.update(&encoded);
        hash.update(&try reader.digest(io, r));
    }
    return hash.finalResult();
}

/// Returns exact persistent record reservations for preflight capacity checks.
pub const Reservation = struct { snapshots: u64, scratch: u64, state: u64, program: u64, markers: u64, total: u64 };
pub fn reservation(a: std.mem.Allocator, p: programs.Program, block: u32, retained: bool) !Reservation {
    const slots = try Slots.init(a, p, block, retained);
    defer a.free(slots.snapshots);
    defer a.free(slots.scratch);
    const markers = @as(u64, if (retained) 6 else 3) * block;
    var total = try std.math.add(u64, slots.snapshot_bytes, slots.scratch_bytes);
    total = try std.math.add(u64, total, slots.state_bytes);
    total = try std.math.add(u64, total, p.encoded.len);
    total = try std.math.add(u64, total, markers);
    return .{ .snapshots = slots.snapshot_bytes, .scratch = slots.scratch_bytes, .state = slots.state_bytes, .program = p.encoded.len, .markers = markers, .total = total };
}

pub fn accept(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store) !void {
    if (!try store.exists(io, .verified) or try store.exists(io, .undo) or try store.exists(io, .restored)) return error.TransactionNotAwaitingAcceptance;
    const result = try recover(a, io, disk, store, null);
    if (result == .committed) return;
    if (result != .verified) return error.TransactionNotAwaitingAcceptance;
    const p = try programs.decode(a, try store.read(io, .program, a, programs.MAX_ENCODED_BYTES));
    try marker(io, store, .commit, p.digest, try a.alloc(u8, try store.blockSize(io)));
}

pub fn undo(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, observer: ?Observer) !Result {
    return undoOptions(a, io, disk, store, observer, false);
}
/// Coordinator-only rollback of a retained predecessor after a dependent
/// transaction has been undone. The current footprint may include its former
/// work store. Never grants acceptance or skips before-image validation.
pub fn undoPredecessor(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, observer: ?Observer) !Result {
    if (try store.exists(io, .restored)) return recover(a, io, disk, store, observer);
    return undoOptions(a, io, disk, store, observer, true);
}
fn undoOptions(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, observer: ?Observer, replaced_by_dependent: bool) !Result {
    if (try store.exists(io, .commit)) return error.TransactionAlreadyAccepted;
    if (!try store.exists(io, .verified)) return error.TransactionNotAwaitingAcceptance;
    if (!try store.exists(io, .undo)) {
        if (try recoverOptions(a, io, disk, store, null, replaced_by_dependent) != .verified) return error.TransactionNotAwaitingAcceptance;
        const p = try programs.decode(a, try store.read(io, .program, a, programs.MAX_ENCODED_BYTES));
        try marker(io, store, .undo, p.digest, try a.alloc(u8, try store.blockSize(io)));
    }
    return recover(a, io, disk, store, observer);
}
