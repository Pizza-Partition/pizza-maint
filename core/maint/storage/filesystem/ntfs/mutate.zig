//! Conservative NTFS repair: reconstruct only an unambiguous boot backup.
const std = @import("std");
const root = @import("root.zig");
const model = @import("../../model.zig");
const Reader = @import("../../device.zig").Reader;
const mutation = @import("../../mutation.zig");
pub fn prepare(comptime operation: model.Kind, a: std.mem.Allocator, io: std.Io, reader: Reader, _: model.Snapshot, _: u64) !mutation.MutationSet {
    if (operation != .repair) return error.SemanticPlanningRequired;
    try @import("semantic.zig").validate(a, io, reader, true);
    const g = try root.format.load(io, reader);
    var collector: mutation.Collector = .{ .allocator = a, .target = reader.target };
    root.checkBackup(io, reader, g) catch |err| switch (err) {
        error.NtfsBackupBoot => {
            const boot = try reader.read(a, io, .{ .offset = 0, .length = g.sector });
            try collector.write(g.bytes - g.sector, boot);
        },
        else => return err,
    };
    return collector.finish();
}
