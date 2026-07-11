//! Parses a resolved string value (from argv, env, config, or a default) to
//! a Spec field's declared `Value` type. Boolean flags are presence-only and
//! never reach this helper -- the caller reads `Parser.flag`'s return
//! directly. Bad input is always `error.UsageError`, never a panic or a
//! silently-wrong zero value.
const std = @import("std");

/// The single error `parseValue` returns for any bad input.
pub const Error = error{UsageError};

/// Parses `s` to `T`: `[]const u8` passes through verbatim, integers via
/// `std.fmt.parseInt` (base 10), enums via `std.meta.stringToEnum`. Any
/// other `T` is a compile error - extend the switch to add a type.
pub fn parseValue(comptime T: type, s: []const u8) Error!T {
    if (T == []const u8) return s;
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, s, 10) catch error.UsageError,
        .@"enum" => std.meta.stringToEnum(T, s) orelse error.UsageError,
        else => @compileError("resolve.parseValue: unsupported value type " ++ @typeName(T)),
    };
}

test "parseValue: ints parse or report UsageError on bad input" {
    try std.testing.expectEqual(@as(u16, 8080), try parseValue(u16, "8080"));
    try std.testing.expectError(error.UsageError, parseValue(u16, "not-a-number"));
}

test "parseValue: enums parse via stringToEnum or report UsageError" {
    const Level = enum { low, high };
    try std.testing.expectEqual(Level.high, try parseValue(Level, "high"));
    try std.testing.expectError(error.UsageError, parseValue(Level, "medium"));
}

test "parseValue: []const u8 passes through verbatim" {
    try std.testing.expectEqualStrings("widget", try parseValue([]const u8, "widget"));
}
