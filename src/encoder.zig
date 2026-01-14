//! PNG image encoder.
//!
//! Encodes raw pixel data into PNG format with compression and filtering.
//! Supports all standard color types, bit depths, and optional interlacing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const png = @import("png.zig");
const color = @import("color.zig");
const filters = @import("filters.zig");
const chunks = @import("chunks/chunks.zig");
const critical = @import("chunks/critical.zig");
const zlib = @import("compression/zlib.zig");
const interlace = @import("interlace.zig");
const Adam7 = interlace.Adam7;

/// Encoder errors.
pub const EncodeError = error{
    OutOfMemory,
    BufferTooSmall,
    InvalidImage,
    CompressionFailed,
    SizeOverflow,
} || zlib.ZlibCompressError;

/// Options for PNG encoding.
pub const EncodeOptions = struct {
    /// Compression level for DEFLATE.
    compression_level: zlib.CompressionLevel = .default,

    /// Filter strategy for scanlines.
    filter_strategy: filters.FilterStrategy = .adaptive,
};

/// Calculate the maximum encoded size for a PNG image.
/// This is a conservative upper bound for buffer allocation.
/// Returns error if the size calculation would overflow.
pub fn maxEncodedSize(header: critical.Header) EncodeError!usize {
    const bytes_per_row = header.bytesPerRow() catch return error.SizeOverflow;
    const pixel_data_size = bytes_per_row * header.height;
    // PNG overhead: signature (8) + IHDR chunk (25) + PLTE max (768+12)
    // + IDAT header per chunk + IEND (12) + compression expansion
    // Worst case: data expands by ~0.1% + 12 bytes per 16KB block + zlib overhead
    const overhead = 8 + 25 + 780 + 12; // Fixed overhead
    // Compression can expand data by a small amount in worst case
    // Add filter bytes (1 per row) and estimate 5% expansion for safety
    const filtered_size = pixel_data_size + header.height;
    const compressed_max = filtered_size + (filtered_size / 20) + 256;
    // IDAT chunks: header (4+4) + data + CRC (4) per chunk
    const num_idat_chunks = (compressed_max + 32767) / 32768;
    return overhead + compressed_max + num_idat_chunks * 12;
}

/// Encode an image to PNG format.
/// Returns the number of bytes written to the output buffer.
pub fn encode(
    allocator: Allocator,
    image: *const png.Image,
    output: []u8,
    options: EncodeOptions,
) EncodeError!usize {
    return encodeRaw(
        allocator,
        image.header,
        image.pixels,
        image.palette,
        output,
        options,
    );
}

/// Encode raw pixel data to PNG format.
/// Returns the number of bytes written to the output buffer.
pub fn encodeRaw(
    allocator: Allocator,
    header: critical.Header,
    pixels: []const u8,
    palette: ?[]const critical.PaletteEntry,
    output: []u8,
    options: EncodeOptions,
) EncodeError!usize {
    var pos: usize = 0;

    // Write PNG signature
    if (output.len < 8) return error.BufferTooSmall;
    @memcpy(output[0..8], &png.signature);
    pos = 8;

    // Write IHDR chunk
    const ihdr_data = header.serialize();
    const ihdr_len = chunks.writeChunk(output[pos..], chunks.chunk_types.IHDR, &ihdr_data) catch
        return error.BufferTooSmall;
    pos += ihdr_len;

    // Write PLTE chunk if indexed color
    if (header.color_type == .indexed) {
        if (palette) |pal| {
            var plte_buffer: [768]u8 = undefined;
            const plte_data = critical.serializePlte(pal, &plte_buffer) catch
                return error.InvalidImage;
            const plte_len = chunks.writeChunk(output[pos..], chunks.chunk_types.PLTE, plte_data) catch
                return error.BufferTooSmall;
            pos += plte_len;
        } else {
            return error.InvalidImage;
        }
    }

    // Filter and compress pixel data
    const compressed_data = try filterAndCompress(allocator, header, pixels, options);
    defer allocator.free(compressed_data);

    // Write IDAT chunk(s)
    // Split into chunks of at most 32KB
    const max_idat_size: usize = 32768;
    var idat_offset: usize = 0;
    while (idat_offset < compressed_data.len) {
        const remaining = compressed_data.len - idat_offset;
        const chunk_size = @min(remaining, max_idat_size);
        const idat_len = chunks.writeChunk(
            output[pos..],
            chunks.chunk_types.IDAT,
            compressed_data[idat_offset..][0..chunk_size],
        ) catch return error.BufferTooSmall;
        pos += idat_len;
        idat_offset += chunk_size;
    }

    // Write IEND chunk
    const iend_len = chunks.writeChunk(output[pos..], chunks.chunk_types.IEND, &.{}) catch
        return error.BufferTooSmall;
    pos += iend_len;

    return pos;
}

