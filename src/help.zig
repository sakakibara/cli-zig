//! Renders CLI help from a Command's derived metadata (`About` plus the
//! Spec-derived flags/args) - never a hand-written help string, so help can
//! never drift from what argv actually accepts.
const std = @import("std");

/// A renderer for one app's `Command`/`Flag`/`Arg`/`Group` shapes, generic
/// over whatever `App(cfg)` monomorphized them to.
pub fn Renderer(comptime Command: type, comptime Flag: type, comptime Arg: type, comptime Group: type, comptime Constraint: type) type {
    return struct {
        fn padTo(w: *std.Io.Writer, text: []const u8, width: usize) !void {
            try w.writeAll(text);
            if (text.len < width) try w.splatByteAll(' ', width - text.len);
        }

        /// Already-spelled flag names, comma-joined: how a constraint line
        /// names either side of a relation.
        fn writeJoined(w: *std.Io.Writer, names: []const []const u8) !void {
            for (names, 0..) |n, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(n);
            }
        }

        /// One relation, as a line under `Constraints:`. Names arrive already
        /// spelled as argv accepts them, so this only joins and phrases them.
        fn writeConstraint(w: *std.Io.Writer, c: Constraint) !void {
            try w.writeAll("  ");
            switch (c.kind) {
                .exclusive => {
                    try w.writeAll("at most one of ");
                    try writeJoined(w, c.subject);
                },
                .conflicts => {
                    try writeJoined(w, c.subject);
                    try w.writeAll(" cannot combine with ");
                    try writeJoined(w, c.others);
                },
                .requires_any => {
                    try writeJoined(w, c.subject);
                    try w.writeAll(" requires one of ");
                    try writeJoined(w, c.others);
                },
                .requires_all => {
                    try writeJoined(w, c.subject);
                    try w.writeAll(" requires ");
                    try writeJoined(w, c.others);
                },
            }
            if (c.why.len > 0) try w.print(" ({s})", .{c.why});
            try w.writeByte('\n');
        }

        /// Builds `<name> [--flags] <pos> [<opt>] [<rest...>]` from a
        /// command's derived flags/args, for a command whose `About.usage`
        /// was left empty - help never omits a synopsis. A command that has
        /// subcommands ends with `<command>`, so its synopsis reads as a
        /// group expecting a further subcommand name.
        pub fn synthesizeUsage(alloc: std.mem.Allocator, cmd: Command) ![]const u8 {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            try aw.writer.writeAll(cmd.name);
            if (cmd.flags.len > 0) try aw.writer.writeAll(" [--flags]");
            for (cmd.args) |a| {
                if (a.variadic) {
                    try aw.writer.print(" [<{s}...>]", .{a.name});
                } else if (a.optional) {
                    try aw.writer.print(" [<{s}>]", .{a.name});
                } else {
                    try aw.writer.print(" <{s}>", .{a.name});
                }
            }
            if (cmd.subcommands.len > 0) try aw.writer.writeAll(" <command>");
            return aw.toOwnedSlice();
        }

        /// The command's declared `usage`, or a synthesized one when empty.
        pub fn usageLine(alloc: std.mem.Allocator, cmd: Command) ![]const u8 {
            if (cmd.usage.len > 0) return cmd.usage;
            return synthesizeUsage(alloc, cmd);
        }

        /// Grouped command table: a heading per `Group` enum value (in
        /// declaration order) that has at least one matching command, each
        /// row `name  summary`. `group_heading`, when non-null, replaces the
        /// enum field name as the heading text; `footer`, when non-null,
        /// replaces the built-in "run --help"/"completion" trailer.
        pub fn renderTop(
            w: *std.Io.Writer,
            prog_name: []const u8,
            commands: []const Command,
            group_heading: ?*const fn (group: Group) []const u8,
            footer: ?*const fn (w: *std.Io.Writer, prog_name: []const u8) anyerror!void,
        ) !void {
            var width: usize = 0;
            for (commands) |c| width = @max(width, c.name.len);

            try w.print("Usage: {s} <command> [flags]\n", .{prog_name});

            inline for (@typeInfo(Group).@"enum".field_names) |fname| {
                const g = @field(Group, fname);
                var any = false;
                for (commands) |c| {
                    if (c.group == g) any = true;
                }
                if (any) {
                    const heading = if (group_heading) |gh| gh(g) else fname;
                    try w.print("\n{s}:\n", .{heading});
                    for (commands) |c| {
                        if (c.group != g) continue;
                        try w.writeAll("  ");
                        try padTo(w, c.name, width);
                        try w.writeAll("  ");
                        try w.writeAll(c.summary);
                        try w.writeByte('\n');
                    }
                }
            }

            if (footer) |f| {
                try f(w, prog_name);
            } else {
                try w.print("\nRun \"{s} <command> --help\" for details on a command.\n", .{prog_name});
                try w.print("Run \"{s} completion <shell>\" to enable shell tab-completion.\n", .{prog_name});
            }
        }

        fn flagSpelling(alloc: std.mem.Allocator, f: Flag) ![]const u8 {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            try aw.writer.print("--{s}", .{f.long});
            if (f.short) |s| try aw.writer.print(", -{c}", .{s});
            if (f.takes_value) try aw.writer.print(" <{s}>", .{f.value_name});
            return aw.toOwnedSlice();
        }

        fn argLabel(alloc: std.mem.Allocator, a: Arg) ![]const u8 {
            return std.fmt.allocPrint(alloc, "<{s}>", .{a.name});
        }

        /// Synopsis, then a Flags table (from `cmd.flags`) and an Args table
        /// (from `cmd.args`), then `cmd.details` prose - all derived from the
        /// single `Command` the Spec built.
        pub fn renderCommand(alloc: std.mem.Allocator, w: *std.Io.Writer, cmd: Command) !void {
            const usage = try usageLine(alloc, cmd);
            try w.print("Usage: {s}\n", .{usage});
            if (cmd.summary.len > 0) try w.print("\n{s}\n", .{cmd.summary});

            if (cmd.flags.len > 0) {
                var width: usize = 0;
                const spellings = try alloc.alloc([]const u8, cmd.flags.len);
                for (cmd.flags, spellings) |f, *s| {
                    s.* = try flagSpelling(alloc, f);
                    width = @max(width, s.*.len);
                }
                try w.writeAll("\nFlags:\n");
                for (cmd.flags, spellings) |f, s| {
                    try w.writeAll("  ");
                    try padTo(w, s, width);
                    if (f.help.len > 0) try w.print("  {s}", .{f.help});
                    try w.writeByte('\n');
                }
            }

            if (cmd.args.len > 0) {
                var width: usize = 0;
                const labels = try alloc.alloc([]const u8, cmd.args.len);
                for (cmd.args, labels) |a, *l| {
                    l.* = try argLabel(alloc, a);
                    width = @max(width, l.*.len);
                }
                try w.writeAll("\nArgs:\n");
                for (cmd.args, labels) |a, l| {
                    try w.writeAll("  ");
                    try padTo(w, l, width);
                    if (a.variadic) {
                        try w.writeAll("  (variadic)");
                    } else if (a.optional) {
                        try w.writeAll("  (optional)");
                    }
                    try w.writeByte('\n');
                }
            }

            // After the tables that say what exists, before the prose: what
            // the parser will refuse. A reader who has just seen two flags
            // listed side by side is the one who needs to know they cannot
            // be given together.
            if (cmd.constraints.len > 0) {
                try w.writeAll("\nConstraints:\n");
                for (cmd.constraints) |c| try writeConstraint(w, c);
            }

            if (cmd.subcommands.len > 0) {
                var width: usize = 0;
                for (cmd.subcommands) |s| width = @max(width, s.name.len);
                try w.writeAll("\nCommands:\n");
                for (cmd.subcommands) |s| {
                    try w.writeAll("  ");
                    try padTo(w, s.name, width);
                    if (s.summary.len > 0) try w.print("  {s}", .{s.summary});
                    try w.writeByte('\n');
                }
            }

            if (cmd.details.len > 0) try w.print("\n{s}\n", .{cmd.details});
        }
    };
}

