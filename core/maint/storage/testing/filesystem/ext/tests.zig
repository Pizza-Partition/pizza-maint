//! Host-only acceptance: independent mkfs/fsck tools, never production fallbacks.
const std = @import("std");
const storage = @import("storage");
const ext = storage.ext;
const REGISTRY = storage.filesystem.BUILTIN;
const model = storage.model;
const device = storage.device;
const Image = storage.testing.Image;
const IDENTITY = storage.testing.fixture.IDENTITY;

const command = storage.testing.tools.command;
const create = storage.testing.ext_tools.create;
const digest = storage.testing.tools.digest;

test "pinned libext2fs reads real ext2/3/4 variants and leaves every image byte unchanged" {
    const Case = struct { filesystem: model.Filesystem, block_size: []const u8 = "1024", features: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .filesystem = .ext2 },                                   .{ .filesystem = .ext3 },                              .{ .filesystem = .ext4 },
        .{ .filesystem = .ext4, .block_size = "4096" },             .{ .filesystem = .ext4, .features = "^64bit" },        .{ .filesystem = .ext4, .features = "^metadata_csum,uninit_bg" },
        .{ .filesystem = .ext4, .features = "metadata_csum_seed" }, .{ .filesystem = .ext4, .features = "sparse_super2" }, .{ .filesystem = .ext4, .features = "^has_journal" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-ext-acceptance-");
        defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
        const path = try create(a, io, home, case.filesystem, case.block_size, case.features);
        var image = try Image.open(io, path, IDENTITY, 512);
        defer image.close(io);
        const before = try digest(io, image.reader());
        const snapshot = try REGISTRY.query(a, io, image.reader());
        try std.testing.expectEqual(case.filesystem, snapshot.filesystem);
        try std.testing.expectEqual(64 * 1024 * 1024, snapshot.filesystem_bytes);
        try std.testing.expect(snapshot.clean);
        const allocation = ext.allocation(a, io, image.reader()) catch |err| {
            std.debug.print("ext case {s}/{s}/{s}: {t}\n", .{ @tagName(case.filesystem), case.block_size, case.features orelse "default", err });
            return err;
        };
        try std.testing.expect(allocation.free_blocks > 0 and allocation.free_blocks < allocation.blocks);
        if (case.filesystem == .ext4 and case.features == null and std.mem.eql(u8, case.block_size, "1024")) {
            try std.testing.expect(allocation.lazy_block_groups > 0);
            try std.testing.expect(allocation.lazy_inode_groups > 0);
        }
        const check = try REGISTRY.check(a, io, image.reader());
        try std.testing.expect(check.consistent);
        try std.testing.expect(check.scope == .allocation_metadata);
        try std.testing.expectEqualSlices(u8, &before, &try digest(io, image.reader()));
    }
    try std.testing.expectEqualStrings("1.47.4", ext.version());
}

test "ext query recognizes bigalloc while its allocation check remains explicitly unsupported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-ext-features-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const path = try create(a, io, home, .ext4, "4096", "bigalloc");
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const snapshot = try REGISTRY.query(a, io, image.reader());
    try std.testing.expectEqual(model.Filesystem.ext4, snapshot.filesystem);
    try std.testing.expectEqual(model.Support.unavailable, snapshot.capabilities[2].support);
    try std.testing.expect(snapshot.capabilities[2].reason == .feature_unsupported);
    try std.testing.expectError(error.NativeOperationUnavailable, REGISTRY.check(a, io, image.reader()));
}