/// Filter scanlines and compress to zlib format.
fn filterAndCompress(
    allocator: Allocator,
    header: critical.Header,
    pixels: []const u8,
    options: EncodeOptions,
) EncodeError![]u8 {
    if (header.isInterlaced()) {
        return filterAndCompressInterlaced(allocator, header, pixels, options);
    } else {
        return filterAndCompressNonInterlaced(allocator, header, pixels, options);
    }
}

/// Filter and compress non-interlaced image data.
fn filterAndCompressNonInterlaced(
    allocator: Allocator,
    header: critical.Header,
    pixels: []const u8,
    options: EncodeOptions,
) EncodeError![]u8 {
    const bytes_per_row = header.bytesPerRow() catch return error.SizeOverflow;
    const bytes_per_row_with_filter = bytes_per_row + 1;
    const bpp = header.bytesPerPixel();

    // Allocate filtered data buffer (rows with filter bytes)
    const filtered_size = bytes_per_row_with_filter * header.height;
    const filtered = try allocator.alloc(u8, filtered_size);
    defer allocator.free(filtered);

    // Scratch buffer for adaptive filter selection
    var scratch: []u8 = &.{};
    if (options.filter_strategy == .adaptive) {
        scratch = try allocator.alloc(u8, bytes_per_row);
    }
    defer if (scratch.len > 0) allocator.free(scratch);

    // Filter each scanline
    var prev_row: ?[]const u8 = null;
    for (0..header.height) |y| {
        const src_start = y * bytes_per_row;
        const dst_start = y * bytes_per_row_with_filter;
        const src_row = pixels[src_start..][0..bytes_per_row];
        const dst_row = filtered[dst_start..][0..bytes_per_row_with_filter];

        const filter_type = selectFilter(options.filter_strategy, src_row, prev_row, bpp, scratch);
        filters.filterRow(filter_type, src_row, prev_row, dst_row, bpp);

        prev_row = src_row;
    }

    // Compress the filtered data
    return compressData(allocator, filtered, options.compression_level);
}

/// Filter and compress interlaced image data.
fn filterAndCompressInterlaced(
    allocator: Allocator,
    header: critical.Header,
    pixels: []const u8,
    options: EncodeOptions,
) EncodeError![]u8 {
    const bpp = header.bytesPerPixel();

    // Calculate total size for all passes (with filter bytes)
    const total_raw_size = Adam7.totalInterlacedBytes(header) catch return error.SizeOverflow;

    // Allocate buffers for pass pixel data
    var pass_buffers: [7][]u8 = undefined;
    var allocated_passes: [7]?[]u8 = [_]?[]u8{null} ** 7;
    errdefer {
        for (allocated_passes) |maybe_alloc| {
            if (maybe_alloc) |buf| {
                allocator.free(buf);
            }
        }
    }

    for (0..interlace.pass_count) |p| {
        const pass: u3 = @intCast(p);
        const pass_row_bytes_inner = Adam7.passRowBytes(pass, header) catch return error.SizeOverflow;
        const pass_pixel_bytes = pass_row_bytes_inner * Adam7.passHeight(pass, header.height);
        if (pass_pixel_bytes == 0) {
            pass_buffers[p] = &[_]u8{};
        } else {
            const buf = try allocator.alloc(u8, pass_pixel_bytes);
            allocated_passes[p] = buf;
            pass_buffers[p] = buf;
        }
    }

    // Interlace the image into passes
    Adam7.interlace(pixels, &pass_buffers, header);

    // Allocate filtered data buffer
    const filtered = try allocator.alloc(u8, total_raw_size);
    defer allocator.free(filtered);

    // Scratch buffer for adaptive filter selection
    var max_row_bytes: usize = 0;
    for (0..interlace.pass_count) |p| {
        const prb = Adam7.passRowBytes(@intCast(p), header) catch return error.SizeOverflow;
        max_row_bytes = @max(max_row_bytes, prb);
    }
    var scratch: []u8 = &.{};
    if (options.filter_strategy == .adaptive and max_row_bytes > 0) {
        scratch = try allocator.alloc(u8, max_row_bytes);
    }
    defer if (scratch.len > 0) allocator.free(scratch);

    // Filter each pass
    var filtered_offset: usize = 0;
    for (0..interlace.pass_count) |p| {
        const pass: u3 = @intCast(p);
        const pass_w = Adam7.passWidth(pass, header.width);
        const pass_h = Adam7.passHeight(pass, header.height);

        if (pass_w == 0 or pass_h == 0) continue;

        const pass_row_bytes = Adam7.passRowBytes(pass, header) catch return error.SizeOverflow;
        const pass_row_bytes_with_filter = pass_row_bytes + 1;
        const pass_pixels = pass_buffers[p];

        var prev_row: ?[]const u8 = null;
        for (0..pass_h) |y| {
            const src_start = y * pass_row_bytes;
            const src_row = pass_pixels[src_start..][0..pass_row_bytes];
            const dst_row = filtered[filtered_offset..][0..pass_row_bytes_with_filter];

            const filter_type = selectFilter(options.filter_strategy, src_row, prev_row, bpp, scratch);
            filters.filterRow(filter_type, src_row, prev_row, dst_row, bpp);

            filtered_offset += pass_row_bytes_with_filter;
            prev_row = src_row;
        }
    }

    // Free pass buffers
    for (allocated_passes) |maybe_alloc| {
        if (maybe_alloc) |buf| {
            allocator.free(buf);
        }
    }

    // Compress the filtered data
    return compressData(allocator, filtered[0..filtered_offset], options.compression_level);
}

