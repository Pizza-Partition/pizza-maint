//! Offline FAT32 file allocation proof. Uses the existing full ownership scan,
//! not FIEMAP guesses or a second filesystem implementation. The ESP must stay
//! unmounted and allocation chains must remain fixed throughout maintenance.
const std = @import("std");
const storage = @import("root.zig");
const fat = storage.fat32;
const format = fat.format;
pub const ShortName = [11]u8;
pub const Proof = struct {
    disk_identity: storage.model.Digest,
    esp: storage.model.Range,
    extents: []const storage.model.Range,
    bytes: u64,
    metadata_digest: storage.model.Digest,
    content_digest: storage.model.Digest,
    pub fn slice(self: Proof, a: std.mem.Allocator, offset: u64, length: u64, block: u32) ![]const storage.model.Range {
        try storage.recovery_store.validateBlockSize(block);
        if (length == 0 or offset % block != 0 or length % block != 0 or try std.math.add(u64, offset, length) > self.bytes) return error.InvalidAnchorSlice;
        var ranges: std.ArrayList(storage.model.Range) = .empty;
        var logical: u64 = 0;
        const end = offset + length;
        for (self.extents) |r| {
            const start = @max(offset, logical);
            const stop = @min(end, logical + r.length);
            if (start < stop) {
                const part: storage.model.Range = .{ .offset = r.offset + start - logical, .length = stop - start };
                try part.validate(try self.esp.end(), block);
                try ranges.append(a, part);
            }
            logical += r.length;
        }
        return ranges.toOwnedSlice(a);
    }
};
pub fn inspect(a: std.mem.Allocator, io: std.Io, disk: storage.device.Reader, esp: storage.model.Range, path: []const ShortName, block: u32) !Proof {
    try esp.validate(disk.target.capacity, disk.target.sector_size);
    try storage.recovery_store.validateBlockSize(block);
    if (block < disk.target.sector_size or path.len == 0 or path.len > 16) return error.InvalidAnchorPath;
    for (path) |name| {
        if (name[0] == ' ' or name[0] == '.') return error.InvalidAnchorPath;
        for (name) |ch| if (!(ch >= 'A' and ch <= 'Z') and !std.ascii.isDigit(ch) and ch != ' ' and ch != '_' and ch != '-') return error.InvalidAnchorPath;
    }
    var builder = storage.program.PhysicalProgramBuilder.init(a, disk);
    var view: storage.program.PhysicalProgramBuilder.View = .{ .builder = &builder, .version = 0, .range = esp };
    const reader = view.reader();
    const loaded = try fat.scan.load(a, io, reader, false);
    const g = loaded.graph.geometry;
    var metadata = std.crypto.hash.sha2.Sha256.init(.{});
    metadata.update("pizza-esp-anchor-v1");
    metadata.update(&disk.target.identity);
    var bounds: [16]u8 = undefined;
    std.mem.writeInt(u64, bounds[0..8], esp.offset, .little);
    std.mem.writeInt(u64, bounds[8..16], esp.length, .little);
    metadata.update(&bounds);
    metadata.update(loaded.boot.bytes);
    metadata.update(loaded.graph.fat);
    var object_index: usize = 0;
    for (path, 0..) |name, depth| {
        const parent = loaded.graph.objects.items[object_index];
        if (!parent.directory) return error.AnchorNotDirectory;
        var found: ?usize = null;
        for (loaded.graph.references.items) |ref| {
            if (ref.directory != object_index) continue;
            const at = try g.offset(parent.chain[ref.position / g.clusterBytes()]) + ref.position % g.clusterBytes();
            var entry: [32]u8 = undefined;
            try reader.readInto(io, at, &entry);
            if (!std.mem.eql(u8, &name, entry[0..11])) continue;
            if (found != null) return error.AmbiguousAnchorPath;
            const owner = loaded.graph.owners[ref.cluster];
            if (owner == 0) return error.UnownedAnchorCluster;
            found = owner - 1;
            metadata.update(&name);
            std.mem.writeInt(u64, bounds[0..8], at, .little);
            metadata.update(bounds[0..8]);
            metadata.update(&entry);
        }
        object_index = found orelse return error.AnchorFileNotFound;
        if (depth + 1 == path.len and loaded.graph.objects.items[object_index].directory) return error.AnchorNotFile;
    }
    const object = loaded.graph.objects.items[object_index];
    if (object.bytes == 0 or object.bytes % block != 0 or object.bytes != @as(u64, object.chain.len) * g.clusterBytes()) return error.AnchorNotFullyReserved;
    var extents: std.ArrayList(storage.model.Range) = .empty;
    var content = std.crypto.hash.sha2.Sha256.init(.{});
    const buffer = try a.alloc(u8, g.clusterBytes());
    defer a.free(buffer);
    for (object.chain) |cluster| {
        const local = try g.offset(cluster);
        try reader.readInto(io, local, buffer);
        content.update(buffer);
        const r: storage.model.Range = .{ .offset = esp.offset + local, .length = g.clusterBytes() };
        if (extents.items.len != 0 and try extents.items[extents.items.len - 1].end() == r.offset) extents.items[extents.items.len - 1].length += r.length else try extents.append(a, r);
    }
    for (extents.items) |r| try r.validate(disk.target.capacity, block);
    return .{ .disk_identity = disk.target.identity, .esp = esp, .extents = try extents.toOwnedSlice(a), .bytes = object.bytes, .metadata_digest = metadata.finalResult(), .content_digest = content.finalResult() };
}
pub fn revalidate(a: std.mem.Allocator, io: std.Io, disk: storage.device.Reader, path: []const ShortName, block: u32, expected: Proof, check_contents: bool) !Proof {
    const actual = try inspect(a, io, disk, expected.esp, path, block);
    if (!std.mem.eql(u8, &actual.disk_identity, &expected.disk_identity) or !std.mem.eql(u8, &actual.metadata_digest, &expected.metadata_digest) or actual.bytes != expected.bytes or actual.extents.len != expected.extents.len) return error.AnchorAllocationChanged;
    for (actual.extents, expected.extents) |x, y| if (!std.meta.eql(x, y)) return error.AnchorAllocationChanged;
    if (check_contents and !std.mem.eql(u8, &actual.content_digest, &expected.content_digest)) return error.AnchorContentsChanged;
    return actual;
}

