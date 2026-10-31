//! Format-independent private-image test utilities.
const std = @import("std");
const model = @import("../model.zig");
const device = @import("../device.zig");

pub fn command(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(a, io, .{ .argv = argv });
    if (!result.term.success()) {
        std.debug.print("fixture command {s}: {s}\n{s}\n", .{ argv[0], result.stdout, result.stderr });
        return error.FixtureToolFailed;
    }
}

pub fn digest(io: std.Io, reader: device.Reader) !model.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.target.capacity) {
        const bytes = buffer[0..@intCast(@min(buffer.len, reader.target.capacity - offset))];
        try reader.readInto(io, offset, bytes);
        hash.update(bytes);
        offset += bytes.len;
    }
    return hash.finalResult();
}

/// Hash meaningful retained bytes outside explicitly destructive write ranges.
pub fn programRetainedDigest(io: std.Io, reader: @import("../device.zig").Reader, program: @import("../program.zig").Program) !@import("../model.zig").Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.target.capacity) {
        var next = reader.target.capacity;
        var skip: u64 = offset;
        for (program.steps, 0..) |step, i| {
            if (!(step.operation == .copy or (step.operation == .write and step.operation.write.discard))) continue;
            const range = program.targetRange(i).?;
            if (range.offset <= offset and try range.end() > offset) skip = @max(skip, try range.end()) else if (range.offset > offset) next = @min(next, range.offset);
        }
        if (skip > offset) {
            offset = skip;
            continue;
        }
        const part = bytes[0..@intCast(@min(bytes.len, next - offset))];
        try reader.readInto(io, offset, part);
        hash.update(part);
        offset += part.len;
    }
    return hash.finalResult();
}
