const std = @import("std");

pub fn build(b: *std.Build) void {
    // Dependencies
    const hyperloglog_dep = b.dependency("hyperloglog", .{});
    const hyperloglog_mod = hyperloglog_dep.module("hyperloglog");

    const clap_dep = b.dependency("clap", .{});
    const clap_mod = clap_dep.module("clap");

    // Executable
    const exe_step = b.step("exe", "Run Loog server log analyzer");

    const exe = b.addExecutable(.{
        .name = "loog",
        .root_source_file = std.Build.LazyPath.relative("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    exe.root_module.addImport("hyperloglog", hyperloglog_mod);
    exe.root_module.addImport("clap", clap_mod);
    b.installArtifact(exe);

    const exe_run = b.addRunArtifact(exe);
    if (b.args) |args| {
        exe_run.addArgs(args);
    }

    exe_step.dependOn(&exe_run.step);
    b.default_step.dependOn(exe_step);

    // Lints
    const lints_step = b.step("lint", "Run lints");

    const lints = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });

    lints_step.dependOn(&lints.step);
    b.default_step.dependOn(lints_step);
}
