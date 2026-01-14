//! PNG image decoder.
//!
//! Decodes PNG images from byte streams into raw pixel data.
//! Supports all standard color types, bit depths, and filter types.

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

/// Decoder errors.
pub const DecodeError = error{
    InvalidSignature,
    MissingIhdr,
    InvalidIhdr,
    MissingIdat,
    DecompressionFailed,
    InvalidFilterType,
    OutOfMemory,
    UnexpectedChunk,
    InvalidChunk,
    PrematureEnd,
} || chunks.ChunkError || critical.HeaderError || zlib.ZlibError || filters.FilterError;

/// Decoded PNG image.
pub const Image = struct {
    /// Image header information.
    header: critical.Header,

    /// Raw pixel data (row-major, unfiltered).
    /// For indexed images, these are palette indices.
    pixels: []u8,

    /// Optional palette (for indexed color images).
    palette: ?[]const critical.PaletteEntry,

    /// The allocator used for this image's memory.
    allocator: Allocator,

    const Self = @This();

    /// Free the image's allocated memory.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    /// Get a pixel value at the given coordinates.
    /// Returns raw bytes for that pixel (1-8 bytes depending on format).
    pub fn getPixel(self: *const Self, x: u32, y: u32) []const u8 {
        const bpp = self.header.bytesPerPixel();
        const row_start = y * self.header.bytesPerRow();
        const pixel_start = row_start + x * bpp;
        return self.pixels[pixel_start..][0..bpp];
    }

    /// Get a full row of pixel data.
    pub fn getRow(self: *const Self, y: u32) []const u8 {
        const bytes_per_row = self.header.bytesPerRow();
        const start = y * bytes_per_row;
        return self.pixels[start..][0..bytes_per_row];
    }

    /// Get width in pixels.
    pub fn width(self: *const Self) u32 {
        return self.header.width;
    }

    /// Get height in pixels.
    pub fn height(self: *const Self) u32 {
        return self.header.height;
    }
};

/// Decode a PNG image from a byte buffer.
pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image {
    // Verify PNG signature
    if (data.len < 8) {
        return error.InvalidSignature;
    }
    if (!std.mem.eql(u8, data[0..8], &png.signature)) {
        return error.InvalidSignature;
    }

    // Parse chunks
    var iter = chunks.ChunkIterator.init(data[8..]);

    // First chunk must be IHDR
    const first_chunk = (try iter.next()) orelse return error.MissingIhdr;
    if (!std.mem.eql(u8, &first_chunk.chunk_type, &chunks.chunk_types.IHDR)) {
        return error.MissingIhdr;
    }
    if (!first_chunk.verifyCrc()) {
        return error.InvalidChunk;
    }

    const header = critical.Header.parse(first_chunk.data) catch return error.InvalidIhdr;

    // Collect IDAT chunks
    var idat_data = std.ArrayListUnmanaged(u8){};
    defer idat_data.deinit(allocator);

    var palette: ?[]const critical.PaletteEntry = null;
    var found_iend = false;

    while (try iter.next()) |chunk| {
        // Verify CRC for all chunks
        if (!chunk.verifyCrc()) {
            return error.InvalidChunk;
        }

        if (std.mem.eql(u8, &chunk.chunk_type, &chunks.chunk_types.IDAT)) {
            try idat_data.appendSlice(allocator, chunk.data);
        } else if (std.mem.eql(u8, &chunk.chunk_type, &chunks.chunk_types.PLTE)) {
            palette = critical.parsePlte(chunk.data) catch null;
        } else if (std.mem.eql(u8, &chunk.chunk_type, &chunks.chunk_types.IEND)) {
            found_iend = true;
            break;
        }
        // Skip other ancillary chunks for now
    }

    if (idat_data.items.len == 0) {
        return error.MissingIdat;
    }

    if (!found_iend) {
        return error.PrematureEnd;
    }

    // Allocate final pixel buffer
    const pixel_row_bytes = header.bytesPerRow();
    const pixels = try allocator.alloc(u8, pixel_row_bytes * header.height);
    errdefer allocator.free(pixels);

    if (header.isInterlaced()) {
        try decodeInterlaced(allocator, header, idat_data.items, pixels);
    } else {
        try decodeNonInterlaced(allocator, header, idat_data.items, pixels);
    }

    return Image{
        .header = header,
        .pixels = pixels,
        .palette = palette,
        .allocator = allocator,
    };
}

