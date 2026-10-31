//! Test fault injection around the production planner, executor and raw recovery.
//! Faults observe durable protocol boundaries; no alternative storage algorithm.
const std = @import("std");
const model = @import("../model.zig");
const device = @import("../device.zig");
const programs = @import("../program.zig");
const execution = @import("../program_executor.zig");
const recovery = @import("../recovery_store.zig");
const filesystems = @import("../filesystem/root.zig");
const service = @import("../service.zig");
const memory = @import("../memory.zig");
pub const Action = struct { kind: model.Kind, target_bytes: u64 = 0, filesystem: ?model.Filesystem = null };
pub const Cut = enum { program, ready, written, step, validated, committed };
pub const ExecutionOptions = struct { recovery_directory: ?std.Io.Dir = null, fault: ?Cut = null, memory_options: memory.Options = .{} };
pub const Result = struct { changed: bool, program_digest: model.Digest };

pub fn prepare(registry: filesystems.Registry, a: std.mem.Allocator, io: std.Io, reader: device.Reader, action: Action) !service.Plan {
    if (action.kind == .query or action.kind == .check) return error.ReadOnlyOperationHasNoMutationPlan;
    const selected = if (action.filesystem) |format| try registry.get(format) else try registry.detect(io, reader);
    return service.filesystem(a, io, reader, .{ .offset = 0, .length = reader.target.capacity }, selected, .{ .operation = action.kind, .bytes = action.target_bytes });
}
pub fn execute(_: std.mem.Allocator, io: std.Io, disk: device.Device, action: Action, options: ExecutionOptions) !Result {
    var budget = try memory.Controller.init(io, options.memory_options);
    const guarded = disk.withMemory(&budget);
    try writable(io, guarded, options);
    var arena: std.heap.ArenaAllocator = .init(budget.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const plan = prepare(filesystems.BUILTIN, a, io, guarded.reader(), action) catch |err| return budget.failure orelse err;
    const result = submit(a, io, guarded, options.recovery_directory.?, plan, &.{}, options.fault) catch |err| return budget.failure orelse err;
    try budget.check();
    return result;
}
pub fn create(a: std.mem.Allocator, io: std.Io, disk: device.Device, format: model.Filesystem, options: ExecutionOptions) !Result {
    return execute(a, io, disk, .{ .kind = .create, .filesystem = format }, options);
}
pub fn repair(a: std.mem.Allocator, io: std.Io, disk: device.Device, options: ExecutionOptions) !Result {
    return execute(a, io, disk, .{ .kind = .repair }, options);
}
pub fn grow(a: std.mem.Allocator, io: std.Io, disk: device.Device, bytes: u64, options: ExecutionOptions) !Result {
    return execute(a, io, disk, .{ .kind = .grow, .target_bytes = bytes }, options);
}
pub fn shrink(a: std.mem.Allocator, io: std.Io, disk: device.Device, bytes: u64, options: ExecutionOptions) !Result {
    return execute(a, io, disk, .{ .kind = .shrink, .target_bytes = bytes }, options);
}
pub fn copy(_: std.mem.Allocator, io: std.Io, source: device.Reader, destination: device.Device, options: ExecutionOptions) !Result {
    var budget = try memory.Controller.init(io, options.memory_options);
    const guarded = destination.withMemory(&budget);
    try writable(io, guarded, options);
    var arena: std.heap.ArenaAllocator = .init(budget.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const source_reader = source.withMemory(&budget);
    const plan = service.copy(a, io, source_reader, guarded.reader(), .{ .offset = 0, .length = destination.target.capacity }) catch |err| return budget.failure orelse err;
    const result = submit(a, io, guarded, options.recovery_directory.?, plan, &.{source_reader}, options.fault) catch |err| return budget.failure orelse err;
    try budget.check();
    return result;
}
pub fn submit(a: std.mem.Allocator, io: std.Io, disk: device.Device, directory: std.Io.Dir, plan: service.Plan, sources: []const device.Reader, fault: ?Cut) !Result {
    var files: recovery.Files = .{ .directory = directory };
    defer files.deinit(io);
    const Context = struct {
        a: std.mem.Allocator,
        plan: service.Plan,
        fn check(raw: *const anyopaque, inner_io: std.Io, reader: device.Reader) !bool {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return self.plan.verify(self.a, inner_io, reader);
        }
    };
    const context: Context = .{ .a = a, .plan = plan };
    try runProgram(a, io, disk, files.store(), plan.program, sources, .{ .context = &context, .check = Context.check }, fault);
    var changed = false;
    for (plan.program.steps, 0..) |_, index| if (plan.program.targetRange(index) != null) {
        changed = true;
        break;
    };
    return .{ .changed = changed, .program_digest = plan.program.digest };
}
pub fn recover(io: std.Io, disk: device.Device, directory: std.Io.Dir, options: memory.Options, stop_after_write: ?usize) !execution.Result {
    var budget = try memory.Controller.init(io, options);
    var arena: std.heap.ArenaAllocator = .init(budget.allocator());
    defer arena.deinit();
    var files: recovery.Files = .{ .directory = directory };
    defer files.deinit(io);
    const result = recoverStore(arena.allocator(), io, disk.withMemory(&budget), files.store(), stop_after_write) catch |err| return budget.failure orelse err;
    try budget.check();
    return result;
}
fn writable(io: std.Io, disk: device.Device, options: ExecutionOptions) !void {
    if (options.recovery_directory == null) return error.MissingRecoveryDirectory;
    try disk.authorizeMutation();
    try disk.validate(io);
}

pub fn runProgram(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, program: programs.Program, sources: []const device.Reader, verifier: ?execution.Verifier, cut: ?Cut) !void {
    var faults: Faults = .{ .inner = store, .program = program, .cut = cut, .verifier = verifier };
    try execution.executeWithSources(a, io, disk, faults.store(), program, sources, .{ .context = &faults, .check = Faults.verify }, faults.observer());
}
pub fn recoverStore(a: std.mem.Allocator, io: std.Io, disk: device.Device, store: recovery.Store, stop_after_write: ?usize) !execution.Result {
    var faults: Faults = .{ .inner = store, .restore_stop = stop_after_write };
    return execution.recover(a, io, disk, faults.store(), faults.observer());
}
const Faults = struct {
    inner: recovery.Store,
    program: ?programs.Program = null,
    cut: ?Cut = null,
    verifier: ?execution.Verifier = null,
    restore_stop: ?usize = null,
    writes: usize = 0,
    published: ?recovery.Record = null,
    fn cast(raw: *anyopaque) *@This() {
        return @ptrCast(@alignCast(raw));
    }
    fn observer(self: *@This()) execution.Observer {
        return .{ .context = self, .event = event, .progress = progress };
    }
    fn verify(raw: *const anyopaque, io: std.Io, reader: device.Reader) !bool {
        const self: *const @This() = @ptrCast(@alignCast(raw));
        if (self.verifier) |v| if (!try v.check(v.context, io, reader)) return false;
        if (self.cut == .validated) return error.InjectedExecutionInterruption;
        return true;
    }
    fn event(raw: *anyopaque, _: usize, _: usize, bytes: u64) !void {
        const self = cast(raw);
        if (bytes == 0) return;
        if (self.restore_stop) |stop| {
            defer self.writes += 1;
            if (self.writes == stop) return error.InjectedRestoreInterruption;
        }
        if (self.cut == .step) return error.InjectedExecutionInterruption;
    }
    fn progress(raw: *anyopaque, step: usize, bytes: u64, _: u64) !void {
        const self = cast(raw);
        if (self.cut == .written and bytes > 0) if (self.program) |p| if (p.targetRange(step) != null) return error.InjectedExecutionInterruption;
    }
    fn store(self: *@This()) recovery.Store {
        return .{ .context = self, .vtable = &VTABLE };
    }
    fn reserve(raw: *anyopaque, io: std.Io, r: recovery.Record, n: u64) !void {
        return cast(raw).inner.reserve(io, r, n);
    }
    fn blockSize(raw: *anyopaque, io: std.Io) !u32 {
        return cast(raw).inner.blockSize(io);
    }
    fn exists(raw: *anyopaque, io: std.Io, r: recovery.Record) !bool {
        return cast(raw).inner.exists(io, r);
    }
    fn size(raw: *anyopaque, io: std.Io, r: recovery.Record) !u64 {
        return cast(raw).inner.size(io, r);
    }
    fn read(raw: *anyopaque, io: std.Io, r: recovery.Record, a: std.mem.Allocator, n: usize) ![]u8 {
        return cast(raw).inner.read(io, r, a, n);
    }
    fn readAt(raw: *anyopaque, io: std.Io, r: recovery.Record, offset: u64, bytes: []u8) !usize {
        return cast(raw).inner.readAt(io, r, offset, bytes);
    }
    fn createFile(raw: *anyopaque, io: std.Io, r: recovery.Record, atomic: bool) !void {
        return cast(raw).inner.create(io, r, atomic);
    }
    fn write(raw: *anyopaque, io: std.Io, r: recovery.Record, bytes: []const u8) !void {
        return cast(raw).inner.write(io, r, bytes);
    }
    fn writeAt(raw: *anyopaque, io: std.Io, r: recovery.Record, offset: u64, bytes: []const u8) !void {
        return cast(raw).inner.writeAt(io, r, offset, bytes);
    }
    fn syncFile(raw: *anyopaque, io: std.Io, r: recovery.Record) !void {
        return cast(raw).inner.syncFile(io, r);
    }
    fn publish(raw: *anyopaque, io: std.Io, r: recovery.Record) !void {
        const self = cast(raw);
        try self.inner.publish(io, r);
        self.published = r;
    }
    fn syncDirectory(raw: *anyopaque, io: std.Io) !void {
        const self = cast(raw);
        try self.inner.syncDirectory(io);
        if (self.published) |r| {
            if ((self.cut == .program and r == .program) or (self.cut == .ready and r == .ready) or (self.cut == .committed and r == .commit)) return error.InjectedExecutionInterruption;
        }
    }
    const VTABLE: recovery.Store.VTable = .{ .reserve = reserve, .block_size = blockSize, .exists = exists, .size = size, .read = read, .read_at = readAt, .create = createFile, .write = write, .write_at = writeAt, .sync_file = syncFile, .publish = publish, .sync_directory = syncDirectory };
};
