//! Spec-driven shell-completion candidate engine. Given the words typed so
//! far, it decides what is being completed - a command name, a subcommand
//! name, a positional slot, or a flag - and produces candidates plus one
//! directive a generated shell script acts on. The engine is generic over a
//! caller's `Command`/`Flag`/`Arg`/`Ctx` types (mirroring `help.Renderer`) and
//! reaches outside its own candidate logic only through `Resolve`, the seam a
//! caller plugs in to answer a `.dynamic` completion key.
const std = @import("std");
const meta = @import("meta.zig");
const spec = @import("spec.zig");
const testing = std.testing;

/// Tells the generated shell script how to treat the candidate list.
pub const Directive = enum {
    /// Normal completion: append a space after a unique match.
    default,
    /// Do not append a space (the candidate is a prefix the user keeps typing).
    nospace,
    /// Emit no candidates; let the shell complete filesystem paths itself.
    files,

    pub fn tag(self: Directive) []const u8 {
        return @tagName(self);
    }
};

/// One completion candidate: the value the shell inserts, and an optional
/// human-readable annotation shells that support it render alongside it.
pub const Candidate = struct { value: []const u8, description: ?[]const u8 = null };

/// The outcome of a completion query: what to tell the shell (`directive`)
/// plus the candidate list, already filtered and ranked.
pub const Result = struct {
    directive: Directive,
    candidates: []const Candidate,
};

fn empty() Result {
    return .{ .directive = .default, .candidates = &.{} };
}

/// Writes `s` to `w`, replacing any tab, newline, or carriage return with a
/// space. A candidate occupies exactly one line of the reply protocol and a
/// tab separates its value from its description, so neither field may
/// itself carry one of those bytes.
fn writeSanitized(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\t', '\n', '\r' => try w.writeByte(' '),
            else => try w.writeByte(c),
        }
    }
}

fn hasPrefixIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (prefix.len > s.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn isSubsequenceIgnoreCase(query: []const u8, target: []const u8) bool {
    var qi: usize = 0;
    for (target) |tc| {
        if (qi == query.len) break;
        if (std.ascii.toLower(tc) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

fn isSubsequence(query: []const u8, target: []const u8) bool {
    var qi: usize = 0;
    for (target) |tc| {
        if (qi == query.len) break;
        if (tc == query[qi]) qi += 1;
    }
    return qi == query.len;
}

/// Case-insensitive subsequence match (smartcase: a query with an uppercase
/// letter matches case-sensitively). Prefix and exact matches are
/// subsequences too, so this is a superset of a plain prefix test.
fn matches(query: []const u8, target: []const u8) bool {
    if (query.len == 0) return true;
    const cased = for (query) |c| {
        if (std.ascii.isUpper(c)) break true;
    } else false;
    if (cased) return isSubsequence(query, target);
    return isSubsequenceIgnoreCase(query, target);
}

/// Wraps plain values as descriptionless candidates, for sources that don't
/// (yet) carry an annotation.
fn plain(alloc: std.mem.Allocator, values: []const []const u8) ![]const Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    for (values) |v| try out.append(alloc, .{ .value = v });
    return out.toOwnedSlice(alloc);
}

/// Rank: 0 exact, 1 prefix, 2 subsequence; drop non-matches. Within a rank,
/// ties break on original index so ordering is deterministic regardless of
/// whether the sort implementation is stable. Matches (and ranks) on each
/// candidate's `.value`; its description rides along unchanged.
fn filterMatches(alloc: std.mem.Allocator, all: []const Candidate, cur: []const u8) ![]const Candidate {
    if (cur.len == 0) return all;
    const Ranked = struct { rank: u8, idx: usize, val: Candidate };
    var ranked: std.ArrayList(Ranked) = .empty;
    for (all, 0..) |c, i| {
        if (!matches(cur, c.value)) continue;
        const rank: u8 = if (std.ascii.eqlIgnoreCase(c.value, cur)) 0 else if (hasPrefixIgnoreCase(c.value, cur)) 1 else 2;
        try ranked.append(alloc, .{ .rank = rank, .idx = i, .val = c });
    }
    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn lt(_: void, a: Ranked, b: Ranked) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return a.idx < b.idx;
        }
    }.lt);
    var out: std.ArrayList(Candidate) = .empty;
    for (ranked.items) |r| try out.append(alloc, r.val);
    return out.toOwnedSlice(alloc);
}

