//! Comptime-parameterized command dispatcher. `Cli(cfg)` monomorphizes a
//! `Ctx`/`Command`/`run` for one app's context type and help-grouping enum,
//! so a command only ever implements its own `run`.
const std = @import("std");
const spec = @import("spec.zig");
const args = @import("args.zig");
const meta = @import("meta.zig");
const help = @import("help.zig");
const complete = @import("complete.zig");
const shells = @import("shells.zig");
const schema = @import("schema.zig");

/// A single flag/option, derived from a Spec field's `arg_info` at comptime -
/// the same declaration the parser reads from, so help can never drift from
/// what argv accepts.
pub const Flag = struct {
    long: []const u8,
    short: ?u8 = null,
    help: []const u8 = "",
    takes_value: bool = false,
    value_name: []const u8 = "value",
    complete: meta.Complete = .none,
};

/// One positional/variadic slot, derived the same way.
pub const Arg = struct {
    name: []const u8,
    complete: meta.Complete = .none,
    optional: bool = false,
    variadic: bool = false,
};

fn deriveFlags(comptime Spec: type) []const Flag {
    comptime {
        var flags: []const Flag = &.{};
        for (@typeInfo(Spec).@"struct".fields) |f| {
            const info = @field(f.type, "arg_info");
            if (info.kind != .flag and info.kind != .option) continue;
            const long = spec.kebab(f.name);
            flags = flags ++ [_]Flag{.{
                .long = long,
                .short = info.meta.short,
                .help = info.meta.help,
                .takes_value = info.kind == .option,
                .value_name = info.meta.value_name,
                .complete = info.meta.complete,
            }};
        }
        return flags;
    }
}

fn deriveArgs(comptime Spec: type) []const Arg {
    comptime {
        var out: []const Arg = &.{};
        for (@typeInfo(Spec).@"struct".fields) |f| {
            const info = @field(f.type, "arg_info");
            if (info.kind != .positional and info.kind != .variadic) continue;
            out = out ++ [_]Arg{.{
                .name = f.name,
                .complete = info.meta.complete,
                .optional = info.meta.optional or info.kind == .variadic,
                .variadic = info.kind == .variadic,
            }};
        }
        return out;
    }
}

fn emptyEnv(_: []const u8) ?[]const u8 {
    return null;
}

fn isHelpFlag(s: []const u8) bool {
    return std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h");
}

/// A help request is `-h`/`--help` appearing BEFORE the first bare `--`.
/// Tokens at or after `--` are passthrough (e.g. for a `Rest`-wrapped program),
/// so `app files -- --help` must not hijack the wrapped program's `--help`.
fn hasHelpFlag(argv: []const []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, "--")) return false;
        if (isHelpFlag(a)) return true;
    }
    return false;
}

/// Writes a usage error to `err_w`: `message`, then `usage` prefixed with
/// "usage: " when non-empty.
fn writeUsageError(err_w: *std.Io.Writer, message: []const u8, usage: []const u8) void {
    err_w.print("{s}\n", .{message}) catch {};
    if (usage.len > 0) err_w.print("usage: {s}\n", .{usage}) catch {};
}

