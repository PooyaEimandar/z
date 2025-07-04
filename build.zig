const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "z",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zigcoro_mod = b.dependency("zigcoro", .{}).module("libcoro");
    exe.root_module.addImport("zigcoro", zigcoro_mod);

    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("uring");

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the HTTP server");
    run_step.dependOn(&b.addRunArtifact(exe).step);
}
