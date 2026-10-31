//! Format-specific fixture construction and independent oracles. The shared
//! suites own operations, crash schedules, recovery and acceptance assertions.
const std = @import("std");
const model = @import("../../model.zig");
const Driver = @import("../../semantic.zig").Driver;
const Image = @import("../image.zig").Image;

pub const Fixture = struct {
    filesystem: model.Filesystem,
    capacity: u64,
    smaller_bytes: u64,
    sector_size: u32 = 512,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (std.mem.Allocator, std.Io, []const u8, model.Filesystem, u64) anyerror![]const u8,
        seed_payload: *const fn (std.mem.Allocator, std.Io, []const u8, []const u8, []const u8, bool) anyerror!void,
        check: *const fn (std.mem.Allocator, std.Io, []const u8) anyerror!void,
        check_payload: *const fn (std.mem.Allocator, std.Io, []const u8, []const u8, []const u8) anyerror!void,
        make_repairable: ?*const fn (std.mem.Allocator, std.Io, *Image) anyerror!void = null,
    };
    pub fn create(self: Fixture, a: std.mem.Allocator, io: std.Io, home: []const u8, initial_bytes: u64) ![]const u8 {
        return self.vtable.create(a, io, home, self.filesystem, initial_bytes);
    }
    pub fn seedPayload(self: Fixture, a: std.mem.Allocator, io: std.Io, home: []const u8, path: []const u8, bytes: []const u8, tail: bool) !void {
        return self.vtable.seed_payload(a, io, home, path, bytes, tail);
    }
    pub fn check(self: Fixture, a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        return self.vtable.check(a, io, path);
    }
    pub fn checkPayload(self: Fixture, a: std.mem.Allocator, io: std.Io, path: []const u8, output: []const u8, bytes: []const u8) !void {
        return self.vtable.check_payload(a, io, path, output, bytes);
    }
    pub fn makeRepairable(self: Fixture, a: std.mem.Allocator, io: std.Io, image: *Image) !void {
        return (self.vtable.make_repairable orelse return error.MissingRepairFixture)(a, io, image);
    }
};

pub const Case = struct {
    driver: Driver,
    fixture: Fixture,
    pub fn supports(self: Case, kind: model.Kind) bool {
        for (self.driver.operations) |cap| if (cap.operation == kind) return cap.support == .validated;
        return false;
    }
};
