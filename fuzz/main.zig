//! Bounded random-argv fuzzer for the argv parsing and dispatch surface.
//!
//! Mutates a set of valid argv seeds (byte flips/inserts/deletes on
//! individual arguments, plus arg-level truncation/duplication/deletion/
//! splice) and also throws fully random argv at the target. Every generated
//! argv is capped at `max_input_args` arguments of at most `max_arg_bytes`
//! bytes each, and the outer loop runs a fixed iteration count, so no
//! timeout machinery is needed.
//!
//! `std.testing.fuzz` is not usable here: its `test_runner` wiring is broken
//! in Zig 0.16.0, so this is a plain executable driven by its own bounded
//! loop instead of `zig test --fuzz`.
//!
//! Checked per generated argv:
//!
//! 1. `cli.args.parseInto` against a representative `Spec` (several bool
//!    short flags, a multi-word long-only bool flag, a short `u16` option, a
//!    short string option, a required positional, and a variadic tail) never
//!    panics; a malformed argv reports `UsageError` rather than crashing.
//!    The short flags and options exist so clustered tokens (`-ab`, `-abc`,
//!    a cluster's trailing value-option glued or as the next token) and
//!    repeated flags/options (idempotent bool, last-wins value) are
//!    meaningfully exercised, not just long-flag forms.
//! 2. `cli.cli.Cli(cfg).run` against a small command table (a plain command,
//!    and a parent command with one subcommand) never panics and its
//!    internal error boundary means `run` itself should never return an
//!    error - one doing so is treated as a failure.
//!
//! A custom panic handler records the (seed, iteration, argv) of whichever
//! check is in flight and prints it before handing off to the default panic
//! handler, so a genuine crash (not just a returned error) is reproducible.
//!
//! Usage: `zig build fuzz -- [--seed S] [--iters N]`. Defaults are fixed, so
//! plain `zig build fuzz` is deterministic; a reported failure prints the
//! seed and iteration needed to reproduce it.

const std = @import("std");
const cli = @import("cli");

const max_input_args: usize = 64;
const max_arg_bytes: usize = 256;
const default_iterations: usize = 10_000;
const default_seed: u64 = 0x636c692d7a6967; // "cli-zig"

/// `FuzzSpec`'s bool-flag short chars, drawn from by `shortCluster` to
/// synthesize clustered tokens (e.g. "-vab") that may not appear verbatim in
/// any seed.
const short_flag_chars: []const u8 = "vabc";
/// `FuzzSpec`'s value-option short chars, drawn from by `glueOptionValue` to
/// synthesize glued value-option tokens (e.g. "-p99").
const short_opt_chars: []const u8 = "po";

const Random = std.Random;

pub const panic = std.debug.FullPanic(fuzzPanic);

var last_label: []const u8 = "";
var last_seed: u64 = 0;
var last_iter: usize = 0;
var last_argv_buf: [max_input_args][]const u8 = undefined;
var last_argv_len: usize = 0;

/// Records the argv about to be handed to a target, so a panic mid-call can
/// still report a reproducible (seed, iteration, argv).
fn recordAttempt(label: []const u8, seed: u64, iter: usize, argv: []const []const u8) void {
    last_label = label;
    last_seed = seed;
    last_iter = iter;
    last_argv_len = @min(argv.len, max_input_args);
    for (argv[0..last_argv_len], 0..) |a, i| last_argv_buf[i] = a;
}

