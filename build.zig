const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Define the library
    const lib = b.addStaticLibrary(.{
        .name = "pg",
        .root_source_file = b.path("src/zpg.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();

    // Install the library
    b.installArtifact(lib);

    // Expose the library as a module
    const zpg_module = b.addModule("zpg", .{
        .root_source_file = b.path("src/zpg.zig"),
    });

    // Create a test step
    const tests = b.addTest(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the `src` directory to the module search path
    tests.root_module.addImport("zpg", zpg_module);
    tests.linkLibC();
    // Add the test step to the default build step
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}