/// Bounded Levenshtein edit distance; command names are short so a fixed
/// 32-byte stack row never needs to grow.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 31 or b.len > 31) {
        return if (a.len > b.len) a.len - b.len else b.len - a.len;
    }

    var prev: [32]usize = undefined;
    var curr: [32]usize = undefined;
    for (0..b.len + 1) |i| prev[i] = i;

    for (0..a.len) |i| {
        curr[0] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            curr[j + 1] = @min(@min(prev[j + 1] + 1, curr[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Per-app configuration: `cfg.Context` is the app-specific value a command
/// can request via `needs_context`, `cfg.Group` sections commands in help,
/// and `cfg.loadContext` produces a `Context`. On a failed load, `run` reads
/// `diag.message` but never frees it; an allocation `loadContext` makes for
/// that message is the app's own to own, reclaimed for free by the process
/// exit that follows a terminal load failure. `cfg` is a comptime struct
/// literal (its field values carry their own concrete types), not a named
/// type, so `Cli` can build `Ctx`/`Command` around whatever `Context` and
/// `Group` the caller supplies.
pub fn Cli(comptime cfg: anytype) type {
    return struct {
        /// Per-dispatch state handed to a command's `run`. `context` is
        /// populated only for commands that declare `needs_context`.
        pub const Ctx = struct {
            alloc: std.mem.Allocator,
            io: std.Io,
            context: ?cfg.Context = null,
            out: *std.Io.Writer,
            err: *std.Io.Writer,
            argv: []const []const u8 = &.{},
        };

        /// One registered command. `group` places it in help output;
        /// `needs_context` gates whether `run` loads `cfg.Context` before
        /// dispatch; `subcommands` nests further commands to arbitrary
        /// depth - a subcommand's own `subcommands` field may in turn carry
        /// its own subcommands, and so on, with no built-in limit.
        pub const Command = struct {
            name: []const u8,
            summary: []const u8 = "",
            usage: []const u8 = "",
            group: cfg.Group,
            details: []const u8 = "",
            needs_context: bool = false,
            run: *const fn (ctx: *Ctx) anyerror!u8,
            subcommands: []const Command = &.{},
            /// Flags/options derived from a Spec at comptime by `command()`,
            /// for help/completion to render without a second hand-written copy.
            flags: []const Flag = &.{},
            /// Positional/variadic slots derived from a Spec at comptime.
            args: []const Arg = &.{},
        };

        /// Renders help from `Command`/`Flag`/`Arg`/`cfg.Group` alone - the
        /// same metadata `command()` derives from a Spec, never a second
        /// hand-written help string.
        const HelpRenderer = help.Renderer(Command, Flag, Arg, cfg.Group);

        /// Produces shell-completion candidates from `Command`/`Flag`/`Arg`
        /// alone, the same metadata help renders from.
        const Completion = complete.Completion(Command, Flag, Arg, Ctx);
        /// The dynamic-completion resolver hook type for this `Cli(cfg)`.
        /// See `complete.Completion.Resolve`.
        pub const CompletionResolve = Completion.Resolve;
        /// Writes a completion reply for `words` to a writer. See
        /// `complete.Completion.reply`.
        pub const completionReply = Completion.reply;
        /// Computes a completion `Result` for `words`. See
        /// `complete.Completion.compute`.
        pub const completionCompute = Completion.compute;

        /// Emits the command table as JSON from `Command`/`Flag`/`Arg` alone,
        /// the same metadata help renders from.
        const Schema = schema.Emitter(Command, Flag, Arg, cfg.Group);

        /// Adapts `cfg.resolveCompletion` (whose `ctx` param is `anytype`,
        /// since `Ctx` cannot be named from outside `Cli(cfg)`, the same
        /// reason `makeSource` takes `anytype`) into a concrete `CompletionResolve`
        /// function pointer closed over this `Ctx`.
        const ResolveAdapter = struct {
            fn resolve(alloc: std.mem.Allocator, key: []const u8, prev: ?[]const u8, cur: []const u8, ctx: *Ctx) anyerror!complete.Result {
                return cfg.resolveCompletion(alloc, key, prev, cur, ctx);
            }
        };

        /// An app opts into dynamic completion categories (a `.dynamic` spec
        /// key resolving to real values) by putting a `resolveCompletion` on
        /// `cfg` - the same `@hasField` gate `makeSource` uses. It receives
        /// the word under the cursor (`cur`) and owns the full `Result`
        /// (directive and candidates); cli-zig does not filter a `.dynamic`
        /// reply. Absent `resolveCompletion`, every `.dynamic` spec completes
        /// to no candidates.
        pub const completion_resolve: CompletionResolve = if (@hasField(@TypeOf(cfg), "resolveCompletion"))
            &ResolveAdapter.resolve
        else
            null;

        /// An app opts into custom group headings in `renderTop` by putting a
        /// `groupHeading` on `cfg` - the same `@hasField` gate `makeSource`
        /// uses. Absent it, `renderTop` prints each `Group` enum field name.
        pub const group_heading: ?*const fn (group: cfg.Group) []const u8 = if (@hasField(@TypeOf(cfg), "groupHeading"))
            cfg.groupHeading
        else
            null;

        /// An app opts into a custom `renderTop` footer by putting a
        /// `renderHelpFooter` on `cfg`. Absent it, `renderTop` prints its
        /// built-in "run --help"/"completion" trailer.
        pub const help_footer: ?*const fn (w: *std.Io.Writer, prog_name: []const u8) anyerror!void = if (@hasField(@TypeOf(cfg), "renderHelpFooter"))
            cfg.renderHelpFooter
        else
            null;

        /// Adapts `cfg.renderTopHelp` (whose `commands` param is `anytype`,
        /// since `Command` cannot be named from outside `Cli(cfg)`, the same
        /// reason `ResolveAdapter` wraps `resolveCompletion`) into a
        /// concrete-typed function pointer closed over this `Command`.
        const RenderTopAdapter = struct {
            fn render(w: *std.Io.Writer, prog_name: []const u8, commands: []const Command) anyerror!void {
                return cfg.renderTopHelp(w, prog_name, commands);
            }
        };

        /// An app opts into fully replacing top-level help by putting a
        /// `renderTopHelp` on `cfg` - the same `@hasField` gate `makeSource`
        /// uses. Absent it, `run` falls back to the built-in
        /// `HelpRenderer.renderTop`.
        pub const render_top_help: ?*const fn (w: *std.Io.Writer, prog_name: []const u8, commands: []const Command) anyerror!void = if (@hasField(@TypeOf(cfg), "renderTopHelp"))
            &RenderTopAdapter.render
        else
            null;

        /// Adapts `cfg.renderCommandHelp` the same way `RenderTopAdapter`
        /// adapts `renderTopHelp`.
        const RenderCommandAdapter = struct {
            fn render(w: *std.Io.Writer, prog_name: []const u8, cmd: Command) anyerror!void {
                return cfg.renderCommandHelp(w, prog_name, cmd);
            }
        };

        /// An app opts into fully replacing per-command help by putting a
        /// `renderCommandHelp` on `cfg`. Absent it, `run` falls back to the
        /// built-in `HelpRenderer.renderCommand`.
        pub const render_command_help: ?*const fn (w: *std.Io.Writer, prog_name: []const u8, command: Command) anyerror!void = if (@hasField(@TypeOf(cfg), "renderCommandHelp"))
            &RenderCommandAdapter.render
        else
            null;

        /// Writes top-level help: `cfg.renderTopHelp` when present, else the
        /// built-in grouped command table.
        fn writeTopHelp(out: *std.Io.Writer, prog_name: []const u8, commands: []const Command) void {
            if (render_top_help) |f| {
                f(out, prog_name, commands) catch {};
            } else {
                HelpRenderer.renderTop(out, prog_name, commands, group_heading, help_footer) catch {};
            }
        }

        /// Writes one command's help: `cfg.renderCommandHelp` when present,
        /// else the built-in synopsis/flags/args table.
        fn writeCommandHelp(alloc: std.mem.Allocator, out: *std.Io.Writer, prog_name: []const u8, cmd: Command) void {
            if (render_command_help) |f| {
                f(out, prog_name, cmd) catch {};
            } else {
                HelpRenderer.renderCommand(alloc, out, cmd) catch {};
            }
        }

        /// An app opts into human error messages by putting a `describeError`
        /// on `cfg` - the same `@hasField` gate `makeSource` uses. `run`'s
        /// error boundary consults it for both a command-body error and a
        /// `loadContext` failure; when it returns a message for a given
        /// error, `run` prints that instead of `error: <name>`. Absent it,
        /// or when it returns null for a given error, `run` falls back to
        /// `error: <name>`.
        pub const describe_error: ?*const fn (err: anyerror) ?[]const u8 = if (@hasField(@TypeOf(cfg), "describeError"))
            cfg.describeError
        else
            null;

        /// The non-derivable command attributes `command()` needs alongside a
        /// Spec: everything the Spec itself cannot express (name, help text,
        /// grouping, whether the command needs a loaded `cfg.Context`).
        pub const About = struct {
            name: []const u8,
            summary: []const u8 = "",
            usage: []const u8 = "",
            group: cfg.Group,
            details: []const u8 = "",
            needs_context: bool = false,
            /// Mutually-exclusive groups: within each inner list of field
            /// names, at most one may be provided, else `command()`'s
            /// trampoline reports a usage error naming the conflicting two.
            /// Field names are comptime-checked against `Spec`, so a typo is
            /// a build error, never a silent no-op. A required (non-optional,
            /// non-bool) field is always "provided" per `isProvided`, so
            /// putting one in a group makes that group perpetually conflict -
            /// only optional fields and bool flags belong in `exclusive`.
            exclusive: []const []const []const u8 = &.{},
        };

        /// Validates every field name in `about.exclusive` against `Spec` at
        /// comptime, so a mistyped constraint is a build error rather than a
        /// silently-ignored group.
        fn validateExclusive(comptime Spec: type, comptime about: About) void {
            for (about.exclusive) |group| {
                for (group) |name| {
                    if (!@hasField(Spec, name))
                        @compileError("exclusive constraint names \"" ++ name ++ "\", which is not a field of the schema");
                }
            }
        }

        /// A field is "provided" when the user gave it: a bool flag that is
        /// true, or an optional option/positional that is non-null. A
        /// required field is always provided.
        fn isProvided(comptime Spec: type, parsed: args.Args(Spec), comptime name: []const u8) bool {
            const v = @field(parsed, name);
            return switch (@typeInfo(@TypeOf(v))) {
                .bool => v,
                .optional => v != null,
                else => true,
            };
        }

        /// Checks `about.exclusive` against `parsed`: returns the kebab-
        /// spelled pair of the first two fields provided within the same
        /// group, or null when every group has at most one field provided.
        fn exclusiveConflict(comptime Spec: type, comptime about: About, parsed: args.Args(Spec)) ?[2][]const u8 {
            inline for (about.exclusive) |group| {
                var first: ?[]const u8 = null;
                inline for (group) |name| {
                    if (isProvided(Spec, parsed, name)) {
                        const spelled = comptime spec.kebab(name);
                        if (first) |a| return .{ a, spelled };
                        first = spelled;
                    }
                }
            }
            return null;
        }

        /// Builds a `Command` from a typed Spec: derives its flags/args
        /// metadata at comptime, and wraps `run_fn` in a trampoline that
        /// parses `ctx.argv` into `args.Args(Spec)` before calling it. A
        /// `UsageError` from the parse writes the diagnostic and the
        /// command's usage to `ctx.err` and returns exit code 2 without
        /// calling `run_fn`. A conflict within an `about.exclusive` group is
        /// checked after a successful parse and reported the same way.
        pub fn command(
            comptime Spec: type,
            comptime about: About,
            comptime run_fn: fn (ctx: *Ctx, parsed: args.Args(Spec)) anyerror!u8,
        ) Command {
            comptime validateExclusive(Spec, about);

            const Trampoline = struct {
                fn run(ctx: *Ctx) anyerror!u8 {
                    // parseInto's `rest` slice and a failed parse's
                    // `Diagnostic.message` are alloc-owned; an arena scoped to
                    // this one dispatch frees them wholesale on return instead
                    // of requiring the trampoline to track each allocation.
                    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
                    defer arena_state.deinit();

                    var diag = args.Diagnostic{};
                    // An app opts into real env/config by putting a `makeSource`
                    // on `cfg`; since `run` loads `ctx.context` first, the source
                    // it builds can depend on the loaded context. Absent it, argv
                    // and `.default` are the only inputs.
                    const source = if (@hasField(@TypeOf(cfg), "makeSource"))
                        cfg.makeSource(ctx)
                    else
                        args.Source{ .env_get = emptyEnv, .config_get = null };
                    const parsed = args.parseInto(Spec, arena_state.allocator(), ctx.argv, source, &diag) catch |e| switch (e) {
                        error.OutOfMemory => return e,
                        error.UsageError => {
                            writeUsageError(ctx.err, diag.message, about.usage);
                            return 2;
                        },
                    };
                    if (exclusiveConflict(Spec, about, parsed)) |conflict| {
                        const msg = std.fmt.allocPrint(arena_state.allocator(), "--{s} and --{s} are mutually exclusive", .{ conflict[0], conflict[1] }) catch "mutually exclusive flags";
                        writeUsageError(ctx.err, msg, about.usage);
                        return 2;
                    }
                    return run_fn(ctx, parsed);
                }
            };

            return .{
                .name = about.name,
                .summary = about.summary,
                .usage = about.usage,
                .group = about.group,
                .details = about.details,
                .needs_context = about.needs_context,
                .flags = comptime deriveFlags(Spec),
                .args = comptime deriveArgs(Spec),
                .run = &Trampoline.run,
            };
        }

        fn findCommand(candidates: []const Command, name: []const u8) ?Command {
            for (candidates) |cmd| {
                if (std.mem.eql(u8, cmd.name, name)) return cmd;
            }
            return null;
        }

        /// Nearest registered command name to `name`: an exact prefix match
        /// either way, else the closest by edit distance. Null only for an
        /// empty table.
        fn suggestCommand(candidates: []const Command, name: []const u8) ?[]const u8 {
            for (candidates) |cmd| {
                if (std.mem.startsWith(u8, cmd.name, name) or std.mem.startsWith(u8, name, cmd.name)) return cmd.name;
            }

            var best: ?[]const u8 = null;
            var best_dist: usize = std.math.maxInt(usize);
            for (candidates) |cmd| {
                const d = editDistance(name, cmd.name);
                if (d < best_dist) {
                    best = cmd.name;
                    best_dist = d;
                }
            }
            return best;
        }

        /// The outcome of walking `leaf` down through matching subcommands:
        /// the deepest command reached, the index of the first token not
        /// consumed by the walk, and whether the walk stopped because a
        /// present, non-flag-shaped token failed to name one of the current
        /// command's subcommands - as opposed to stopping because there was
        /// no next token, the next token was flag-shaped, or the current
        /// command has no subcommands at all.
        const Descent = struct {
            leaf: Command,
            index: usize,
            stopped_on_mismatch: bool,
        };

        /// Walks `leaf` forward through `argv` starting at `index`: while the
        /// current command has subcommands and `argv[index]` exists, is not
        /// flag-shaped (`spec.looksLikeFlag`), and names one of them, it
        /// descends into that subcommand and advances `index`; this repeats
        /// to arbitrary depth. The walk is bounded by `argv.len`, since
        /// `index` strictly increases each iteration. A caller that treats a
        /// mismatched token as belonging to the leaf's own argv (dispatch)
        /// ignores `stopped_on_mismatch`; a caller that treats it as an error
        /// (help) reports it against `leaf.subcommands` instead.
        fn descend(leaf_in: Command, argv: []const []const u8, index_in: usize) Descent {
            var leaf = leaf_in;
            var index = index_in;
            while (leaf.subcommands.len > 0 and index < argv.len and !spec.looksLikeFlag(argv[index])) {
                const sub = findCommand(leaf.subcommands, argv[index]) orelse
                    return .{ .leaf = leaf, .index = index, .stopped_on_mismatch = true };
                leaf = sub;
                index += 1;
            }
            return .{ .leaf = leaf, .index = index, .stopped_on_mismatch = false };
        }

        /// Writes an unknown-command diagnostic to `err_w` and returns exit
        /// code 2: `name`'s nearest match via `suggestCommand`, unless `name`
        /// is flag-shaped, in which case suggesting a command for a
        /// `--`-prefixed token would be odd, so no suggestion is offered.
        fn reportUnknownCommand(commands: []const Command, name: []const u8, err_w: *std.Io.Writer) u8 {
            if (!spec.looksLikeFlag(name)) {
                if (suggestCommand(commands, name)) |suggestion| {
                    err_w.print("unknown command \"{s}\" (did you mean \"{s}\"?)\n", .{ name, suggestion }) catch {};
                    return 2;
                }
            }
            err_w.print("unknown command \"{s}\"\n", .{name}) catch {};
            return 2;
        }

        /// Writes a command-body error to `w`: `describeError(e)`'s message
        /// when `cfg` provides that hook and it returns one, else
        /// `error: <name>`.
        fn reportError(w: *std.Io.Writer, e: anyerror) void {
            if (describe_error) |f| {
                if (f(e)) |msg| {
                    if (msg.len > 0) {
                        w.print("{s}\n", .{msg}) catch {};
                        return;
                    }
                }
            }
            w.print("error: {s}\n", .{@errorName(e)}) catch {};
        }

        /// Writes a `loadContext` failure to `w`: `diag.message` when
        /// non-empty, else `describeError(e)`'s message when present, else
        /// `failed to load context: <name>`.
        fn reportLoadContextError(w: *std.Io.Writer, e: anyerror, diag: args.Diagnostic) void {
            if (diag.message.len > 0) {
                w.print("{s}\n", .{diag.message}) catch {};
                return;
            }
            if (describe_error) |f| {
                if (f(e)) |msg| {
                    if (msg.len > 0) {
                        w.print("{s}\n", .{msg}) catch {};
                        return;
                    }
                }
            }
            w.print("failed to load context: {s}\n", .{@errorName(e)}) catch {};
        }

        /// Resolves `argv[1]` against `commands` by name, then walks deeper
        /// via `descend`: for as long as the current command declares
        /// `subcommands` and the next token is present, is not flag-shaped,
        /// and names one of them, dispatch continues into that subcommand -
        /// to arbitrary depth, not just one level. The deepest command the
        /// walk reaches is the leaf, and the first token past it is where its
        /// own argv begins. A flag (`parent --help`), an unmatched token
        /// (`parent bogus`), or no further token at all (`parent`) all stop
        /// the walk and leave the last-reached command to handle its own
        /// argv rather than erroring. Building the `Ctx`, the `needs_context`
        /// gate, and the call into `run` all happen once, against the
        /// resolved leaf - so a subcommand's own `needs_context` governs
        /// context loading regardless of its parent's. An empty or unmatched
        /// top-level command name writes a one-line message to `err` and
        /// returns exit code 2 without calling any command. A
        /// `loadContext` failure writes `diag.message` to `err` when
        /// non-empty, else `describeError(e)`'s message when `cfg` provides
        /// that hook and it returns one, else `failed to load context:
        /// <name>`; either way it returns exit code 1 without calling the
        /// command. `run` is also the uniform error boundary for a command
        /// body: any error the leaf's `run` returns (other than the parse
        /// `UsageError` the trampoline handles as code 2) is reported the
        /// same way - `describeError(e)`'s message when present, else
        /// `error: <name>` - to `err`, and turned into exit code 1, so a
        /// command's error never escapes `run`.
        ///
        /// `argv[1] == "__complete"` is intercepted before help or command
        /// lookup: it is the hidden endpoint a generated shell script calls
        /// with the words being completed (`argv[2..]`), which may itself
        /// contain `--` or `--foo` tokens that must reach the completion
        /// engine rather than being read as this `run`'s own flags. It is
        /// never a registered `Command`, so it cannot appear in help or be
        /// dispatched as one. A resolver-needed context is loaded
        /// best-effort - a `loadContext` failure yields a null context
        /// rather than failing completion, since a broken shell integration
        /// must never crash the shell.
        ///
        /// `argv[1] == "__schema"` is intercepted the same way, right after
        /// `__complete`: it writes the whole `commands` table to `out` as a
        /// versioned JSON envelope (`{"version","program","commands"}`) and
        /// returns 0. `program` is `argv[0]`'s basename, the same derivation
        /// `completion` uses. Never a registered `Command`, so it too is
        /// absent from help and cannot be dispatched as one.
        ///
        /// `argv[1] == "completion"` is intercepted the same way, right
        /// after `__complete`: `argv[2]` names the shell to emit a script
        /// for. Unlike `__complete` this is a documented, user-facing entry
        /// point (the command a user runs once to install completions), but
        /// it is intercepted rather than registered as a `Command` for the
        /// same reason - it is framework-level, not app-specific, so no
        /// caller-supplied `Spec` or context should be involved. A missing
        /// or unrecognized shell name writes a one-line message to `err` and
        /// returns exit code 2 without writing a script. The program name
        /// embedded in the script is `argv[0]`'s basename, not the raw
        /// invocation path.
        ///
        /// Help is rendered instead of dispatching in three cases: no
        /// command is given, or `--help`/`-h` is the first argument (top-
        /// level help); `help <cmd> <sub> <subsub> ...` (per-command help by
        /// name, resolving subcommands the same `descend` walk dispatch
        /// uses, to arbitrary depth - but unlike dispatch's lenient
        /// fallback, a present, non-flag-shaped token that names no
        /// subcommand at its level is an unknown-subcommand error rather
        /// than falling back to the last-matched command's own help, since
        /// `help` has no "own argv" for a mismatched token to fall back
        /// into); or `<cmd> ... --help`/`-h` anywhere in the resolved leaf's
        /// own argv (per-command
        /// help for that leaf, checked before context loading so a broken
        /// `loadContext` never blocks `--help`). Every one of these renders
        /// via `writeTopHelp`/`writeCommandHelp`, which call `cfg`'s
        /// `renderTopHelp`/`renderCommandHelp` override when present instead
        /// of the built-in `HelpRenderer`.
        ///
        /// `help`, `completion`, `__complete`, and `__schema` are RESERVED
        /// command names: each is intercepted above before `commands` is
        /// ever searched. An app that registers a `Command` with one of
        /// these names has it permanently shadowed - it is never reachable
        /// via dispatch and never appears in help.
        ///
        /// A top-level `--version`/`-v` dispatches the registered `version`
        /// command with an empty argv, using the same `needs_context` gate
        /// and error boundary as a normal command. If no `version` command
        /// is registered, `--version`/`-v` falls through to normal lookup
        /// and is reported as an unknown command.
        pub fn run(
            alloc: std.mem.Allocator,
            io: std.Io,
            argv: []const []const u8,
            commands: []const Command,
            out: *std.Io.Writer,
            err: *std.Io.Writer,
        ) anyerror!u8 {
            const prog_name = if (argv.len > 0) argv[0] else "app";

            if (argv.len >= 2 and std.mem.eql(u8, argv[1], "__complete")) {
                var arena_state = std.heap.ArenaAllocator.init(alloc);
                defer arena_state.deinit();
                const arena = arena_state.allocator();

                var ctx = Ctx{ .alloc = arena, .io = io, .out = out, .err = err };
                if (completion_resolve != null) {
                    var diag = args.Diagnostic{};
                    ctx.context = cfg.loadContext(arena, io, &diag) catch null;
                }
                completionReply(arena, commands, argv[2..], completion_resolve, &ctx, out) catch {};
                return 0;
            }

            if (argv.len >= 2 and std.mem.eql(u8, argv[1], "__schema")) {
                Schema.emit(out, std.fs.path.basename(prog_name), commands) catch {};
                return 0;
            }

            if (argv.len >= 2 and std.mem.eql(u8, argv[1], "completion")) {
                if (argv.len < 3) {
                    err.print("usage: {s} completion <shell>\n", .{prog_name}) catch {};
                    return 2;
                }
                const sh = shells.parse(argv[2]) orelse {
                    err.print("unknown shell: {s}\n", .{argv[2]}) catch {};
                    return 2;
                };
                shells.emit(out, sh, std.fs.path.basename(prog_name)) catch {};
                return 0;
            }

            if (argv.len < 2 or argv[1].len == 0 or isHelpFlag(argv[1])) {
                writeTopHelp(out, prog_name, commands);
                return 0;
            }

            if (argv.len >= 2 and (std.mem.eql(u8, argv[1], "--version") or std.mem.eql(u8, argv[1], "-v"))) {
                if (findCommand(commands, "version")) |version_cmd| {
                    var ctx = Ctx{ .alloc = alloc, .io = io, .out = out, .err = err };
                    if (version_cmd.needs_context) {
                        var diag = args.Diagnostic{};
                        ctx.context = cfg.loadContext(ctx.alloc, ctx.io, &diag) catch |e| {
                            reportLoadContextError(err, e, diag);
                            return 1;
                        };
                    }
                    return version_cmd.run(&ctx) catch |e| {
                        reportError(err, e);
                        return 1;
                    };
                }
            }

            if (std.mem.eql(u8, argv[1], "help")) {
                if (argv.len < 3) {
                    writeTopHelp(out, prog_name, commands);
                    return 0;
                }
                const target = findCommand(commands, argv[2]) orelse return reportUnknownCommand(commands, argv[2], err);

                // Mirrors the leaf resolution below via the same `descend`
                // walk, so `help` and dispatch always agree on what a chain
                // of names means. Unlike dispatch's lenient fallback, a
                // present, non-flag-shaped token that names no subcommand at
                // its level is reported as unknown rather than silently
                // rendering the last-matched command's help - help has no
                // "own argv" for a mismatched token to fall back into.
                const help_descent = descend(target, argv, 3);
                if (help_descent.stopped_on_mismatch) {
                    return reportUnknownCommand(help_descent.leaf.subcommands, argv[help_descent.index], err);
                }

                var arena_state = std.heap.ArenaAllocator.init(alloc);
                defer arena_state.deinit();
                writeCommandHelp(arena_state.allocator(), out, prog_name, help_descent.leaf);
                return 0;
            }

            const name = argv[1];
            const top = findCommand(commands, name) orelse return reportUnknownCommand(commands, name, err);

            const dispatch_descent = descend(top, argv, 2);
            const leaf = dispatch_descent.leaf;
            const leaf_argv = argv[dispatch_descent.index..];

            if (hasHelpFlag(leaf_argv)) {
                var arena_state = std.heap.ArenaAllocator.init(alloc);
                defer arena_state.deinit();
                writeCommandHelp(arena_state.allocator(), out, prog_name, leaf);
                return 0;
            }

            var ctx = Ctx{
                .alloc = alloc,
                .io = io,
                .out = out,
                .err = err,
                .argv = leaf_argv,
            };
            if (leaf.needs_context) {
                var diag = args.Diagnostic{};
                ctx.context = cfg.loadContext(ctx.alloc, ctx.io, &diag) catch |e| {
                    reportLoadContextError(err, e, diag);
                    return 1;
                };
            }
            return leaf.run(&ctx) catch |e| {
                reportError(err, e);
                return 1;
            };
        }
    };
}

fn testNoopLoadContext(_: std.mem.Allocator, _: std.Io, _: *args.Diagnostic) anyerror!void {}

test "Cli.run routes argv to a registered command" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });
    const cmd = TestCli.Command{
        .name = "hello",
        .group = .general,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll("hi\n");
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "hello" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("hi\n", out_w.buffered());
}

test "Cli.run reports an unknown command with exit code 2" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });
    const cmd = TestCli.Command{
        .name = "hello",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "bogus" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("unknown command \"bogus\" (did you mean \"hello\"?)\n", err_w.buffered());
}

