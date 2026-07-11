//! Per-field metadata attached to a Spec field via `spec.Flag`/`Opt`/`Pos`/
//! `Rest`: help text, shell-completion behavior, and env/config/default
//! fallback. Read by `args`, `cli`, `help`, `complete`, and `schema` - never
//! duplicated, so a field's behavior can never drift from its declaration.

/// How a flag/option/positional value is completed by a generated shell
/// script. Read by `complete.Completion` and serialized by `schema.Emitter`.
pub const Complete = union(enum) {
    /// No candidates; the shell offers nothing for this slot.
    none,
    /// Delegate to the shell's own filename completion.
    files,
    /// A fixed candidate list, filtered against the word under the cursor.
    choices: []const []const u8,
    /// Resolved at completion time via the app's `resolveCompletion` hook
    /// (see `cli.Cli`'s `cfg.resolveCompletion`); the payload is the key
    /// passed to that hook.
    dynamic: []const u8,
};

/// Declares one Spec field's shape to `args`, `cli`, `help`, `complete`, and
/// `schema`. Constructed via `spec.Flag`/`Opt`/`Pos`/`Rest`, never directly.
pub const Meta = struct {
    /// Single-character alias (`-p` alongside `--port`). Flags/options only.
    short: ?u8 = null,
    /// Help text rendered in `--help` output and `schema`'s JSON envelope.
    help: []const u8 = "",
    /// Placeholder name for an option's value in its `--help` usage line
    /// (e.g. `--port <value>`).
    value_name: []const u8 = "value",
    /// Environment variable consulted when argv omits this field, before
    /// `config_key` and `default`.
    env: ?[]const u8 = null,
    /// Config-lookup key consulted when argv and `env` both miss, before
    /// `default`. Defaults to the field's own name when null.
    config_key: ?[]const u8 = null,
    /// String fallback used when argv, `env`, and `config_key` all miss.
    /// Parsed the same way as an argv-supplied value.
    default: ?[]const u8 = null,
    /// Shell-completion behavior for this field's value. See `Complete`.
    complete: Complete = .none,
    /// Positional-only: whether a missing value is `null` rather than a
    /// `UsageError`. Ignored for flags/options/variadic, whose optionality
    /// follows from their own `Args` field type.
    optional: bool = false,
};
