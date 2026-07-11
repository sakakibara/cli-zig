//! A parent command with two subcommands, one of which (`list`) itself
//! carries a further subcommand (`verbose`) - subcommands nest to arbitrary
//! depth, not just one level - plus the flag-shape bypass: a flag-shaped or
//! unmatched token after a command's name is handled by that command's own
//! run instead of erroring.

const std = @import("std");
const cli = @import("cli");

const Group = enum { general };

fn loadContext(_: std.mem.Allocator, _: std.Io, _: *cli.args.Diagnostic) anyerror!void {}

const App = cli.cli.Cli(.{
    .Context = void,
    .Group = Group,
    .loadContext = loadContext,
});

const RemoteSpec = struct {
    verbose: cli.spec.Flag(.{ .short = 'v', .help = "list remotes with their URLs" }),
};

fn remoteRun(ctx: *App.Ctx, a: cli.args.Args(RemoteSpec)) anyerror!u8 {
    try ctx.out.print("remote (no subcommand given, verbose={})\n", .{a.verbose});
    return 0;
}

const AddSpec = struct {
    name: cli.spec.Pos([]const u8, .{ .help = "remote name" }),
    url: cli.spec.Opt([]const u8, .{ .help = "remote URL", .value_name = "URL" }),
};

fn addRun(ctx: *App.Ctx, a: cli.args.Args(AddSpec)) anyerror!u8 {
    try ctx.out.print("added {s} -> {s}\n", .{ a.name, a.url orelse "(no url)" });
    return 0;
}

fn listRun(ctx: *App.Ctx) anyerror!u8 {
    try ctx.out.writeAll("origin\nupstream\n");
    return 0;
}

fn listVerboseRun(ctx: *App.Ctx) anyerror!u8 {
    try ctx.out.writeAll("origin\thttps://example.com/repo.git\nupstream\thttps://example.com/upstream.git\n");
    return 0;
}

const add_cmd = App.command(AddSpec, .{
    .name = "add",
    .summary = "add a remote",
    .usage = "remote add <name> --url <url>",
    .group = .general,
}, addRun);

const list_verbose_cmd = App.Command{
    .name = "verbose",
    .summary = "list remotes with their URLs",
    .group = .general,
    .run = listVerboseRun,
};

const list_cmd = App.Command{
    .name = "list",
    .summary = "list remotes",
    .group = .general,
    .run = listRun,
    .subcommands = &.{list_verbose_cmd},
};

const subcommands = [_]App.Command{ add_cmd, list_cmd };

var remote_cmd = App.command(RemoteSpec, .{
    .name = "remote",
    .summary = "manage remotes",
    .usage = "remote [-v] <add|list>",
    .group = .general,
}, remoteRun);

fn printArgv(argv: []const []const u8) void {
    std.debug.print("$", .{});
    for (argv) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    remote_cmd.subcommands = &subcommands;
    const commands = [_]App.Command{remote_cmd};

    const runs = [_][]const []const u8{
        &.{ "app", "remote", "add", "origin", "--url", "https://example.com/repo.git" },
        &.{ "app", "remote", "list" },
        &.{ "app", "remote", "list", "verbose" },
        &.{ "app", "remote", "-v" },
    };

    for (runs) |argv| {
        var out_buf: [256]u8 = undefined;
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
