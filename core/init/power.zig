//! PID 1's final power syscalls. Shutdown/durability policy lives in recovery.zig.
const std = @import("std");
const linux = std.os.linux;

pub const Action = enum { reboot, poweroff, halt };
pub const Error = error{ NotPid1, PowerOperationFailed, PowerOperationReturned };

pub fn request(action: Action) Error!noreturn {
    if (linux.getpid() != 1) return error.NotPid1;
    const command: linux.LINUX_REBOOT.CMD = switch (action) {
        .reboot => .RESTART,
        .poweroff => .POWER_OFF,
        .halt => .HALT,
    };
    const result = linux.reboot(.MAGIC1, .MAGIC2, command, null);
    if (linux.errno(result) != .SUCCESS) return error.PowerOperationFailed;
    return error.PowerOperationReturned;
}

pub fn poweroff() Error!noreturn {
    return request(.poweroff);
}

/// Route Ctrl-Alt-Del through PID 1's SIGINT handler and controlled shutdown.
pub fn configure() Error!void {
    if (linux.getpid() != 1) return error.NotPid1;
    if (linux.errno(linux.reboot(.MAGIC1, .MAGIC2, .CAD_OFF, null)) != .SUCCESS)
        return error.PowerOperationFailed;
}

test "power operations refuse ordinary processes before making a power syscall" {
    for (std.enums.values(Action)) |action|
        try std.testing.expectError(error.NotPid1, request(action));
    try std.testing.expectError(error.NotPid1, configure());
}
