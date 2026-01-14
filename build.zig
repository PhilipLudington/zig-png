const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module - for use as a dependency
    _ = b.addModule("png", .{
        .root_source_file = b.path("src/png.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library artifact (for C interop or linking)
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "png",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/png.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // Unit tests (Zig 0.15+: use root_module)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/png.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Validation tool executable
    const png_mod = b.createModule(.{
        .root_source_file = b.path("src/png.zig"),
        .target = target,
        .optimize = optimize,
    });

    const validate_exe = b.addExecutable(.{
        .name = "validate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/validate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "png", .module = png_mod },
            },
        }),
    });
    b.installArtifact(validate_exe);

    const run_validate = b.addRunArtifact(validate_exe);
    run_validate.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_validate.addArgs(args);
    }

    const validate_step = b.step("validate", "Run PNG validation tool");
    validate_step.dependOn(&run_validate.step);
}
