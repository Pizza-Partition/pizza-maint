const std = @import("std");
const storage = @import("storage");
const Raw = storage.recovery_store.RawCapsule;
const IO = std.testing.io;
const Machine = storage.testing.crash_model.Machine;

test "same-disk capsule survives reopen and undo; rejects overlapping writes before preparation" {
    for ([_]u32{ 512, 4096 }) |sector| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const original = try a.alloc(u8, 256 * 1024);
        @memset(original, 0x23);
        const target: storage.model.Target = .{ .identity = @splat(0x73), .capacity = original.len, .sector_size = sector };
        var m = try Machine.init(a, target, original);
        var b = storage.program.Builder.init(a, m.disk().reader());
        const replacement = try a.alloc(u8, sector);
        @memset(replacement, 0x91);
        try b.write(IO, .{ .offset = 0, .length = sector }, replacement, true);
        const p = try b.finish();
        const r = try storage.program_executor.reservation(a, p, 4096, true);
        const desc: storage.recovery_store.CapsuleDescriptor = .{ .session = @splat(0x51), .block_size = 4096, .extents = &.{.{ .offset = 65536, .length = 196608 }} };
        var capsule = try Raw.format(a, IO, m.disk(), desc, Raw.limitsFor(r, 4096));
        try storage.program_executor.executeDeferred(a, IO, m.disk(), capsule.store(), p, &.{}, null, null);
        try m.powerLoss(27, .garbage);
        capsule = try Raw.open(a, IO, m.disk(), desc);
        try std.testing.expectEqual(.verified, try storage.program_executor.recover(a, IO, m.disk(), capsule.store(), null));
        try std.testing.expectEqual(.rolled_back, try storage.program_executor.undo(a, IO, m.disk(), capsule.store(), null));
        try std.testing.expectEqualSlices(u8, original[0..65536], m.live[0..65536]);
        var overlap = storage.program.Builder.init(a, m.disk().reader());
        try overlap.write(IO, .{ .offset = 65536, .length = sector }, replacement, false);
        try std.testing.expectError(error.ProgramOverwritesRecovery, capsule.protects(try overlap.finish()));
        var wrong = desc;
        wrong.session = @splat(0x62);
        try std.testing.expectError(error.InvalidCapsuleHeaders, Raw.open(a, IO, m.disk(), wrong));
    }
}

test "capsule capacity and extent overlap are checked before initialization" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes: [16384]u8 = @splat(0);
    var m = try Machine.init(a, .{ .identity = @splat(1), .capacity = bytes.len, .sector_size = 512 }, &bytes);
    const limits: [storage.recovery_store.RECORD_COUNT]u64 = @splat(4096);
    const desc: storage.recovery_store.CapsuleDescriptor = .{ .session = @splat(1), .block_size = 4096, .extents = &.{.{ .offset = 0, .length = 16384 }} };
    try std.testing.expectError(error.CapsuleTooSmall, Raw.format(a, IO, m.disk(), desc, limits));
    var overlap = desc;
    overlap.extents = &.{ .{ .offset = 0, .length = 8192 }, .{ .offset = 4096, .length = 8192 } };
    try std.testing.expectError(error.OverlappingCapsuleExtents, Raw.format(a, IO, m.disk(), overlap, limits));
    try std.testing.expectEqualSlices(u8, &bytes, m.live);
}
