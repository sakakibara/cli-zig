//! A small CLI with a typed command (flags, an option, a positional) and two
//! plain commands, dispatched against top-level help and two sample argv.

const std = @import("std");
const cli = @import("cli");

const Group = enum { general };

fn loadContext(_: std.mem.Allocator, _: std.Io, _: *cli.args.Diagnostic) anyerror!void {}

const App = cli.cli.Cli(.{
    .Context = void,
    .Group = Group,
    .loadContext = loadContext,
});

const GreetSpec = struct {
    verbose: cli.spec.Flag(.{ .short = 'v', .help = "print an extra detail line" }),
    port: cli.spec.Opt(u16, .{ .short = 'p', .help = "port to greet on", .value_name = "PORT" }),
    name: cli.spec.Pos([]const u8, .{ .help = "who to greet" }),
};

fn greetRun(ctx: *App.Ctx, a: cli.args.Args(GreetSpec)) anyerror!u8 {
    try ctx.out.print("hello, {s}\n", .{a.name});
    if (a.verbose) {
        try ctx.out.print("  (port={d})\n", .{a.port orelse 0});
    }
    return 0;
}

fn statusRun(ctx: *App.Ctx) anyerror!u8 {
    try ctx.out.writeAll("all systems normal\n");
    return 0;
}

fn versionRun(ctx: *App.Ctx) anyerror!u8 {
    try ctx.out.writeAll("basic 1.0.0\n");
    return 0;
}

const greet_cmd = App.command(GreetSpec, .{
    .name = "greet",
    .summary = "say hello to someone",
    .usage = "basic greet [-v] [-p port] <name>",
    .group = .general,
}, greetRun);

const status_cmd = App.Command{
    .name = "status",
    .summary = "report health",
    .group = .general,
    .run = statusRun,
};

const version_cmd = App.Command{
    .name = "version",
    .group = .general,
    .run = versionRun,
};

const commands = [_]App.Command{ greet_cmd, status_cmd, version_cmd };

fn printArgv(argv: []const []const u8) void {
    std.debug.print("$", .{});
    for (argv) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const runs = [_][]const []const u8{
        &.{"basic"},
        &.{ "basic", "greet", "-v", "-p", "9090", "world" },
        &.{ "basic", "status" },
    };

    for (runs) |argv| {
        var out_buf: [512]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [256]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const code = try App.run(gpa.allocator(), init.io, argv, &commands, &out_w, &err_w);

        printArgv(argv);
        std.debug.print("{s}", .{out_w.buffered()});
        if (err_w.buffered().len > 0) std.debug.print("{s}", .{err_w.buffered()});
        std.debug.print("exit: {d}\n\n", .{code});
    }
}
