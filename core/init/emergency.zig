//! Allocation-free, bounded best-effort output, also usable after a panic.
const linux = @import("std").os.linux;

pub fn write(bytes: []const u8) void {
    _ = writeTo(linux.STDERR_FILENO, bytes);
}

pub fn writeTo(fd: linux.fd_t, bytes: []const u8) bool {
    var remaining = bytes;
    for (0..16) |_| {
        if (remaining.len == 0) return true;
        const result = linux.write(fd, remaining.ptr, remaining.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return false;
                remaining = remaining[result..];
            },
            .INTR => continue,
            else => return false,
        }
    }
    return remaining.len == 0;
}
