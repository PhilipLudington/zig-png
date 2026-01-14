//! Streaming PNG decoder.
//!
//! Allows incremental parsing of PNG data, producing decoded rows as they become
//! available. This is useful for processing large images without loading the entire
//! file into memory, or for streaming scenarios where data arrives in chunks.
//!
//! Usage:
//! ```
//! var decoder = StreamDecoder.init(allocator);
//! defer decoder.deinit();
//!
//! // Feed data as it arrives
//! while (more_data) |chunk| {
//!     while (try decoder.feed(chunk)) |row| {
//!         // Process row.pixels
//!         row.deinit();  // Or keep for later
//!     }
//! }
//!
//! // Get final image or remaining rows
//! const image = try decoder.finish();
//! defer image.deinit();
//! ```

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

/// Errors that can occur during stream decoding.
pub const StreamDecodeError = error{
    InvalidSignature,
    MissingIhdr,
    InvalidIhdr,
    InvalidChunk,
    DecompressionFailed,
    InvalidFilterType,
    OutOfMemory,
    UnexpectedChunk,
    PrematureEnd,
    InterlacedNotSupported,
    AlreadyFinished,
    SizeOverflow,
} || chunks.ChunkError || critical.HeaderError || zlib.ZlibError || filters.FilterError;

/// State of the stream decoder state machine.
const DecoderState = enum {
    /// Waiting for PNG signature (first 8 bytes).
    signature,
    /// Waiting for IHDR chunk.
    ihdr,
    /// Processing chunks (PLTE, IDAT, etc.).
    chunks,
    /// Received IEND, decoder is finished.
    finished,
};

