const std = @import("std");
test {
    std.testing.refAllDecls(@import("inventory.zig"));
    std.testing.refAllDecls(@import("planner.zig"));
    _ = @import("linux_inventory.zig");
    std.testing.refAllDecls(@import("compiler.zig"));
    std.testing.refAllDecls(@import("maintenance.zig"));
    _ = @import("uefi.zig");
    std.testing.refAllDecls(@import("boot_binding.zig").Binding);
    std.testing.refAllDecls(@import("session_manifest.zig"));
    std.testing.refAllDecls(@import("session_manifest.zig").Loaded);
    std.testing.refAllDecls(@import("maintenance_compiler.zig"));
    _ = @import("linux_efivars.zig");
    std.testing.refAllDecls(@import("linux_efivars.zig").Efivars);
    _ = @import("esp_anchor.zig");
    _ = @import("esp_receipt.zig");
    _ = @import("restart.zig");
    _ = @import("maintenance_filesystem_tests.zig");
}

test "three-phase compiler creates a tail partition then returns the exact approved GPT" {
    const storage = @import("storage");
    const proto = @import("proto");
    const wire = proto.wire;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const bytes = try storage.testing.gpt_fixture.initial(a, 4096);
    // Enlarge the retained ESP placeholder so both fixed recovery capsules fit.
    for ([_]usize{ 2, 510 }) |at| std.mem.writeInt(u64, bytes[at * 4096 + 40 ..][0..8], 319, .little);
    for ([_]usize{ 1, 511 }) |at| {
        const header = bytes[at * 4096 ..][0..4096];
        const array_at: usize = if (at == 1) 2 else 510;
        std.mem.writeInt(u32, header[88..92], std.hash.Crc32.hash(bytes[array_at * 4096 ..][0..4096]), .little);
        std.mem.writeInt(u32, header[16..20], 0, .little);
        std.mem.writeInt(u32, header[16..20], std.hash.Crc32.hash(header[0..92]), .little);
    }
    var m = try storage.testing.crash_model.Machine.init(a, .{ .identity = @splat(0x71), .capacity = bytes.len, .sector_size = 4096 }, bytes);
    const baseline = try storage.partition_table.BUILTIN.readLayout(a, io, m.disk().reader());
    const esp = baseline.entries[0];
    const disk_id = try a.dupe(u8, &std.fmt.bytesToHex(m.target.identity, .lower));
    const part_id = try a.dupe(u8, &std.fmt.bytesToHex(esp.id, .lower));
    const partitions = [_]wire.HostPartition{.{ .id = part_id, .offset = try a.print("{d}", .{esp.range.offset}), .length = try a.print("{d}", .{esp.range.length}), .name = "ESP", .encryption = .none, .protected = true, .attributes = try a.print("{d}", .{esp.attributes}) }};
    const disks = [_]wire.HostDisk{.{ .path = "/dev/fixture", .identity = disk_id, .capacity = try a.print("{d}", .{bytes.len}), .sector_size = 4096, .model = "fixture", .read_only = false, .partition_table = "gpt", .usable_offset = try a.print("{d}", .{baseline.usable.offset}), .usable_length = try a.print("{d}", .{baseline.usable.length}), .partitions = &partitions }};
    const inventory: wire.InventorySnapshot = .{ .version = 4, .snapshot_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .platform = .linux, .disks = &disks };
    const draft: wire.PlanDraft = .{ .version = 4, .snapshot_id = inventory.snapshot_id, .disk_identity = disk_id, .layout = &.{.{ .id = part_id, .offset = partitions[0].offset, .length = partitions[0].length, .name = "ESP", .retain_data = true, .attributes = partitions[0].attributes.? }} };
    const session_id: storage.model.Digest = @splat(0x93);
    const resources: @import("maintenance_compiler.zig").Resources = .{
        .session = session_id,
        .maintenance_uuid = @splat(0x48),
        .tail = .{ .offset = 384 * 4096, .length = 126 * 4096 },
        .esp = esp.range,
        .control = .{ .offset = esp.range.offset, .length = 8192 },
        .bootstrap_store = .{ .session = session_id, .block_size = 4096, .extents = &.{.{ .offset = 68 * 4096, .length = 96 * 4096 }} },
        .cleanup_store = .{ .session = session_id, .block_size = 4096, .extents = &.{.{ .offset = 192 * 4096, .length = 96 * 4096 }} },
    };
    // Repeat-use residue must be initialized transactionally before format.
    for (0..2) |i| @memcpy(m.live[resources.tail.offset + i * 4096 ..][0..8], "PZCAP001");
    const compiled = try @import("maintenance_compiler.zig").compile(a, io, m.disk().reader(), inventory, draft, resources);
    const anchor: storage.esp_anchor.Proof = .{ .disk_identity = m.target.identity, .esp = esp.range, .extents = &.{esp.range}, .bytes = esp.range.length, .metadata_digest = @splat(1), .content_digest = @splat(2) };
    try storage.block_device.validateSessionAnchor(a, m.target, compiled.bundle, anchor);
    var wrong_anchor = anchor;
    wrong_anchor.disk_identity = @splat(9);
    try std.testing.expectError(error.RecoveryBackingChanged, storage.block_device.validateSessionAnchor(a, m.target, compiled.bundle, wrong_anchor));
    wrong_anchor = anchor;
    wrong_anchor.extents = &.{resources.control};
    try std.testing.expectError(error.RecoveryCapsuleOutsideAnchor, storage.block_device.validateSessionAnchor(a, m.target, compiled.bundle, wrong_anchor));
    var unprotected = compiled.bundle;
    unprotected.protected = &.{};
    try std.testing.expectError(error.EspNotProtected, storage.block_device.validateSessionAnchor(a, m.target, unprotected, anchor));
    const uefi = @import("uefi.zig");
    var firmware: uefi.MemoryVariables = .{ .a = a };
    const lease = try uefi.Lease.capture(a, io, firmware.vars(), 0x5049, try uefi.loadOption(a, 1, esp.range.offset / 4096, esp.range.length / 4096, esp.uuid, "\\EFI\\Pizza\\session.efi"));
    const manifest = @import("session_manifest.zig");
    const sealed = try manifest.seal(a, compiled, anchor, &.{"ANCHOR  BIN".*}, lease, @splat(0x49));
    try std.testing.expectError(error.MissingBootBinding, manifest.load(a, io, firmware.vars(), sealed.bytes, @splat(0x49)));
    try sealed.binding.install(a, io, firmware.vars());
    var receipts: TestReceipts = .{ .a = a };
    const loaded = try manifest.load(a, io, firmware.vars(), sealed.bytes, @splat(0x49));
    try loaded.arm(a, io, firmware.vars());
    const corrupted = try a.dupe(u8, sealed.bytes);
    corrupted[30] ^= 1; // verification policy and program bytes are both pinned
    try std.testing.expectError(error.SessionManifestChanged, manifest.load(a, io, firmware.vars(), corrupted, @splat(0x49)));
    try std.testing.expectError(error.MaintenanceImageChanged, manifest.load(a, io, firmware.vars(), sealed.bytes, @splat(9)));
    try std.testing.expectError(error.SessionManifestChanged, manifest.load(a, io, firmware.vars(), sealed.bytes[0 .. sealed.bytes.len - 1], @splat(0x49)));
    try std.testing.expectEqualSlices(u8, &compiled.bundle.digest(), &loaded.compiled.bundle.digest());
    var session = try storage.maintenance_session.Session.prepare(a, io, m.disk(), compiled.bundle);
    try session.bootstrap(io, compiled.verifier(.bootstrap), null);
    try std.testing.expectEqual(2, (try storage.partition_table.BUILTIN.readLayout(a, io, m.disk().reader())).entries.len);
    try session.apply(io, compiled.verifier(.apply), null);
    try std.testing.expectError(error.MaintenanceStillOwnsBoot, loaded.finish(a, io, firmware.vars(), session, receipts.sink()));
    try sealed.binding.require(a, io, firmware.vars());
    try session.accept(io);
    try session.cleanup(io, compiled.verifier(.cleanup), null);
    try std.testing.expectEqual(.completed, session.phase);
    try std.testing.expect(try compiled.cleanup.verify(a, io, m.disk().reader()));
    receipts.fail_publish = true;
    try std.testing.expectError(error.ReceiptSyncFailed, loaded.finish(a, io, firmware.vars(), session, receipts.sink()));
    try sealed.binding.require(a, io, firmware.vars());
    try std.testing.expect(firmware.owned != null);
    receipts.fail_publish = false;
    receipts.corrupt_readback = true;
    try std.testing.expectError(error.CompletionReceiptReadbackMismatch, loaded.finish(a, io, firmware.vars(), session, receipts.sink()));
    try sealed.binding.require(a, io, firmware.vars());
    try std.testing.expect(firmware.owned != null);
    receipts.corrupt_readback = false;
    const receipt = try loaded.receipt(a, session);
    try std.testing.expectEqual(.completed, receipt.outcome);
    const receipt_writes = receipts.writes;
    // Boot restoration and clearing the firmware pin are restartable even
    // after the firmware acknowledged a write but the caller saw an error.
    for (1..5) |cut| {
        var interrupted: uefi.MemoryVariables = .{ .a = a };
        try sealed.binding.install(a, io, interrupted.vars());
        try loaded.arm(a, io, interrupted.vars());
        interrupted.next = null; // firmware consumed BootNext
        interrupted.fail_after = interrupted.writes + cut;
        loaded.finish(a, io, interrupted.vars(), session, receipts.sink()) catch |err| if (err != error.SimulatedFirmwareInterruption) return err;
        interrupted.fail_after = null;
        try loaded.finish(a, io, interrupted.vars(), session, receipts.sink());
        try std.testing.expect(interrupted.binding == null);
        try std.testing.expect(interrupted.owned == null);
        try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, interrupted.order.?);
        try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, interrupted.next.?);
    }
    try loaded.finish(a, io, firmware.vars(), session, receipts.sink());
    try loaded.finish(a, io, firmware.vars(), session, receipts.sink());
    try std.testing.expectEqual(receipt_writes, receipts.writes);
    try std.testing.expect(firmware.binding == null);
    try std.testing.expect(firmware.owned == null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, firmware.order.?);
    for (baseline.original) |record| try std.testing.expectEqualSlices(u8, record.content, m.live[@intCast(record.range.offset)..][0..record.content.len]);
}

