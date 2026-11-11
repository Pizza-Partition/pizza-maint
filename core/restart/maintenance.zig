//! Common maintenance actions for an already admitted device. No platform
//! acquisition, elevation, shell commands or implicit reboots occur here.
const std = @import("std");
const storage = @import("storage");
const wire = @import("proto").wire;
const ms = storage.recovery_session;
pub const Action = enum { prepare, bootstrap, apply, status, recover, undo, accept, cleanup };
pub fn restoreBoot(a: std.mem.Allocator, io: std.Io, session: ms.RecoverySession, lease: @import("uefi.zig").Lease, variables: @import("uefi.zig").Variables) !void {
    switch (session.phase) {
        .completed, .rolled_back, .failed_bootstrap => try lease.restore(a, io, variables),
        else => return error.MaintenanceStillOwnsBoot,
    }
}
pub fn run(a: std.mem.Allocator, io: std.Io, disk: storage.device.Device, bundle: ms.Bundle, action: Action, verifier: ?storage.program_executor.Verifier, observer: ?storage.program_executor.Observer) !wire.MaintenanceSession {
    var session = if (action == .prepare) try ms.RecoverySession.prepare(a, io, disk, bundle) else try ms.RecoverySession.open(a, io, disk, bundle);
    switch (action) {
        .prepare, .status => {},
        .bootstrap => try session.bootstrap(io, verifier, observer),
        .apply => try session.apply(io, verifier, observer),
        .recover => try session.recover(io),
        .undo => try session.undo(io),
        .accept => try session.accept(io),
        .cleanup => try session.cleanup(io, verifier, observer),
    }
    return project(a, session);
}
pub fn project(a: std.mem.Allocator, session: ms.RecoverySession) !wire.MaintenanceSession {
    return .{ .version = 4, .id = try a.dupe(u8, &std.fmt.bytesToHex(session.bundle.session, .lower)), .plan_digest = try a.dupe(u8, &std.fmt.bytesToHex(session.bundle.digest(), .lower)), .phase = switch (session.phase) {
        .preparing, .prepared => .prepared,
        .bootstrapping, .initialized => .bootstrapping,
        .preparing_apply, .applying => .applying,
        .verified => .verified,
        .undoing, .restoring_bootstrap => .undoing,
        .accepted => .accepted,
        .preparing_cleanup, .cleaning, .committing_cleanup => .cleaning,
        .completed => .completed,
        .rolled_back => .rolled_back,
        .failed_bootstrap, .failed_cleanup => .failed,
    }, .message = switch (session.phase) {
        .preparing => "Initializing maintenance recovery anchors.",
        .prepared => "Maintenance recovery anchors prepared.",
        .bootstrapping => "Creating the temporary maintenance area.",
        .initialized => "Temporary maintenance area verified; user plan has not run.",
        .preparing_apply => "Initializing the temporary transaction store.",
        .applying => "Applying the approved plan.",
        .verified => "Changes verified. Undo remains available until acceptance.",
        .undoing => "Restoring user changes.",
        .restoring_bootstrap => "Restoring the layout preceding maintenance setup.",
        .accepted => "Changes accepted. Undo is closed; cleanup is pending.",
        .preparing_cleanup => "Reinitializing cleanup recovery after rollback.",
        .cleaning => "Removing the temporary maintenance area.",
        .committing_cleanup => "Finalizing verified cleanup.",
        .completed => "Final layout verified; boot restoration may proceed.",
        .rolled_back => "User changes and maintenance layout restored.",
        .failed_bootstrap => "Interrupted setup restored. Remain in maintenance.",
        .failed_cleanup => "Interrupted cleanup restored to the accepted layout. Remain in maintenance.",
    } };
}
