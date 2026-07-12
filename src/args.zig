//! Reifies a Spec struct into its typed result (`Args`) and resolves each
//! field from argv, falling back through env, config, and declared defaults
//! via `parseInto`. The bridge between `spec`'s comptime field declarations
//! and `parse`'s argv classifier.
const std = @import("std");
const spec = @import("spec.zig");
const parse = @import("parse.zig");
const resolve = @import("resolve.zig");

/// Reify the typed result struct for a Spec: one field per Spec field, typed by
/// its arg_info. flag->bool (default false), option(T)->?T (default null),
/// positional(T)->T (required) or ?T (default null) when meta.optional,
/// variadic->[]const []const u8 (default &.{}). Field names match the Spec.
pub fn Args(comptime Spec: type) type {
    const Attributes = std.builtin.Type.StructField.Attributes;
    const src_fields = @typeInfo(Spec).@"struct".fields;
    var names: [src_fields.len][:0]const u8 = undefined;
    var types: [src_fields.len]type = undefined;
    var attrs: [src_fields.len]Attributes = undefined;
    inline for (src_fields, 0..) |f, i| {
        const info = @field(f.type, "arg_info");
        names[i] = f.name;
        types[i] = switch (info.kind) {
            .flag => bool,
            .option => ?info.Value,
            .positional => if (info.meta.optional) ?info.Value else info.Value,
            .variadic => []const []const u8,
        };
        attrs[i] = switch (info.kind) {
            .flag => .{ .default_value_ptr = &false },
            .option => .{ .default_value_ptr = &@as(?info.Value, null) },
            .positional => if (info.meta.optional)
                .{ .default_value_ptr = &@as(?info.Value, null) }
            else
                .{},
            .variadic => .{ .default_value_ptr = @as(?*const anyopaque, @ptrCast(&@as([]const []const u8, &.{}))) },
        };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

test "Args(Spec) maps each field to its parsed value type" {
    const Spec = struct {
        json: spec.Flag(.{}),
        port: spec.Opt(u16, .{}),
        name: spec.Pos([]const u8, .{}),
        tags: spec.Pos([]const u8, .{ .optional = true }),
        rest: spec.Rest(.{}),
    };
    const A = Args(Spec);
    const fields = @typeInfo(A).@"struct".fields;
    try std.testing.expectEqual(bool, @FieldType(A, "json"));
    try std.testing.expectEqual(?u16, @FieldType(A, "port"));
    try std.testing.expectEqual([]const u8, @FieldType(A, "name"));
    try std.testing.expectEqual(?[]const u8, @FieldType(A, "tags"));
    try std.testing.expectEqual([]const []const u8, @FieldType(A, "rest"));
    try std.testing.expectEqual(@as(usize, 5), fields.len);

    const a: A = .{ .name = "x" };
    try std.testing.expectEqual(false, a.json);
    try std.testing.expectEqual(@as(?u16, null), a.port);
    try std.testing.expectEqual(@as(?[]const u8, null), a.tags);
    try std.testing.expectEqual(@as(usize, 0), a.rest.len);
}

/// The app-supplied env and (optional) config lookups `parseInto` falls back
/// to when argv omits a field.
pub const Source = struct {
    env_get: *const fn ([]const u8) ?[]const u8,
    config_get: ?*const fn ([]const u8) ?[]const u8,
};

/// Optional out-param for `parseInto`: on a `UsageError` its `message` is set
/// to a human-readable, `alloc`-owned string the caller can render. Left empty
/// on success. Caller frees `message` (an arena frees it wholesale).
pub const Diagnostic = struct { message: []const u8 = "" };

/// `meta`'s fallback string for `field_name`, tried in env > config > default
/// order (argv is handled by the caller before reaching here). The config key
/// defaults to the field name, overridable via `meta.config_key`.
fn fallback(m: spec.Meta, field_name: []const u8, source: Source) ?[]const u8 {
    if (m.env) |e| if (source.env_get(e)) |v| return v;
    if (source.config_get) |get| if (get(m.config_key orelse field_name)) |v| return v;
    return m.default;
}

/// Records `msg` (formatted into `alloc`) on `diag` when present, then returns
/// the `UsageError` every `parseInto` failure site propagates. An allocation
/// failure while formatting degrades to an empty message rather than masking
/// the usage error.
fn usageError(alloc: std.mem.Allocator, diag: ?*Diagnostic, comptime fmt: []const u8, args: anytype) parse.Error {
    if (diag) |d| d.message = std.fmt.allocPrint(alloc, fmt, args) catch "";
    return error.UsageError;
}

/// Drives a `parse.Parser` over `Spec`'s declared flags/options/positionals
/// and resolves each field's string by precedence argv > env > config >
/// default, parsing it to the field's `Value` type. Three passes over the
/// comptime fields, regardless of declaration order: pass 1 claims every
/// flag and value-option so a two-token option's value can never be stolen
/// by `positional()`; pass 2 reads all fixed positionals; pass 3 reads the
/// variadic tail. When `Spec` declares a variadic (`Rest`) field, a fixed
/// positional may only resolve from a token before a lone "--": it never
/// dips into the post-"--" tail, which belongs to the variadic exclusively,
/// so a starved optional positional resolves to its fallback/null and a
/// starved required one is `error.UsageError` even when post-"--" tokens
/// exist. A `Spec` with no variadic field keeps the older behavior: a
/// positional may still claim a post-"--" token verbatim (dash-led included),
/// since that is the only way such a Spec can accept a dash-led positional
/// value. A required positional with no resolved value is `error.UsageError`.
///
/// The result's variadic (`rest`) slice is owned by `alloc` and outlives the
/// Parser; its elements point into the caller's `argv`. Intended usage is an
/// arena freed wholesale; a non-arena caller must `alloc.free(result.rest)`.
///
/// On any `UsageError`, when `diag` is non-null its `message` is set to an
/// `alloc`-owned human-readable string (the parser's own message, or the
/// missing/invalid field). `diag` may be null when the caller does not need
/// the text.
pub fn parseInto(comptime Spec: type, alloc: std.mem.Allocator, argv: []const []const u8, source: Source, diag: ?*Diagnostic) parse.Error!Args(Spec) {
    var p = try parse.Parser.init(alloc, argv);
    defer p.deinit();

    var result: Args(Spec) = undefined;
    const fields = @typeInfo(Spec).@"struct".fields;

    // Register every flag/option's short char up front so a clustered token
    // (`-abc`) can be decomposed against the full set, regardless of which
    // field's `flag`/`option` call reaches it first.
    inline for (fields) |f| {
        const info = @field(f.type, "arg_info");
        if (info.meta.short) |s| {
            switch (info.kind) {
                .flag => try p.registerShort(s, .flag),
                .option => try p.registerShort(s, .option),
                .positional, .variadic => {},
            }
        }
    }

    inline for (fields) |f| {
        const info = @field(f.type, "arg_info");
        switch (info.kind) {
            .flag => {
                const long = comptime spec.kebab(f.name);
                @field(result, f.name) = p.flag(long, info.meta.short) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    error.UsageError => return usageError(alloc, diag, "{s}", .{p.message}),
                };
            },
            .option => {
                const long = comptime spec.kebab(f.name);
                const opt = p.option(long, info.meta.short) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    error.UsageError => return usageError(alloc, diag, "{s}", .{p.message}),
                };
                const raw = opt orelse fallback(info.meta, f.name, source);
                @field(result, f.name) = if (raw) |s|
                    resolve.parseValue(info.Value, s) catch
                        return usageError(alloc, diag, "invalid value for --" ++ long ++ ": {s}", .{s})
                else
                    null;
            },
            .positional, .variadic => {},
        }
    }

    // A variadic (Rest) field anywhere in the Spec means a fixed positional
    // must never dip past a lone "--": every post-"--" token belongs to the
    // variadic exclusively. Computed once, order-independent.
    const has_rest = comptime blk: {
        for (fields) |f| {
            if (@field(f.type, "arg_info").kind == .variadic) break :blk true;
        }
        break :blk false;
    };

    // Fixed positionals resolve before the variadic, regardless of field
    // order.
    inline for (fields) |f| {
        const info = @field(f.type, "arg_info");
        if (info.kind == .positional) {
            const raw = p.positional(!has_rest) orelse fallback(info.meta, f.name, source);
            if (raw) |s| {
                @field(result, f.name) = resolve.parseValue(info.Value, s) catch
                    return usageError(alloc, diag, "invalid value for " ++ f.name ++ ": {s}", .{s});
            } else if (info.meta.optional) {
                @field(result, f.name) = null;
            } else {
                return usageError(alloc, diag, "missing required argument: " ++ f.name, .{});
            }
        }
    }

    inline for (fields) |f| {
        const info = @field(f.type, "arg_info");
        if (info.kind == .variadic) {
            @field(result, f.name) = try p.restAfterDoubleDash();
        }
    }

    p.finish() catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.UsageError => return usageError(alloc, diag, "{s}", .{p.message}),
    };

    // Re-own the variadic tail in `alloc`: `restAfterDoubleDash` hands back a
    // Parser-owned array that `deinit` frees on return. Done after `finish`
    // so a failed parse never allocates it.
    inline for (fields) |f| {
        if (@field(f.type, "arg_info").kind == .variadic) {
            @field(result, f.name) = try alloc.dupe([]const u8, @field(result, f.name));
        }
    }

    return result;
}

