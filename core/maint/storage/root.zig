//! Native filesystem architecture. Production mutation is gated independently.
pub const model = @import("model.zig");
pub const device = @import("device.zig");
pub const block_device = @import("block_device.zig");
pub const partition = @import("partition.zig");
pub const space = @import("space.zig");
pub const filesystem = @import("filesystem/root.zig");
pub const ext = @import("filesystem/ext/root.zig");
pub const fat32 = @import("filesystem/fat32/root.zig");
pub const btrfs = @import("filesystem/btrfs/root.zig");
pub const ntfs = @import("filesystem/ntfs/root.zig");
pub const recovery_store = @import("recovery_store.zig");
pub const probe = @import("probe.zig");

/// Test-only support; production uses semantic filesystems and physical programs.
pub const testing = if (@import("builtin").is_test or (@hasDecl(@import("root"), "enable_storage_test_support") and @import("root").enable_storage_test_support)) @import("testing/support.zig") else struct {};
pub const memory = @import("memory.zig");
pub const mutation = @import("mutation.zig");
pub const partition_table = @import("partition_table.zig");
pub const program = @import("program.zig");
pub const program_executor = @import("program_executor.zig");
pub const recovery_session = @import("recovery_session.zig");
pub const esp_anchor = @import("esp_anchor.zig");
pub const semantic = @import("semantic.zig");
pub const algorithm = @import("algorithm.zig");
pub const service = @import("service.zig");

pub const session_admission = @import("session_admission.zig");