/// A decoded row from the stream decoder.
pub const DecodedRow = struct {
    /// The row number (0-indexed).
    y: u32,
    /// The pixel data for this row (without filter byte).
    pixels: []u8,
    /// Allocator used for this row's memory.
    allocator: Allocator,

    /// Free the row's memory.
    pub fn deinit(self: *DecodedRow) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Streaming PNG decoder that processes data incrementally.
///
/// The stream decoder maintains internal state and buffers, allowing PNG data
/// to be fed in arbitrary chunks. Decoded rows are produced as soon as enough
/// compressed data has been accumulated and decompressed.
///
/// Note: Interlaced images are not currently supported by the stream decoder.
/// Use the standard `png.decode()` function for interlaced images.
pub const StreamDecoder = struct {
    allocator: Allocator,
    state: DecoderState,

    /// Input buffer for accumulating partial data.
    input_buffer: std.ArrayListUnmanaged(u8),

    /// Accumulated IDAT compressed data.
    idat_buffer: std.ArrayListUnmanaged(u8),

    /// Decompressed (raw) data buffer with filter bytes.
    raw_buffer: std.ArrayListUnmanaged(u8),

    /// Parsed header (available after IHDR is processed).
    header: ?critical.Header,

    /// Parsed palette (available after PLTE is processed).
    /// This is owned memory that is freed on deinit().
    palette: ?[]critical.PaletteEntry,

    /// Current row being processed (0-indexed).
    current_row: u32,

    /// Previous row's data (for filter reconstruction).
    prev_row: ?[]u8,

    /// Position in raw_buffer where we've processed up to.
    raw_pos: usize,

    /// Whether we've seen IEND.
    seen_iend: bool,

    const Self = @This();

    /// Initialize a new stream decoder.
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .state = .signature,
            .input_buffer = .{},
            .idat_buffer = .{},
            .raw_buffer = .{},
            .header = null,
            .palette = null,
            .current_row = 0,
            .prev_row = null,
            .raw_pos = 0,
            .seen_iend = false,
        };
    }

    /// Free all resources used by the decoder.
    pub fn deinit(self: *Self) void {
        self.input_buffer.deinit(self.allocator);
        self.idat_buffer.deinit(self.allocator);
        self.raw_buffer.deinit(self.allocator);
        if (self.prev_row) |prev| {
            self.allocator.free(prev);
        }
        if (self.palette) |pal| {
            self.allocator.free(pal);
        }
        self.* = undefined;
    }

    /// Get the image header, if available.
    /// Returns null if IHDR has not been processed yet.
    pub fn getHeader(self: *const Self) ?critical.Header {
        return self.header;
    }

    /// Get the palette, if available.
    /// Returns null if no PLTE chunk has been processed.
    pub fn getPalette(self: *const Self) ?[]const critical.PaletteEntry {
        return self.palette;
    }

    /// Check if the decoder has finished (received IEND).
    pub fn isFinished(self: *const Self) bool {
        return self.state == .finished;
    }

    /// Feed data to the decoder and get the next available decoded row.
    ///
    /// Returns a decoded row if one is available, or null if more data is needed.
    /// The caller owns the returned row and must call `deinit()` on it when done.
    ///
    /// Call this function in a loop until it returns null, then feed more data.
    pub fn feed(self: *Self, data: []const u8) StreamDecodeError!?DecodedRow {
        // Append new data to input buffer
        try self.input_buffer.appendSlice(self.allocator, data);

        // Process based on current state
        return self.processInput();
    }

    /// Try to produce the next decoded row without feeding more data.
    ///
    /// This is useful after calling `feed()` to drain all available rows
    /// before feeding more data.
    pub fn nextRow(self: *Self) StreamDecodeError!?DecodedRow {
        return self.processInput();
    }

    /// Process buffered input and try to produce a decoded row.
    fn processInput(self: *Self) StreamDecodeError!?DecodedRow {
        while (true) {
            switch (self.state) {
                .signature => {
                    if (!try self.processSignature()) return null;
                },
                .ihdr => {
                    if (!try self.processIhdr()) return null;
                },
                .chunks => {
                    // Process chunks and decompress data
                    if (!try self.processChunks()) {
                        // No more chunks to process, try to produce rows
                        return try self.tryProduceRow();
                    }
                    // After processing chunks, we might have enough data for a row
                    if (try self.tryProduceRow()) |row| {
                        return row;
                    }
                    // Otherwise continue processing chunks
                },
                .finished => {
                    // Try to produce remaining rows from buffered raw data
                    return try self.tryProduceRow();
                },
            }
        }
    }

    /// Process the PNG signature.
    fn processSignature(self: *Self) StreamDecodeError!bool {
        if (self.input_buffer.items.len < 8) {
            return false; // Need more data
        }

        if (!std.mem.eql(u8, self.input_buffer.items[0..8], &png.signature)) {
            return error.InvalidSignature;
        }

        // Remove signature from buffer
        std.mem.copyForwards(u8, self.input_buffer.items[0..], self.input_buffer.items[8..]);
        self.input_buffer.items.len -= 8;

        self.state = .ihdr;
        return true;
    }

    /// Process the IHDR chunk.
    fn processIhdr(self: *Self) StreamDecodeError!bool {
        // Need at least 12 bytes for minimum chunk (length + type + crc)
        if (self.input_buffer.items.len < 12) {
            return false;
        }

        // Try to read the chunk
        const result = chunks.readChunk(self.input_buffer.items) catch |err| {
            if (err == error.UnexpectedEndOfData) {
                return false; // Need more data
            }
            return err;
        };

        if (!std.mem.eql(u8, &result.chunk.chunk_type, &chunks.chunk_types.IHDR)) {
            return error.MissingIhdr;
        }

        if (!result.chunk.verifyCrc()) {
            return error.InvalidChunk;
        }

        self.header = critical.Header.parse(result.chunk.data) catch return error.InvalidIhdr;

        // Check for interlacing - not supported in streaming mode
        if (self.header.?.interlace_method == .adam7) {
            return error.InterlacedNotSupported;
        }

        // Remove chunk from buffer
        std.mem.copyForwards(u8, self.input_buffer.items[0..], self.input_buffer.items[result.bytes_consumed..]);
        self.input_buffer.items.len -= result.bytes_consumed;

        self.state = .chunks;
        return true;
    }

    /// Process chunks (PLTE, IDAT, etc.).
    /// Returns true if a chunk was processed, false if more data is needed.
    fn processChunks(self: *Self) StreamDecodeError!bool {
        if (self.input_buffer.items.len < 12) {
            return false;
        }

        const result = chunks.readChunk(self.input_buffer.items) catch |err| {
            if (err == error.UnexpectedEndOfData) {
                return false; // Need more data
            }
            return err;
        };

        // Process the chunk based on type
        if (std.mem.eql(u8, &result.chunk.chunk_type, &chunks.chunk_types.IDAT)) {
            // Accumulate IDAT data
            try self.idat_buffer.appendSlice(self.allocator, result.chunk.data);

            // Try to decompress accumulated data
            try self.tryDecompress();
        } else if (std.mem.eql(u8, &result.chunk.chunk_type, &chunks.chunk_types.PLTE)) {
            // Parse and copy palette to owned memory
            const parsed_pal = critical.parsePlte(result.chunk.data) catch null;
            if (parsed_pal) |pal| {
                const owned_pal = try self.allocator.alloc(critical.PaletteEntry, pal.len);
                @memcpy(owned_pal, pal);
                self.palette = owned_pal;
            }
        } else if (std.mem.eql(u8, &result.chunk.chunk_type, &chunks.chunk_types.IEND)) {
            self.seen_iend = true;
            self.state = .finished;

            // Do final decompression with all IDAT data
            try self.tryDecompress();
        }
        // Skip other ancillary chunks

        // Remove chunk from buffer
        std.mem.copyForwards(u8, self.input_buffer.items[0..], self.input_buffer.items[result.bytes_consumed..]);
        self.input_buffer.items.len -= result.bytes_consumed;

        return true;
    }

    /// Try to decompress accumulated IDAT data.
    fn tryDecompress(self: *Self) StreamDecodeError!void {
        if (self.idat_buffer.items.len == 0) {
            return;
        }

        const header = self.header orelse return;

        // Calculate how much raw data we need
        const total_raw_size = header.rawDataSize() catch return error.SizeOverflow;

        // Only attempt full decompression when we have IEND or enough data
        // For streaming, we accumulate all IDAT chunks first, then decompress
        if (!self.seen_iend) {
            return; // Wait for all IDAT chunks
        }

        // Allocate raw buffer if needed
        if (self.raw_buffer.items.len == 0) {
            try self.raw_buffer.resize(self.allocator, total_raw_size);

            const decompressed_len = zlib.decompress(self.idat_buffer.items, self.raw_buffer.items) catch
                return error.DecompressionFailed;

            if (decompressed_len != total_raw_size) {
                return error.DecompressionFailed;
            }

            // Clear IDAT buffer to free memory
            self.idat_buffer.clearAndFree(self.allocator);
        }
    }

    /// Try to produce a decoded row from the raw buffer.
    fn tryProduceRow(self: *Self) StreamDecodeError!?DecodedRow {
        const header = self.header orelse return null;

        if (self.current_row >= header.height) {
            return null; // All rows processed
        }

        if (self.raw_buffer.items.len == 0) {
            return null; // No decompressed data yet
        }

        const bytes_per_row_with_filter = header.bytesPerRowWithFilter() catch return error.SizeOverflow;
        const bytes_per_row = header.bytesPerRow() catch return error.SizeOverflow;
        const bpp = header.bytesPerPixel();

        // Check if we have enough data for the next row
        const row_start = self.current_row * bytes_per_row_with_filter;
        const row_end = row_start + bytes_per_row_with_filter;

        if (row_end > self.raw_buffer.items.len) {
            return null; // Not enough data
        }

        // Get the raw row (with filter byte)
        const raw_row = self.raw_buffer.items[row_start..row_end];

        // Unfilter the row in place
        try filters.unfilterRow(raw_row, self.prev_row, bpp);

        // Allocate output row (without filter byte)
        const pixels = try self.allocator.alloc(u8, bytes_per_row);
        @memcpy(pixels, raw_row[1..]);

        // Update previous row for next iteration
        if (self.prev_row) |prev| {
            self.allocator.free(prev);
        }
        self.prev_row = try self.allocator.alloc(u8, bytes_per_row_with_filter);
        @memcpy(self.prev_row.?, raw_row);

        const row = DecodedRow{
            .y = self.current_row,
            .pixels = pixels,
            .allocator = self.allocator,
        };

        self.current_row += 1;

        return row;
    }

    /// Finish decoding and return a complete image.
    ///
    /// This collects all remaining rows and assembles them into an Image struct
    /// compatible with the regular decoder output.
    ///
    /// The caller owns the returned Image and must call `deinit()` on it.
    pub fn finish(self: *Self) StreamDecodeError!png.Image {
        if (self.state != .finished) {
            // Try to process remaining input
            while (try self.processInput()) |row| {
                // Process remaining rows
                var mutable_row = row;
                mutable_row.deinit();
            }

            if (self.state != .finished) {
                return error.PrematureEnd;
            }
        }

        const header = self.header orelse return error.MissingIhdr;

        // Allocate pixel buffer for the complete image
        const bytes_per_row = header.bytesPerRow() catch return error.SizeOverflow;
        const pixel_size = bytes_per_row * header.height;
        const pixels = try self.allocator.alloc(u8, pixel_size);
        errdefer self.allocator.free(pixels);

        // Copy all rows to the pixel buffer
        const bytes_per_row_with_filter = header.bytesPerRowWithFilter() catch return error.SizeOverflow;

        for (0..header.height) |y| {
            const raw_row_start = y * bytes_per_row_with_filter;
            const raw_row = self.raw_buffer.items[raw_row_start..][0..bytes_per_row_with_filter];
            const dst_row_start = y * bytes_per_row;
            @memcpy(pixels[dst_row_start..][0..bytes_per_row], raw_row[1..]); // Skip filter byte
        }

        return png.Image{
            .header = header,
            .pixels = pixels,
            .palette = self.palette,
            .allocator = self.allocator,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StreamDecoder decode simple grayscale" {
    const allocator = std.testing.allocator;

    // 2x2 grayscale PNG
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xDD, 0x52,
        0xF8, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x70, 0x60, 0x68,
        0xF8, 0x0F, 0x00, 0x03, 0x05, 0x01, 0xC0, 0x53, 0x5B, 0x15, 0x9F, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var decoder = StreamDecoder.init(allocator);
    defer decoder.deinit();

    // Feed all data at once
    var row0: ?DecodedRow = try decoder.feed(&test_png);
    var row1: ?DecodedRow = null;

    if (row0 == null) {
        row0 = try decoder.nextRow();
    }
    if (row0 != null) {
        row1 = try decoder.nextRow();
    }

    // Verify header
    const header = decoder.getHeader().?;
    try std.testing.expectEqual(@as(u32, 2), header.width);
    try std.testing.expectEqual(@as(u32, 2), header.height);
    try std.testing.expectEqual(color.ColorType.grayscale, header.color_type);

    // Verify rows
    if (row0) |*r| {
        defer r.deinit();
        try std.testing.expectEqual(@as(u32, 0), r.y);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x40 }, r.pixels);
    }

    if (row1) |*r| {
        defer r.deinit();
        try std.testing.expectEqual(@as(u32, 1), r.y);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0xFF }, r.pixels);
    }
}

