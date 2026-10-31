//! Real maintenance jobs. Physical recovery is independent of the event journal.
const std = @import("std");
const proto = @import("proto");
const journal = @import("journal");
const storage = @import("storage");
const tui = @import("execution_tui");
const devices = @import("devices.zig");
pub const Options = struct {
    console: bool = true,
    devices: devices.Provider = .{},
    pub fn validate(_: Options) !void {}
};
pub const validate = proto.validatePlan;
const Atomic = std.atomic.Value;
const Work = struct {
    io: std.Io,
    header: proto.Plan,
    boundary: journal.Boundary,
    directory: std.Io.Dir,
    files: storage.recovery_store.Files,
    budget: storage.memory.Controller,
    arena: std.heap.ArenaAllocator,
    writer: ?journal.Writer = null,
    writer_mutex: std.Io.Mutex = .init,
    target: ?devices.Handle = null,
    source: ?devices.Handle = null,
    devices: devices.Provider,
    recovery_admitted: bool = false,
    started_ns: u64,
    physical_plan: ?storage.service.Plan = null,
    summary: proto.Plan,
    planned: Atomic(bool) = .init(false),
    cancel_requested: Atomic(bool) = .init(false),
    phase: Atomic(u8) = .init(0),
    status: Atomic(u8) = .init(@backingInt(proto.wire.ExecutionStatus.running)),
    completed: Atomic(u32) = .init(0),
    completed_bytes: Atomic(u64) = .init(0),
    visible_bytes: Atomic(u64) = .init(0),
    total_bytes: Atomic(u64) = .init(0),
    error_value: ?anyerror = null,
    fn a(self: *Work) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn appendNote(self: *Work, text: []const u8) !void {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        if (self.writer) |*writer| _ = try writer.note(self.io, 0, try journal.monotonicNow(self.io), text);
    }
    fn publishSummary(self: *Work, program: storage.program.Program) !void {
        const steps = try self.a().alloc(proto.wire.Step, program.steps.len);
        var bytes: u64 = 0;
        for (program.steps, steps, 0..) |step, *summary, i| {
            summary.* = .{ .id = @intCast(i + 1), .label = switch (step.operation) {
                .save => "Protect source data",
                .restore => "Relocate allocated data",
                .write => "Update filesystem metadata",
                .barrier => "Confirm durable changes",
                .copy => "Clone filesystem",
            } };
            bytes = try std.math.add(u64, bytes, stepBytes(program, i));
        }
        self.summary = .{ .id = self.header.id, .version = proto.API_VERSION, .steps = steps, .request = self.header.request };
        self.total_bytes.store(bytes, .release);
        self.planned.store(true, .release);
    }
    fn stepBytes(program: storage.program.Program, index: usize) u64 {
        return if (program.steps[index].operation == .save) program.steps[index].operation.save.source.length else if (program.targetRange(index)) |range| range.length else 0;
    }
    fn run(self: *Work) void {
        defer {
            if (self.source) |*source| source.close(self.io);
            if (self.target) |*target| target.close(self.io);
        }
        self.perform() catch |err| {
            self.error_value = err;
            if (self.recovery_admitted) if (self.target) |*target| {
                self.phase.store(2, .release);
                const result = storage.program_executor.recover(self.a(), self.io, target.backend(), self.files.store(), null) catch |restore_error| {
                    self.error_value = restore_error;
                    self.status.store(@backingInt(proto.wire.ExecutionStatus.degraded), .release);
                    return;
                };
                if (result == .committed) {
                    target.refreshLayout() catch |refresh_error| {
                        self.error_value = refresh_error;
                        self.status.store(@backingInt(proto.wire.ExecutionStatus.degraded), .release);
                        return;
                    };
                    self.status.store(@backingInt(proto.wire.ExecutionStatus.succeeded), .release);
                    return;
                }
            };
            self.status.store(@backingInt(if (err == error.OperationCancelled) proto.wire.ExecutionStatus.interrupted else proto.wire.ExecutionStatus.failed), .release);
        };
    }
    fn selectedRange(self: *Work, request: proto.wire.OperationRequest, reader: storage.device.Reader) !storage.model.Range {
        if (request.partition_id) |id| {
            const digest = try proto.hexDigest(id);
            const layout = try storage.partition_table.BUILTIN.readLayout(self.a(), self.io, reader);
            for (layout.entries) |entry| if (std.mem.eql(u8, &entry.id, &digest)) return entry.range;
            return error.PartitionIdentityChanged;
        }
        return .{ .offset = 0, .length = reader.target.capacity };
    }
    fn perform(self: *Work) !void {
        const request = self.header.request orelse return error.MissingOperationRequest;
        self.target = try self.devices.open(self.a(), self.io, request.target, true);
        if (request.operation == .layout and !self.target.?.whole_root) return error.LayoutRequiresWholeDisk;
        try self.target.?.admitRecovery(self.io, self.directory);
        self.recovery_admitted = true;
        // Admission precedes even presentation-log creation: a recovery home
        // on the target must not modify that disk while rejecting the request.
        try self.writer_mutex.lock(self.io);
        self.writer = journal.Writer.create(self.a(), self.io, self.directory, self.boundary, self.started_ns, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => journal.Writer.open(self.a(), self.io, self.directory, self.boundary, self.started_ns, .{}) catch null,
            else => {
                self.writer_mutex.unlock(self.io);
                return err;
            },
        };
        self.writer_mutex.unlock(self.io);
        const disk = self.target.?.backend().withMemory(&self.budget);
        var existing = false;
        for (std.enums.values(storage.recovery_store.Record)) |record| if (try self.files.store().exists(self.io, record)) {
            existing = true;
            break;
        };
        const request_digest = storage.model.digest(try std.json.Stringify.valueAlloc(self.a(), request, .{}));
        if (existing or request.operation == .recover) {
            var matching = request.operation == .recover;
            self.phase.store(2, .release);
            if (try self.files.store().exists(self.io, .program)) {
                const bytes = try self.files.store().read(self.io, .program, self.a(), storage.program.MAX_ENCODED_BYTES);
                const saved = try storage.program.decode(self.a(), bytes);
                matching = matching or std.mem.eql(u8, &saved.request_digest, &request_digest);
                try self.publishSummary(saved);
            }
            const result = try storage.program_executor.recover(self.a(), self.io, disk, self.files.store(), null);
            if (result == .committed) self.target.?.refreshLayout() catch |err| {
                self.error_value = err;
                self.status.store(@backingInt(proto.wire.ExecutionStatus.degraded), .release);
                return;
            };
            if (!matching) {
                self.error_value = error.RecoveryRequestMismatch;
                self.status.store(@backingInt(proto.wire.ExecutionStatus.failed), .release);
                return;
            }
            self.status.store(@backingInt(if (result == .committed) proto.wire.ExecutionStatus.succeeded else proto.wire.ExecutionStatus.interrupted), .release);
            return;
        }
        if (self.writer == null) return error.EventJournalUnavailable;
        const range = try self.selectedRange(request, disk.reader());
        var plan: storage.service.Plan = if (request.operation == .layout) blk: {
            const layout = try storage.partition_table.BUILTIN.readLayout(self.a(), self.io, disk.reader());
            const entries = try self.a().dupe(storage.partition_table.Entry, layout.entries);
            for (request.partitions) |change| {
                const id = try proto.hexDigest(change.partition_id);
                var found = false;
                for (entries) |*entry| if (std.mem.eql(u8, &entry.id, &id)) {
                    entry.range = .{ .offset = try proto.byteCount(change.offset), .length = try proto.byteCount(change.length) };
                    found = true;
                    break;
                };
                if (!found) return error.PartitionIdentityChanged;
            }
            break :blk try storage.service.layout(self.a(), self.io, disk.reader(), entries);
        } else if (request.operation == .copy) blk: {
            const source = request.source.?;
            self.source = try self.devices.open(self.a(), self.io, source, false);
            break :blk try storage.service.copy(self.a(), self.io, self.source.?.backend().reader().withMemory(&self.budget), disk.reader(), range);
        } else blk: {
            const operation = std.meta.stringToEnum(storage.model.Kind, @tagName(request.operation)) orelse return error.InvalidOperationRequest;
            const driver = if (request.filesystem) |format| try storage.filesystem.BUILTIN.get(std.meta.stringToEnum(storage.model.Filesystem, @tagName(format)).?) else null;
            break :blk try storage.service.filesystem(self.a(), self.io, disk.reader(), range, driver, .{ .operation = operation, .bytes = if (request.target_bytes) |bytes| try proto.byteCount(bytes) else 0, .partition_offset = range.offset });
        };
        plan.program = try storage.program.bindRequest(self.a(), plan.program, request_digest);
        self.physical_plan = plan;
        try self.publishSummary(plan.program);
        try self.appendNote(try self.a().print("compiled_program_sha256={s}", .{std.fmt.bytesToHex(plan.program.digest, .lower)}));
        self.phase.store(1, .release);
        const sources: []const storage.device.Reader = if (self.source) |*source| try self.a().dupe(storage.device.Reader, &.{source.backend().reader().withMemory(&self.budget)}) else &.{};
        try storage.program_executor.executeWithSources(self.a(), self.io, disk, self.files.store(), plan.program, sources, .{ .context = self, .check = verify }, .{ .context = self, .event = event, .cancelled = cancelled, .progress = progress });
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        var boundary = self.boundary;
        boundary.state = .complete;
        _ = try self.writer.?.boundaryRecord(self.io, boundary, try journal.monotonicNow(self.io));
        self.target.?.refreshLayout() catch |err| {
            self.error_value = err;
            self.status.store(@backingInt(proto.wire.ExecutionStatus.degraded), .release);
            return;
        };
        self.status.store(@backingInt(proto.wire.ExecutionStatus.succeeded), .release);
    }
    fn cancelled(ctx: *anyopaque) bool {
        const self: *Work = @ptrCast(@alignCast(ctx));
        return self.cancel_requested.load(.acquire);
    }
    fn verify(ctx: *const anyopaque, io: std.Io, reader: storage.device.Reader) !bool {
        const self: *Work = @constCast(@as(*const Work, @ptrCast(@alignCast(ctx))));
        return self.physical_plan.?.verify(self.a(), io, reader);
    }
    fn progress(ctx: *anyopaque, _: usize, done: u64, _: u64) !void {
        const self: *Work = @ptrCast(@alignCast(ctx));
        self.visible_bytes.store(self.completed_bytes.load(.acquire) + done, .release);
    }
    fn event(ctx: *anyopaque, completed: usize, _: usize, _: u64) !void {
        const self: *Work = @ptrCast(@alignCast(ctx));
        const plan = self.physical_plan.?;
        const step = self.summary.steps[completed - 1];
        if (plan.table_checkpoint == completed) if (!try plan.verifyFilesystems(self.a(), self.io, self.target.?.backend().reader())) return error.ProgramVerificationFailed;
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        // These records describe actual completed physical steps. The physical
        // intent/undo protocol remains the authority for crash recovery.
        _ = try self.writer.?.intent(self.io, step.id, try journal.monotonicNow(self.io), step.label);
        _ = try self.writer.?.commit(self.io, step.id, try journal.monotonicNow(self.io), step.label);
        const bytes = stepBytes(plan.program, completed - 1);
        const previous = self.completed_bytes.fetchAdd(bytes, .release);
        self.visible_bytes.store(previous + bytes, .release);
        self.completed.store(@intCast(completed), .release);
    }
};