/// A view over a caller's command table: `Completion(Command, Flag, Arg,
/// Ctx)` reads only `Command{ name, subcommands, flags, args }`,
/// `Flag{ long, short, takes_value, complete }`, and `Arg{ complete,
/// variadic }`, mirroring how `help.Renderer` reads the same generic shapes.
pub fn Completion(comptime Command: type, comptime Flag: type, comptime Arg: type, comptime Ctx: type) type {
    // Arg is part of the signature to mirror help.Renderer/schema.Emitter,
    // even though every Arg field access below goes through cmd.args[i]
    // (typed as Command's own Arg) rather than the Arg parameter directly.
    _ = Arg;
    return struct {
        /// The dynamic-key seam: turns a `.dynamic` completion key into a
        /// `Result` by querying whatever the caller's `Ctx` gives access to.
        /// Sees `cur`, the word under the cursor, and owns the full `Result`
        /// (directive and candidates) - the engine does not filter a
        /// `.dynamic` reply, since a caller may decide the directive itself
        /// from `cur`'s shape or need to filter against more than `cur`
        /// alone. Passed into `compute`/`reply` rather than stored, so a
        /// caller with no dynamic categories can simply pass `null`.
        pub const Resolve = ?*const fn (alloc: std.mem.Allocator, key: []const u8, prev: ?[]const u8, cur: []const u8, ctx: *Ctx) anyerror!Result;

        /// Prints the completion reply for `words` (every token after the
        /// program name, the last being the possibly-empty word under the
        /// cursor): a directive line, then one candidate per line as
        /// `value\tdescription` (just `value` when there is no description).
        /// Never fails the shell - an error out of `compute` (including one
        /// surfaced from `resolve_fn`) yields the default directive with no
        /// candidates rather than propagating.
        pub fn reply(alloc: std.mem.Allocator, table: []const Command, words: []const []const u8, resolve_fn: Resolve, ctx: *Ctx, w: *std.Io.Writer) !void {
            const r = compute(alloc, table, words, resolve_fn, ctx) catch empty();
            try w.print("{s}\n", .{r.directive.tag()});
            for (r.candidates) |c| {
                try writeSanitized(w, c.value);
                if (c.description) |d| {
                    try w.writeByte('\t');
                    try writeSanitized(w, d);
                }
                try w.writeByte('\n');
            }
        }

        /// The engine. `words[0]` is the (maybe partial) command name; a
        /// bare-command completion has `words.len <= 1`.
        pub fn compute(alloc: std.mem.Allocator, table: []const Command, words: []const []const u8, resolve_fn: Resolve, ctx: *Ctx) !Result {
            if (words.len <= 1) {
                const prefix = if (words.len == 1) words[0] else "";
                return .{ .directive = .default, .candidates = try commandNames(alloc, table, prefix) };
            }

            const cmd = findCommand(table, words[0]) orelse return empty();
            return resolveGroup(alloc, cmd, words[1..], resolve_fn, ctx);
        }

        /// Recurses through `cmd`'s subcommands to arbitrary depth: `rest` is
        /// the words after `cmd`'s own name, the last always being the word
        /// under the cursor. A subcommand group defers to a matching
        /// non-cursor word, recursing into that subcommand with the words
        /// after it - to whatever depth the table nests. A parent may also
        /// own its own flags/args (it can be dispatched directly, e.g.
        /// `parent --flag`), so a dash-led cursor word, or any word past the
        /// first that is flag-shaped or names no sub, completes against `cmd`
        /// itself rather than yielding nothing; only a bare (non-dash) cursor
        /// word in the sub-name position offers sub-names. The flag-shape
        /// guard on the descending word mirrors dispatch's `descend`, so
        /// completion and dispatch walk the tree identically. Bounded by
        /// `rest.len`, which strictly decreases each recursive call.
        fn resolveGroup(alloc: std.mem.Allocator, cmd: Command, rest: []const []const u8, resolve_fn: Resolve, ctx: *Ctx) !Result {
            if (cmd.subcommands.len > 0) {
                if (rest.len == 1) {
                    if (spec.looksLikeFlag(rest[0])) return computeFor(alloc, cmd, rest, resolve_fn, ctx);
                    return .{ .directive = .default, .candidates = try commandNames(alloc, cmd.subcommands, rest[0]) };
                }
                if (!spec.looksLikeFlag(rest[0])) {
                    if (findCommand(cmd.subcommands, rest[0])) |sub| return resolveGroup(alloc, sub, rest[1..], resolve_fn, ctx);
                }
                return computeFor(alloc, cmd, rest, resolve_fn, ctx);
            }

            return computeFor(alloc, cmd, rest, resolve_fn, ctx);
        }

        /// Completion within a single (sub)command: `rest` is the args after
        /// the command name, the last being the word under the cursor.
        fn computeFor(alloc: std.mem.Allocator, cmd: Command, rest: []const []const u8, resolve_fn: Resolve, ctx: *Ctx) !Result {
            const cur = rest[rest.len - 1];
            const prior = rest[0 .. rest.len - 1];

            // A self-contained `--flag=value` word completes the flag's value
            // against the part after `=`, not the flag name itself.
            if (cur.len > 1 and cur[0] == '-') {
                if (std.mem.indexOfScalar(u8, cur, '=')) |eq| {
                    const name = cur[0..eq];
                    const val = cur[eq + 1 ..];
                    if (pendingValueFlag(name, cmd.flags)) |f| {
                        return resolveSpec(alloc, f.complete, val, lastPositional(prior, cmd.flags), resolve_fn, ctx);
                    }
                }
            }

            // A dash-led word completes flag names, not a positional value.
            if (cur.len > 0 and cur[0] == '-') {
                return .{ .directive = .default, .candidates = try flagNames(alloc, cmd.flags, cur, prior) };
            }

            // The word right after a value-taking flag completes that flag's
            // value, not a positional (`--org <cur>`).
            if (prior.len > 0) {
                if (pendingValueFlag(prior[prior.len - 1], cmd.flags)) |f| {
                    return resolveSpec(alloc, f.complete, cur, lastPositional(prior[0 .. prior.len - 1], cmd.flags), resolve_fn, ctx);
                }
            }

            const slot = positionalSlot(prior, cmd.flags);
            const s = argSpec(cmd, slot) orelse return empty();
            return resolveSpec(alloc, s, cur, lastPositional(prior, cmd.flags), resolve_fn, ctx);
        }

        /// Turns one completion spec into candidates. `.choices` is filtered
        /// by the current word here, since a static list is cli-zig's to
        /// filter. `.dynamic` is not: its resolver sees `cur` and returns the
        /// final `Result` verbatim, since only the caller knows how to
        /// interpret `cur` (e.g. deciding the directive from its shape, or
        /// filtering against more than `cur` alone). A `.dynamic` key with no
        /// `resolve_fn`, or whose `resolve_fn` call errors, yields no
        /// candidates rather than failing completion.
        fn resolveSpec(alloc: std.mem.Allocator, s: meta.Complete, cur: []const u8, prev: ?[]const u8, resolve_fn: Resolve, ctx: *Ctx) !Result {
            switch (s) {
                .none => return empty(),
                .files => return .{ .directive = .files, .candidates = &.{} },
                .choices => |cs| return .{ .directive = .default, .candidates = try filterMatches(alloc, try plain(alloc, cs), cur) },
                .dynamic => |key| {
                    const fn_ptr = resolve_fn orelse return empty();
                    return fn_ptr(alloc, key, prev, cur, ctx) catch return empty();
                },
            }
        }

        /// The declared value-flag that `tok` names when it is a bare
        /// `--long`/`-s` awaiting a value (not the self-contained
        /// `--long=v`). Null otherwise.
        fn pendingValueFlag(tok: []const u8, flags: []const Flag) ?Flag {
            if (std.mem.indexOfScalar(u8, tok, '=') != null) return null;
            for (flags) |f| {
                if (!f.takes_value) continue;
                if (std.mem.startsWith(u8, tok, "--") and std.mem.eql(u8, tok[2..], f.long)) return f;
                if (f.short) |s| {
                    if (tok.len == 2 and tok[0] == '-' and tok[1] == s) return f;
                }
            }
            return null;
        }

        /// The completer for positional slot `slot`, reusing a final variadic
        /// slot for any slot past the end. Null when there is nothing to
        /// complete there.
        fn argSpec(cmd: Command, slot: usize) ?meta.Complete {
            if (cmd.args.len == 0) return null;
            if (slot < cmd.args.len) return cmd.args[slot].complete;
            const last = cmd.args[cmd.args.len - 1];
            return if (last.variadic) last.complete else null;
        }

        fn commandNames(alloc: std.mem.Allocator, table: []const Command, prefix: []const u8) ![]const Candidate {
            var out: std.ArrayList([]const u8) = .empty;
            for (table) |c| try out.append(alloc, c.name);
            return filterMatches(alloc, try plain(alloc, try out.toOwnedSlice(alloc)), prefix);
        }

        fn flagNames(alloc: std.mem.Allocator, flags: []const Flag, cur: []const u8, prior: []const []const u8) ![]const Candidate {
            var out: std.ArrayList([]const u8) = .empty;
            for (flags) |f| {
                if (flagPresent(prior, f)) continue;
                try out.append(alloc, try std.fmt.allocPrint(alloc, "--{s}", .{f.long}));
            }
            return filterMatches(alloc, try plain(alloc, try out.toOwnedSlice(alloc)), cur);
        }

        /// Whether `f` already appears in `prior` as `--long` (with or
        /// without `=value`) or as its `-s` short form - so the completer
        /// does not re-offer a flag the user already typed.
        fn flagPresent(prior: []const []const u8, f: Flag) bool {
            for (prior) |tok| {
                if (std.mem.startsWith(u8, tok, "--")) {
                    const name = if (std.mem.indexOfScalar(u8, tok, '=')) |e| tok[2..e] else tok[2..];
                    if (std.mem.eql(u8, name, f.long)) return true;
                } else if (f.short) |s| {
                    if (tok.len == 2 and tok[0] == '-' and tok[1] == s) return true;
                }
            }
            return false;
        }

        /// How many positional args appear in `prior`, so the cursor word is
        /// the next slot. A declared value-flag consumes the token after it,
        /// so that value is not miscounted as a positional.
        fn positionalSlot(prior: []const []const u8, flags: []const Flag) usize {
            var count: usize = 0;
            var i: usize = 0;
            while (i < prior.len) : (i += 1) {
                const tok = prior[i];
                if (tok.len > 0 and tok[0] == '-') {
                    if (std.mem.indexOfScalar(u8, tok, '=') != null) continue; // --k=v is self-contained
                    if (flagTakesValue(flags, tok)) i += 1; // skip the value token
                    continue;
                }
                count += 1;
            }
            return count;
        }

        /// The last positional value in `prior` - context for a slot that
        /// completes against an earlier arg. Null if none.
        fn lastPositional(prior: []const []const u8, flags: []const Flag) ?[]const u8 {
            var last: ?[]const u8 = null;
            var i: usize = 0;
            while (i < prior.len) : (i += 1) {
                const tok = prior[i];
                if (tok.len > 0 and tok[0] == '-') {
                    if (std.mem.indexOfScalar(u8, tok, '=') != null) continue;
                    if (flagTakesValue(flags, tok)) i += 1;
                    continue;
                }
                last = tok;
            }
            return last;
        }

        fn flagTakesValue(flags: []const Flag, tok: []const u8) bool {
            for (flags) |f| {
                if (std.mem.startsWith(u8, tok, "--") and std.mem.eql(u8, tok[2..], f.long)) return f.takes_value;
                if (f.short) |s| {
                    if (tok.len == 2 and tok[0] == '-' and tok[1] == s) return f.takes_value;
                }
            }
            return false;
        }

        fn findCommand(table: []const Command, name: []const u8) ?Command {
            for (table) |c| {
                if (std.mem.eql(u8, c.name, name)) return c;
            }
            return null;
        }
    };
}

