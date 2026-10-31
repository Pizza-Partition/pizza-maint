//! Refresh Sigstore verification material through authenticated TUF metadata.
//! Networking is confined to this module; sigstore.verify remains offline.
const std = @import("std");
const utils = @import("utils");
const tuf = @import("tuf.zig");
const schema = @import("schema.zig");
const INITIAL_ROOT = @embedFile("trust/root.json");
const MIRROR = "https://tuf-repo-cdn.sigstore.dev";
const CACHE_LIMIT = 16 * 1024 * 1024;

pub const Options = struct {
    offline: bool = false,
    cache: ?[]const u8 = null,
};

const Fetcher = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,

    pub fn fetch(self: Fetcher, path: []const u8, limit: usize) !?[]const u8 {
        const result = try std.process.run(self.a, self.io, .{
            .argv = &.{
                "curl",                                         "--disable",                       "--location",    "--silent",       "--show-error",
                "--proto",                                      "=https",                          "--proto-redir", "=https",         "--connect-timeout",
                "10",                                           "--max-time",                      "30",            "--retry",        "2",
                "--max-filesize",                               try self.a.print("{d}", .{limit}), "--write-out",   "\n%{http_code}", "--url",
                try self.a.print("{s}/{s}", .{ MIRROR, path }),
            },
            .environ_map = self.env,
            .stdout_limit = .limited(limit + 4),
            .stderr_limit = .limited(4096),
        });
        if (result.term != .exited or result.term.exited != 0) {
            std.log.err("Sigstore TUF download failed for {s}: {s}", .{ path, result.stderr });
            return error.TufDownloadFailed;
        }
        if (result.stdout.len < 4) return error.TufDownloadFailed;
        const boundary = result.stdout.len - 4;
        if (result.stdout[boundary] != '\n') return error.TufDownloadFailed;
        const status = result.stdout[boundary + 1 ..];
        if (std.mem.eql(u8, status, "404")) return null;
        if (!std.mem.eql(u8, status, "200")) return error.TufHttpError;
        if (boundary > limit) return error.TufDownloadTooLarge;
        return result.stdout[0..boundary];
    }
};

const Store = struct {
    a: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,

    pub fn save(self: Store, state: tuf.State) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.a, state, .{});
        defer self.a.free(bytes);
        if (bytes.len > CACHE_LIMIT) return error.TufCacheTooLarge;
        var output = try std.Io.Dir.cwd().createFileAtomic(self.io, try std.fs.path.join(self.a, &.{ self.directory, "state.json" }), .{
            .replace = true,
            .permissions = .fromMode(0o600),
        });
        defer output.deinit(self.io);
        try output.file.writePositionalAll(self.io, bytes, 0);
        try output.file.sync(self.io);
        try output.replace(self.io);
        // On the Linux host, sync the directory entry as well as the file data:
        // rollback protection must survive a crash immediately after replacement.
        const parent = try std.Io.Dir.cwd().openFile(self.io, self.directory, .{ .allow_directory = true });
        defer parent.close(self.io);
        try parent.sync(self.io);
    }
};

fn cachePath(a: std.mem.Allocator, env: *std.process.Environ.Map, options: Options) ![]const u8 {
    if (options.cache orelse env.get("PIZZA_SIGSTORE_CACHE")) |path| {
        if (path.len == 0) return error.InvalidTrustCachePath;
        return path;
    }
    if (env.get("XDG_CACHE_HOME")) |path| {
        if (std.fs.path.isAbsolute(path)) return std.fs.path.join(a, &.{ path, "pizza", "sigstore" });
    }
    return std.fs.path.join(a, &.{ env.get("HOME") orelse return error.MissingTrustCacheDirectory, ".cache", "pizza", "sigstore" });
}

pub fn load(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, options: Options, now: u64) !schema.TrustRoot {
    const directory = try cachePath(a, env, options);
    var offline = options.offline;
    if (env.get("PIZZA_SIGSTORE_OFFLINE")) |value| {
        if (std.mem.eql(u8, value, "1")) {
            offline = true;
        } else if (!std.mem.eql(u8, value, "0")) return error.InvalidTrustOfflineSetting;
    }
    try std.Io.Dir.cwd().createDirPath(io, directory);
    // Serialize readers and updaters so concurrent commands cannot roll back the cache.
    const lock = try std.Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ directory, "lock" }), .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = .fromMode(0o600),
    });
    defer lock.close(io);
    const cache = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ directory, "state.json" }), a, .limited(CACHE_LIMIT)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var state = if (cache) |bytes| try std.json.parseFromSliceLeaky(tuf.State, a, bytes, .{ .max_value_len = tuf.METADATA_LIMIT }) else tuf.State{};
    const bytes = if (offline)
        try tuf.offline(a, INITIAL_ROOT, state, now)
    else
        try tuf.refresh(a, INITIAL_ROOT, &state, now, Fetcher{ .a = a, .io = io, .env = env }, Store{ .a = a, .io = io, .directory = directory });
    return std.json.parseFromSliceLeaky(schema.TrustRoot, a, bytes, .{ .ignore_unknown_fields = true, .max_value_len = tuf.METADATA_LIMIT });
}

test {
    _ = tuf;
}

test "trust cache persists authenticated metadata and offline loading uses no subprocess" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const directory = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-tuf-cache-");
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", "/nonexistent");
    const now: u64 = 1792540800;
    try std.testing.expectError(error.MissingTufCache, load(a, io, &env, .{ .offline = true, .cache = directory }, now));
    const state = tuf.State{
        .timestamp = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixtures/sigstore/tuf/timestamp.json", a, .limited(tuf.METADATA_LIMIT)),
        .snapshot = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixtures/sigstore/tuf/166.snapshot.json", a, .limited(tuf.METADATA_LIMIT)),
        .targets = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixtures/sigstore/tuf/14.targets.json", a, .limited(tuf.METADATA_LIMIT)),
        .target = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixtures/sigstore/trusted_root.json", a, .limited(tuf.METADATA_LIMIT)),
    };
    const store = Store{ .a = a, .io = io, .directory = directory };
    try store.save(state);
    try env.put("PIZZA_SIGSTORE_CACHE", directory);
    try env.put("PIZZA_SIGSTORE_OFFLINE", "1");
    const root = try load(a, io, &env, .{}, now);
    try std.testing.expect(root.tlogs.len > 0 and root.ctlogs.len > 0 and root.certificateAuthorities.len > 0);
    try std.testing.expectError(error.ExpiredTufMetadata, load(a, io, &env, .{}, try utils.time.timestamp("2026-10-28T00:00:00Z")));
    var forged = state;
    forged.target = try a.dupe(u8, state.target.?);
    @constCast(forged.target.?)[0] ^= 1;
    try store.save(forged);
    try std.testing.expectError(error.TufHashMismatch, load(a, io, &env, .{}, now));
}
