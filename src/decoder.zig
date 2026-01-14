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

    // Decompress IDAT data
    // Calculate required output size: all rows including filter bytes
    const raw_size = header.rawDataSize();
    var raw_data = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw_data);

    const decompressed_len = zlib.decompress(idat_data.items, raw_data) catch
        return error.DecompressionFailed;

    if (decompressed_len != raw_size) {
        return error.DecompressionFailed;
    }

    // Unfilter scanlines
    const bytes_per_row = header.bytesPerRowWithFilter();
    const bpp = header.bytesPerPixel();

    var prev_row: ?[]const u8 = null;
    for (0..header.height) |y| {
        const row_start = y * bytes_per_row;
        const row = raw_data[row_start..][0..bytes_per_row];

        try filters.unfilterRow(row, prev_row, bpp);
        prev_row = row;
    }

    // Allocate final pixel buffer (without filter bytes)
    const pixel_row_bytes = header.bytesPerRow();
    const pixels = try allocator.alloc(u8, pixel_row_bytes * header.height);
    errdefer allocator.free(pixels);

    // Copy unfiltered data (skip filter byte from each row)
    for (0..header.height) |y| {
        const src_start = y * bytes_per_row + 1; // +1 to skip filter byte
        const dst_start = y * pixel_row_bytes;
        @memcpy(pixels[dst_start..][0..pixel_row_bytes], raw_data[src_start..][0..pixel_row_bytes]);
    }

    return Image{
        .header = header,
        .pixels = pixels,
        .palette = palette,
        .allocator = allocator,
    };
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
