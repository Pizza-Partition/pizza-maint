const std = @import("std");
const storage = @import("storage");
const wire = @import("proto").wire;
const fsutil = @import("utils").filesystem;
const Mount = struct { device: []const u8, root: []const u8, path: []const u8, filesystem: []const u8, source: []const u8 };

pub fn unescape(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            try bytes.append(a, text[i]);
            continue;
        }
        if (i + 3 >= text.len) return error.InvalidMountEscape;
        var value: u16 = 0;
        for (text[i + 1 ..][0..3]) |c| {
            if (c < '0' or c > '7') return error.InvalidMountEscape;
            value = value * 8 + c - '0';
        }
        if (value == 0 or value > 255) return error.InvalidMountEscape;
        try bytes.append(a, @intCast(value));
        i += 3;
    }
    return bytes.toOwnedSlice(a);
}
pub fn mounts(a: std.mem.Allocator, bytes: []const u8) ![]const Mount {
    var result: std.ArrayList(Mount) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const separator = std.mem.indexOf(u8, line, " - ") orelse return error.InvalidMountInfo;
        var left = std.mem.tokenizeScalar(u8, line[0..separator], ' ');
        _ = left.next() orelse return error.InvalidMountInfo;
        _ = left.next() orelse return error.InvalidMountInfo;
        const dev = left.next() orelse return error.InvalidMountInfo;
        const root = left.next() orelse return error.InvalidMountInfo;
        const path = left.next() orelse return error.InvalidMountInfo;
        var right = std.mem.tokenizeScalar(u8, line[separator + 3 ..], ' ');
        const filesystem = right.next() orelse return error.InvalidMountInfo;
        const source = right.next() orelse return error.InvalidMountInfo;
        try result.append(a, .{ .device = dev, .root = try unescape(a, root), .path = try unescape(a, path), .filesystem = filesystem, .source = try unescape(a, source) });
    }
    return result.toOwnedSlice(a);
}
fn read(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
}
fn optional(a: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const bytes = read(a, io, path) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return null,
        else => return err,
    };
    return std.mem.trim(u8, bytes, "\n \t");
}
fn number(a: std.mem.Allocator, io: std.Io, path: []const u8) !?u64 {
    return if (try optional(a, io, path)) |s| try std.fmt.parseInt(u64, s, 10) else null;
}
fn sameMount(io: std.Io, a: std.mem.Allocator, node: storage.probe.BlockDevice, mount: Mount) bool {
    if (node.device_number) |n| if (std.mem.eql(u8, n, mount.device)) return true;
    // Btrfs reports a synthetic major/minor for subvolume mounts. Resolve its
    // source instead of treating that synthetic number as a physical disk.
    if (!std.mem.startsWith(u8, mount.source, "/dev/")) return false;
    const source = std.Io.Dir.cwd().realPathFileAlloc(io, mount.source, a) catch mount.source;
    return std.mem.eql(u8, source, node.path);
}
fn caps(a: std.mem.Allocator, part: wire.HostPartition) ![]const wire.HostCapability {
    const list = try a.alloc(wire.HostCapability, 7);
    const kinds = [_]wire.IntentKind{ .resize, .move, .create, .delete, .format, .label, .copy };
    const registered = if (part.filesystem) |f| switch (f) {
        .ext2, .ext3, .ext4, .vfat, .ntfs, .btrfs => true,
        else => false,
    } else false;
    for (list, kinds) |*c, kind| {
        const blocked = part.protected or part.encryption != .none or !registered or kind == .label;
        c.* = .{ .operation = kind, .support = if (blocked) .unavailable else .offline_check, .reason = if (part.protected) "recovery_anchor_or_boot_partition" else if (part.encryption != .none) "encryption_not_supported_or_unknown" else if (!registered) "filesystem_driver_unavailable" else if (kind == .label) "label_mutation_unimplemented" else "offline_filesystem_validation_required" };
    }
    return list;
}
fn fsKind(name: []const u8) ?wire.FilesystemKind {
    return std.meta.stringToEnum(wire.FilesystemKind, name);
}
fn udev(a: std.mem.Allocator, io: std.Io, node: storage.probe.BlockDevice, key: []const u8) !?[]const u8 {
    const dev = node.device_number orelse return null;
    const bytes = (try optional(a, io, try a.print("/run/udev/data/b{s}", .{dev}))) orelse return null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const prefix = try a.print("E:{s}=", .{key});
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}
pub fn query(a: std.mem.Allocator, io: std.Io) !wire.InventorySnapshot {
    const nodes = (try storage.probe.querySystem(a, io)).block_devices;
    const mounted = try mounts(a, try read(a, io, "/proc/self/mountinfo"));
    var disks: std.ArrayList(wire.HostDisk) = .empty;
    var sysfs = try std.Io.Dir.cwd().openDir(io, "/sys/dev/block", .{});
    defer sysfs.close(io);
    var esp: ?[]const u8 = null;
    for (nodes) |node| {
        if (node.partition_number != null or node.capacity_bytes == null or node.logical_block_size == null) continue;
        var diags: std.ArrayList(wire.Diagnostic) = .empty;
        const e = if (node.device_number) |dev| storage.block_device.inspectSysfs(a, io, sysfs, try storage.block_device.Node.parse(dev)) catch null else null;
        if (e == null) {
            // Virtual devices remain visible, but never acquire executable identity.
            try diags.append(a, .{ .code = "unsupported_topology", .severity = .warning, .message = "Physical identity or topology could not be established." });
        }
        var disk: wire.HostDisk = .{ .path = node.path, .identity = if (e) |v| try a.dupe(u8, &std.fmt.bytesToHex(v.identity, .lower)) else null, .capacity = try a.print("{d}", .{node.capacity_bytes orelse 0}), .sector_size = node.logical_block_size orelse 512, .physical_block_size = node.physical_block_size, .model = node.model orelse node.name, .read_only = node.read_only orelse true };
        var block: ?storage.block_device.BlockDevice = storage.block_device.BlockDevice.open(a, io, node.path, null, null, .probe) catch |err| blk: {
            try diags.append(a, .{ .code = @errorName(err), .severity = .warning, .message = "Raw partition metadata unavailable; displayed geometry is advisory." });
            break :blk null;
        };
        defer if (block) |*b| b.close(io);
        const layout: ?storage.partition_table.Layout = if (block) |*b| storage.partition_table.BUILTIN.readLayout(a, io, b.backend().reader()) catch |err| blk: {
            try diags.append(a, .{ .code = @errorName(err), .severity = .warning, .message = "Partition table could not be validated." });
            break :blk null;
        } else null;
        if (layout) |table| {
            disk.partition_table = @tagName(table.kind);
            disk.usable_offset = try a.print("{d}", .{table.usable.offset});
            disk.usable_length = try a.print("{d}", .{table.usable.length});
        }
        var parts: std.ArrayList(wire.HostPartition) = .empty;
        for (nodes) |child| {
            const pn = child.partition_number orelse continue;
            const parent = (try optional(a, io, try a.print("/sys/class/block/{s}/../dev", .{child.name}))) orelse continue;
            if (!std.mem.eql(u8, parent, node.device_number orelse "")) continue;
            const start = (try number(a, io, try a.print("/sys/class/block/{s}/start", .{child.name}))) orelse continue;
            var p: wire.HostPartition = .{ .id = try a.print("unverified:{s}", .{child.name}), .offset = try a.print("{d}", .{try std.math.mul(u64, start, 512)}), .length = try a.print("{d}", .{child.capacity_bytes orelse 0}), .name = child.name, .encryption = .unknown, .slot = pn - 1 };
            var paths: std.ArrayList([]const u8) = .empty;
            for (mounted) |m| if (sameMount(io, a, child, m)) {
                try paths.append(a, m.path);
                p.filesystem = fsKind(m.filesystem);
                if (p.filesystem != null) p.encryption = .none;
                if (std.mem.eql(u8, m.path, "/boot") or std.mem.eql(u8, m.path, "/boot/efi") or std.mem.eql(u8, m.path, "/efi")) {
                    p.protected = true;
                    if (p.filesystem == .vfat) esp = m.path;
                }
                var directory = std.Io.Dir.cwd().openDir(io, m.path, .{}) catch continue;
                defer directory.close(io);
                const space = fsutil.space(directory) catch continue;
                p.free_bytes = try a.print("{d}", .{space.available_bytes});
                p.used_bytes = try a.print("{d}", .{space.total_bytes -| space.free_bytes});
            };
            p.mountpoints = try paths.toOwnedSlice(a);
            if (try udev(a, io, child, "ID_FS_TYPE")) |kind| {
                p.filesystem = fsKind(kind);
                p.encryption = if (std.mem.eql(u8, kind, "crypto_LUKS") or std.mem.eql(u8, kind, "BitLocker")) .encrypted else if (p.filesystem != null) .none else .unknown;
            }
            if (try udev(a, io, child, "ID_FS_LABEL")) |label| p.name = label;
            if (layout) |table| for (table.entries) |entry| {
                if (entry.slot != pn - 1) continue;
                p.id = try a.dupe(u8, &std.fmt.bytesToHex(entry.id, .lower));
                p.type_guid = try a.dupe(u8, &std.fmt.bytesToHex(entry.type_id, .lower));
                p.partition_uuid = try a.dupe(u8, &std.fmt.bytesToHex(entry.uuid, .lower));
                p.attributes = try a.print("{d}", .{entry.attributes});
                if (std.mem.eql(u8, p.type_guid.?, "28732ac11ff8d211ba4b00a0c93ec93b")) p.protected = true;
                if (p.mountpoints.len == 0 and block != null) {
                    var builder = storage.program.PhysicalProgramBuilder.init(a, block.?.backend().reader());
                    var view: storage.program.PhysicalProgramBuilder.View = .{ .builder = &builder, .version = 0, .range = entry.range };
                    const snapshot = storage.filesystem.BUILTIN.query(a, io, view.reader()) catch null;
                    if (snapshot) |f| {
                        p.filesystem = @fromBackingInt(@intCast(@backingInt(f.filesystem)));
                        p.encryption = .none;
                    }
                }
                break;
            };
            p.capabilities = try caps(a, p);
            try parts.append(a, p);
        }
        disk.partitions = try parts.toOwnedSlice(a);
        disk.diagnostics = try diags.toOwnedSlice(a);
        try disks.append(a, disk);
    }
    var snapshot: wire.InventorySnapshot = .{ .version = 4, .snapshot_id = "", .platform = .linux, .disks = try disks.toOwnedSlice(a), .esp_path = esp };
    snapshot.snapshot_id = try @import("inventory.zig").fingerprint(a, snapshot);
    return snapshot;
}

test "mountinfo parsing preserves escaped paths and Btrfs source" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try mounts(arena.allocator(), "22 1 0:34 /@home /home\\040data rw - btrfs /dev/nvme0n1p2 rw\n");
    try std.testing.expectEqualStrings("/home data", result[0].path);
    try std.testing.expectEqualStrings("/dev/nvme0n1p2", result[0].source);
    try std.testing.expectError(error.InvalidMountEscape, unescape(arena.allocator(), "abc\\999"));
}
