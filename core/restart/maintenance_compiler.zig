//! Compile bootstrap -> user -> cleanup before any physical write. Intermediate
//! layouts reserve the tail; the cleanup layout is exactly the approved layout.
const std = @import("std");
const storage = @import("storage");
const proto = @import("proto");
const wire = proto.wire;
pub const Resources = struct {
    session: storage.model.Digest,
    maintenance_uuid: [16]u8,
    tail: storage.model.Range,
    esp: storage.model.Range,
    control: storage.model.Range,
    bootstrap_store: storage.recovery_store.CapsuleDescriptor,
    cleanup_store: storage.recovery_store.CapsuleDescriptor,
};
pub const Compiled = struct {
    bundle: storage.recovery_session.Bundle,
    bootstrap: storage.service.Plan,
    apply: storage.service.Plan,
    cleanup: storage.service.Plan,
    allocator: std.mem.Allocator,
    pub fn verifier(self: *const Compiled, phase: enum { bootstrap, apply, cleanup }) storage.program_executor.Verifier {
        return .{ .context = self, .check = switch (phase) {
            .bootstrap => verifyBootstrap,
            .apply => verifyApply,
            .cleanup => verifyCleanup,
        } };
    }
    fn verifyBootstrap(ctx: *const anyopaque, io: std.Io, reader: storage.device.Reader) !bool {
        const self: *const Compiled = @ptrCast(@alignCast(ctx));
        return self.bootstrap.verify(self.allocator, io, reader);
    }
    fn verifyApply(ctx: *const anyopaque, io: std.Io, reader: storage.device.Reader) !bool {
        const self: *const Compiled = @ptrCast(@alignCast(ctx));
        return self.apply.verify(self.allocator, io, reader);
    }
    fn verifyCleanup(ctx: *const anyopaque, io: std.Io, reader: storage.device.Reader) !bool {
        const self: *const Compiled = @ptrCast(@alignCast(ctx));
        return self.cleanup.verify(self.allocator, io, reader);
    }
};
fn contains(outer: storage.model.Range, inner: storage.model.Range) !bool {
    return outer.offset <= inner.offset and try outer.end() >= try inner.end();
}
pub fn tailRange(usable: storage.model.Range, bytes: u64, block: u32) !storage.model.Range {
    try storage.recovery_store.validateBlockSize(block);
    if (bytes == 0) return error.InvalidMaintenanceAreaSize;
    const end = try usable.end() / block * block;
    const length = try std.math.add(u64, bytes, block - 1) / block * block;
    if (length > end or end - length < usable.offset) return error.InsufficientMaintenanceArea;
    return .{ .offset = end - length, .length = length };
}
pub fn compile(a: std.mem.Allocator, io: std.Io, reader: storage.device.Reader, inventory: wire.InventorySnapshot, draft: wire.PlanDraft, resources: Resources) !Compiled {
    const compiled = try @import("compiler.zig").compileOffline(a, io, reader, inventory, draft);
    const final = compiled.plan;
    const target = reader.target;
    const original = try storage.partition_table.BUILTIN.readLayout(a, io, reader);
    const block = resources.bootstrap_store.block_size;
    try resources.tail.validate(target.capacity, block);
    try resources.esp.validate(target.capacity, target.sector_size);
    // A 512-byte GPT usually ends 33 sectors before the device end, which is
    // not 4 KiB aligned. Leave that sub-block padding outside the raw capsule.
    if (try resources.tail.end() != try original.usable.end() / block * block) return error.MaintenanceAreaMustEndAtUsableTail;
    if (resources.tail.overlaps(resources.esp)) return error.MaintenanceAreaOverlapsEsp;
    if (!try contains(resources.esp, resources.control)) return error.RecoveryAnchorOutsideEsp;
    for ([_]storage.recovery_store.CapsuleDescriptor{ resources.bootstrap_store, resources.cleanup_store }) |desc| {
        for (desc.extents) |range| if (!try contains(resources.esp, range)) return error.RecoveryAnchorOutsideEsp;
    }
    // The ESP itself must retain its identity, geometry, GPT type and flags.
    const esp = for (original.entries) |entry| {
        if (std.meta.eql(entry.range, resources.esp)) break entry;
    } else return error.EspPartitionNotFound;
    const kept_esp = for (final.layout orelse return error.MissingFinalLayout) |entry| {
        if (std.mem.eql(u8, &entry.id, &esp.id)) break entry;
    } else return error.EspPartitionChanged;
    if (!std.meta.eql(esp, kept_esp)) return error.EspPartitionChanged;
    for (draft.layout) |p| if (std.mem.eql(u8, &try proto.hexDigest(p.id), &esp.id) and !p.retain_data) return error.EspPartitionChanged;
    const table_slots = std.mem.readInt(u32, original.original[1].content[80..84], .little);
    const slot: u32 = outer: for (0..table_slots) |i| {
        for (original.entries) |e| if (e.slot == i) continue :outer;
        for (final.layout.?) |e| if (e.slot == i) continue :outer;
        break @intCast(i);
    } else return error.NoMaintenanceGptSlot;
    const maintenance: storage.partition_table.Entry = .{
        .id = storage.partition_table.stableId(target, &resources.maintenance_uuid),
        .uuid = resources.maintenance_uuid,
        .type_id = .{ 0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4 },
        .slot = slot,
        .range = resources.tail,
    };
    for (original.entries) |entry| if (std.mem.eql(u8, &entry.id, &maintenance.id)) return error.MaintenanceUuidAlreadyExists;
    for (final.layout.?) |entry| if (std.mem.eql(u8, &entry.id, &maintenance.id)) return error.MaintenanceUuidAlreadyExists;
    const boot_layout = try intermediate(a, original.entries, maintenance);
    // Never shrink a protected, encrypted or unidentified host partition simply
    // to create maintenance room. Filesystem feasibility is checked below.
    for (boot_layout) |entry| for (inventory.disks) |disk| {
        if (disk.identity == null or !std.mem.eql(u8, disk.identity.?, draft.disk_identity)) continue;
        for (disk.partitions) |part| if (std.mem.eql(u8, &entry.id, &try proto.hexDigest(part.id))) {
            if ((entry.range.offset != try proto.byteCount(part.offset) or entry.range.length != try proto.byteCount(part.length)) and (part.protected or part.encryption != .none)) return error.ProtectedMaintenanceBootstrap;
        };
    };
    var bootstrap = try storage.service.layoutWithFormats(a, io, reader, boot_layout, &.{.{ .partition_id = maintenance.id, .driver = null }});
    bootstrap.program = try prepareTail(a, io, reader, original.entries, resources.tail, block, bootstrap.program);
    var boot_preview = try storage.program.Preview.init(reader, bootstrap.program);
    const apply_layout = try intermediate(a, final.layout.?, maintenance);
    var formats: std.ArrayList(storage.service.Format) = .empty;
    for (draft.layout) |p| if (!p.retain_data) {
        const fs = p.filesystem orelse return error.MissingFilesystemSelection;
        try formats.append(a, .{ .partition_id = try proto.hexDigest(p.id), .driver = try storage.filesystem.BUILTIN.get(@fromBackingInt(@intCast(@backingInt(fs)))), .label = p.name });
    };
    var apply = try storage.service.layoutWithFormats(a, io, boot_preview.reader(), apply_layout, formats.items);
    var apply_preview = try storage.program.Preview.init(boot_preview.reader(), apply.program);
    var cleanup = try storage.service.layout(a, io, apply_preview.reader(), final.layout.?);
    const request_digest = compiled.digest;
    bootstrap.program = try storage.program.bindRequest(a, bootstrap.program, request_digest);
    apply.program = try storage.program.bindRequest(a, apply.program, request_digest);
    cleanup.program = try storage.program.bindRequest(a, cleanup.program, request_digest);
    const bundle: storage.recovery_session.Bundle = .{
        .session = resources.session,
        .control = resources.control,
        .bootstrap = bootstrap.program,
        .apply = apply.program,
        .cleanup = cleanup.program,
        .bootstrap_store = resources.bootstrap_store,
        .cleanup_store = resources.cleanup_store,
        .apply_store = .{ .session = resources.session, .block_size = block, .extents = try a.dupe(storage.model.Range, &.{resources.tail}) },
        .protected = try a.dupe(storage.model.Range, &.{resources.esp}),
    };
    try bundle.validate(a, target);
    return .{ .bundle = bundle, .bootstrap = bootstrap, .apply = apply, .cleanup = cleanup, .allocator = a };
}
/// A shrink can relocate a live block out of the tail without overwriting its
/// old address. Later capsule writes WILL overwrite that address. Bootstrap
/// undo restores the original allocation references, so its retained journal
/// must also capture those original bytes before the tail store is initialized.
/// Identity writes use the existing complete before-image executor machinery;
/// unallocated residue needs no preservation and no filesystem-specific branch.
fn prepareTail(a: std.mem.Allocator, io: std.Io, reader: storage.device.Reader, entries: []const storage.partition_table.Entry, tail: storage.model.Range, block: u32, p: storage.program.Program) !storage.program.Program {
    var builder = storage.program.PhysicalProgramBuilder.init(a, reader);
    try builder.steps.appendSlice(a, p.steps);
    try builder.guards.appendSlice(a, p.guards);
    try builder.evidence.appendSlice(a, p.evidence);
    var source = storage.program.PhysicalProgramBuilder.init(a, reader);
    for (entries) |entry| {
        if (!entry.range.overlaps(tail)) continue;
        var view: storage.program.PhysicalProgramBuilder.View = .{ .builder = &source, .version = 0, .range = entry.range };
        const driver = try storage.filesystem.BUILTIN.detect(io, view.reader());
        const fs = try driver.open(a, io, view.reader(), false);
        defer fs.close();
        for (try storage.service.coverage(a, fs)) |local| {
            const start = @max(entry.range.offset + local.offset, tail.offset);
            const end = @min(entry.range.offset + try local.end(), try tail.end());
            if (start >= end) continue;
            // Preserve sector-rounded coverage, without touching a byte outside
            // the reserved tail. Allocation granules are sector-aligned.
            var offset = start;
            while (offset < end) {
                const range: storage.model.Range = .{ .offset = offset, .length = @min(end - offset, storage.mutation.MAX_RECORD_BYTES) };
                const bytes = try reader.read(a, io, range);
                defer a.free(bytes);
                try builder.write(io, range, bytes, false);
                offset += range.length;
            }
        }
    }
    // A previous completed session may leave capsule signatures in free space.
    // Initialize both heads as bootstrap writes, with ordinary before-images;
    // never weaken RawCapsule.format's refusal to replace an existing capsule.
    const heads: storage.model.Range = .{ .offset = tail.offset, .length = @as(u64, block) * 2 };
    if (!try contains(tail, heads)) return error.CapsuleTooSmall;
    const empty = try a.alloc(u8, @intCast(heads.length));
    defer a.free(empty);
    @memset(empty, 0);
    try builder.write(io, heads, empty, false);
    return builder.finish();
}
fn intermediate(a: std.mem.Allocator, entries: []const storage.partition_table.Entry, maintenance: storage.partition_table.Entry) ![]const storage.partition_table.Entry {
    const output = try a.alloc(storage.partition_table.Entry, entries.len + 1);
    @memcpy(output[0..entries.len], entries);
    for (output[0..entries.len]) |*entry| if (entry.range.overlaps(maintenance.range)) {
        if (entry.range.offset >= maintenance.range.offset) return error.MaintenanceAreaConflictsWithPartition;
        entry.range.length = maintenance.range.offset - entry.range.offset;
        if (entry.range.length == 0) return error.MaintenanceAreaConflictsWithPartition;
    };
    output[entries.len] = maintenance;
    return output;
}

test "512-byte GPT tails retain physical recovery-block alignment" {
    const usable: storage.model.Range = .{ .offset = 34 * 512, .length = 128 * 1024 * 1024 - 67 * 512 };
    const tail = try tailRange(usable, 16 * 1024 * 1024 + 1, 4096);
    try std.testing.expectEqual(0, tail.offset % 4096);
    try std.testing.expectEqual(0, tail.length % 4096);
    try std.testing.expect(try tail.end() <= try usable.end());
    try std.testing.expect(try usable.end() - try tail.end() < 4096);
    try std.testing.expectError(error.InsufficientMaintenanceArea, tailRange(usable, 256 * 1024 * 1024, 4096));
}