test "Cli.run suggests the nearest registered command name on a typo" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });
    const cmd = TestCli.Command{
        .name = "status",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);

    for ([_][]const u8{ "stauts", "statis" }) |typo| {
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", typo }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 2), code);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "unknown command \"{s}\" (did you mean \"status\"?)\n", .{typo});
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, err_w.buffered());
    }
}

test "Cli.run reports the plain unknown-command form when no command is registered" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "anything" }, &.{}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("unknown command \"anything\"\n", err_w.buffered());
}

test "editDistance: identical strings are zero, one substitution/insertion/deletion is one" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("status", "status"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("status", "statue"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("stats", "status"));
    try std.testing.expectEqual(@as(usize, 3), editDistance("kitten", "sitting"));
}

test "editDistance: degrades to the length difference past the 31-byte row cap" {
    const long_a = "a" ** 32;
    const long_b = "a" ** 40;
    try std.testing.expectEqual(@as(usize, 8), editDistance(long_a, long_b));
}

test "Cli.run renders top-level help grouped by command when no command is given" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general, extra },
        .loadContext = testNoopLoadContext,
    });
    const cmd = TestCli.Command{
        .name = "hello",
        .summary = "says hi",
        .group = .extra,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{"app"}, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "extra:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "says hi") != null);
}