fn envNone(_: []const u8) ?[]const u8 {
    return null;
}
fn envProfile(k: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, k, "APP_PROFILE")) "work" else null;
}

test "parseInto: argv wins; env fallback; default; required-missing errors" {
    const a = std.testing.allocator;
    const Spec = struct {
        json: spec.Flag(.{}),
        profile: spec.Opt([]const u8, .{ .env = "APP_PROFILE", .default = "personal" }),
        port: spec.Opt(u16, .{ .default = "8080" }),
        name: spec.Pos([]const u8, .{}),
    };
    const src = Source{ .env_get = envProfile, .config_get = null };

    // argv provides name + json; profile falls back to env; port to default.
    const r = try parseInto(Spec, a, &.{ "--json", "widget" }, src, null);
    try std.testing.expect(r.json);
    try std.testing.expectEqualStrings("work", r.profile.?); // from env
    try std.testing.expectEqual(@as(u16, 8080), r.port.?); // from default
    try std.testing.expectEqualStrings("widget", r.name);

    // required positional missing -> UsageError
    const bad = parseInto(Spec, a, &.{"--json"}, .{ .env_get = envNone, .config_get = null }, null);
    try std.testing.expectError(error.UsageError, bad);
}

test "parseInto: option is claimed before positional even when the positional field is declared first" {
    const a = std.testing.allocator;
    const Spec = struct {
        name: spec.Pos([]const u8, .{}),
        port: spec.Opt(u16, .{ .short = 'p' }),
    };
    const src = Source{ .env_get = envNone, .config_get = null };

    // A naive single-pass, declaration-order implementation would let
    // positional() steal "8080" before option("port", 'p') claims it.
    const r = try parseInto(Spec, a, &.{ "-p", "8080", "thename" }, src, null);
    try std.testing.expectEqual(@as(?u16, 8080), r.port);
    try std.testing.expectEqualStrings("thename", r.name);
}