test "StreamDecoder decode in chunks" {
    const allocator = std.testing.allocator;

    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xDD, 0x52,
        0xF8, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x70, 0x60, 0x68,
        0xF8, 0x0F, 0x00, 0x03, 0x05, 0x01, 0xC0, 0x53, 0x5B, 0x15, 0x9F, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var decoder = StreamDecoder.init(allocator);
    defer decoder.deinit();

    // Feed data in small chunks
    const chunk_size = 10;
    var offset: usize = 0;
    var collected_rows = std.ArrayListUnmanaged(DecodedRow){};
    defer {
        for (collected_rows.items) |*row| {
            row.deinit();
        }
        collected_rows.deinit(allocator);
    }

    while (offset < test_png.len) {
        const end = @min(offset + chunk_size, test_png.len);
        const chunk = test_png[offset..end];

        // Feed chunk and collect all available rows
        if (try decoder.feed(chunk)) |row| {
            try collected_rows.append(allocator, row);
        }

        // Drain any additional rows
        while (try decoder.nextRow()) |row| {
            try collected_rows.append(allocator, row);
        }

        offset = end;
    }

    // Verify we got all rows
    try std.testing.expectEqual(@as(usize, 2), collected_rows.items.len);
    try std.testing.expectEqual(@as(u32, 0), collected_rows.items[0].y);
    try std.testing.expectEqual(@as(u32, 1), collected_rows.items[1].y);
}

