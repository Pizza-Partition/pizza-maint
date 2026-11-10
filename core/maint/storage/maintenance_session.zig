//! Durable three-transaction maintenance coordinator. The caller supplies
//! offline-compiled programs and authenticated, exclusively acquired extents.
//! This module never weakens the physical device's mutation admission policy.
const std = @import("std");
const model = @import("model.zig");
const device = @import("device.zig");
const program = @import("program.zig");
const executor = @import("program_executor.zig");
const recovery = @import("recovery_store.zig");
const Raw = recovery.RawCapsule;
const Descriptor = recovery.CapsuleDescriptor;

pub const Phase = enum(u8) {
    prepared,
    bootstrapping,
    initialized,
    preparing_apply,
    applying,
    verified,
    undoing,
    restoring_bootstrap,
    accepted,
    cleaning,
    committing_cleanup,
    completed,
    rolled_back,
    failed_bootstrap,
    failed_cleanup,
    preparing,
    preparing_cleanup,
};
pub const Bundle = struct {
    session: model.Digest,
    /// Two independently writable recovery blocks in the ESP anchor.
    control: model.Range,
    bootstrap: program.Program,
    apply: program.Program,
    cleanup: program.Program,
    bootstrap_store: Descriptor,
    apply_store: Descriptor,
    cleanup_store: Descriptor,
    protected: []const model.Range = &.{},

    pub fn validate(self: Bundle, a: std.mem.Allocator, target: model.Target) !void {
        const block = self.bootstrap_store.block_size;
        try recovery.validateBlockSize(block);
        if (block < target.sector_size) return error.InvalidCapsuleGeometry;
        if (self.control.length != @as(u64, block) * 2) return error.InvalidSessionControl;
        try self.control.validate(target.capacity, block);
        for (self.protected) |r| try r.validate(target.capacity, target.sector_size);
        const stores = [_]Descriptor{ self.bootstrap_store, self.apply_store, self.cleanup_store };
        const plans = [_]program.Program{ self.bootstrap, self.apply, self.cleanup };
        for (stores, plans, 0..) |desc, p, index| {
            if (!std.mem.eql(u8, &self.session, &desc.session) or desc.block_size != block) return error.SessionIdentityMismatch;
            const decoded = try program.decode(a, p.encoded);
            if (!std.mem.eql(u8, &p.digest, &decoded.digest) or !target.same(decoded.target)) return error.TransactionTargetMismatch;
            for (decoded.steps) |step| if (step.operation == .copy) return error.SessionCloneNotSupported;
            var capacity: u64 = 0;
            if (desc.extents.len == 0 or desc.extents.len > 16384) return error.InvalidCapsuleGeometry;
            for (desc.extents, 0..) |r, ri| {
                try r.validate(target.capacity, block);
                if (r.overlaps(self.control)) return error.OverlappingSessionStorage;
                for (desc.extents[0..ri]) |other| if (r.overlaps(other)) return error.OverlappingSessionStorage;
                for (stores[0..index]) |prior| for (prior.extents) |other| {
                    if (r.overlaps(other)) return error.OverlappingSessionStorage;
                };
                capacity = try std.math.add(u64, capacity, r.length);
            }
            const limits = Raw.limitsFor(try executor.reservation(a, decoded, block, true), block);
            if (try Raw.required(limits, block) > capacity) return error.CapsuleTooSmall;
            for (decoded.steps, 0..) |_, i| if (decoded.targetRange(i)) |r| {
                if (r.overlaps(self.control)) return error.ProgramOverwritesRecovery;
                for (self.protected) |excluded| if (r.overlaps(excluded)) return error.ProgramOverwritesRecovery;
                // ESP stores survive all phases. Bootstrap may preserve bytes
                // at the future tail store before it exists; apply must never
                // overwrite its active store. Cleanup may reclaim it only
                // after durable acceptance.
                for (stores, 0..) |protected, si| {
                    if (index != 1 and si == 1) continue;
                    for (protected.extents) |excluded| if (r.overlaps(excluded)) return error.ProgramOverwritesRecovery;
                }
            };
        }
    }
    pub fn digest(self: Bundle) model.Digest {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("pizza-maintenance-session-v1");
        h.update(&self.session);
        h.update(&self.bootstrap.digest);
        h.update(&self.apply.digest);
        h.update(&self.cleanup.digest);
        hashRange(&h, self.control);
        var n: [8]u8 = undefined;
        std.mem.writeInt(u64, &n, self.protected.len, .little);
        h.update(&n);
        for (self.protected) |r| hashRange(&h, r);
        for ([_]Descriptor{ self.bootstrap_store, self.apply_store, self.cleanup_store }) |d| {
            var b: [16]u8 = undefined;
            std.mem.writeInt(u64, b[0..8], d.block_size, .little);
            std.mem.writeInt(u64, b[8..16], d.extents.len, .little);
            h.update(&b);
            for (d.extents) |r| hashRange(&h, r);
        }
        return h.finalResult();
    }
};
fn hashRange(h: *std.crypto.hash.sha2.Sha256, r: model.Range) void {
    var b: [16]u8 = undefined;
    std.mem.writeInt(u64, b[0..8], r.offset, .little);
    std.mem.writeInt(u64, b[8..16], r.length, .little);
    h.update(&b);
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    disk: device.Device,
    bundle: Bundle,
    phase: Phase,
    sequence: u64,
    active: usize,

    /// Only ESP-owned extents are initialized here. The tail capsule is not
    /// touched until the bootstrap transaction has freed and verified its area.
    pub fn prepare(a: std.mem.Allocator, io: std.Io, disk: device.Device, bundle: Bundle) !Session {
        try disk.authorizeMutation();
        try disk.validate(io);
        try bundle.validate(a, disk.target);
        var self: Session = .{ .allocator = a, .disk = disk, .bundle = bundle, .phase = .prepared, .sequence = 0, .active = 1 };
        const bytes = try a.alloc(u8, bundle.bootstrap_store.block_size);
        defer a.free(bytes);
        for (0..2) |i| {
            try disk.reader().readInto(io, bundle.control.offset + i * bytes.len, bytes);
            if (self.decode(bytes)) |_| return error.MaintenanceSessionAlreadyExists else |_| {}
        }
        // A torn first control write is restartable only while BOTH capsule
        // headers still contain the host's zero reservation. Never erase logs
        // merely because later control records have become corrupt.
        for ([_]Descriptor{ bundle.bootstrap_store, bundle.cleanup_store }) |desc| {
            try disk.reader().readInto(io, desc.extents[0].offset, bytes);
            if (!std.mem.allEqual(u8, bytes, 0)) return error.InvalidSessionHeaders;
        }
        try self.persist(io, .preparing);
        try self.persist(io, .preparing);
        try self.initialize(io);
        return self;
    }
    fn initialize(self: *Session, io: std.Io) !void {
        const a = self.allocator;
        const bundle = self.bundle;
        const zero = try a.alloc(u8, bundle.bootstrap_store.block_size);
        defer a.free(zero);
        @memset(zero, 0);
        for ([_]Descriptor{ bundle.bootstrap_store, bundle.cleanup_store }) |desc| {
            // Only initialization can enter this phase. Later failures must open
            // and recover the existing logs instead of calling initialize().
            try self.disk.write(io, .{ .offset = desc.extents[0].offset, .length = zero.len }, zero);
            // A header may span a fragmented extent map. Find its second block.
            var remaining: u64 = zero.len;
            for (desc.extents) |extent| {
                if (remaining < extent.length) {
                    try self.disk.write(io, .{ .offset = extent.offset + remaining, .length = zero.len }, zero);
                    break;
                }
                remaining -= extent.length;
            }
        }
        try self.disk.flush(io);
        _ = try Raw.format(a, io, self.disk, bundle.bootstrap_store, Raw.limitsFor(try executor.reservation(a, bundle.bootstrap, bundle.bootstrap_store.block_size, true), bundle.bootstrap_store.block_size));
        _ = try Raw.format(a, io, self.disk, bundle.cleanup_store, Raw.limitsFor(try executor.reservation(a, bundle.cleanup, bundle.cleanup_store.block_size, true), bundle.cleanup_store.block_size));
        try self.persist(io, .prepared);
        try self.persist(io, .prepared);
    }
    pub fn open(a: std.mem.Allocator, io: std.Io, disk: device.Device, bundle: Bundle) !Session {
        try disk.validate(io);
        try bundle.validate(a, disk.target);
        var self: Session = .{ .allocator = a, .disk = disk, .bundle = bundle, .phase = .prepared, .sequence = 0, .active = 1 };
        const bytes = try a.alloc(u8, bundle.bootstrap_store.block_size);
        defer a.free(bytes);
        for (0..2) |i| {
            try disk.reader().readInto(io, bundle.control.offset + i * bytes.len, bytes);
            const candidate = self.decode(bytes) catch continue;
            if (candidate.sequence == self.sequence and candidate.phase != self.phase) return error.ConflictingSessionHeaders;
            if (candidate.sequence > self.sequence) {
                self.sequence = candidate.sequence;
                self.phase = candidate.phase;
                self.active = i;
            }
        }
        if (self.sequence == 0) return error.InvalidSessionHeaders;
        return self;
    }
    fn decode(self: Session, b: []const u8) !struct { sequence: u64, phase: Phase } {
        if (!std.mem.eql(u8, b[0..8], "PZSES001") or !std.mem.eql(u8, b[16..48], &self.disk.target.identity) or !std.mem.eql(u8, b[48..80], &self.bundle.session) or !std.mem.eql(u8, b[80..112], &self.bundle.digest()) or !std.mem.eql(u8, b[b.len - 32 ..], &model.digest(b[0 .. b.len - 32])) or !std.mem.allEqual(u8, b[113 .. b.len - 32], 0)) return error.InvalidSessionHeader;
        const phase = std.enums.fromInt(Phase, b[112]) orelse return error.InvalidSessionHeader;
        const seq = std.mem.readInt(u64, b[8..16], .little);
        if (seq == 0) return error.InvalidSessionHeader;
        return .{ .sequence = seq, .phase = phase };
    }
    fn persist(self: *Session, io: std.Io, phase: Phase) !void {
        const block = self.bundle.bootstrap_store.block_size;
        const b = try self.allocator.alloc(u8, block);
        defer self.allocator.free(b);
        @memset(b, 0);
        @memcpy(b[0..8], "PZSES001");
        const seq = try std.math.add(u64, self.sequence, 1);
        std.mem.writeInt(u64, b[8..16], seq, .little);
        @memcpy(b[16..48], &self.disk.target.identity);
        @memcpy(b[48..80], &self.bundle.session);
        @memcpy(b[80..112], &self.bundle.digest());
        b[112] = @backingInt(phase);
        @memcpy(b[b.len - 32 ..], &model.digest(b[0 .. b.len - 32]));
        const next = 1 - self.active;
        const r: model.Range = .{ .offset = self.bundle.control.offset + next * block, .length = block };
        try self.disk.write(io, r, b);
        try self.disk.flush(io);
        try self.disk.reader().readInto(io, r.offset, b);
        const actual = try self.decode(b);
        if (actual.sequence != seq or actual.phase != phase) return error.SessionReadbackMismatch;
        self.phase = phase;
        self.sequence = seq;
        self.active = next;
    }
    pub fn bootstrap(self: *Session, io: std.Io, verifier: ?executor.Verifier, observer: ?executor.Observer) !void {
        if (self.phase != .prepared) return error.InvalidSessionTransition;
        var cap = try self.capsule(io, self.bundle.bootstrap_store);
        try self.persist(io, .bootstrapping);
        try executor.executeDeferred(self.allocator, io, self.disk, cap.store(), self.bundle.bootstrap, &.{}, verifier, observer);
        try self.persist(io, .initialized);
    }
    pub fn apply(self: *Session, io: std.Io, verifier: ?executor.Verifier, observer: ?executor.Observer) !void {
        if (self.phase != .initialized) return error.InvalidSessionTransition;
        // Mark the attempt first. A failure at any point is recovered, never
        // silently retried with the original user request.
        try self.persist(io, .preparing_apply);
        var cap = try Raw.format(self.allocator, io, self.disk, self.bundle.apply_store, Raw.limitsFor(try executor.reservation(self.allocator, self.bundle.apply, self.bundle.apply_store.block_size, true), self.bundle.apply_store.block_size));
        try self.persist(io, .applying);
        try executor.executeDeferred(self.allocator, io, self.disk, cap.store(), self.bundle.apply, &.{}, verifier, observer);
        try self.persist(io, .verified);
    }
    pub fn undo(self: *Session, io: std.Io) !void {
        if (self.phase != .verified and self.phase != .initialized) return error.InvalidSessionTransition;
        try self.persist(io, if (self.phase == .verified) .undoing else .restoring_bootstrap);
        try self.recover(io);
    }
    /// Acceptance closes Undo durably before any cleanup writes are permitted.
    pub fn accept(self: *Session, io: std.Io) !void {
        if (self.phase != .verified) return error.InvalidSessionTransition;
        var cap = try self.capsule(io, self.bundle.apply_store);
        if (try executor.recover(self.allocator, io, self.disk, cap.store(), null) != .verified) return error.TransactionNotAwaitingAcceptance;
        try self.persist(io, .accepted);
        try executor.accept(self.allocator, io, self.disk, cap.store());
    }
    pub fn cleanup(self: *Session, io: std.Io, verifier: ?executor.Verifier, observer: ?executor.Observer) !void {
        if (self.phase != .accepted and self.phase != .failed_cleanup) return error.InvalidSessionTransition;
        var main = try self.capsule(io, self.bundle.apply_store);
        try executor.accept(self.allocator, io, self.disk, main.store());
        if (self.phase == .failed_cleanup) {
            // The previous cleanup has been fully rolled back. Its log can now
            // be reset, after publishing an explicit accepted state for recovery.
            try self.persist(io, .preparing_cleanup);
            try self.initializeCleanup(io);
        }
        var cap = try self.capsule(io, self.bundle.cleanup_store);
        try self.persist(io, .cleaning);
        try executor.executeDeferred(self.allocator, io, self.disk, cap.store(), self.bundle.cleanup, &.{}, verifier, observer);
        try self.persist(io, .committing_cleanup);
        try executor.accept(self.allocator, io, self.disk, cap.store());
        try self.persist(io, .completed);
    }
    fn initializeCleanup(self: *Session, io: std.Io) !void {
        const desc = self.bundle.cleanup_store;
        const zero = try self.allocator.alloc(u8, desc.block_size);
        defer self.allocator.free(zero);
        @memset(zero, 0);
        for (0..2) |head| {
            var remaining: u64 = head * zero.len;
            for (desc.extents) |extent| {
                if (remaining < extent.length) {
                    try self.disk.write(io, .{ .offset = extent.offset + remaining, .length = zero.len }, zero);
                    break;
                }
                remaining -= extent.length;
            }
        }
        try self.disk.flush(io);
        _ = try Raw.format(self.allocator, io, self.disk, desc, Raw.limitsFor(try executor.reservation(self.allocator, self.bundle.cleanup, desc.block_size, true), desc.block_size));
        try self.persist(io, .accepted);
    }
    fn capsule(self: *Session, io: std.Io, desc: Descriptor) !Raw {
        return Raw.open(self.allocator, io, self.disk, desc);
    }
    /// Recovery never reruns bootstrap/apply/cleanup. Incomplete execution is
    /// rolled back; completed execution resumes only its durable finalization.
    pub fn recover(self: *Session, io: std.Io) !void {
        switch (self.phase) {
            .preparing => try self.initialize(io),
            .preparing_cleanup => try self.initializeCleanup(io),
            .bootstrapping => {
                var cap = try self.capsule(io, self.bundle.bootstrap_store);
                const result = try executor.recover(self.allocator, io, self.disk, cap.store(), null);
                try self.persist(io, if (result == .verified) .initialized else if (result == .unprepared or result == .rolled_back) .failed_bootstrap else return error.InvalidSessionRecovery);
            },
            .preparing_apply => {
                // Capsule initialization can only touch the newly freed tail.
                // The user transaction cannot start until applying is durable.
                try self.persist(io, .restoring_bootstrap);
                try self.recover(io);
            },
            .applying => {
                var cap = try self.capsule(io, self.bundle.apply_store);
                const result = try executor.recover(self.allocator, io, self.disk, cap.store(), null);
                if (result == .verified) return self.persist(io, .verified);
                if (result != .unprepared and result != .rolled_back) return error.InvalidSessionRecovery;
                try self.persist(io, .restoring_bootstrap);
                try self.recover(io);
            },
            .undoing => {
                var cap = try self.capsule(io, self.bundle.apply_store);
                const result = try executor.recover(self.allocator, io, self.disk, cap.store(), null);
                if (result == .verified) {
                    if (try executor.undo(self.allocator, io, self.disk, cap.store(), null) != .rolled_back) return error.InvalidSessionRecovery;
                } else if (result != .rolled_back) return error.InvalidSessionRecovery;
                try self.persist(io, .restoring_bootstrap);
                try self.recover(io);
            },
            .restoring_bootstrap => {
                var cap = try self.capsule(io, self.bundle.bootstrap_store);
                // apply has been undone (or never began), but its raw tail
                // store can overwrite original allocated bootstrap sources.
                // Restore the validated predecessor snapshots directly.
                if (try executor.undoPredecessor(self.allocator, io, self.disk, cap.store(), null) != .rolled_back) return error.InvalidSessionRecovery;
                try self.persist(io, .rolled_back);
            },
            .accepted => {
                var cap = try self.capsule(io, self.bundle.apply_store);
                try executor.accept(self.allocator, io, self.disk, cap.store());
            },
            .cleaning => {
                var cap = try self.capsule(io, self.bundle.cleanup_store);
                const result = try executor.recover(self.allocator, io, self.disk, cap.store(), null);
                if (result != .verified) {
                    if (result != .unprepared and result != .rolled_back) return error.InvalidSessionRecovery;
                    return self.persist(io, .failed_cleanup);
                }
                try self.persist(io, .committing_cleanup);
                try self.recover(io);
            },
            .committing_cleanup => {
                var cap = try self.capsule(io, self.bundle.cleanup_store);
                try executor.accept(self.allocator, io, self.disk, cap.store());
                try self.persist(io, .completed);
            },
            .prepared, .initialized, .verified, .completed, .rolled_back, .failed_bootstrap, .failed_cleanup => {},
        }
    }
};
