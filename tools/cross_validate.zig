//! Cross-validation tool comparing zig-png against reference implementations.
//!
//! Decodes PNG files using both zig-png and a reference decoder (ImageMagick),
//! then compares the raw pixel output to ensure correctness.
//!
//! Usage:
//!   cross-validate <file.png>           Validate single file
//!   cross-validate --dir <directory>    Validate all PNGs in directory
//!   cross-validate --corpus             Validate fuzz corpus and test_data

const std = @import("std");
const png = @import("png");
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    // Check for reference decoder availability
    const ref_decoder = try detectReferenceDecoder(allocator);
    if (ref_decoder == null) {
        std.debug.print("Error: No reference decoder found.\n", .{});
        std.debug.print("Please install one of:\n", .{});
        std.debug.print("  - ImageMagick (convert command)\n", .{});
        std.debug.print("  - NetPBM (pngtopam command)\n", .{});
        std.debug.print("  - libpng (pngtopnm command)\n", .{});
        return;
    }
    std.debug.print("Using reference decoder: {s}\n\n", .{@tagName(ref_decoder.?)});

    const command = args[1];

    if (std.mem.eql(u8, command, "--dir")) {
        if (args.len < 3) {
            std.debug.print("Error: --dir requires a directory path\n", .{});
            return;
        }
        try validateDirectory(allocator, ref_decoder.?, args[2]);
    } else if (std.mem.eql(u8, command, "--corpus")) {
        try validateCorpus(allocator, ref_decoder.?);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        // Single file validation
        _ = try validateFile(allocator, ref_decoder.?, command, true);
    }
}

const ReferenceDecoder = enum {
    imagemagick,
    netpbm,
    libpng_pngtopnm,
};

fn detectReferenceDecoder(allocator: Allocator) !?ReferenceDecoder {
    // Try ImageMagick first (most common)
    if (try commandExists(allocator, &.{ "convert", "--version" })) {
        return .imagemagick;
    }
    // Try NetPBM
    if (try commandExists(allocator, &.{ "pngtopam", "--version" })) {
        return .netpbm;
    }
    // Try libpng's pngtopnm
    if (try commandExists(allocator, &.{"pngtopnm"})) {
        return .libpng_pngtopnm;
    }
    return null;
}

fn commandExists(allocator: Allocator, argv: []const []const u8) !bool {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    _ = child.spawnAndWait() catch return false;
    return true;
}

fn getStdout() std.fs.File {
    return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

fn printUsage() !void {
    const stdout = getStdout();
    try stdout.writeAll(
        \\Cross-validation tool for zig-png
        \\
        \\Compares zig-png decoder output against reference implementations
        \\(ImageMagick, NetPBM, or libpng) to ensure correctness.
        \\
        \\Usage:
        \\  cross-validate <file.png>           Validate single PNG file
        \\  cross-validate --dir <directory>    Validate all PNGs in directory
        \\  cross-validate --corpus             Validate fuzz_corpus/ and test_data/
        \\  cross-validate --help               Show this help
        \\
        \\Requirements:
        \\  One of: ImageMagick (convert), NetPBM (pngtopam), or libpng (pngtopnm)
        \\
    );
}

fn validateCorpus(allocator: Allocator, decoder: ReferenceDecoder) !void {
    var total: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    // Validate test_data directory
    std.debug.print("=== Validating test_data/ ===\n", .{});
    const test_data_result = try validateDirectoryWithStats(allocator, decoder, "test_data");
    total += test_data_result.total;
    passed += test_data_result.passed;
    failed += test_data_result.failed;
    skipped += test_data_result.skipped;

    // Validate fuzz_corpus directory
    std.debug.print("\n=== Validating fuzz_corpus/ ===\n", .{});
    const fuzz_result = try validateDirectoryWithStats(allocator, decoder, "fuzz_corpus");
    total += fuzz_result.total;
    passed += fuzz_result.passed;
    failed += fuzz_result.failed;
    skipped += fuzz_result.skipped;

    // Summary
    std.debug.print("\n=== SUMMARY ===\n", .{});
    std.debug.print("Total: {d}, Passed: {d}, Failed: {d}, Skipped: {d}\n", .{
        total, passed, failed, skipped,
    });

    if (failed > 0) {
        std.debug.print("\nValidation FAILED - {d} files have mismatched output\n", .{failed});
        std.process.exit(1);
    } else {
        std.debug.print("\nValidation PASSED\n", .{});
    }
}

const ValidationStats = struct {
    total: usize,
    passed: usize,
    failed: usize,
    skipped: usize,
};

fn validateDirectory(allocator: Allocator, decoder: ReferenceDecoder, dir_path: []const u8) !void {
    const stats = try validateDirectoryWithStats(allocator, decoder, dir_path);

    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("Total: {d}, Passed: {d}, Failed: {d}, Skipped: {d}\n", .{
        stats.total, stats.passed, stats.failed, stats.skipped,
    });

    if (stats.failed > 0) {
        std.process.exit(1);
    }
}

fn validateDirectoryWithStats(allocator: Allocator, decoder: ReferenceDecoder, dir_path: []const u8) !ValidationStats {
    var stats = ValidationStats{ .total = 0, .passed = 0, .failed = 0, .skipped = 0 };

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory {s}: {}\n", .{ dir_path, err });
        return stats;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        // Only process .png files
        if (!std.mem.endsWith(u8, entry.name, ".png")) continue;

        stats.total += 1;

        // Skip known invalid test files (PngSuite 'x' prefix = expected to fail)
        if (entry.name[0] == 'x') {
            stats.skipped += 1;
            continue;
        }

        // Build full path
        var path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        const result = validateFile(allocator, decoder, full_path, false) catch |err| {
            std.debug.print("FAIL: {s} - error: {}\n", .{ entry.name, err });
            stats.failed += 1;
            continue;
        };

        if (result) {
            stats.passed += 1;
        } else {
            stats.failed += 1;
        }
    }

    return stats;
}

