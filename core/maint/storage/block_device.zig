//! Linux block devices: stable identity, exclusive acquisition and direct I/O.
const std = @import("std");
const linux = std.os.linux;
const model = @import("model.zig");
const device = @import("device.zig");
const fs = @import("utils").filesystem;

// Linux x86-64 block-device and Btrfs ioctl request codes.
const BLKGETSIZE64: u32 = 0x80081272;
const BLKSSZGET: u32 = 0x1268;
const BLKPBSZGET: u32 = 0x127b;
const BLKROGET: u32 = 0x125e;
const BLKRRPART: u32 = 0x125f;
const BTRFS_IOC_FS_INFO: u32 = 0x8400941f;

fn rangeWithin(r: model.Range, allowed: []const model.Range) bool {
    const end = r.end() catch return false;
    if (r.length == 0) return false;
    for (allowed) |other| if (other.offset <= r.offset and (other.end() catch continue) >= end) return true;
    return false;
}
/// Pure portion of same-disk admission, also exercised without a host device.
pub fn validateSessionAnchor(a: std.mem.Allocator, target: model.Target, bundle: @import("maintenance_session.zig").Bundle, proof: @import("esp_anchor.zig").Proof) !void {
    try bundle.validate(a, target);
    if (!std.mem.eql(u8, &target.identity, &proof.disk_identity)) return error.RecoveryBackingChanged;
    if (!rangeWithin(proof.esp, bundle.protected)) return error.EspNotProtected;
    if (!rangeWithin(bundle.control, proof.extents)) return error.SessionControlOutsideAnchor;
    for ([_]@import("recovery_store.zig").CapsuleDescriptor{ bundle.bootstrap_store, bundle.cleanup_store }) |d| {
        for (d.extents) |r| if (!rangeWithin(r, proof.extents)) return error.RecoveryCapsuleOutsideAnchor;
    }
    for (bundle.apply_store.extents) |r| if (r.overlaps(proof.esp)) return error.WorkStoreOverlapsEsp;
}

pub const Node = struct {
    major: u32,
    minor: u32,
    pub fn parse(bytes: []const u8) !Node {
        var parts = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, " \r\n"), ':');
        const major = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidDeviceNumber, 10);
        const minor = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidDeviceNumber, 10);
        if (parts.next() != null) return error.InvalidDeviceNumber;
        return .{ .major = major, .minor = minor };
    }
    pub fn same(self: Node, other: Node) bool {
        return std.meta.eql(self, other);
    }
};

pub const Evidence = struct {
    node: Node,
    root_node: Node,
    root_path: []const u8,
    identity: model.Digest,
    disk_identity: model.Digest,
    offset: u64,
    capacity: u64,
    logical: u32,
    physical: u32,
    partition: bool,
};

fn text(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]const u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return std.mem.trim(u8, try reader.interface.allocRemaining(a, .limited(8 * 1024 * 1024)), " \t\r\n");
}
fn optionalText(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !?[]const u8 {
    const value = text(a, io, dir, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return if (value.len == 0) null else value;
}
fn hardwareText(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !?[]const u8 {
    const file = dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return null,
        else => return err,
    };
    defer file.close(io);
    // Optional SCSI VPD attributes return EINVAL when the device does not
    // supply the requested page, or ENXIO when no serial is available.
    // Neither grants an identity; discovery must continue to other sources.
    const buffer = try a.alloc(u8, 4096);
    while (true) {
        const result = linux.read(file.handle, buffer.ptr, buffer.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == buffer.len) return error.HardwareIdentityTooLarge;
                const value = std.mem.trim(u8, buffer[0..result], " \t\r\n");
                return if (value.len == 0) null else value;
            },
            .INTR => continue,
            .NXIO, .INVAL, .IO, .NODEV, .ACCES, .PERM => return null,
            else => return error.HardwareIdentityReadFailed,
        }
    }
}

