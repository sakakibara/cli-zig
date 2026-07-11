//! cli-zig: a comptime-typed CLI framework for Zig.
const std = @import("std");

/// Per-field metadata (help text, completion, env/config/default fallback).
/// See `src/meta.zig`.
pub const meta = @import("meta.zig");
/// Spec field-type constructors: `Flag`/`Opt`/`Pos`/`Rest`. See `src/spec.zig`.
pub const spec = @import("spec.zig");
/// Reifies a Spec into its typed result and resolves it from argv/env/
/// config/defaults. See `src/args.zig`.
pub const args = @import("args.zig");
/// Left-to-right argv classifier underlying `args.parseInto`. See
/// `src/parse.zig`.
pub const parse = @import("parse.zig");
/// Parses a resolved string value to a Spec field's declared type. See
/// `src/resolve.zig`.
pub const resolve = @import("resolve.zig");
/// Comptime-parameterized command dispatcher (`Cli(cfg)`). See `src/cli.zig`.
pub const cli = @import("cli.zig");
/// Renders `--help` output from a command table. See `src/help.zig`.
pub const help = @import("help.zig");
/// Shell-completion candidate engine. See `src/complete.zig`.
pub const complete = @import("complete.zig");
/// Generated shell-completion scripts (bash/zsh/fish/powershell). See
/// `src/shells.zig`.
pub const shells = @import("shells.zig");
/// Emits a command table as a versioned JSON envelope. See `src/schema.zig`.
pub const schema = @import("schema.zig");

test "root builds" {
    try std.testing.expect(true);
}

test {
    _ = meta;
    _ = spec;
    _ = args;
    _ = parse;
    _ = resolve;
    _ = cli;
    _ = help;
    _ = complete;
    _ = shells;
    _ = schema;
}
