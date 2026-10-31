//! UEFI boot lease. Persist Lease in the authenticated recovery anchor BEFORE
//! arm(); restore() is permitted only after durable session completion/undo.
//! Firmware image trust is checked by the platform preparer, outside this ABI.
const std = @import("std");
pub const GLOBAL_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
pub const PIZZA_GUID = "137310f9-bc70-4fea-8571-1a1a3fca2c38";
pub const Variable = union(enum) { boot: u16, order, next, current, pizza_session };
pub const Variables = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, std.mem.Allocator, std.Io, Variable) anyerror!?[]const u8,
    write: *const fn (*anyopaque, std.Io, Variable, ?[]const u8) anyerror!void,

    pub fn get(self: Variables, a: std.mem.Allocator, io: std.Io, key: Variable) !?[]const u8 {
        return self.read(self.context, a, io, key);
    }
    pub fn set(self: Variables, a: std.mem.Allocator, io: std.Io, key: Variable, value: ?[]const u8) !void {
        try self.write(self.context, io, key, value);
        if (!optionalEq(try self.get(a, io, key), value)) return error.FirmwareReadbackMismatch;
    }
};
fn optionalEq(x: ?[]const u8, y: ?[]const u8) bool {
    if (x) |v| return y != null and std.mem.eql(u8, v, y.?);
    return y == null;
}
fn orderValid(bytes: []const u8) !void {
    if (bytes.len % 2 != 0 or bytes.len > 8192) return error.InvalidBootOrder;
    var i: usize = 0;
    while (i < bytes.len) : (i += 2) {
        var j: usize = 0;
        while (j < i) : (j += 2) if (std.mem.eql(u8, bytes[i..][0..2], bytes[j..][0..2])) return error.DuplicateBootOption;
    }
}
pub const Lease = struct {
    slot: u16,
    original_order: []const u8,
    original_next: ?[]const u8,
    option: []const u8,

    pub fn capture(a: std.mem.Allocator, io: std.Io, vars: Variables, slot: u16, option: []const u8) !Lease {
        const order = try vars.get(a, io, .order) orelse return error.MissingBootOrder;
        try orderValid(order);
        const next = try vars.get(a, io, .next);
        if (next) |n| if (n.len != 2) return error.InvalidBootNext;
        if (try vars.get(a, io, .{ .boot = slot }) != null) return error.BootOptionAlreadyExists;
        const own = encodedSlot(slot);
        var i: usize = 0;
        while (i < order.len) : (i += 2) if (std.mem.eql(u8, &own, order[i..][0..2])) return error.BootOptionAlreadyExists;
        if (next) |n| if (std.mem.eql(u8, &own, n)) return error.BootOptionAlreadyExists;
        if (option.len < 12 or option.len > 65536) return error.InvalidBootOption;
        return .{ .slot = slot, .original_order = order, .original_next = next, .option = try a.dupe(u8, option) };
    }
    /// Allocate from actual firmware state rather than reserving a fixed slot.
    /// capture() repeats all ownership checks before a slot can be published.
    pub fn captureAvailable(a: std.mem.Allocator, io: std.Io, vars: Variables, option: []const u8) !Lease {
        for (0..@as(usize, std.math.maxInt(u16)) + 1) |index| {
            return capture(a, io, vars, @intCast(index), option) catch |err| switch (err) {
                error.BootOptionAlreadyExists => continue,
                else => return err,
            };
        }
        return error.NoAvailableBootSlot;
    }
    fn armedOrder(self: Lease, a: std.mem.Allocator) ![]const u8 {
        return std.mem.concat(a, u8, &.{ &encodedSlot(self.slot), self.original_order });
    }
    /// Preserve devices appended by firmware, rejecting any change to the saved
    /// prefix or an owned entry anywhere except its armed first position.
    pub fn restoredOrder(self: Lease, order: []const u8) ![]const u8 {
        try orderValid(self.original_order);
        try orderValid(order);
        const own = encodedSlot(self.slot);
        const rest = if (std.mem.startsWith(u8, order, &own)) order[2..] else order;
        if (!std.mem.startsWith(u8, rest, self.original_order)) return error.FirmwareBootOrderChanged;
        var i: usize = 0;
        while (i < rest.len) : (i += 2) if (std.mem.eql(u8, rest[i..][0..2], &own)) return error.FirmwareBootOrderChanged;
        return rest;
    }
    /// Idempotent across interruption after any firmware variable update.
    /// BootOrder keeps maintenance first even after BootNext is consumed.
    pub fn arm(self: Lease, a: std.mem.Allocator, io: std.Io, vars: Variables) !void {
        try orderValid(self.original_order);
        const armed = try self.armedOrder(a);
        const order = try vars.get(a, io, .order);
        if (!optionalEq(order, self.original_order) and !optionalEq(order, armed)) return error.FirmwareBootOrderChanged;
        const next = try vars.get(a, io, .next);
        const own = encodedSlot(self.slot);
        if (next != null and !optionalEq(next, self.original_next) and !optionalEq(next, &own)) return error.FirmwareBootNextChanged;
        if (try vars.get(a, io, .{ .boot = self.slot })) |existing| {
            if (!std.mem.eql(u8, existing, self.option)) return error.FirmwareBootOptionChanged;
        } else try vars.set(a, io, .{ .boot = self.slot }, self.option);
        if (!optionalEq(order, armed)) try vars.set(a, io, .order, armed);
        if (!optionalEq(next, &own)) try vars.set(a, io, .next, &own);
    }
    /// Never removes or overwrites another application's boot entry. A foreign
    /// change stops restoration for diagnosis instead of silently clobbering it.
    pub fn restore(self: Lease, a: std.mem.Allocator, io: std.Io, vars: Variables) !void {
        const order = try vars.get(a, io, .order);
        const restored = try self.restoredOrder(order orelse return error.FirmwareBootOrderChanged);
        const own = encodedSlot(self.slot);
        const next = try vars.get(a, io, .next);
        if (next != null and !optionalEq(next, &own) and !optionalEq(next, self.original_next)) return error.FirmwareBootNextChanged;
        const entry = try vars.get(a, io, .{ .boot = self.slot });
        if (entry) |bytes| if (!std.mem.eql(u8, bytes, self.option)) return error.FirmwareBootOptionChanged;
        // An absent owned entry with the armed order is not a completed restore.
        if (entry == null and restored.len != order.?.len) return error.FirmwareBootOptionMissing;
        if (!optionalEq(next, self.original_next)) try vars.set(a, io, .next, self.original_next);
        if (!optionalEq(order, restored)) try vars.set(a, io, .order, restored);
        if (entry != null) try vars.set(a, io, .{ .boot = self.slot }, null);
    }
};
fn encodedSlot(slot: u16) [2]u8 {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, slot, .little);
    return bytes;
}

