//! FAT32 plans cover all FAT copies, boot/FSInfo records, directory references
//! and relocated payload bytes. No mutation reaches the underlying device.
const std = @import("std");
const format = @import("format.zig");
const scanner = @import("scan.zig");
const MutationBuilder = @import("../../mutation.zig").MutationBuilder;
const Reader = @import("../../device.zig").Reader;
const MutationSet = @import("../../mutation.zig").MutationSet;

pub fn prepareRepair(a: std.mem.Allocator, io: std.Io, reader: Reader, clusters: []const u32) !MutationSet {
    var overlay = MutationBuilder.init(a, reader);
    defer overlay.deinit();
    try repair(a, io, &overlay, clusters);
    _ = try scanner.load(a, io, overlay.reader(), false);
    return overlay.finish(io, false);
}

pub fn writeFat(a: std.mem.Allocator, io: std.Io, overlay: *MutationBuilder, g: format.Geometry, old: format.Geometry, fat: []const u8) !void {
    const previous = try a.alloc(u8, old.fatBytes());
    defer a.free(previous);
    const output = try a.alloc(u8, fat.len);
    defer a.free(output);
    for (0..g.copies) |copy| {
        // Reserved bits belong to the old logical FAT entry. After FAT growth,
        // the new physical address may contain user data, not an old entry.
        try overlay.originalReader().readInto(io, old.fatOffset(@intCast(copy)), previous);
        for (0..fat.len / 4) |index| {
            const reserved = if (index < previous.len / 4) format.get32(previous, index * 4) & ~format.MASK else 0;
            format.put32(output, index * 4, reserved | (format.get32(fat, index * 4) & format.MASK));
        }
        try overlay.stageWrite(io, g.fatOffset(@intCast(copy)), output);
    }
}
pub fn writeAux(a: std.mem.Allocator, io: std.Io, overlay: *MutationBuilder, g: format.Geometry, boot: []const u8, fat: []const u8) !void {
    var free: u32 = 0;
    var next: u32 = 0xffffffff;
    for (2..@as(usize, g.clusters) + 2) |index| if (format.get32(fat, index * 4) & format.MASK == 0) {
        free += 1;
        if (next == 0xffffffff) next = @intCast(index);
    };
    try overlay.stageWrite(io, 0, boot);
    if (g.backup != 0 and g.backup != 0xffff) try overlay.stageWrite(io, @as(u64, g.backup) * g.sector, boot);
    if (g.info != 0 and g.info != 0xffff) {
        const info = try a.alloc(u8, g.sector);
        defer a.free(info);
        format.makeInfo(info, free, next);
        try overlay.stageWrite(io, @as(u64, g.info) * g.sector, info);
        if (g.backup != 0 and g.backup != 0xffff and @as(u32, g.backup) + g.info < g.reserved)
            try overlay.stageWrite(io, (@as(u64, g.backup) + g.info) * g.sector, info);
    }
}

fn repair(a: std.mem.Allocator, io: std.Io, overlay: *MutationBuilder, clusters: []const u32) !void {
    var loaded = try scanner.load(a, io, overlay.reader(), true);
    if (loaded.graph.value(1) & 0x04000000 == 0) return error.FatSurfaceScanRequired;
    try salvage(a, io, overlay, &loaded.graph, clusters);
    loaded.graph.set(1, loaded.graph.value(1) | format.CLEAN_BITS);
    loaded.boot.bytes[65] &= ~@as(u8, 1);
    try writeFat(a, io, overlay, loaded.boot.geometry, loaded.boot.geometry, loaded.graph.fat);
    try writeAux(a, io, overlay, loaded.boot.geometry, loaded.boot.bytes, loaded.graph.fat);
}