test "Cli.run shows top-level help when --help or -h is the first argument" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });
    const cmd = TestCli.Command{
        .name = "hello",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    for ([_][]const u8{ "--help", "-h" }) |flag_arg| {
        var out_buf: [256]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", flag_arg }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "hello") != null);
    }
}

test "Cli.run dispatches --version and -v to the registered version command" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });
    const version_cmd = TestCli.Command{
        .name = "version",
        .group = .general,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll("myapp 1.2.3\n");
                return 0;
            }
        }.r,
    };

    for ([_][]const u8{ "--version", "-v" }) |flag_arg| {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", flag_arg }, &.{version_cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("myapp 1.2.3\n", out_w.buffered());
    }
}

test "Cli.run treats --version as an unknown command when no version command is registered, with no suggestion since it is flag-shaped" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });
    const cmd = TestCli.Command{
        .name = "hello",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "--version" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("unknown command \"--version\"\n", err_w.buffered());
}

const GreetSpec = struct {
    verbose: spec.Flag(.{ .short = 'v' }),
    port: spec.Opt(u16, .{ .short = 'p' }),
    name: spec.Pos([]const u8, .{}),
};

test "command() trampoline parses argv into typed values and calls run_fn" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        var seen_verbose: bool = false;
        var seen_port: ?u16 = null;
        var seen_name: []const u8 = "";

        fn r(_: *TestCli.Ctx, a: args.Args(GreetSpec)) anyerror!u8 {
            seen_verbose = a.verbose;
            seen_port = a.port;
            seen_name = a.name;
            return 0;
        }
    };

    const cmd = TestCli.command(GreetSpec, .{
        .name = "greet",
        .group = .general,
        .usage = "app greet [-v] [-p port] <name>",
    }, S.r);

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "greet", "-v", "-p", "9090", "world" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(S.seen_verbose);
    try std.testing.expectEqual(@as(?u16, 9090), S.seen_port);
    try std.testing.expectEqualStrings("world", S.seen_name);
}

test "command() trampoline reports a bad parse to ctx.err and returns code 2" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    };

    const cmd = TestCli.command(GreetSpec, .{
        .name = "greet",
        .group = .general,
        .usage = "app greet [-v] [-p port] <name>",
    }, S.r);

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    // No "name" positional given -> parseInto reports a required-argument
    // UsageError, which the trampoline turns into a code-2 diagnostic.
    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "greet" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expect(err_w.buffered().len != 0);
    try std.testing.expect(std.mem.indexOf(u8, err_w.buffered(), "name") != null);
}

const FilesSpec = struct {
    files: spec.Rest(.{}),
};

test "command() trampoline frees parse-owned memory via a per-dispatch arena" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        fn r(_: *TestCli.Ctx, a: args.Args(FilesSpec)) anyerror!u8 {
            return @intCast(a.files.len);
        }
    };

    const cmd = TestCli.command(FilesSpec, .{
        .name = "files",
        .group = .general,
        .usage = "app files -- <files...>",
    }, S.r);

    var out_buf: [8]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [8]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    // The Rest field's slice is alloc-owned by parseInto; std.testing.allocator
    // (as ctx.alloc, backing the trampoline's arena) fails the test on any leak.
    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "files", "--", "a", "b", "c" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 3), code);
}

test "command() derives Flag/Arg metadata matching the Spec" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    };

    const cmd = TestCli.command(GreetSpec, .{
        .name = "greet",
        .group = .general,
        .usage = "app greet [-v] [-p port] <name>",
    }, S.r);

    try std.testing.expectEqual(@as(usize, 2), cmd.flags.len);

    const verbose_flag = cmd.flags[0];
    try std.testing.expectEqualStrings("verbose", verbose_flag.long);
    try std.testing.expectEqual(@as(?u8, 'v'), verbose_flag.short);
    try std.testing.expectEqual(false, verbose_flag.takes_value);

    const port_flag = cmd.flags[1];
    try std.testing.expectEqualStrings("port", port_flag.long);
    try std.testing.expectEqual(@as(?u8, 'p'), port_flag.short);
    try std.testing.expectEqual(true, port_flag.takes_value);

    try std.testing.expectEqual(@as(usize, 1), cmd.args.len);
    const name_arg = cmd.args[0];
    try std.testing.expectEqualStrings("name", name_arg.name);
    try std.testing.expectEqual(false, name_arg.optional);
    try std.testing.expectEqual(false, name_arg.variadic);
}