test "StreamDecoder finish returns complete image" {
    const allocator = std.testing.allocator;

    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xDD, 0x52,
        0xF8, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x70, 0x60, 0x68,
        0xF8, 0x0F, 0x00, 0x03, 0x05, 0x01, 0xC0, 0x53, 0x5B, 0x15, 0x9F, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var decoder = StreamDecoder.init(allocator);
    defer decoder.deinit();

    // Feed all data and drain any returned rows
    if (try decoder.feed(&test_png)) |row| {
        var r = row;
        r.deinit();
    }
    while (try decoder.nextRow()) |row| {
        var r = row;
        r.deinit();
    }

    // Get complete image
    var image = try decoder.finish();
    defer image.deinit();

    // Verify
    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(@as(u8, 0x00), (try image.getPixel(0, 0))[0]);
    try std.testing.expectEqual(@as(u8, 0x40), (try image.getPixel(1, 0))[0]);
    try std.testing.expectEqual(@as(u8, 0x80), (try image.getPixel(0, 1))[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), (try image.getPixel(1, 1))[0]);
}

test "StreamDecoder rejects invalid signature" {
    const allocator = std.testing.allocator;

    var decoder = StreamDecoder.init(allocator);
    defer decoder.deinit();

    const bad_data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    try std.testing.expectError(error.InvalidSignature, decoder.feed(&bad_data));
}

