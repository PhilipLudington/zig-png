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

    // PngSuite conformance test executable
    const pngsuite_exe = b.addExecutable(.{
        .name = "pngsuite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/pngsuite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "png", .module = png_mod },
            },
        }),
    });
    b.installArtifact(pngsuite_exe);

    const run_pngsuite = b.addRunArtifact(pngsuite_exe);
    run_pngsuite.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_pngsuite.addArgs(args);
    }

    const pngsuite_step = b.step("pngsuite", "Run PngSuite conformance tests");
    pngsuite_step.dependOn(&run_pngsuite.step);

    // Fuzz testing
    // To run fuzz tests: zig build fuzz --fuzz
    // Without --fuzz flag, runs the fuzz functions once as regular tests
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
    });

    const run_fuzz = b.addRunArtifact(fuzz_tests);

    const fuzz_step = b.step("fuzz", "Run fuzz tests (add --fuzz for continuous fuzzing)");
    fuzz_step.dependOn(&run_fuzz.step);

    // AFL++ harness for external fuzzing
    // Build with: zig build afl-harness
    // Run with: afl-fuzz -i fuzz_corpus -o fuzz_output -- ./zig-out/bin/afl-harness
    const afl_harness = b.addExecutable(.{
        .name = "afl-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/afl_harness.zig"),
            .target = target,
            .optimize = .ReleaseSafe, // ReleaseSafe for safety checks during fuzzing
            .imports = &.{
                .{ .name = "png", .module = png_mod },
            },
        }),
    });
    b.installArtifact(afl_harness);

    const afl_step = b.step("afl-harness", "Build AFL++ fuzz harness");
    afl_step.dependOn(&afl_harness.step);
}