const KebabSpec = struct {
    old_org: spec.Opt([]const u8, .{}),
};

test "command() derives a kebab-case long flag from a multi-word field name" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        fn r(_: *TestCli.Ctx, _: args.Args(KebabSpec)) anyerror!u8 {
            return 0;
        }
    };

    const cmd = TestCli.command(KebabSpec, .{
        .name = "rename",
        .group = .general,
    }, S.r);

    try std.testing.expectEqual(@as(usize, 1), cmd.flags.len);
    try std.testing.expectEqualStrings("old-org", cmd.flags[0].long);
}

const ExclusiveSpec = struct {
    a: spec.Opt([]const u8, .{}),
    b: spec.Opt([]const u8, .{}),
};

test "command() trampoline enforces About.exclusive and never calls run_fn on conflict" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        var called: bool = false;

        fn r(_: *TestCli.Ctx, _: args.Args(ExclusiveSpec)) anyerror!u8 {
            called = true;
            return 0;
        }
    };

    const cmd = TestCli.command(ExclusiveSpec, .{
        .name = "ex",
        .group = .general,
        .exclusive = &.{&.{ "a", "b" }},
    }, S.r);

    {
        S.called = false;
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [128]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "ex", "--a", "x", "--b", "y" }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 2), code);
        try std.testing.expect(!S.called);
        try std.testing.expect(std.mem.indexOf(u8, err_w.buffered(), "--a and --b are mutually exclusive") != null);
    }

    {
        S.called = false;
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "ex", "--a", "x" }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(S.called);
    }
}

const ContextSentinel = struct { id: u32 };

test "run loads the context only for commands that declare needs_context" {
    const S = struct {
        var load_count: u32 = 0;

        fn loadContext(_: std.mem.Allocator, _: std.Io, _: *args.Diagnostic) anyerror!ContextSentinel {
            load_count += 1;
            return .{ .id = 42 };
        }
    };
    S.load_count = 0;

    const TestCli = Cli(.{
        .Context = ContextSentinel,
        .Group = enum { general },
        .loadContext = S.loadContext,
    });

    const with_ctx = TestCli.Command{
        .name = "with",
        .group = .general,
        .needs_context = true,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                if (ctx.context) |c| {
                    try ctx.out.print("id={d}\n", .{c.id});
                } else {
                    try ctx.out.writeAll("no-context\n");
                }
                return 0;
            }
        }.r,
    };

    const without_ctx = TestCli.Command{
        .name = "without",
        .group = .general,
        .needs_context = false,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll(if (ctx.context == null) "null\n" else "not-null\n");
                return 0;
            }
        }.r,
    };

    const commands = &.{ with_ctx, without_ctx };

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "with" }, commands, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqual(@as(u32, 1), S.load_count);
        try std.testing.expectEqualStrings("id=42\n", out_w.buffered());
    }

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "without" }, commands, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqual(@as(u32, 1), S.load_count);
        try std.testing.expectEqualStrings("null\n", out_w.buffered());
    }
}

test "run reports a loadContext error to ctx.err and returns exit code 1" {
    const S = struct {
        fn loadContext(_: std.mem.Allocator, _: std.Io, _: *args.Diagnostic) anyerror!ContextSentinel {
            return error.Boom;
        }
    };

    const TestCli = Cli(.{
        .Context = ContextSentinel,
        .Group = enum { general },
        .loadContext = S.loadContext,
    });

    const cmd = TestCli.Command{
        .name = "with",
        .group = .general,
        .needs_context = true,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [128]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "with" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(err_w.buffered().len != 0);
}

test "run's describeError hook prints its message instead of error: <name> for a command-body error" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
        .describeError = struct {
            fn f(e: anyerror) ?[]const u8 {
                return if (e == error.Boom) "the boom failed" else null;
            }
        }.f,
    });

    const cmd = TestCli.Command{
        .name = "boom",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return error.Boom;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "boom" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("the boom failed\n", err_w.buffered());
}

test "run falls back to error: <name> when describeError returns an empty string" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
        .describeError = struct {
            fn f(_: anyerror) ?[]const u8 {
                return "";
            }
        }.f,
    });

    const cmd = TestCli.Command{
        .name = "boom",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return error.Boom;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "boom" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("error: Boom\n", err_w.buffered());
}

test "run falls back to failed to load context: <name> when describeError returns an empty string" {
    const S = struct {
        fn loadContext(_: std.mem.Allocator, _: std.Io, _: *args.Diagnostic) anyerror!ContextSentinel {
            return error.Boom;
        }
    };

    const TestCli = Cli(.{
        .Context = ContextSentinel,
        .Group = enum { general },
        .loadContext = S.loadContext,
        .describeError = struct {
            fn f(_: anyerror) ?[]const u8 {
                return "";
            }
        }.f,
    });

    const cmd = TestCli.Command{
        .name = "with",
        .group = .general,
        .needs_context = true,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "with" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("failed to load context: Boom\n", err_w.buffered());
}

test "run falls back to error: <name> when describeError is absent" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.Command{
        .name = "boom",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return error.Boom;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "boom" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("error: Boom\n", err_w.buffered());
}

test "run prints diag.message from a failing loadContext instead of the errorName" {
    const S = struct {
        fn loadContext(_: std.mem.Allocator, _: std.Io, diag: *args.Diagnostic) anyerror!ContextSentinel {
            diag.message = "config.toml:3 bad";
            return error.Boom;
        }
    };

    const TestCli = Cli(.{
        .Context = ContextSentinel,
        .Group = enum { general },
        .loadContext = S.loadContext,
    });

    const cmd = TestCli.Command{
        .name = "with",
        .group = .general,
        .needs_context = true,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "with" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("config.toml:3 bad\n", err_w.buffered());
}

test "run's --version dispatch consults describeError the same way as a normal command" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
        .describeError = struct {
            fn f(e: anyerror) ?[]const u8 {
                return if (e == error.Boom) "the boom failed" else null;
            }
        }.f,
    });

    const version_cmd = TestCli.Command{
        .name = "version",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return error.Boom;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "--version" }, &.{version_cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("the boom failed\n", err_w.buffered());
}

test "command() trampoline reports a bad typed-option value and never calls run_fn" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        var called: bool = false;

        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            called = true;
            return 0;
        }
    };

    const cmd = TestCli.command(GreetSpec, .{
        .name = "greet",
        .group = .general,
        .usage = "app greet [-v] [-p port] <name>",
    }, S.r);

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    // "-p xyz" fails resolve.parseValue(u16, "xyz") -> UsageError before
    // run_fn is ever reached.
    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "greet", "-p", "xyz", "world" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expect(err_w.buffered().len != 0);
    try std.testing.expect(std.mem.indexOf(u8, err_w.buffered(), "invalid value") != null);
    try std.testing.expect(!S.called);
}

test "run dispatches one level of nested subcommands by name, and a bare top-level command still works" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const sub1 = TestCli.Command{
        .name = "sub1",
        .group = .general,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll("sub1\n");
                return 0;
            }
        }.r,
    };
    const sub2 = TestCli.Command{
        .name = "sub2",
        .group = .general,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll("sub2\n");
                return 0;
            }
        }.r,
    };
    const group = TestCli.Command{
        .name = "group",
        .group = .general,
        .subcommands = &.{ sub1, sub2 },
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };
    const plain = TestCli.Command{
        .name = "plain",
        .group = .general,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll("plain\n");
                return 0;
            }
        }.r,
    };

    const commands = &.{ group, plain };

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "group", "sub1" }, commands, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("sub1\n", out_w.buffered());
    }

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "group", "sub2" }, commands, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("sub2\n", out_w.buffered());
    }

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "plain" }, commands, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("plain\n", out_w.buffered());
    }
}

test "run lets a parent with subcommands handle a flag-shaped or unmatched next token itself" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const sub = TestCli.Command{
        .name = "sub",
        .group = .general,
        .usage = "app parent sub [flags]",
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll("sub\n");
                return 0;
            }
        }.r,
    };
    const parent = TestCli.Command{
        .name = "parent",
        .group = .general,
        .usage = "app parent [flags]",
        .subcommands = &.{sub},
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                for (ctx.argv) |a| {
                    try ctx.out.writeAll(a);
                    try ctx.out.writeAll("\n");
                }
                return 0;
            }
        }.r,
    };

    // "parent --help" renders the parent's own help rather than erroring.
    {
        var out_buf: [128]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "parent", "--help" }, &.{parent}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(std.mem.startsWith(u8, out_w.buffered(), "Usage: app parent [flags]\n"));
    }

    // "parent sub" still dispatches the registered subcommand.
    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "parent", "sub" }, &.{parent}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("sub\n", out_w.buffered());
    }

    // "parent sub --help" renders the subcommand's own help.
    {
        var out_buf: [128]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "parent", "sub", "--help" }, &.{parent}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(std.mem.startsWith(u8, out_w.buffered(), "Usage: app parent sub [flags]\n"));
    }

    // "parent bogus" names no registered subcommand, so the parent handles
    // it as its own argv instead of erroring.
    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "parent", "bogus" }, &.{parent}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("bogus\n", out_w.buffered());
    }
}

