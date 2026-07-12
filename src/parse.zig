//! Left-to-right argv classifier: flags, `--opt value`/`--opt=value` options,
//! positionals, and a `--` passthrough tail are each matched independently of
//! their position in argv. Callers must consume all flags and value-taking
//! options before calling `positional()`: a two-token option's value would
//! otherwise be ambiguous with a positional (e.g. `positional()` on
//! `{"-p", "8080"}` would steal "8080" if called before `option("port", 'p')`
//! claims it). `finish` then verifies every token was claimed.
//!
//! A short flag/option may also appear clustered with others in one token
//! (`-abc`); `registerShort` must be called for every short char before any
//! cluster token is scanned, so a cluster can be decomposed against the full
//! set of registered chars regardless of which `flag`/`option` call reaches
//! it first. `flag`/`option` are idempotent across repeats: a flag repeated
//! (clustered or not) stays true, and an option repeated keeps its last value.
const std = @import("std");
const spec = @import("spec.zig");

/// `UsageError` for malformed argv (bad flag, missing value, unconsumed
/// token); `OutOfMemory` propagates from the allocator passed to `init`.
pub const Error = error{ UsageError, OutOfMemory };

/// Whether a registered short char is a bare boolean flag or takes a value,
/// as declared via `Parser.registerShort`.
pub const ShortRole = enum { flag, option };

/// One resolved short flag/option occurrence inside a clustered token
/// (`-abc`), claimed independently by whichever `flag`/`option` call matches
/// its `char`.
const ClusterSlot = struct {
    char: u8,
    role: ShortRole,
    claimed: bool = false,
    /// Set only when `role == .option`: the glued value text taken from the
    /// rest of the owning token, or null when the value is the following
    /// argv token.
    glued_value: ?[]const u8 = null,
};

/// One argv element and whether some `flag`/`option`/`positional`/
/// `rest` call has already claimed it.
pub const Token = struct {
    raw: []const u8,
    consumed: bool = false,
    /// Lazily computed decomposition for a clustered short token; null until
    /// some `flag`/`option` call first scans past it. Arena-owned by the
    /// Parser.
    cluster: ?[]ClusterSlot = null,
};

