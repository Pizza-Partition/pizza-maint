//! Filesystem driver discovery. Open sessions expose only the semantic vtable;
//! operation planning and execution belong to service and program_executor.
const std = @import("std");
const model = @import("../model.zig");
const device = @import("../device.zig");
pub const Driver = @import("../semantic.zig").Driver;
pub const Filesystem = @import("../semantic.zig").Filesystem;
pub const Registry = struct {
    drivers: []const Driver,
    pub fn detect(self: Registry, io: std.Io, reader: device.Reader) !Driver {
        try reader.target.validate();
        var selected: ?Driver = null;
        for (self.drivers) |driver| {
            if (!try driver.probe(io, reader)) continue;
            if (selected != null) return error.AmbiguousFilesystem;
            selected = driver;
        }
        return selected orelse error.FilesystemUnavailable;
    }
    /// Formatting chooses a format explicitly and never probes blank bytes.
    pub fn get(self: Registry, format: model.Filesystem) !Driver {
        var selected: ?Driver = null;
        for (self.drivers) |driver| if (driver.filesystem == format) {
            if (selected != null) return error.DuplicateFilesystemDriver;
            selected = driver;
        };
        return selected orelse error.FilesystemUnavailable;
    }
    pub fn open(self: Registry, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !Filesystem {
        return (try self.detect(io, reader)).open(a, io, reader, false);
    }
    pub fn query(self: Registry, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Snapshot {
        const fs = try self.open(a, io, reader);
        defer fs.close();
        return fs.inspect();
    }
    pub fn check(self: Registry, a: std.mem.Allocator, io: std.Io, reader: device.Reader) !model.Check {
        const fs = try self.open(a, io, reader);
        defer fs.close();
        return fs.check();
    }
};
const DRIVERS = @import("ext/semantic.zig").DRIVERS ++
    [_]Driver{ @import("fat32/semantic.zig").DRIVER, @import("ntfs/semantic.zig").DRIVER, @import("btrfs/semantic.zig").DRIVER };
pub const BUILTIN: Registry = .{ .drivers = &DRIVERS };