test "run gates context loading on the resolved leaf command, not its parent" {
    const S = struct {
        var load_count: u32 = 0;

        fn loadContext(_: std.mem.Allocator, _: std.Io, _: *args.Diagnostic) anyerror!ContextSentinel {
            load_count += 1;
            return .{ .id = 7 };
        }
    };
    S.load_count = 0;

    const TestCli = Cli(.{
        .Context = ContextSentinel,
        .Group = enum { general },
        .loadContext = S.loadContext,
    });

    const needs_ctx_sub = TestCli.Command{
        .name = "sub",
        .group = .general,
        .needs_context = true,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                if (ctx.context) |c| {
                    try ctx.out.print("id={d}\n", .{c.id});
                } else {
                    try ctx.out.writeAll("no-context\n");
                }
                return 0;
            }
        }.r,
    };
    const plain_sub = TestCli.Command{
        .name = "plain",
        .group = .general,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll(if (ctx.context == null) "null\n" else "not-null\n");
                return 0;
            }
        }.r,
    };
    // The parent itself declares needs_context = false: if the gate ran on
    // the parent instead of the resolved leaf, "sub" would wrongly see a
    // null context and "plain" would wrongly trigger a load.
    const group = TestCli.Command{
        .name = "group",
        .group = .general,
        .needs_context = false,
        .subcommands = &.{ needs_ctx_sub, plain_sub },
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "group", "sub" }, &.{group}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqual(@as(u32, 1), S.load_count);
        try std.testing.expectEqualStrings("id=7\n", out_w.buffered());
    }

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "group", "plain" }, &.{group}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqual(@as(u32, 1), S.load_count);
        try std.testing.expectEqualStrings("null\n", out_w.buffered());
    }
}

test "run resolves a typed command() subcommand's own argv from argv[3..]" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        var seen_port: ?u16 = null;

        fn r(_: *TestCli.Ctx, a: args.Args(GreetSpec)) anyerror!u8 {
            seen_port = a.port;
            return 0;
        }
    };

    const sub = TestCli.command(GreetSpec, .{
        .name = "sub",
        .group = .general,
        .usage = "app group sub [-v] [-p port] <name>",
    }, S.r);

    const group = TestCli.Command{
        .name = "group",
        .group = .general,
        .subcommands = &.{sub},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "group", "sub", "-p", "5", "world" }, &.{group}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(?u16, 5), S.seen_port);
}

const ServeSpec = struct {
    port: spec.Opt(u16, .{ .short = 'p', .help = "listen port", .value_name = "PORT" }),
    name: spec.Pos([]const u8, .{}),
};

test "<cmd> --help shows the command's usage, a flag's help text, and its value_name" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        fn r(_: *TestCli.Ctx, _: args.Args(ServeSpec)) anyerror!u8 {
            return 0;
        }
    };

    const cmd = TestCli.command(ServeSpec, .{
        .name = "serve",
        .group = .general,
        .usage = "app serve [-p PORT] <name>",
    }, S.r);

    var out_buf: [512]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "serve", "--help" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "app serve [-p PORT] <name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "listen port") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PORT") != null);
}

test "help <cmd> renders the same per-command help as <cmd> --help" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        fn r(_: *TestCli.Ctx, _: args.Args(ServeSpec)) anyerror!u8 {
            return 0;
        }
    };

    const cmd = TestCli.command(ServeSpec, .{
        .name = "serve",
        .group = .general,
        .usage = "app serve [-p PORT] <name>",
    }, S.r);

    var out_buf_a: [512]u8 = undefined;
    var out_w_a = std.Io.Writer.fixed(&out_buf_a);
    var err_buf_a: [64]u8 = undefined;
    var err_w_a = std.Io.Writer.fixed(&err_buf_a);
    _ = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "serve", "--help" }, &.{cmd}, &out_w_a, &err_w_a);

    var out_buf_b: [512]u8 = undefined;
    var out_w_b = std.Io.Writer.fixed(&out_buf_b);
    var err_buf_b: [64]u8 = undefined;
    var err_w_b = std.Io.Writer.fixed(&err_buf_b);
    _ = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "serve" }, &.{cmd}, &out_w_b, &err_w_b);

    try std.testing.expectEqualStrings(out_w_a.buffered(), out_w_b.buffered());
}

test "help <cmd> reports an unknown command name the same way as the top-level path" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });
    const cmd = TestCli.Command{
        .name = "status",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "stauts" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("unknown command \"stauts\" (did you mean \"status\"?)\n", err_w.buffered());
}

test "suggestCommand's exact-prefix branch wins over a closer edit-distance candidate" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });
    // "stat" is an exact prefix of "status" (distance 2), but "stag" is
    // closer by edit distance (distance 1, one substitution). The prefix
    // branch is checked first, so "status" must win despite being farther.
    const status_cmd = TestCli.Command{
        .name = "status",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };
    const stag_cmd = TestCli.Command{
        .name = "stag",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "stat" }, &.{ stag_cmd, status_cmd }, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("unknown command \"stat\" (did you mean \"status\"?)\n", err_w.buffered());
}

test "run loads context for a version command that declares needs_context" {
    const S = struct {
        var load_count: u32 = 0;

        fn loadContext(_: std.mem.Allocator, _: std.Io, _: *args.Diagnostic) anyerror!ContextSentinel {
            load_count += 1;
            return .{ .id = 99 };
        }
    };
    S.load_count = 0;

    const TestCli = Cli(.{
        .Context = ContextSentinel,
        .Group = enum { general },
        .loadContext = S.loadContext,
    });

    const version_cmd = TestCli.Command{
        .name = "version",
        .group = .general,
        .needs_context = true,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                if (ctx.context) |c| {
                    try ctx.out.print("id={d}\n", .{c.id});
                } else {
                    try ctx.out.writeAll("no-context\n");
                }
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "--version" }, &.{version_cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(u32, 1), S.load_count);
    try std.testing.expectEqualStrings("id=99\n", out_w.buffered());
}

test "run falls back to error: <name> when describeError is present but returns null for the thrown error" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
        .describeError = struct {
            fn f(e: anyerror) ?[]const u8 {
                return if (e == error.OtherError) "unrelated" else null;
            }
        }.f,
    });

    const cmd = TestCli.Command{
        .name = "boom",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return error.Boom;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "boom" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("error: Boom\n", err_w.buffered());
}

test "run's loadContext failure with an empty diag.message falls back to describeError's message" {
    const S = struct {
        fn loadContext(_: std.mem.Allocator, _: std.Io, _: *args.Diagnostic) anyerror!ContextSentinel {
            return error.Boom;
        }
    };

    const TestCli = Cli(.{
        .Context = ContextSentinel,
        .Group = enum { general },
        .loadContext = S.loadContext,
        .describeError = struct {
            fn f(e: anyerror) ?[]const u8 {
                return if (e == error.Boom) "context load failed: boom" else null;
            }
        }.f,
    });

    const cmd = TestCli.Command{
        .name = "with",
        .group = .general,
        .needs_context = true,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "with" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("context load failed: boom\n", err_w.buffered());
}

test "hasHelpFlag stops at -- so --help after it passes through, but --help before it shows help" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        var called: bool = false;
        var seen_len: usize = 0;
        var seen0: []const u8 = "";
        var seen1: []const u8 = "";

        fn r(_: *TestCli.Ctx, a: args.Args(FilesSpec)) anyerror!u8 {
            called = true;
            seen_len = a.files.len;
            if (a.files.len > 0) seen0 = a.files[0];
            if (a.files.len > 1) seen1 = a.files[1];
            return 0;
        }
    };

    const cmd = TestCli.command(FilesSpec, .{
        .name = "files",
        .group = .general,
        .usage = "app files -- <files...>",
    }, S.r);

    // `--help` after a bare `--` is passthrough: run_fn is called and sees it.
    {
        S.called = false;
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "files", "--", "--help", "x" }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(S.called);
        try std.testing.expectEqual(@as(usize, 2), S.seen_len);
        try std.testing.expectEqualStrings("--help", S.seen0);
        try std.testing.expectEqualStrings("x", S.seen1);
    }

    // `--help` before any `--` still shows the command's help without calling run_fn.
    {
        S.called = false;
        var out_buf: [256]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "files", "--help" }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(!S.called);
        try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "files") != null);
    }
}

test "run renders a run_fn's own error to ctx.err and returns exit code 1" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.Command{
        .name = "boom",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return error.Boom;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "boom" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(err_w.buffered().len != 0);
    try std.testing.expect(std.mem.indexOf(u8, err_w.buffered(), "Boom") != null);
}

const RegionSpec = struct {
    region: spec.Opt([]const u8, .{ .env = "region" }),
};

fn regionEnv(k: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, k, "region")) "envval" else null;
}