fn configRegion(k: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, k, "region")) "us-east" else null;
}

test "parseInto: rest slice is alloc-owned and outlives the Parser" {
    const a = std.testing.allocator;
    const Spec = struct { rest: spec.Rest(.{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "--", "alpha", "beta" }, src, null);
    defer a.free(r.rest);

    // Reuse of any freed backing array would corrupt r.rest before this read.
    const scratch = try a.alloc(u8, 64);
    @memset(scratch, 0xAA);
    a.free(scratch);

    try std.testing.expectEqual(@as(usize, 2), r.rest.len);
    try std.testing.expectEqualStrings("alpha", r.rest[0]);
    try std.testing.expectEqualStrings("beta", r.rest[1]);
}

test "parseInto: a multi-word option field matches its kebab-case flag, not the underscored spelling" {
    const a = std.testing.allocator;
    const Spec = struct { old_org: spec.Opt([]const u8, .{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "--old-org", "acme" }, src, null);
    try std.testing.expectEqualStrings("acme", r.old_org.?);

    const bad = parseInto(Spec, a, &.{ "--old_org", "acme" }, src, null);
    try std.testing.expectError(error.UsageError, bad);
}

test "parseInto: config key defaults to the field name" {
    const a = std.testing.allocator;
    const Spec = struct { region: spec.Opt([]const u8, .{ .default = "def" }) };
    const src = Source{ .env_get = envNone, .config_get = configRegion };

    const r = try parseInto(Spec, a, &.{}, src, null);
    try std.testing.expectEqualStrings("us-east", r.region.?);
}

test "parseInto: required-missing populates the diagnostic message" {
    const a = std.testing.allocator;
    const Spec = struct { name: spec.Pos([]const u8, .{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    var diag = Diagnostic{};
    const bad = parseInto(Spec, a, &.{}, src, &diag);
    defer a.free(diag.message);

    try std.testing.expectError(error.UsageError, bad);
    try std.testing.expect(diag.message.len != 0);
}

test "parseInto: an option does not swallow a following flag-shaped token as its value" {
    const a = std.testing.allocator;
    const Spec = struct {
        org: spec.Opt([]const u8, .{}),
        json: spec.Flag(.{}),
    };
    const src = Source{ .env_get = envNone, .config_get = null };

    const bad = parseInto(Spec, a, &.{ "--org", "--json" }, src, null);
    try std.testing.expectError(error.UsageError, bad);
}

test "parseInto: the flag-shaped-value rejection is independent of field declaration order" {
    const a = std.testing.allocator;
    const Spec = struct {
        json: spec.Flag(.{}),
        org: spec.Opt([]const u8, .{}),
    };
    const src = Source{ .env_get = envNone, .config_get = null };

    const bad = parseInto(Spec, a, &.{ "--org", "--json" }, src, null);
    try std.testing.expectError(error.UsageError, bad);
}

test "parseInto: an option still takes a non-flag-shaped adjacent value" {
    const a = std.testing.allocator;
    const Spec = struct { org: spec.Opt([]const u8, .{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "--org", "val" }, src, null);
    try std.testing.expectEqualStrings("val", r.org.?);
}

test "parseInto: explicit --long=value still allows a dash-led value" {
    const a = std.testing.allocator;
    const Spec = struct { org: spec.Opt([]const u8, .{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{"--org=--json"}, src, null);
    try std.testing.expectEqualStrings("--json", r.org.?);
}

test "parseInto: a lone -- terminates options for a Spec with no Rest field" {
    const a = std.testing.allocator;
    const Spec = struct { name: spec.Pos([]const u8, .{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "--", "thing" }, src, null);
    try std.testing.expectEqualStrings("thing", r.name);
}

test "parseInto: a positional after -- is taken verbatim even when dash-led" {
    const a = std.testing.allocator;
    const Spec = struct { name: spec.Pos([]const u8, .{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "--", "-5" }, src, null);
    try std.testing.expectEqualStrings("-5", r.name);
}

test "parseInto: positionals before and after -- both resolve correctly" {
    const a = std.testing.allocator;
    const Spec = struct {
        first: spec.Pos([]const u8, .{}),
        second: spec.Pos([]const u8, .{}),
    };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "x", "--", "-y" }, src, null);
    try std.testing.expectEqualStrings("x", r.first);
    try std.testing.expectEqualStrings("-y", r.second);
}

test "parseInto: a flag before -- and a positional after -- both resolve" {
    const a = std.testing.allocator;
    const Spec = struct {
        flag: spec.Flag(.{}),
        name: spec.Pos([]const u8, .{}),
    };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "--flag", "--", "pos" }, src, null);
    try std.testing.expect(r.flag);
    try std.testing.expectEqualStrings("pos", r.name);
}

test "parseInto: a Rest field still captures dash-led tokens after --" {
    const a = std.testing.allocator;
    const Spec = struct { rest: spec.Rest(.{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "--", "-a", "-b" }, src, null);
    defer a.free(r.rest);

    try std.testing.expectEqual(@as(usize, 2), r.rest.len);
    try std.testing.expectEqualStrings("-a", r.rest[0]);
    try std.testing.expectEqualStrings("-b", r.rest[1]);
}

test "parseInto: -- is never reported as a leftover argument even with no positional or Rest field" {
    const a = std.testing.allocator;
    const Spec = struct { flag: spec.Flag(.{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "--flag", "--" }, src, null);
    try std.testing.expect(r.flag);
}

test "parseInto: with a Rest field, a required positional starved of a pre-- token errors even though post-- tokens exist" {
    const a = std.testing.allocator;
    const Spec = struct {
        p: spec.Pos([]const u8, .{}),
        rest: spec.Rest(.{}),
    };
    const src = Source{ .env_get = envNone, .config_get = null };

    // p may not dip past "--" to claim "a" - it stays unfilled, which is a
    // UsageError for a required positional, even though the Rest field
    // could easily have absorbed everything.
    var diag = Diagnostic{};
    const bad = parseInto(Spec, a, &.{ "--", "a" }, src, &diag);
    defer a.free(diag.message);
    try std.testing.expectError(error.UsageError, bad);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "missing required argument") != null);
}

test "parseInto: with a Rest field, a starved optional positional resolves to null and the variadic takes every post-- token; order-independent" {
    const src = Source{ .env_get = envNone, .config_get = null };

    // p declared before rest.
    {
        const a = std.testing.allocator;
        const Spec = struct {
            p: spec.Pos([]const u8, .{ .optional = true }),
            rest: spec.Rest(.{}),
        };
        const r = try parseInto(Spec, a, &.{ "--", "a", "b" }, src, null);
        defer a.free(r.rest);

        try std.testing.expectEqual(@as(?[]const u8, null), r.p);
        try std.testing.expectEqual(@as(usize, 2), r.rest.len);
        try std.testing.expectEqualStrings("a", r.rest[0]);
        try std.testing.expectEqualStrings("b", r.rest[1]);
    }

    // rest declared before p - same result, proving field-order independence.
    {
        const a = std.testing.allocator;
        const Spec = struct {
            rest: spec.Rest(.{}),
            p: spec.Pos([]const u8, .{ .optional = true }),
        };
        const r = try parseInto(Spec, a, &.{ "--", "a", "b" }, src, null);
        defer a.free(r.rest);

        try std.testing.expectEqual(@as(?[]const u8, null), r.p);
        try std.testing.expectEqual(@as(usize, 2), r.rest.len);
        try std.testing.expectEqualStrings("a", r.rest[0]);
        try std.testing.expectEqualStrings("b", r.rest[1]);
    }
}

test "parseInto: a pre-- positional and a post-- variadic do not overlap" {
    const a = std.testing.allocator;
    const Spec = struct {
        p: spec.Pos([]const u8, .{}),
        rest: spec.Rest(.{}),
    };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r = try parseInto(Spec, a, &.{ "x", "--", "a", "b" }, src, null);
    defer a.free(r.rest);

    try std.testing.expectEqualStrings("x", r.p);
    try std.testing.expectEqual(@as(usize, 2), r.rest.len);
    try std.testing.expectEqualStrings("a", r.rest[0]);
    try std.testing.expectEqualStrings("b", r.rest[1]);
}

const ClusterSpec = struct {
    a: spec.Flag(.{ .short = 'a' }),
    b: spec.Flag(.{ .short = 'b' }),
    o: spec.Opt([]const u8, .{ .short = 'o' }),
};
const cluster_src = Source{ .env_get = envNone, .config_get = null };

test "parseInto: a short-flag cluster sets each bool flag" {
    const a = std.testing.allocator;
    const r = try parseInto(ClusterSpec, a, &.{"-ab"}, cluster_src, null);
    try std.testing.expect(r.a);
    try std.testing.expect(r.b);
    try std.testing.expectEqual(@as(?[]const u8, null), r.o);
}

test "parseInto: a cluster's trailing value-option takes the next token" {
    const a = std.testing.allocator;
    const r = try parseInto(ClusterSpec, a, &.{ "-abo", "val" }, cluster_src, null);
    try std.testing.expect(r.a);
    try std.testing.expect(r.b);
    try std.testing.expectEqualStrings("val", r.o.?);
}

test "parseInto: a cluster's trailing value-option takes a glued value" {
    const a = std.testing.allocator;
    const r = try parseInto(ClusterSpec, a, &.{"-aoval"}, cluster_src, null);
    try std.testing.expect(r.a);
    try std.testing.expect(!r.b);
    try std.testing.expectEqualStrings("val", r.o.?);
}

test "parseInto: a clustered value-option greedily takes the token remainder" {
    const a = std.testing.allocator;
    // a,b are registered bool flags, yet -o still takes "ab" as its value:
    // the parse of -o<chars> does not depend on whether the following chars
    // are registered.
    const r = try parseInto(ClusterSpec, a, &.{"-oab"}, cluster_src, null);
    try std.testing.expect(!r.a);
    try std.testing.expect(!r.b);
    try std.testing.expectEqualStrings("ab", r.o.?);
}

test "parseInto: an unknown short char in a cluster is a UsageError" {
    const a = std.testing.allocator;
    const bad = parseInto(ClusterSpec, a, &.{"-ax"}, cluster_src, null);
    try std.testing.expectError(error.UsageError, bad);
}

test "parseInto: a single -a and a separate -o value still work" {
    const a = std.testing.allocator;
    const r = try parseInto(ClusterSpec, a, &.{ "-a", "-o", "val" }, cluster_src, null);
    try std.testing.expect(r.a);
    try std.testing.expect(!r.b);
    try std.testing.expectEqualStrings("val", r.o.?);
}

test "parseInto: a repeated bool flag, long or short, is idempotent" {
    const a = std.testing.allocator;
    const Spec = struct { verbose: spec.Flag(.{ .short = 'v' }) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r1 = try parseInto(Spec, a, &.{ "--verbose", "--verbose" }, src, null);
    try std.testing.expect(r1.verbose);

    const r2 = try parseInto(Spec, a, &.{ "-v", "-v" }, src, null);
    try std.testing.expect(r2.verbose);

    const r3 = try parseInto(Spec, a, &.{"-vv"}, src, null);
    try std.testing.expect(r3.verbose);
}

test "parseInto: a repeated option is last-wins, two-token and =value forms" {
    const a = std.testing.allocator;
    const Spec = struct { port: spec.Opt(u16, .{}) };
    const src = Source{ .env_get = envNone, .config_get = null };

    const r1 = try parseInto(Spec, a, &.{ "--port", "1", "--port", "2" }, src, null);
    try std.testing.expectEqual(@as(?u16, 2), r1.port);

    const r2 = try parseInto(Spec, a, &.{ "--port=1", "--port=2" }, src, null);
    try std.testing.expectEqual(@as(?u16, 2), r2.port);
}