/// GPT hard-drive short-form device path followed by a fixed Pizza UKI path.
/// The GUID uses GPT on-disk byte order; geometry is in logical sectors.
pub fn loadOption(a: std.mem.Allocator, partition_number: u32, start_lba: u64, size_lba: u64, partition_guid: [16]u8, path: []const u8) ![]const u8 {
    if (partition_number == 0 or size_lba == 0 or std.mem.allEqual(u8, &partition_guid, 0)) return error.InvalidEspIdentity;
    if (!std.mem.startsWith(u8, path, "\\EFI\\Pizza\\") or !std.mem.endsWith(u8, path, ".efi") or path.len > 240) return error.InvalidMaintenanceBootPath;
    for (path) |c| if (!(std.ascii.isAlphanumeric(c) or c == '\\' or c == '.' or c == '-' or c == '_')) return error.InvalidMaintenanceBootPath;
    var components = std.mem.splitScalar(u8, path[1..], '\\');
    while (components.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidMaintenanceBootPath;
    const name = try std.unicode.utf8ToUtf16LeAlloc(a, "Pizza maintenance");
    const file = try std.unicode.utf8ToUtf16LeAlloc(a, path);
    const file_length = 4 + (file.len + 1) * 2;
    const device_length = 42 + file_length + 4;
    const result = try a.alloc(u8, 6 + (name.len + 1) * 2 + device_length);
    @memset(result, 0);
    std.mem.writeInt(u32, result[0..4], 1, .little); // LOAD_OPTION_ACTIVE
    std.mem.writeInt(u16, result[4..6], @intCast(device_length), .little);
    for (name, 0..) |ch, i| std.mem.writeInt(u16, result[6 + i * 2 ..][0..2], ch, .little);
    const d = result[6 + (name.len + 1) * 2 ..];
    @memcpy(d[0..4], &[_]u8{ 4, 1, 42, 0 }); // MEDIA_HARDDRIVE_DP
    std.mem.writeInt(u32, d[4..8], partition_number, .little);
    std.mem.writeInt(u64, d[8..16], start_lba, .little);
    std.mem.writeInt(u64, d[16..24], size_lba, .little);
    @memcpy(d[24..40], &partition_guid);
    d[40] = 2;
    d[41] = 2; // GPT and GUID signature
    d[42] = 4;
    d[43] = 4; // MEDIA_FILEPATH_DP
    std.mem.writeInt(u16, d[44..46], @intCast(file_length), .little);
    for (file, 0..) |ch, i| std.mem.writeInt(u16, d[46 + i * 2 ..][0..2], ch, .little);
    @memcpy(d[42 + file_length ..][0..4], &[_]u8{ 0x7f, 0xff, 4, 0 });
    return result;
}

pub const MemoryVariables = struct {
    a: std.mem.Allocator,
    order: ?[]const u8 = &.{ 1, 0, 2, 0 },
    next: ?[]const u8 = &.{ 2, 0 },
    current: ?[]const u8 = null,
    owned: ?[]const u8 = null,
    owned_slot: u16 = 0x5049,
    occupied: []const u16 = &.{},
    binding: ?[]const u8 = null,
    writes: usize = 0,
    fail_after: ?usize = null,
    pub fn vars(self: *MemoryVariables) Variables {
        return .{ .context = self, .read = read, .write = write };
    }
    fn read(ctx: *anyopaque, a: std.mem.Allocator, _: std.Io, key: Variable) !?[]const u8 {
        const self: *MemoryVariables = @ptrCast(@alignCast(ctx));
        const value = switch (key) {
            .order => self.order,
            .next => self.next,
            .current => self.current,
            .boot => |slot| blk: {
                for (self.occupied) |used| if (used == slot) break :blk "foreign boot option";
                break :blk if (slot == self.owned_slot) self.owned else null;
            },
            .pizza_session => self.binding,
        };
        return if (value) |bytes| try a.dupe(u8, bytes) else null;
    }
    fn write(ctx: *anyopaque, _: std.Io, key: Variable, bytes: ?[]const u8) !void {
        const self: *MemoryVariables = @ptrCast(@alignCast(ctx));
        const value = if (bytes) |v| try self.a.dupe(u8, v) else null;
        switch (key) {
            .order => self.order = value,
            .next => self.next = value,
            .current => return error.ReadOnlyFirmwareVariable,
            .boot => |slot| {
                if (slot != self.owned_slot) return error.TestUnexpectedBootSlot;
                self.owned = value;
            },
            .pizza_session => self.binding = value,
        }
        self.writes += 1;
        if (self.fail_after == self.writes) return error.SimulatedFirmwareInterruption;
    }
};
test "boot lease survives interrupted arm, consumed BootNext and interrupted restore" {
    for (0..7) |cut| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var memory: MemoryVariables = .{ .a = a };
        const option = try loadOption(a, 1, 2048, 262144, @splat(0x35), "\\EFI\\Pizza\\session-123.efi");
        const lease = try Lease.capture(a, std.testing.io, memory.vars(), 0x5049, option);
        memory.fail_after = if (cut != 0) cut else null;
        lease.arm(a, std.testing.io, memory.vars()) catch |err| if (err != error.SimulatedFirmwareInterruption) return err;
        memory.fail_after = null;
        try lease.arm(a, std.testing.io, memory.vars());
        memory.next = null; // firmware consumes BootNext before the image starts
        try std.testing.expectEqualSlices(u8, &.{ 0x49, 0x50, 1, 0, 2, 0 }, memory.order.?);
        memory.writes = 3;
        memory.fail_after = if (cut > 3) cut else null;
        lease.restore(a, std.testing.io, memory.vars()) catch |err| if (err != error.SimulatedFirmwareInterruption) return err;
        memory.fail_after = null;
        try lease.restore(a, std.testing.io, memory.vars());
        try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, memory.order.?);
        try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, memory.next.?);
        try std.testing.expect(memory.owned == null);
    }
}
test "boot lease refuses foreign edits and escaping image paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory: MemoryVariables = .{ .a = a };
    const option = try loadOption(a, 1, 2048, 262144, @splat(0x35), "\\EFI\\Pizza\\session.efi");
    const lease = try Lease.capture(a, std.testing.io, memory.vars(), 0x5049, option);
    try lease.arm(a, std.testing.io, memory.vars());
    memory.order = &.{ 3, 0, 0x49, 0x50 };
    try std.testing.expectError(error.FirmwareBootOrderChanged, lease.restore(a, std.testing.io, memory.vars()));
    try std.testing.expect(memory.owned != null);
    try std.testing.expectError(error.InvalidMaintenanceBootPath, loadOption(a, 1, 2048, 100, @splat(1), "\\EFI\\Pizza\\..\\Microsoft\\boot.efi"));
}