test "approved GPT deletion compiles through native storage and remains reversible" {
    const storage = @import("storage");
    const wire = @import("proto").wire;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const bytes = try storage.testing.gpt_fixture.initial(a, 512);
    var m = try storage.testing.crash_model.Machine.init(a, .{ .identity = @splat(0x43), .capacity = bytes.len, .sector_size = 512 }, bytes);
    const layout = try storage.partition_table.BUILTIN.readLayout(a, io, m.disk().reader());
    const entry = layout.entries[0];
    const disk_id = try a.dupe(u8, &std.fmt.bytesToHex(m.target.identity, .lower));
    const partition_id = try a.dupe(u8, &std.fmt.bytesToHex(entry.id, .lower));
    const partitions = [_]wire.HostPartition{.{ .id = partition_id, .offset = try a.print("{d}", .{entry.range.offset}), .length = try a.print("{d}", .{entry.range.length}), .name = "Data", .encryption = .none, .attributes = try a.print("{d}", .{entry.attributes}) }};
    const disks = [_]wire.HostDisk{.{ .path = "/dev/test", .identity = disk_id, .capacity = try a.print("{d}", .{bytes.len}), .sector_size = 512, .model = "fixture", .read_only = false, .partition_table = "gpt", .usable_offset = try a.print("{d}", .{layout.usable.offset}), .usable_length = try a.print("{d}", .{layout.usable.length}), .partitions = &partitions }};
    const inventory: wire.InventorySnapshot = .{ .version = 4, .snapshot_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .platform = .linux, .disks = &disks };
    const draft: wire.PlanDraft = .{ .version = 4, .snapshot_id = inventory.snapshot_id, .disk_identity = disk_id, .intents = &.{.{ .kind = .delete, .partition_id = partition_id }} };
    const compiled = try @import("compiler.zig").compileOffline(a, io, m.disk().reader(), inventory, draft);
    try storage.program_executor.executeDeferred(a, io, m.disk(), m.store(), compiled.program, &.{}, null, null);
    try std.testing.expect(try compiled.verify(a, io, m.disk().reader()));
    try std.testing.expectEqual(0, (try storage.partition_table.BUILTIN.readLayout(a, io, m.disk().reader())).entries.len);
    try std.testing.expectEqual(.rolled_back, try storage.program_executor.undo(a, io, m.disk(), m.store(), null));
    try std.testing.expectEqualSlices(u8, bytes, m.live);
    var stale = draft;
    stale.snapshot_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try std.testing.expectError(error.InvalidHostPlan, @import("compiler.zig").compileOffline(a, io, m.disk().reader(), inventory, stale));
}

