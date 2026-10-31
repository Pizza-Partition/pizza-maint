//! Bounded, read-only traversal of SINGLE/DUP mappings and allocation metadata.
//! File extents retain their logical addresses during physical chunk movement.
const std = @import("std");
const f = @import("format.zig");
const Reader = @import("../../device.zig").Reader;
pub const Stripe = struct { physical: u64 };
pub const Chunk = struct { logical: u64, length: u64, flags: u64, raw: []u8, stripes: []Stripe };
pub const Node = struct { logical: u64, bytes: []u8, entries: []f.Entry, children: []u64, first: ?f.Key };
pub const Tree = struct { owner: u64, root: u64, leaves: []u64 };
pub const Graph = struct {
    a: std.mem.Allocator,
    io: std.Io,
    reader: Reader,
    geometry: f.Geometry,
    chunks: []Chunk,
    nodes: std.AutoHashMap(u64, Node),
    trees: std.ArrayList(Tree) = .empty,
    fn mapping(g: *const Graph, logical: u64, size: u64) !*const Chunk {
        var lo: usize = 0;
        var hi = g.chunks.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (g.chunks[mid].logical <= logical) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return error.BtrfsUnmappedAddress;
        const chunk = &g.chunks[lo - 1];
        if (logical - chunk.logical > chunk.length or size > chunk.length - (logical - chunk.logical)) return error.BtrfsUnmappedAddress;
        return chunk;
    }
    pub fn physical(g: *const Graph, logical: u64, size: u64) !u64 {
        const chunk = try g.mapping(logical, size);
        return chunk.stripes[0].physical + logical - chunk.logical;
    }
    pub fn readLogical(g: *const Graph, logical: u64, bytes: []u8) !void {
        const chunk = try g.mapping(logical, bytes.len);
        try g.reader.readInto(g.io, chunk.stripes[0].physical + logical - chunk.logical, bytes);
        if (chunk.stripes.len == 2) {
            const other = try g.a.alloc(u8, bytes.len);
            defer g.a.free(other);
            try g.reader.readInto(g.io, chunk.stripes[1].physical + logical - chunk.logical, other);
            if (!std.mem.eql(u8, bytes, other)) return error.BtrfsReplicaMismatch;
        }
    }
    pub fn node(g: *Graph, logical: u64) !*Node {
        return g.nodes.getPtr(logical) orelse error.BtrfsInvalidNode;
    }
    pub fn tree(g: *Graph, owner: u64) !*Tree {
        for (g.trees.items) |*t| if (t.owner == owner) return t;
        return error.BtrfsMissingTree;
    }
    pub fn entries(g: *Graph, owner: u64) ![]f.Entry {
        var result: std.ArrayList(f.Entry) = .empty;
        for ((try g.tree(owner)).leaves) |logical| try result.appendSlice(g.a, (try g.node(logical)).entries);
        return result.toOwnedSlice(g.a);
    }
    fn walk(g: *Graph, logical: u64, generation: u64, level: u64, owner: u64, seen: *std.AutoHashMap(u64, void), leaves: *std.ArrayList(u64)) anyerror!?f.Key {
        if (logical % g.geometry.sector() != 0 or generation == 0 or generation > g.geometry.value("generation") or level >= 8) return error.BtrfsInvalidNode;
        if ((try seen.getOrPut(logical)).found_existing) return error.BtrfsTreeCycle;
        if (!g.nodes.contains(logical)) {
            if ((g.nodes.count() + 1) * g.geometry.nodeSize() > f.MAX_METADATA) return error.BtrfsResourceLimit;
            const b = try g.a.alloc(u8, g.geometry.nodeSize());
            try g.readLogical(logical, b);
            try f.checksum(g.geometry.value("csum_type"), b);
            if (f.get(f.HEADER, "bytenr", b) != logical or !std.mem.eql(u8, f.field(f.HEADER, "fsid", b), g.geometry.fsid())) return error.BtrfsInvalidNode;
            var leaf_entries: []f.Entry = &.{};
            var children: []u64 = &.{};
            const count = f.get(f.HEADER, "nritems", b);
            if (level == 0) leaf_entries = try f.items(g.a, b) else {
                if (count == 0 or count > (b.len - f.HEADER_SIZE) / @sizeOf(f.PTR)) return error.BtrfsInvalidNode;
                children = try g.a.alloc(u64, @intCast(count));
                var prev: ?f.Key = null;
                for (children, 0..) |*child, i| {
                    const p = b[f.HEADER_SIZE + i * @sizeOf(f.PTR) ..][0..@sizeOf(f.PTR)];
                    const key = f.Key.read(p);
                    if (prev) |v| if (!f.Key.less({}, v, key)) return error.BtrfsKeyOrder;
                    prev = key;
                    child.* = f.get(f.PTR, "blockptr", p);
                }
            }
            try g.nodes.put(logical, .{ .logical = logical, .bytes = b, .entries = leaf_entries, .children = children, .first = null });
        }
        // Recursive insertion can rehash the map; never retain its pointers.
        const n = (try g.node(logical)).*;
        const actual_owner = f.get(f.HEADER, "owner", n.bytes);
        const fs_tree = owner == 5 or (owner >= 256 and owner < (@as(u64, 1) << 63));
        if (f.get(f.HEADER, "generation", n.bytes) != generation or f.get(f.HEADER, "level", n.bytes) != level or (actual_owner != owner and !(fs_tree and (actual_owner == 5 or (actual_owner >= 256 and actual_owner < (@as(u64, 1) << 63)))))) return error.BtrfsParentMismatch;
        var first: ?f.Key = null;
        if (level == 0) {
            try leaves.append(g.a, logical);
            if (n.entries.len != 0) first = n.entries[0].key;
        } else {
            for (n.children, 0..) |child, i| {
                const p = n.bytes[f.HEADER_SIZE + i * @sizeOf(f.PTR) ..][0..@sizeOf(f.PTR)];
                const key = (try g.walk(child, f.get(f.PTR, "generation", p), level - 1, owner, seen, leaves)) orelse return error.BtrfsInvalidNode;
                if (!std.meta.eql(key, f.Key.read(p))) return error.BtrfsParentMismatch;
                if (i == 0) first = key;
            }
        }
        (try g.node(logical)).first = first;
        return first;
    }
    fn loadTree(g: *Graph, owner: u64, root: u64, generation: u64, level: u64) !void {
        for (g.trees.items) |t| if (t.owner == owner) return error.BtrfsDuplicateRoot;
        var seen: std.AutoHashMap(u64, void) = .init(g.a);
        defer seen.deinit();
        var leaves: std.ArrayList(u64) = .empty;
        _ = try g.walk(root, generation, level, owner, &seen, &leaves);
        var prev: ?f.Key = null;
        for (leaves.items) |logical| for ((try g.node(logical)).entries) |entry| {
            if (prev) |key| if (!f.Key.less({}, key, entry.key)) return error.BtrfsKeyOrder;
            prev = entry.key;
        };
        try g.trees.append(g.a, .{ .owner = owner, .root = root, .leaves = try leaves.toOwnedSlice(g.a) });
    }
};
pub fn parseChunk(a: std.mem.Allocator, g: *const f.Geometry, key: f.Key, raw: []const u8) !Chunk {
    if (key.object != 256 or key.kind != f.c.BTRFS_CHUNK_ITEM_KEY or raw.len < @sizeOf(f.CHUNK)) return error.BtrfsInvalidChunk;
    const count = f.get(f.CHUNK, "num_stripes", raw);
    const flags = f.get(f.CHUNK, "type", raw);
    const profile = flags & ~@as(u64, 7);
    if ((profile != 0 and profile != f.c.BTRFS_BLOCK_GROUP_DUP) or (profile == 0 and count != 1) or (profile != 0 and count != 2)) return error.BtrfsUnsupportedProfile;
    if (raw.len != @offsetOf(f.CHUNK, "stripe") + count * @sizeOf(f.STRIPE) or (flags & 7 != 1 and flags & 7 != 2 and flags & 7 != 4 and flags & 7 != 5) or (flags & 7 == 5 and g.value("incompat_flags") & 4 == 0) or f.get(f.CHUNK, "owner", raw) != 2 or f.get(f.CHUNK, "sector_size", raw) != g.sector() or f.get(f.CHUNK, "stripe_len", raw) != 65536) return error.BtrfsInvalidChunk;
    const length = f.get(f.CHUNK, "length", raw);
    if (length == 0 or length % g.sector() != 0 or key.offset % g.sector() != 0 or length > std.math.maxInt(u64) - key.offset) return error.BtrfsInvalidChunk;
    const stripes = try a.alloc(Stripe, @intCast(count));
    for (stripes, 0..) |*stripe, i| {
        const s = raw[@offsetOf(f.CHUNK, "stripe") + i * @sizeOf(f.STRIPE) ..][0..@sizeOf(f.STRIPE)];
        const offset = f.get(f.STRIPE, "offset", s);
        if (f.get(f.STRIPE, "devid", s) != f.get(f.DEV, "devid", g.dev()) or !std.mem.eql(u8, f.field(f.STRIPE, "dev_uuid", s), f.field(f.DEV, "uuid", g.dev())) or offset < 1024 * 1024 or offset % g.sector() != 0 or offset > g.bytes() or length > g.bytes() - offset) return error.BtrfsInvalidChunk;
        stripe.* = .{ .physical = offset };
    }
    return .{ .logical = key.offset, .length = length, .flags = flags, .raw = try a.dupe(u8, raw), .stripes = stripes };
}
pub fn load(a: std.mem.Allocator, io: std.Io, reader: Reader, mirrors: bool) !Graph {
    const geometry = try f.load(io, reader);
    if (geometry.sector() < reader.target.sector_size) return error.BtrfsUnsupportedSectorSize;
    try geometry.supported();
    if (mirrors) try f.checkMirrors(io, reader, &geometry);
    var initial: std.ArrayList(Chunk) = .empty;
    const array = f.field(f.SUPER, "sys_chunk_array", &geometry.super)[0..@intCast(geometry.value("sys_chunk_array_size"))];
    var at: usize = 0;
    while (at < array.len) {
        if (array.len - at < 17 + @sizeOf(f.CHUNK)) return error.BtrfsInvalidChunk;
        const raw = array[at + 17 ..];
        const size = @offsetOf(f.CHUNK, "stripe") + f.get(f.CHUNK, "num_stripes", raw) * @sizeOf(f.STRIPE);
        if (size > raw.len) return error.BtrfsInvalidChunk;
        const chunk = try parseChunk(a, &geometry, f.Key.read(array[at..]), raw[0..@intCast(size)]);
        if (chunk.flags & f.c.BTRFS_BLOCK_GROUP_SYSTEM == 0) return error.BtrfsInvalidChunk;
        try initial.append(a, chunk);
        at += 17 + @as(usize, @intCast(size));
    }
    var graph: Graph = .{ .a = a, .io = io, .reader = reader, .geometry = geometry, .chunks = initial.items, .nodes = .init(a) };
    try validateChunks(&graph);
    try graph.loadTree(3, geometry.value("chunk_root"), geometry.value("chunk_root_generation"), geometry.value("chunk_root_level"));
    var chunks: std.ArrayList(Chunk) = .empty;
    var devs: usize = 0;
    for (try graph.entries(3)) |entry| {
        if (entry.key.kind == f.c.BTRFS_CHUNK_ITEM_KEY) {
            if (chunks.items.len >= 4096) return error.BtrfsResourceLimit;
            try chunks.append(a, try parseChunk(a, &geometry, entry.key, entry.data));
        } else if (entry.key.kind == f.c.BTRFS_DEV_ITEM_KEY) {
            devs += 1;
            if (entry.key.object != 1 or entry.key.offset != f.get(f.DEV, "devid", geometry.dev()) or entry.data.len != @sizeOf(f.DEV) or !std.mem.eql(u8, entry.data, geometry.dev())) return error.BtrfsDeviceMismatch;
        } else return error.BtrfsInvalidChunk;
    }
    if (devs != 1) return error.BtrfsDeviceMismatch;
    var systems: usize = 0;
    for (chunks.items) |chunk| if (chunk.flags & f.c.BTRFS_BLOCK_GROUP_SYSTEM != 0) {
        systems += 1;
        var found = false;
        for (initial.items) |sys| if (sys.logical == chunk.logical and std.mem.eql(u8, sys.raw, chunk.raw)) {
            found = true;
            break;
        };
        if (!found) return error.BtrfsSystemChunkMismatch;
    };
    if (systems != initial.items.len) return error.BtrfsSystemChunkMismatch;
    graph.chunks = try chunks.toOwnedSlice(a);
    try validateChunks(&graph);
    try graph.loadTree(1, geometry.value("root"), geometry.value("generation"), geometry.value("root_level"));
    for (try graph.entries(1)) |entry| if (entry.key.kind == f.c.BTRFS_ROOT_ITEM_KEY) {
        if (entry.data.len < @offsetOf(f.ROOT, "generation_v2")) return error.BtrfsInvalidRoot;
        if (f.get(f.ROOT, "refs", entry.data) == 0 or f.get(f.ROOT, "drop_level", entry.data) != 0 or !std.mem.allEqual(u8, f.field(f.ROOT, "drop_progress", entry.data), 0)) return error.BtrfsDroppingRootUnsupported;
        try graph.loadTree(entry.key.object, f.get(f.ROOT, "bytenr", entry.data), f.get(f.ROOT, "generation", entry.data), f.get(f.ROOT, "level", entry.data));
    };
    try allocation(&graph);
    return graph;
}
fn validateChunks(g: *Graph) !void {
    if (g.chunks.len == 0 or g.chunks.len > 4096) return error.BtrfsResourceLimit;
    const Order = struct {
        fn chunk(_: void, x: Chunk, y: Chunk) bool {
            return x.logical < y.logical;
        }
        const Range = struct { begin: u64, end: u64 };
        fn range(_: void, x: Range, y: Range) bool {
            return x.begin < y.begin;
        }
    };
    std.mem.sort(Chunk, g.chunks, {}, Order.chunk);
    var ranges: std.ArrayList(Order.Range) = .empty;
    defer ranges.deinit(g.a);
    var physical_bytes: u64 = 0;
    var logical_end: u64 = 0;
    for (g.chunks) |chunk| {
        if (chunk.logical < logical_end) return error.BtrfsOverlappingChunks;
        logical_end = chunk.logical + chunk.length;
        for (chunk.stripes) |stripe| {
            physical_bytes = try std.math.add(u64, physical_bytes, chunk.length);
            try ranges.append(g.a, .{ .begin = stripe.physical, .end = stripe.physical + chunk.length });
        }
    }
    std.mem.sort(Order.Range, ranges.items, {}, Order.range);
    var physical_end: u64 = 0;
    for (ranges.items) |range| {
        if (range.begin < physical_end) return error.BtrfsOverlappingChunks;
        physical_end = range.end;
    }
    // Bootstrap has only system chunks; its total is checked after full load.
    if (g.trees.items.len != 0 and physical_bytes != f.get(f.DEV, "bytes_used", g.geometry.dev())) return error.BtrfsDeviceAccounting;
}
fn allocation(g: *Graph) !void {
    const chunk_uuid = f.field(f.HEADER, "chunk_tree_uuid", (try g.node(g.geometry.value("chunk_root"))).bytes);
    const dev_entries = try g.entries(4);
    var extents: usize = 0;
    for (dev_entries) |entry| if (entry.key.kind == f.c.BTRFS_DEV_EXTENT_KEY) {
        if (entry.data.len != @sizeOf(f.DEV_EXTENT) or entry.key.object != f.get(f.DEV, "devid", g.geometry.dev()) or f.get(f.DEV_EXTENT, "chunk_tree", entry.data) != 3 or f.get(f.DEV_EXTENT, "chunk_objectid", entry.data) != 256 or !std.mem.eql(u8, f.field(f.DEV_EXTENT, "chunk_tree_uuid", entry.data), chunk_uuid)) return error.BtrfsDeviceExtent;
        var found = false;
        for (g.chunks) |chunk| if (f.get(f.DEV_EXTENT, "chunk_offset", entry.data) == chunk.logical and f.get(f.DEV_EXTENT, "length", entry.data) == chunk.length) {
            for (chunk.stripes) |s| if (s.physical == entry.key.offset) {
                found = true;
            };
        };
        if (!found) return error.BtrfsDeviceExtent;
        extents += 1;
    };
    var stripe_count: usize = 0;
    for (g.chunks) |chunk| stripe_count += chunk.stripes.len;
    if (extents != stripe_count) return error.BtrfsDeviceExtent;
    const entries = try g.entries(2);
    const used = try g.a.alloc(u64, g.chunks.len);
    @memset(used, 0);
    var allocations: std.AutoHashMap(u64, f.Entry) = .init(g.a);
    defer allocations.deinit();
    var previous_end: u64 = 0;
    for (entries) |entry| {
        if (entry.key.kind != f.c.BTRFS_EXTENT_ITEM_KEY and entry.key.kind != f.c.BTRFS_METADATA_ITEM_KEY) continue;
        const length: u64 = if (entry.key.kind == f.c.BTRFS_METADATA_ITEM_KEY) g.geometry.nodeSize() else entry.key.offset;
        if (entry.data.len < @sizeOf(f.c.struct_btrfs_extent_item) or f.get(f.c.struct_btrfs_extent_item, "refs", entry.data) == 0 or entry.key.object < previous_end or entry.key.object % g.geometry.sector() != 0 or length == 0 or length % g.geometry.sector() != 0) return error.BtrfsExtentAccounting;
        const flags = f.get(f.c.struct_btrfs_extent_item, "flags", entry.data);
        if ((flags & 3 != 1 and flags & 3 != 2) or (entry.key.kind == f.c.BTRFS_METADATA_ITEM_KEY and flags & 3 != 2) or f.get(f.c.struct_btrfs_extent_item, "generation", entry.data) > g.geometry.value("generation")) return error.BtrfsExtentAccounting;
        const physical = try g.physical(entry.key.object, length);
        _ = physical;
        for (g.chunks, 0..) |chunk, i| if (entry.key.object >= chunk.logical and entry.key.object - chunk.logical < chunk.length) {
            used[i] += length;
            break;
        };
        try allocations.put(entry.key.object, entry);
        previous_end = try std.math.add(u64, entry.key.object, length);
    }
    const bg_entries = if (g.geometry.value("compat_ro_flags") & 8 != 0) try g.entries(11) else entries;
    var total: u64 = 0;
    for (g.chunks, used) |chunk, bytes| {
        var found = false;
        for (bg_entries) |entry| if (entry.key.object == chunk.logical and entry.key.kind == f.c.BTRFS_BLOCK_GROUP_ITEM_KEY and entry.key.offset == chunk.length) {
            const T = f.c.struct_btrfs_block_group_item;
            if (entry.data.len != @sizeOf(T) or f.get(T, "used", entry.data) != bytes or f.get(T, "flags", entry.data) != chunk.flags or f.get(T, "chunk_objectid", entry.data) != 256) return error.BtrfsBlockGroupAccounting;
            found = true;
        };
        if (!found) return error.BtrfsBlockGroupAccounting;
        total += bytes;
    }
    if (total != g.geometry.value("bytes_used")) return error.BtrfsExtentAccounting;
    var iterator = g.nodes.valueIterator();
    while (iterator.next()) |node| {
        if (!std.mem.eql(u8, f.field(f.HEADER, "chunk_tree_uuid", node.bytes), chunk_uuid)) return error.BtrfsDeviceMismatch;
        const entry = allocations.get(node.logical) orelse return error.BtrfsUnallocatedNode;
        const correct_length = if (entry.key.kind == f.c.BTRFS_METADATA_ITEM_KEY) entry.key.offset == f.get(f.HEADER, "level", node.bytes) else entry.key.offset == g.geometry.nodeSize();
        if (!correct_length or f.get(f.c.struct_btrfs_extent_item, "flags", entry.data) & 3 != 2 or f.get(f.c.struct_btrfs_extent_item, "generation", entry.data) != f.get(f.HEADER, "generation", node.bytes)) return error.BtrfsUnallocatedNode;
    }
}
