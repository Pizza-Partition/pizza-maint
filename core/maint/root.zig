//! Maintenance business state shared by the application and execution UIs.
pub const backend = @import("backend.zig");
pub const devices = @import("devices.zig");
pub const plan = @import("plan.zig");
pub const storage = @import("storage");
pub const Testing = struct {
    pub const devices = @import("testing/devices.zig");
    pub const simulated_plan = @import("testing/simulated_plan.zig");
    pub const execution_tests = @import("testing/execution_tests.zig");
};
