//! Production v4 restart composition. Firmware authenticates the semantic
//! request, then the frozen physical manifest, then the return receipt. Device
//! acquisition and FAT allocation admission remain in the native storage port.
const std = @import("std");
const proto = @import("proto");
const Handoff = proto.Handoff;
const storage = @import("storage");
const uefi = @import("uefi.zig");
const Binding = @import("boot_binding.zig").Binding;
const manifest = @import("session_manifest.zig");
const compiler = @import("maintenance_compiler.zig");
const anchor = storage.esp_anchor;
const File = enum { request, image, manifest, recovery, receipt };
const ROOT_NAMES = [_]anchor.ShortName{ "EFI        ".*, "PIZZA      ".* };
fn path(a: std.mem.Allocator, id: []const u8, file: File) ![]const anchor.ShortName {
    _ = try proto.hexDigest(id);
    const out = try a.alloc(anchor.ShortName, 11);
    @memcpy(out[0..2], &ROOT_NAMES);
    for (0..8) |i| {
        @memset(&out[i + 2], ' ');
        for (id[i * 8 ..][0..8], 0..) |ch, j| out[i + 2][j] = std.ascii.toUpper(ch);
    }
    out[10] = switch (file) {
        .request => "REQUEST BIN".*,
        .image => "MAINT   EFI".*,
        .manifest => "SESSION BIN".*,
        .recovery => "ANCHOR  BIN".*,
        .receipt => "RECEIPT BIN".*,
    };
    return out;
}
fn readFile(a: std.mem.Allocator, io: std.Io, disk: storage.device.Reader, esp: Handoff.Esp, id: []const u8, file: File, max: u64) !struct { bytes: []const u8, proof: anchor.Proof } {
    const proof = try anchor.inspect(a, io, disk, .{ .offset = esp.offset, .length = esp.length }, try path(a, id, file), Handoff.BLOCK_SIZE);
    if (proof.bytes == 0 or proof.bytes > max) return error.HandoffTooLarge;
    const bytes = try a.alloc(u8, @intCast(proof.bytes));
    var offset: usize = 0;
    for (proof.extents) |extent| {
        try disk.readInto(io, extent.offset, bytes[offset..][0..@intCast(extent.length)]);
        offset += @intCast(extent.length);
    }
    if (offset != bytes.len) return error.InvalidHandoff;
    return .{ .bytes = bytes, .proof = proof };
}
fn writeFrozen(io: std.Io, disk: storage.device.Device, proof: anchor.Proof, bytes: []const u8) !void {
    if (proof.bytes != bytes.len) return error.StageReservationSizeChanged;
    var offset: usize = 0;
    for (proof.extents) |extent| {
        var local: u64 = 0;
        while (local < extent.length) {
            const size: usize = @intCast(@min(extent.length - local, 1024 * 1024));
            try disk.write(io, .{ .offset = extent.offset + local, .length = size }, bytes[offset..][0..size]);
            offset += size;
            local += size;
        }
    }
    try disk.flush(io);
}
fn devicePath(a: std.mem.Allocator, io: std.Io, expected: storage.model.Digest) ![]const u8 {
    var sys = try std.Io.Dir.cwd().openDir(io, "/sys/class/block", .{ .iterate = true });
    defer sys.close(io);
    var entries = sys.iterate();
    var found: ?[]const u8 = null;
    while (try entries.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name.len > 128 or std.mem.indexOfScalar(u8, entry.name, '/') != null) continue;
        const candidate = try a.print("/dev/{s}", .{entry.name});
        var block = storage.block_device.BlockDevice.open(a, io, candidate, null, null, .probe) catch |err| switch (err) {
            error.ComplexBlockDeviceUnsupported, error.StableDeviceIdentityUnavailable => continue,
            else => return err,
        };
        defer block.close(io);
        if (block.evidence.partition or !std.mem.eql(u8, &block.target.identity, &expected)) continue;
        if (found != null) return error.AmbiguousStorageIdentity;
        found = candidate;
    }
    return found orelse error.DiskIdentityNotFound;
}
fn device(a: std.mem.Allocator, io: std.Io, expected: storage.model.Digest) ![]const u8 {
    for (0..20) |_| {
        return devicePath(a, io, expected) catch |err| {
            if (err != error.DiskIdentityNotFound) return err;
            try std.Io.sleep(io, .fromMilliseconds(500), .awake);
            continue;
        };
    }
    return error.DiskIdentityNotFound;
}
/// The active firmware Boot option supplies ESP coordinates even if GPT publication
/// was interrupted. It is checked against the authenticated request before use.
const BootEsp = struct {
    esp: Handoff.Esp,
    option: []const u8,
    slot: u16,
    fn requireLease(self: BootEsp, lease: Handoff.Lease) !void {
        if (lease.slot != self.slot or !std.mem.eql(u8, lease.option, self.option)) return error.FirmwareBootOptionChanged;
    }
};
fn bootEsp(a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, capacity: u64, sector: u32) !BootEsp {
    const current = try vars.get(a, io, .current) orelse return error.BootCurrentUnavailable;
    if (current.len != @sizeOf(u16)) return error.InvalidBootCurrent;
    const slot = std.mem.readInt(u16, current[0..2], .little);
    const bytes = try vars.get(a, io, .{ .boot = slot }) orelse return error.MaintenanceBootOptionMissing;
    if (bytes.len < 6 or std.mem.readInt(u32, bytes[0..4], .little) != 1) return error.InvalidBootOption;
    var start: usize = 6;
    while (start + 2 <= bytes.len and std.mem.readInt(u16, bytes[start..][0..2], .little) != 0) : (start += 2) {}
    start += 2;
    if (start > bytes.len or bytes.len - start < 50 or std.mem.readInt(u16, bytes[4..6], .little) != bytes.len - start) return error.InvalidBootOption;
    const dp = bytes[start..];
    if (!std.mem.eql(u8, dp[0..4], &.{ 4, 1, 42, 0 }) or dp[40] != 2 or dp[41] != 2) return error.InvalidBootOption;
    const offset = try std.math.mul(u64, std.mem.readInt(u64, dp[8..16], .little), sector);
    const length = try std.math.mul(u64, std.mem.readInt(u64, dp[16..24], .little), sector);
    if (length == 0 or try std.math.add(u64, offset, length) > capacity) return error.InvalidEspIdentity;
    return .{ .esp = .{ .number = std.mem.readInt(u32, dp[4..8], .little), .uuid = dp[24..40].*, .offset = offset, .length = length }, .option = bytes, .slot = slot };
}
fn requestChecks(a: std.mem.Allocator, request: Handoff.Request, esp: Handoff.Esp, boot: ?BootEsp) !void {
    try request.validate();
    if (!std.meta.eql(request.esp, esp)) return error.EspPartitionChanged;
    if (boot) |value| try value.requireLease(request.lease);
    const validated = try @import("planner.zig").validate(a, request.inventory, request.draft);
    if (!std.mem.eql(u8, validated.digest, request.plan_digest)) return error.PlanApprovalChanged;
    for (validated.diagnostics) |d| if (d.severity == .@"error") return error.InvalidHostPlan;
}
fn savedLease(value: Handoff.Lease) uefi.Lease {
    return .{ .slot = value.slot, .original_order = value.original_order, .original_next = value.original_next, .option = value.option };
}
fn compile(a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, block: *storage.block_device.BlockDevice, esp: Handoff.Esp, id: []const u8, request: Handoff.Request, request_bytes: []const u8) !manifest.Loaded {
    const reader = block.backend().reader();
    const recovery_path = try path(a, id, .recovery);
    const recovery = try anchor.inspect(a, io, reader, .{ .offset = esp.offset, .length = esp.length }, recovery_path, Handoff.BLOCK_SIZE);
    if (recovery.bytes != Handoff.RECOVERY_BYTES) return error.InvalidRecoveryReservation;
    const control = try recovery.slice(a, 0, 2 * Handoff.BLOCK_SIZE, Handoff.BLOCK_SIZE);
    if (control.len != 1) return error.FragmentedSessionControl;
    const receipt_path = try path(a, id, .receipt);
    const receipt_proof = try anchor.inspect(a, io, reader, recovery.esp, receipt_path, Handoff.BLOCK_SIZE);
    const compiled_path = try path(a, id, .manifest);
    const compiled_proof = try anchor.inspect(a, io, reader, recovery.esp, compiled_path, Handoff.BLOCK_SIZE);
    if (compiled_proof.bytes != Handoff.MANIFEST_BYTES) return error.InvalidManifestReservation;
    const table = try storage.partition_table.BUILTIN.readLayout(a, io, reader);
    var uuid: [16]u8 = storage.model.digest(try a.print("pizza-maintenance-partition:{s}", .{id}))[0..16].*;
    uuid[7] = (uuid[7] & 15) | 0x40;
    uuid[8] = (uuid[8] & 63) | 0x80;
    const sid = try proto.hexDigest(id);
    const resources: compiler.Resources = .{ .session = sid, .maintenance_uuid = uuid, .tail = try compiler.tailRange(table.usable, Handoff.TAIL_BYTES, Handoff.BLOCK_SIZE), .esp = recovery.esp, .control = control[0], .bootstrap_store = .{ .session = sid, .block_size = Handoff.BLOCK_SIZE, .extents = try recovery.slice(a, 2 * Handoff.BLOCK_SIZE, 32 * 1024 * 1024, Handoff.BLOCK_SIZE) }, .cleanup_store = .{ .session = sid, .block_size = Handoff.BLOCK_SIZE, .extents = try recovery.slice(a, 2 * Handoff.BLOCK_SIZE + 32 * 1024 * 1024, 32 * 1024 * 1024, Handoff.BLOCK_SIZE) } };
    std.log.info("PIZZA_RESTART_COMPILING", .{});
    const compiled = try compiler.compile(a, io, reader, request.inventory, request.draft, resources);
    const sealed = try manifest.sealRestart(a, compiled, recovery, recovery_path, savedLease(request.lease), try proto.hexDigest(request.image_digest), .{ .proof = receipt_proof, .path = receipt_path }, storage.model.digest(request_bytes));
    // Initial request pin is still intact; no target/capsule write is admitted.
    const old = try Binding.read(a, io, vars);
    try old.check(request_bytes, try proto.hexDigest(request.image_digest));
    try block.admitPreparationFile(a, io, storage.model.digest(request_bytes), compiled_path, compiled_proof, Handoff.BLOCK_SIZE);
    try writeFrozen(io, block.backend(), compiled_proof, sealed.bytes);
    const persisted = try readFile(a, io, reader, esp, id, .manifest, Handoff.MANIFEST_BYTES);
    if (!std.mem.eql(u8, &storage.model.digest(persisted.bytes), &sealed.binding.payload_digest)) return error.SessionManifestChanged;
    try vars.set(a, io, .pizza_session, &try sealed.binding.encode());
    return manifest.load(a, io, vars, persisted.bytes, try proto.hexDigest(request.image_digest));
}
fn choice(io: std.Io, prompt: []const u8, allowed: []const u8) !u8 {
    // Discard input typed before this decision became visible. TCFLSH/TCIFLUSH
    // is the Linux terminal ABI used by our x86_64 maintenance console.
    while (true) {
        const result = std.os.linux.ioctl(0, 0x540b, 0);
        switch (std.os.linux.errno(result)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.MaintenanceConsoleRequired,
        }
    }
    try std.Io.File.stdout().writeStreamingAll(io, prompt);
    var first: ?u8 = null;
    var invalid = false;
    while (true) {
        var byte: u8 = 0;
        const count = std.os.linux.read(0, @ptrCast(&byte), 1);
        switch (std.os.linux.errno(count)) {
            .INTR => continue,
            .SUCCESS => {
                if (count == 0) return error.MaintenanceConsoleRequired;
                if (byte == '\n') {
                    if (!invalid) if (first) |ch| if (std.mem.indexOfScalar(u8, allowed, ch) != null) return ch;
                    first = null;
                    invalid = false;
                    try std.Io.File.stdout().writeStreamingAll(io, "Enter one of the displayed letters, then Enter.\n");
                } else if (byte != '\r') {
                    if (first != null) invalid = true else first = std.ascii.toLower(byte);
                }
            },
            else => return error.MaintenanceConsoleRequired,
        }
    }
}