const TestFlag = struct {
    long: []const u8,
    short: ?u8 = null,
    takes_value: bool = false,
    complete: meta.Complete = .none,
};

const TestArg = struct {
    name: []const u8 = "",
    complete: meta.Complete = .none,
    optional: bool = false,
    variadic: bool = false,
};

const TestCommand = struct {
    name: []const u8,
    subcommands: []const TestCommand = &.{},
    flags: []const TestFlag = &.{},
    args: []const TestArg = &.{},
};

const TestCtx = struct { seen_key: []const u8 = "" };

const TC = Completion(TestCommand, TestFlag, TestArg, TestCtx);

/// A resolver standing in for an app that decides behavior from `cur`'s
/// shape: a path-shaped word (leading `/`) yields the `.files` directive,
/// otherwise a candidate list with `cur` echoed into one value - proving
/// `cur` reached the hook and that its `Result` is what `compute` returns.
fn testResolve(alloc: std.mem.Allocator, key: []const u8, prev: ?[]const u8, cur: []const u8, ctx: *TestCtx) anyerror!Result {
    _ = prev;
    ctx.seen_key = key;
    if (!std.mem.eql(u8, key, "thing")) return empty();
    if (cur.len > 0 and cur[0] == '/') return .{ .directive = .files, .candidates = &.{} };
    var out: std.ArrayList(Candidate) = .empty;
    try out.append(alloc, .{ .value = try std.fmt.allocPrint(alloc, "foo-{s}", .{cur}), .description = "a thing" });
    try out.append(alloc, .{ .value = "bar" });
    return .{ .directive = .default, .candidates = try out.toOwnedSlice(alloc) };
}