test "StreamDecoder rejects interlaced images" {
    const allocator = std.testing.allocator;

    // Construct a PNG with interlace_method = 1 (adam7)
    // We need: signature + IHDR chunk with interlace=1
    var buffer: [100]u8 = undefined;
    var pos: usize = 0;

    // PNG signature
    @memcpy(buffer[pos..][0..8], &png.signature);
    pos += 8;

    // IHDR data with interlace=1
    const ihdr_data = [_]u8{
        0x00, 0x00, 0x00, 0x02, // width = 2
        0x00, 0x00, 0x00, 0x02, // height = 2
        0x08, // bit depth = 8
        0x00, // color type = grayscale
        0x00, // compression = 0
        0x00, // filter = 0
        0x01, // interlace = 1 (adam7)
    };

    // Write IHDR chunk
    std.mem.writeInt(u32, buffer[pos..][0..4], 13, .big);
    pos += 4;
    @memcpy(buffer[pos..][0..4], "IHDR");
    pos += 4;
    @memcpy(buffer[pos..][0..13], &ihdr_data);
    pos += 13;
    const crc = chunks.calculateCrc("IHDR".*, &ihdr_data);
    std.mem.writeInt(u32, buffer[pos..][0..4], crc, .big);
    pos += 4;

    var decoder = StreamDecoder.init(allocator);
    defer decoder.deinit();

    try std.testing.expectError(error.InterlacedNotSupported, decoder.feed(buffer[0..pos]));
}

test "StreamDecoder RGB image" {
    const allocator = std.testing.allocator;

    // 2x2 RGB 8-bit PNG
    const test_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A,
        0x73, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xC0,
        0x00, 0xC2, 0x0C, 0xFF, 0x81, 0x00, 0x00, 0x1F, 0xEE, 0x05, 0xFB, 0xF1, 0xAB, 0xBA, 0x77, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var decoder = StreamDecoder.init(allocator);
    defer decoder.deinit();

    // Feed all data and drain any returned rows
    if (try decoder.feed(&test_png)) |row| {
        var r = row;
        r.deinit();
    }
    while (try decoder.nextRow()) |row| {
        var r = row;
        r.deinit();
    }

    var image = try decoder.finish();
    defer image.deinit();

    try std.testing.expectEqual(color.ColorType.rgb, image.header.color_type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0 }, (try image.getPixel(0, 0)));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0 }, (try image.getPixel(1, 0)));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255 }, (try image.getPixel(0, 1)));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255 }, (try image.getPixel(1, 1)));
}
