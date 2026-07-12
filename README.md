# cli-zig

A comptime-typed CLI framework for Zig: declare a command's flags and
positionals as a plain struct, and parsing, help, shell completion, and a
JSON schema all derive from that one declaration.

- **Typed comptime specs** - `Flag`/`Opt`/`Pos`/`Rest` field constructors on a
  plain struct declare a command's shape; `command(Spec, About, run)` derives
  the parser, `--help` output, completion candidates, and schema JSON from
  it, so none of the four can drift from what argv actually accepts.
- **argv > env > config > default resolution** - a flag can name a fallback
  environment variable and a config-lookup key, tried in that order when
  argv omits it, before a literal default.
- **Subcommands** - arbitrary-depth nesting, with a flag-shape bypass at
  every level so a parent command's own flags (`app remote -v`) still reach
  it when no subcommand name matches.
- **Spec-driven shell completion** - `<prog> completion <shell>` emits an
  installable bash, zsh, fish, or PowerShell script backed by the same
  command table; a `.dynamic` field resolves candidates through an
  app-supplied hook that sees the word under the cursor.
- **Machine-readable schema** - `<prog> __schema` emits the whole command
  table as versioned JSON, for doc generation or agent tool surfaces that
  would otherwise have to re-parse `--help` text.
- **Did-you-mean suggestions** - an unknown command name suggests the
  nearest registered one, by prefix match or bounded edit distance.
- **Mutually exclusive flag groups** - `About.exclusive` names groups of
  fields where at most one may be provided; a conflict is caught and
  reported before your command body ever runs.
- **Dependency-free** - pure Zig, no libc, no external packages.

```zig
const std = @import("std");
const cli = @import("cli");

const Group = enum { general };

fn loadContext(_: std.mem.Allocator, _: std.Io, _: *cli.args.Diagnostic) anyerror!void {}

const App = cli.cli.Cli(.{ .Context = void, .Group = Group, .loadContext = loadContext });

const GreetSpec = struct {
    name: cli.spec.Pos([]const u8, .{ .help = "who to greet" }),
};

fn greetRun(ctx: *App.Ctx, a: cli.args.Args(GreetSpec)) anyerror!u8 {
    try ctx.out.print("hello, {s}\n", .{a.name});
    return 0;
}

const commands = [_]App.Command{
    App.command(GreetSpec, .{ .name = "greet", .group = .general }, greetRun),
};

// App.run(alloc, io, argv, &commands, stdout_writer, stderr_writer) -> u8 exit code
```

## Install

Requires Zig 0.16.0 or newer.

```sh
zig fetch --save git+https://github.com/sakakibara/cli-zig
```

In `build.zig`:

```zig
const cli = b.dependency("cli", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("cli", cli.module("cli"));
```

## Quickstart

### Defining a typed command

A Spec is a plain struct; each field's type comes from `cli.spec.Flag`,
`.Opt(T, ...)`, `.Pos(T, ...)`, or `.Rest(...)`. `command(Spec, About,
run_fn)` derives that command's `Flag`/`Arg` metadata at comptime and wraps
`run_fn` in a trampoline that parses argv into `args.Args(Spec)` before
calling it - a bad parse never reaches `run_fn`.

```zig
const GreetSpec = struct {
    verbose: cli.spec.Flag(.{ .short = 'v', .help = "print an extra detail line" }),
    port: cli.spec.Opt(u16, .{ .short = 'p', .help = "port to greet on", .value_name = "PORT" }),
    name: cli.spec.Pos([]const u8, .{ .help = "who to greet" }),
};

fn greetRun(ctx: *App.Ctx, a: cli.args.Args(GreetSpec)) anyerror!u8 {
    try ctx.out.print("hello, {s}\n", .{a.name});
    if (a.verbose) try ctx.out.print("  (port={d})\n", .{a.port orelse 0});
    return 0;
}

const greet_cmd = App.command(GreetSpec, .{
    .name = "greet",
    .summary = "say hello to someone",
    .usage = "app greet [-v] [-p port] <name>",
    .group = .general,
}, greetRun);
```

`Args(GreetSpec)` maps each field by kind: a `Flag` becomes `bool`
(default `false`), an `Opt(T, ...)` becomes `?T` (default `null`, or
`m.default` parsed when set), a required `Pos(T, ...)` becomes `T`, an
optional one (`.optional = true`) becomes `?T`, and `Rest(...)` becomes
`[]const []const u8` (default `&.{}`).

A `Rest` field takes the positionals left over after the fixed ones, plus
everything after a lone `--` verbatim (dash-led included) - so `cmd a b c`
and `cmd -- -a -b` both reach it. A flag-shaped token before `--` is never
swallowed into the tail: an unknown flag still errors.

