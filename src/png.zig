//! Zig PNG Library
//!
//! A pure Zig implementation of PNG image encoding and decoding.
//! Supports all standard PNG color types, bit depths, and interlacing methods.

const std = @import("std");
const decoder = @import("decoder.zig");
const encoder = @import("encoder.zig");
const critical = @import("chunks/critical.zig");
const filters = @import("filters.zig");
const zlib = @import("compression/zlib.zig");
pub const color = @import("color.zig");

// Streaming API
pub const stream_decoder = @import("stream_decoder.zig");
pub const stream_encoder = @import("stream_encoder.zig");

// Re-export public types
pub const Image = decoder.Image;
pub const DecodeError = decoder.DecodeError;
pub const EncodeError = encoder.EncodeError;
pub const EncodeOptions = encoder.EncodeOptions;
pub const Header = critical.Header;
pub const PaletteEntry = critical.PaletteEntry;
pub const ColorType = color.ColorType;
pub const BitDepth = color.BitDepth;
pub const FilterType = color.FilterType;
pub const FilterStrategy = filters.FilterStrategy;
pub const InterlaceMethod = color.InterlaceMethod;
pub const CompressionLevel = zlib.CompressionLevel;

// Re-export streaming types
pub const StreamDecoder = stream_decoder.StreamDecoder;
pub const StreamDecodeError = stream_decoder.StreamDecodeError;
pub const DecodedRow = stream_decoder.DecodedRow;
pub const StreamEncoder = stream_encoder.StreamEncoder;
pub const StreamEncodeError = stream_encoder.StreamEncodeError;
pub const StreamEncodeOptions = stream_encoder.StreamEncodeOptions;

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

/// Encode a PNG image to a memory buffer.
/// Returns the number of bytes written to the output buffer.
pub fn encode(
    allocator: std.mem.Allocator,
    image: *const Image,
    output: []u8,
    options: EncodeOptions,
) EncodeError!usize {
    return encoder.encode(allocator, image, output, options);
}

/// Encode raw pixel data to a PNG memory buffer.
/// Returns the number of bytes written to the output buffer.
pub fn encodeRaw(
    allocator: std.mem.Allocator,
    header: Header,
    pixels: []const u8,
    palette: ?[]const PaletteEntry,
    output: []u8,
    options: EncodeOptions,
) EncodeError!usize {
    return encoder.encodeRaw(allocator, header, pixels, palette, output, options);
}

/// Encode a PNG image to a file.
pub fn encodeFile(
    allocator: std.mem.Allocator,
    image: *const Image,
    path: []const u8,
    options: EncodeOptions,
) !void {
    return encoder.encodeFile(allocator, image, path, options);
}

/// Calculate the maximum buffer size needed to encode a PNG.
pub fn maxEncodedSize(header: Header) usize {
    return encoder.maxEncodedSize(header);
}

test {
    // Import all test modules
    _ = @import("color.zig");
    _ = @import("filters.zig");
    _ = @import("decoder.zig");
    _ = @import("encoder.zig");
    _ = @import("interlace.zig");
    _ = @import("chunks/chunks.zig");
    _ = @import("chunks/critical.zig");
    // _ = @import("chunks/ancillary.zig");
    _ = @import("compression/huffman.zig");
    _ = @import("compression/inflate.zig");
    _ = @import("compression/deflate.zig");
    _ = @import("compression/zlib.zig");
    _ = @import("compression/lz77.zig");
    _ = @import("utils/crc32.zig");
    _ = @import("utils/adler32.zig");
    _ = @import("utils/bit_reader.zig");
    _ = @import("utils/bit_writer.zig");
    // Streaming API
    _ = @import("stream_decoder.zig");
    _ = @import("stream_encoder.zig");
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

test "png.encode round-trip grayscale" {
    const allocator = std.testing.allocator;

    // Decode a test PNG
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xDD, 0x52,
        0xF8, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x70, 0x60, 0x68,
        0xF8, 0x0F, 0x00, 0x03, 0x05, 0x01, 0xC0, 0x53, 0x5B, 0x15, 0x9F, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var original = try decode(allocator, &test_png);
    defer original.deinit();

    // Re-encode
    var output: [1024]u8 = undefined;
    const encoded_len = try encode(allocator, &original, &output, .{});

    // Decode again
    var decoded = try decode(allocator, output[0..encoded_len]);
    defer decoded.deinit();

    // Verify pixels match
    try std.testing.expectEqualSlices(u8, original.pixels, decoded.pixels);
    try std.testing.expectEqual(original.header.width, decoded.header.width);
    try std.testing.expectEqual(original.header.height, decoded.header.height);
    try std.testing.expectEqual(original.header.color_type, decoded.header.color_type);
    try std.testing.expectEqual(original.header.bit_depth, decoded.header.bit_depth);
}

test "png.encode round-trip RGB" {
    const allocator = std.testing.allocator;

    // 2x2 RGB 8-bit: Red, Green / Blue, White
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A,
        0x73, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xC0,
        0x00, 0xC2, 0x0C, 0xFF, 0x81, 0x00, 0x00, 0x1F, 0xEE, 0x05, 0xFB, 0xF1, 0xAB, 0xBA, 0x77, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var original = try decode(allocator, &test_png);
    defer original.deinit();

    var output: [1024]u8 = undefined;
    const encoded_len = try encode(allocator, &original, &output, .{});

    var decoded = try decode(allocator, output[0..encoded_len]);
    defer decoded.deinit();

    try std.testing.expectEqualSlices(u8, original.pixels, decoded.pixels);
    try std.testing.expectEqual(ColorType.rgb, decoded.header.color_type);
}

test "png.encode round-trip RGBA" {
    const allocator = std.testing.allocator;

    // 2x2 RGBA 8-bit
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xB6, 0x0D,
        0x24, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x08, 0x1B, 0x18, 0x80, 0x34, 0x90, 0xCD, 0xC0, 0x00, 0x00, 0x3A, 0xDC, 0x05, 0x7C, 0x7D,
        0x0B, 0x6B, 0x2B, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var original = try decode(allocator, &test_png);
    defer original.deinit();

    var output: [1024]u8 = undefined;
    const encoded_len = try encode(allocator, &original, &output, .{});

    var decoded = try decode(allocator, output[0..encoded_len]);
    defer decoded.deinit();

    try std.testing.expectEqualSlices(u8, original.pixels, decoded.pixels);
    try std.testing.expectEqual(ColorType.rgba, decoded.header.color_type);
}

test "png.encodeRaw creates valid PNG" {
    const allocator = std.testing.allocator;

    const header = Header{
        .width = 4,
        .height = 4,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    // Create a gradient image
    var pixels: [16]u8 = undefined;
    for (0..16) |i| {
        pixels[i] = @intCast(i * 16);
    }

    var output: [2048]u8 = undefined;
    const len = try encodeRaw(allocator, header, &pixels, null, &output, .{});

    // Decode and verify
    var image = try decode(allocator, output[0..len]);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 4), image.width());
    try std.testing.expectEqual(@as(u32, 4), image.height());
    try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
}
