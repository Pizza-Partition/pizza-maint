//! Library algorithms operate on an isolated overlay. User data relocation
//! becomes a movement DAG; only metadata changes become byte patches.
const std = @import("std");
const model = @import("../../model.zig");
const device = @import("../../device.zig");
const MutationSet = @import("../../mutation.zig").MutationSet;
const MutationBuilder = @import("../../mutation.zig").MutationBuilder;
const ext = @import("root.zig");
const Session = @import("io.zig").Session;
const c_api = ext.c_api;

pub fn prepare(comptime operation: model.Kind, a: std.mem.Allocator, io: std.Io, reader: device.Reader, snapshot: model.Snapshot, _: u64) !MutationSet {
    var overlay = MutationBuilder.init(a, reader);
    defer overlay.deinit();
    switch (operation) {
        .repair => try repair(a, io, &overlay),
        else => return error.ReadOnlyOperationHasNoMutationPlan,
    }
    if (!try ext.probe(&snapshot.filesystem, io, overlay.reader())) return error.FilesystemProgramMismatch;
    // Reopen from staged bytes: stale library caches cannot satisfy verification.
    _ = try ext.allocation(a, io, overlay.reader());
    return overlay.finish(io, operation == .create);
}

/// Conservative repair: only allocation summary counters, never inferred file
/// ownership, discarded inodes, checksum bypasses or journal replay.
fn repair(a: std.mem.Allocator, io: std.Io, overlay: *MutationBuilder) !void {
    const session = try Session.openStaged(a, io, overlay);
    defer session.close();
    const fs = session.fs;
    ext.loadBitmaps(session) catch |err| return switch (err) {
        error.ExtUnsupportedFeature => error.ExtRecoveryRequired,
        else => err,
    };
    const buffer = try a.alloc(u8, fs.*.blocksize);
    defer a.free(buffer);
    var free_blocks: u64 = 0;
    var free_inodes: u64 = 0;
    var changed = false;
    for (0..fs.*.group_desc_count) |index| {
        const group: c_api.dgrp_t = @intCast(index);
        const counts = try ext.freeCounts(session, group, buffer);
        const block_count = counts.blocks;
        const inode_count = counts.inodes;
        if (block_count != c_api.ext2fs_bg_free_blocks_count(fs, group) or inode_count != c_api.ext2fs_bg_free_inodes_count(fs, group)) {
            c_api.ext2fs_bg_free_blocks_count_set(fs, group, block_count);
            c_api.ext2fs_bg_free_inodes_count_set(fs, group, inode_count);
            c_api.ext2fs_group_desc_csum_set(fs, group);
            changed = true;
        }
        free_blocks += block_count;
        free_inodes += inode_count;
    }
    if (free_blocks != c_api.ext2fs_free_blocks_count(fs.*.super) or free_inodes != fs.*.super.*.s_free_inodes_count) changed = true;
    if (!changed) return;
    c_api.ext2fs_free_blocks_count_set(fs.*.super, free_blocks);
    fs.*.super.*.s_free_inodes_count = @intCast(free_inodes);
    fs.*.flags |= c_api.EXT2_FLAG_DIRTY | c_api.EXT2_FLAG_CHANGED;
    try session.check(c_api.ext2fs_flush(fs));
}