fn usbIdentity(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, root_path: []const u8) !?[]const u8 {
    const scsi = root.realPathFileAlloc(io, "device", a) catch return null;
    const address = std.fs.path.basename(scsi);
    const separator = std.mem.lastIndexOfScalar(u8, address, ':') orelse return null;
    const lun = std.fmt.parseInt(u64, address[separator + 1 ..], 10) catch return null;
    var interface: ?[]const u8 = null;
    var ancestor = std.fs.path.dirname(root_path);
    while (ancestor) |path| : (ancestor = std.fs.path.dirname(path)) {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        if (try hardwareText(a, io, dir, "bInterfaceNumber")) |value| interface = value;
        if (try hardwareText(a, io, dir, "idVendor")) |vendor| {
            const product = try hardwareText(a, io, dir, "idProduct") orelse return error.StableDeviceIdentityUnavailable;
            const serial = try hardwareText(a, io, dir, "serial") orelse return error.StableDeviceIdentityUnavailable;
            return try a.print("usb:{s}:{s}:{s}:{s}:{d}", .{ vendor, product, serial, interface orelse return error.StableDeviceIdentityUnavailable, lun });
        }
        if (std.mem.eql(u8, path, "/sys/devices")) break;
    }
    return null;
}
fn number(comptime T: type, a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !T {
    return std.fmt.parseInt(T, try text(a, io, dir, path), 10);
}
fn stat(fd: linux.fd_t) !linux.Statx {
    var value: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &value)) != .SUCCESS) return error.DeviceStatFailed;
    return value;
}
fn blockNode(fd: linux.fd_t) !Node {
    const value = try stat(fd);
    if (value.mode & 0o170000 != 0o060000) return error.BlockDeviceRequired;
    return .{ .major = value.rdev_major, .minor = value.rdev_minor };
}