/// Left-to-right argv classifier. See the module doc for the full
/// claim-before-`positional()` contract.
pub const Parser = struct {
    alloc: std.mem.Allocator,
    tokens: []Token,
    message: []const u8 = "",
    /// Owned by the Parser (not the caller) so `deinit` can free it: the
    /// slice `rest` hands back, retained here purely for cleanup bookkeeping.
    passthrough: ?[]const []const u8 = null,
    /// Index of the first literal "--" token, if argv has one. A lone "--"
    /// always ends option parsing: `flag`/`option` never match at or past
    /// this index, and `finish` never reports the "--" token itself as a
    /// leftover.
    dashdash: ?usize = null,
    /// Every short char declared via `registerShort`, consulted to
    /// decompose a clustered token. Backed by `cluster_arena`.
    short_registry: std.AutoHashMapUnmanaged(u8, ShortRole) = .{},
    /// Backs `short_registry` and every `Token.cluster` slice; freed in one
    /// shot by `deinit`.
    cluster_arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator, argv: []const []const u8) !Parser {
        const tokens = try alloc.alloc(Token, argv.len);
        for (argv, tokens) |raw, *t| t.* = .{ .raw = raw };
        var dashdash: ?usize = null;
        for (tokens, 0..) |t, i| {
            if (std.mem.eql(u8, t.raw, "--")) {
                dashdash = i;
                break;
            }
        }
        return .{
            .alloc = alloc,
            .tokens = tokens,
            .dashdash = dashdash,
            .cluster_arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.cluster_arena.deinit();
        self.alloc.free(self.tokens);
        if (self.passthrough) |p| self.alloc.free(p);
        if (self.message.len != 0) self.alloc.free(self.message);
    }

    /// Declares a short char's role so a later clustered token (`-abc`) can
    /// be decomposed correctly regardless of which `flag`/`option` call
    /// scans it first. Every short char used in a Spec must be registered
    /// before any `flag`/`option` call runs.
    pub fn registerShort(self: *Parser, short: u8, role: ShortRole) error{OutOfMemory}!void {
        try self.short_registry.put(self.cluster_arena.allocator(), short, role);
    }

    /// Sets `self.message`, freeing any prior message first so repeated
    /// error paths on the same Parser don't leak.
    fn setMessage(self: *Parser, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const new_message = try std.fmt.allocPrint(self.alloc, fmt, args);
        if (self.message.len != 0) self.alloc.free(self.message);
        self.message = new_message;
    }

    fn isLongFlag(raw: []const u8, long: []const u8) bool {
        return std.mem.startsWith(u8, raw, "--") and std.mem.eql(u8, raw[2..], long);
    }

    fn isShortFlag(raw: []const u8, short: u8) bool {
        return raw.len == 2 and raw[0] == '-' and raw[1] == short;
    }

    /// A clustered short-flag token: `-abc`, but not a bare `-a` (handled by
    /// `isShortFlag`) or a long flag/option (`--x`).
    fn isCluster(raw: []const u8) bool {
        return raw.len > 2 and raw[0] == '-' and raw[1] != '-';
    }

    /// Tokens `flag`/`option` are allowed to match against: everything before
    /// a lone "--", or the whole token list when there is none.
    fn beforeDoubleDash(self: *Parser) []Token {
        return self.tokens[0..(self.dashdash orelse self.tokens.len)];
    }

    /// Decomposes a clustered token (`raw.len > 2`, single leading `-`) into
    /// its short flag/option occurrences, scanning left to right against
    /// `short_registry`. A bool-flag char is consumed and scanning
    /// continues; a value-option char ends the scan, greedily taking the
    /// rest of the token as its glued value (or, if it is the terminal char,
    /// the following argv token) regardless of what those following bytes
    /// are, so the same `-o<chars>` shape parses identically no matter which
    /// following bytes happen to be registered short chars. A single leading
    /// `=` in the glued remainder is stripped (`-o=val` -> `val`), mirroring
    /// the long form's `--opt=val`; a literal-leading-`=` value goes through
    /// the next-token form (`-o =x`). An unregistered char is rejected by
    /// name.
    fn classifyCluster(self: *Parser, raw: []const u8) Error![]ClusterSlot {
        var slots: std.ArrayListUnmanaged(ClusterSlot) = .empty;
        var i: usize = 1;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            const role = self.short_registry.get(c) orelse {
                try self.setMessage("unknown short flag: -{c}", .{c});
                return error.UsageError;
            };
            switch (role) {
                .flag => try slots.append(self.cluster_arena.allocator(), .{ .char = c, .role = .flag }),
                .option => {
                    const glued: ?[]const u8 = if (i + 1 >= raw.len)
                        null
                    else if (raw[i + 1] == '=')
                        raw[i + 2 ..]
                    else
                        raw[i + 1 ..];
                    try slots.append(self.cluster_arena.allocator(), .{ .char = c, .role = .option, .glued_value = glued });
                    break;
                },
            }
        }
        return slots.toOwnedSlice(self.cluster_arena.allocator());
    }

    /// Returns `t`'s cached cluster decomposition, computing and caching it
    /// on first access.
    fn clusterSlots(self: *Parser, t: *Token) Error![]ClusterSlot {
        if (t.cluster) |c| return c;
        const slots = try self.classifyCluster(t.raw);
        t.cluster = slots;
        return slots;
    }

    /// Matches `--long` or `-{short}` among unconsumed tokens before a lone
    /// "--" (if any), including as part of a clustered token (`-abc`).
    /// `short` is optional; pass null for a flag with no short form. Scans
    /// every unconsumed token so a repeated flag is fully consumed
    /// (idempotent) rather than left over for `finish`.
    pub fn flag(self: *Parser, long: []const u8, short: ?u8) Error!bool {
        var found = false;
        for (self.beforeDoubleDash()) |*t| {
            if (t.consumed) continue;

            if (isLongFlag(t.raw, long) or (short != null and isShortFlag(t.raw, short.?))) {
                t.consumed = true;
                found = true;
                continue;
            }

            if (isCluster(t.raw)) {
                const slots = try self.clusterSlots(t);
                var all_claimed = true;
                for (slots) |*slot| {
                    if (short != null and slot.role == .flag and slot.char == short.? and !slot.claimed) {
                        slot.claimed = true;
                        found = true;
                    }
                    if (!slot.claimed) all_claimed = false;
                }
                if (all_claimed) t.consumed = true;
            }
        }
        return found;
    }

    /// Matches `--long=value`, `--long value`, or `-{short} value` among
    /// unconsumed tokens before a lone "--" (if any), including a clustered
    /// token's trailing value-option (`-abo value` or glued `-abovalue`).
    /// The two-token forms error if no value follows. Scans every unconsumed
    /// token so a repeated option keeps its last value (last-wins) rather
    /// than leaving an earlier occurrence unconsumed for `finish`.
    pub fn option(self: *Parser, long: []const u8, short: ?u8) Error!?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.beforeDoubleDash(), 0..) |*t, i| {
            if (t.consumed) continue;

            if (std.mem.startsWith(u8, t.raw, "--")) {
                const body = t.raw[2..];
                if (std.mem.eql(u8, body, long)) {
                    result = try self.takeFollowingValue(t, i, "--", long);
                    continue;
                }
                if (body.len > long.len and body[long.len] == '=' and std.mem.startsWith(u8, body, long)) {
                    t.consumed = true;
                    result = body[long.len + 1 ..];
                    continue;
                }
                continue;
            }

            if (short != null and isShortFlag(t.raw, short.?)) {
                result = try self.takeFollowingValue(t, i, "-", &[_]u8{short.?});
                continue;
            }

            if (short != null and isCluster(t.raw)) {
                const slots = try self.clusterSlots(t);
                var all_claimed = true;
                for (slots) |*slot| {
                    if (slot.role == .option and slot.char == short.? and !slot.claimed) {
                        slot.claimed = true;
                        result = slot.glued_value orelse try self.consumeValueToken(i, "-", &[_]u8{short.?});
                    }
                    if (!slot.claimed) all_claimed = false;
                }
                if (all_claimed) t.consumed = true;
            }
        }
        return result;
    }

    /// Shared two-token-option logic: consumes `tokens[i + 1]` as the value,
    /// or reports `spelling ++ name` requires a value when no adjacent token
    /// follows or that token is flag-shaped. Flag-shapedness is checked on
    /// the raw text so the outcome does not depend on whether some other
    /// field has already consumed the token.
    fn consumeValueToken(self: *Parser, i: usize, prefix: []const u8, name: []const u8) Error![]const u8 {
        if (i + 1 >= self.tokens.len or spec.looksLikeFlag(self.tokens[i + 1].raw)) {
            try self.setMessage("{s}{s} requires a value", .{ prefix, name });
            return error.UsageError;
        }
        self.tokens[i + 1].consumed = true;
        return self.tokens[i + 1].raw;
    }

    /// The flag token plus its following value, via `consumeValueToken`.
    fn takeFollowingValue(self: *Parser, flag_tok: *Token, i: usize, prefix: []const u8, name: []const u8) Error!?[]const u8 {
        const value = try self.consumeValueToken(i, prefix, name);
        flag_tok.consumed = true;
        return value;
    }

    /// Next unconsumed token, in argv order. Before a lone "--" (if any) it
    /// must not be flag-shaped. `allow_past_dashdash` governs what happens
    /// once the pre-"--" tokens are exhausted: when true, the "--" itself is
    /// skipped and every token past it is returned verbatim regardless of
    /// shape (the no-variadic Spec case, where a positional is the only way
    /// to reach a post-"--" value); when false, scanning stops at "--" and a
    /// starved call returns null without touching "--" or anything past it,
    /// leaving those tokens exclusively for `rest` (the
    /// Pos+Rest case).
    pub fn positional(self: *Parser, allow_past_dashdash: bool) ?[]const u8 {
        const limit = if (allow_past_dashdash) self.tokens.len else (self.dashdash orelse self.tokens.len);
        for (self.tokens[0..limit], 0..) |*t, i| {
            if (t.consumed) continue;
            if (self.dashdash) |dd| {
                if (i == dd) {
                    t.consumed = true;
                    continue;
                }
                if (i > dd) {
                    t.consumed = true;
                    return t.raw;
                }
            }
            if (spec.looksLikeFlag(t.raw)) continue;
            t.consumed = true;
            return t.raw;
        }
        return null;
    }

    /// The variadic tail, in argv order: every plain positional left over
    /// after the fixed ones, plus every post-"--" token verbatim (dash-led
    /// included). Before "--", a flag-shaped token is left unclaimed so an
    /// unknown flag still surfaces from `finish` instead of being silently
    /// swallowed into the tail. Consumes "--" and each token it returns, so a
    /// later `flag`/`option`/`positional` call never mistakes tail content for
    /// one of the parser's own switches. A caller with no variadic field may
    /// still call `positional(true)` first and let it dip past "--"; any token
    /// that dipped is already consumed and is skipped here, so the same token
    /// is never handed to both a positional and the tail. Caller does not own
    /// the returned slice's memory beyond the Parser's lifetime.
    pub fn rest(self: *Parser) Error![]const []const u8 {
        var count: usize = 0;
        for (self.tokens, 0..) |t, i| {
            if (t.consumed) continue;
            if (self.dashdash) |dd| {
                if (i == dd) continue;
                if (i > dd) {
                    count += 1;
                    continue;
                }
            }
            if (spec.looksLikeFlag(t.raw)) continue;
            count += 1;
        }

        const out = try self.alloc.alloc([]const u8, count);
        var j: usize = 0;
        for (self.tokens, 0..) |*t, i| {
            if (t.consumed) continue;
            if (self.dashdash) |dd| {
                if (i == dd) {
                    t.consumed = true;
                    continue;
                }
                if (i > dd) {
                    t.consumed = true;
                    out[j] = t.raw;
                    j += 1;
                    continue;
                }
            }
            if (spec.looksLikeFlag(t.raw)) continue;
            t.consumed = true;
            out[j] = t.raw;
            j += 1;
        }
        self.passthrough = out;
        return out;
    }

    /// Errors if any token was never consumed by `flag`/`option`/`positional`
    /// or swallowed by `rest`. A lone "--" is never reported
    /// even when nothing else consumed it (a Spec with no positional or
    /// variadic field still lets "--" terminate options cleanly).
    pub fn finish(self: *Parser) Error!void {
        for (self.tokens, 0..) |t, i| {
            if (self.dashdash != null and i == self.dashdash.?) continue;
            if (!t.consumed) {
                try self.setMessage("unexpected argument: {s}", .{t.raw});
                return error.UsageError;
            }
        }
    }
};