fn fuzzPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("\nfuzz FAILURE (panic during {s}): {s}\n  seed: 0x{x}\n  iteration: {d}\n  argv:", .{
        last_label, msg, last_seed, last_iter,
    });
    for (last_argv_buf[0..last_argv_len]) |a| {
        std.debug.print(" ", .{});
        printEscaped(a);
    }
    std.debug.print("\n", .{});
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Several short-and-long bool flags (`v`, `a`, `b`, `c`) so a clustered
/// token (`-ab`, `-abc`, `-vv`) has more than one char to decompose, one
/// multi-word (kebab) long-only bool flag, a short-and-long `u16` option and
/// a short-and-long string option (so a cluster's trailing value-option, and
/// a repeated option's last-wins resolution, are both exercised across two
/// value types), a required positional, and a variadic tail - one
/// representative of each `spec.Kind`, weighted toward short forms.
const FuzzSpec = struct {
    verbose: cli.spec.Flag(.{ .short = 'v' }),
    alpha: cli.spec.Flag(.{ .short = 'a' }),
    bravo: cli.spec.Flag(.{ .short = 'b' }),
    charlie: cli.spec.Flag(.{ .short = 'c' }),
    dry_run: cli.spec.Flag(.{}),
    port: cli.spec.Opt(u16, .{ .short = 'p' }),
    output: cli.spec.Opt([]const u8, .{ .short = 'o' }),
    name: cli.spec.Pos([]const u8, .{}),
    rest: cli.spec.Rest(.{}),
};

const ChildSpec = struct {
    flag_x: cli.spec.Flag(.{}),
};

const GrandchildSpec = struct {
    flag_y: cli.spec.Flag(.{}),
};

fn envNone(_: []const u8) ?[]const u8 {
    return null;
}
const fuzz_source = cli.args.Source{ .env_get = envNone, .config_get = null };

const Group = enum { general };

fn noopLoadContext(_: std.mem.Allocator, _: std.Io, _: *cli.args.Diagnostic) anyerror!void {}

const FuzzCli = cli.cli.Cli(.{
    .Context = void,
    .Group = Group,
    .loadContext = noopLoadContext,
});

fn greetRun(_: *FuzzCli.Ctx, _: cli.args.Args(FuzzSpec)) anyerror!u8 {
    return 0;
}

fn childRun(_: *FuzzCli.Ctx, _: cli.args.Args(ChildSpec)) anyerror!u8 {
    return 0;
}

fn grandchildRun(_: *FuzzCli.Ctx, _: cli.args.Args(GrandchildSpec)) anyerror!u8 {
    return 0;
}

/// Valid argv seeds for the direct `parseInto` target (no program/command
/// name prefix): bare positional, short and long flags, a multi-word kebab
/// flag, `--opt value`, `--opt=value`, a `--` passthrough tail, an empty
/// argv (missing the required positional), clustered short tokens (bool-only
/// and ending in a value-option, glued or two-token), repeated bool flags
/// (long, short, and clustered), and repeated options across the space/
/// glued/`=` forms and mixed spellings.
const spec_seed_argvs = [_][]const []const u8{
    &.{"widget"},
    &.{ "-v", "widget" },
    &.{ "--verbose", "widget" },
    &.{ "--dry-run", "widget" },
    &.{ "--port", "8080", "widget" },
    &.{ "--port=8080", "widget" },
    &.{ "-p", "8080", "widget" },
    &.{ "widget", "--", "extra", "args" },
    &.{ "-v", "--dry-run", "--port=9090", "widget", "--", "a", "b" },
    &.{},

    &.{ "-ab", "widget" },
    &.{ "-abc", "widget" },
    &.{ "-vab", "widget" },
    &.{ "-aoval", "widget" },
    &.{ "-ovalue", "widget" },
    &.{ "-oab", "widget" },
    &.{ "-abo", "val", "widget" },

    &.{ "--verbose", "--verbose", "widget" },
    &.{ "-v", "-v", "widget" },
    &.{ "-vv", "widget" },
    &.{ "-aa", "widget" },

    &.{ "--port", "1", "--port", "2", "widget" },
    &.{ "--port=1", "--port=2", "widget" },
    &.{ "-p", "1", "-p", "2", "widget" },
    &.{ "-p", "1", "--port=2", "widget" },
    &.{ "--output", "x", "--output=y", "widget" },
    &.{ "-oval1", "-oval2", "widget" },

    &.{ "-abc", "widget", "--", "extra", "args" },
    &.{ "-vv", "--port=1", "--port=2", "widget", "--", "a" },
};

