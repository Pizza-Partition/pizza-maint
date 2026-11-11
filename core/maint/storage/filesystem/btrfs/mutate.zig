const std = @import("std");
const format = @import("format.zig");
const scan = @import("scan.zig");
const MutationBuilder = @import("../../mutation.zig").MutationBuilder;
const model = @import("../../model.zig");
const Reader = @import("../../device.zig").Reader;
const MutationSet = @import("../../mutation.zig").MutationSet;
pub fn prepare(comptime operation: model.Kind, a: std.mem.Allocator, io: std.Io, reader: Reader, _: model.Snapshot, _: u64) !MutationSet {
    var overlay = MutationBuilder.init(a, reader);
    defer overlay.deinit();
    switch (operation) {
        .repair => {
            const graph = try scan.load(a, io, overlay.reader(), false);
            // A valid, conflicting backup is evidence of ambiguity, not a
            // license to overwrite it with whichever primary we read first.
            for (format.MIRRORS[1..]) |position| {
                if (position + 4096 > graph.geometry.bytes()) continue;
                var b: [4096]u8 = undefined;
                try overlay.reader().readInto(io, position, &b);
                if (format.parse(b, reader.target.capacity, position)) |other| {
                    var normalized = other.super;
                    format.put(format.SUPER, "bytenr", &normalized, format.MIRRORS[0]);
                    try format.seal(graph.geometry.value("csum_type"), &normalized);
                    if (!std.mem.eql(u8, &normalized, &graph.geometry.super)) return error.BtrfsAmbiguousSuper;
                } else |_| {}
            }
            try writeSupers(io, &overlay, graph.geometry.super, graph.geometry.bytes());
        },
        else => return error.ReadOnlyOperationHasNoMutationPlan,
    }
    const graph = try scan.load(a, io, overlay.reader(), true);
    const expected = switch (operation) {
        .create => reader.target.capacity,
        else => graph.geometry.bytes(),
    };
    if (graph.geometry.bytes() != expected) return error.BtrfsWrongSize;
    return overlay.finish(io, operation == .create);
}
pub fn writeSupers(io: std.Io, overlay: *MutationBuilder, super: [4096]u8, previous_bytes: u64) !void {
    const bytes = format.get(format.SUPER, "total_bytes", &super);
    for (format.MIRRORS) |position| {
        if (position + 4096 > bytes) {
            if (position + 4096 <= previous_bytes) try overlay.stageWrite(io, position, &@as([4096]u8, @splat(0)));
            continue;
        }
        var b = super;
        format.put(format.SUPER, "bytenr", &b, position);
        try format.seal(format.get(format.SUPER, "csum_type", &b), &b);
        try overlay.stageWrite(io, position, &b);
    }
}
/// Repack device extents after key changes, preserving tree topology and all
/// item payloads. A plan that would need a B-tree split is rejected pre-write.
pub fn rewrite(a: std.mem.Allocator, io: std.Io, overlay: *MutationBuilder, g: *scan.Graph, bytes: u64) !void {
    _ = a;
    const old_bytes = g.geometry.bytes();
    const dev_entries = try g.entries(4);
    std.mem.sort(format.Entry, dev_entries, {}, format.Entry.less);
    var at: usize = 0;
    for ((try g.tree(4)).leaves) |logical| {
        const node = try g.node(logical);
        const count = node.entries.len;
        @memcpy(node.entries, dev_entries[at..][0..count]);
        at += count;
        try format.pack(node.bytes, node.entries);
        node.first = if (count != 0) node.entries[0].key else null;
    }
    try separator(g, (try g.tree(4)).root);
    format.put(format.SUPER, "total_bytes", &g.geometry.super, bytes);
    format.put(format.DEV, "total_bytes", format.field(format.SUPER, "dev_item", &g.geometry.super), bytes);
    @memset(format.field(format.SUPER, "super_roots", &g.geometry.super), 0);
    // Old space-cache inodes refer to logical allocation, unchanged here.
    for ((try g.tree(3)).leaves) |logical| {
        const node = try g.node(logical);
        for (node.entries) |*entry| {
            if (entry.key.kind == format.c_api.BTRFS_DEV_ITEM_KEY) @memcpy(entry.data, g.geometry.dev());
            if (entry.key.kind == format.c_api.BTRFS_CHUNK_ITEM_KEY) for (g.chunks) |chunk| if (chunk.logical == entry.key.offset) {
                @memcpy(entry.data, chunk.raw);
            };
        }
        try format.pack(node.bytes, node.entries);
    }
    const sys = format.field(format.SUPER, "sys_chunk_array", &g.geometry.super);
    @memset(sys, 0);
    var size: usize = 0;
    for (g.chunks) |chunk| if (chunk.flags & format.c_api.BTRFS_BLOCK_GROUP_SYSTEM != 0) {
        if (size + 17 + chunk.raw.len > sys.len) return error.BtrfsResourceLimit;
        (format.Key{ .object = 256, .kind = format.c_api.BTRFS_CHUNK_ITEM_KEY, .offset = chunk.logical }).write(sys[size..]);
        @memcpy(sys[size + 17 ..][0..chunk.raw.len], chunk.raw);
        size += 17 + chunk.raw.len;
    };
    format.put(format.SUPER, "sys_chunk_array_size", &g.geometry.super, size);
    var iterator = g.nodes.valueIterator();
    while (iterator.next()) |node| {
        try format.seal(g.geometry.value("csum_type"), node.bytes);
        for (g.chunks) |chunk| {
            if (node.logical < chunk.logical or node.logical - chunk.logical >= chunk.length) continue;
            for (chunk.stripes) |stripe| try overlay.stageWrite(io, stripe.physical + node.logical - chunk.logical, node.bytes);
        }
    }
    try writeSupers(io, overlay, g.geometry.super, old_bytes);
}
fn separator(g: *scan.Graph, logical: u64) anyerror!void {
    const node = try g.node(logical);
    if (node.children.len == 0) return;
    for (node.children, 0..) |child, i| {
        try separator(g, child);
        const key = (try g.node(child)).first orelse return error.BtrfsInvalidNode;
        key.write(node.bytes[format.HEADER_SIZE + i * @sizeOf(format.PTR) ..]);
        if (i == 0) node.first = key;
    }
}
