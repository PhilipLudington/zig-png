//! PNG validation tool.
//!
//! Generates test PNG images and can decode/re-encode PNGs for validation
//! against external tools like pngcheck and ImageMagick.

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

    const command = args[1];

    if (std.mem.eql(u8, command, "generate")) {
        try generateTestImages(allocator, "test_output");
    } else if (std.mem.eql(u8, command, "decode")) {
        if (args.len < 3) {
            std.debug.print("Error: decode requires a file path\n", .{});
            return;
        }
        try decodeAndPrint(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "roundtrip")) {
        if (args.len < 4) {
            std.debug.print("Error: roundtrip requires input and output paths\n", .{});
            return;
        }
        try roundtrip(allocator, args[2], args[3]);
    } else if (std.mem.eql(u8, command, "dump-raw")) {
        if (args.len < 4) {
            std.debug.print("Error: dump-raw requires input PNG and output raw path\n", .{});
            return;
        }
        try dumpRaw(allocator, args[2], args[3]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
    }
}

fn getStdout() std.fs.File {
    return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

fn printUsage() !void {
    const stdout = getStdout();
    try stdout.writeAll(
        \\Usage: validate <command> [args...]
        \\
        \\Commands:
        \\  generate              Generate test PNG images in test_output/
        \\  decode <file>         Decode a PNG and print info
        \\  roundtrip <in> <out>  Decode a PNG and re-encode it
        \\  dump-raw <in> <out>   Decode PNG and dump raw pixels to file
        \\
    );
}

fn generateTestImages(allocator: Allocator, output_dir: []const u8) !void {
    // Create output directory
    std.fs.cwd().makeDir(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    std.debug.print("Generating test images...\n", .{});

    // Basic color types (8-bit)
    try generateGrayscale8(allocator, output_dir);
    try generateRgb8(allocator, output_dir);
    try generateRgba8(allocator, output_dir);
    try generateGrayscaleAlpha8(allocator, output_dir);

    // Pattern images
    try generateGradient(allocator, output_dir);
    try generateCheckerboard(allocator, output_dir);

    // Different bit depths
    try generateGrayscale16(allocator, output_dir);
    try generateRgb16(allocator, output_dir);
    try generateRgba16(allocator, output_dir);

    // Edge case sizes
    try generateTiny1x1(allocator, output_dir);
    try generateWide(allocator, output_dir);
    try generateTall(allocator, output_dir);
    try generateLarge(allocator, output_dir);

    // Interlaced images
    try generateInterlaced(allocator, output_dir);

    // Different compression levels
    try generateCompressionTest(allocator, output_dir);

    // Solid colors (good for compression edge cases)
    try generateSolidBlack(allocator, output_dir);
    try generateSolidWhite(allocator, output_dir);
    try generateSolidRed(allocator, output_dir);

    std.debug.print("Generated test images in {s}/\n", .{output_dir});
}

fn generateGrayscale8(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 16;
    const height: u32 = 16;

    // Create gradient pattern
    var pixels: [width * height]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            pixels[y * width + x] = @intCast((x * 16 + y * 16) % 256);
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [8192]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/grayscale_8bit.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateRgb8(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 16;
    const height: u32 = 16;

    // Create RGB pattern - red/green gradient
    var pixels: [width * height * 3]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 3;
            pixels[idx + 0] = @intCast(x * 16); // R
            pixels[idx + 1] = @intCast(y * 16); // G
            pixels[idx + 2] = 128; // B
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [16384]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/rgb_8bit.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateRgba8(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 16;
    const height: u32 = 16;

    // Create RGBA pattern with transparency gradient
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 4;
            pixels[idx + 0] = 255; // R
            pixels[idx + 1] = @intCast(x * 16); // G
            pixels[idx + 2] = @intCast(y * 16); // B
            pixels[idx + 3] = @intCast((x + y) * 8); // A - diagonal gradient
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .rgba,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [16384]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/rgba_8bit.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateGradient(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 256;
    const height: u32 = 64;

    // Full horizontal gradient
    var pixels: [width * height]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            pixels[y * width + x] = @intCast(x);
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [32768]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/gradient_256x64.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateCheckerboard(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 64;
    const height: u32 = 64;
    const tile_size: u32 = 8;

    // Checkerboard pattern in RGB
    var pixels: [width * height * 3]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 3;
            const tile_x = x / tile_size;
            const tile_y = y / tile_size;
            const is_white = (tile_x + tile_y) % 2 == 0;

            if (is_white) {
                pixels[idx + 0] = 255;
                pixels[idx + 1] = 255;
                pixels[idx + 2] = 255;
            } else {
                pixels[idx + 0] = 0;
                pixels[idx + 1] = 0;
                pixels[idx + 2] = 0;
            }
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [32768]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/checkerboard_64x64.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateGrayscaleAlpha8(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 16;
    const height: u32 = 16;

    // Grayscale with varying alpha
    var pixels: [width * height * 2]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 2;
            pixels[idx + 0] = @intCast(x * 16); // Gray value
            pixels[idx + 1] = @intCast(y * 16); // Alpha
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .grayscale_alpha,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [8192]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/grayscale_alpha_8bit.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateGrayscale16(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 16;
    const height: u32 = 16;

    // 16-bit grayscale gradient
    var pixels: [width * height * 2]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 2;
            const value: u16 = @intCast((x * 4096 + y * 4096) % 65536);
            // Big-endian
            pixels[idx + 0] = @intCast(value >> 8);
            pixels[idx + 1] = @intCast(value & 0xFF);
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"16",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [8192]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/grayscale_16bit.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateRgb16(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 16;
    const height: u32 = 16;

    // 16-bit RGB (6 bytes per pixel)
    var pixels: [width * height * 6]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 6;
            const r: u16 = @intCast(x * 4096);
            const g: u16 = @intCast(y * 4096);
            const b: u16 = 32768;
            // Big-endian for each channel
            pixels[idx + 0] = @intCast(r >> 8);
            pixels[idx + 1] = @intCast(r & 0xFF);
            pixels[idx + 2] = @intCast(g >> 8);
            pixels[idx + 3] = @intCast(g & 0xFF);
            pixels[idx + 4] = @intCast(b >> 8);
            pixels[idx + 5] = @intCast(b & 0xFF);
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"16",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [16384]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/rgb_16bit.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateRgba16(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 16;
    const height: u32 = 16;

    // 16-bit RGBA (8 bytes per pixel)
    var pixels: [width * height * 8]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 8;
            const r: u16 = 65535;
            const g: u16 = @intCast(x * 4096);
            const b: u16 = @intCast(y * 4096);
            const a: u16 = @intCast((x + y) * 2048);
            // Big-endian for each channel
            pixels[idx + 0] = @intCast(r >> 8);
            pixels[idx + 1] = @intCast(r & 0xFF);
            pixels[idx + 2] = @intCast(g >> 8);
            pixels[idx + 3] = @intCast(g & 0xFF);
            pixels[idx + 4] = @intCast(b >> 8);
            pixels[idx + 5] = @intCast(b & 0xFF);
            pixels[idx + 6] = @intCast(a >> 8);
            pixels[idx + 7] = @intCast(a & 0xFF);
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"16",
        .color_type = .rgba,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [16384]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/rgba_16bit.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateTiny1x1(allocator: Allocator, output_dir: []const u8) !void {
    // Smallest possible PNG - 1x1 RGB
    const pixels = [_]u8{ 255, 0, 0 }; // Red pixel

    const header = png.Header{
        .width = 1,
        .height = 1,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [1024]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/tiny_1x1.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateWide(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 512;
    const height: u32 = 8;

    // Wide horizontal gradient
    const pixels = try allocator.alloc(u8, width * height);
    defer allocator.free(pixels);

    for (0..height) |y| {
        for (0..width) |x| {
            pixels[y * width + x] = @intCast(x / 2);
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [16384]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/wide_512x8.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateTall(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 8;
    const height: u32 = 512;

    // Tall vertical gradient
    const pixels = try allocator.alloc(u8, width * height);
    defer allocator.free(pixels);

    for (0..height) |y| {
        for (0..width) |_| {
            pixels[y * width] = @intCast(y / 2);
        }
        // Fill rest of row
        for (1..width) |x| {
            pixels[y * width + x] = pixels[y * width];
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [16384]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/tall_8x512.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateLarge(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 256;
    const height: u32 = 256;

    // Large RGB image with complex pattern
    const pixels = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(pixels);

    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 3;
            // Create a colorful pattern
            pixels[idx + 0] = @intCast(x); // R
            pixels[idx + 1] = @intCast(y); // G
            pixels[idx + 2] = @intCast((x + y) / 2); // B
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    const output_buf = try allocator.alloc(u8, png.maxEncodedSize(header));
    defer allocator.free(output_buf);

    const len = try png.encodeRaw(allocator, header, pixels, null, output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/large_256x256.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateInterlaced(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 32;
    const height: u32 = 32;

    // RGB image with Adam7 interlacing
    var pixels: [width * height * 3]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 3;
            pixels[idx + 0] = @intCast(x * 8); // R
            pixels[idx + 1] = @intCast(y * 8); // G
            pixels[idx + 2] = 128; // B
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    var output_buf: [32768]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/interlaced_32x32.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateCompressionTest(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 64;
    const height: u32 = 64;

    // Same image data, different compression levels
    var pixels: [width * height]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            // Noisy pattern - harder to compress
            pixels[y * width + x] = @intCast(((x * 7) ^ (y * 13)) % 256);
        }
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    const levels = [_]struct { level: png.CompressionLevel, name: []const u8 }{
        .{ .level = .store, .name = "store" },
        .{ .level = .fastest, .name = "fastest" },
        .{ .level = .default, .name = "default" },
        .{ .level = .best, .name = "best" },
    };

    for (levels) |l| {
        var output_buf: [32768]u8 = undefined;
        const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{
            .compression_level = l.level,
        });

        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/compression_{s}.png", .{ output_dir, l.name });

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(output_buf[0..len]);

        std.debug.print("  Created {s} ({d} bytes)\n", .{ path, len });
    }
}

fn generateSolidBlack(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 64;
    const height: u32 = 64;

    // All black - should compress very well
    var pixels: [width * height * 3]u8 = undefined;
    @memset(&pixels, 0);

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [8192]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/solid_black.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateSolidWhite(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 64;
    const height: u32 = 64;

    // All white
    var pixels: [width * height * 3]u8 = undefined;
    @memset(&pixels, 255);

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [8192]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/solid_white.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn generateSolidRed(allocator: Allocator, output_dir: []const u8) !void {
    const width: u32 = 64;
    const height: u32 = 64;

    // All red
    var pixels: [width * height * 3]u8 = undefined;
    var i: usize = 0;
    while (i < pixels.len) : (i += 3) {
        pixels[i + 0] = 255; // R
        pixels[i + 1] = 0; // G
        pixels[i + 2] = 0; // B
    }

    const header = png.Header{
        .width = width,
        .height = height,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output_buf: [8192]u8 = undefined;
    const len = try png.encodeRaw(allocator, header, &pixels, null, &output_buf, .{});

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/solid_red.png", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("  Created {s}\n", .{path});
}

fn decodeAndPrint(allocator: Allocator, path: []const u8) !void {
    var image = try png.decodeFile(allocator, path);
    defer image.deinit();

    const stdout = getStdout();

    var buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf,
        \\PNG Image: {s}
        \\  Dimensions: {d}x{d}
        \\  Color type: {s}
        \\  Bit depth: {d}
        \\  Interlace: {s}
        \\  Pixel data size: {d} bytes
        \\
    , .{
        path,
        image.width(),
        image.height(),
        @tagName(image.header.color_type),
        image.header.bit_depth.toInt(),
        @tagName(image.header.interlace_method),
        image.pixels.len,
    });
    try stdout.writeAll(msg);
}

fn roundtrip(allocator: Allocator, input_path: []const u8, output_path: []const u8) !void {
    // Decode
    var image = try png.decodeFile(allocator, input_path);
    defer image.deinit();

    // Re-encode
    const max_size = png.maxEncodedSize(image.header);
    const output_buf = try allocator.alloc(u8, max_size);
    defer allocator.free(output_buf);

    const len = try png.encode(allocator, &image, output_buf, .{});

    // Write to file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(output_buf[0..len]);

    std.debug.print("Roundtrip complete: {s} -> {s} ({d} bytes)\n", .{ input_path, output_path, len });
}

fn dumpRaw(allocator: Allocator, input_path: []const u8, output_path: []const u8) !void {
    // Decode
    var image = try png.decodeFile(allocator, input_path);
    defer image.deinit();

    // Write raw pixels
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(image.pixels);

    std.debug.print("Dumped {d} raw bytes from {s} to {s}\n", .{ image.pixels.len, input_path, output_path });
}