/// Valid argv seeds for the `Cli.run` dispatch target, prefixed with a
/// program name: plain-command invocations exercising the same grammar as
/// `spec_seed_argvs` (including clustered short tokens and repeated flags/
/// options), a parent/child/grandchild subcommand path three levels deep
/// (also exercised with clusters and repeats, and with a flag-shaped or
/// unmatched token stopping the walk short of the deepest level), help/
/// version/completion entry points, and an unknown command.
const cli_seed_argvs = [_][]const []const u8{
    &.{ "app", "greet", "widget" },
    &.{ "app", "greet", "-v", "widget" },
    &.{ "app", "greet", "--verbose", "widget" },
    &.{ "app", "greet", "--dry-run", "widget" },
    &.{ "app", "greet", "--port", "8080", "widget" },
    &.{ "app", "greet", "--port=8080", "widget" },
    &.{ "app", "greet", "-p", "8080", "widget" },
    &.{ "app", "greet", "widget", "--", "extra", "args" },
    &.{ "app", "parent", "widget" },
    &.{ "app", "parent", "child" },
    &.{ "app", "parent", "child", "--flag-x" },
    &.{ "app", "parent", "child", "grandchild" },
    &.{ "app", "parent", "child", "grandchild", "--flag-y" },
    &.{ "app", "parent", "child", "--flag-x", "grandchild" },
    &.{ "app", "parent", "child", "bogus" },
    &.{ "app", "--help" },
    &.{ "app", "greet", "--help" },
    &.{ "app", "parent", "child", "--help" },
    &.{ "app", "parent", "child", "grandchild", "--help" },
    &.{ "app", "help", "greet" },
    &.{ "app", "help", "parent", "child" },
    &.{ "app", "help", "parent", "child", "grandchild" },
    &.{ "app", "help", "parent", "child", "bogus" },
    &.{"app"},
    &.{ "app", "bogus" },
    &.{ "app", "--version" },
    &.{ "app", "completion", "fish" },
    &.{ "app", "__schema" },
    &.{ "app", "__complete", "greet", "" },

    &.{ "app", "greet", "-ab", "widget" },
    &.{ "app", "greet", "-abc", "widget" },
    &.{ "app", "greet", "-vab", "widget" },
    &.{ "app", "greet", "-aoval", "widget" },
    &.{ "app", "greet", "-ovalue", "widget" },
    &.{ "app", "greet", "-oab", "widget" },
    &.{ "app", "greet", "-abo", "val", "widget" },

    &.{ "app", "greet", "--verbose", "--verbose", "widget" },
    &.{ "app", "greet", "-v", "-v", "widget" },
    &.{ "app", "greet", "-vv", "widget" },

    &.{ "app", "greet", "--port", "1", "--port", "2", "widget" },
    &.{ "app", "greet", "--port=1", "--port=2", "widget" },
    &.{ "app", "greet", "-p", "1", "--port=2", "widget" },

    &.{ "app", "parent", "-ab", "widget" },
    &.{ "app", "parent", "-vv", "--port=1", "--port=2", "widget", "--", "a" },
};

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var seed: u64 = default_seed;
    var iterations: usize = default_iterations;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--seed")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("fuzz: --seed requires a value\n", .{});
                std.process.exit(2);
            }
            seed = std.fmt.parseInt(u64, argv[i], 0) catch {
                std.debug.print("fuzz: bad seed '{s}' (want integer)\n", .{argv[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, argv[i], "--iters")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("fuzz: --iters requires a value\n", .{});
                std.process.exit(2);
            }
            iterations = std.fmt.parseInt(usize, argv[i], 0) catch {
                std.debug.print("fuzz: bad iteration count '{s}' (want integer)\n", .{argv[i]});
                std.process.exit(2);
            };
        } else {
            std.debug.print("fuzz: unknown argument '{s}'\n", .{argv[i]});
            std.process.exit(2);
        }
    }

    var prng = Random.DefaultPrng.init(seed);
    const random = prng.random();

    // Built once, at main's own stack frame, so the parent/child commands'
    // `subcommands` slices stay valid for the whole run. `parent` -> `child`
    // -> `grandchild` is three levels deep, exercising the fuzzer's dispatch
    // and help paths past the one-level case.
    const grandchild_cmd = FuzzCli.command(GrandchildSpec, .{
        .name = "grandchild",
        .group = .general,
    }, grandchildRun);
    const grandchildren = [_]FuzzCli.Command{grandchild_cmd};
    var child_cmd = FuzzCli.command(ChildSpec, .{
        .name = "child",
        .group = .general,
    }, childRun);
    child_cmd.subcommands = &grandchildren;
    const subcommands = [_]FuzzCli.Command{child_cmd};
    var parent_cmd = FuzzCli.command(FuzzSpec, .{
        .name = "parent",
        .group = .general,
    }, greetRun);
    parent_cmd.subcommands = &subcommands;
    const greet_cmd = FuzzCli.command(FuzzSpec, .{
        .name = "greet",
        .group = .general,
    }, greetRun);
    const commands = [_]FuzzCli.Command{ greet_cmd, parent_cmd };

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    var parse_ok: usize = 0;
    var parse_usage_error: usize = 0;
    var cli_exit: [4]usize = .{ 0, 0, 0, 0 }; // index 3 buckets any exit code > 2

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        defer _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();

        const spec_argv = try generateArgv(random, a, &spec_seed_argvs);
        recordAttempt("parseInto", seed, iter, spec_argv);
        switch (checkParseInto(a, spec_argv)) {
            .ok => parse_ok += 1,
            .usage_error => parse_usage_error += 1,
        }

        const cli_argv = try generateArgv(random, a, &cli_seed_argvs);
        recordAttempt("cli.run", seed, iter, cli_argv);
        const code = checkCliRun(a, init.io, &commands, cli_argv) catch |err| {
            reportFailure("cli.run", err, seed, iter, cli_argv);
        };
        cli_exit[@min(code, 3)] += 1;
    }

    std.debug.print(
        "fuzz: {d} iterations OK (seed 0x{x}); parseInto ok={d} usage_error={d}; cli.run exit 0={d} 1={d} 2={d} other={d}\n",
        .{ iterations, seed, parse_ok, parse_usage_error, cli_exit[0], cli_exit[1], cli_exit[2], cli_exit[3] },
    );
}

