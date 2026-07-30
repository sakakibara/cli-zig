//! Emits a CLI's whole command table as a versioned JSON envelope -
//! `{"version","program","commands":[...]}`, one array entry per top-level
//! command, recursing into subcommands - for a consumer that never
//! re-parses help text (doc generation, agent-tool surfaces).
const std = @import("std");
const meta = @import("meta.zig");

/// The schema envelope's `version` field. Bumped whenever the emitted shape
/// changes in a way a consumer must branch on.
///
/// 2 added a `constraints` array to every command object (see
/// `writeConstraint`); it is always present, empty when a command declares no
/// relations, so a version-1 reader that ignores unknown keys still parses.
pub const schema_version = 2;

/// Writes `s` as a `"`-quoted JSON string, escaping per the JSON spec.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeBool(w: *std.Io.Writer, b: bool) !void {
    try w.writeAll(if (b) "true" else "false");
}

/// Serializes a `meta.Complete` as `{"kind":"none|files|choices|dynamic", ...}`.
fn writeComplete(w: *std.Io.Writer, c: meta.Complete) !void {
    switch (c) {
        .none => try w.writeAll("{\"kind\":\"none\"}"),
        .files => try w.writeAll("{\"kind\":\"files\"}"),
        .choices => |values| {
            try w.writeAll("{\"kind\":\"choices\",\"values\":[");
            for (values, 0..) |v, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonString(w, v);
            }
            try w.writeAll("]}");
        },
        .dynamic => |key| {
            try w.writeAll("{\"kind\":\"dynamic\",\"key\":");
            try writeJsonString(w, key);
            try w.writeAll("}");
        },
    }
}

/// A view over a caller's command table: `Emitter(Command, Flag, Arg,
/// Group)` reads only the fields listed in the module doc, mirroring how
/// `help.Renderer` and `complete.Completion` read the same generic shapes.
pub fn Emitter(comptime Command: type, comptime Flag: type, comptime Arg: type, comptime Group: type, comptime Constraint: type) type {
    // Group is part of the signature to mirror help.Renderer/complete.Completion,
    // even though @tagName below reads it off cmd.group's own type.
    _ = Group;
    return struct {
        fn writeFlag(w: *std.Io.Writer, f: Flag) !void {
            try w.writeAll("{\"long\":");
            try writeJsonString(w, f.long);
            try w.writeAll(",\"short\":");
            if (f.short) |s| {
                if (s >= 0x20 and s <= 0x7e) {
                    try writeJsonString(w, &[_]u8{s});
                } else {
                    try w.writeAll("null");
                }
            } else {
                try w.writeAll("null");
            }
            try w.writeAll(",\"help\":");
            try writeJsonString(w, f.help);
            try w.writeAll(",\"takes_value\":");
            try writeBool(w, f.takes_value);
            try w.writeAll(",\"value_name\":");
            try writeJsonString(w, f.value_name);
            try w.writeAll(",\"complete\":");
            try writeComplete(w, f.complete);
            try w.writeByte('}');
        }

        fn writeArg(w: *std.Io.Writer, a: Arg) !void {
            try w.writeAll("{\"name\":");
            try writeJsonString(w, a.name);
            try w.writeAll(",\"optional\":");
            try writeBool(w, a.optional);
            try w.writeAll(",\"variadic\":");
            try writeBool(w, a.variadic);
            try w.writeAll(",\"complete\":");
            try writeComplete(w, a.complete);
            try w.writeByte('}');
        }

        fn writeCommand(w: *std.Io.Writer, cmd: Command) !void {
            try w.writeAll("{\"name\":");
            try writeJsonString(w, cmd.name);
            try w.writeAll(",\"summary\":");
            try writeJsonString(w, cmd.summary);
            try w.writeAll(",\"usage\":");
            try writeJsonString(w, cmd.usage);
            try w.writeAll(",\"group\":");
            try writeJsonString(w, @tagName(cmd.group));
            try w.writeAll(",\"details\":");
            try writeJsonString(w, cmd.details);
            try w.writeAll(",\"needs_context\":");
            try writeBool(w, cmd.needs_context);

            try w.writeAll(",\"flags\":[");
            for (cmd.flags, 0..) |f, i| {
                if (i > 0) try w.writeByte(',');
                try writeFlag(w, f);
            }
            try w.writeByte(']');

            try w.writeAll(",\"args\":[");
            for (cmd.args, 0..) |a, i| {
                if (i > 0) try w.writeByte(',');
                try writeArg(w, a);
            }
            try w.writeByte(']');

            try w.writeAll(",\"constraints\":[");
            for (cmd.constraints, 0..) |c, i| {
                if (i > 0) try w.writeByte(',');
                try writeConstraint(w, c);
            }
            try w.writeByte(']');

            try w.writeAll(",\"subcommands\":[");
            for (cmd.subcommands, 0..) |sub, i| {
                if (i > 0) try w.writeByte(',');
                try writeCommand(w, sub);
            }
            try w.writeByte(']');

            try w.writeByte('}');
        }

        /// One relation among a command's flags. Emitted so a consumer that
        /// builds a call from this schema can honor a constraint the parser
        /// enforces, instead of discovering it from a rejected invocation.
        fn writeConstraint(w: *std.Io.Writer, c: Constraint) !void {
            try w.writeAll("{\"kind\":");
            try writeJsonString(w, @tagName(c.kind));
            try w.writeAll(",\"subject\":[");
            for (c.subject, 0..) |n, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonString(w, n);
            }
            try w.writeAll("],\"others\":[");
            for (c.others, 0..) |n, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonString(w, n);
            }
            try w.writeAll("],\"why\":");
            try writeJsonString(w, c.why);
            try w.writeByte('}');
        }

        /// Writes `table` as a JSON envelope object:
        /// `{"version":1,"program":"<prog_name>","commands":[...]}`.
        pub fn emit(w: *std.Io.Writer, prog_name: []const u8, table: []const Command) !void {
            try w.writeAll("{\"version\":");
            try w.print("{d}", .{schema_version});
            try w.writeAll(",\"program\":");
            try writeJsonString(w, prog_name);
            try w.writeAll(",\"commands\":[");
            for (table, 0..) |cmd, i| {
                if (i > 0) try w.writeByte(',');
                try writeCommand(w, cmd);
            }
            try w.writeAll("]}");
        }
    };
}