fn validateFile(allocator: Allocator, decoder: ReferenceDecoder, path: []const u8, verbose: bool) !bool {
    // Decode with zig-png
    var zig_image = png.decodeFile(allocator, path) catch |err| {
        if (verbose) {
            std.debug.print("zig-png decode failed: {}\n", .{err});
        }
        return err;
    };
    defer zig_image.deinit();

    // Get reference decoder output
    const ref_pixels = try decodeWithReference(allocator, decoder, path, zig_image.header) orelse {
        if (verbose) {
            std.debug.print("Reference decoder failed or unsupported format\n", .{});
        }
        return error.ReferenceDecoderFailed;
    };
    defer allocator.free(ref_pixels);

    // Compare pixel data
    if (zig_image.pixels.len != ref_pixels.len) {
        if (verbose) {
            std.debug.print("FAIL: {s}\n", .{path});
            std.debug.print("  Size mismatch: zig-png={d}, reference={d}\n", .{
                zig_image.pixels.len, ref_pixels.len,
            });
        } else {
            std.debug.print("FAIL: {s} (size mismatch: {d} vs {d})\n", .{
                path, zig_image.pixels.len, ref_pixels.len,
            });
        }
        return false;
    }

    // Compare actual bytes
    var diff_count: usize = 0;
    var first_diff: ?usize = null;
    for (zig_image.pixels, ref_pixels, 0..) |z, r, i| {
        if (z != r) {
            diff_count += 1;
            if (first_diff == null) first_diff = i;
        }
    }

    if (diff_count > 0) {
        if (verbose) {
            std.debug.print("FAIL: {s}\n", .{path});
            std.debug.print("  {d} differing bytes, first diff at offset {d}\n", .{
                diff_count, first_diff.?,
            });
            // Show first few differences
            var shown: usize = 0;
            for (zig_image.pixels, ref_pixels, 0..) |z, r, i| {
                if (z != r and shown < 5) {
                    std.debug.print("    [{d}]: zig=0x{x:0>2}, ref=0x{x:0>2}\n", .{ i, z, r });
                    shown += 1;
                }
            }
        } else {
            std.debug.print("FAIL: {s} ({d} bytes differ)\n", .{ path, diff_count });
        }
        return false;
    }

    if (verbose) {
        std.debug.print("PASS: {s} ({d}x{d}, {d} bytes match)\n", .{
            path,
            zig_image.width(),
            zig_image.height(),
            zig_image.pixels.len,
        });
    } else {
        std.debug.print("PASS: {s}\n", .{path});
    }

    return true;
}