/// Decode a non-interlaced PNG image.
fn decodeNonInterlaced(
    allocator: Allocator,
    header: critical.Header,
    compressed_data: []const u8,
    pixels: []u8,
) DecodeError!void {
    // Calculate required output size: all rows including filter bytes
    const raw_size = header.rawDataSize();
    var raw_data = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw_data);

    const decompressed_len = zlib.decompress(compressed_data, raw_data) catch
        return error.DecompressionFailed;

    if (decompressed_len != raw_size) {
        return error.DecompressionFailed;
    }

    // Unfilter scanlines
    const bytes_per_row_with_filter = header.bytesPerRowWithFilter();
    const bytes_per_row = header.bytesPerRow();
    const bpp = header.bytesPerPixel();

    var prev_row: ?[]const u8 = null;
    for (0..header.height) |y| {
        const row_start = y * bytes_per_row_with_filter;
        const row = raw_data[row_start..][0..bytes_per_row_with_filter];

        try filters.unfilterRow(row, prev_row, bpp);
        prev_row = row;
    }

    // Copy unfiltered data (skip filter byte from each row)
    for (0..header.height) |y| {
        const src_start = y * bytes_per_row_with_filter + 1; // +1 to skip filter byte
        const dst_start = y * bytes_per_row;
        @memcpy(pixels[dst_start..][0..bytes_per_row], raw_data[src_start..][0..bytes_per_row]);
    }
}

/// Decode an interlaced (Adam7) PNG image.
fn decodeInterlaced(
    allocator: Allocator,
    header: critical.Header,
    compressed_data: []const u8,
    pixels: []u8,
) DecodeError!void {
    // Calculate total raw size for all passes
    const raw_size = Adam7.totalInterlacedBytes(header);
    var raw_data = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw_data);

    const decompressed_len = zlib.decompress(compressed_data, raw_data) catch
        return error.DecompressionFailed;

    if (decompressed_len != raw_size) {
        return error.DecompressionFailed;
    }

    const bpp = header.bytesPerPixel();

    // Process each pass: unfilter then extract pixel data
    var pass_pixels: [7][]u8 = undefined;
    var pass_allocations: [7]?[]u8 = [_]?[]u8{null} ** 7;
    defer {
        for (pass_allocations) |maybe_alloc| {
            if (maybe_alloc) |alloc_slice| {
                allocator.free(alloc_slice);
            }
        }
    }

    var raw_offset: usize = 0;
    for (0..interlace.pass_count) |p| {
        const pass: u3 = @intCast(p);
        const pass_h = Adam7.passHeight(pass, header.height);
        const pass_raw_bytes = Adam7.passRawBytes(pass, header);
        const pass_row_bytes = Adam7.passRowBytes(pass, header);
        const pass_row_bytes_with_filter = Adam7.passRowBytesWithFilter(pass, header);

        if (pass_h == 0 or pass_raw_bytes == 0) {
            pass_pixels[p] = &[_]u8{};
            continue;
        }

        // Unfilter this pass's rows
        var prev_row: ?[]const u8 = null;
        for (0..pass_h) |y| {
            const row_start = raw_offset + y * pass_row_bytes_with_filter;
            const row = raw_data[row_start..][0..pass_row_bytes_with_filter];
            try filters.unfilterRow(row, prev_row, bpp);
            prev_row = row;
        }

        // Allocate and copy pixel data (without filter bytes)
        const pass_pixel_bytes = pass_row_bytes * pass_h;
        const pass_pixel_data = try allocator.alloc(u8, pass_pixel_bytes);
        pass_allocations[p] = pass_pixel_data;
        pass_pixels[p] = pass_pixel_data;

        for (0..pass_h) |y| {
            const src_start = raw_offset + y * pass_row_bytes_with_filter + 1;
            const dst_start = y * pass_row_bytes;
            @memcpy(pass_pixel_data[dst_start..][0..pass_row_bytes], raw_data[src_start..][0..pass_row_bytes]);
        }

        raw_offset += pass_raw_bytes;
    }

    // Initialize output to zero (important for sub-byte formats)
    @memset(pixels, 0);

    // Deinterlace: scatter pass pixels to final image
    Adam7.deinterlace(pass_pixels, pixels, header);
}

/// Decode a PNG image from a file path.
pub fn decodeFile(allocator: Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 256); // Max 256MB
    defer allocator.free(data);

    return decode(allocator, data);
}