/// Select filter type based on strategy.
fn selectFilter(
    strategy: filters.FilterStrategy,
    row: []const u8,
    prev_row: ?[]const u8,
    bpp: u8,
    scratch: []u8,
) filters.FilterType {
    return switch (strategy) {
        .none => .none,
        .sub => .sub,
        .up => .up,
        .average => .average,
        .paeth => .paeth,
        .adaptive => filters.selectBestFilter(row, prev_row, bpp, scratch),
    };
}

/// Compress data using zlib.
/// Caller owns the returned slice and must free it with allocator.free().
fn compressData(
    allocator: Allocator,
    data: []const u8,
    level: zlib.CompressionLevel,
) EncodeError![]u8 {
    // Estimate output size: input + expansion + headers
    const max_output = data.len + (data.len / 10) + 256;
    const output = try allocator.alloc(u8, max_output);
    errdefer allocator.free(output);

    const compressed_len = zlib.compress(data, output, level) catch
        return error.CompressionFailed;

    // Reallocate to exact size so caller can free correctly
    const exact_output = try allocator.alloc(u8, compressed_len);
    @memcpy(exact_output, output[0..compressed_len]);
    allocator.free(output);

    return exact_output;
}

/// Encode an image to a file.
pub fn encodeFile(
    allocator: Allocator,
    image: *const png.Image,
    path: []const u8,
    options: EncodeOptions,
) !void {
    const max_size = try maxEncodedSize(image.header);
    const buffer = try allocator.alloc(u8, max_size);
    defer allocator.free(buffer);

    const encoded_len = try encode(allocator, image, buffer, options);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(buffer[0..encoded_len]);
}

// ============================================================================
// Tests
// ============================================================================

test "encode minimal grayscale image" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 2,
        .height = 2,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    // 2x2 grayscale: 4 pixels
    const pixels = [_]u8{ 0x00, 0x40, 0x80, 0xFF };

    var output: [1024]u8 = undefined;
    const len = try encodeRaw(allocator, header, &pixels, null, &output, .{});

    // Verify PNG signature
    try std.testing.expectEqualSlices(u8, &png.signature, output[0..8]);

    // Verify we can decode it back
    var image = try png.decode(allocator, output[0..len]);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
}

test "encode RGB image" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 2,
        .height = 2,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    // 2x2 RGB: Red, Green / Blue, White
    const pixels = [_]u8{
        255, 0,   0,   0,   255, 0, // Row 0: Red, Green
        0,   0,   255, 255, 255, 255, // Row 1: Blue, White
    };

    var output: [1024]u8 = undefined;
    const len = try encodeRaw(allocator, header, &pixels, null, &output, .{});

    // Verify round-trip
    var image = try png.decode(allocator, output[0..len]);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(color.ColorType.rgb, image.header.color_type);
    try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
}