fn failingResolve(_: std.mem.Allocator, _: []const u8, _: ?[]const u8, _: []const u8, _: *TestCtx) anyerror!Result {
    return error.Boom;
}

fn containsValue(cands: []const Candidate, value: []const u8) bool {
    for (cands) |c| {
        if (std.mem.eql(u8, c.value, value)) return true;
    }
    return false;
}

test "compute: an empty word at command position lists every command name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{ .{ .name = "alpha" }, .{ .name = "beta" } };
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{""}, null, &ctx);
    try testing.expectEqual(@as(usize, 2), got.candidates.len);
    try testing.expect(containsValue(got.candidates, "alpha"));
    try testing.expect(containsValue(got.candidates, "beta"));
}

test "compute: a command-position prefix filters to matching command names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{ .{ .name = "grape" }, .{ .name = "apple" } };
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{"gr"}, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("grape", got.candidates[0].value);
}

test "compute: a subcommand group's own sub-names complete at the second word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "org",
        .subcommands = &.{ .{ .name = "rename" }, .{ .name = "list" } },
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "org", "re" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("rename", got.candidates[0].value);
}

test "compute: a dash-led word after a command lists that command's flag names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "archive",
        .flags = &.{ .{ .long = "yes", .short = 'y' }, .{ .long = "yolo" } },
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "archive", "--" }, null, &ctx);
    try testing.expectEqual(@as(usize, 2), got.candidates.len);
    try testing.expect(containsValue(got.candidates, "--yes"));
    try testing.expect(containsValue(got.candidates, "--yolo"));
}

