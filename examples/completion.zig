//! Shell-completion support: emitting an installable `completion <shell>`
//! script, and driving `__complete` for a dynamic option key resolved by a
//! `resolveCompletion` hook that filters against the word under the cursor.

const std = @import("std");
const cli = @import("cli");

const Group = enum { general };

fn loadContext(_: std.mem.Allocator, _: std.Io, _: *cli.args.Diagnostic) anyerror!void {}

const environments = [_][]const u8{ "dev", "staging", "prod" };

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

fn deployRun(ctx: *App.Ctx, a: cli.args.Args(DeploySpec)) anyerror!u8 {
    try ctx.out.print("deploying to {s}\n", .{a.env orelse "(unset)"});
    return 0;
}

const deploy_cmd = App.command(DeploySpec, .{
    .name = "deploy",
    .summary = "deploy to an environment",
    .usage = "app deploy --env <env>",
    .group = .general,
}, deployRun);

const commands = [_]App.Command{deploy_cmd};

fn printArgv(argv: []const []const u8) void {
    std.debug.print("$", .{});
    for (argv) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    {
        var out: std.Io.Writer.Allocating = .init(gpa.allocator());
        defer out.deinit();
        var err_buf: [256]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const argv = &.{ "app", "completion", "bash" };
        const code = try App.run(gpa.allocator(), init.io, argv, &commands, &out.writer, &err_w);

        printArgv(argv);
        std.debug.print("{s}\nexit: {d}\n\n", .{ out.written(), code });
    }

    {
        var out_buf: [256]u8 = undefined;
        var out_w = std.Io.Writer.fixed(&out_buf);
        var err_buf: [256]u8 = undefined;
        var err_w = std.Io.Writer.fixed(&err_buf);

        const argv = &.{ "app", "__complete", "deploy", "--env", "st" };
        const code = try App.run(gpa.allocator(), init.io, argv, &commands, &out_w, &err_w);

        printArgv(argv);
        std.debug.print("{s}exit: {d}\n\n", .{ out_w.buffered(), code });
    }
}
