//! Immutable terminal receipt in a preallocated FAT32 ESP file. Raw writes touch
//! its admitted extents only; allocation metadata and recovery capsules stay frozen.
const std = @import("std");
const storage = @import("storage");
const proto = @import("proto");
pub const MAX_BYTES = 65536;
pub const Anchor = struct { proof: storage.esp_anchor.Proof, path: []const storage.esp_anchor.ShortName };

pub fn reservationBytes(block: u32) !u64 {
    try storage.recovery_store.validateBlockSize(block);
    return try std.math.add(u64, block, std.mem.alignForward(u64, MAX_BYTES, block));
}
pub fn validate(a: std.mem.Allocator, target: storage.model.Target, bundle: storage.maintenance_session.Bundle, recovery: storage.esp_anchor.Proof, anchor: Anchor) !void {
    try bundle.validate(a, target);
    const proof = anchor.proof;
    const block = bundle.bootstrap_store.block_size;
    if (!std.mem.eql(u8, &proof.disk_identity, &target.identity) or !std.meta.eql(proof.esp, recovery.esp) or
        proof.bytes != try reservationBytes(block) or anchor.path.len == 0 or anchor.path.len > 16) return error.InvalidReceiptAnchor;
    try proof.esp.validate(target.capacity, target.sector_size);
    for (anchor.path) |name| {
        if (name[0] == ' ' or name[0] == '.') return error.InvalidReceiptAnchor;
        for (name) |ch| if (!(ch >= 'A' and ch <= 'Z') and !std.ascii.isDigit(ch) and ch != ' ' and ch != '_' and ch != '-') return error.InvalidReceiptAnchor;
    }
    var total: u64 = 0;
    for (proof.extents, 0..) |r, i| {
        try r.validate(target.capacity, block);
        if (r.offset < proof.esp.offset or try r.end() > try proof.esp.end()) return error.ReceiptOutsideEsp;
        for (proof.extents[0..i]) |other| if (r.overlaps(other)) return error.InvalidReceiptAnchor;
        for (recovery.extents) |other| if (r.overlaps(other)) return error.ReceiptOverlapsRecovery;
        if (r.overlaps(bundle.control)) return error.ReceiptOverlapsRecovery;
        for ([_]storage.recovery_store.CapsuleDescriptor{ bundle.bootstrap_store, bundle.apply_store, bundle.cleanup_store }) |d| {
            for (d.extents) |other| if (r.overlaps(other)) return error.ReceiptOverlapsRecovery;
        }
        for ([_]storage.program.Program{ bundle.bootstrap, bundle.apply, bundle.cleanup }) |p| {
            for (p.steps, 0..) |_, index| if (p.targetRange(index)) |other| if (r.overlaps(other)) return error.ReceiptOverlapsProgram;
        }
        total = try std.math.add(u64, total, r.length);
    }
    if (total != proof.bytes) return error.InvalidReceiptAnchor;
}

