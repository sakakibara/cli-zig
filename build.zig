const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("cli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // Generated reference docs (Zig stdlib pattern). Browse
    // `zig-out/docs/index.html` after `zig build docs`.
    const docs_obj = b.addObject(.{
        .name = "cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const docs_install = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API reference docs to zig-out/docs/");
    docs_step.dependOn(&docs_install.step);

    // Bounded argv fuzzer. Sidesteps the broken `zig test --fuzz` mode in
    // 0.16.0 and gives us a portable, scriptable harness.
    const fuzz_exe = b.addExecutable(.{
        .name = "cli-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "cli", .module = mod }},
        }),
    });
    b.installArtifact(fuzz_exe);
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |a| run_fuzz.addArgs(a);
    const fuzz_step = b.step("fuzz", "Run the bounded argv-parser fuzzer");
    fuzz_step.dependOn(&run_fuzz.step);

    // Runnable examples. `zig build example-NAME` runs each. They need
    // `std.process.Init` and a hosted I/O surface; skip them on freestanding
    // targets where those don't exist.
    if (target.result.os.tag != .freestanding and target.result.os.tag != .other) {
        const examples_step = b.step("examples", "Build all examples");
        inline for (.{ "basic", "subcommands", "completion", "schema" }) |name| {
            const exe = b.addExecutable(.{
                .name = "example-" ++ name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "cli", .module = mod }},
                }),
            });
            const install = b.addInstallArtifact(exe, .{});
            examples_step.dependOn(&install.step);

            const run = b.addRunArtifact(exe);
            const run_step = b.step("example-" ++ name, "Run the " ++ name ++ " example");
            run_step.dependOn(&run.step);
        }
    }
}
