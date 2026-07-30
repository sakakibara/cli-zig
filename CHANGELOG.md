# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-07-31

### Added

- `About.conflicts` and `About.requires`: the flag relations `exclusive`
  cannot express. `conflicts` rules one set out against another while each
  side stays free to combine internally (`--own` pairs with `--own-absent`,
  and both rule out `--recursive`); `requires` names the companions a field is
  meaningless without, by `any_of` or `all_of`. Both are comptime-checked
  against the Spec like `exclusive`, and additionally reject a rule that could
  never hold -- a field on both sides of a conflict, or a requirement naming
  itself as its own companion.
- Both carry a `why`: the reason, in the command's own vocabulary. One
  declaration feeds the usage error, `--help`, and the schema, so an app
  states a constraint once instead of hand-rolling the check and then
  restating it in prose.
- `--help` gains a `Constraints:` section listing every relation -- including
  `exclusive` groups, which until now appeared nowhere in help output.
- `Command.constraints` exposes those relations to any renderer, and the
  schema emits them per command as `constraints`.

### Changed

- **Breaking:** `About.exclusive` takes `[]const Exclusive` instead of
  `[]const []const []const u8`, so a group can carry a `why` like the other
  two relations. `.exclusive = &.{&.{ "a", "b" }}` becomes
  `.exclusive = &.{.{ .any_of = &.{ "a", "b" } }}`. A group of fewer than two
  fields is now a build error -- it could never conflict.
- **Breaking (internal):** `help.Renderer` and `schema.Emitter` take a
  `Constraint` type parameter alongside `Command`/`Flag`/`Arg`/`Group`. An app
  built on `App(cfg)` is unaffected; only a caller instantiating those
  renderers directly passes the extra argument.
- The schema envelope's `version` is now `2`: every command object carries a
  `constraints` array, empty when the command declares none. A version-1
  reader that ignores unknown keys needs no change.

## [0.2.0] - 2026-07-26

### Changed

- **Breaking:** the root module exports a curated surface instead of the
  internal file layout. `cli.cli.Cli(cfg)` is now `cli.App(cfg)`; the Spec
  constructors and args-layer entry points are flat re-exports
  (`cli.Flag`/`cli.Opt`/`cli.Pos`/`cli.Rest`, `cli.looksLikeFlag`,
  `cli.Args`, `cli.parseInto`, `cli.Source`, `cli.Diagnostic`); the `meta`
  and `complete` namespaces remain as they were. The `spec`, `args`,
  `parse`, `resolve`, `cli`, `help`, `shells`, and `schema` namespaces are
  no longer exported, with no aliases kept: `cli.spec.Flag` becomes
  `cli.Flag`, `cli.args.Args` becomes `cli.Args`, and the parse/resolve/
  help/shells/schema internals are reachable only through `App` and the
  derived `completion`/`__schema` commands.

## [0.1.2] - 2026-07-12

### Fixed

- A `Rest` field now captures the plain positionals left over after the fixed
  ones, not only the tokens after a lone `--`. `cmd <file>...` previously
  rejected its own arguments with "unexpected argument" whenever the Spec
  declared its tail as `Rest` and the caller passed the files directly, which
  is the shape most variadic commands take. Post-`--` tokens are still taken
  verbatim, dash-led ones included, and a flag-shaped token before `--` is
  still never swallowed into the tail, so an unknown flag keeps erroring
  instead of silently landing in the variadic.

## [0.1.1] - 2026-07-12

### Added

- Arbitrary-depth subcommand nesting: dispatch, `help <cmd> <sub> ...`, and
  shell completion all resolve a chain of subcommand names to whatever depth
  the command table nests, sharing one descent so every entry point agrees on
  what a chain of names means. A token that names no subcommand at its level
  stops the walk: dispatch and completion fall back to the last-matched
  command's own flags/args, while `help` reports it as an unknown subcommand.
- Per-command help lists a command's subcommands under a `Commands:` section
  (each an aligned `<name>  <summary>` row), and a subcommand-bearing
  command's synthesized synopsis ends in `<command>`, so a group's children
  are discoverable from its own `--help`.
- `renderTopHelp`/`renderCommandHelp` hooks on `cfg`: when present, `run`
  calls them instead of the built-in help renderer for top-level and
  per-command help respectively, letting an app replace the whole help
  layout rather than only the group heading and footer.
- `cfg.messagePrefix`: an optional `[]const u8` prepended to every
  framework-generated stderr message - the unknown-command diagnostic, a
  command-body error, a `loadContext` failure, a parse `UsageError`'s
  message and usage line, and an `About.exclusive` conflict message. Absent
  it, no prefix is added.