test "libext2fs cannot bypass Reader with writes, discard or zeroout, and preserves read errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-ext-io-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const path = try create(a, io, home, .ext4, "1024", null);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const before = try digest(io, image.reader());
    {
        const session = try ext.Session.open(a, io, image.reader());
        defer session.close();
        const channel = session.fs.*.io;
        var buffer: [1024]u8 = @splat(0xAA);
        try std.testing.expectEqual(0, session.fs.*.flags & ext.c.EXT2_FLAG_RW);
        try std.testing.expectEqual(0, channel.*.manager.*.read_blk.?(channel, 1, -1024, &buffer));
        try std.testing.expectEqual(@as(u16, ext.c.EXT2_SUPER_MAGIC), std.mem.readInt(u16, buffer[0x38..0x3A], .little));
        try std.testing.expectEqual(ext.c.EXT2_ET_RO_FILSYS, channel.*.manager.*.write_blk.?(channel, 1, 1, &buffer));
        try std.testing.expectEqual(ext.c.EXT2_ET_RO_FILSYS, channel.*.manager.*.write_blk64.?(channel, 1, 1, &buffer));
        try std.testing.expectEqual(ext.c.EXT2_ET_RO_FILSYS, channel.*.manager.*.write_byte.?(channel, 1024, 1, &buffer));
        try std.testing.expectEqual(ext.c.EXT2_ET_RO_FILSYS, ext.c.io_channel_discard(channel, 1, 1));
        try std.testing.expectEqual(ext.c.EXT2_ET_RO_FILSYS, ext.c.io_channel_zeroout(channel, 1, 1));
    }
    try std.testing.expectEqualSlices(u8, &before, &try digest(io, image.reader()));
    const Failing = struct {
        reader: device.Reader,
        fn read(context: *const anyopaque, inner_io: std.Io, offset: u64, bytes: []u8) !void {
            const self: *const @This() = @ptrCast(@alignCast(context));
            if (offset >= 2048) return error.InjectedExtRead;
            return self.reader.readInto(inner_io, offset, bytes);
        }
    };
    const failing: Failing = .{ .reader = image.reader() };
    const reader: device.Reader = .{ .context = &failing, .target = image.target, .vtable = &.{ .read = Failing.read } };
    try std.testing.expectError(error.InjectedExtRead, ext.Session.open(a, io, reader));
}

test "ext rejects corrupt metadata, dirty state and out-of-bounds geometry without library writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-ext-corrupt-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const path = try create(a, io, home, .ext4, "1024", null);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    var super: [1024]u8 = undefined;
    try image.reader().readInto(io, 1024, &super);
    var changed = super;
    changed[0x78] ^= 1;
    try image.file.writePositionalAll(io, &changed, 1024);
    try std.testing.expectError(error.ExtSuperblockChecksum, REGISTRY.query(a, io, image.reader()));
    changed = super;
    std.mem.writeInt(u32, changed[4..8], 0xFFFFFFFF, .little);
    try image.file.writePositionalAll(io, &changed, 1024);
    try std.testing.expectError(error.ExtInvalidGeometry, REGISTRY.query(a, io, image.reader()));
    try image.file.writePositionalAll(io, &super, 1024);
    var checksum_byte: [1]u8 = undefined;
    try image.reader().readInto(io, 2048 + 0x1E, &checksum_byte);
    const changed_byte = [_]u8{checksum_byte[0] ^ 1};
    try image.file.writePositionalAll(io, &changed_byte, 2048 + 0x1E);
    try std.testing.expectError(error.ExtDescriptorChecksum, ext.allocation(a, io, image.reader()));
    try image.file.writePositionalAll(io, &checksum_byte, 2048 + 0x1E);
    const session = try ext.Session.open(a, io, image.reader());
    const bitmap = ext.c.ext2fs_block_bitmap_loc(session.fs, 0);
    const inode_bitmap = ext.c.ext2fs_inode_bitmap_loc(session.fs, 0);
    session.close();
    for ([_]u64{ bitmap, inode_bitmap }, 0..) |block, index| {
        var byte: [1]u8 = undefined;
        try image.reader().readInto(io, block * 1024, &byte);
        try image.file.writePositionalAll(io, &.{byte[0] ^ 1}, block * 1024);
        try std.testing.expectError(if (index == 0) error.ExtBlockBitmapChecksum else error.ExtInodeBitmapChecksum, ext.allocation(a, io, image.reader()));
        try image.file.writePositionalAll(io, &byte, block * 1024);
    }
    // Disable metadata checksums only on this deliberately damaged fixture, so
    // the dirty flag can be observed without masking it with a checksum error.
    changed = super;
    std.mem.writeInt(u32, changed[0x64..0x68], std.mem.readInt(u32, changed[0x64..0x68], .little) & ~@as(u32, 0x400), .little);
    std.mem.writeInt(u16, changed[0x3A..0x3C], 0, .little);
    try image.file.writePositionalAll(io, &changed, 1024);
    const snapshot = try REGISTRY.query(a, io, image.reader());
    try std.testing.expect(!snapshot.clean);
    const checked = try REGISTRY.check(a, io, image.reader());
    try std.testing.expect(!checked.consistent);
    try std.testing.expectEqualStrings("ExtRecoveryRequired", checked.detail);
}