test "compute: a flag already present in prior words is not offered again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "archive",
        .flags = &.{ .{ .long = "yes", .short = 'y' }, .{ .long = "yolo" } },
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "archive", "--yes", "--y" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("--yolo", got.candidates[0].value);
}

test "compute: a .choices positional completes to the choice list filtered by prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "deploy",
        .args = &.{.{ .name = "env", .complete = .{ .choices = &.{ "dev", "staging", "prod" } } }},
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "deploy", "st" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("staging", got.candidates[0].value);
}

test "compute: a .choices option value completes via glued --flag=value syntax" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "deploy",
        .flags = &.{.{ .long = "env", .takes_value = true, .complete = .{ .choices = &.{ "dev", "staging", "prod" } } }},
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "deploy", "--env=st" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("staging", got.candidates[0].value);
}

test "compute: the word after a bare value-taking flag completes that flag's value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "deploy",
        .flags = &.{.{ .long = "env", .takes_value = true, .complete = .{ .choices = &.{ "dev", "staging", "prod" } } }},
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "deploy", "--env", "st" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("staging", got.candidates[0].value);
}

test "compute: a final variadic slot's completer is reused for every slot past the end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "tag",
        .args = &.{.{ .name = "names", .variadic = true, .complete = .{ .choices = &.{ "red", "green", "blue" } } }},
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "tag", "red", "green", "bl" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("blue", got.candidates[0].value);
}

