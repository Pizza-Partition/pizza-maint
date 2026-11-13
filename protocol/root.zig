const std = @import("std");
pub const wire = @import("generated.zig");

pub const API_VERSION = wire.API_VERSION;
pub const Plan = wire.Plan;
pub const Event = wire.Event;
pub const JournalPhase = wire.JournalPhase;

test "journal header size is stable" {
    try std.testing.expectEqual(@as(usize, 64), wire.JOURNAL_HEADER_BYTES);
    try std.testing.expectEqual(@as(u32, 0x505a4a31), wire.JOURNAL_MAGIC);
}

pub fn validatePlan(plan: Plan) !void {
    if (plan.version != API_VERSION or plan.id.len == 0 or plan.id.len > 64 or plan.steps.len > 16384) return error.InvalidPlan;
    for (plan.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidPlan;
    if (plan.request) |request| try validateRequest(request);
    for (plan.steps, 0..) |step, index| {
        if ((plan.request != null and step.simulated) or step.id == 0 or step.label.len == 0 or step.label.len > 256 or !std.unicode.utf8ValidateSlice(step.label)) return error.InvalidPlan;
        for (plan.steps[0..index]) |previous| if (step.id == previous.id) return error.InvalidPlan;
    }
}

pub fn hexDigest(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidDeviceIdentity;
    var bytes: [32]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        var value: u8 = 0;
        for (text[i * 2 ..][0..2]) |ch| {
            const digit: u8 = if (ch >= '0' and ch <= '9') ch - '0' else if (ch >= 'a' and ch <= 'f') ch - 'a' + 10 else return error.InvalidDeviceIdentity;
            value = value * 16 + digit;
        }
        byte.* = value;
    }
    return bytes;
}
pub fn byteCount(text: []const u8) !u64 {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidByteCount;
    for (text) |ch| if (ch < '0' or ch > '9') return error.InvalidByteCount;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidByteCount;
}
fn validateDevice(ref: wire.DeviceRef) !void {
    if (!std.fs.path.isAbsolute(ref.path) or ref.path.len > 4096 or std.mem.indexOfScalar(u8, ref.path, 0) != null) return error.InvalidDevicePath;
    _ = try hexDigest(ref.identity);
    if (ref.sector_size < 512 or ref.sector_size > 65536 or !std.math.isPowerOfTwo(ref.sector_size)) return error.InvalidSectorSize;
}
pub fn validateRequest(request: wire.OperationRequest) !void {
    try validateDevice(request.target);
    if (request.source) |source| try validateDevice(source);
    if (request.partition_id) |id| _ = try hexDigest(id);
    if (request.target_bytes) |bytes| if (try byteCount(bytes) == 0) return error.InvalidByteCount;
    if ((request.operation == .create) != (request.filesystem != null)) return error.InvalidFilesystemSelection;
    if ((request.operation == .copy) != (request.source != null)) return error.InvalidCloneRequest;
    if ((request.operation == .grow or request.operation == .shrink) != (request.target_bytes != null)) return error.InvalidResizeRequest;
    if ((request.operation == .layout) != (request.partitions.len != 0) or request.partitions.len > 4096) return error.InvalidPartitionChanges;
    if (request.operation == .layout or request.operation == .recover) if (request.partition_id != null) return error.InvalidPartitionChanges;
    for (request.partitions, 0..) |change, i| {
        _ = try hexDigest(change.partition_id);
        const offset = try byteCount(change.offset);
        const length = try byteCount(change.length);
        if (length == 0 or offset % request.target.sector_size != 0 or length % request.target.sector_size != 0) return error.InvalidPartitionChanges;
        _ = std.math.add(u64, offset, length) catch return error.InvalidPartitionChanges;
        for (request.partitions[0..i]) |previous| if (std.mem.eql(u8, previous.partition_id, change.partition_id)) return error.InvalidPartitionChanges;
    }
}

pub const JAVASCRIPT_BINDING = @embedFile("generated/contract.js");
pub const TYPESCRIPT_BINDING = @embedFile("generated/contract.d.ts");

