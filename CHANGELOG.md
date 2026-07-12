# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Fixed

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

[Unreleased]: https://github.com/sakakibara/cli-zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sakakibara/cli-zig/releases/tag/v0.1.0
