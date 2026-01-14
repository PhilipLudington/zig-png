//! Zig PNG Library
//!
//! A pure Zig implementation of PNG image encoding and decoding.
//! Supports all standard PNG color types, bit depths, and interlacing methods.

const std = @import("std");
const decoder = @import("decoder.zig");
const critical = @import("chunks/critical.zig");
pub const color = @import("color.zig");

// Re-export public types
pub const Image = decoder.Image;
pub const DecodeError = decoder.DecodeError;
pub const Header = critical.Header;
pub const PaletteEntry = critical.PaletteEntry;
pub const ColorType = color.ColorType;
pub const BitDepth = color.BitDepth;
pub const FilterType = color.FilterType;
pub const InterlaceMethod = color.InterlaceMethod;

/// PNG file signature
pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

/// Decode a PNG image from a memory buffer.
/// Caller owns the returned Image and must call deinit() when done.
pub fn decode(allocator: std.mem.Allocator, buffer: []const u8) DecodeError!Image {
    return decoder.decode(allocator, buffer);
}

/// Decode a PNG image from a file path.
/// Caller owns the returned Image and must call deinit() when done.
pub fn decodeFile(allocator: std.mem.Allocator, path: []const u8) !Image {
    return decoder.decodeFile(allocator, path);
}

test {
    // Import all test modules
    _ = @import("color.zig");
    _ = @import("filters.zig");
    _ = @import("decoder.zig");
    // _ = @import("encoder.zig");
    _ = @import("interlace.zig");
    _ = @import("chunks/chunks.zig");
    _ = @import("chunks/critical.zig");
    // _ = @import("chunks/ancillary.zig");
    _ = @import("compression/huffman.zig");
    _ = @import("compression/inflate.zig");
    // _ = @import("compression/deflate.zig");
    _ = @import("compression/zlib.zig");
    // _ = @import("compression/lz77.zig");
    _ = @import("utils/crc32.zig");
    _ = @import("utils/adler32.zig");
    _ = @import("utils/bit_reader.zig");
    _ = @import("utils/bit_writer.zig");
}

test "png signature is correct" {
    try std.testing.expectEqual(@as(usize, 8), signature.len);
    try std.testing.expectEqual(@as(u8, 0x89), signature[0]);
    try std.testing.expectEqual(@as(u8, 'P'), signature[1]);
    try std.testing.expectEqual(@as(u8, 'N'), signature[2]);
    try std.testing.expectEqual(@as(u8, 'G'), signature[3]);
}

test "png.decode decodes 2x2 grayscale PNG" {
    // A 2x2 grayscale PNG, 8-bit
    // Pixels: [0x00, 0x40] / [0x80, 0xFF]
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xDD, 0x52,
        0xF8, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x70, 0x60, 0x68,
        0xF8, 0x0F, 0x00, 0x03, 0x05, 0x01, 0xC0, 0x53, 0x5B, 0x15, 0x9F, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(ColorType.grayscale, image.header.color_type);
    try std.testing.expectEqual(BitDepth.@"8", image.header.bit_depth);

    // Check pixel values
    try std.testing.expectEqual(@as(u8, 0x00), image.getPixel(0, 0)[0]);
    try std.testing.expectEqual(@as(u8, 0x40), image.getPixel(1, 0)[0]);
    try std.testing.expectEqual(@as(u8, 0x80), image.getPixel(0, 1)[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), image.getPixel(1, 1)[0]);
}