/// These identifiers must come from the host's root-owned pending session,
/// never from the receipt being checked. Parsing does not authenticate an ESP
/// file: its device/allocation binding is verified by the platform importer.
pub const ReceiptIdentity = struct {
    id: []const u8,
    plan_digest: []const u8,
    program_digest: []const u8,
    disk_identity: []const u8,
    image_digest: []const u8,
};
pub fn parseCompletion(a: std.mem.Allocator, bytes: []const u8, expected: ReceiptIdentity) !wire.CompletionReceipt {
    if (bytes.len == 0 or bytes.len > 65536) return error.CompletionReceiptTooLarge;
    const value = try std.json.parseFromSliceLeaky(wire.CompletionReceipt, a, bytes, .{});
    if (value.version != API_VERSION) return error.IncompatibleCompletionReceipt;
    if (value.message.len > 4096 or !std.unicode.utf8ValidateSlice(value.message) or std.mem.indexOfScalar(u8, value.message, 0) != null) return error.InvalidCompletionReceipt;
    inline for (comptime std.meta.fieldNames(ReceiptIdentity)) |field| {
        const actual = @field(value, field);
        _ = try hexDigest(actual);
        _ = try hexDigest(@field(expected, field));
        if (!std.mem.eql(u8, actual, @field(expected, field))) return error.CompletionReceiptIdentityMismatch;
    }
    return value;
}
test "completion receipts bind every identifier and reject incompatible or extra data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "1111111111111111111111111111111111111111111111111111111111111111";
    const other = "2222222222222222222222222222222222222222222222222222222222222222";
    const expected: ReceiptIdentity = .{ .id = id, .plan_digest = id, .program_digest = id, .disk_identity = id, .image_digest = id };
    var receipt: wire.CompletionReceipt = .{ .version = API_VERSION, .id = id, .plan_digest = id, .program_digest = id, .disk_identity = id, .image_digest = id, .outcome = .completed, .message = "Verified maintenance complete" };
    const bytes = try std.json.Stringify.valueAlloc(a, receipt, .{});
    _ = try parseCompletion(a, bytes, expected);
    inline for (comptime std.meta.fieldNames(ReceiptIdentity)) |field| {
        var changed = receipt;
        @field(changed, field) = other;
        try std.testing.expectError(error.CompletionReceiptIdentityMismatch, parseCompletion(a, try std.json.Stringify.valueAlloc(a, changed, .{}), expected));
    }
    receipt.version = 3;
    try std.testing.expectError(error.IncompatibleCompletionReceipt, parseCompletion(a, try std.json.Stringify.valueAlloc(a, receipt, .{}), expected));
    const extra = try std.mem.concat(a, u8, &.{ bytes[0 .. bytes.len - 1], ",\"command\":\"arbitrary\"}" });
    try std.testing.expectError(error.UnknownField, parseCompletion(a, extra, expected));
    try std.testing.expectError(error.CompletionReceiptTooLarge, parseCompletion(a, try a.alloc(u8, 65537), expected));
}