test "compute: a .dynamic key passes the actual cur to the resolver and returns its Result verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "use",
        .args = &.{.{ .name = "key", .complete = .{ .dynamic = "thing" } }},
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "use", "f" }, testResolve, &ctx);
    try testing.expectEqualStrings("thing", ctx.seen_key);
    try testing.expectEqual(@as(usize, 2), got.candidates.len);
    try testing.expectEqualStrings("foo-f", got.candidates[0].value);
    try testing.expectEqualStrings("a thing", got.candidates[0].description.?);
    try testing.expectEqualStrings("bar", got.candidates[1].value);
}

test "compute: a .dynamic resolver deciding .files from cur's shape has that directive returned unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "use",
        .args = &.{.{ .name = "key", .complete = .{ .dynamic = "thing" } }},
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "use", "/etc/passwd" }, testResolve, &ctx);
    try testing.expectEqual(Directive.files, got.directive);
    try testing.expectEqual(@as(usize, 0), got.candidates.len);
}

test "compute: a .dynamic key with a null resolver returns no candidates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "use",
        .args = &.{.{ .name = "key", .complete = .{ .dynamic = "thing" } }},
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "use", "" }, null, &ctx);
    try testing.expectEqual(@as(usize, 0), got.candidates.len);
    try testing.expectEqual(Directive.default, got.directive);
}

const GroupTestTable = [_]TestCommand{.{
    .name = "grp",
    .subcommands = &.{.{ .name = "sub" }},
    .flags = &.{.{ .long = "verbose" }},
    .args = &.{.{ .name = "which", .complete = .{ .choices = &.{ "red", "green" } } }},
}};

test "compute: a subcommand-bearing parent completes its own flag names when the second word is dash-led" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &GroupTestTable, &.{ "grp", "--" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("--verbose", got.candidates[0].value);
}

test "compute: a subcommand-bearing parent still offers sub-names when the second word is not dash-led" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &GroupTestTable, &.{ "grp", "" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("sub", got.candidates[0].value);
}

test "compute: a subcommand-bearing parent still descends into a matching subcommand name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &GroupTestTable, &.{ "grp", "sub", "" }, null, &ctx);
    try testing.expectEqual(@as(usize, 0), got.candidates.len);
}

test "compute: a subcommand-bearing parent completes its own positional choices past an unrecognized second word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &GroupTestTable, &.{ "grp", "--verbose", "" }, null, &ctx);
    try testing.expectEqual(@as(usize, 2), got.candidates.len);
    try testing.expect(containsValue(got.candidates, "red"));
    try testing.expect(containsValue(got.candidates, "green"));
}

test "compute: a resolver error yields the default directive with no candidates, not a failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "use",
        .args = &.{.{ .name = "key", .complete = .{ .dynamic = "thing" } }},
    }};
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &table, &.{ "use", "" }, failingResolve, &ctx);
    try testing.expectEqual(@as(usize, 0), got.candidates.len);
    try testing.expectEqual(Directive.default, got.directive);
}