pub fn run(a: std.mem.Allocator, io: std.Io) !void {
    var efivars = try @import("linux_efivars.zig").Efivars.open(io, true);
    defer efivars.close(io);
    const vars = efivars.variables();
    const raw = try vars.get(a, io, .pizza_session) orelse return error.MissingBootBinding;
    const terminal = if (std.mem.startsWith(u8, raw, "PZTERM01")) try Handoff.Terminal.decode(a, raw) else null;
    const pin = if (terminal == null) try Binding.decode(raw) else null;
    const id = if (terminal) |value| value.expected.id else try a.dupe(u8, &std.fmt.bytesToHex(pin.?.session, .lower));
    const disk_id = if (terminal) |value| try proto.hexDigest(value.expected.disk_identity) else pin.?.disk_identity;
    const native_path = try device(a, io, disk_id);
    var block = try storage.block_device.BlockDevice.open(a, io, native_path, disk_id, null, .write);
    defer block.close(io);
    const boot = if (terminal == null) try bootEsp(a, io, vars, block.target.capacity, block.target.sector_size) else null;
    const esp = if (terminal) |value| value.esp else boot.?.esp;
    const request_file = try readFile(a, io, block.backend().reader(), esp, id, .request, 4 * 1024 * 1024 + 4096);
    const request = try Handoff.Request.decode(a, request_file.bytes);
    try requestChecks(a, request, esp, boot);
    if (!std.mem.eql(u8, request.id, id) or !std.mem.eql(u8, &try proto.hexDigest(request.draft.disk_identity), &disk_id)) return error.SessionIdentityMismatch;
    const image = try anchor.inspect(a, io, block.backend().reader(), request_file.proof.esp, try path(a, id, .image), Handoff.BLOCK_SIZE);
    if (!std.mem.eql(u8, &image.content_digest, &try proto.hexDigest(request.image_digest))) return error.MaintenanceImageChanged;
    if (terminal) |value| {
        const receipt_file = try readFile(a, io, block.backend().reader(), esp, id, .receipt, 2 * 1024 * 1024);
        const json = try receiptBody(receipt_file.bytes, value);
        _ = try value.receipt(a, request, request_file.bytes, json);
        try savedLease(request.lease).restore(a, io, vars);
        return;
    }
    var loaded: manifest.Loaded = undefined;
    if (std.mem.eql(u8, &storage.model.digest(request_file.bytes), &pin.?.payload_digest)) {
        try pin.?.check(request_file.bytes, image.content_digest);
        loaded = try compile(a, io, vars, &block, esp, id, request, request_file.bytes);
    } else {
        const frozen = try readFile(a, io, block.backend().reader(), esp, id, .manifest, Handoff.MANIFEST_BYTES);
        loaded = try manifest.load(a, io, vars, frozen.bytes, image.content_digest);
        if (!std.mem.eql(u8, &storage.model.digest(request_file.bytes), &(loaded.metadata.request_digest orelse return error.MissingRequestProvenance))) return error.HandoffRequestChanged;
    }
    if (!std.mem.eql(u8, loaded.metadata.lease.option, request.lease.option) or !std.mem.eql(u8, loaded.metadata.lease.original_order, request.lease.original_order)) return error.PreparedSessionChanged;
    const prior = storage.maintenance_session.Session.open(a, io, block.backend(), loaded.compiled.bundle) catch |err| switch (err) {
        error.InvalidSessionHeaders => null,
        else => return err,
    };
    const fresh = prior == null;
    try loaded.admit(a, io, vars, &block, fresh);
    var session = prior orelse try storage.maintenance_session.Session.prepare(a, io, block.backend(), loaded.compiled.bundle);
    if (!fresh) try session.recover(io);
    if (session.phase == .prepared or session.phase == .initialized) {
        if (!fresh) _ = try choice(io, "Recovered session. Press C then Enter to continue the approved plan.\n", "c");
        if (session.phase == .prepared) {
            std.log.info("PIZZA_RESTART_BOOTSTRAP", .{});
            try session.bootstrap(io, loaded.compiled.verifier(.bootstrap), null);
        }
        std.log.info("PIZZA_RESTART_APPLY", .{});
        try session.apply(io, loaded.compiled.verifier(.apply), null);
    }
    if (session.phase == .verified) {
        std.log.info("PIZZA_RESTART_VERIFIED", .{});
        const action = try choice(io, "Changes verified. Press A then Enter to accept, or U then Enter to undo.\n", "au");
        if (action == 'a') try session.accept(io) else try session.undo(io);
    }
    if (session.phase == .failed_cleanup) _ = try choice(io, "Cleanup failed; accepted disk changes are retained. Press R then Enter to retry cleanup.\n", "r");
    if (session.phase == .accepted or session.phase == .failed_cleanup) {
        std.log.info("PIZZA_RESTART_CLEANUP", .{});
        try session.cleanup(io, loaded.compiled.verifier(.cleanup), null);
    }
    try loaded.finishPinned(a, io, vars, session, request, request_file.bytes);
    try block.refreshLayout();
    std.log.info("PIZZA_RESTART_RECEIPT_PINNED", .{});
}
fn receiptBody(bytes: []const u8, terminal: Handoff.Terminal) ![]const u8 {
    if (bytes.len != Handoff.BLOCK_SIZE + 65536 or !std.mem.eql(u8, bytes[0..8], "PZRCPT01") or std.mem.readInt(u32, bytes[12..16], .little) != Handoff.BLOCK_SIZE) return error.InvalidCompletionReceiptEnvelope;
    const size = std.mem.readInt(u32, bytes[8..12], .little);
    if (size == 0 or size > 65536 or !std.mem.eql(u8, bytes[Handoff.BLOCK_SIZE - 32 .. Handoff.BLOCK_SIZE], &storage.model.digest(bytes[0 .. Handoff.BLOCK_SIZE - 32])) or !std.mem.eql(u8, bytes[16..48], &try proto.hexDigest(terminal.expected.id)) or !std.mem.eql(u8, bytes[48..80], &try proto.hexDigest(terminal.expected.disk_identity))) return error.InvalidCompletionReceiptEnvelope;
    const result = bytes[Handoff.BLOCK_SIZE..][0..size];
    if (!std.mem.eql(u8, bytes[80..112], &storage.model.digest(result)) or !std.mem.allEqual(u8, bytes[Handoff.BLOCK_SIZE + size ..], 0)) return error.InvalidCompletionReceiptEnvelope;
    return result;
}

