//! Production planning entry points. Algorithms are shared; devices stay read-only.
const std = @import("std");
const model = @import("model.zig");
const device = @import("device.zig");
const semantic = @import("semantic.zig");
const algorithm = @import("algorithm.zig");
const programs = @import("program.zig");
const tables = @import("partition_table.zig");
const filesystems = @import("filesystem/root.zig");
pub const Verification = struct { driver: semantic.Driver, range: model.Range, intent: semantic.Intent };
pub const Plan = struct {
    program: programs.Program,
    checks: []const Verification,
    layout: ?[]const tables.Entry = null,
    clone_digest: ?model.Digest = null,
    clone_range: ?model.Range = null,
    table_checkpoint: ?usize = null,
    pub fn verifyFilesystems(self: Plan, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !bool {
        var source = programs.PhysicalProgramBuilder.init(a, reader);
        for (self.checks) |check| {
            var view: programs.PhysicalProgramBuilder.View = .{ .builder = &source, .version = 0, .range = check.range };
            const fs = try check.driver.open(a, io, view.reader(), false);
            defer fs.close();
            const snapshot = try fs.inspect();
            if ((check.intent.operation == .grow or check.intent.operation == .shrink or check.intent.operation == .create) and snapshot.filesystem_bytes != check.intent.bytes) return false;
            if (!(try fs.verify(check.intent, view.reader())).consistent) return false;
        }
        if (self.clone_digest) |expected| if (!std.mem.eql(u8, &expected, &try (reader).digest(io, self.clone_range.?))) return false;
        return true;
    }
    pub fn verify(self: Plan, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !bool {
        if (!try self.verifyFilesystems(a, io, reader)) return false;
        if (self.layout) |expected| {
            const actual = try tables.BUILTIN.readLayout(a, io, reader);
            if (actual.entries.len != expected.len) return false;
            for (expected) |entry| {
                var found = false;
                for (actual.entries) |other| if (std.mem.eql(u8, &entry.id, &other.id) and std.meta.eql(entry.range, other.range) and std.mem.eql(u8, &entry.type_id, &other.type_id) and entry.attributes == other.attributes and std.mem.eql(u8, &entry.uuid, &other.uuid) and std.mem.eql(u8, &entry.name_utf16, &other.name_utf16)) {
                    found = true;
                    break;
                };
                if (!found) return false;
            }
        }
        return true;
    }
};
fn driverFor(io: std.Io, reader: device.Reader) !semantic.Driver {
    return filesystems.BUILTIN.detect(io, reader);
}
fn appendFilesystem(a: std.mem.Allocator, io: std.Io, builder: *programs.PhysicalProgramBuilder, range: model.Range, selected: ?semantic.Driver, intent: semantic.Intent) !semantic.Driver {
    var view: programs.PhysicalProgramBuilder.View = .{ .builder = builder, .version = builder.currentVersion(), .range = range };
    const driver = selected orelse try driverFor(io, view.reader());
    if (intent.label.len != 0 and (driver.filesystem != .ntfs or intent.operation != .create)) return error.UnsupportedFilesystemLabel;
    const fs = try driver.open(a, io, view.reader(), intent.operation == .create);
    defer fs.close();
    var scoped = intent;
    scoped.partition_offset = view.reader().location().range.offset;
    const prepared = try algorithm.prepare(a, fs, scoped);
    try builder.attest(range, try fs.inspect(), intent.operation);
    try algorithm.append(a, io, builder, range.offset, prepared);
    return driver;
}
pub fn filesystem(a: std.mem.Allocator, io: std.Io, reader: device.Reader, range: model.Range, selected: ?semantic.Driver, intent: semantic.Intent) !Plan {
    try range.validate(reader.target.capacity, reader.target.sector_size);
    var builder = programs.PhysicalProgramBuilder.init(a, reader);
    const driver = try appendFilesystem(a, io, &builder, range, selected, intent);
    var expected = intent;
    if (expected.operation == .create) expected.bytes = range.length;
    return .{ .program = try builder.finish(), .checks = try a.dupe(Verification, &.{.{ .driver = driver, .range = range, .intent = expected }}) };
}
const SavedRange = struct { saved: u32, offset: u64 };
const Transition = struct { old: tables.Entry, desired: tables.Entry, driver: semantic.Driver, saved: []const SavedRange = &.{} };
/// One root device, one program, one commit. Every moving partition is captured
/// from the post-shrink version before any partition destination is overwritten.
pub const Format = struct { partition_id: model.Digest, driver: ?semantic.Driver, label: []const u8 = "" };
/// Explicit formats include newly created filesystems; null is reserved for an
/// internal raw maintenance partition, never inferred from an unknown filesystem.
pub fn layout(a: std.mem.Allocator, io: std.Io, reader: device.Reader, desired: []const tables.Entry) !Plan {
    return layoutWithFormats(a, io, reader, desired, &.{});
}
pub fn layoutWithFormats(a: std.mem.Allocator, io: std.Io, reader: device.Reader, desired: []const tables.Entry, formats: []const Format) !Plan {
    const original = try tables.BUILTIN.readLayout(a, io, reader);
    try tables.BUILTIN.validateLayout(original, desired);
    var builder = programs.PhysicalProgramBuilder.init(a, reader);
    for (original.original) |r| try builder.guard(io, r.range);
    for (formats, 0..) |format, i| {
        for (formats[0..i]) |other| if (std.mem.eql(u8, &format.partition_id, &other.partition_id)) return error.DuplicateFormatIntent;
        const found = for (desired) |entry| {
            if (std.mem.eql(u8, &entry.id, &format.partition_id)) break true;
        } else false;
        if (!found) return error.FormatPartitionMissing;
    }
    var transitions: std.ArrayList(Transition) = .empty;
    for (desired) |entry| {
        const formatted = for (formats) |format| {
            if (std.mem.eql(u8, &format.partition_id, &entry.id)) break true;
        } else false;
        if (formatted) continue;
        const old = for (original.entries) |old| {
            if (std.mem.eql(u8, &old.id, &entry.id)) break old;
        } else return error.PartitionIdentityChanged;
        if (std.meta.eql(old.range, entry.range)) continue;
        var view: programs.PhysicalProgramBuilder.View = .{ .builder = &builder, .version = 0, .range = old.range };
        try transitions.append(a, .{ .old = old, .desired = entry, .driver = try driverFor(io, view.reader()) });
    }
    // Shrinking takes place at the old origin. Never expose the final geometry
    // to an algorithm before its allocated content has been evacuated.
    for (transitions.items) |t| {
        if (t.desired.range.length < t.old.range.length) _ = try appendFilesystem(a, io, &builder, t.old.range, t.driver, .{ .operation = .shrink, .bytes = t.desired.range.length, .partition_offset = t.old.range.offset });
    }
    const compacted = builder.currentVersion();
    for (transitions.items) |*t| {
        if (t.old.range.offset == t.desired.range.offset) continue;
        var view: programs.PhysicalProgramBuilder.View = .{ .builder = &builder, .version = compacted, .range = t.old.range };
        const fs = try t.driver.open(a, io, view.reader(), false);
        defer fs.close();
        const ranges = try coverage(a, fs);
        var saved: std.ArrayList(SavedRange) = .empty;
        for (ranges) |range| {
            if (try range.end() > t.desired.range.length) return error.AllocationOutsideNewPartition;
            try saved.append(a, .{ .offset = range.offset, .saved = try builder.save(io, compacted, .{ .offset = t.old.range.offset + range.offset, .length = range.length }) });
        }
        t.saved = try saved.toOwnedSlice(a);
    }
    for (transitions.items) |t| for (t.saved) |range| try builder.restore(range.saved, t.desired.range.offset + range.offset);
    var checks: std.ArrayList(Verification) = .empty;
    for (transitions.items) |t| {
        // Same-size geometry encoding also handles fields such as FAT hidden
        // sectors that depend on the partition's absolute origin.
        const intent: semantic.Intent = .{ .operation = .grow, .bytes = t.desired.range.length, .partition_offset = t.desired.range.offset };
        _ = try appendFilesystem(a, io, &builder, t.desired.range, t.driver, intent);
        try checks.append(a, .{ .driver = t.driver, .range = t.desired.range, .intent = intent });
    }
    // Retained data has been captured and relocated before creating anything
    // that could overwrite a former source range.
    for (formats) |format| {
        const driver = format.driver orelse continue;
        const entry = for (desired) |e| {
            if (std.mem.eql(u8, &e.id, &format.partition_id)) break e;
        } else unreachable;
        const intent: semantic.Intent = .{ .operation = .create, .bytes = entry.range.length, .partition_offset = entry.range.offset, .label = format.label };
        _ = try appendFilesystem(a, io, &builder, entry.range, driver, intent);
        try checks.append(a, .{ .driver = driver, .range = entry.range, .intent = intent });
    }
    try builder.barrier();
    const checkpoint = builder.steps.items.len;
    const encoded = try tables.BUILTIN.encodeLayout(a, original, desired);
    // GPT order is deliberately backup array/header, then primary array/header.
    // Do not sort the records by disk offset or imply atomic publication.
    for (encoded.writes) |w| {
        try builder.applyVersion(io, 0, .{ .target = reader.target, .writes = &.{w} }, false, 0);
        try builder.barrier();
    }
    return .{ .program = try builder.finish(), .checks = try checks.toOwnedSlice(a), .layout = try a.dupe(tables.Entry, desired), .table_checkpoint = checkpoint };
}

/// Physical bytes which the format declares meaningful. Unallocated residue is
/// deliberately excluded; file data, metadata, mirrors and fixed records remain.
pub fn coverage(a: std.mem.Allocator, fs: semantic.Filesystem) ![]const model.Range {
    const g = try fs.describeGeometry(.{ .operation = .query });
    var ranges: std.ArrayList(model.Range) = .empty;
    try ranges.appendSlice(a, g.reserved);
    var cursor: semantic.Cursor = .{};
    while (try fs.enumerateAllocations(&cursor)) |unit| try ranges.appendSlice(a, unit.sources);
    std.mem.sort(model.Range, ranges.items, {}, struct {
        fn less(_: void, x: model.Range, y: model.Range) bool {
            return x.offset < y.offset;
        }
    }.less);
    var output: std.ArrayList(model.Range) = .empty;
    for (ranges.items) |range| {
        if (range.length == 0 or try range.end() > g.bytes) return error.InvalidFilesystemCoverage;
        if (output.items.len != 0) {
            const last = &output.items[output.items.len - 1];
            if (range.offset <= try last.end()) {
                last.length = @max(try last.end(), try range.end()) - last.offset;
                continue;
            }
        }
        try output.append(a, range);
    }
    return output.toOwnedSlice(a);
}

/// Frozen source identity and digest, bounded streaming at execution time.
/// The source stays exclusively open until execution finishes; rollback needs
/// only the target and recovery records, even when that source has disappeared.
pub fn copy(a: std.mem.Allocator, io: std.Io, source: device.Reader, destination: device.Reader, range: model.Range) !Plan {
    if (std.mem.eql(u8, &source.location().identity, &destination.location().identity)) return error.CopyAliasesSource;
    if (source.target.sector_size != destination.target.sector_size) return error.InvalidCloneGeometry;
    try range.validate(destination.target.capacity, destination.target.sector_size);
    const driver = try driverFor(io, source);
    const fs = try driver.open(a, io, source, false);
    defer fs.close();
    const snapshot = try fs.inspect();
    if (!snapshot.clean or !(try fs.check()).consistent) return error.UncleanFilesystem;
    var allowed = false;
    for (snapshot.capabilities) |cap| if (cap.operation == .copy and cap.support == .validated) {
        allowed = true;
        break;
    };
    if (!allowed) return error.NativeOperationUnavailable;
    if (snapshot.filesystem_bytes > range.length) return error.CopyTargetTooSmall;
    var builder = programs.PhysicalProgramBuilder.init(a, destination);
    try builder.attest(range, snapshot, .copy);
    const digest = try builder.copy(io, source, .{ .offset = 0, .length = snapshot.filesystem_bytes }, range.offset);
    const output_range: model.Range = .{ .offset = range.offset, .length = snapshot.filesystem_bytes };
    return .{ .program = try builder.finish(), .checks = try a.dupe(Verification, &.{.{ .driver = driver, .range = range, .intent = .{ .operation = .copy, .bytes = snapshot.filesystem_bytes } }}), .clone_digest = digest, .clone_range = output_range };
}