/// Caller owns strings through its allocator. sysfs is borrowed, allowing the
/// same evidence parser to be checked against fixtures without opening devices.
pub fn inspectSysfs(a: std.mem.Allocator, io: std.Io, sysfs: std.Io.Dir, node: Node) !Evidence {
    const path = try sysfs.realPathFileAlloc(io, try a.print("{d}:{d}", .{ node.major, node.minor }), a);
    if (std.mem.indexOf(u8, path, "/virtual/") != null) return error.ComplexBlockDeviceUnsupported;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const partition = (try optionalText(a, io, dir, "partition")) != null;
    const root_path = if (partition) std.fs.path.dirname(path) orelse return error.InvalidDeviceTopology else path;
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    const root_node = try Node.parse(try text(a, io, root, "dev"));
    if (!node.same(try Node.parse(try text(a, io, dir, "dev")))) return error.DeviceIdentityChanged;
    const capacity = try std.math.mul(u64, try number(u64, a, io, dir, "size"), 512);
    const root_capacity = try std.math.mul(u64, try number(u64, a, io, root, "size"), 512);
    const offset = if (partition) try std.math.mul(u64, try number(u64, a, io, dir, "start"), 512) else 0;
    if (try std.math.add(u64, offset, capacity) > root_capacity) return error.InvalidDeviceTopology;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-physical-identity-v1\x00");
    const wwid = try hardwareText(a, io, root, "wwid") orelse try hardwareText(a, io, root, "device/wwid");
    const serial = if (wwid != null) null else try hardwareText(a, io, root, "serial") orelse try hardwareText(a, io, root, "device/serial") orelse try usbIdentity(a, io, root, root_path);
    if (wwid) |id| {
        hash.update("wwid\x00");
        hash.update(id);
    } else if (serial) |id| {
        hash.update("serial\x00");
        hash.update(id);
        for ([_][]const u8{ "device/vendor", "device/model", "nsid" }) |key| {
            hash.update("\x00");
            hash.update(key);
            hash.update("\x00");
            if (try optionalText(a, io, root, key)) |value| hash.update(value);
        }
    } else return error.StableDeviceIdentityUnavailable;
    const disk_identity = hash.finalResult();
    hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&disk_identity);
    hash.update(if (partition) "partition" else "disk");
    if (partition) {
        var range: [16]u8 = undefined;
        std.mem.writeInt(u64, range[0..8], offset, .little);
        std.mem.writeInt(u64, range[8..16], capacity, .little);
        hash.update(&range);
    }
    const logical = try number(u32, a, io, root, "queue/logical_block_size");
    const physical = try number(u32, a, io, root, "queue/physical_block_size");
    const identity = hash.finalResult();
    try (model.Target{ .identity = identity, .capacity = capacity, .sector_size = logical, .kind = .physical_device }).validate();
    if (physical < logical or physical > 65536 or !std.math.isPowerOfTwo(physical)) return error.InvalidSectorSize;
    return .{ .node = node, .root_node = root_node, .root_path = root_path, .identity = identity, .disk_identity = disk_identity, .offset = offset, .capacity = capacity, .logical = logical, .physical = physical, .partition = partition };
}
fn inspect(a: std.mem.Allocator, io: std.Io, node: Node) !Evidence {
    var sysfs = try std.Io.Dir.cwd().openDir(io, "/sys/dev/block", .{});
    defer sysfs.close(io);
    return inspectSysfs(a, io, sysfs, node);
}
fn empty(io: std.Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var entries = dir.iterate();
    if (try entries.next(io) != null) return error.BlockDeviceInUse;
}
fn contains(nodes: []const Node, node: Node) bool {
    for (nodes) |entry| if (entry.same(node)) return true;
    return false;
}
pub fn checkMounts(mountinfo: []const u8, nodes: []const Node) !void {
    var lines = std.mem.tokenizeScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse return error.InvalidMountEvidence;
        _ = fields.next() orelse return error.InvalidMountEvidence;
        const node = try Node.parse(fields.next() orelse return error.InvalidMountEvidence);
        if (contains(nodes, node)) return error.BlockDeviceMounted;
    }
}
fn unused(a: std.mem.Allocator, io: std.Io, e: Evidence) !void {
    var nodes: std.ArrayList(Node) = .empty;
    try nodes.append(a, e.node);
    // A whole-disk claim must account for every child partition. A partition
    // claim leaves disjoint sibling partitions available to their owners.
    if (!e.partition) {
        var root = try std.Io.Dir.cwd().openDir(io, e.root_path, .{ .iterate = true });
        defer root.close(io);
        var it = root.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (try optionalText(a, io, root, try a.print("{s}/partition", .{entry.name}))) |_| {
                try nodes.append(a, try Node.parse(try text(a, io, root, try a.print("{s}/dev", .{entry.name}))));
            }
        }
    }
    try empty(io, try a.print("{s}/slaves", .{e.root_path}));
    try empty(io, try a.print("{s}/holders", .{e.root_path}));
    for (nodes.items) |node|
        try empty(io, try a.print("/sys/dev/block/{d}:{d}/holders", .{ node.major, node.minor }));
    try checkMounts(try text(a, io, .cwd(), "/proc/self/mountinfo"), nodes.items);
    var swaps = std.mem.tokenizeScalar(u8, try text(a, io, .cwd(), "/proc/swaps"), '\n');
    _ = swaps.next();
    while (swaps.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const path = fields.next() orelse return error.InvalidSwapEvidence;
        // Kernel mount exclusion also covers swapfiles; reject unresolvable
        // escaped names instead of treating them as unused.
        if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnresolvedSwapEvidence;
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const value = try stat(file.handle);
        const node: Node = if (value.mode & 0o170000 == 0o060000) .{ .major = value.rdev_major, .minor = value.rdev_minor } else .{ .major = value.dev_major, .minor = value.dev_minor };
        if (contains(nodes.items, node)) return error.BlockDeviceInSwap;
    }
}

