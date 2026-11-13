//! Offline policy over the shared protocol's pure plan admission.
const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;
const common = proto.plan_validation;
pub const optimize = common.optimize;
pub fn validate(a: std.mem.Allocator, inventory: wire.InventorySnapshot, draft: wire.PlanDraft) !wire.ValidatedPlan {
    var base = try common.validate(a, inventory, draft);
    try common.admitMaintenance(a, &base.diagnostics, base.disk, draft);
    try common.diagnostic(a, &base.diagnostics, "offline_validation_required", "Filesystem feasibility, bootstrap and cleanup reservations must be verified offline before any target write.", null);
    // This note is informational: feasibility remains an offline preflight gate.
    base.diagnostics.items[base.diagnostics.items.len - 1].severity = .info;
    return .{ .version = proto.API_VERSION, .digest = base.digest, .executable = false, .offline_validation_required = true, .diagnostics = try base.diagnostics.toOwnedSlice(a), .operations = base.operations, .destructive_partitions = try base.destructive_partitions.toOwnedSlice(a), .draft = draft };
}