const testing = std.testing;

const TestGroup = enum { general, system };

const TestFlag = struct {
    long: []const u8,
    short: ?u8 = null,
    help: []const u8 = "",
    takes_value: bool = false,
    value_name: []const u8 = "value",
};

const TestArg = struct {
    name: []const u8,
    optional: bool = false,
    variadic: bool = false,
};

const TestCommand = struct {
    name: []const u8,
    summary: []const u8 = "",
    usage: []const u8 = "",
    group: TestGroup = .general,
    details: []const u8 = "",
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

const TR = Renderer(TestCommand, TestFlag, TestArg, TestGroup, TestConstraint);

test "renderTop points the user at completion <shell> alongside <command> --help" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const commands = [_]TestCommand{.{ .name = "hello", .summary = "says hi" }};
    try TR.renderTop(&w, "app", &commands, null, null);
    const got = w.buffered();

    try testing.expect(std.mem.indexOf(u8, got, "\ngeneral:\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "app <command> --help") != null);
    try testing.expect(std.mem.indexOf(u8, got, "app completion <shell>") != null);
}

fn testGroupHeading(g: TestGroup) []const u8 {
    return switch (g) {
        .general => "general",
        .system => "System tools",
    };
}

test "renderTop uses a groupHeading hook's text instead of the bare enum field name" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const commands = [_]TestCommand{.{ .name = "reboot", .summary = "restarts", .group = .system }};
    try TR.renderTop(&w, "app", &commands, &testGroupHeading, null);
    const got = w.buffered();

    try testing.expect(std.mem.indexOf(u8, got, "System tools:") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\nsystem:\n") == null);
}

fn testHelpFooter(w: *std.Io.Writer, prog_name: []const u8) anyerror!void {
    _ = prog_name;
    try w.writeAll("see docs\n");
}

test "renderTop calls a renderHelpFooter hook instead of the built-in footer" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const commands = [_]TestCommand{.{ .name = "hello", .summary = "says hi" }};
    try TR.renderTop(&w, "app", &commands, null, &testHelpFooter);
    const got = w.buffered();

    try testing.expect(std.mem.endsWith(u8, got, "see docs\n"));
    try testing.expect(std.mem.indexOf(u8, got, "<command> --help") == null);
    try testing.expect(std.mem.indexOf(u8, got, "completion <shell>") == null);
}

test "renderCommand lists a command's subcommands under a Commands section, with a synthesized usage ending in <command>" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const cmd = TestCommand{
        .name = "remote",
        .subcommands = &.{
            .{ .name = "add", .summary = "add a remote" },
            .{ .name = "list", .summary = "list remotes" },
        },
    };
    try TR.renderCommand(arena_state.allocator(), &w, cmd);
    const got = w.buffered();

    try testing.expect(std.mem.startsWith(u8, got, "Usage: remote <command>\n"));
    try testing.expect(std.mem.indexOf(u8, got, "\nCommands:\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  add   add a remote\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  list  list remotes\n") != null);
}