test "restart paths use fixed FAT short names and the complete session identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const names = try path(arena.allocator(), "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", .request);
    try std.testing.expectEqual(11, names.len);
    try std.testing.expectEqualStrings("01234567   ", &names[2]);
    try std.testing.expectEqualStrings("89ABCDEF   ", &names[9]);
    try std.testing.expectEqualStrings("REQUEST BIN", &names[10]);
}

test "restart discovers actual BootCurrent and binds its slot to the lease" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sector: u32 = 4096;
    const start = 257;
    const size = 1024;
    for ([_]u16{ 3, 0x5000, 0xfffe }) |slot| {
        var current: [2]u8 = undefined;
        std.mem.writeInt(u16, &current, slot, .little);
        var vars: uefi.MemoryVariables = .{ .a = a, .current = &current, .owned_slot = slot, .owned = try uefi.loadOption(a, 2, start, size, @splat(0x31), "\\EFI\\Pizza\\maint.efi") };
        const found = try bootEsp(a, std.testing.io, vars.vars(), (start + size + 1) * sector, sector);
        try std.testing.expectEqual(slot, found.slot);
        try std.testing.expectEqual(start * sector, found.esp.offset);
        const lease: Handoff.Lease = .{ .slot = slot, .option = found.option, .original_order = &.{ 1, 0 }, .original_next = null };
        try found.requireLease(lease);
        var wrong = lease;
        wrong.slot ^= 1;
        try std.testing.expectError(error.FirmwareBootOptionChanged, found.requireLease(wrong));
        vars.current = null;
        try std.testing.expectError(error.BootCurrentUnavailable, bootEsp(a, std.testing.io, vars.vars(), (start + size + 1) * sector, sector));
    }
}