fn decodeWithReference(
    allocator: Allocator,
    decoder: ReferenceDecoder,
    path: []const u8,
    header: png.Header,
) !?[]u8 {
    return switch (decoder) {
        .imagemagick => try decodeWithImageMagick(allocator, path, header),
        .netpbm => try decodeWithNetPBM(allocator, path, header),
        .libpng_pngtopnm => try decodeWithPngtopnm(allocator, path, header),
    };
}

fn decodeWithImageMagick(allocator: Allocator, path: []const u8, header: png.Header) !?[]u8 {
    // Use ImageMagick to convert PNG to raw RGB/RGBA/Gray data
    // Format: convert input.png -depth 8 RGB:- (or RGBA:-, GRAY:-, etc.)

    const format = switch (header.color_type) {
        .grayscale => "GRAY",
        .rgb => "RGB",
        .indexed => "RGB", // ImageMagick expands palette
        .grayscale_alpha => "GRAYA",
        .rgba => "RGBA",
    };

    // For 16-bit images, we need -depth 16
    const depth_str = if (header.bit_depth == .@"16") "16" else "8";

    // Build output format string (e.g., "RGB:-")
    var format_buf: [32]u8 = undefined;
    const format_spec = std.fmt.bufPrint(&format_buf, "{s}:-", .{format}) catch return null;

    var child = std.process.Child.init(&.{
        "convert",
        path,
        "-depth",
        depth_str,
        format_spec,
    }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Read all stdout
    const stdout = child.stdout.?;
    const raw_pixels = try stdout.readToEndAlloc(allocator, 100 * 1024 * 1024);
    errdefer allocator.free(raw_pixels);

    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(raw_pixels);
        return null;
    }

    // For indexed images, ImageMagick outputs RGB, but zig-png outputs palette indices
    // We need to handle this case specially
    if (header.color_type == .indexed) {
        // Skip comparison for indexed images - format mismatch is expected
        allocator.free(raw_pixels);
        return null;
    }

    return raw_pixels;
}

fn decodeWithNetPBM(allocator: Allocator, path: []const u8, header: png.Header) !?[]u8 {
    // NetPBM's pngtopam converts to PAM format which has a header
    // We need to strip the header and get raw pixel data

    var child = std.process.Child.init(&.{ "pngtopam", path }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = child.stdout.?;
    const pam_data = try stdout.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(pam_data);

    const result = try child.wait();
    if (result.Exited != 0) {
        return null;
    }

    // Parse PAM header to find where pixel data starts
    // PAM header ends with "ENDHDR\n"
    const header_end = std.mem.indexOf(u8, pam_data, "ENDHDR\n") orelse return null;
    const pixel_start = header_end + 7;

    if (pixel_start >= pam_data.len) return null;

    // Copy pixel data
    const pixels = try allocator.dupe(u8, pam_data[pixel_start..]);

    // Handle indexed images
    if (header.color_type == .indexed) {
        allocator.free(pixels);
        return null;
    }

    return pixels;
}

fn decodeWithPngtopnm(allocator: Allocator, path: []const u8, header: png.Header) !?[]u8 {
    // Similar to NetPBM but uses libpng's pngtopnm
    var child = std.process.Child.init(&.{ "pngtopnm", "-raw", path }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = child.stdout.?;
    const pnm_data = try stdout.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(pnm_data);

    const result = try child.wait();
    if (result.Exited != 0) {
        return null;
    }

    // PNM format: "P5/P6\n<width> <height>\n<maxval>\n<data>"
    // Find the third newline to locate pixel data
    var newline_count: usize = 0;
    var pixel_start: usize = 0;
    for (pnm_data, 0..) |c, i| {
        if (c == '\n') {
            newline_count += 1;
            if (newline_count == 3) {
                pixel_start = i + 1;
                break;
            }
        }
    }

    if (pixel_start == 0 or pixel_start >= pnm_data.len) return null;

    const pixels = try allocator.dupe(u8, pnm_data[pixel_start..]);

    // Handle indexed images
    if (header.color_type == .indexed) {
        allocator.free(pixels);
        return null;
    }

    return pixels;
}