test "anchor slices retain fragmented physical mapping and reject partial recovery blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: Proof = .{ .disk_identity = @splat(1), .esp = .{ .offset = 0, .length = 65536 }, .bytes = 16384, .metadata_digest = @splat(2), .content_digest = @splat(3), .extents = &.{ .{ .offset = 8192, .length = 8192 }, .{ .offset = 32768, .length = 8192 } } };
    const ranges = try p.slice(a, 4096, 8192, 4096);
    try std.testing.expectEqualSlices(storage.model.Range, &.{ .{ .offset = 12288, .length = 4096 }, .{ .offset = 32768, .length = 4096 } }, ranges);
    try std.testing.expectError(error.InvalidAnchorSlice, p.slice(a, 512, 8192, 4096));
    try std.testing.expectError(error.InvalidAnchorSlice, p.slice(a, 8192, 12288, 4096));
}

test "offline anchor proof follows a checked FAT chain and permits only content changes after initialization" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const zero: storage.device.Reader = .{ .context = &ZERO_CONTEXT, .target = .{ .identity = @splat(0x29), .capacity = 64 * 1024 * 1024, .sector_size = 512 }, .vtable = &.{ .read = readZero } };
    const area: storage.model.Range = .{ .offset = 0, .length = zero.target.capacity };
    const driver = try storage.filesystem.BUILTIN.get(.vfat);
    const created = try storage.service.filesystem(a, io, zero, area, driver, .{ .operation = .create, .bytes = area.length });
    var empty = try storage.program.Preview.init(zero, created.program);
    const loaded = try fat.scan.load(a, io, empty.reader(), false);
    const g = loaded.graph.geometry;
    var builder = storage.program.PhysicalProgramBuilder.init(a, empty.reader());
    var first: u32 = 3;
    while (try g.offset(first) % 4096 != 0) first += 1;
    const clusters = @max(@as(u32, 1), 16384 / g.clusterBytes());
    const length = clusters * g.clusterBytes();
    const allocation = try a.dupe(u8, loaded.graph.fat);
    for (0..clusters) |i| format.put32(allocation, (first + i) * 4, if (i + 1 == clusters) format.EOC else @intCast(first + i + 1));
    for (0..g.copies) |copy| try builder.write(io, .{ .offset = g.fatOffset(@intCast(copy)), .length = allocation.len }, allocation, false);
    const root = try a.alloc(u8, g.clusterBytes());
    try empty.reader().readInto(io, try g.offset(g.root), root);
    var at: usize = 0;
    while (root[at] != 0) : (at += 32) {}
    const entry = root[at..][0..32];
    @memcpy(entry[0..11], "ANCHOR  BIN");
    entry[11] = 0x20;
    format.setFirst(entry, first);
    format.put32(entry, 28, length);
    try builder.write(io, .{ .offset = try g.offset(g.root), .length = root.len }, root, false);
    const info = try a.alloc(u8, g.sector);
    format.makeInfo(info, loaded.graph.free - clusters, 0xffffffff);
    try builder.write(io, .{ .offset = @as(u64, g.info) * g.sector, .length = g.sector }, info, false);
    var reserved = try storage.program.Preview.init(empty.reader(), try builder.finish());
    const path: []const ShortName = &.{"ANCHOR  BIN".*};
    const proof = try inspect(a, io, reserved.reader(), area, path, 4096);
    try std.testing.expectEqual(length, proof.bytes);
    try std.testing.expectEqual(1, proof.extents.len);
    _ = try revalidate(a, io, reserved.reader(), path, 4096, proof, true);
    var initialized = storage.program.PhysicalProgramBuilder.init(a, reserved.reader());
    const header: [4096]u8 = @splat(0x64);
    try initialized.write(io, .{ .offset = proof.extents[0].offset, .length = header.len }, &header, false);
    var changed = try storage.program.Preview.init(reserved.reader(), try initialized.finish());
    _ = try revalidate(a, io, changed.reader(), path, 4096, proof, false);
    try std.testing.expectError(error.AnchorContentsChanged, revalidate(a, io, changed.reader(), path, 4096, proof, true));
}
const ZERO_CONTEXT: u8 = 0;
fn readZero(_: *const anyopaque, _: std.Io, _: u64, bytes: []u8) !void {
    @memset(bytes, 0);
}
