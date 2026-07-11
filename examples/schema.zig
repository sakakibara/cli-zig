//! Emitting the `__schema` JSON envelope: every registered command with its
//! derived flags, options, and positionals, for a caller that generates
//! docs or a wrapper script from the command table instead of parsing help
//! text.

const std = @import("std");
const cli = @import("cli");

const Group = enum { general };

fn loadContext(_: std.mem.Allocator, _: std.Io, _: *cli.args.Diagnostic) anyerror!void {}

const App = cli.cli.Cli(.{
    .Context = void,
    .Group = Group,
    .loadContext = loadContext,
});

const DeploySpec = struct {
    env: cli.spec.Opt([]const u8, .{ .help = "target environment", .complete = .{ .choices = &.{ "dev", "staging", "prod" } } }),
};

fn deployRun(_: *App.Ctx, _: cli.args.Args(DeploySpec)) anyerror!u8 {
    return 0;
}

fn statusRun(_: *App.Ctx) anyerror!u8 {
    return 0;
}

const deploy_cmd = App.command(DeploySpec, .{
    .name = "deploy",
    .summary = "deploy to an environment",
    .usage = "app deploy --env <env>",
    .group = .general,
}, deployRun);

const status_cmd = App.Command{
    .name = "status",
    .summary = "report health",
    .group = .general,
    .run = statusRun,
};

const commands = [_]App.Command{ deploy_cmd, status_cmd };

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    var err_buf: [256]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const argv: []const []const u8 = &.{ "app", "__schema" };
    const code = try App.run(gpa.allocator(), init.io, argv, &commands, &out.writer, &err_w);

    std.debug.print("$", .{});
    for (argv) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n{s}\nexit: {d}\n", .{ out.written(), code });
}