fn reportFailure(label: []const u8, err: anyerror, seed: u64, iter: usize, argv: []const []const u8) noreturn {
    std.debug.print("\nfuzz FAILURE ({s}): {t}\n  seed: 0x{x}\n  iteration: {d}\n  argv:", .{ label, err, seed, iter });
    for (argv) |a| {
        std.debug.print(" ", .{});
        printEscaped(a);
    }
    std.debug.print("\n", .{});
    std.process.exit(1);
}

const ParseOutcome = enum { ok, usage_error };

fn checkParseInto(a: std.mem.Allocator, argv: []const []const u8) ParseOutcome {
    var diag = cli.args.Diagnostic{};
    _ = cli.args.parseInto(FuzzSpec, a, argv, fuzz_source, &diag) catch |err| switch (err) {
        error.UsageError, error.OutOfMemory => return .usage_error,
    };
    return .ok;
}

/// `Cli.run` catches every fallible operation internally (a command body's
/// error, a `loadContext` failure, a render/emit failure); it should never
/// itself return an error, so a caller treats one as a real failure.
fn checkCliRun(a: std.mem.Allocator, io: std.Io, commands: []const FuzzCli.Command, argv: []const []const u8) !u8 {
    var out_scratch: [256]u8 = undefined;
    var out_w: std.Io.Writer.Discarding = .init(&out_scratch);
    var err_scratch: [256]u8 = undefined;
    var err_w: std.Io.Writer.Discarding = .init(&err_scratch);
    return FuzzCli.run(a, io, argv, commands, &out_w.writer, &err_w.writer);
}