pub const Executor = struct {
    work: *Work,
    plan: proto.Plan,
    options: Options,
    future: ?std.Io.Future(void) = null,
    status: proto.wire.ExecutionStatus = .running,
    message: []const u8 = "Planning storage changes",
    committed: u32 = 0,
    revision: u64 = 1,
    ready: bool = false,
    byte_buffers: [2][20]u8 = undefined,
    completed_bytes: u64 = 0,
    total_bytes: u64 = 0,
    pub fn start(_: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, plan: proto.Plan, boundary: journal.Boundary, now: u64, options: Options) !Executor {
        try validate(plan);
        try options.validate();
        if (plan.request == null) return error.MissingOperationRequest;
        if (!std.mem.eql(u8, plan.id, boundary.plan_id)) return error.JournalPlanMismatch;
        const work = try std.heap.page_allocator.create(Work);
        errdefer std.heap.page_allocator.destroy(work);
        const owned = try directory.openDir(io, ".", .{});
        errdefer owned.close(io);
        work.* = .{ .io = io, .header = plan, .summary = plan, .boundary = boundary, .directory = owned, .files = .{ .directory = owned }, .budget = try storage.memory.Controller.init(io, .{}), .arena = undefined, .devices = options.devices, .started_ns = now };
        work.arena = .init(work.budget.allocator());
        errdefer work.arena.deinit();
        return .{ .work = work, .plan = plan, .options = options };
    }
    pub fn cancel(self: *Executor) void {
        self.work.cancel_requested.store(true, .release);
    }
    pub fn close(self: *Executor, io: std.Io) void {
        self.cancel();
        if (self.future) |*future| future.await(io);
        if (self.work.writer) |*writer| writer.close(io);
        self.work.files.deinit(io);
        self.work.directory.close(io);
        self.work.arena.deinit();
        std.heap.page_allocator.destroy(self.work);
        self.* = undefined;
    }
    pub fn terminal(self: *const Executor) bool {
        return self.status != .running;
    }
    pub fn view(self: *Executor) proto.wire.Execution {
        return .{ .status = self.status, .step_id = if (self.committed < self.plan.steps.len) self.plan.steps[self.committed].id else 0, .committed = self.committed, .total = @intCast(self.plan.steps.len), .message = self.message, .completed_bytes = std.fmt.bufPrint(&self.byte_buffers[0], "{d}", .{self.completed_bytes}) catch unreachable, .total_bytes = std.fmt.bufPrint(&self.byte_buffers[1], "{d}", .{self.total_bytes}) catch unreachable };
    }
    pub fn tick(self: *Executor, io: std.Io, _: u64) !void {
        if (self.future == null) self.future = try io.concurrent(Work.run, .{self.work});
        if (!self.ready and self.work.planned.load(.acquire)) {
            self.plan = self.work.summary;
            self.ready = true;
            self.revision += 1;
        }
        const completed_bytes = self.work.visible_bytes.load(.acquire);
        const total_bytes = self.work.total_bytes.load(.acquire);
        if (completed_bytes != self.completed_bytes or total_bytes != self.total_bytes) {
            self.completed_bytes = @min(completed_bytes, total_bytes);
            self.total_bytes = total_bytes;
            self.revision += 1;
        }
        const status: proto.wire.ExecutionStatus = @fromBackingInt(@intCast(self.work.status.load(.acquire)));
        const committed = self.work.completed.load(.acquire);
        const message = if (status == .failed or status == .degraded) @errorName(self.work.error_value.?) else if (status == .succeeded) "Storage changes committed" else if (status == .interrupted) "Operation interrupted; recovery completed" else switch (self.work.phase.load(.acquire)) {
            0 => "Planning storage changes",
            1 => "Applying storage changes",
            else => "Restoring original layout",
        };
        if (status != self.status or committed != self.committed or !std.mem.eql(u8, self.message, message)) {
            self.status = status;
            self.committed = committed;
            self.message = message;
            self.revision += 1;
            if (self.options.console) tui.state(io, status, committed, @intCast(self.plan.steps.len), message);
        }
    }
    pub fn journalOffset(self: *Executor, io: std.Io) !u64 {
        try self.work.writer_mutex.lock(io);
        defer self.work.writer_mutex.unlock(io);
        return if (self.work.writer) |writer| writer.offset else 0;
    }
    pub fn snapshot(self: *Executor, a: std.mem.Allocator, io: std.Io) !?journal.Scan {
        try self.work.writer_mutex.lock(io);
        defer self.work.writer_mutex.unlock(io);
        return if (self.work.writer) |writer| try writer.snapshot(a, io) else null;
    }
};