const TestReceipts = struct {
    a: std.mem.Allocator,
    bytes: []const u8 = "",
    fail_publish: bool = false,
    corrupt_readback: bool = false,
    writes: usize = 0,
    fn sink(self: *@This()) @import("session_manifest.zig").ReceiptSink {
        return .{ .context = self, .publish = publish, .read = read };
    }
    fn publish(context: *anyopaque, _: std.Io, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.fail_publish) return error.ReceiptSyncFailed;
        self.bytes = try self.a.dupe(u8, bytes);
        self.writes += 1;
    }
    fn read(context: *anyopaque, _: std.mem.Allocator, _: std.Io) ![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return if (self.corrupt_readback) "corrupted" else self.bytes;
    }
};

test "NTFS create preserves approved Unicode volume labels and detects mismatches" {
    const storage = @import("storage");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try a.alloc(u8, 32 * 1024 * 1024);
    @memset(bytes, 0);
    var machine = try storage.testing.crash_model.Machine.init(a, .{ .identity = @splat(0x51), .capacity = bytes.len, .sector_size = 512 }, bytes);
    const range: storage.model.Range = .{ .offset = 0, .length = bytes.len };
    const driver = try storage.filesystem.BUILTIN.get(.ntfs);
    const intent: storage.semantic.Intent = .{ .operation = .create, .bytes = bytes.len, .label = "Pizza中文😀" };
    const plan = try storage.service.filesystem(a, std.testing.io, machine.disk().reader(), range, driver, intent);
    var preview = try storage.program.Preview.init(machine.disk().reader(), plan.program);
    try std.testing.expect(try plan.verify(a, std.testing.io, preview.reader()));
    const fs = try driver.open(a, std.testing.io, preview.reader(), false);
    defer fs.close();
    var wrong = intent;
    wrong.label = "different";
    try std.testing.expect(!(try fs.verify(wrong, preview.reader())).consistent);
    wrong.label = "invalid/name";
    try std.testing.expectError(error.NtfsInvalidVolumeLabel, storage.service.filesystem(a, std.testing.io, machine.disk().reader(), range, driver, wrong));
    wrong.label = "123456789012345678901234567890123";
    try std.testing.expectError(error.NtfsInvalidVolumeLabel, storage.service.filesystem(a, std.testing.io, machine.disk().reader(), range, driver, wrong));
}
