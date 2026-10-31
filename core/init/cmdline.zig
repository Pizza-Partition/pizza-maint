//! Non-secret maintenance options. Session secrets must use a protected RAM file.
const std = @import("std");

pub const Parameters = struct {
    boot: enum { normal, smoke, selftest, backend_test, storage_test, reboot_test } = .normal,
    plan_id: ?[]const u8 = null,
    kiosk: enum { enabled, disabled } = .enabled,
    journal: enum { enabled, disabled, fsync_fail } = .enabled,
    step_fail: ?u32 = null,
    step_hang: ?u32 = null,
    fsync_fail_step: ?u32 = null,
};

/// Borrows strings from `line`. Ignores kernel options; rejects unknown, duplicate
/// or malformed pizza options without including their values in diagnostics.
pub fn parse(line: []const u8) !Parameters {
    if (line.len > 16 * 1024) return error.CommandLineTooLong;
    const Key = std.meta.FieldEnum(Parameters);
    var seen: std.EnumSet(Key) = .empty;
    var result: Parameters = .{};
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n");
    while (tokens.next()) |token| {
        if (!std.mem.startsWith(u8, token, "pizza.")) continue;
        const equal = std.mem.indexOfScalar(u8, token, '=') orelse return error.MissingParameterValue;
        const name = token[6..equal];
        if (std.mem.eql(u8, name, "nonce")) return error.SecretOnCommandLine;
        const key = std.meta.stringToEnum(Key, name) orelse return error.UnknownParameter;
        if (seen.contains(key)) return error.DuplicateParameter;
        seen.insert(key);
        const value = token[equal + 1 ..];
        switch (key) {
            .boot => result.boot = std.meta.stringToEnum(@TypeOf(result.boot), value) orelse return error.InvalidBootMode,
            .plan_id => {
                if (value.len == 0 or value.len > 128) return error.InvalidPlanId;
                for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidPlanId;
                result.plan_id = value;
            },
            .kiosk => result.kiosk = if (try enabled(value)) .enabled else .disabled,
            .journal => result.journal = if (std.mem.eql(u8, value, "fsync_fail")) .fsync_fail else if (try enabled(value)) .enabled else .disabled,
            .step_fail => result.step_fail = try step(value),
            .step_hang => result.step_hang = try step(value),
            .fsync_fail_step => result.fsync_fail_step = try step(value),
        }
    }
    return result;
}

fn enabled(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "enable")) return true;
    if (std.mem.eql(u8, value, "disable")) return false;
    return error.InvalidSwitch;
}

fn step(value: []const u8) !u32 {
    for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidStep;
    const number = std.fmt.parseInt(u32, value, 10) catch return error.InvalidStep;
    if (number == 0 or number > 20) return error.InvalidStep;
    return number;
}

test "kernel options are ignored and maintenance options are parsed without secrets" {
    const p = try parse("console=ttyS0 root=/dev/ignored pizza.boot=selftest pizza.plan_id=plan_01 pizza.kiosk=disable pizza.journal=fsync_fail pizza.step_fail=20 pizza.step_hang=1 pizza.fsync_fail_step=7\n");
    try std.testing.expectEqual(.selftest, p.boot);
    try std.testing.expectEqualStrings("plan_01", p.plan_id.?);
    try std.testing.expectEqual(.disabled, p.kiosk);
    try std.testing.expectEqual(.fsync_fail, p.journal);
    try std.testing.expectEqual(@as(?u32, 20), p.step_fail);
    try std.testing.expectEqual(@as(?u32, 1), p.step_hang);
    try std.testing.expectEqual(@as(?u32, 7), p.fsync_fail_step);
    try std.testing.expectEqual(.normal, (try parse("quiet")).boot);
}

test "malformed and ambiguous maintenance parameters fail closed" {
    try std.testing.expectError(error.DuplicateParameter, parse("pizza.kiosk=enable pizza.kiosk=disable"));
    try std.testing.expectError(error.SecretOnCommandLine, parse("pizza.nonce=secret"));
    try std.testing.expectError(error.UnknownParameter, parse("pizza.typo=1"));
    try std.testing.expectError(error.MissingParameterValue, parse("pizza.kiosk"));
    try std.testing.expectError(error.InvalidSwitch, parse("pizza.kiosk=maybe"));
    try std.testing.expectError(error.InvalidBootMode, parse("pizza.boot=shutdown"));
    try std.testing.expectError(error.InvalidPlanId, parse("pizza.plan_id=../../disk"));
    for ([_][]const u8{ "", "0", "21", "-1", "+1", "999999999999999999999" }) |value| {
        var buffer: [128]u8 = undefined;
        try std.testing.expectError(error.InvalidStep, parse(try std.fmt.bufPrint(&buffer, "pizza.step_fail={s}", .{value})));
    }
}
