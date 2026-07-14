const std = @import("std");

pub fn build(build_system: *std.Build) void {
    const target = build_system.standardTargetOptions(.{});
    const optimize = build_system.standardOptimizeOption(.{});

    const zepoch = build_system.addModule("zepoch", .{
        .root_source_file = build_system.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const example = build_system.addExecutable(.{
        .name = "zepoch-example",
        .root_module = build_system.createModule(.{
            .root_source_file = build_system.path("examples/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zepoch", .module = zepoch }},
        }),
    });
    build_system.installArtifact(example);

    const run_example = build_system.addRunArtifact(example);
    run_example.step.dependOn(build_system.getInstallStep());
    run_example.addPassthruArgs();
    build_system.step("run", "Run the example").dependOn(&run_example.step);

    const library_tests = build_system.addTest(.{ .root_module = zepoch });
    const run_library_tests = build_system.addRunArtifact(library_tests);
    build_system.step("test", "Run all library tests").dependOn(
        &run_library_tests.step,
    );
}
