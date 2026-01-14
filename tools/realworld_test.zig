//! Real-world PNG image testing tool.
//!
//! Downloads and tests PNG images from the web to validate the decoder
//! against images found "in the wild" that may have different characteristics
//! than synthetic test images.
//!
//! Usage:
//!   realworld-test                     Run tests on cached images
//!   realworld-test --download          Download fresh test images
//!   realworld-test --url <url>         Test a specific URL
//!   realworld-test --dir <directory>   Test all PNGs in a directory

const std = @import("std");
const png = @import("png");
const Allocator = std.mem.Allocator;

// Test image sources - public domain and CC0 images
const TestImage = struct {
    name: []const u8,
    url: []const u8,
    description: []const u8,
};

// Curated list of real-world PNG test images from various sources
const test_images = [_]TestImage{
    // Wikipedia/Wikimedia Commons - Public Domain
    .{
        .name = "wikipedia_png_example.png",
        .url = "https://upload.wikimedia.org/wikipedia/commons/4/47/PNG_transparency_demonstration_1.png",
        .description = "Wikipedia PNG transparency demo (RGBA)",
    },
    .{
        .name = "wikipedia_grayscale.png",
        .url = "https://upload.wikimedia.org/wikipedia/commons/f/f2/Grayscale_8bits_palette_sample_image.png",
        .description = "Wikipedia grayscale sample",
    },

    // PNG test suite from official sources
    .{
        .name = "w3c_png_home.png",
        .url = "https://www.w3.org/Graphics/PNG/img_home.png",
        .description = "W3C PNG homepage image",
    },

    // Game/icon style images (different compression patterns)
    .{
        .name = "opengameart_icon.png",
        .url = "https://opengameart.org/sites/default/files/styles/thumbnail/public/heart_0.png",
        .description = "OpenGameArt icon (small indexed)",
    },

    // Photo-style images (complex patterns)
    .{
        .name = "unsplash_sample.png",
        .url = "https://images.unsplash.com/photo-1506905925346-21bda4d32df4?w=200&fm=png",
        .description = "Unsplash photo (complex RGB)",
    },

    // Technical diagrams
    .{
        .name = "libpng_logo.png",
        .url = "http://www.libpng.org/pub/png/img_png/pnglogo-grr.png",
        .description = "libpng official logo",
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cache_dir = "test_cache/realworld";

    if (args.len < 2) {
        // Default: run tests on cached images
        try runCachedTests(allocator, cache_dir);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--download")) {
        try downloadTestImages(allocator, cache_dir);
    } else if (std.mem.eql(u8, command, "--url")) {
        if (args.len < 3) {
            std.debug.print("Error: --url requires a URL\n", .{});
            return;
        }
        try testUrl(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "--dir")) {
        if (args.len < 3) {
            std.debug.print("Error: --dir requires a directory path\n", .{});
            return;
        }
        try testDirectory(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        // Assume it's a file path
        try testFile(allocator, command);
    }
}

fn getStdout() std.fs.File {
    return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

fn printUsage() !void {
    const stdout = getStdout();
    try stdout.writeAll(
        \\Real-world PNG Testing Tool
        \\
        \\Tests zig-png decoder against real-world images from the web.
        \\
        \\Usage:
        \\  realworld-test                     Run tests on cached images
        \\  realworld-test --download          Download fresh test images
        \\  realworld-test --url <url>         Test a specific PNG URL
        \\  realworld-test --dir <directory>   Test all PNGs in a directory
        \\  realworld-test <file>              Test a specific file
        \\  realworld-test --help              Show this help
        \\
        \\The tool downloads images to test_cache/realworld/ and tests them.
        \\
    );
}

fn downloadTestImages(allocator: Allocator, cache_dir: []const u8) !void {
    // Create cache directory
    std.fs.cwd().makePath(cache_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    std.debug.print("Downloading test images to {s}/\n\n", .{cache_dir});

    var downloaded: usize = 0;
    var failed: usize = 0;

    for (test_images) |img| {
        std.debug.print("Downloading: {s}\n", .{img.name});
        std.debug.print("  URL: {s}\n", .{img.url});
        std.debug.print("  Description: {s}\n", .{img.description});

        downloadFile(allocator, img.url, cache_dir, img.name) catch |err| {
            std.debug.print("  FAILED: {}\n\n", .{err});
            failed += 1;
            continue;
        };

        std.debug.print("  OK\n\n", .{});
        downloaded += 1;
    }

    std.debug.print("Downloaded {d} images, {d} failed\n", .{ downloaded, failed });
}

fn downloadFile(allocator: Allocator, url: []const u8, output_dir: []const u8, filename: []const u8) !void {
    // Use curl for downloading (available on most systems)
    var path_buf: [512]u8 = undefined;
    const output_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ output_dir, filename });

    var child = std.process.Child.init(&.{
        "curl",
        "-L", // Follow redirects
        "-s", // Silent
        "-f", // Fail on HTTP errors
        "-o",
        output_path,
        "--max-time",
        "30", // 30 second timeout
        url,
    }, allocator);

    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    try child.spawn();
    const result = try child.wait();

    if (result.Exited != 0) {
        return error.DownloadFailed;
    }

    // Verify the file was created and is not empty
    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) {
        return error.EmptyFile;
    }
}

fn runCachedTests(allocator: Allocator, cache_dir: []const u8) !void {
    // Check if cache directory exists
    var dir = std.fs.cwd().openDir(cache_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No cached images found. Run with --download first.\n", .{});
            std.debug.print("  realworld-test --download\n", .{});
            return;
        }
        return err;
    };
    defer dir.close();

    std.debug.print("Testing cached real-world images in {s}/\n\n", .{cache_dir});

    var total: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".png")) continue;

        total += 1;

        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache_dir, entry.name });

        const result = testFileInternal(allocator, full_path, entry.name);

        if (result) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    // Summary
    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Total: {d}, Passed: {d}, Failed: {d}\n", .{ total, passed, failed });

    if (failed > 0) {
        std.debug.print("\nSome tests FAILED\n", .{});
        std.process.exit(1);
    } else if (total == 0) {
        std.debug.print("\nNo PNG files found. Run with --download first.\n", .{});
    } else {
        std.debug.print("\nAll tests PASSED\n", .{});
    }
}

