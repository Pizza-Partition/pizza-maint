//! Test-only fixtures and execution harness shared by independently compiled tests.
pub const ImageDevice = @import("image_device.zig").ImageDevice;
pub const Image = @import("image.zig").Image;
pub const fixture = @import("fixture.zig");
pub const crash_model = @import("crash_model.zig");
pub const ext_tools = @import("filesystem/ext/tools.zig");
pub const tools = @import("tools.zig");
pub const filesystems = @import("filesystem/fixtures.zig");
pub const btrfs_fixture = @import("filesystem/btrfs/fixture.zig");
pub const executor = @import("executor.zig");

pub const gpt_fixture = @import("gpt_fixture.zig");