/// One argv-level mutation applied on top of a seed. Byte-level edits are
/// weighted more heavily than the structural (arg-granularity) ones in
/// `mutateArgv`, mirroring how a single-byte edit is far more likely than a
/// whole-argument edit to land near an interesting grammar boundary.
/// `short_cluster` and `glue_option_value` synthesize a whole new clustered
/// or glued-value token from `FuzzSpec`'s short chars rather than editing an
/// existing one, reaching shapes (e.g. "-vv", "-aab", "-p99") a byte edit of
/// a seed argument would rarely produce directly.
const MutateOp = enum {
    byte_flip,
    byte_insert,
    byte_delete,
    arg_truncate,
    arg_duplicate,
    arg_delete,
    arg_splice,
    short_cluster,
    glue_option_value,
};

/// Builds one argv: with low probability a fully random argv (arg count and
/// per-arg bytes each capped), otherwise a seed argv from `seeds` put
/// through 1..8 random mutations. Returned slice and its contents are
/// allocated from `a` (the caller's per-iteration arena).
fn generateArgv(random: Random, a: std.mem.Allocator, seeds: []const []const []const u8) ![]const []const u8 {
    if (random.uintLessThan(u8, 8) == 0) return generateRandomArgv(random, a);

    var list: std.ArrayList(std.ArrayList(u8)) = .empty;
    const seed_argv = seeds[random.uintLessThan(usize, seeds.len)];
    for (seed_argv) |arg| {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(a, arg);
        try list.append(a, buf);
    }

    const mutations = 1 + random.uintLessThan(usize, 8);
    var m: usize = 0;
    while (m < mutations) : (m += 1) {
        try mutateArgv(random, a, &list, seeds);
    }

    const out = try a.alloc([]const u8, list.items.len);
    for (list.items, 0..) |buf, idx| out[idx] = buf.items;
    return out;
}

fn generateRandomArgv(random: Random, a: std.mem.Allocator) ![]const []const u8 {
    const count = random.uintAtMost(usize, max_input_args);
    const out = try a.alloc([]const u8, count);
    for (out) |*slot| {
        const len = random.uintAtMost(usize, max_arg_bytes);
        const buf = try a.alloc(u8, len);
        random.bytes(buf);
        slot.* = buf;
    }
    return out;
}

fn mutateArgv(
    random: Random,
    a: std.mem.Allocator,
    list: *std.ArrayList(std.ArrayList(u8)),
    seeds: []const []const []const u8,
) !void {
    if (list.items.len == 0) return argSplice(random, a, list, seeds);

    switch (random.uintLessThan(u8, 13)) {
        0, 1, 2 => byteFlip(random, list),
        3, 4 => try byteInsert(random, a, list),
        5, 6 => byteDelete(random, list),
        7 => argTruncate(random, list),
        8 => try argDuplicate(random, a, list),
        9 => argDelete(random, list),
        10 => try argSplice(random, a, list, seeds),
        11 => try shortCluster(random, a, list),
        12 => try glueOptionValue(random, a, list),
        else => unreachable,
    }
}

fn pickArg(random: Random, list: *std.ArrayList(std.ArrayList(u8))) *std.ArrayList(u8) {
    return &list.items[random.uintLessThan(usize, list.items.len)];
}

fn byteFlip(random: Random, list: *std.ArrayList(std.ArrayList(u8))) void {
    const arg = pickArg(random, list);
    if (arg.items.len == 0) return;
    const pos = random.uintLessThan(usize, arg.items.len);
    arg.items[pos] ^= @as(u8, 1) << random.int(u3);
}

fn byteInsert(random: Random, a: std.mem.Allocator, list: *std.ArrayList(std.ArrayList(u8))) !void {
    const arg = pickArg(random, list);
    if (arg.items.len >= max_arg_bytes) return;
    const pos = random.uintAtMost(usize, arg.items.len);
    try arg.insert(a, pos, random.int(u8));
}

fn byteDelete(random: Random, list: *std.ArrayList(std.ArrayList(u8))) void {
    const arg = pickArg(random, list);
    if (arg.items.len == 0) return;
    _ = arg.orderedRemove(random.uintLessThan(usize, arg.items.len));
}

