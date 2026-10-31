//! Common contracts enroll all registered backends; format-specific tests are
//! additional coverage rather than separate copies of the shared framework.
test {
    _ = @import("filesystem/suite.zig");
    _ = @import("filesystem/semantic_tests.zig");
    _ = @import("filesystem/layout_tests.zig");
    _ = @import("filesystem/copy_tests.zig");
    _ = @import("filesystem/memory_tests.zig");
    _ = @import("filesystem/ext/tests.zig");
    _ = @import("filesystem/fat32/tests.zig");
    _ = @import("filesystem/ntfs/tests.zig");
    _ = @import("filesystem/btrfs/tests.zig");
}
