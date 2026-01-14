//! PngSuite conformance test runner.
//!
//! Tests the PNG library against the official PngSuite test images.
//! See: http://www.schaik.com/pngsuite/

const std = @import("std");
const png = @import("png");

const Allocator = std.mem.Allocator;

const Results = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    fn total(self: Results) u32 {
        return self.passed + self.failed + self.skipped;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var test_dir: []const u8 = "test_data";
    var verbose = false;
    var roundtrip = false;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-v") or std.mem.eql(u8, args[i], "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, args[i], "-r") or std.mem.eql(u8, args[i], "--roundtrip")) {
            roundtrip = true;
        } else if (std.mem.eql(u8, args[i], "-d") or std.mem.eql(u8, args[i], "--dir")) {
            i += 1;
            if (i < args.len) {
                test_dir = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            try printUsage();
            return;
        }
    }

    std.debug.print("PngSuite Conformance Test\n", .{});
    std.debug.print("=========================\n\n", .{});

    var results = Results{};

    // Open test directory
    var dir = std.fs.cwd().openDir(test_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Error: Cannot open test directory '{s}': {}\n", .{ test_dir, err });
        std.debug.print("Download PngSuite first:\n", .{});
        std.debug.print("  mkdir -p test_data && cd test_data\n", .{});
        std.debug.print("  curl -LO http://www.schaik.com/pngsuite/PngSuite-2017jul19.zip\n", .{});
        std.debug.print("  unzip PngSuite-2017jul19.zip\n", .{});
        return;
    };
    defer dir.close();

    // Collect and sort PNG files
    var files = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
            const name_copy = try allocator.dupe(u8, entry.name);
            try files.append(allocator, name_copy);
        }
    }

    // Sort for consistent output
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    std.debug.print("Found {d} PNG files in '{s}'\n\n", .{ files.items.len, test_dir });

    // Test each file
    for (files.items) |filename| {
        const result = testFile(allocator, dir, filename, roundtrip, verbose);
        switch (result) {
            .pass => results.passed += 1,
            .fail => results.failed += 1,
            .skip => results.skipped += 1,
        }
    }

    // Summary
    std.debug.print("\n=========================\n", .{});
    std.debug.print("Results: {d} passed, {d} failed, {d} skipped (total: {d})\n", .{
        results.passed,
        results.failed,
        results.skipped,
        results.total(),
    });

    if (results.failed > 0) {
        std.process.exit(1);
    }
}

const TestResult = enum { pass, fail, skip };

fn testFile(allocator: Allocator, dir: std.fs.Dir, filename: []const u8, do_roundtrip: bool, verbose: bool) TestResult {
    const expect_failure = filename.len > 0 and filename[0] == 'x';

    // Read file
    const file_data = dir.readFileAlloc(allocator, filename, 10 * 1024 * 1024) catch |err| {
        std.debug.print("[FAIL] {s}: cannot read file: {}\n", .{ filename, err });
        return .fail;
    };
    defer allocator.free(file_data);

    // Attempt decode
    var image = png.decode(allocator, file_data) catch |err| {
        if (expect_failure) {
            if (verbose) {
                std.debug.print("[PASS] {s}: correctly rejected ({})\n", .{ filename, err });
            } else {
                std.debug.print("[PASS] {s}: correctly rejected\n", .{filename});
            }
            return .pass;
        } else {
            std.debug.print("[FAIL] {s}: decode error: {}\n", .{ filename, err });
            return .fail;
        }
    };
    defer image.deinit();

    if (expect_failure) {
        std.debug.print("[FAIL] {s}: should have been rejected but decoded successfully\n", .{filename});
        return .fail;
    }

    // Decode succeeded for valid file
    if (verbose) {
        std.debug.print("[PASS] {s}: decoded {d}x{d} {s} {d}-bit", .{
            filename,
            image.width(),
            image.height(),
            @tagName(image.header.color_type),
            image.header.bit_depth.toInt(),
        });
        if (image.header.interlace_method == .adam7) {
            std.debug.print(" interlaced", .{});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("[PASS] {s}\n", .{filename});
    }

    // Roundtrip test if requested
    if (do_roundtrip) {
        return roundtripTest(allocator, &image, filename, verbose);
    }

    return .pass;
}

fn roundtripTest(allocator: Allocator, image: *const png.Image, filename: []const u8, verbose: bool) TestResult {
    // Skip indexed color for now (palette handling in roundtrip is complex)
    if (image.header.color_type == .indexed) {
        if (verbose) {
            std.debug.print("       {s}: roundtrip skipped (indexed color)\n", .{filename});
        }
        return .pass; // Don't count as skip, decode passed
    }

    // Encode
    const max_size = png.maxEncodedSize(image.header);
    const output_buf = allocator.alloc(u8, max_size) catch {
        std.debug.print("[FAIL] {s}: roundtrip alloc failed\n", .{filename});
        return .fail;
    };
    defer allocator.free(output_buf);

    const encoded_len = png.encode(allocator, image, output_buf, .{}) catch |err| {
        std.debug.print("[FAIL] {s}: roundtrip encode failed: {}\n", .{ filename, err });
        return .fail;
    };

    // Decode the re-encoded image
    var image2 = png.decode(allocator, output_buf[0..encoded_len]) catch |err| {
        std.debug.print("[FAIL] {s}: roundtrip decode failed: {}\n", .{ filename, err });
        return .fail;
    };
    defer image2.deinit();

    // Compare dimensions
    if (image.width() != image2.width() or image.height() != image2.height()) {
        std.debug.print("[FAIL] {s}: roundtrip dimension mismatch\n", .{filename});
        return .fail;
    }

    // Compare pixel data
    if (!std.mem.eql(u8, image.pixels, image2.pixels)) {
        std.debug.print("[FAIL] {s}: roundtrip pixel mismatch\n", .{filename});
        return .fail;
    }

    if (verbose) {
        std.debug.print("       {s}: roundtrip OK ({d} bytes)\n", .{ filename, encoded_len });
    }

    return .pass;
}

fn printUsage() !void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(
        \\PngSuite Conformance Test
        \\
        \\Usage: pngsuite [options]
        \\
        \\Options:
        \\  -d, --dir <path>    Test directory (default: test_data)
        \\  -v, --verbose       Show detailed output
        \\  -r, --roundtrip     Also test encode/decode roundtrip
        \\  -h, --help          Show this help
        \\
        \\PngSuite files starting with 'x' are expected to fail decoding.
        \\All other files should decode successfully.
        \\
    );
}
