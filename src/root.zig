//! cli-zig: a comptime-typed CLI framework for Zig.
const std = @import("std");
const spec = @import("spec.zig");
const args = @import("args.zig");

/// Comptime-parameterized command dispatcher. See `src/app.zig`.
pub const App = @import("app.zig").App;

/// Spec field-type constructors. See `src/spec.zig`.
pub const Flag = spec.Flag;
pub const Opt = spec.Opt;
pub const Pos = spec.Pos;
pub const Rest = spec.Rest;

/// A flag-shaped token: starts with `-` and is more than a bare `-`.
pub const looksLikeFlag = spec.looksLikeFlag;

/// The typed result struct a Spec reifies to. See `src/args.zig`.
pub const Args = args.Args;
/// Parses argv into `Args(Spec)`, resolving each field by
/// argv > env > config > default.
pub const parseInto = args.parseInto;
/// Env/config lookup hooks for `parseInto` (what `cfg.makeSource` returns).
pub const Source = args.Source;
/// Carries the human-readable message of a parse or context-load failure.
pub const Diagnostic = args.Diagnostic;

/// Per-field metadata (help text, completion, env/config/default fallback).
/// See `src/meta.zig`.
pub const meta = @import("meta.zig");
/// Shell-completion candidate engine (`Result`/`Candidate`/`Directive`).
/// See `src/complete.zig`.
pub const complete = @import("complete.zig");

test "root builds" {
    try std.testing.expect(true);
}

test {
    _ = meta;
    _ = spec;
    _ = args;
    _ = @import("parse.zig");
    _ = @import("resolve.zig");
    _ = @import("app.zig");
    _ = @import("help.zig");
    _ = complete;
    _ = @import("shells.zig");
    _ = @import("schema.zig");
}
