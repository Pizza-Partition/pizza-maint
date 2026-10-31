//! One operation's hard allocation budget and latched system-headroom evidence.
const std = @import("std");
pub const linux = @import("utils").memory;
pub const MI_B = 1024 * 1024;
/// Bounds for in-memory record encoding and captured read evidence.
pub const MAX_STAGING_BYTES: u64 = 4 * 1024 * MI_B;
pub const PlanningLimits = struct {
    encoded_bytes: u64 = 64 * MI_B,
    read_bytes: u64 = 128 * MI_B,
    pub fn validate(self: PlanningLimits) !void {
        if (self.encoded_bytes == 0 or self.encoded_bytes > MAX_STAGING_BYTES or self.read_bytes == 0 or self.read_bytes > MAX_STAGING_BYTES) return error.InvalidStorageLimits;
    }
};
pub const Probe = struct {
    context: *const anyopaque,
    sample_fn: *const fn (*const anyopaque, std.Io) anyerror!linux.Snapshot,
    pub fn sample(self: Probe, io: std.Io) !linux.Snapshot {
        return self.sample_fn(self.context, io);
    }
};
const SYSTEM_CONTEXT: u8 = 0;
pub const SYSTEM: Probe = .{ .context = &SYSTEM_CONTEXT, .sample_fn = systemSample };
fn systemSample(_: *const anyopaque, io: std.Io) !linux.Snapshot {
    return linux.probe(io, linux.SYSTEM);
}
pub const Policy = struct {
    minimum_reserve: u64 = 512 * MI_B,
    reserve_percent: u8 = 10,
    // libext2fs allocations and other non-cache work do not belong to Builder.
    work_reserve: u64 = 256 * MI_B,
    recovery_reserve: u64 = 64 * MI_B,
    cache_cap: ?u64 = null,
    pub fn reserve(self: Policy, total: u64) !u64 {
        if (self.reserve_percent > 100) return error.InvalidMemoryPolicy;
        return @max(self.minimum_reserve, total / 100 * self.reserve_percent + total % 100 * self.reserve_percent / 100);
    }
};
pub const Options = struct { probe: Probe = SYSTEM, policy: Policy = .{}, evidence: ?*Evidence = null };
pub const Budget = struct {
    total: u64,
    available: u64,
    reserve: u64,
    work_reserve: u64,
    recovery_reserve: u64,
    cache_bytes: u64,
    pub fn derive(snapshot: linux.Snapshot, policy: Policy) !Budget {
        if (snapshot.effective_total == 0 or snapshot.effective_available > snapshot.effective_total or snapshot.effective_total > snapshot.total or snapshot.effective_available > snapshot.available) return error.InvalidMemoryEvidence;
        const reserve = try policy.reserve(snapshot.effective_total);
        const extra = try std.math.add(u64, policy.work_reserve, policy.recovery_reserve);
        const retained = try std.math.add(u64, reserve, extra);
        const cache = @min(snapshot.effective_available -| retained, policy.cache_cap orelse std.math.maxInt(u64));
        if (cache < 4096) return error.InsufficientMemoryBudget;
        return .{ .total = snapshot.effective_total, .available = snapshot.effective_available, .reserve = reserve, .work_reserve = policy.work_reserve, .recovery_reserve = policy.recovery_reserve, .cache_bytes = cache };
    }
};
pub const Evidence = struct { checks: u64, minimum_available: u64, reserve: u64, peak_charged: u64, allocation_limit: u64, violated: bool };
pub const Controller = struct {
    io: std.Io,
    probe: Probe,
    budget: Budget,
    backing: std.mem.Allocator = std.heap.page_allocator,
    mutex: std.Io.Mutex = .init,
    charged: u64 = 0,
    peak: u64 = 0,
    checks: u64 = 0,
    minimum_available: u64 = std.math.maxInt(u64),
    violated: bool = false,
    failure: ?anyerror = null,
    io_bytes: u64 = 0,
    output: ?*Evidence = null,
    pub fn init(io: std.Io, options: Options) !Controller {
        const snapshot = try options.probe.sample(io);
        var result: Controller = .{ .io = io, .probe = options.probe, .budget = try Budget.derive(snapshot, options.policy), .minimum_available = snapshot.effective_available, .checks = 1, .output = options.evidence };
        result.publish();
        return result;
    }
    fn publish(self: *Controller) void {
        if (self.output) |out| out.* = .{ .checks = self.checks, .minimum_available = self.minimum_available, .reserve = self.budget.reserve, .peak_charged = self.peak, .allocation_limit = self.budget.cache_bytes, .violated = self.violated };
    }
    pub fn evidence(self: *Controller) Evidence {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .checks = self.checks, .minimum_available = self.minimum_available, .reserve = self.budget.reserve, .peak_charged = self.peak, .allocation_limit = self.budget.cache_bytes, .violated = self.violated };
    }
    fn fail(self: *Controller, err: anyerror) anyerror {
        if (self.failure == null or err == error.MemorySafetyReserveBreached) self.failure = err;
        return err;
    }
    fn observe(self: *Controller) !linux.Snapshot {
        defer self.publish();
        const snapshot = self.probe.sample(self.io) catch |err| return self.fail(err);
        if (snapshot.effective_available > snapshot.effective_total or snapshot.effective_total == 0) return self.fail(error.InvalidMemoryEvidence);
        self.checks += 1;
        self.minimum_available = @min(self.minimum_available, snapshot.effective_available);
        // This floor is fixed at admission. A later pressure event may never
        // lower it or erase evidence of a temporary breach.
        if (snapshot.effective_available < self.budget.reserve) {
            self.violated = true;
            return self.fail(error.MemorySafetyReserveBreached);
        }
        if (self.violated) return error.MemorySafetyReserveBreached;
        return snapshot;
    }
    fn room(self: *Controller, bytes: u64) !void {
        if (self.failure) |err| return err;
        const snapshot = try self.observe();
        const extra = self.budget.work_reserve + self.budget.recovery_reserve;
        if (bytes > self.budget.cache_bytes -| self.charged or snapshot.effective_available - self.budget.reserve < extra or bytes > snapshot.effective_available - self.budget.reserve - extra) return self.fail(error.MemoryBudgetExceeded);
    }
    pub fn check(self: *Controller) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Observe even after an earlier denial so a recovered value cannot
        // disguise a test's transient reserve violation.
        _ = try self.observe();
        if (self.failure) |err| return err;
    }
    pub fn planningLimits(self: *const Controller) PlanningLimits {
        // Original records, edited copies, frozen program bytes and arena growth
        // all coexist. Budget the whole working set, not just payload bytes.
        const payload = @min(MAX_STAGING_BYTES, self.budget.cache_bytes / 6) & ~@as(u64, 511);
        return .{ .encoded_bytes = payload, .read_bytes = @min(MAX_STAGING_BYTES, payload * 2) };
    }
    pub fn activity(self: *Controller, bytes: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failure) |err| return err;
        self.io_bytes +|= bytes;
        if (self.io_bytes >= 4 * MI_B) {
            self.io_bytes = 0;
            _ = try self.observe();
        }
    }
    pub fn allocator(self: *Controller) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &VTABLE };
    }
    fn charge(bytes: usize) ?u64 {
        const adjusted = std.math.add(u64, bytes, 4095) catch return null;
        return adjusted & ~@as(u64, 4095);
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Controller = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const bytes = charge(length) orelse {
            if (self.failure == null) self.failure = error.MemoryBudgetExceeded;
            return null;
        };
        self.room(bytes) catch return null;
        const ptr = self.backing.rawAlloc(length, alignment, ra) orelse {
            if (self.failure == null) self.failure = error.OutOfMemory;
            return null;
        };
        // Commit each newly obtained page now, rather than reserving an
        // unaccounted virtual allocation whose RSS appears much later.
        var page: usize = 0;
        while (page < length) : (page += 4096) {
            const byte: *volatile u8 = @ptrCast(ptr + page);
            byte.* = 0;
        }
        self.charged += bytes;
        self.peak = @max(self.peak, self.charged);
        _ = self.observe() catch {
            self.backing.rawFree(ptr[0..length], alignment, ra);
            self.charged -= bytes;
            return null;
        };
        return ptr;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Controller = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.backing.rawFree(bytes, alignment, ra);
        self.charged -= charge(bytes.len).?;
    }
    const VTABLE: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free };
};
