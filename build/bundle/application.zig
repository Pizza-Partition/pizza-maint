//! Linkage contract for the single maintenance executable shipped in the bundle.
const std = @import("std");
const utils = @import("utils");

pub const INTERPRETER = "lib/ld-linux-x86-64.so.2";
pub const RUNPATH = "$ORIGIN/../lib";

/// Inspect the linker's output without modifying any ELF bytes.
pub fn verify(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try verifyMetadata(try utils.elf.metadata(a, io, path));
}

fn verifyMetadata(meta: utils.elf.Metadata) !void {
    if (meta.class != .@"64" or meta.machine != .X86_64 or meta.endian != .little) return error.IncompatibleApplicationElf;
    if (meta.interp.len != 1 or !std.mem.eql(u8, meta.interp[0], INTERPRETER)) return error.ApplicationInterpreterMismatch;
    if (meta.runpath.len != 1 or !std.mem.eql(u8, meta.runpath[0], RUNPATH)) return error.ApplicationRunpathMismatch;
    if (meta.rpath.len != 0) return error.ApplicationLegacyRpath;
}

test "maintenance linkage rejects host interpreters, alternate search paths and incompatible ELF" {
    const valid: utils.elf.Metadata = .{
        .needed = &.{"libc.so.6"},
        .runpath = &.{RUNPATH},
        .rpath = &.{},
        .interp = &.{INTERPRETER},
        .isa = utils.elf.X86_ISA_BASELINE,
        .soname = &.{},
        .class = .@"64",
        .machine = .X86_64,
        .endian = .little,
        .needed_versions = .empty,
        .defined_versions = &.{},
    };
    try verifyMetadata(valid);
    var bad = valid;
    bad.interp = &.{"/lib64/ld-linux-x86-64.so.2"};
    try std.testing.expectError(error.ApplicationInterpreterMismatch, verifyMetadata(bad));
    bad = valid;
    bad.interp = &.{};
    try std.testing.expectError(error.ApplicationInterpreterMismatch, verifyMetadata(bad));
    bad = valid;
    bad.runpath = &.{ RUNPATH, "/usr/lib" };
    try std.testing.expectError(error.ApplicationRunpathMismatch, verifyMetadata(bad));
    bad = valid;
    bad.runpath = &.{};
    try std.testing.expectError(error.ApplicationRunpathMismatch, verifyMetadata(bad));
    bad = valid;
    bad.rpath = &.{RUNPATH};
    try std.testing.expectError(error.ApplicationLegacyRpath, verifyMetadata(bad));
    bad = valid;
    bad.machine = .AARCH64;
    try std.testing.expectError(error.IncompatibleApplicationElf, verifyMetadata(bad));
}