const testing = std.testing;

const TestGroup = enum { general, extra };

const TestFlag = struct {
    long: []const u8,
    short: ?u8 = null,
    help: []const u8 = "",
    takes_value: bool = false,
    value_name: []const u8 = "value",
    complete: meta.Complete = .none,
};

const TestArg = struct {
    name: []const u8,
    complete: meta.Complete = .none,
    optional: bool = false,
    variadic: bool = false,
};

const TestCommand = struct {
    name: []const u8,
    summary: []const u8 = "",
    usage: []const u8 = "",
    group: TestGroup = .general,
    details: []const u8 = "",
    needs_context: bool = false,
    flags: []const TestFlag = &.{},
    args: []const TestArg = &.{},
    subcommands: []const TestCommand = &.{},
    constraints: []const TestConstraint = &.{},
};

/// Mirrors `App(cfg).Constraint`, which the generic renderer/emitter never
/// see directly -- they take whatever shape the app monomorphized.
const TestConstraint = struct {
    kind: enum { exclusive, conflicts, requires_any, requires_all },
    subject: []const []const u8,
    others: []const []const u8 = &.{},
    why: []const u8 = "",
};

const TE = Emitter(TestCommand, TestFlag, TestArg, TestGroup, TestConstraint);

test "emit carries each constraint so a consumer honors it without a rejected call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());

    const cmd = TestCommand{
        .name = "add",
        .constraints = &.{.{
            .kind = .conflicts,
            .subject = &.{"--recursive"},
            .others = &.{"--own"},
            .why = "a key path names one file",
        }},
    };
    try TE.emit(&aw.writer, "app", &.{cmd});

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const constraints = parsed.value.object.get("commands").?.array.items[0]
        .object.get("constraints").?.array;
    try testing.expectEqual(@as(usize, 1), constraints.items.len);

    const c = constraints.items[0].object;
    try testing.expectEqualStrings("conflicts", c.get("kind").?.string);
    try testing.expectEqualStrings("--recursive", c.get("subject").?.array.items[0].string);
    try testing.expectEqualStrings("--own", c.get("others").?.array.items[0].string);
    try testing.expectEqualStrings("a key path names one file", c.get("why").?.string);
}

test "emit gives a constraint-free command an empty constraints array, never a missing key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());

    try TE.emit(&aw.writer, "app", &.{TestCommand{ .name = "plain" }});
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const c = parsed.value.object.get("commands").?.array.items[0].object.get("constraints").?;
    try testing.expectEqual(@as(usize, 0), c.array.items.len);
}

