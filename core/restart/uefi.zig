//! Shared firmware contract; OS adapters implement Variables.
const shared = @import("proto").uefi;
pub const GLOBAL_GUID = shared.GLOBAL_GUID;
pub const PIZZA_GUID = shared.PIZZA_GUID;
pub const SecureBoot = shared.SecureBoot;
pub const secureBootState = shared.secureBootState;
pub const Variable = shared.Variable;
pub const Variables = shared.Variables;
pub const loadOption = shared.loadOption;
pub const MemoryVariables = shared.MemoryVariables;
pub const Lease = shared.StrictLease;