// Tests

test "decode 2x2 grayscale PNG" {
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
    try std.testing.expectEqual(color.ColorType.grayscale, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"8", image.header.bit_depth);

    // Check pixel values
    try std.testing.expectEqual(@as(u8, 0x00), image.getPixel(0, 0)[0]);
    try std.testing.expectEqual(@as(u8, 0x40), image.getPixel(1, 0)[0]);
    try std.testing.expectEqual(@as(u8, 0x80), image.getPixel(0, 1)[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), image.getPixel(1, 1)[0]);
}

test "decode rejects invalid signature" {
    const bad_data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expectError(error.InvalidSignature, decode(std.testing.allocator, &bad_data));
}

test "decode rejects truncated data" {
    // Just PNG signature, no chunks
    try std.testing.expectError(error.MissingIhdr, decode(std.testing.allocator, &png.signature));
}

test "decode 2x2 RGB 8-bit PNG" {
    // 2x2 RGB 8-bit: Red, Green / Blue, White
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A,
        0x73, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xC0,
        0x00, 0xC2, 0x0C, 0xFF, 0x81, 0x00, 0x00, 0x1F, 0xEE, 0x05, 0xFB, 0xF1, 0xAB, 0xBA, 0x77, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.rgb, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"8", image.header.bit_depth);

    // 3 bytes per pixel (RGB)
    // Pixel (0,0) = Red
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0 }, image.getPixel(0, 0));
    // Pixel (1,0) = Green
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0 }, image.getPixel(1, 0));
    // Pixel (0,1) = Blue
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255 }, image.getPixel(0, 1));
    // Pixel (1,1) = White
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255 }, image.getPixel(1, 1));
}

test "decode 2x2 RGBA 8-bit PNG" {
    // 2x2 RGBA 8-bit: Red opaque, Green semi-transparent / Blue opaque, Fully transparent
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xB6, 0x0D,
        0x24, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x08, 0x1B, 0x18, 0x80, 0x34, 0x90, 0xCD, 0xC0, 0x00, 0x00, 0x3A, 0xDC, 0x05, 0x7C, 0x7D,
        0x0B, 0x6B, 0x2B, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.rgba, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"8", image.header.bit_depth);

    // 4 bytes per pixel (RGBA)
    // Pixel (0,0) = Red opaque
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, image.getPixel(0, 0));
    // Pixel (1,0) = Green semi-transparent
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 128 }, image.getPixel(1, 0));
    // Pixel (0,1) = Blue opaque
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, image.getPixel(0, 1));
    // Pixel (1,1) = Fully transparent
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, image.getPixel(1, 1));
}

test "decode 2x2 grayscale+alpha 8-bit PNG" {
    // 2x2 Grayscale+Alpha 8-bit: Black opaque, White semi / Gray opaque, Gray transparent
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x04, 0x00, 0x00, 0x00, 0xD8, 0xBF, 0xC5,
        0xAF, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0xF8, 0xFF, 0xBF,
        0x81, 0xA1, 0xE1, 0xBF, 0x03, 0x03, 0x00, 0x17, 0x78, 0x04, 0x3E, 0xB5, 0x72, 0x42, 0x34, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.grayscale_alpha, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"8", image.header.bit_depth);

    // 2 bytes per pixel (Gray + Alpha)
    // Pixel (0,0) = Black opaque (0, 255)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255 }, image.getPixel(0, 0));
    // Pixel (1,0) = White semi (255, 128)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 128 }, image.getPixel(1, 0));
    // Pixel (0,1) = Gray opaque (128, 255)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 128, 255 }, image.getPixel(0, 1));
    // Pixel (1,1) = Gray transparent (64, 0)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 64, 0 }, image.getPixel(1, 1));
}

test "decode 2x2 grayscale 16-bit PNG" {
    // 2x2 16-bit Grayscale: 0, 16384 / 32768, 65535
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x10, 0x00, 0x00, 0x00, 0x00, 0x07, 0x4D, 0x8E,
        0xBB, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x60, 0x70, 0x60,
        0x60, 0x68, 0x60, 0xF8, 0xFF, 0x1F, 0x00, 0x06, 0xC7, 0x02, 0xBF, 0xC7, 0x37, 0x5C, 0x6D, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.grayscale, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"16", image.header.bit_depth);

    // 2 bytes per pixel (big-endian 16-bit)
    // Pixel (0,0) = 0x0000
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, image.getPixel(0, 0));
    // Pixel (1,0) = 0x4000 (16384)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x40, 0 }, image.getPixel(1, 0));
    // Pixel (0,1) = 0x8000 (32768)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0 }, image.getPixel(0, 1));
    // Pixel (1,1) = 0xFFFF (65535)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF }, image.getPixel(1, 1));
}