test "reply: emits the directive line, then value<TAB>description or bare value per candidate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "use",
        .args = &.{.{ .name = "key", .complete = .{ .dynamic = "thing" } }},
    }};
    var ctx = TestCtx{};

    var out: std.Io.Writer.Allocating = .init(arena);
    try TC.reply(arena, &table, &.{ "use", "" }, testResolve, &ctx, &out.writer);
    const got = out.written();
    try testing.expect(std.mem.startsWith(u8, got, "default\n"));
    try testing.expect(std.mem.indexOf(u8, got, "foo-\ta thing\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "bar\n") != null);
}

fn dirtyResolve(alloc: std.mem.Allocator, _: []const u8, _: ?[]const u8, _: []const u8, _: *TestCtx) anyerror!Result {
    var out: std.ArrayList(Candidate) = .empty;
    try out.append(alloc, .{ .value = "a\nb", .description = "x\ty" });
    return .{ .directive = .default, .candidates = try out.toOwnedSlice(alloc) };
}

test "reply: a candidate whose value or description carries a tab/newline is sanitized to one line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "use",
        .args = &.{.{ .name = "key", .complete = .{ .dynamic = "thing" } }},
    }};
    var ctx = TestCtx{};

    var out: std.Io.Writer.Allocating = .init(arena);
    try TC.reply(arena, &table, &.{ "use", "" }, dirtyResolve, &ctx, &out.writer);
    const got = out.written();

    const line_count = std.mem.count(u8, got, "\n");
    try testing.expectEqual(@as(usize, 2), line_count); // directive line + one candidate line
    try testing.expect(std.mem.indexOf(u8, got, "a b\tx y\n") != null);
}

test "reply: a resolver error still emits a directive line and no candidate lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = [_]TestCommand{.{
        .name = "use",
        .args = &.{.{ .name = "key", .complete = .{ .dynamic = "thing" } }},
    }};
    var ctx = TestCtx{};

    var out: std.Io.Writer.Allocating = .init(arena);
    try TC.reply(arena, &table, &.{ "use", "" }, failingResolve, &ctx, &out.writer);
    try testing.expectEqualStrings("default\n", out.written());
}

const NestedTestTable = [_]TestCommand{.{
    .name = "a",
    .subcommands = &.{.{
        .name = "b",
        .flags = &.{.{ .long = "bflag" }},
        .subcommands = &.{.{
            .name = "c",
            .flags = &.{.{ .long = "cflag" }},
            .args = &.{.{ .name = "which", .complete = .{ .choices = &.{ "red", "green" } } }},
        }},
    }},
}};

test "compute: a 3-level subcommand tree offers the middle command's sub-names at its own bare cursor position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &NestedTestTable, &.{ "a", "b", "" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("c", got.candidates[0].value);
}

test "compute: a 3-level subcommand tree recurses to the deepest command's own positional completer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &NestedTestTable, &.{ "a", "b", "c", "" }, null, &ctx);
    try testing.expectEqual(@as(usize, 2), got.candidates.len);
    try testing.expect(containsValue(got.candidates, "red"));
    try testing.expect(containsValue(got.candidates, "green"));
}

test "compute: a 3-level subcommand tree recurses to the deepest command's own flag names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = TestCtx{};

    const got = try TC.compute(arena, &NestedTestTable, &.{ "a", "b", "c", "--" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("--cflag", got.candidates[0].value);
}

const DashNamedSubTable = [_]TestCommand{.{
    .name = "cmd",
    .flags = &.{.{ .long = "top" }},
    // A dash-named subcommand is nonsensical but structurally possible; the
    // flag-shape guard must refuse to descend into it, exactly as dispatch's
    // `descend` does, so completion and dispatch walk the tree identically.
    .subcommands = &.{.{ .name = "-x", .flags = &.{.{ .long = "deep" }} }},
}};

test "compute: a flag-shaped descending word is not matched against subcommand names, mirroring dispatch's descend guard" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = TestCtx{};

    // Without the guard, "-x" would descend into the dash-named subcommand
    // and offer its "--deep" flag; with it, the walk stays on cmd and offers
    // cmd's own "--top".
    const got = try TC.compute(arena, &DashNamedSubTable, &.{ "cmd", "-x", "--" }, null, &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("--top", got.candidates[0].value);
}
