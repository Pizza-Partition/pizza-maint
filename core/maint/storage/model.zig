//! Format-independent identities, capabilities and results. Recognizing a format never grants write support.
const std = @import("std");

pub const Digest = [32]u8;

pub const Filesystem = enum {
    ext2,
    ext3,
    ext4,
    xfs,
    btrfs,
    vfat,
    exfat,
    ntfs,
    f2fs,
    nilfs2,
    udf,
};

pub const Kind = enum {
    create,
    query,
    check,
    repair,
    grow,
    shrink,
    copy,
};

pub const Range = struct {
    offset: u64,
    length: u64,

    pub fn end(self: Range) !u64 {
        return std.math.add(u64, self.offset, self.length) catch error.RangeOverflow;
    }

    pub fn validate(self: Range, capacity: u64, alignment: u32) !void {
        if (alignment == 0 or self.length == 0 or self.offset % alignment != 0 or self.length % alignment != 0)
            return error.UnalignedRange;
        if (try self.end() > capacity) return error.RangeOutsideDevice;
    }

    /// Callers validate first; subtraction also makes this safe for invalid input.
    pub fn overlaps(self: Range, other: Range) bool {
        return if (self.offset <= other.offset) other.offset - self.offset < self.length else self.offset - other.offset < other.length;
    }
};

pub const Target = struct {
    identity: Digest,
    capacity: u64,
    sector_size: u32,
    kind: enum { private_image, physical_device } = .private_image,

    pub fn validate(self: Target) !void {
        if (self.sector_size < 512 or self.sector_size > 65536 or
            !std.math.isPowerOfTwo(self.sector_size))
            return error.InvalidSectorSize;

        if (self.capacity == 0 or self.capacity % self.sector_size != 0)
            return error.InvalidDeviceSize;

        if (std.mem.allEqual(u8, &self.identity, 0))
            return error.MissingDeviceIdentity;
    }

    pub fn same(self: Target, other: Target) bool {
        return std.meta.eql(self, other);
    }
};

pub const Support = enum {
    unavailable,
    planned,
    implemented,
    validated,
};

pub const Capability = struct {
    operation: Kind,
    support: Support = .planned,
    reason: enum {
        driver_missing,
        feature_unsupported,
        recovery_unvalidated,
        operation_unimplemented,
        resource_limit,
        available,
    } = .driver_missing,
    scope: CheckScope = .filesystem,
};

pub const Usage = struct {
    /// Format accounting, not a promise about relocatability or shrink bounds.
    used_bytes: ?u64 = null,
    free_bytes: ?u64 = null,
    advisory: bool = true,
};

pub const Snapshot = struct {
    filesystem: Filesystem,
    target: Target,
    generation: u64,
    block_size: u32,
    filesystem_bytes: u64,
    clean: bool,
    usage: Usage = .{},
    /// Format-specific feature names are diagnostic; the driver owns the allowlist.
    features: []const []const u8 = &.{},
    /// Capabilities assessed for this exact volume's features and state.
    capabilities: []const Capability = &.{},
};

pub const CheckScope = enum { filesystem, allocation_metadata };
pub const Check = struct {
    consistent: bool,
    detail: []const u8,
    scope: CheckScope = .filesystem,
};

pub fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

/// All registered operations are validated; only the check/repair scope varies.
pub fn validatedOperations(comptime check_scope: CheckScope) [std.enums.values(Kind).len]Capability {
    var caps: [std.enums.values(Kind).len]Capability = undefined;
    for (std.enums.values(Kind), &caps) |kind, *cap| cap.* = .{ .operation = kind, .support = .validated, .reason = .available, .scope = if (kind == .check or kind == .repair) check_scope else .filesystem };
    return caps;
}

test "validated operation tables preserve allocation-only check and repair scope" {
    const full = validatedOperations(.filesystem);
    const allocation = validatedOperations(.allocation_metadata);
    for (full, allocation) |whole, scoped| {
        try std.testing.expectEqual(whole.operation, scoped.operation);
        try std.testing.expectEqual(.validated, scoped.support);
        try std.testing.expectEqual(.available, scoped.reason);
        try std.testing.expectEqual(.filesystem, whole.scope);
        try std.testing.expectEqual(if (scoped.operation == .check or scoped.operation == .repair) CheckScope.allocation_metadata else CheckScope.filesystem, scoped.scope);
    }
}