test "emit writes a JSON envelope containing a command's name and a flag's long name under commands" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const table = [_]TestCommand{.{
        .name = "greet",
        .group = .general,
        .flags = &.{.{ .long = "verbose", .short = 'v' }},
    }};

    try TE.emit(&w, "app", &table);
    const got = w.buffered();

    try testing.expect(std.mem.startsWith(u8, got, "{"));
    try testing.expect(std.mem.indexOf(u8, got, "\"version\":2") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"program\":\"app\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"commands\":[") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"name\":\"greet\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"long\":\"verbose\"") != null);
}

test "emit serializes a .choices completer as {\"kind\":\"choices\",\"values\":[...]}" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const table = [_]TestCommand{.{
        .name = "deploy",
        .args = &.{.{ .name = "env", .complete = .{ .choices = &.{ "dev", "prod" } } }},
    }};

    try TE.emit(&w, "app", &table);
    const got = w.buffered();

    try testing.expect(std.mem.indexOf(u8, got, "\"complete\":{\"kind\":\"choices\",\"values\":[\"dev\",\"prod\"]}") != null);
}

test "emit escapes a double quote in a summary" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const table = [_]TestCommand{.{
        .name = "greet",
        .summary = "he said \"hi\"",
    }};

    try TE.emit(&w, "app", &table);
    const got = w.buffered();

    try testing.expect(std.mem.indexOf(u8, got, "\"summary\":\"he said \\\"hi\\\"\"") != null);
}

test "emit writes null for a non-ASCII-printable short flag and stays valid JSON" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const table = [_]TestCommand{.{
        .name = "greet",
        .flags = &.{.{ .long = "weird", .short = 0xE9 }},
    }};

    try TE.emit(&w, "app", &table);
    const got = w.buffered();

    try testing.expect(std.mem.indexOf(u8, got, "\"short\":null") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
}

test "emit round-trips through std.json as a versioned envelope object, with a group tagName and a recursed subcommand" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const table = [_]TestCommand{.{
        .name = "org",
        .group = .extra,
        .needs_context = true,
        .subcommands = &.{.{ .name = "rename", .args = &.{.{ .name = "id", .variadic = true }} }},
    }};

    try TE.emit(&w, "app", &table);
    const got = w.buffered();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();

    const envelope = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), envelope.get("version").?.integer);
    try testing.expectEqualStrings("app", envelope.get("program").?.string);

    const arr = envelope.get("commands").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    const cmd = arr.items[0].object;
    try testing.expectEqualStrings("org", cmd.get("name").?.string);
    try testing.expectEqualStrings("extra", cmd.get("group").?.string);
    try testing.expectEqual(true, cmd.get("needs_context").?.bool);

    const subs = cmd.get("subcommands").?.array;
    try testing.expectEqual(@as(usize, 1), subs.items.len);
    const sub = subs.items[0].object;
    try testing.expectEqualStrings("rename", sub.get("name").?.string);
    const sub_args = sub.get("args").?.array;
    try testing.expectEqual(@as(usize, 1), sub_args.items.len);
    try testing.expectEqual(true, sub_args.items[0].object.get("variadic").?.bool);
}

test "emit recurses a 3-level subcommand tree, nesting the deepest command under its parent under the top-level command" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const table = [_]TestCommand{.{
        .name = "a",
        .subcommands = &.{.{
            .name = "b",
            .subcommands = &.{.{ .name = "c", .flags = &.{.{ .long = "cflag" }} }},
        }},
    }};

    try TE.emit(&w, "app", &table);
    const got = w.buffered();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();

    const a_cmd = parsed.value.object.get("commands").?.array.items[0].object;
    try testing.expectEqualStrings("a", a_cmd.get("name").?.string);

    const b_subs = a_cmd.get("subcommands").?.array;
    try testing.expectEqual(@as(usize, 1), b_subs.items.len);
    const b_cmd = b_subs.items[0].object;
    try testing.expectEqualStrings("b", b_cmd.get("name").?.string);

    const c_subs = b_cmd.get("subcommands").?.array;
    try testing.expectEqual(@as(usize, 1), c_subs.items.len);
    const c_cmd = c_subs.items[0].object;
    try testing.expectEqualStrings("c", c_cmd.get("name").?.string);
    try testing.expectEqualStrings("cflag", c_cmd.get("flags").?.array.items[0].object.get("long").?.string);
}