test "parser: flags, options, positionals, passthrough, finish" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "--json", "-p", "8080", "name", "--", "raw", "args" });
    defer p.deinit();
    try std.testing.expect(try p.flag("json", null));
    try std.testing.expectEqualStrings("8080", (try p.option("port", 'p')).?);
    try std.testing.expectEqualStrings("name", p.positional(true).?);
    const rest = try p.rest();
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try p.finish(); // nothing left over
}

test "parser: finish reports an unconsumed unknown flag" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{"--nope"});
    defer p.deinit();
    try std.testing.expectError(error.UsageError, p.finish());
}

test "parser: two error paths do not leak the message" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{"--a"});
    defer p.deinit();
    _ = p.option("a", null) catch {};
    try std.testing.expectError(error.UsageError, p.finish());
}

test "parser: option() does not take a flag-shaped adjacent token as its value" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "--org", "--json" });
    defer p.deinit();
    try std.testing.expectError(error.UsageError, p.option("org", null));
}

test "parser: option() rejection of a flag-shaped value does not depend on match order" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "--org", "--json" });
    defer p.deinit();
    try std.testing.expect(try p.flag("json", null));
    try std.testing.expectError(error.UsageError, p.option("org", null));
}

test "parser: positional() returns tokens after a lone -- verbatim, including dash-led ones" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "x", "--", "-y" });
    defer p.deinit();
    try std.testing.expectEqualStrings("x", p.positional(true).?);
    try std.testing.expectEqualStrings("-y", p.positional(true).?);
    try p.finish();
}