test "decode 2x2 RGB 16-bit PNG" {
    // 2x2 16-bit RGB: Red, Green / Blue, White
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x10, 0x02, 0x00, 0x00, 0x00, 0xAD, 0x44, 0x46,
        0x30, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xFF, 0x9F, 0x01,
        0x0C, 0x60, 0x34, 0x90, 0x01, 0x01, 0x00, 0x75, 0xA4, 0x0B, 0xF5, 0x97, 0xF4, 0x36, 0xA1, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.rgb, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"16", image.header.bit_depth);

    // 6 bytes per pixel (RGB, 2 bytes each, big-endian)
    // Pixel (0,0) = Red (0xFFFF, 0, 0)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0, 0, 0, 0 }, image.getPixel(0, 0));
    // Pixel (1,0) = Green (0, 0xFFFF, 0)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0xFF, 0xFF, 0, 0 }, image.getPixel(1, 0));
    // Pixel (0,1) = Blue (0, 0, 0xFFFF)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0xFF, 0xFF }, image.getPixel(0, 1));
    // Pixel (1,1) = White (0xFFFF, 0xFFFF, 0xFFFF)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, image.getPixel(1, 1));
}

test "decode 4x4 indexed 8-bit PNG" {
    // 4x4 Indexed 8-bit with 4-color palette: Red, Green, Blue, White
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x03, 0x00, 0x00, 0x00, 0x9E, 0x2F, 0x6E,
        0x4C, 0x00, 0x00, 0x00, 0x0C, 0x50, 0x4C, 0x54, 0x45, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
        0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, 0x00, 0x60, 0xF6, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,
        0x54, 0x78, 0xDA, 0x63, 0x60, 0x60, 0x64, 0x62, 0x06, 0x63, 0x06, 0x10, 0xCD, 0x00, 0x62, 0x03,
        0x00, 0x01, 0x04, 0x00, 0x19, 0x92, 0xAF, 0x76, 0xB7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 4), image.width());
    try std.testing.expectEqual(@as(u32, 4), image.height());
    try std.testing.expectEqual(color.ColorType.indexed, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"8", image.header.bit_depth);

    // For indexed, pixels are 1 byte palette indices
    // Check that we have a palette
    try std.testing.expect(image.palette != null);
    const palette = image.palette.?;
    try std.testing.expectEqual(@as(usize, 4), palette.len);

    // Verify palette: Red, Green, Blue, White
    try std.testing.expectEqual(@as(u8, 255), palette[0].r);
    try std.testing.expectEqual(@as(u8, 0), palette[0].g);
    try std.testing.expectEqual(@as(u8, 0), palette[0].b);
    try std.testing.expectEqual(@as(u8, 255), palette[2].b);

    // Check some pixel indices
    // Row 0: 0, 1, 2, 3
    try std.testing.expectEqual(@as(u8, 0), image.getPixel(0, 0)[0]);
    try std.testing.expectEqual(@as(u8, 1), image.getPixel(1, 0)[0]);
    try std.testing.expectEqual(@as(u8, 2), image.getPixel(2, 0)[0]);
    try std.testing.expectEqual(@as(u8, 3), image.getPixel(3, 0)[0]);
}

test "decode 8x2 1-bit grayscale PNG" {
    // 8x2 1-bit grayscale
    // Row 0: 0xAA = 10101010 (pixels: 1,0,1,0,1,0,1,0)
    // Row 1: 0x55 = 01010101 (pixels: 0,1,0,1,0,1,0,1)
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x4D, 0xEF, 0xA0,
        0x40, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x58, 0xC5, 0x10, 0x0A,
        0x00, 0x02, 0x57, 0x01, 0x00, 0x58, 0xB2, 0xCA, 0x23, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 8), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.grayscale, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"1", image.header.bit_depth);

    // For 1-bit, pixels are packed into bytes (MSB first)
    // Row 0: 0xAA = 10101010
    try std.testing.expectEqual(@as(u8, 0xAA), image.getRow(0)[0]);
    // Row 1: 0x55 = 01010101
    try std.testing.expectEqual(@as(u8, 0x55), image.getRow(1)[0]);
}