pub const EspReceipt = struct {
    allocator: std.mem.Allocator,
    disk: storage.device.Device,
    proof: storage.esp_anchor.Proof,
    block: u32,
    expected: proto.ReceiptIdentity,
    pub fn open(a: std.mem.Allocator, io: std.Io, disk: storage.device.Device, anchor: Anchor, block: u32, expected: proto.ReceiptIdentity) !EspReceipt {
        try disk.authorizeMutation();
        if (!std.mem.eql(u8, &disk.target.identity, &anchor.proof.disk_identity) or
            !std.mem.eql(u8, &try proto.hexDigest(expected.disk_identity), &disk.target.identity) or anchor.proof.bytes != try reservationBytes(block)) return error.InvalidReceiptAnchor;
        const actual = try storage.esp_anchor.revalidate(a, io, disk.reader(), anchor.path, block, anchor.proof, false);
        return .{ .allocator = a, .disk = disk, .proof = actual, .block = block, .expected = expected };
    }
    pub fn sink(self: *EspReceipt) @import("session_manifest.zig").ReceiptSink {
        return .{ .context = self, .publish = publish, .read = read };
    }
    fn transfer(self: *EspReceipt, io: std.Io, logical: u64, bytes: []u8, writing: bool) !void {
        const end = try std.math.add(u64, logical, bytes.len);
        if (end > self.proof.bytes or logical % self.block != 0 or bytes.len % self.block != 0) return error.InvalidReceiptRange;
        var base: u64 = 0;
        var transferred: u64 = 0;
        for (self.proof.extents) |extent| {
            const first = @max(logical, base);
            const stop = @min(end, try std.math.add(u64, base, extent.length));
            if (first < stop) {
                const offset = extent.offset + first - base;
                const segment = bytes[@intCast(first - logical)..][0..@intCast(stop - first)];
                if (writing) try self.disk.write(io, .{ .offset = offset, .length = segment.len }, segment) else try self.disk.reader().readInto(io, offset, segment);
                transferred += segment.len;
            }
            base = try std.math.add(u64, base, extent.length);
        }
        if (transferred != bytes.len) return error.InvalidReceiptRange;
    }
    fn read(ctx: *anyopaque, a: std.mem.Allocator, io: std.Io) ![]const u8 {
        const self: *EspReceipt = @ptrCast(@alignCast(ctx));
        const header = try a.alloc(u8, self.block);
        defer a.free(header);
        try self.transfer(io, 0, header, false);
        if (std.mem.allEqual(u8, header, 0)) return error.FileNotFound;
        if (!std.mem.eql(u8, header[0..8], "PZRCPT01") or
            !std.mem.eql(u8, header[header.len - 32 ..], &storage.model.digest(header[0 .. header.len - 32]))) return error.FileNotFound;
        const size = std.mem.readInt(u32, header[8..12], .little);
        if (size == 0 or size > MAX_BYTES or std.mem.readInt(u32, header[12..16], .little) != self.block or
            !std.mem.eql(u8, header[16..48], &try proto.hexDigest(self.expected.id)) or
            !std.mem.eql(u8, header[48..80], &self.disk.target.identity) or
            !std.mem.allEqual(u8, header[112 .. header.len - 32], 0)) return error.FileNotFound;
        const body = try a.alloc(u8, @intCast(self.proof.bytes - self.block));
        defer a.free(body);
        try self.transfer(io, self.block, body, false);
        if (!std.mem.eql(u8, header[80..112], &storage.model.digest(body[0..size])) or
            !std.mem.allEqual(u8, body[size..], 0)) return error.FileNotFound;
        _ = try proto.parseCompletion(a, body[0..size], self.expected);
        return try a.dupe(u8, body[0..size]);
    }
    fn publish(ctx: *anyopaque, io: std.Io, bytes: []const u8) !void {
        const self: *EspReceipt = @ptrCast(@alignCast(ctx));
        _ = try proto.parseCompletion(self.allocator, bytes, self.expected);
        const old = read(ctx, self.allocator, io) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        if (old.len != 0) {
            if (!std.mem.eql(u8, old, bytes)) return error.CompletionReceiptChanged;
            return;
        }
        const body = try self.allocator.alloc(u8, @intCast(self.proof.bytes - self.block));
        defer self.allocator.free(body);
        @memset(body, 0);
        @memcpy(body[0..bytes.len], bytes);
        try self.transfer(io, self.block, body, true);
        try self.disk.flush(io);
        const header = try self.allocator.alloc(u8, self.block);
        defer self.allocator.free(header);
        @memset(header, 0);
        @memcpy(header[0..8], "PZRCPT01");
        std.mem.writeInt(u32, header[8..12], @intCast(bytes.len), .little);
        std.mem.writeInt(u32, header[12..16], self.block, .little);
        @memcpy(header[16..48], &try proto.hexDigest(self.expected.id));
        @memcpy(header[48..80], &self.disk.target.identity);
        @memcpy(header[80..112], &storage.model.digest(bytes));
        @memcpy(header[header.len - 32 ..], &storage.model.digest(header[0 .. header.len - 32]));
        // A durable payload precedes its checked publication header. A torn or
        // unsynced header remains unpublished, retaining the firmware binding.
        try self.transfer(io, 0, header, true);
        try self.disk.flush(io);
    }
};

test "ESP receipt survives every modeled persistence cut without accepting torn data" {
    var cuts: usize = 1;
    var cut: usize = 0;
    while (cut <= cuts) : (cut += 1) {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const baseline = try a.alloc(u8, 128 * 1024);
        @memset(baseline, 0);
        var machine = try storage.testing.crash_model.Machine.init(a, .{ .identity = @splat(2), .capacity = baseline.len, .sector_size = 4096 }, baseline);
        const id = "0101010101010101010101010101010101010101010101010101010101010101";
        const disk = "0202020202020202020202020202020202020202020202020202020202020202";
        const expected: proto.ReceiptIdentity = .{ .id = id, .disk_identity = disk, .plan_digest = id, .program_digest = id, .image_digest = id };
        const value: proto.wire.CompletionReceipt = .{ .version = 4, .id = id, .disk_identity = disk, .plan_digest = id, .program_digest = id, .image_digest = id, .outcome = .completed, .message = "verified" };
        const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
        // Fragmentation is deliberate; no physical write may cross the gap.
        const proof: storage.esp_anchor.Proof = .{ .disk_identity = @splat(2), .esp = .{ .offset = 0, .length = baseline.len }, .bytes = try reservationBytes(4096), .metadata_digest = @splat(3), .content_digest = @splat(4), .extents = &.{ .{ .offset = 0, .length = 4096 }, .{ .offset = 32768, .length = 65536 } } };
        var store: EspReceipt = .{ .allocator = a, .disk = machine.disk(), .proof = proof, .block = 4096, .expected = expected };
        if (cut != 0) machine.arm(cut, .crash);
        const port = store.sink();
        port.publish(port.context, io, bytes) catch |err| if (err != error.SimulatedPowerLoss) return err;
        if (cut == 0) cuts = machine.events;
        try machine.powerLoss(@intCast(101 + cut), .tear);
        const previous = port.read(port.context, a, io) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        if (previous.len != 0) try std.testing.expectEqualStrings(bytes, previous);
        try port.publish(port.context, io, bytes);
        try std.testing.expectEqualStrings(bytes, try port.read(port.context, a, io));
        try std.testing.expect(std.mem.allEqual(u8, machine.live[4096..32768], 0));
        var changed = value;
        changed.message = "changed";
        try std.testing.expectError(error.CompletionReceiptChanged, port.publish(port.context, io, try std.json.Stringify.valueAlloc(a, changed, .{})));
    }
}
