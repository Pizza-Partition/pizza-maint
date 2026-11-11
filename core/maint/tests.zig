//! Maintenance tests need their own module root; dependency tests are not discovered.
test {
    _ = @import("legacy_backend.zig");
    _ = @import("testing/execution_tests.zig");
    _ = @import("testing/simulated_plan.zig");
}
