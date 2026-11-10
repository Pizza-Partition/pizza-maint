//! ext2/3/4 parsing and allocation checks behind the semantic driver.
const std = @import("std");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
const bridge = @import("io.zig");
pub const c_api = bridge.c_api;
pub const Session = bridge.Session;

pub const semantic = @import("semantic.zig");
pub const OPERATIONS = [_]model.Capability{
    .{ .operation = .create, .support = .validated, .reason = .available },
    .{ .operation = .query, .support = .validated, .reason = .available },
    .{ .operation = .check, .support = .validated, .reason = .available, .scope = .allocation_metadata },
    .{ .operation = .repair, .support = .validated, .reason = .available, .scope = .allocation_metadata },
    .{ .operation = .grow, .support = .validated, .reason = .available },
    .{ .operation = .shrink, .support = .validated, .reason = .available },
    .{ .operation = .copy, .support = .validated, .reason = .available },
};

pub const Allocation = struct {
    groups: u32,
    blocks: u64,
    free_blocks: u64,
    inodes: u32,
    free_inodes: u64,
    lazy_block_groups: u32 = 0,
    lazy_inode_groups: u32 = 0,
};
// libext2fs materializes bitmaps. Cap this stage before allocating them.
pub const MAX_SCAN_BLOCKS = 512 * 1024 * 1024;
pub const MAX_SCAN_INODES = 128 * 1024 * 1024;

pub fn version() []const u8 {
    var text: [*c]const u8 = null;
    _ = c_api.ext2fs_get_library_version(&text, null);
    return std.mem.span(text);
}

fn expected(context: *const anyopaque) model.Filesystem {
    return @as(*const model.Filesystem, @ptrCast(@alignCast(context))).*;
}

pub fn probe(context: *const anyopaque, io: std.Io, reader: device.Reader) !bool {
    if (reader.target.capacity < 2048) return false;
    var raw: [1024]u8 = undefined;
    try reader.readInto(io, 1024, &raw);
    return identify(&raw) == expected(context);
}

pub fn identify(raw: *const [1024]u8) ?model.Filesystem {
    if (std.mem.readInt(u16, raw[0x38..0x3A], .little) != c_api.EXT2_SUPER_MAGIC) return null;
    const compat = std.mem.readInt(u32, raw[0x5C..0x60], .little);
    const incompat = std.mem.readInt(u32, raw[0x60..0x64], .little);
    const ro = std.mem.readInt(u32, raw[0x64..0x68], .little);
    return classify(std.mem.readInt(u32, raw[0x4C..0x50], .little), compat, incompat, ro);
}

fn classify(revision: u32, compat: u32, incompat: u32, ro: u32) ?model.Filesystem {
    if (revision == 0) return .ext2;
    if (incompat & c_api.EXT3_FEATURE_INCOMPAT_JOURNAL_DEV != 0) return null;
    // A feature-compatible ext4 volume can legitimately identify as ext2/3.
    if (incompat & ~@as(u32, 0x2 | 0x4 | 0x10) != 0 or ro & ~@as(u32, 7) != 0 or compat & ~@as(u32, 0x3F) != 0) return .ext4;
    return if (compat & c_api.EXT3_FEATURE_COMPAT_HAS_JOURNAL != 0) .ext3 else .ext2;
}

pub fn clean(sb: *const c_api.struct_ext2_super_block) bool {
    return sb.s_state == c_api.EXT2_VALID_FS and sb.s_feature_incompat & c_api.EXT3_FEATURE_INCOMPAT_RECOVER == 0 and
        sb.s_last_orphan == 0 and sb.s_feature_ro_compat & c_api.EXT4_FEATURE_RO_COMPAT_ORPHAN_PRESENT == 0;
}