test "run flows a cfg.makeSource env value through the trampoline; no makeSource keeps the empty source" {
    // With makeSource: env "region" resolves to "envval" even though argv omits it.
    {
        const TestCli = Cli(.{
            .Context = void,
            .Group = enum { general },
            .loadContext = testNoopLoadContext,
            .makeSource = struct {
                fn make(_: anytype) args.Source {
                    return .{ .env_get = regionEnv, .config_get = null };
                }
            }.make,
        });

        const S = struct {
            var seen: []const u8 = "";
            fn r(_: *TestCli.Ctx, a: args.Args(RegionSpec)) anyerror!u8 {
                seen = a.region orelse "";
                return 0;
            }
        };
        S.seen = "";

        const cmd = TestCli.command(RegionSpec, .{ .name = "cfg", .group = .general }, S.r);

        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "cfg" }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("envval", S.seen);
    }

    // Without makeSource: the empty source resolves the option to null.
    {
        const TestCli = Cli(.{
            .Context = void,
            .Group = enum { general },
            .loadContext = testNoopLoadContext,
        });

        const S = struct {
            var was_null: bool = false;
            fn r(_: *TestCli.Ctx, a: args.Args(RegionSpec)) anyerror!u8 {
                was_null = a.region == null;
                return 0;
            }
        };
        S.was_null = false;

        const cmd = TestCli.command(RegionSpec, .{ .name = "cfg", .group = .general }, S.r);

        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "cfg" }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(S.was_null);
    }
}

test "command help synthesizes a usage line from the Spec when About.usage is empty" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    };

    const cmd = TestCli.command(GreetSpec, .{
        .name = "greet",
        .group = .general,
    }, S.r);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "greet", "--help" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[--flags]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<name>") != null);
}

const EnvSpec = struct {
    env: spec.Opt([]const u8, .{ .complete = .{ .dynamic = "env" } }),
};

/// A test resolver that, like a real app's hook now must, filters against
/// `cur` itself - cli-zig no longer post-filters a `.dynamic` reply.
fn cliTestResolveCompletion(alloc: std.mem.Allocator, key: []const u8, _: ?[]const u8, cur: []const u8, _: anytype) anyerror!complete.Result {
    if (!std.mem.eql(u8, key, "env")) return .{ .directive = .default, .candidates = &.{} };
    var out: std.ArrayList(complete.Candidate) = .empty;
    for ([_][]const u8{ "staging", "prod" }) |v| {
        if (std.mem.startsWith(u8, v, cur)) try out.append(alloc, .{ .value = v });
    }
    return .{ .directive = .default, .candidates = try out.toOwnedSlice(alloc) };
}

test "Cli builds completion_resolve from cfg.resolveCompletion and feeds completionCompute" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
        .resolveCompletion = cliTestResolveCompletion,
    });

    const cmd = TestCli.command(EnvSpec, .{ .name = "deploy", .group = .general }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(EnvSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var ctx = TestCli.Ctx{ .alloc = arena, .io = std.testing.io, .out = undefined, .err = undefined };
    const got = try TestCli.completionCompute(arena, &.{cmd}, &.{ "deploy", "--env", "st" }, TestCli.completion_resolve, &ctx);
    try std.testing.expectEqual(@as(usize, 1), got.candidates.len);
    try std.testing.expectEqualStrings("staging", got.candidates[0].value);
}

test "Cli.completion_resolve is null when cfg has no resolveCompletion" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    try std.testing.expectEqual(@as(TestCli.CompletionResolve, null), TestCli.completion_resolve);
}

const CliTestGroup = enum { general, system };

fn cliTestGroupHeading(g: CliTestGroup) []const u8 {
    return switch (g) {
        .general => "general",
        .system => "System tools",
    };
}

fn cliTestHelpFooter(w: *std.Io.Writer, prog_name: []const u8) anyerror!void {
    _ = prog_name;
    try w.writeAll("see docs\n");
}

test "run forwards cfg.groupHeading and cfg.renderHelpFooter to renderTop on the no-command help path" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = CliTestGroup,
        .loadContext = testNoopLoadContext,
        .groupHeading = cliTestGroupHeading,
        .renderHelpFooter = cliTestHelpFooter,
    });

    const cmd = TestCli.command(GreetSpec, .{ .name = "greet", .group = .system }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{"app"}, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "System tools:") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "see docs\n"));
}

test "run forwards cfg.groupHeading and cfg.renderHelpFooter to renderTop on the bare help path" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = CliTestGroup,
        .loadContext = testNoopLoadContext,
        .groupHeading = cliTestGroupHeading,
        .renderHelpFooter = cliTestHelpFooter,
    });

    const cmd = TestCli.command(GreetSpec, .{ .name = "greet", .group = .system }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "System tools:") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "see docs\n"));
}

test "run's top-level help keeps the built-in heading and footer when cfg has neither hook" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = CliTestGroup,
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.command(GreetSpec, .{ .name = "greet", .group = .system }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{"app"}, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\nsystem:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<command> --help") != null);
}

test "run intercepts __complete and replies with matching command names" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.command(GreetSpec, .{
        .name = "greet",
        .group = .general,
        .usage = "app greet [-v] [-p port] <name>",
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "__complete", "gr" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();

    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next(); // directive line
    var found = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "greet")) found = true;
    }
    try std.testing.expect(found);
}

test "run intercepts __complete and replies with a command's flag names after --" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.command(GreetSpec, .{
        .name = "greet",
        .group = .general,
        .usage = "app greet [-v] [-p port] <name>",
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "__complete", "greet", "--" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--port") != null);
}

test "run's __complete interception survives a failing loadContext and still replies with candidates" {
    const S = struct {
        fn loadContext(_: std.mem.Allocator, _: std.Io, _: *args.Diagnostic) anyerror!void {
            return error.Boom;
        }
    };

    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = S.loadContext,
        .resolveCompletion = cliTestResolveCompletion,
    });

    const cmd = TestCli.command(EnvSpec, .{ .name = "deploy", .group = .general }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(EnvSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "__complete", "deploy", "--env", "st" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", err_w.buffered());
    try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "staging") != null);
}

test "run's __complete interception never reaches unknown-command handling, even with argv.len == 2" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.Command{
        .name = "greet",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "__complete" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", err_w.buffered());
    try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "greet") != null);
}

test "run intercepts completion <shell> and writes the shell's script to out" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    var out_buf: [2048]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "completion", "bash" }, &.{}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", err_w.buffered());
    try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "app __complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "complete -F _app_complete app") != null);
}

test "run's completion interception rejects an unknown shell with a code-2 diagnostic" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "completion", "csh" }, &.{}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("", out_w.buffered());
    try std.testing.expect(err_w.buffered().len != 0);
}

test "run's completion interception rejects a missing shell argument with a code-2 diagnostic" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "completion" }, &.{}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("", out_w.buffered());
    try std.testing.expect(err_w.buffered().len != 0);
}

test "run intercepts __schema and writes the command table as a versioned JSON envelope" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.command(GreetSpec, .{
        .name = "greet",
        .group = .general,
        .usage = "app greet [-v] [-p port] <name>",
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(GreetSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var out_buf: [1024]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "__schema" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", err_w.buffered());
    const out = out_w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "{"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"program\":\"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"commands\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"greet\"") != null);
}

const DeploySpec = struct {
    env: spec.Opt([]const u8, .{ .complete = .{ .choices = &.{ "dev", "staging", "prod" } } }),
};

test "__schema emits a command()-derived flag's .choices completer" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.command(DeploySpec, .{
        .name = "deploy",
        .group = .general,
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(DeploySpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var out_buf: [1024]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "__schema" }, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"complete\":{\"kind\":\"choices\",\"values\":[\"dev\",\"staging\",\"prod\"]}") != null);
}

test "__schema is never shown in top-level help" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const cmd = TestCli.Command{
        .name = "greet",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{"app"}, &.{cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "__schema") == null);
}

test "help parent renders its own help and lists its subcommands with their summaries" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const sub = TestCli.command(ServeSpec, .{
        .name = "sub",
        .summary = "run the sub",
        .group = .general,
        .usage = "app grp sub [-p PORT] <name>",
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(ServeSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    const grp = TestCli.Command{
        .name = "grp",
        .group = .general,
        .subcommands = &.{sub},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [128]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    // grp's usage is synthesized (About.usage empty); having subcommands
    // makes the synopsis end in <command> and adds a Commands section that
    // lists each subcommand by name and summary.
    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "grp" }, &.{grp}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("Usage: grp <command>\n\nCommands:\n  sub  run the sub\n", out_w.buffered());
}

test "help parent sub renders the subcommand's own help" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const sub = TestCli.command(ServeSpec, .{
        .name = "sub",
        .group = .general,
        .usage = "app grp sub [-p PORT] <name>",
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(ServeSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    const grp = TestCli.Command{
        .name = "grp",
        .group = .general,
        .subcommands = &.{sub},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [512]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "grp", "sub" }, &.{grp}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "Usage: app grp sub [-p PORT] <name>\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "listen port") != null);
}

test "help parent bogus reports an unknown subcommand with exit code 2" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const sub = TestCli.Command{
        .name = "sub",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };
    const grp = TestCli.Command{
        .name = "grp",
        .group = .general,
        .subcommands = &.{sub},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "grp", "bogus" }, &.{grp}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expectEqualStrings("", out_w.buffered());
    try std.testing.expectEqualStrings("unknown command \"bogus\" (did you mean \"sub\"?)\n", err_w.buffered());
}

fn testRenderTopHelp(w: *std.Io.Writer, prog_name: []const u8, commands: anytype) anyerror!void {
    _ = prog_name;
    _ = commands;
    try w.writeAll("CUSTOM TOP HELP\n");
}

test "run calls cfg.renderTopHelp instead of the built-in top-level renderer, on both the no-command and --help paths" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
        .renderTopHelp = testRenderTopHelp,
    });

    const cmd = TestCli.Command{
        .name = "hello",
        .summary = "says hi",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    for ([_][]const []const u8{ &.{"app"}, &.{ "app", "--help" } }) |argv| {
        var out_buf: [128]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, argv, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("CUSTOM TOP HELP\n", out_w.buffered());
        try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "Usage:") == null);
        try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "general:") == null);
    }
}