test "decode 4x2 4-bit grayscale PNG" {
    // 4x2 4-bit grayscale
    // Row 0: 0x01, 0x23 (pixels: 0, 1, 2, 3)
    // Row 1: 0xEF, 0xDC (pixels: 14, 15, 13, 12)
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x04, 0x00, 0x00, 0x00, 0x00, 0x9F, 0x33, 0xCF,
        0xBE, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x54, 0x66, 0x78,
        0x7F, 0x07, 0x00, 0x03, 0x51, 0x01, 0xF0, 0xF6, 0xC2, 0x1E, 0x45, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 4), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.grayscale, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"4", image.header.bit_depth);

    // For 4-bit, pixels are packed into bytes (high nibble first)
    // Row 0: 0x01, 0x23 (pixels: 0, 1, 2, 3)
    try std.testing.expectEqual(@as(u8, 0x01), image.getRow(0)[0]);
    try std.testing.expectEqual(@as(u8, 0x23), image.getRow(0)[1]);
    // Row 1: 0xEF, 0xDC (pixels: 14, 15, 13, 12)
    try std.testing.expectEqual(@as(u8, 0xEF), image.getRow(1)[0]);
    try std.testing.expectEqual(@as(u8, 0xDC), image.getRow(1)[1]);
}

test "decode 4x2 2-bit grayscale PNG" {
    // 4x2 2-bit grayscale
    // Row 0: 0x1B = 00_01_10_11 (pixels: 0, 1, 2, 3)
    // Row 1: 0xE4 = 11_10_01_00 (pixels: 3, 2, 1, 0)
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x02, 0x00, 0x00, 0x00, 0x00, 0x10, 0x73, 0x3A,
        0x1E, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x90, 0x66, 0x78, 0x02,
        0x00, 0x01, 0x39, 0x01, 0x00, 0x7B, 0x99, 0x42, 0x37, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 4), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.grayscale, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"2", image.header.bit_depth);

    // For 2-bit, 4 pixels per byte (high bits first)
    // Row 0: 0x1B = 00_01_10_11
    try std.testing.expectEqual(@as(u8, 0x1B), image.getRow(0)[0]);
    // Row 1: 0xE4 = 11_10_01_00
    try std.testing.expectEqual(@as(u8, 0xE4), image.getRow(1)[0]);
}

test "decode 4x2 indexed 4-bit PNG" {
    // 4x2 Indexed 4-bit with 4-color palette: Black, Red, Green, Blue
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x04, 0x03, 0x00, 0x00, 0x00, 0x8D, 0x86, 0x60,
        0x50, 0x00, 0x00, 0x00, 0x0C, 0x50, 0x4C, 0x54, 0x45, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00,
        0xFF, 0x00, 0x00, 0x00, 0xFF, 0x9B, 0xC0, 0x13, 0xDC, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41,
        0x54, 0x78, 0xDA, 0x63, 0x60, 0x54, 0x66, 0x30, 0x12, 0x00, 0x00, 0x01, 0x0B, 0x00, 0x67, 0x47,
        0x8C, 0x8E, 0xCB, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &test_png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 4), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(color.ColorType.indexed, image.header.color_type);
    try std.testing.expectEqual(color.BitDepth.@"4", image.header.bit_depth);

    // Verify palette exists
    try std.testing.expect(image.palette != null);
    const palette = image.palette.?;
    try std.testing.expectEqual(@as(usize, 4), palette.len);

    // Palette: Black, Red, Green, Blue
    try std.testing.expectEqual(@as(u8, 0), palette[0].r);
    try std.testing.expectEqual(@as(u8, 255), palette[1].r);
    try std.testing.expectEqual(@as(u8, 255), palette[2].g);
    try std.testing.expectEqual(@as(u8, 255), palette[3].b);

    // Row 0: 0x01, 0x23 (indices: 0, 1, 2, 3)
    try std.testing.expectEqual(@as(u8, 0x01), image.getRow(0)[0]);
    try std.testing.expectEqual(@as(u8, 0x23), image.getRow(0)[1]);
    // Row 1: 0x32, 0x10 (indices: 3, 2, 1, 0)
    try std.testing.expectEqual(@as(u8, 0x32), image.getRow(1)[0]);
    try std.testing.expectEqual(@as(u8, 0x10), image.getRow(1)[1]);
}