A plain (untyped) command skips `command()` entirely and builds a
`Command` literal with its own `run` directly:

```zig
const status_cmd = App.Command{
    .name = "status",
    .summary = "report health",
    .group = .general,
    .run = struct {
        fn r(ctx: *App.Ctx) anyerror!u8 {
            try ctx.out.writeAll("all systems normal\n");
            return 0;
        }
    }.r,
};
```

### Dispatching with Cli(cfg)

`Cli(cfg)` is comptime-parameterized per app: `cfg.Context` is the value a
command can request via `About.needs_context`, `cfg.Group` is the enum used
to section commands in help output, and `cfg.loadContext` produces a
`Context`. `App.run` resolves `argv[1]` against the registered commands and
dispatches:

```zig
const commands = [_]App.Command{ greet_cmd, status_cmd };

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var out_buf: [4096]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try App.run(gpa.allocator(), init.io, init.argv, &commands, &out_w, &err_w);
    std.process.exit(code);
}
```

No command, or a bare `--help`/`-h`, renders top-level help grouped by
`cfg.Group`. `<cmd> --help`/`-h` and `help <cmd>` both render that command's
own help, synthesizing a usage line from its derived flags/args when
`About.usage` was left empty. A command that has subcommands lists them under
a `Commands:` section (each an aligned `<name>  <summary>` row) and its
synthesized synopsis ends in `<command>`, so a group and its children are
discoverable from the group's own `--help`. `help <cmd> <sub> ...` resolves a
chain of subcommand names the same way dispatch does, to whatever depth the
table nests, rendering the deepest match's own help; a name in the chain that
matches no registered subcommand is reported as unknown.

### Value resolution: argv > env > config > default

An `Opt`/`Pos` field's `Meta` can name a fallback `env` var and a
`config_key` (an app-supplied config lookup), tried in that order after argv
comes up empty, before a literal string `default`:

```zig
const DeploySpec = struct {
    profile: cli.spec.Opt([]const u8, .{
        .env = "APP_PROFILE",
        .default = "personal",
    }),
    port: cli.spec.Opt(u16, .{ .default = "8080" }),
};
```

Env and config lookups come from a `Source` an app builds itself - `cfg`
opts in with an optional `makeSource(ctx: *App.Ctx) args.Source` hook.
Absent it, only argv and `.default` apply.

### Subcommands

A `Command`'s `subcommands` field nests further commands to arbitrary depth
- a subcommand can itself carry its own `subcommands`, and so on. For as long
as the current command has subcommands and the next token matches one of
them, dispatch keeps descending; a flag-shaped or unmatched token stops the
walk and falls through to the last-matched command's own `run`:

```zig
const add_cmd = App.command(AddSpec, .{ .name = "add", .group = .general }, addRun);
const list_cmd = App.Command{ .name = "list", .group = .general, .run = listRun };

var remote_cmd = App.command(RemoteSpec, .{
    .name = "remote",
    .usage = "remote [-v] <add|list>",
    .group = .general,
}, remoteRun);
remote_cmd.subcommands = &.{ add_cmd, list_cmd };
```

`remote add origin` dispatches `add_cmd`; `remote -v` (no matching
subcommand name) dispatches `remote_cmd` itself with `-v` in its own argv.
Nesting one more level (say `add_cmd.subcommands = &.{origin_cmd}`) makes
`remote add origin` descend through `remote` and `add` to reach
`origin_cmd`, with no change to how either level is declared.

### Shell completion

`<prog> completion <shell>` (`bash`, `zsh`, `fish`, or `powershell`) writes
an installable script that calls back into the hidden `<prog> __complete`
endpoint. A `.dynamic` completer resolves through a `resolveCompletion` hook
on `cfg`, which sees the key, the previous token, and the word under the
cursor:

```zig
fn resolveCompletion(alloc: std.mem.Allocator, key: []const u8, _: ?[]const u8, cur: []const u8, _: anytype) anyerror!cli.complete.Result {
    if (!std.mem.eql(u8, key, "env")) return .{ .directive = .default, .candidates = &.{} };
    var out: std.ArrayList(cli.complete.Candidate) = .empty;
    for (environments) |e| {
        if (std.mem.startsWith(u8, e, cur)) try out.append(alloc, .{ .value = e });
    }
    return .{ .directive = .default, .candidates = try out.toOwnedSlice(alloc) };
}

const App = cli.cli.Cli(.{
    .Context = void,
    .Group = Group,
    .loadContext = loadContext,
    .resolveCompletion = resolveCompletion,
});

const DeploySpec = struct {
    env: cli.spec.Opt([]const u8, .{ .help = "target environment", .complete = .{ .dynamic = "env" } }),
};
```