/// Preserve every unreachable allocated cluster as root FSCKnnnn.CHK files.
/// Live cross-links/broken chains are rejected by scan; orphan merges into live
/// data or other orphan heads are rejected rather than discarding a reference.
const Salvage = struct { head: u32, bytes: u32 };
fn lostFiles(a: std.mem.Allocator, graph: *scanner.Graph) ![]Salvage {
    if (graph.orphans == 0) return &.{};
    const g = graph.geometry;
    const incoming = try a.alloc(u8, graph.owners.len);
    defer a.free(incoming);
    @memset(incoming, 0);
    for (2..graph.owners.len) |index| {
        const value = graph.value(@intCast(index));
        if (graph.owners[index] != 0 or value == 0 or value == format.BAD or format.terminal(value)) continue;
        if (value < 2 or value >= graph.owners.len) return error.FatInvalidCluster;
        if (graph.owners[value] != 0 or incoming[value] != 0) return error.FatCrossLink;
        incoming[value] = 1;
    }
    var files: std.ArrayList(Salvage) = .empty;
    const max_chain = std.math.maxInt(u32) / g.clusterBytes();
    for (0..2) |pass| {
        for (2..graph.owners.len) |index| {
            if (graph.owners[index] != 0 or graph.value(@intCast(index)) == 0 or graph.value(@intCast(index)) == format.BAD or (pass == 0 and incoming[index] != 0)) continue;
            var cluster: u32 = @intCast(index);
            var head = cluster;
            var count: u32 = 0;
            while (true) {
                if (cluster < 2 or cluster >= graph.owners.len) return error.FatInvalidCluster;
                if (graph.owners[cluster] != 0) return error.FatCrossLink;
                graph.owners[cluster] = std.math.maxInt(u32);
                count += 1;
                const next = graph.value(cluster);
                if (next == 0 or next == format.BAD or (!format.terminal(next) and (next < 2 or next >= graph.owners.len))) return error.FatInvalidCluster;
                const done = format.terminal(next) or next == index;
                if (done or count == max_chain) {
                    graph.set(cluster, format.EOC);
                    try files.append(a, .{ .head = head, .bytes = count * g.clusterBytes() });
                    if (done) break;
                    head = next;
                    count = 0;
                }
                cluster = next;
            }
        }
    }
    return files.toOwnedSlice(a);
}
pub fn repairBytes(a: std.mem.Allocator, io: std.Io, reader: Reader, graph: *const scanner.Graph) !u64 {
    if (graph.orphans == 0) return 0;
    var copy = graph.*;
    copy.fat = try a.dupe(u8, graph.fat);
    defer a.free(copy.fat);
    copy.owners = try a.dupe(u32, graph.owners);
    defer a.free(copy.owners);
    const files = try lostFiles(a, &copy);
    defer a.free(files);
    const buffer = try a.alloc(u8, graph.geometry.clusterBytes());
    defer a.free(buffer);
    var slots: u64 = 0;
    var ended = false;
    for (graph.objects.items[0].chain) |cluster| {
        try reader.readInto(io, try graph.geometry.offset(cluster), buffer);
        var at: usize = 0;
        while (at < buffer.len) : (at += 32) {
            if (buffer[at] == 0) ended = true;
            if (ended or buffer[at] == 0xe5) slots += 1;
        }
    }
    const missing = @as(u64, files.len) -| slots;
    return try std.math.divCeil(u64, missing, graph.geometry.clusterBytes() / 32) * graph.geometry.clusterBytes();
}
fn salvage(a: std.mem.Allocator, io: std.Io, overlay: *MutationBuilder, graph: *scanner.Graph, clusters: []const u32) !void {
    const files = try lostFiles(a, graph);
    defer a.free(files);
    if (files.len == 0) return;
    const g = graph.geometry;
    var names: std.AutoHashMap([11]u8, void) = .init(a);
    defer names.deinit();
    var slots: std.ArrayList(u64) = .empty;
    const buffer = try a.alloc(u8, g.clusterBytes());
    defer a.free(buffer);
    var ended = false;
    for (graph.objects.items[0].chain) |cluster| {
        const base = try g.offset(cluster);
        try overlay.reader().readInto(io, base, buffer);
        var at: usize = 0;
        while (at < buffer.len) : (at += 32) {
            if (buffer[at] == 0) ended = true;
            if (ended or buffer[at] == 0xe5) try slots.append(a, base + at) else if (buffer[at + 11] != 0x0f) try names.put(buffer[at..][0..11].*, {});
        }
    }
    // Ensure remaining slots after the old end marker cannot reveal stale data.
    if (ended) {
        var after_end = false;
        for (graph.objects.items[0].chain) |cluster| {
            const base = try g.offset(cluster);
            try overlay.reader().readInto(io, base, buffer);
            var changed = false;
            var at: usize = 0;
            while (at < buffer.len) : (at += 32) {
                if (buffer[at] == 0) after_end = true;
                if (after_end) {
                    @memset(buffer[at..][0..32], 0);
                    changed = true;
                }
            }
            if (changed) try overlay.stageWrite(io, base, buffer);
        }
    }
    var last = graph.objects.items[0].chain[graph.objects.items[0].chain.len - 1];
    var used: usize = 0;
    while (slots.items.len < files.len) {
        if (used == clusters.len) return error.MissingRepairPlacement;
        const cursor = clusters[used];
        used += 1;
        if (cursor < 2 or cursor >= g.clusters + 2 or graph.value(cursor) != 0) return error.InvalidRepairPlacement;
        graph.set(last, cursor);
        graph.set(cursor, format.EOC);
        graph.owners[cursor] = 1;
        const base = try g.offset(cursor);
        @memset(buffer, 0);
        try overlay.stageWrite(io, base, buffer);
        var at: usize = 0;
        while (at < buffer.len) : (at += 32) try slots.append(a, base + at);
        last = cursor;
    }
    var suffix: u32 = 0;
    for (files, slots.items[0..files.len]) |file, offset| {
        var name: [11]u8 = undefined;
        while (true) {
            if (suffix >= 10000) return error.FatRecoveryDirectoryFull;
            const formatted = try std.fmt.bufPrint(&name, "FSCK{d:0>4}CHK", .{suffix});
            std.debug.assert(formatted.len == 11);
            suffix += 1;
            if (!names.contains(name)) break;
        }
        var entry: [32]u8 = @splat(0);
        @memcpy(entry[0..11], &name);
        entry[11] = 0x20;
        format.setFirst(&entry, file.head);
        format.put32(&entry, 28, file.bytes);
        try overlay.stageWrite(io, offset, &entry);
    }
}

test "orphan salvage rejects chains entering bad, free, reserved or out-of-range clusters" {
    for ([_]u32{ 0, format.BAD, 1, 99 }) |end| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var geometry = std.mem.zeroes(format.Geometry);
        geometry.sector = 512;
        geometry.per_cluster = 1;
        geometry.clusters = 6;
        var fat: [32]u8 = @splat(0);
        var owners: [8]u32 = @splat(0);
        var graph: scanner.Graph = .{ .allocator = a, .geometry = geometry, .fat = &fat, .owners = &owners, .orphans = 1 };
        graph.set(2, 3);
        graph.set(3, end);
        try std.testing.expectError(error.FatInvalidCluster, lostFiles(a, &graph));
    }
}