pub fn supported(sb: *const c_api.struct_ext2_super_block) bool {
    // Scope is allocation metadata, not inode/directory/journal verification.
    return sb.s_feature_compat & ~@as(u32, 0x4 | 0x8 | 0x10 | 0x20 | 0x200 | 0x1000) == 0 and
        sb.s_feature_incompat & ~@as(u32, 0x2 | 0x4 | 0x10 | 0x40 | 0x80 | 0x200 | 0x2000) == 0 and
        sb.s_feature_ro_compat & ~@as(u32, 0x1 | 0x2 | 0x8 | 0x10 | 0x20 | 0x40 | 0x400 | 0x10000) == 0;
}

pub fn inspect(context: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Snapshot {
    const session = try Session.open(a, io, reader);
    defer session.close();
    const fs = session.fs;
    const sb = &fs.*.super.*;
    if (classify(sb.s_rev_level, sb.s_feature_compat, sb.s_feature_incompat, sb.s_feature_ro_compat) != expected(context)) return error.FilesystemIdentityMismatch;
    const caps = try a.dupe(model.Capability, &OPERATIONS);
    if (!supported(sb)) {
        caps[2].support = .unavailable;
        caps[2].reason = .feature_unsupported;
    } else if (c_api.ext2fs_blocks_count(fs.*.super) > MAX_SCAN_BLOCKS or sb.s_inodes_count > MAX_SCAN_INODES) {
        caps[2].support = .unavailable;
        caps[2].reason = .resource_limit;
    }
    for (caps[3..]) |*entry| {
        if (caps[2].support != .validated) {
            entry.support = caps[2].support;
            entry.reason = caps[2].reason;
        } else if (!clean(sb)) {
            entry.support = .unavailable;
            entry.reason = .recovery_unvalidated;
        } else if ((entry.operation == .grow or entry.operation == .shrink) and sb.s_feature_compat & c_api.EXT4_FEATURE_COMPAT_SPARSE_SUPER2 != 0) {
            entry.support = .unavailable;
            entry.reason = .feature_unsupported;
        }
    }
    const features = try a.alloc([]const u8, 3);
    features[0] = try a.print("compat=0x{x}", .{sb.s_feature_compat});
    features[1] = try a.print("incompat=0x{x}", .{sb.s_feature_incompat});
    features[2] = try a.print("ro_compat=0x{x}", .{sb.s_feature_ro_compat});
    const total_blocks = c_api.ext2fs_blocks_count(fs.*.super);
    const free_blocks = c_api.ext2fs_free_blocks_count(fs.*.super);
    if (free_blocks > total_blocks) return error.ExtCounterMismatch;
    return .{ .usage = .{ .used_bytes = (total_blocks - free_blocks) * fs.*.blocksize, .free_bytes = free_blocks * fs.*.blocksize }, .filesystem = expected(context), .target = reader.target, .generation = 0, .block_size = fs.*.blocksize, .filesystem_bytes = c_api.ext2fs_blocks_count(fs.*.super) * fs.*.blocksize, .clean = clean(sb), .features = features, .capabilities = caps };
}

pub fn allocation(a: std.mem.Allocator, io: std.Io, reader: device.Reader) !Allocation {
    const session = try Session.open(a, io, reader);
    defer session.close();
    const fs = session.fs;
    const sb = &fs.*.super.*;
    if (!supported(sb)) return error.ExtUnsupportedFeature;
    if (!clean(sb)) return error.ExtRecoveryRequired;
    const blocks = c_api.ext2fs_blocks_count(fs.*.super);
    if (blocks > MAX_SCAN_BLOCKS or sb.s_inodes_count > MAX_SCAN_INODES) return error.ExtScanBudgetExceeded;
    try session.check(c_api.ext2fs_check_desc(fs));
    for (0..fs.*.group_desc_count) |index| {
        if (c_api.ext2fs_group_desc_csum_verify(fs, @intCast(index)) == 0) return error.ExtDescriptorChecksum;
    }
    // The library verifies bitmap checksums and synthesizes lazy/uninitialized
    // bitmaps with their reserved metadata, rather than treating them as zeros.
    try session.check(c_api.ext2fs_read_bitmaps(fs));
    if (fs.*.flags & (c_api.EXT2_FLAG_BBITMAP_TAIL_PROBLEM | c_api.EXT2_FLAG_IBITMAP_TAIL_PROBLEM) != 0) return error.ExtBitmapPadding;
    const buffer = try a.alloc(u8, fs.*.blocksize);
    defer a.free(buffer);
    var result: Allocation = .{ .groups = fs.*.group_desc_count, .blocks = blocks, .free_blocks = 0, .inodes = sb.s_inodes_count, .free_inodes = 0 };
    for (0..fs.*.group_desc_count) |index| {
        const group: c_api.dgrp_t = @intCast(index);
        const count = c_api.ext2fs_group_blocks_count(fs, group);
        if (count <= 0 or count > fs.*.blocksize * 8) return error.ExtInvalidGeometry;
        try session.check(c_api.ext2fs_get_block_bitmap_range2(fs.*.block_map, c_api.ext2fs_group_first_block2(fs, group), @intCast(count), buffer.ptr));
        const free_blocks = countFree(buffer, @intCast(count));
        if (free_blocks != c_api.ext2fs_bg_free_blocks_count(fs, group)) return error.ExtCounterMismatch;
        const inode_start = @as(u64, group) * sb.s_inodes_per_group;
        if (inode_start >= sb.s_inodes_count) return error.ExtInvalidGeometry;
        const inode_count: usize = @intCast(@min(sb.s_inodes_per_group, sb.s_inodes_count - inode_start));
        if (inode_count > buffer.len * 8) return error.ExtInvalidGeometry;
        try session.check(c_api.ext2fs_get_inode_bitmap_range2(fs.*.inode_map, inode_start + 1, inode_count, buffer.ptr));
        const free_inodes = countFree(buffer, inode_count);
        if (free_inodes != c_api.ext2fs_bg_free_inodes_count(fs, group)) return error.ExtCounterMismatch;
        result.free_blocks += free_blocks;
        result.free_inodes += free_inodes;
        const flags = c_api.ext2fs_bg_flags(fs, group);
        if (flags & c_api.EXT2_BG_BLOCK_UNINIT != 0) result.lazy_block_groups += 1;
        if (flags & c_api.EXT2_BG_INODE_UNINIT != 0) result.lazy_inode_groups += 1;
    }
    if (result.free_blocks != c_api.ext2fs_free_blocks_count(fs.*.super) or result.free_inodes != sb.s_free_inodes_count) return error.ExtCounterMismatch;
    return result;
}

pub fn countFree(bytes: []const u8, count: usize) u64 {
    var used: u64 = 0;
    for (bytes[0 .. count / 8]) |byte| used += @popCount(byte);
    if (count % 8 != 0) used += @popCount(bytes[count / 8] & (@as(u8, 0xFF) >> @as(u3, @intCast(8 - count % 8))));
    return count - used;
}

pub fn check(_: *const anyopaque, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Check {
    const result = allocation(a, io, reader) catch |err| switch (err) {
        error.ExtRecoveryRequired, error.ExtInvalidGeometry, error.ExtInvalidDescriptor, error.ExtDescriptorChecksum, error.ExtSuperblockChecksum, error.ExtBlockBitmapChecksum, error.ExtInodeBitmapChecksum, error.ExtBitmapPadding, error.ExtCounterMismatch => return .{ .consistent = false, .scope = .allocation_metadata, .detail = @errorName(err) },
        else => return err,
    };
    return .{ .consistent = true, .scope = .allocation_metadata, .detail = try a.print("ext allocation metadata: {d} groups, {d} free blocks, {d} free inodes; inode/directory/journal checks not performed", .{ result.groups, result.free_blocks, result.free_inodes }) };
}