/// Storage-independent restart handoff. Host requests carry reviewed semantic
/// intent; physical programs are compiled only after the target is offline.
/// Terminal state remains firmware-pinned until the host has durably imported it.
pub const Handoff = struct {
    pub const BLOCK_SIZE = 4096;
    pub const MANIFEST_BYTES = 64 * 1024 * 1024;
    pub const RECOVERY_BYTES = 64 * 1024 * 1024 + 2 * BLOCK_SIZE;
    pub const TAIL_BYTES = 64 * 1024 * 1024;
    pub const Lease = struct { slot: u16, original_order: []const u8, original_next: ?[]const u8, option: []const u8 };
    pub const Esp = struct { number: u32, uuid: [16]u8, offset: u64, length: u64 };
    pub const Request = struct {
        version: u16 = 1,
        id: []const u8,
        plan_digest: []const u8,
        image_digest: []const u8,
        inventory: wire.InventorySnapshot,
        draft: wire.PlanDraft,
        esp: Esp,
        lease: Lease,
        pub fn validate(self: Request) !void {
            if (self.version != 1 or self.inventory.version != API_VERSION or self.draft.version != API_VERSION) return error.IncompatibleHandoff;
            _ = try hexDigest(self.id);
            _ = try hexDigest(self.plan_digest);
            _ = try hexDigest(self.image_digest);
            _ = try hexDigest(self.draft.disk_identity);
            if (!std.mem.eql(u8, self.inventory.snapshot_id, self.draft.snapshot_id) or self.inventory.disks.len > 4096 or self.draft.layout.len > 4096 or self.draft.intents.len > 16384) return error.InvalidHandoff;
            if (self.esp.number == 0 or self.esp.length == 0 or self.esp.offset % BLOCK_SIZE != 0 or self.esp.length % BLOCK_SIZE != 0 or std.mem.allEqual(u8, &self.esp.uuid, 0)) return error.InvalidHandoff;
            _ = try std.math.add(u64, self.esp.offset, self.esp.length);
            const l = self.lease;
            if (l.original_order.len == 0 or l.original_order.len % 2 != 0 or l.original_order.len > 8192 or l.option.len < 12 or l.option.len > 65536) return error.InvalidHandoff;
            if (l.original_next) |n| if (n.len != 2) return error.InvalidHandoff;
        }
        pub fn encode(self: Request, a: std.mem.Allocator) ![]const u8 {
            try self.validate();
            return frame(a, "PZREQ001", self, 4 * 1024 * 1024, BLOCK_SIZE);
        }
        pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Request {
            const value = try std.json.parseFromSliceLeaky(Request, a, try body(bytes, "PZREQ001", 4 * 1024 * 1024, BLOCK_SIZE), .{});
            try value.validate();
            return value;
        }
    };
    pub const Terminal = struct {
        version: u16 = 1,
        request_digest: [32]u8,
        esp: Esp,
        receipt_digest: [32]u8,
        expected: ReceiptIdentity,
        pub fn validate(self: Terminal) !void {
            if (self.version != 1 or std.mem.allEqual(u8, &self.request_digest, 0) or std.mem.allEqual(u8, &self.receipt_digest, 0)) return error.InvalidTerminalHandoff;
            inline for (comptime std.meta.fieldNames(ReceiptIdentity)) |field| _ = try hexDigest(@field(self.expected, field));
        }
        pub fn encode(self: Terminal, a: std.mem.Allocator) ![]const u8 {
            try self.validate();
            return frame(a, "PZTERM01", self, 16 * 1024, 1);
        }
        pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Terminal {
            const value = try std.json.parseFromSliceLeaky(Terminal, a, try body(bytes, "PZTERM01", 16 * 1024, 1), .{});
            try value.validate();
            return value;
        }
        /// Receipt bytes are authorized by the retained firmware terminal pin,
        /// in addition to the protected host request and all five identities.
        pub fn receipt(self: Terminal, a: std.mem.Allocator, request: Request, request_bytes: []const u8, bytes: []const u8) !wire.CompletionReceipt {
            try self.validate();
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(request_bytes, &hash, .{});
            if (!std.mem.eql(u8, &hash, &self.request_digest)) return error.HandoffRequestChanged;
            std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
            if (!std.mem.eql(u8, &hash, &self.receipt_digest)) return error.CompletionReceiptChanged;
            if (!std.meta.eql(request.esp, self.esp) or !std.mem.eql(u8, request.id, self.expected.id) or !std.mem.eql(u8, request.plan_digest, self.expected.plan_digest) or
                !std.mem.eql(u8, request.image_digest, self.expected.image_digest) or !std.mem.eql(u8, request.draft.disk_identity, self.expected.disk_identity)) return error.CompletionReceiptIdentityMismatch;
            return parseCompletion(a, bytes, self.expected);
        }
    };
    fn frame(a: std.mem.Allocator, magic: *const [8]u8, value: anytype, max: usize, alignment: usize) ![]const u8 {
        const json = try std.json.Stringify.valueAlloc(a, value, .{});
        defer a.free(json);
        if (json.len == 0 or json.len > max) return error.HandoffTooLarge;
        const bytes = try a.alloc(u8, std.mem.alignForward(usize, 12 + json.len, alignment));
        @memset(bytes, 0);
        @memcpy(bytes[0..8], magic);
        std.mem.writeInt(u32, bytes[8..12], @intCast(json.len), .little);
        @memcpy(bytes[12..][0..json.len], json);
        return bytes;
    }
    fn body(bytes: []const u8, magic: *const [8]u8, max: usize, alignment: usize) ![]const u8 {
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidHandoff;
        const length = std.mem.readInt(u32, bytes[8..12], .little);
        if (length == 0 or length > max or bytes.len != std.mem.alignForward(usize, 12 + @as(usize, length), alignment) or !std.mem.allEqual(u8, bytes[12 + length ..], 0)) return error.InvalidHandoff;
        return bytes[12..][0..length];
    }
};

test "restart handoff frames reject padding changes, extra fields and oversized payloads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "1111111111111111111111111111111111111111111111111111111111111111";
    const terminal: Handoff.Terminal = .{ .request_digest = @splat(1), .esp = .{ .number = 1, .uuid = @splat(3), .offset = 1048576, .length = 1048576 }, .receipt_digest = @splat(2), .expected = .{ .id = text, .plan_digest = text, .program_digest = text, .disk_identity = text, .image_digest = text } };
    const bytes = try terminal.encode(a);
    try std.testing.expectEqualStrings(text, (try Handoff.Terminal.decode(a, bytes)).expected.program_digest);
    const padded = try Handoff.frame(a, "PZREQ001", terminal, 16384, 4096);
    _ = try Handoff.body(padded, "PZREQ001", 16384, 4096);
    @constCast(padded)[padded.len - 1] = 1;
    try std.testing.expectError(error.InvalidHandoff, Handoff.body(padded, "PZREQ001", 16384, 4096));
    try std.testing.expectError(error.InvalidHandoff, Handoff.Terminal.decode(a, bytes[0 .. bytes.len - 1]));
}

pub const uefi = @import("uefi.zig");
pub const firmware_pin = @import("firmware_pin.zig");
pub const receipt_envelope = @import("receipt_envelope.zig");
pub const inventory_fingerprint = @import("inventory_fingerprint.zig");
pub const intent_normalization = @import("intent_normalization.zig");
test {
    std.testing.refAllDecls(uefi);
    std.testing.refAllDecls(intent_normalization);
    std.testing.refAllDecls(receipt_envelope);
}

pub const plan_validation_cases = @import("plan_validation_cases.zig");
pub const plan_validation = @import("plan_validation.zig").For(@This());

test "shared plan admission corpus" {
    try @import("plan_validation_cases.zig").run(@This());
}
