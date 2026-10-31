//! Standalone disposable-image self-test; never linked into pizza-maint.
const std = @import("std");
const storage = @import("storage");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    if ((try init.minimal.args.toSlice(a)).len != 1) return error.InvalidTestArguments;
    const stats = try storage.testing.fixture.run(a, init.io);
    try std.Io.File.stdout().writeStreamingAll(init.io, try a.print("PIZZA_STORAGE_PRIMITIVES:{s}\n", .{try std.json.Stringify.valueAlloc(a, .{
        .test_name = "storage-primitives",
        .scope = "private_image_primitives",
        .filesystem_writes = false,
        .persistent_recovery_qualified = false,
        .results = stats,
    }, .{})}));
}