test "boot restoration preserves appended discovery entries across interrupted writes" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for (0..4) |cut| {
        var memory: MemoryVariables = .{ .a = arena.allocator() };
        const lease = try Lease.capture(arena.allocator(), std.testing.io, memory.vars(), 0x5049, &@as([12]u8, @splat(1)));
        try lease.arm(arena.allocator(), std.testing.io, memory.vars());
        memory.order = &.{ 0x49, 0x50, 1, 0, 2, 0, 7, 0, 8, 0 };
        memory.next = null;
        memory.fail_after = memory.writes + cut;
        lease.restore(arena.allocator(), std.testing.io, memory.vars()) catch |err| if (err != error.SimulatedFirmwareInterruption) return err;
        memory.fail_after = null;
        try lease.restore(arena.allocator(), std.testing.io, memory.vars());
        try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 7, 0, 8, 0 }, memory.order.?);
        try std.testing.expect(memory.owned == null);
        for ([_][]const u8{ &.{ 2, 0, 1, 0 }, &.{ 1, 0 }, &.{ 7, 0, 1, 0, 2, 0 }, &.{ 1, 0, 2, 0, 0x49, 0x50 } }) |foreign|
            try std.testing.expectError(error.FirmwareBootOrderChanged, lease.restoredOrder(foreign));
    }
}

test "boot slot allocation skips existing entries, order references and BootNext" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vars: MemoryVariables = .{ .a = a, .order = &.{ 1, 0 }, .next = &.{ 2, 0 }, .occupied = &.{0}, .owned_slot = 3 };
    const lease = try Lease.captureAvailable(a, std.testing.io, vars.vars(), "a valid boot option");
    try std.testing.expectEqual(vars.owned_slot, lease.slot);
    try std.testing.expectEqual(0, vars.writes);
    try lease.arm(a, std.testing.io, vars.vars());
    try lease.restore(a, std.testing.io, vars.vars());
    try std.testing.expectEqualStrings("foreign boot option", (try vars.vars().get(a, std.testing.io, .{ .boot = 0 })).?);
}