test "parser: positional(false) refuses to dip past a lone --, leaving it and everything after untouched" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "--", "a", "b" });
    defer p.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), p.positional(false));
    const rest = try p.rest();
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("a", rest[0]);
    try std.testing.expectEqualStrings("b", rest[1]);
}

test "parser: positional(false) still resolves a token that appears before --" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "x", "--", "a" });
    defer p.deinit();
    try std.testing.expectEqualStrings("x", p.positional(false).?);
    const rest = try p.rest();
    try std.testing.expectEqual(@as(usize, 1), rest.len);
    try std.testing.expectEqualStrings("a", rest[0]);
}

test "parser: finish() does not report a lone -- even when nothing consumes it" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{"--"});
    defer p.deinit();
    try p.finish();
}

test "parser: a short-flag cluster sets each registered bool flag" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{"-ab"});
    defer p.deinit();
    try p.registerShort('a', .flag);
    try p.registerShort('b', .flag);
    try std.testing.expect(try p.flag("alpha", 'a'));
    try std.testing.expect(try p.flag("bravo", 'b'));
    try p.finish();
}

test "parser: a cluster's trailing value-option takes the next token" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "-abo", "val" });
    defer p.deinit();
    try p.registerShort('a', .flag);
    try p.registerShort('b', .flag);
    try p.registerShort('o', .option);
    try std.testing.expect(try p.flag("alpha", 'a'));
    try std.testing.expect(try p.flag("bravo", 'b'));
    try std.testing.expectEqualStrings("val", (try p.option("oscar", 'o')).?);
    try p.finish();
}

test "parser: a cluster's trailing value-option takes a glued value" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{"-aoval"});
    defer p.deinit();
    try p.registerShort('a', .flag);
    try p.registerShort('o', .option);
    try std.testing.expect(try p.flag("alpha", 'a'));
    try std.testing.expectEqualStrings("val", (try p.option("oscar", 'o')).?);
    try p.finish();
}