### Changed

- **Breaking:** `cfg.describeError`'s signature is now `fn (alloc:
  std.mem.Allocator, err: anyerror) ?[]const u8`, so it can format dynamic
  content (e.g. `allocPrint(alloc, "internal error: {s}", .{@errorName(err)})`)
  instead of only returning a static string. The allocator is a short-lived
  arena scoped to the one `run` error-reporting call and freed right after
  the message is printed, so a formatted message never needs the hook to
  free it itself.

- `resolve.parseValue` now accepts float `Value` types (`std.fmt.parseFloat`),
  alongside the existing integer, enum, and string support.

### Fixed

- A bad option or positional value now reports a type-aware message naming
  what was expected instead of a generic `invalid value for --x: y`: an
  integer field says `--jobs requires an integer, got "x"`, a float field
  says `requires a number`, an enum field lists its variants (`requires one
  of: fast, slow`), and a bool field says `requires true or false`.
- A Spec pairing a fixed positional with a variadic (`Rest`) field no longer
  lets the positional dip into tokens after a lone `--`: when a `Rest` field
  is present, a fixed positional resolves only from tokens before `--`, and
  every post-`--` token belongs to the variadic exclusively. Previously
  `cmd <optional-pos> -- <passthrough...>` misparsed - `cmd --flag x -- a b`
  bound the positional to `a` instead of leaving it unfilled. A Spec with no
  `Rest` field is unaffected: its positional can still claim a post-`--`
  token verbatim, which remains the only way such a Spec accepts a dash-led
  positional value.

## [0.1.0] - 2026-07-12

Initial release. A comptime-typed CLI framework: typed specs, a command
dispatcher, spec-driven shell completion, and a JSON schema.

### Added

- Typed comptime Spec: `spec.Flag`/`Opt`/`Pos`/`Rest` field constructors and
  the left-to-right argv classifier (`parse.Parser`) underlying them.
  `args.Args(Spec)` reifies a Spec to its typed result struct;
  `args.parseInto` resolves each field by argv > env > config > default and
  parses it to the field's declared type.
- `cli.Cli(cfg)`: a comptime-parameterized command dispatcher. `command(Spec,
  About, run_fn)` derives a command's flags/positionals from a Spec at
  comptime and wraps `run_fn` in an argv-parsing trampoline; `run` resolves
  argv against a registered command table, descending through subcommands to
  arbitrary depth with a flag-shape bypass for a parent's own flags at every
  level.
- Value resolution precedence argv > env > config > default, via an
  app-supplied `Source` (`makeSource` hook) consulted per field.
- Spec-driven shell completion: `<prog> completion <shell>` emits an
  installable bash, zsh, fish, or PowerShell script; the hidden `<prog>
  __complete` endpoint drives it, with fixed (`.choices`), filesystem
  (`.files`), and app-resolved (`.dynamic`, via a `resolveCompletion` hook
  that sees the cursor word) candidate sources.
- `<prog> __schema`: emits the whole command table as a versioned JSON
  envelope (flags, positionals, subcommands, recursively), for a consumer
  that generates docs or a tool surface without parsing `--help` text.
- Kebab-case flags: a multi-word Spec field name (`old_org`) derives the
  `--old-org` long spelling; the underscored spelling is rejected.
- `--version`/`-v` dispatches a registered `version` command with an empty
  argv, using the same context-loading and error boundary as any other
  command.
- Did-you-mean suggestions: an unknown command name suggests the nearest
  registered one, by prefix match or bounded Levenshtein edit distance.
- Mutually exclusive flag groups: `About.exclusive` names groups of fields
  where at most one may be provided; a conflict is reported before the
  command body runs, with field names comptime-checked against the Spec.
- Customizable help: `cfg.groupHeading` overrides a `Group` enum field's
  heading text; `cfg.renderHelpFooter` replaces the built-in footer;
  `cfg.describeError` supplies a human-readable message for a command-body
  or `loadContext` error in place of `error: <name>`.
- Bounded random-argv fuzzer (`zig build fuzz`) exercising `parseInto` and
  `Cli(cfg).run` against mutated and fully random argv, with a panic handler
  that records a reproducible seed and iteration.
- Runnable examples (`examples/`): a typed command with plain commands, a
  parent command with subcommands, shell completion with a dynamic resolver,
  and `__schema` emission.

[Unreleased]: https://github.com/sakakibara/cli-zig/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/sakakibara/cli-zig/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/sakakibara/cli-zig/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/sakakibara/cli-zig/releases/tag/v0.1.0