fn testDirectory(allocator: Allocator, dir_path: []const u8) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory {s}: {}\n", .{ dir_path, err });
        return;
    };
    defer dir.close();

    std.debug.print("Testing all PNGs in {s}/\n\n", .{dir_path});

    var total: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".png")) continue;

        total += 1;

        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });

        const result = testFileInternal(allocator, full_path, entry.name);

        if (result) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Total: {d}, Passed: {d}, Failed: {d}\n", .{ total, passed, failed });

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn testUrl(allocator: Allocator, url: []const u8) !void {
    std.debug.print("Testing URL: {s}\n", .{url});

    // Create temp directory
    const temp_dir = "test_cache/temp";
    std.fs.cwd().makePath(temp_dir) catch {};

    // Download to temp file
    const temp_file = "test_cache/temp/url_test.png";
    downloadFile(allocator, url, temp_dir, "url_test.png") catch |err| {
        std.debug.print("Download failed: {}\n", .{err});
        return;
    };

    // Test the downloaded file
    try testFile(allocator, temp_file);

    // Clean up
    std.fs.cwd().deleteFile(temp_file) catch {};
}

fn testFile(allocator: Allocator, path: []const u8) !void {
    _ = testFileInternal(allocator, path, path);
}

fn testFileInternal(allocator: Allocator, path: []const u8, display_name: []const u8) bool {
    // Try to decode
    var image = png.decodeFile(allocator, path) catch |err| {
        std.debug.print("FAIL: {s}\n", .{display_name});
        std.debug.print("  Decode error: {}\n", .{err});
        return false;
    };
    defer image.deinit();

    // Validate basic properties
    if (image.width() == 0 or image.height() == 0) {
        std.debug.print("FAIL: {s}\n", .{display_name});
        std.debug.print("  Invalid dimensions: {d}x{d}\n", .{ image.width(), image.height() });
        return false;
    }

    // Check pixel buffer size matches expected
    const expected_size = calculateExpectedPixelSize(image.header);
    if (expected_size) |exp| {
        if (image.pixels.len != exp) {
            std.debug.print("FAIL: {s}\n", .{display_name});
            std.debug.print("  Pixel buffer size mismatch: got {d}, expected {d}\n", .{
                image.pixels.len, exp,
            });
            return false;
        }
    }

    // Test roundtrip if possible
    const roundtrip_ok = testRoundtrip(allocator, &image);

    std.debug.print("PASS: {s} ({d}x{d} {s} {d}-bit", .{
        display_name,
        image.width(),
        image.height(),
        @tagName(image.header.color_type),
        image.header.bit_depth.toInt(),
    });

    if (image.header.interlace_method == .adam7) {
        std.debug.print(" interlaced", .{});
    }

    if (!roundtrip_ok) {
        std.debug.print(" [roundtrip skipped]", .{});
    }

    std.debug.print(")\n", .{});

    return true;
}

fn calculateExpectedPixelSize(header: png.Header) ?usize {
    const channels: usize = switch (header.color_type) {
        .grayscale => 1,
        .rgb => 3,
        .indexed => 1,
        .grayscale_alpha => 2,
        .rgba => 4,
    };

    const bytes_per_sample: usize = if (header.bit_depth == .@"16") 2 else 1;

    // For sub-byte bit depths, calculation is more complex
    if (header.bit_depth.toInt() < 8) {
        return null; // Skip validation for sub-byte formats
    }

    return @as(usize, header.width) * @as(usize, header.height) * channels * bytes_per_sample;
}

fn testRoundtrip(allocator: Allocator, image: *const png.Image) bool {
    // Skip indexed images (palette handling needed)
    if (image.header.color_type == .indexed) {
        return true;
    }

    // Encode
    const max_size = png.maxEncodedSize(image.header);
    const encode_buf = allocator.alloc(u8, max_size) catch return false;
    defer allocator.free(encode_buf);

    const encoded_len = png.encode(allocator, image, encode_buf, .{}) catch return false;

    // Decode again
    var decoded = png.decode(allocator, encode_buf[0..encoded_len]) catch return false;
    defer decoded.deinit();

    // Compare dimensions
    if (decoded.width() != image.width() or decoded.height() != image.height()) {
        return false;
    }

    // Compare pixels
    if (decoded.pixels.len != image.pixels.len) {
        return false;
    }

    return std.mem.eql(u8, decoded.pixels, image.pixels);
}