test "encode RGBA image" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 2,
        .height = 2,
        .bit_depth = .@"8",
        .color_type = .rgba,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    // 2x2 RGBA
    const pixels = [_]u8{
        255, 0,   0,   255, 0,   255, 0,   128, // Row 0: Red opaque, Green semi
        0,   0,   255, 255, 128, 128, 128, 0, // Row 1: Blue opaque, Gray transparent
    };

    var output: [1024]u8 = undefined;
    const len = try encodeRaw(allocator, header, &pixels, null, &output, .{});

    var image = try png.decode(allocator, output[0..len]);
    defer image.deinit();

    try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
}

test "encode indexed image" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 2,
        .height = 2,
        .bit_depth = .@"8",
        .color_type = .indexed,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    const palette = [_]critical.PaletteEntry{
        .{ .r = 255, .g = 0, .b = 0 }, // 0: Red
        .{ .r = 0, .g = 255, .b = 0 }, // 1: Green
        .{ .r = 0, .g = 0, .b = 255 }, // 2: Blue
        .{ .r = 255, .g = 255, .b = 255 }, // 3: White
    };

    // 2x2 indexed: indices 0,1,2,3
    const pixels = [_]u8{ 0, 1, 2, 3 };

    var output: [1024]u8 = undefined;
    const len = try encodeRaw(allocator, header, &pixels, &palette, &output, .{});

    var image = try png.decode(allocator, output[0..len]);
    defer image.deinit();

    try std.testing.expectEqual(color.ColorType.indexed, image.header.color_type);
    try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
    try std.testing.expect(image.palette != null);
}

test "encode with different filter strategies" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 4,
        .height = 4,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    // Gradient image
    var pixels: [16]u8 = undefined;
    for (0..16) |i| {
        pixels[i] = @intCast(i * 16);
    }

    const strategies = [_]filters.FilterStrategy{
        .none,
        .sub,
        .up,
        .average,
        .paeth,
        .adaptive,
    };

    for (strategies) |strategy| {
        var output: [2048]u8 = undefined;
        const len = try encodeRaw(allocator, header, &pixels, null, &output, .{
            .filter_strategy = strategy,
        });

        var image = try png.decode(allocator, output[0..len]);
        defer image.deinit();

        try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
    }
}

test "encode with different compression levels" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 8,
        .height = 8,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    // Test image
    var pixels: [64]u8 = undefined;
    for (0..64) |i| {
        pixels[i] = @intCast(i * 4);
    }

    const levels = [_]zlib.CompressionLevel{
        .store,
        .fastest,
        .fast,
        .default,
        .best,
    };

    for (levels) |level| {
        var output: [4096]u8 = undefined;
        const len = try encodeRaw(allocator, header, &pixels, null, &output, .{
            .compression_level = level,
        });

        var image = try png.decode(allocator, output[0..len]);
        defer image.deinit();

        try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
    }
}

test "encode grayscale 16-bit" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 2,
        .height = 2,
        .bit_depth = .@"16",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    // 2x2 16-bit grayscale (big-endian)
    const pixels = [_]u8{
        0x00, 0x00, 0x40, 0x00, // Row 0: 0, 16384
        0x80, 0x00, 0xFF, 0xFF, // Row 1: 32768, 65535
    };

    var output: [1024]u8 = undefined;
    const len = try encodeRaw(allocator, header, &pixels, null, &output, .{});

    var image = try png.decode(allocator, output[0..len]);
    defer image.deinit();

    try std.testing.expectEqual(color.BitDepth.@"16", image.header.bit_depth);
    try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
}

test "encode Image struct" {
    const allocator = std.testing.allocator;

    // First decode a test image
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xDD, 0x52,
        0xF8, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x70, 0x60, 0x68,
        0xF8, 0x0F, 0x00, 0x03, 0x05, 0x01, 0xC0, 0x53, 0x5B, 0x15, 0x9F, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try png.decode(allocator, &test_png);
    defer image.deinit();

    // Re-encode
    var output: [1024]u8 = undefined;
    const len = try encode(allocator, &image, &output, .{});

    // Decode again
    var image2 = try png.decode(allocator, output[0..len]);
    defer image2.deinit();

    try std.testing.expectEqualSlices(u8, image.pixels, image2.pixels);
}

test "maxEncodedSize" {
    const header = critical.Header{
        .width = 100,
        .height = 100,
        .bit_depth = .@"8",
        .color_type = .rgba,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    const max_size = try maxEncodedSize(header);

    // Should be larger than raw pixel data
    const raw_size = (try header.bytesPerRow()) * header.height;
    try std.testing.expect(max_size > raw_size);

    // Should be reasonable (not absurdly large)
    try std.testing.expect(max_size < raw_size * 3);
}
