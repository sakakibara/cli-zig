//! Field-type constructors for a Spec struct: `Flag`/`Opt`/`Pos`/`Rest` each
//! produce a distinct type carrying an `arg_info` declaration, the single
//! source `args.Args`, `cli.command`, `help`, `complete`, and `schema` all
//! read to derive a field's runtime behavior.
const std = @import("std");
const meta = @import("meta.zig");
/// Re-exported for convenience: see `meta.Meta`.
pub const Meta = meta.Meta;

/// A Spec field's shape, as declared via `Flag`/`Opt`/`Pos`/`Rest`.
pub const Kind = enum { flag, option, positional, variadic };

/// A Spec field's full declaration: its `Kind`, the value type it parses to,
/// and its `Meta`. Read off a field's type as `@field(FieldType, "arg_info")`.
pub const Info = struct { kind: Kind, Value: type, meta: Meta };

/// Boolean presence flag (e.g. `--json`). Never takes a value; `Args`
/// maps it to `bool`, defaulting to `false`.
pub fn Flag(comptime m: Meta) type {
    return struct {
        /// This field's `Info`, read by `args.Args` and `cli.command`.
        pub const arg_info = Info{ .kind = .flag, .Value = bool, .meta = m };
    };
}
/// A value-taking flag (`--port 8080` or `--port=8080`). `Args` maps it to
/// `?T`, defaulting to `null` (or `m.default`, parsed, when set).
pub fn Opt(comptime T: type, comptime m: Meta) type {
    return struct {
        /// This field's `Info`, read by `args.Args` and `cli.command`.
        pub const arg_info = Info{ .kind = .option, .Value = T, .meta = m };
    };
}
/// A required or (when `m.optional` is true) optional positional argument.
/// `Args` maps it to `T` or `?T` respectively.
pub fn Pos(comptime T: type, comptime m: Meta) type {
    return struct {
        /// This field's `Info`, read by `args.Args` and `cli.command`.
        pub const arg_info = Info{ .kind = .positional, .Value = T, .meta = m };
    };
}
/// The variadic tail after every fixed positional and `--`. At most one per
/// Spec. `Args` maps it to `[]const []const u8`, defaulting to `&.{}`.
pub fn Rest(comptime m: Meta) type {
    return struct {
        /// This field's `Info`, read by `args.Args` and `cli.command`.
        pub const arg_info = Info{ .kind = .variadic, .Value = []const []const u8, .meta = m };
    };
}

/// A flag-shaped token: starts with `-` and is more than a bare `-`.
pub fn looksLikeFlag(s: []const u8) bool {
    return s.len > 1 and s[0] == '-';
}

/// Canonical flag/option long spelling for a Spec field name: underscores
/// become hyphens. The single source both the parser and help/completion/
/// schema derive their `--long` spelling from.
pub fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = name[0..name.len].*;
        for (&buf) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const final = buf;
        return &final;
    }
}

test "kebab replaces underscores with hyphens" {
    try std.testing.expectEqualStrings("old-org", comptime kebab("old_org"));
    try std.testing.expectEqualStrings("port", comptime kebab("port"));
    try std.testing.expectEqualStrings("a-b-c", comptime kebab("a_b_c"));
}

test "Flag/Opt/Pos/Rest expose arg_info with the right kind and Value" {
    const F = Flag(.{ .help = "json out" });
    try std.testing.expectEqual(Kind.flag, F.arg_info.kind);
    try std.testing.expectEqual(bool, F.arg_info.Value);

    const O = Opt(u16, .{ .short = 'p' });
    try std.testing.expectEqual(Kind.option, O.arg_info.kind);
    try std.testing.expectEqual(u16, O.arg_info.Value);
    try std.testing.expectEqual(@as(?u8, 'p'), O.arg_info.meta.short);

    const P = Pos([]const u8, .{ .help = "name" });
    try std.testing.expectEqual(Kind.positional, P.arg_info.kind);

    const R = Rest(.{});
    try std.testing.expectEqual(Kind.variadic, R.arg_info.kind);
}