fn argTruncate(random: Random, list: *std.ArrayList(std.ArrayList(u8))) void {
    const arg = pickArg(random, list);
    if (arg.items.len == 0) return;
    arg.shrinkRetainingCapacity(random.uintAtMost(usize, arg.items.len));
}

fn argDuplicate(random: Random, a: std.mem.Allocator, list: *std.ArrayList(std.ArrayList(u8))) !void {
    if (list.items.len >= max_input_args) return;
    const idx = random.uintLessThan(usize, list.items.len);
    var dup: std.ArrayList(u8) = .empty;
    try dup.appendSlice(a, list.items[idx].items);
    try list.insert(a, idx, dup);
}

fn argDelete(random: Random, list: *std.ArrayList(std.ArrayList(u8))) void {
    if (list.items.len <= 1) return;
    _ = list.orderedRemove(random.uintLessThan(usize, list.items.len));
}

/// Inserts a whole argument copied from a random seed argv at a random
/// position, so a fragment of valid grammar (e.g. `--port=8080`) can land
/// next to mutated content from a different seed.
fn argSplice(
    random: Random,
    a: std.mem.Allocator,
    list: *std.ArrayList(std.ArrayList(u8)),
    seeds: []const []const []const u8,
) !void {
    if (list.items.len >= max_input_args) return;
    const seed_argv = seeds[random.uintLessThan(usize, seeds.len)];
    if (seed_argv.len == 0) return;
    const src = seed_argv[random.uintLessThan(usize, seed_argv.len)];
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, src[0..@min(src.len, max_arg_bytes)]);
    const pos = random.uintAtMost(usize, list.items.len);
    try list.insert(a, pos, buf);
}

/// Synthesizes a clustered short token (`-` followed by 2..4 chars drawn
/// from `short_flag_chars`) and inserts it at a random position. Reaches
/// combinations (e.g. duplicate chars like "-vv", or a run like "-aab") that
/// a byte-level mutation of an existing token would rarely land on.
fn shortCluster(random: Random, a: std.mem.Allocator, list: *std.ArrayList(std.ArrayList(u8))) !void {
    if (list.items.len >= max_input_args) return;
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '-');
    const n = 2 + random.uintLessThan(usize, 3); // 2..4 chars
    var k: usize = 0;
    while (k < n) : (k += 1) {
        try buf.append(a, short_flag_chars[random.uintLessThan(usize, short_flag_chars.len)]);
    }
    const pos = random.uintAtMost(usize, list.items.len);
    try list.insert(a, pos, buf);
}

/// Synthesizes a glued short value-option token (`-` + a char from
/// `short_opt_chars` + 1..4 hex digits, e.g. "-p99" or "-oab1") and inserts
/// it at a random position, so a cluster's greedy-glued-value path is
/// exercised directly rather than only via byte edits of a seed.
fn glueOptionValue(random: Random, a: std.mem.Allocator, list: *std.ArrayList(std.ArrayList(u8))) !void {
    if (list.items.len >= max_input_args) return;
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '-');
    try buf.append(a, short_opt_chars[random.uintLessThan(usize, short_opt_chars.len)]);
    const vlen = 1 + random.uintLessThan(usize, 4); // 1..4 chars
    var k: usize = 0;
    while (k < vlen) : (k += 1) {
        try buf.append(a, "0123456789abcdef"[random.uintLessThan(usize, 16)]);
    }
    const pos = random.uintAtMost(usize, list.items.len);
    try list.insert(a, pos, buf);
}

/// Prints `input` as a double-quoted string with non-printable bytes as
/// \xNN escapes, so a failing argv can be pasted into a regression test.
fn printEscaped(input: []const u8) void {
    std.debug.print("\"", .{});
    for (input) |byte| {
        switch (byte) {
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            ' '...'!', '#'...'[', ']'...'~' => std.debug.print("{c}", .{byte}),
            else => std.debug.print("\\x{x:0>2}", .{byte}),
        }
    }
    std.debug.print("\"", .{});
}