A fixed candidate list needs no hook at all: `.complete = .{ .choices =
&.{ "dev", "staging", "prod" } }`. `.complete = .files` defers to the
shell's own filename completion.

### The __schema JSON

`<prog> __schema` writes the whole command table - name, summary, usage,
flags, positionals, and subcommands, recursively - as a versioned JSON
envelope, for a caller that wants the command surface without parsing
`--help` text:

```json
{"version":1,"program":"app","commands":[
  {"name":"deploy","summary":"deploy to an environment","usage":"app deploy --env <env>",
   "group":"general","details":"","needs_context":false,
   "flags":[{"long":"env","short":null,"help":"target environment","takes_value":true,
             "value_name":"value","complete":{"kind":"choices","values":["dev","staging","prod"]}}],
   "args":[],"subcommands":[]}
]}
```

`help`, `completion`, `__complete`, and `__schema` are reserved command
names: each is intercepted before the registered command table is ever
searched, so they never appear in help and can never be shadowed by an app
command of the same name.

## API surface

### Functions

| Function | Purpose |
| --- | --- |
| `cli.Cli(cfg)` | Comptime-parameterized dispatcher: builds `Ctx`, `Command`, `About`, `command()`, and `run` for one app. |
| `Cli(cfg).command(Spec, about, run_fn)` | Derives a `Command` from a typed Spec, wrapping `run_fn` in an argv-parsing trampoline. |
| `Cli(cfg).run(alloc, io, argv, commands, out, err)` | Resolves `argv[1..]` against `commands` and dispatches, handling help/completion/schema/version interception. |
| `args.Args(Spec)` | The typed result struct a Spec reifies to. |
| `args.parseInto(Spec, alloc, argv, source, diag)` | Parses `argv` into `Args(Spec)`, resolving each field by argv > env > config > default. |
| `spec.Flag(meta)` / `.Opt(T, meta)` / `.Pos(T, meta)` / `.Rest(meta)` | Spec field-type constructors. |
| `spec.kebab(name)` | Comptime underscore-to-hyphen conversion for a field's long flag spelling. |
| `shells.parse(name)` / `shells.emit(w, shell, prog_name)` | Look up a `Shell` by name; write its completion script. |
| `schema.Emitter(Command, Flag, Arg, Group).emit(w, prog_name, table)` | Writes the versioned JSON schema envelope. |

### Types

`spec.Kind`, `spec.Info`, `spec.Meta` (re-exported as `meta.Meta`),
`meta.Complete`, `args.Source`, `args.Diagnostic`, `parse.Error`,
`complete.Directive`, `complete.Candidate`, `complete.Result`,
`shells.Shell`, `Cli(cfg).Ctx`, `Cli(cfg).Command`, `Cli(cfg).About`,
`Cli(cfg).Flag`, `Cli(cfg).Arg`.

Generated reference docs are published at
**https://sakakibara.github.io/cli-zig/**.

Building locally (Zig's docs viewer is WASM-based and must be served over
HTTP, not opened as a `file://` URL):

```sh
zig build docs
cd zig-out/docs && python3 -m http.server 8000
# then visit http://localhost:8000/
```

## Build commands

```sh
zig build test            # unit tests
zig build fuzz             # bounded random-argv fuzzer
zig build examples         # build all examples
zig build example-basic    # run a specific example (basic, subcommands, completion, schema)
zig build docs             # generate reference docs
```

## Memory model

`Cli(cfg).command`'s trampoline opens a fresh arena for each dispatch and
frees it wholesale on return - a command's `run_fn` never tracks or frees a
parsed value itself. Parsed `[]const u8` values (flag values, positionals)
are slices into the caller's own `argv`, so they stay valid only as long as
`argv` does. The one exception is a `Rest` field's variadic tail: `parseInto`
hands back a slice re-owned by the arena (not a Parser-internal buffer), so
it outlives the parse call and is freed along with everything else the
dispatch arena holds.

A `loadContext` failure's diagnostic message is the app's own allocation to
own; on a terminal load failure the process exit that follows reclaims it
for free, so `run` never frees it itself.

## Examples

See `examples/` for runnable samples:

- `basic.zig` - a typed command (flags, an option, a positional) plus two
  plain commands, dispatched against top-level help and sample argv.
- `subcommands.zig` - a parent command with two subcommands, and the
  flag-shape bypass that lets the parent handle its own flags.
- `completion.zig` - emitting a `completion bash` script and driving
  `__complete` for a `.dynamic` option resolved by `resolveCompletion`.
- `schema.zig` - emitting the `__schema` JSON envelope for a small command
  table.