test "renderCommand states every relation under Constraints, with the author's reason" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const cmd = TestCommand{
        .name = "add",
        .flags = &.{
            .{ .long = "recursive", .short = 'r' },
            .{ .long = "own", .takes_value = true, .value_name = "key-path" },
        },
        .constraints = &.{
            .{
                .kind = .conflicts,
                .subject = &.{"--recursive"},
                .others = &.{ "--own", "--own-absent" },
                .why = "a key path names one file",
            },
            .{
                .kind = .requires_any,
                .subject = &.{"--gate"},
                .others = &.{ "--own", "--own-absent" },
            },
            .{ .kind = .exclusive, .subject = &.{ "--json", "--porcelain" } },
        },
    };
    try TR.renderCommand(arena_state.allocator(), &w, cmd);
    const got = w.buffered();

    try testing.expect(std.mem.indexOf(u8, got,
        \\
        \\Constraints:
        \\  --recursive cannot combine with --own, --own-absent (a key path names one file)
        \\  --gate requires one of --own, --own-absent
        \\  at most one of --json, --porcelain
        \\
    ) != null);
}

test "renderCommand omits the Constraints section for a command that declares none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try TR.renderCommand(arena_state.allocator(), &w, TestCommand{ .name = "plain" });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Constraints:") == null);
}

test "renderCommand omits the Commands section for a leaf command with no subcommands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const cmd = TestCommand{ .name = "status", .summary = "show status" };
    try TR.renderCommand(arena_state.allocator(), &w, cmd);
    const got = w.buffered();

    try testing.expect(std.mem.indexOf(u8, got, "Commands:") == null);
    try testing.expect(std.mem.indexOf(u8, got, "<command>") == null);
}