fn testRenderCommandHelp(w: *std.Io.Writer, prog_name: []const u8, command: anytype) anyerror!void {
    _ = prog_name;
    try w.print("CUSTOM COMMAND HELP for {s}\n", .{command.name});
}

test "run calls cfg.renderCommandHelp instead of the built-in per-command renderer, on both <cmd> --help and help <cmd>" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
        .renderCommandHelp = testRenderCommandHelp,
    });

    const cmd = TestCli.command(ServeSpec, .{
        .name = "serve",
        .group = .general,
        .usage = "app serve [-p PORT] <name>",
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(ServeSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    {
        var out_buf: [128]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "serve", "--help" }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("CUSTOM COMMAND HELP for serve\n", out_w.buffered());
        try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "Usage:") == null);
        try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "PORT") == null);
    }

    {
        var out_buf: [128]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "serve" }, &.{cmd}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("CUSTOM COMMAND HELP for serve\n", out_w.buffered());
        try std.testing.expect(std.mem.indexOf(u8, out_w.buffered(), "Usage:") == null);
    }
}

test "run dispatches a 3-level subcommand tree to arbitrary depth, preserving the flag-shape bypass at every level" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const c = TestCli.Command{
        .name = "c",
        .group = .general,
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll("c");
                for (ctx.argv) |a| try ctx.out.print(" {s}", .{a});
                try ctx.out.writeAll("\n");
                return 0;
            }
        }.r,
    };
    const b = TestCli.Command{
        .name = "b",
        .group = .general,
        .subcommands = &.{c},
        .run = struct {
            fn r(ctx: *TestCli.Ctx) anyerror!u8 {
                try ctx.out.writeAll("b");
                for (ctx.argv) |a| try ctx.out.print(" {s}", .{a});
                try ctx.out.writeAll("\n");
                return 0;
            }
        }.r,
    };
    const a = TestCli.Command{
        .name = "a",
        .group = .general,
        .subcommands = &.{b},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    // {app,a,b,c}: the walk descends through both a and b, reaching c.
    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b", "c" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("c\n", out_w.buffered());
    }

    // {app,a,b}: no further token, so the walk stops at b.
    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("b\n", out_w.buffered());
    }

    // {app,a,b,c,--flag}: c is the leaf and sees --flag in its own argv.
    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b", "c", "--flag" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("c --flag\n", out_w.buffered());
    }

    // {app,a,b,--flag}: the flag-shape bypass stops the walk at b, which
    // sees --flag in its own argv instead of the walk trying to match it
    // against b's subcommands.
    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b", "--flag" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("b --flag\n", out_w.buffered());
    }

    // {app,a,b,bogus}: "bogus" names no subcommand of b, so the walk stops
    // at b and lets it handle "bogus" as its own argv rather than erroring.
    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b", "bogus" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("b bogus\n", out_w.buffered());
    }
}

const NestedBSpec = struct {
    bflag: spec.Flag(.{ .help = "b's own flag" }),
};

const NestedCSpec = struct {
    cflag: spec.Flag(.{ .help = "c's own flag" }),
};

test "run resolves a command()-typed 3-level subcommand tree's own declared flag at the deepest leaf" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const S = struct {
        var seen_bflag: bool = false;
        var seen_cflag: bool = false;

        fn runB(_: *TestCli.Ctx, parsed: args.Args(NestedBSpec)) anyerror!u8 {
            seen_bflag = parsed.bflag;
            return 0;
        }
        fn runC(_: *TestCli.Ctx, parsed: args.Args(NestedCSpec)) anyerror!u8 {
            seen_cflag = parsed.cflag;
            return 0;
        }
    };
    S.seen_bflag = false;
    S.seen_cflag = false;

    const c = TestCli.command(NestedCSpec, .{
        .name = "c",
        .group = .general,
        .usage = "app a b c [--cflag]",
    }, S.runC);

    var b = TestCli.command(NestedBSpec, .{
        .name = "b",
        .group = .general,
        .usage = "app a b [--bflag]",
    }, S.runB);
    b.subcommands = &.{c};

    const a = TestCli.Command{
        .name = "a",
        .group = .general,
        .subcommands = &.{b},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b", "c", "--cflag" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(S.seen_cflag);
        try std.testing.expect(!S.seen_bflag);
    }

    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b", "--bflag" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(S.seen_bflag);
    }
}

test "help resolves a 3-level subcommand tree to the deepest matching command" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const c = TestCli.command(NestedCSpec, .{
        .name = "c",
        .group = .general,
        .usage = "app a b c [--cflag]",
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(NestedCSpec)) anyerror!u8 {
            return 0;
        }
    }.r);

    var b = TestCli.command(NestedBSpec, .{
        .name = "b",
        .group = .general,
        .usage = "app a b [--bflag]",
    }, struct {
        fn r(_: *TestCli.Ctx, _: args.Args(NestedBSpec)) anyerror!u8 {
            return 0;
        }
    }.r);
    b.subcommands = &.{c};

    const a = TestCli.Command{
        .name = "a",
        .group = .general,
        .subcommands = &.{b},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    // help a b c -> renders c's own help, including its flag's help text.
    {
        var out_buf: [512]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "a", "b", "c" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        const out = out_w.buffered();
        try std.testing.expect(std.mem.startsWith(u8, out, "Usage: app a b c [--cflag]\n"));
        try std.testing.expect(std.mem.indexOf(u8, out, "c's own flag") != null);
    }

    // help a b renders the exact same help as a b --help.
    {
        var out_buf_a: [512]u8 = undefined;
        var out_w_a = std.Io.Writer.fixed(&out_buf_a);
        var err_buf_a: [64]u8 = undefined;
        var err_w_a = std.Io.Writer.fixed(&err_buf_a);
        _ = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b", "--help" }, &.{a}, &out_w_a, &err_w_a);

        var out_buf_b: [512]u8 = undefined;
        var out_w_b = std.Io.Writer.fixed(&out_buf_b);
        var err_buf_b: [64]u8 = undefined;
        var err_w_b = std.Io.Writer.fixed(&err_buf_b);
        _ = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "a", "b" }, &.{a}, &out_w_b, &err_w_b);

        try std.testing.expectEqualStrings(out_w_a.buffered(), out_w_b.buffered());
        try std.testing.expect(std.mem.indexOf(u8, out_w_a.buffered(), "b's own flag") != null);
    }

    // a b c --help renders c's own help via the composed --help path.
    {
        var out_buf: [512]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "a", "b", "c", "--help" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(std.mem.startsWith(u8, out_w.buffered(), "Usage: app a b c [--cflag]\n"));
    }

    // help a b bogus: "bogus" names no subcommand of b, reported as unknown
    // rather than falling back to b's own help.
    {
        var out_buf: [64]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [64]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);
        const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "help", "a", "b", "bogus" }, &.{a}, &out_w, &err_w);
        try std.testing.expectEqual(@as(u8, 2), code);
        try std.testing.expectEqualStrings("", out_w.buffered());
        try std.testing.expectEqualStrings("unknown command \"bogus\" (did you mean \"c\"?)\n", err_w.buffered());
    }
}

test "run intercepts __schema and emits a 3-level subcommand tree nested to depth" {
    const TestCli = Cli(.{
        .Context = void,
        .Group = enum { general },
        .loadContext = testNoopLoadContext,
    });

    const c = TestCli.Command{
        .name = "c",
        .group = .general,
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };
    const b = TestCli.Command{
        .name = "b",
        .group = .general,
        .subcommands = &.{c},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };
    const a = TestCli.Command{
        .name = "a",
        .group = .general,
        .subcommands = &.{b},
        .run = struct {
            fn r(_: *TestCli.Ctx) anyerror!u8 {
                return 0;
            }
        }.r,
    };

    var out_buf: [2048]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try TestCli.run(std.testing.allocator, std.testing.io, &.{ "app", "__schema" }, &.{a}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();

    const commands = parsed.value.object.get("commands").?.array;
    try std.testing.expectEqual(@as(usize, 1), commands.items.len);
    const a_json = commands.items[0].object;
    try std.testing.expectEqualStrings("a", a_json.get("name").?.string);

    const b_subs = a_json.get("subcommands").?.array;
    try std.testing.expectEqual(@as(usize, 1), b_subs.items.len);
    const b_json = b_subs.items[0].object;
    try std.testing.expectEqualStrings("b", b_json.get("name").?.string);

    const c_subs = b_json.get("subcommands").?.array;
    try std.testing.expectEqual(@as(usize, 1), c_subs.items.len);
    try std.testing.expectEqualStrings("c", c_subs.items[0].object.get("name").?.string);
}
