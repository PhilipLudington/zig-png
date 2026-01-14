//! Fuzz testing for the PNG decoder.
//!
//! This module provides fuzz test targets for finding bugs in the PNG
//! decoder through random/mutated input.
//!
//! Run with: zig build fuzz
//! Or for continuous fuzzing: zig build fuzz --fuzz
//!
//! The fuzzer will:
//! - Accept arbitrary bytes as input
//! - Attempt to decode them as PNG
//! - Gracefully handle all DecodeErrors (expected for invalid input)
//! - Crash only on actual bugs (memory safety, undefined behavior)

const std = @import("std");
const png = @import("png.zig");
const color = @import("color.zig");

/// Fuzz target for the main PNG decoder.
/// Tests the full decode path with arbitrary input.
fn fuzzDecode(_: void, data: []const u8) anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Try to decode - errors are expected and fine
    var image = png.decode(allocator, data) catch {
        // Decode errors are expected for fuzzed input
        // We just want to make sure we don't crash or corrupt memory
        return;
    };
    defer image.deinit();

    // Successfully decoded - verify invariants
    try validateDecodedImage(&image);
}

/// Validate invariants that should hold for any successfully decoded image.
fn validateDecodedImage(image: *const png.Image) !void {
    const header = image.header;

    // Dimensions must be positive (PNG spec)
    if (header.width == 0 or header.height == 0) {
        return error.InvalidDimensions;
    }

    // Verify pixel buffer size matches expected
    const bytes_per_pixel = color.bytesPerPixel(header.color_type, header.bit_depth);
    const expected_size = @as(usize, header.width) * @as(usize, header.height) * bytes_per_pixel;

    if (image.pixels.len != expected_size) {
        return error.PixelBufferSizeMismatch;
    }

    // Verify we can access all pixels without crashing
    const stride = @as(usize, header.width) * bytes_per_pixel;
    for (0..header.height) |y| {
        const row_start = y * stride;
        const row_end = row_start + stride;
        // Just touch the memory to ensure it's valid
        var sum: u8 = 0;
        for (image.pixels[row_start..row_end]) |byte| {
            sum +%= byte;
        }
        std.mem.doNotOptimizeAway(sum);
    }
}

/// Fuzz target for chunk parsing.
/// Tests chunk boundary handling and CRC validation.
fn fuzzChunks(_: void, data: []const u8) anyerror!void {
    const chunks = @import("chunks/chunks.zig");

    // Try to iterate chunks
    var iter = chunks.ChunkIterator.init(data);
    while (true) {
        const maybe_chunk = iter.next() catch break;
        const chunk = maybe_chunk orelse break;

        // Verify chunk properties don't crash
        _ = chunk.isCritical();
        _ = chunk.isPublic();
        _ = chunk.isSafeToCopy();
        _ = chunk.verifyCrc();
    }
}

/// Fuzz target for zlib/DEFLATE decompression.
/// Tests the compression layer in isolation.
fn fuzzInflate(_: void, data: []const u8) anyerror!void {
    const zlib = @import("compression/zlib.zig");

    // Pre-allocate a reasonable output buffer (1MB)
    // If decompression would exceed this, we'll get an error which is fine
    var output: [1024 * 1024]u8 = undefined;

    // Try to decompress
    _ = zlib.decompress(data, &output) catch {
        // Decompression errors are expected for fuzzed input
    };
}

/// Fuzz target for roundtrip encode/decode.
/// If we can decode something, encoding and re-decoding should produce
/// identical pixels (for non-lossy formats like PNG).
fn fuzzRoundtrip(_: void, data: []const u8) anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // First, try to decode
    var image = png.decode(allocator, data) catch return;
    defer image.deinit();

    // Skip indexed images (palette handling in roundtrip is complex)
    if (image.header.color_type == .indexed) return;

    // Skip very large images to avoid OOM
    const pixel_count = @as(u64, image.header.width) * @as(u64, image.header.height);
    if (pixel_count > 4 * 1024 * 1024) return; // 4 megapixels max

    // Calculate max output size
    const max_size = png.maxEncodedSize(image.header);
    if (max_size > 64 * 1024 * 1024) return; // Skip huge images

    const output = allocator.alloc(u8, max_size) catch return;
    defer allocator.free(output);

    // Encode
    const encoded_len = png.encode(allocator, &image, output, .{}) catch return;

    // Decode again
    var decoded = png.decode(allocator, output[0..encoded_len]) catch {
        return error.FailedToDecodeOwnOutput;
    };
    defer decoded.deinit();

    // Verify pixels match exactly
    if (!std.mem.eql(u8, image.pixels, decoded.pixels)) {
        return error.RoundtripPixelMismatch;
    }

    // Verify dimensions match
    if (image.header.width != decoded.header.width or
        image.header.height != decoded.header.height)
    {
        return error.RoundtripDimensionMismatch;
    }
}

// Zig's built-in fuzz test integration
test "fuzz PNG decode" {
    try std.testing.fuzz({}, fuzzDecode, .{});
}

test "fuzz chunk parsing" {
    try std.testing.fuzz({}, fuzzChunks, .{});
}

test "fuzz inflate" {
    try std.testing.fuzz({}, fuzzInflate, .{});
}

test "fuzz roundtrip" {
    try std.testing.fuzz({}, fuzzRoundtrip, .{});
}