test "ext allocation repair refuses untrusted bitmaps and healthy repair is a noop" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-ext-repair-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const path = try create(a, io, home, .ext4, "1024", null);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    const recovery_path = try std.fs.path.join(a, &.{ home, "recovery" });
    try std.Io.Dir.cwd().createDir(io, recovery_path, .default_dir);
    var directory = try std.Io.Dir.cwd().openDir(io, recovery_path, .{});
    defer directory.close(io);
    try std.testing.expect(!(try storage.testing.executor.execute(a, io, image.backend(), .{ .kind = .repair }, .{ .recovery_directory = directory })).changed);
    const session = try ext.Session.open(a, io, image.reader());
    const bitmap = ext.c.ext2fs_block_bitmap_loc(session.fs, 0);
    session.close();
    var byte: [1]u8 = undefined;
    try image.reader().readInto(io, bitmap * 1024, &byte);
    try image.file.writePositionalAll(io, &.{byte[0] ^ 1}, bitmap * 1024);
    const before = try digest(io, image.reader());
    try std.testing.expectError(error.ExtBlockBitmapChecksum, storage.testing.executor.execute(a, io, image.backend(), .{ .kind = .repair }, .{ .recovery_directory = directory }));
    try std.testing.expectEqualSlices(u8, &before, &try digest(io, image.reader()));
}

test "native shrink remaps a high directory inode and reseeds its checksums" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const home = try @import("utils").filesystem.createTemporaryDirectory(a, io, "pizza-ext-inode-relocation-");
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const path = try create(a, io, home, .ext4, "1024", null);
    var image = try Image.open(io, path, IDENTITY, 512);
    defer image.close(io);
    {
        var builder = storage.mutation.Builder.init(a, image.reader());
        defer builder.deinit();
        const session = try ext.Session.openStaged(a, io, &builder);
        try session.check(ext.c.ext2fs_read_bitmaps(session.fs));
        const high = session.fs.*.super.*.s_inodes_count * 3 / 4;
        try session.check(ext.c.ext2fs_mkdir(session.fs, ext.c.EXT2_ROOT_INO, high, "high_directory"));
        try session.check(ext.c.ext2fs_flush(session.fs));
        session.close();
        const changes = try builder.finish(io, false);
        for (changes.writes) |write| try image.file.writePositionalAll(io, write.content, write.range.offset);
        try image.file.sync(io);
    }
    try command(a, io, &.{ "e2fsck", "-fn", path });
    const p = try storage.service.filesystem(a, io, image.reader(), .{ .offset = 0, .length = image.target.capacity }, null, .{ .operation = .shrink, .bytes = 32 * 1024 * 1024 });
    const recovery_path = try std.fs.path.join(a, &.{ home, "recovery" });
    try std.Io.Dir.cwd().createDir(io, recovery_path, .default_dir);
    const directory = try std.Io.Dir.cwd().openDir(io, recovery_path, .{});
    defer directory.close(io);
    var files: storage.recovery_store.Files = .{ .directory = directory };
    defer files.deinit(io);
    try storage.program_executor.execute(a, io, image.backend(), files.store(), p.program, null, null);
    try std.testing.expect(try p.verify(a, io, image.reader()));
    try command(a, io, &.{ "e2fsck", "-fn", path });
    const session = try ext.Session.open(a, io, image.reader());
    defer session.close();
    var number: ext.c.ext2_ino_t = 0;
    try session.check(ext.c.ext2fs_namei(session.fs, ext.c.EXT2_ROOT_INO, ext.c.EXT2_ROOT_INO, "/high_directory", &number));
    try std.testing.expect(number > 0 and number < session.fs.*.super.*.s_inodes_count);
}
