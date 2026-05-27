const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The binding, consumable as a dependency: `@import("circ_test")`.
    const circ_test_mod = b.addModule("circ_test", .{
        .root_source_file = b.path("src/circ_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The example tests need an absolute path to the shared circuits/ dir so
    // they run regardless of the invoking cwd.
    const options = b.addOptions();
    const circuits_dir = b.pathJoin(&.{ b.build_root.path orelse ".", "..", "circuits" });
    options.addOption([]const u8, "circuits_dir", circuits_dir);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/examples_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("circ_test", circ_test_mod);
    test_mod.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the circ-test example tests");
    test_step.dependOn(&run_tests.step);
}
