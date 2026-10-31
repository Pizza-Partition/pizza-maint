//! Portable filesystem semantics. Implementations and library types stay private.
const std = @import("std");
const model = @import("model.zig");
const device = @import("device.zig");
const mutation = @import("mutation.zig");
pub const ObjectId = u64;
pub const Object = struct { id: ObjectId, kind: enum { file, directory, metadata, reserved }, bytes: u64 };
pub const AllocationUnit = struct {
    id: u64,
    owner: ObjectId,
    sources: []const model.Range,
    content_bytes: u64,
    group: u64 = 0,
    movable: bool = true,
    generated: bool = false,
};
pub const Intent = struct { operation: model.Kind, bytes: u64 = 0, partition_offset: u64 = 0, label: []const u8 = "" };
pub const Geometry = struct {
    bytes: u64,
    allocation_size: u32,
    reserved: []const model.Range = &.{},
    private: *const anyopaque,
};
pub const Requirement = struct {
    id: u64,
    bytes: u64,
    granule: u64,
    alignment: u32,
    alignment_origin: u64 = 0,
    bounds: model.Range,
    fixed: bool = false,
};
pub const Placement = struct { id: u64, ranges: []const model.Range };
pub const Requirements = struct { units: []const Requirement, additional: []const Requirement = &.{} };
pub const Cursor = struct { index: usize = 0 };
pub const Driver = struct {
    filesystem: model.Filesystem,
    context: *const anyopaque,
    operations: []const model.Capability,
    vtable: *const VTable,
    pub const VTable = struct {
        probe: *const fn (*const anyopaque, std.Io, device.Reader) anyerror!bool,
        open: *const fn (*const anyopaque, std.mem.Allocator, std.Io, device.Reader, bool) anyerror!Filesystem,
    };
    pub fn probe(self: Driver, io: std.Io, reader: device.Reader) !bool {
        try reader.target.validate();
        return self.vtable.probe(self.context, io, reader);
    }
    pub fn open(self: Driver, a: std.mem.Allocator, io: std.Io, reader: device.Reader, blank: bool) !Filesystem {
        try reader.target.validate();
        const reads = try a.create(ReadSet);
        reads.* = .{ .allocator = a, .source = reader, .guards = .init(a) };
        errdefer {
            reads.guards.deinit();
            a.destroy(reads);
        }
        var result = try self.vtable.open(self.context, a, io, reads.reader(), blank);
        errdefer result.vtable.close(result.context);
        const snapshot = try result.inspect();
        if (snapshot.filesystem != self.filesystem or !snapshot.target.same(reader.target)) return error.FilesystemIdentityMismatch;
        result.reads = reads;
        return result;
    }
};
pub const Filesystem = struct {
    context: *anyopaque,
    vtable: *const FilesystemOps,
    reads: ?*ReadSet = null,
    pub fn close(self: Filesystem) void {
        self.vtable.close(self.context);
        if (self.reads) |reads| {
            reads.guards.deinit();
            reads.allocator.destroy(reads);
        }
    }
    pub fn inspect(self: Filesystem) !model.Snapshot {
        return self.vtable.inspect(self.context);
    }
    pub fn enumerateObjects(self: Filesystem, cursor: *Cursor) !?Object {
        return self.vtable.enumerate_objects(self.context, cursor);
    }
    pub fn enumerateAllocations(self: Filesystem, cursor: *Cursor) !?AllocationUnit {
        return self.vtable.enumerate_allocations(self.context, cursor);
    }
    pub fn describeGeometry(self: Filesystem, intent: Intent) !Geometry {
        return self.vtable.describe_geometry(self.context, intent);
    }
    pub fn requirements(self: Filesystem, intent: Intent, geometry: Geometry, placements: []const Placement) !Requirements {
        return self.vtable.requirements(self.context, intent, geometry, placements);
    }
    pub fn encodeChanges(self: Filesystem, intent: Intent, geometry: Geometry, placements: []const Placement) !mutation.MutationSet {
        var changes = try self.vtable.encode_changes(self.context, intent, geometry, placements);
        if (self.reads) |reads| if (!changes.target.same(reads.source.target)) return error.FilesystemProgramMismatch;
        if (self.reads) |reads| {
            var guards: std.ArrayList(mutation.Read) = .empty;
            try guards.appendSlice(reads.allocator, changes.reads);
            var iterator = reads.guards.iterator();
            while (iterator.next()) |entry| try guards.append(reads.allocator, .{ .range = entry.key_ptr.*, .expected = entry.value_ptr.* });
            changes.reads = try guards.toOwnedSlice(reads.allocator);
        }
        return changes;
    }
    pub fn check(self: Filesystem) !model.Check {
        const snapshot = try self.inspect();
        try requireCapability(snapshot, .check);
        return self.vtable.check(self.context);
    }
    pub fn verify(self: Filesystem, intent: Intent, reader: device.Reader) !model.Check {
        return self.vtable.verify(self.context, intent, reader);
    }
};
pub fn requireCapability(snapshot: model.Snapshot, kind: model.Kind) !void {
    for (snapshot.capabilities) |capability| if (capability.operation == kind) {
        if (capability.support != .validated) return error.NativeOperationUnavailable;
        return;
    };
    return error.NativeOperationUnavailable;
}
pub const FilesystemOps = struct {
    close: *const fn (*anyopaque) void,
    inspect: *const fn (*anyopaque) anyerror!model.Snapshot,
    enumerate_objects: *const fn (*anyopaque, *Cursor) anyerror!?Object,
    enumerate_allocations: *const fn (*anyopaque, *Cursor) anyerror!?AllocationUnit,
    describe_geometry: *const fn (*anyopaque, Intent) anyerror!Geometry,
    requirements: *const fn (*anyopaque, Intent, Geometry, []const Placement) anyerror!Requirements,
    encode_changes: *const fn (*anyopaque, Intent, Geometry, []const Placement) anyerror!mutation.MutationSet,
    check: *const fn (*anyopaque) anyerror!model.Check,
    verify: *const fn (*anyopaque, Intent, device.Reader) anyerror!model.Check,
};
/// Resolve a logical piece of an allocation unit to one contiguous source.
/// Geometry encoders must request a finer granule if a piece crosses extents.
pub fn sourceAt(unit: AllocationUnit, offset: u64, length: u64) !model.Range {
    var remaining = offset;
    for (unit.sources) |source| {
        if (remaining < source.length) {
            if (length > source.length - remaining) return error.NoncontiguousAllocationPiece;
            return .{ .offset = source.offset + remaining, .length = length };
        }
        remaining -= source.length;
    }
    return error.AllocationOutsideObject;
}

const ReadSet = struct {
    allocator: std.mem.Allocator,
    source: device.Reader,
    guards: std.AutoHashMap(model.Range, model.Digest),
    fn reader(self: *ReadSet) device.Reader {
        var result = self.source;
        result.context = self;
        result.vtable = &.{ .read = readInto };
        return result;
    }
    fn readInto(ctx: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self: *ReadSet = @constCast(@as(*const ReadSet, @ptrCast(@alignCast(ctx))));
        try self.source.readInto(io, offset, bytes);
        if (bytes.len == 0) return;
        const sector = self.source.target.sector_size;
        const start = offset / sector * sector;
        const end = std.mem.alignForward(u64, offset + bytes.len, sector);
        const range: model.Range = .{ .offset = start, .length = end - start };
        const digest = if (start == offset and range.length == bytes.len) model.digest(bytes) else try (self.source).digest(io, range);
        const result = try self.guards.getOrPut(range);
        if (result.found_existing and !std.mem.eql(u8, result.value_ptr, &digest)) return error.PlanningReadChanged;
        result.value_ptr.* = digest;
        if (self.guards.count() > @import("program.zig").MAX_STEPS) return error.StorageReadSetTooLarge;
    }
};