test "parser: a value-option greedily takes the token remainder regardless of registration" {
    const a = std.testing.allocator;
    // -oab: a,b registered as bool flags; -o still takes "ab" as its value.
    var p = try Parser.init(a, &.{"-oab"});
    defer p.deinit();
    try p.registerShort('o', .option);
    try p.registerShort('a', .flag);
    try p.registerShort('b', .flag);
    try std.testing.expectEqualStrings("ab", (try p.option("oscar", 'o')).?);
    try std.testing.expect(!try p.flag("alpha", 'a'));
    try std.testing.expect(!try p.flag("bravo", 'b'));
    try p.finish();

    // -oxy: x,y unregistered; same shape, same greedy result "xy", no error.
    var p2 = try Parser.init(a, &.{"-oxy"});
    defer p2.deinit();
    try p2.registerShort('o', .option);
    try std.testing.expectEqualStrings("xy", (try p2.option("oscar", 'o')).?);
    try p2.finish();
}

test "parser: a short value-option accepts -o=value, stripping one leading =" {
    const a = std.testing.allocator;

    // -o=val -> val
    var p = try Parser.init(a, &.{"-o=val"});
    defer p.deinit();
    try p.registerShort('o', .option);
    try std.testing.expectEqualStrings("val", (try p.option("oscar", 'o')).?);
    try p.finish();

    // -o==x -> "=x" (only the first = is stripped, like the long form)
    var p2 = try Parser.init(a, &.{"-o==x"});
    defer p2.deinit();
    try p2.registerShort('o', .option);
    try std.testing.expectEqualStrings("=x", (try p2.option("oscar", 'o')).?);
    try p2.finish();

    // -o= -> "" (empty value)
    var p3 = try Parser.init(a, &.{"-o="});
    defer p3.deinit();
    try p3.registerShort('o', .option);
    try std.testing.expectEqualStrings("", (try p3.option("oscar", 'o')).?);
    try p3.finish();

    // -oval -> val (no =, greedy remainder unchanged)
    var p4 = try Parser.init(a, &.{"-oval"});
    defer p4.deinit();
    try p4.registerShort('o', .option);
    try std.testing.expectEqualStrings("val", (try p4.option("oscar", 'o')).?);
    try p4.finish();

    // -vo=val -> v=true, o="val"
    var p5 = try Parser.init(a, &.{"-vo=val"});
    defer p5.deinit();
    try p5.registerShort('v', .flag);
    try p5.registerShort('o', .option);
    try std.testing.expect(try p5.flag("verbose", 'v'));
    try std.testing.expectEqualStrings("val", (try p5.option("oscar", 'o')).?);
    try p5.finish();

    // -o =x (space form) -> o="=x": a literal-leading-= value stays reachable.
    var p6 = try Parser.init(a, &.{ "-o", "=x" });
    defer p6.deinit();
    try p6.registerShort('o', .option);
    try std.testing.expectEqualStrings("=x", (try p6.option("oscar", 'o')).?);
    try p6.finish();
}

test "parser: an unregistered char in a cluster is a UsageError" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{"-ax"});
    defer p.deinit();
    try p.registerShort('a', .flag);
    try std.testing.expectError(error.UsageError, p.flag("alpha", 'a'));
}

test "parser: a repeated long flag is idempotent, not left over for finish" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "--verbose", "--verbose" });
    defer p.deinit();
    try std.testing.expect(try p.flag("verbose", null));
    try p.finish();
}

test "parser: a repeated short flag, separate and clustered, is idempotent" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "-v", "-v" });
    defer p.deinit();
    try std.testing.expect(try p.flag("verbose", 'v'));
    try p.finish();

    var p2 = try Parser.init(a, &.{"-vv"});
    defer p2.deinit();
    try p2.registerShort('v', .flag);
    try std.testing.expect(try p2.flag("verbose", 'v'));
    try p2.finish();
}

test "parser: a repeated option is last-wins across --opt value and --opt=value forms" {
    const a = std.testing.allocator;
    var p = try Parser.init(a, &.{ "--port", "1", "--port", "2" });
    defer p.deinit();
    try std.testing.expectEqualStrings("2", (try p.option("port", null)).?);
    try p.finish();

    var p2 = try Parser.init(a, &.{ "--port=1", "--port=2" });
    defer p2.deinit();
    try std.testing.expectEqualStrings("2", (try p2.option("port", null)).?);
    try p2.finish();
}