fn ioctl(fd: linux.fd_t, request: u32, value: anytype) !void {
    if (linux.errno(linux.ioctl(fd, request, @intFromPtr(value))) != .SUCCESS) return error.DeviceGeometryUnavailable;
}
const Geometry = struct { bytes: u64, logical: u32, physical: u32, readonly: c_int };
fn geometry(fd: linux.fd_t) !Geometry {
    var result: Geometry = undefined;
    try ioctl(fd, BLKGETSIZE64, &result.bytes);
    try ioctl(fd, BLKSSZGET, &result.logical);
    try ioctl(fd, BLKPBSZGET, &result.physical);
    try ioctl(fd, BLKROGET, &result.readonly);
    return result;
}

fn btrfsInfo(io: std.Io, dir: std.Io.Dir) ![1024]u8 {
    // Non-iterable Zig directories use O_PATH. Reopen the same inode readably
    // for filesystem ioctls instead of treating EBADF as missing evidence.
    var readable = try dir.openDir(io, ".", .{ .iterate = true });
    defer readable.close(io);
    var info: [1024]u8 align(8) = @splat(0);
    ioctl(readable.handle, BTRFS_IOC_FS_INFO, &info) catch return error.RecoveryFilesystemInfoUnavailable;
    if (std.mem.readInt(u64, info[8..16], .little) != 1) return error.ComplexRecoveryDeviceUnsupported;
    return info;
}
fn recoveryNode(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Node {
    const kind = try fs.filesystemType(dir);
    if (kind == fs.EXT4_SUPER_MAGIC or kind == fs.XFS_SUPER_MAGIC) {
        const value = try stat(dir.handle);
        return .{ .major = value.dev_major, .minor = value.dev_minor };
    }
    if (kind != fs.BTRFS_SUPER_MAGIC) return error.RecoveryMustUsePersistentMedia;
    const info = try btrfsInfo(io, dir);
    const uuid = std.fmt.bytesToHex(info[16..32].*, .lower);
    const path = try a.print("/sys/fs/btrfs/{s}-{s}-{s}-{s}-{s}/devices", .{ uuid[0..8], uuid[8..12], uuid[12..16], uuid[16..20], uuid[20..32] });
    var devices = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer devices.close(io);
    var entries = devices.iterate();
    const entry = try entries.next(io) orelse return error.RecoveryBackingUnknown;
    const result = try Node.parse(try text(a, io, devices, try a.print("{s}/dev", .{entry.name})));
    if (try entries.next(io) != null) return error.ComplexRecoveryDeviceUnsupported;
    return result;
}

pub const BlockDevice = struct {
    pub const Mode = enum { probe, source, write };
    file: std.Io.File,
    arena: std.heap.ArenaAllocator,
    evidence: Evidence,
    target: model.Target,
    mode: Mode,
    recovery_directory: ?std.Io.Dir = null,
    recovery_fsid: ?[2]u32 = null,
    preparation_digest: ?model.Digest = null,
    session_digest: ?model.Digest = null,
    session_esp: ?model.Range = null,
    session_writes: []const model.Range = &.{},

    pub fn open(a: std.mem.Allocator, io: std.Io, path: []const u8, expected: ?model.Digest, sector: ?u32, mode: Mode) !BlockDevice {
        if (!std.fs.path.isAbsolute(path)) return error.AbsolutePathRequired;
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
        if ((try std.Io.Dir.cwd().statFile(io, resolved, .{ .follow_symlinks = false })).kind != .block_device) return error.BlockDeviceRequired;
        const path_z = try allocator.dupeSentinel(u8, resolved, 0);
        const fd: linux.fd_t = while (true) {
            const result = linux.open(path_z, .{ .ACCMODE = if (mode == .write) .RDWR else .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .EXCL = mode != .probe, .DIRECT = true }, 0);
            switch (linux.errno(result)) {
                .SUCCESS => break @intCast(result),
                .INTR => continue,
                .BUSY => return error.BlockDeviceInUse,
                .ACCES, .PERM => return error.AccessDenied,
                .NOENT, .NOTDIR => return error.FileNotFound,
                .INVAL => return error.DirectIoUnavailable,
                else => return error.BlockDeviceOpenFailed,
            }
        };
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(io);
        const e = try inspect(allocator, io, try blockNode(fd));
        if (expected) |id| if (!std.mem.eql(u8, &id, &e.identity)) return error.DeviceIdentityChanged;
        if (sector) |size| if (size != e.logical) return error.DeviceGeometryChanged;
        if (mode != .probe) try unused(allocator, io, e);
        var result: BlockDevice = .{ .file = file, .arena = arena, .evidence = e, .target = .{ .identity = e.identity, .capacity = e.capacity, .sector_size = e.logical, .kind = .physical_device }, .mode = mode };
        try result.validateCore();
        return result;
    }
    pub fn close(self: *BlockDevice, io: std.Io) void {
        self.file.close(io);
        self.arena.deinit();
        self.* = undefined;
    }
    /// The directory is borrowed until the device closes. A mounted recovery
    /// filesystem and an exclusive target must have different physical roots.
    pub fn admitRecovery(self: *BlockDevice, a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
        if (self.session_digest != null or self.preparation_digest != null) return error.RecoveryAdmissionAlreadySelected;
        if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0) return error.RecoveryHomeMustBePrivate;
        const root = try inspect(a, io, try recoveryNode(a, io, dir));
        if (root.root_node.same(self.evidence.root_node) or std.mem.eql(u8, &root.disk_identity, &self.evidence.disk_identity)) return error.RecoveryMustUseIndependentDisk;
        self.recovery_directory = dir;
        self.recovery_fsid = try fs.filesystemIdentity(.{ .handle = dir.handle, .flags = .{ .nonblocking = false } });
    }
    /// A separate same-disk route, requiring an offline FAT32 allocation proof,
    /// unchanged GPT ESP identity, complete program reservations, and a bounded
    /// write allowlist. The caller authenticates the bundle/proof against the
    /// firmware-bound session manifest before invoking this method.
    pub fn admitSession(self: *BlockDevice, a: std.mem.Allocator, io: std.Io, bundle: @import("maintenance_session.zig").Bundle, path: []const @import("esp_anchor.zig").ShortName, proof: @import("esp_anchor.zig").Proof, initial: bool) !void {
        if (self.mode != .write or self.evidence.partition or self.recovery_directory != null or self.session_digest != null) return error.InvalidSessionAdmission;
        try unused(a, io, self.evidence);
        if (bundle.bootstrap_store.block_size < self.evidence.physical) return error.RecoveryBlockTooSmall;
        const reader = self.backend().reader();
        const actual = try @import("esp_anchor.zig").revalidate(a, io, reader, path, bundle.bootstrap_store.block_size, proof, false);
        if (initial) {
            // A torn first session header changes reserved ESP bytes but cannot
            // change any planned target byte. Require the complete initial read
            // guards before allowing preparation to resume; prepare() also
            // refuses any existing capsule header.
            for (bundle.bootstrap.guards) |guard| {
                if (!std.mem.eql(u8, &try reader.digest(io, guard.range), &guard.expected)) return error.PlanningReadChanged;
            }
            const table = try @import("partition_table.zig").BUILTIN.readLayout(a, io, reader);
            if (table.kind != .gpt) return error.GptRequiredForSameDiskRecovery;
            const esp_type = [_]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
            const found = for (table.entries) |e| {
                if (std.meta.eql(e.range, actual.esp) and std.mem.eql(u8, &e.type_id, &esp_type)) break true;
            } else false;
            if (!found) return error.EspPartitionChanged;
        } else {
            // GPT publication itself can have been interrupted. Recovery uses
            // the authenticated initial ESP address plus unchanged FAT chain,
            // and requires a valid durable session header before admission.
            _ = try @import("maintenance_session.zig").Session.open(a, io, self.backend(), bundle);
        }
        try validateSessionAnchor(a, self.target, bundle, actual);
        var writes: std.ArrayList(model.Range) = .empty;
        const allocator = self.arena.allocator();
        try writes.append(allocator, bundle.control);
        for ([_]@import("recovery_store.zig").CapsuleDescriptor{ bundle.bootstrap_store, bundle.apply_store, bundle.cleanup_store }) |d| try writes.appendSlice(allocator, d.extents);
        for ([_]@import("program.zig").Program{ bundle.bootstrap, bundle.apply, bundle.cleanup }) |p| {
            for (p.steps, 0..) |_, i| if (p.targetRange(i)) |r| try writes.append(allocator, r);
        }
        self.session_writes = try writes.toOwnedSlice(allocator);
        self.preparation_digest = null;
        self.session_digest = bundle.digest();
        self.session_esp = actual.esp;
    }
    /// The firmware-authenticated semantic request may publish ONLY its frozen
    /// compiled-manifest file before full physical-program admission. This is
    /// deliberately separate from transaction/capsule write authorization.
    pub fn admitPreparationFile(self: *BlockDevice, a: std.mem.Allocator, io: std.Io, request: model.Digest, path: []const @import("esp_anchor.zig").ShortName, proof: @import("esp_anchor.zig").Proof, block: u32) !void {
        if (self.mode != .write or self.evidence.partition or self.session_digest != null or self.preparation_digest != null or self.recovery_directory != null or block < self.evidence.physical or !std.mem.eql(u8, &proof.disk_identity, &self.target.identity)) return error.InvalidSessionAdmission;
        try unused(a, io, self.evidence);
        const actual = try @import("esp_anchor.zig").revalidate(a, io, self.backend().reader(), path, block, proof, false);
        const table = try @import("partition_table.zig").BUILTIN.readLayout(a, io, self.backend().reader());
        const esp_type = [_]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
        const found = for (table.entries) |entry| {
            if (std.meta.eql(entry.range, actual.esp) and std.mem.eql(u8, &entry.type_id, &esp_type)) break true;
        } else false;
        if (table.kind != .gpt or !found) return error.EspPartitionChanged;
        self.session_writes = try self.arena.allocator().dupe(model.Range, actual.extents);
        self.preparation_digest = request;
    }
    /// Add one immutable-allocation ESP file after authenticated session
    /// admission. Never permit it to overlap transaction or recovery writes.
    pub fn admitEspFile(self: *BlockDevice, a: std.mem.Allocator, io: std.Io, session: model.Digest, path: []const @import("esp_anchor.zig").ShortName, proof: @import("esp_anchor.zig").Proof, block: u32) !void {
        const current = self.session_digest orelse return error.InvalidSessionAdmission;
        if (self.mode != .write or !std.mem.eql(u8, &session, &current) or
            !std.mem.eql(u8, &proof.disk_identity, &self.target.identity) or
            !std.meta.eql(self.session_esp orelse return error.InvalidSessionAdmission, proof.esp) or block < self.evidence.physical) return error.InvalidSessionAdmission;
        try unused(a, io, self.evidence);
        const actual = try @import("esp_anchor.zig").revalidate(a, io, self.backend().reader(), path, block, proof, false);
        for (actual.extents) |r| {
            if (!rangeWithin(r, &.{proof.esp})) return error.RecoveryAnchorOutsideEsp;
            for (self.session_writes) |other| if (r.overlaps(other)) return error.EspFileOverlapsSession;
        }
        self.session_writes = try std.mem.concat(self.arena.allocator(), model.Range, &.{ self.session_writes, actual.extents });
    }
    pub fn refreshLayout(self: *BlockDevice) !void {
        if (self.evidence.partition) return;
        if (linux.errno(linux.ioctl(self.file.handle, BLKRRPART, 0)) != .SUCCESS) return error.KernelPartitionRefreshFailed;
    }
    pub fn backend(self: *BlockDevice) device.Device {
        return .{ .context = self, .target = self.target, .write_granule = self.evidence.physical, .physical_write_authorized = self.mode == .write and (self.recovery_directory != null or self.session_digest != null or self.preparation_digest != null), .region = .{ .identity = self.evidence.disk_identity, .range = .{ .offset = self.evidence.offset, .length = self.target.capacity } }, .vtable = &OPS };
    }
    fn cast(ctx: *const anyopaque) *const BlockDevice {
        return @ptrCast(@alignCast(ctx));
    }
    fn validateCore(self: *const BlockDevice) !void {
        if (!(try blockNode(self.file.handle)).same(self.evidence.node)) return error.DeviceIdentityChanged;
        const g = try geometry(self.file.handle);
        if (g.bytes != self.target.capacity or g.logical != self.evidence.logical or g.physical != self.evidence.physical) return error.DeviceGeometryChanged;
        if (self.mode == .write and g.readonly != 0) return error.ReadOnlyDevice;
    }
    fn validate(ctx: *const anyopaque, io: std.Io, target: model.Target) !void {
        const self = cast(ctx);
        if (!target.same(self.target)) return error.TransactionTargetMismatch;
        try self.validateCore();
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const live = try inspect(arena.allocator(), io, self.evidence.node);
        if (!std.mem.eql(u8, &live.identity, &target.identity) or !std.mem.eql(u8, live.root_path, self.evidence.root_path)) return error.DeviceIdentityChanged;
        if (self.recovery_directory) |dir| {
            if (!std.meta.eql(self.recovery_fsid.?, try fs.filesystemIdentity(.{ .handle = dir.handle, .flags = .{ .nonblocking = false } }))) return error.RecoveryBackingChanged;
            if (try fs.filesystemType(dir) == fs.BTRFS_SUPER_MAGIC) _ = try btrfsInfo(io, dir);
        }
    }
    fn read(ctx: *const anyopaque, io: std.Io, offset: u64, bytes: []u8) !void {
        const self = cast(ctx);
        try self.validateCore();
        var buffer: [65536]u8 align(65536) = undefined;
        const sector: u64 = self.target.sector_size;
        const end = try std.math.add(u64, offset, bytes.len);
        if (end > self.target.capacity) return error.RangeOutsideDevice;
        var position = offset & ~(sector - 1);
        const finish = std.mem.alignForward(u64, end, sector);
        while (position < finish) {
            const count: usize = @intCast(@min(buffer.len, finish - position));
            if (try self.file.readPositionalAll(io, buffer[0..count], position) != count) return error.ShortDeviceRead;
            const begin = @max(position, offset);
            const next = @min(position + count, end);
            @memcpy(bytes[@intCast(begin - offset)..][0..@intCast(next - begin)], buffer[@intCast(begin - position)..][0..@intCast(next - begin)]);
            position += count;
        }
    }
    fn write(ctx: *anyopaque, io: std.Io, offset: u64, bytes: []const u8) !void {
        const self = cast(ctx);
        if (self.mode != .write or (self.recovery_directory == null and self.session_digest == null and self.preparation_digest == null)) return error.PhysicalWriteNotAuthorized;
        if ((self.session_digest != null or self.preparation_digest != null) and !rangeWithin(.{ .offset = offset, .length = bytes.len }, self.session_writes)) return error.WriteOutsideAdmittedSession;
        var buffer: [65536]u8 align(65536) = undefined;
        var done: usize = 0;
        while (done < bytes.len) {
            const count = @min(buffer.len, bytes.len - done);
            @memcpy(buffer[0..count], bytes[done..][0..count]);
            try self.file.writePositionalAll(io, buffer[0..count], offset + done);
            done += count;
        }
    }
    fn flush(ctx: *anyopaque, io: std.Io) !void {
        try cast(ctx).file.sync(io);
    }
    const OPS: device.Device.VTable = .{ .reader = .{ .read = read }, .write = write, .flush = flush, .validate = validate };
};
