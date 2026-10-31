//! Every registered backend participates in the common contract suite. Adding
//! a backend without a fixture is an error, never an implicit skipped success.
const std = @import("std");
const model = @import("../../model.zig");
pub const Case = @import("fixture.zig").Case;
pub const Fixture = @import("fixture.zig").Fixture;
const PROVIDERS = @import("ext/fixture.zig").FIXTURES ++ @import("fat32/fixture.zig").FIXTURES ++ @import("ntfs/fixture.zig").FIXTURES ++ @import("btrfs/fixture.zig").FIXTURES;

pub fn cases(a: std.mem.Allocator, registry: anytype) ![]Case {
    return collect(a, registry, &PROVIDERS);
}

pub fn collect(a: std.mem.Allocator, registry: anytype, available: []const Fixture) ![]Case {
    const result = try a.alloc(Case, registry.drivers.len);
    errdefer a.free(result);
    for (registry.drivers, result) |driver, *entry| {
        var selected: ?Fixture = null;
        for (available) |fixture| if (fixture.filesystem == driver.filesystem) {
            if (selected != null) return error.DuplicateFilesystemFixture;
            selected = fixture;
        };
        entry.* = .{ .driver = driver, .fixture = selected orelse return error.MissingFilesystemFixture };
        try (model.Target{ .identity = @splat(0x71), .capacity = entry.fixture.capacity, .sector_size = entry.fixture.sector_size }).validate();
        if (entry.fixture.smaller_bytes == 0 or entry.fixture.smaller_bytes >= entry.fixture.capacity or entry.fixture.capacity % entry.fixture.sector_size != 0 or entry.fixture.smaller_bytes % entry.fixture.sector_size != 0) return error.InvalidFilesystemFixture;
        if (entry.supports(.repair) and entry.fixture.vtable.make_repairable == null) return error.MissingRepairFixture;
    }
    return result;
}
