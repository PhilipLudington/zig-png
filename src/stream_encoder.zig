//! Streaming PNG encoder.
//!
//! Allows incremental encoding of PNG data, writing rows as they become available.
//! This is useful for generating large images without holding all pixel data in memory,
//! or for streaming scenarios where image data is generated progressively.
//!
//! Usage:
//! ```
//! var encoder = try StreamEncoder.init(allocator, header, palette, writer, options);
//! defer encoder.deinit();
//!
//! // Write rows as they become available
//! for (0..height) |y| {
//!     const row_pixels = generateRow(y);
//!     try encoder.writeRow(row_pixels);
//! }
//!
//! // Finalize the PNG
//! try encoder.finish();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const png = @import("png.zig");
const color = @import("color.zig");
const filters = @import("filters.zig");
const chunks = @import("chunks/chunks.zig");
const critical = @import("chunks/critical.zig");
const zlib = @import("compression/zlib.zig");

/// Errors that can occur during stream encoding.
pub const StreamEncodeError = error{
    OutOfMemory,
    BufferOverflow,
    InvalidImage,
    CompressionFailed,
    AlreadyFinished,
    RowCountMismatch,
    InterlacedNotSupported,
    WriteFailed,
    SizeOverflow,
} || zlib.ZlibCompressError;

/// Options for stream encoding.
pub const StreamEncodeOptions = struct {
    /// Compression level for DEFLATE.
    compression_level: zlib.CompressionLevel = .default,

    /// Filter strategy for scanlines.
    filter_strategy: filters.FilterStrategy = .adaptive,
};

/// Streaming PNG encoder that writes data incrementally.
///
/// The stream encoder accepts rows one at a time and writes the PNG data
/// to a provided writer. This allows encoding very large images without
/// holding all pixel data in memory.
///
/// Note: Interlaced encoding is not supported in streaming mode.
/// The encoder accumulates all filtered rows, then compresses and writes
/// them when `finish()` is called.
pub fn StreamEncoder(comptime WriterType: type) type {
    return struct {
        allocator: Allocator,
        writer: WriterType,
        header: critical.Header,
        palette: ?[]const critical.PaletteEntry,
        options: StreamEncodeOptions,

        /// Buffer for filtered row data (all rows accumulated).
        filtered_buffer: std.ArrayListUnmanaged(u8),

        /// Previous row's pixel data (for filter selection).
        prev_row: ?[]u8,

        /// Current row number being processed.
        current_row: u32,

        /// Whether the encoder has been finished.
        finished: bool,

        /// Scratch buffer for adaptive filter selection.
        scratch: []u8,

        const Self = @This();

        /// Initialize a new stream encoder.
        ///
        /// Writes the PNG signature, IHDR, and optionally PLTE chunk immediately.
        pub fn init(
            allocator: Allocator,
            header: critical.Header,
            palette: ?[]const critical.PaletteEntry,
            writer: WriterType,
            options: StreamEncodeOptions,
        ) StreamEncodeError!Self {
            // Interlaced encoding not supported in streaming mode
            if (header.interlace_method == .adam7) {
                return error.InterlacedNotSupported;
            }

            // Validate indexed images have palette
            if (header.color_type == .indexed and palette == null) {
                return error.InvalidImage;
            }

            var self = Self{
                .allocator = allocator,
                .writer = writer,
                .header = header,
                .palette = palette,
                .options = options,
                .filtered_buffer = .{},
                .prev_row = null,
                .current_row = 0,
                .finished = false,
                .scratch = &.{},
            };

            // Allocate scratch buffer for adaptive filter selection
            if (options.filter_strategy == .adaptive) {
                const bpr = header.bytesPerRow() catch return error.SizeOverflow;
                self.scratch = try allocator.alloc(u8, bpr);
            }

            // Write PNG signature
            self.writer.writeAll(&png.signature) catch return error.WriteFailed;

            // Write IHDR chunk
            const ihdr_data = header.serialize();
            try self.writeChunk(chunks.chunk_types.IHDR, &ihdr_data);

            // Write PLTE chunk if indexed color
            if (header.color_type == .indexed) {
                if (palette) |pal| {
                    var plte_buffer: [768]u8 = undefined;
                    const plte_data = critical.serializePlte(pal, &plte_buffer) catch
                        return error.InvalidImage;
                    try self.writeChunk(chunks.chunk_types.PLTE, plte_data);
                }
            }

            return self;
        }

        /// Free all resources used by the encoder.
        pub fn deinit(self: *Self) void {
            self.filtered_buffer.deinit(self.allocator);
            if (self.prev_row) |prev| {
                self.allocator.free(prev);
            }
            if (self.scratch.len > 0) {
                self.allocator.free(self.scratch);
            }
            self.* = undefined;
        }

        /// Write a row of pixel data.
        ///
        /// The row data should be raw pixel bytes without a filter byte.
        /// The row will be filtered and added to the internal buffer.
        pub fn writeRow(self: *Self, pixels: []const u8) StreamEncodeError!void {
            if (self.finished) {
                return error.AlreadyFinished;
            }

            if (self.current_row >= self.header.height) {
                return error.RowCountMismatch;
            }

            const bytes_per_row = self.header.bytesPerRow() catch return error.SizeOverflow;
            if (pixels.len != bytes_per_row) {
                return error.InvalidImage;
            }

            const bpp = self.header.bytesPerPixel();
            const bytes_per_row_with_filter = bytes_per_row + 1;

            // Select filter type
            const filter_type = selectFilter(self.options.filter_strategy, pixels, self.prev_row, bpp, self.scratch);

            // Allocate space for filtered row
            const old_len = self.filtered_buffer.items.len;
            try self.filtered_buffer.resize(self.allocator, old_len + bytes_per_row_with_filter);
            const filtered_row = self.filtered_buffer.items[old_len..][0..bytes_per_row_with_filter];

            // Apply filter
            filters.filterRow(filter_type, pixels, self.prev_row, filtered_row, bpp);

            // Update previous row
            if (self.prev_row) |prev| {
                self.allocator.free(prev);
            }
            self.prev_row = try self.allocator.alloc(u8, bytes_per_row);
            @memcpy(self.prev_row.?, pixels);

            self.current_row += 1;
        }

        /// Finish encoding and write the IDAT and IEND chunks.
        ///
        /// This compresses all accumulated filtered data and writes it as IDAT chunks,
        /// then writes the IEND chunk.
        pub fn finish(self: *Self) StreamEncodeError!void {
            if (self.finished) {
                return error.AlreadyFinished;
            }

            if (self.current_row != self.header.height) {
                return error.RowCountMismatch;
            }

            // Compress the filtered data
            const compressed = try compressData(self.allocator, self.filtered_buffer.items, self.options.compression_level);
            defer self.allocator.free(compressed);

            // Write IDAT chunk(s) - split into max 32KB chunks
            const max_idat_size: usize = 32768;
            var idat_offset: usize = 0;
            while (idat_offset < compressed.len) {
                const remaining = compressed.len - idat_offset;
                const chunk_size = @min(remaining, max_idat_size);
                try self.writeChunk(chunks.chunk_types.IDAT, compressed[idat_offset..][0..chunk_size]);
                idat_offset += chunk_size;
            }

            // Write IEND chunk
            try self.writeChunk(chunks.chunk_types.IEND, &.{});

            self.finished = true;
        }

        /// Write a chunk to the output.
        fn writeChunk(self: *Self, chunk_type: chunks.ChunkType, data: []const u8) StreamEncodeError!void {
            // Calculate total chunk size
            const total_size = 4 + 4 + data.len + 4;

            // Create chunk buffer
            var chunk_buffer = try self.allocator.alloc(u8, total_size);
            defer self.allocator.free(chunk_buffer);

            // Write length (big-endian)
            std.mem.writeInt(u32, chunk_buffer[0..4], @intCast(data.len), .big);

            // Write type
            @memcpy(chunk_buffer[4..8], &chunk_type);

            // Write data
            if (data.len > 0) {
                @memcpy(chunk_buffer[8..][0..data.len], data);
            }

            // Calculate and write CRC
            const crc = chunks.calculateCrc(chunk_type, data);
            std.mem.writeInt(u32, chunk_buffer[8 + data.len ..][0..4], crc, .big);

            // Write to output
            self.writer.writeAll(chunk_buffer) catch return error.WriteFailed;
        }

        /// Check if the encoder has been finished.
        pub fn isFinished(self: *const Self) bool {
            return self.finished;
        }

        /// Get the number of rows written so far.
        pub fn rowsWritten(self: *const Self) u32 {
            return self.current_row;
        }
    };
}

/// Create a stream encoder writing to an ArrayListUnmanaged.
pub fn arrayListStreamEncoder() type {
    return StreamEncoder(std.ArrayListUnmanaged(u8).Writer);
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
fn compressData(
    allocator: Allocator,
    data: []const u8,
    level: zlib.CompressionLevel,
) StreamEncodeError![]u8 {
    // Estimate output size
    const max_output = data.len + (data.len / 10) + 256;
    const output = try allocator.alloc(u8, max_output);
    errdefer allocator.free(output);

    const compressed_len = zlib.compress(data, output, level) catch
        return error.CompressionFailed;

    // Reallocate to exact size
    const exact_output = try allocator.alloc(u8, compressed_len);
    @memcpy(exact_output, output[0..compressed_len]);
    allocator.free(output);

    return exact_output;
}

// ============================================================================
// Tests
// ============================================================================

test "StreamEncoder encode simple grayscale" {
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

    // Output buffer (Zig 0.15 ArrayListUnmanaged pattern)
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    // Create encoder
    var encoder = try StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        null,
        output.writer(allocator),
        .{},
    );
    defer encoder.deinit();

    // Write rows
    try encoder.writeRow(&[_]u8{ 0x00, 0x40 });
    try encoder.writeRow(&[_]u8{ 0x80, 0xFF });

    // Finish encoding
    try encoder.finish();

    // Verify output is a valid PNG by decoding it
    var image = try png.decode(allocator, output.items);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width());
    try std.testing.expectEqual(@as(u32, 2), image.height());
    try std.testing.expectEqual(@as(u8, 0x00), (try image.getPixel(0, 0))[0]);
    try std.testing.expectEqual(@as(u8, 0x40), (try image.getPixel(1, 0))[0]);
    try std.testing.expectEqual(@as(u8, 0x80), (try image.getPixel(0, 1))[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), (try image.getPixel(1, 1))[0]);
}

test "StreamEncoder encode RGB" {
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

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var encoder = try StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        null,
        output.writer(allocator),
        .{},
    );
    defer encoder.deinit();

    // Write RGB rows: Red, Green / Blue, White
    try encoder.writeRow(&[_]u8{ 255, 0, 0, 0, 255, 0 });
    try encoder.writeRow(&[_]u8{ 0, 0, 255, 255, 255, 255 });

    try encoder.finish();

    // Verify
    var image = try png.decode(allocator, output.items);
    defer image.deinit();

    try std.testing.expectEqual(color.ColorType.rgb, image.header.color_type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0 }, (try image.getPixel(0, 0)));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0 }, (try image.getPixel(1, 0)));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255 }, (try image.getPixel(0, 1)));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255 }, (try image.getPixel(1, 1)));
}

test "StreamEncoder encode RGBA" {
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

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var encoder = try StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        null,
        output.writer(allocator),
        .{},
    );
    defer encoder.deinit();

    // Write RGBA rows
    try encoder.writeRow(&[_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 });
    try encoder.writeRow(&[_]u8{ 0, 0, 255, 255, 128, 128, 128, 0 });

    try encoder.finish();

    var image = try png.decode(allocator, output.items);
    defer image.deinit();

    try std.testing.expectEqual(color.ColorType.rgba, image.header.color_type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, (try image.getPixel(0, 0)));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 128 }, (try image.getPixel(1, 0)));
}

test "StreamEncoder encode indexed" {
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
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
        .{ .r = 255, .g = 255, .b = 255 },
    };

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var encoder = try StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        &palette,
        output.writer(allocator),
        .{},
    );
    defer encoder.deinit();

    // Write indexed rows (palette indices)
    try encoder.writeRow(&[_]u8{ 0, 1 });
    try encoder.writeRow(&[_]u8{ 2, 3 });

    try encoder.finish();

    var image = try png.decode(allocator, output.items);
    defer image.deinit();

    try std.testing.expectEqual(color.ColorType.indexed, image.header.color_type);
    try std.testing.expectEqual(@as(u8, 0), (try image.getPixel(0, 0))[0]);
    try std.testing.expectEqual(@as(u8, 1), (try image.getPixel(1, 0))[0]);
    try std.testing.expectEqual(@as(u8, 2), (try image.getPixel(0, 1))[0]);
    try std.testing.expectEqual(@as(u8, 3), (try image.getPixel(1, 1))[0]);
}

test "StreamEncoder rejects interlaced" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 2,
        .height = 2,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    const result = StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        null,
        output.writer(allocator),
        .{},
    );

    try std.testing.expectError(error.InterlacedNotSupported, result);
}

test "StreamEncoder rejects indexed without palette" {
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

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    const result = StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        null, // No palette!
        output.writer(allocator),
        .{},
    );

    try std.testing.expectError(error.InvalidImage, result);
}

test "StreamEncoder rejects wrong row count" {
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

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var encoder = try StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        null,
        output.writer(allocator),
        .{},
    );
    defer encoder.deinit();

    // Only write one row (should be 2)
    try encoder.writeRow(&[_]u8{ 0x00, 0x40 });

    // Try to finish - should fail
    try std.testing.expectError(error.RowCountMismatch, encoder.finish());
}

test "StreamEncoder with different filter strategies" {
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

    // Generate gradient rows
    var rows: [4][4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            rows[y][x] = @intCast((y * 4 + x) * 16);
        }
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
        var output = std.ArrayListUnmanaged(u8){};
        defer output.deinit(allocator);

        var encoder = try StreamEncoder(@TypeOf(output.writer(allocator))).init(
            allocator,
            header,
            null,
            output.writer(allocator),
            .{ .filter_strategy = strategy },
        );
        defer encoder.deinit();

        for (&rows) |*row| {
            try encoder.writeRow(row);
        }

        try encoder.finish();

        // Verify round-trip
        var image = try png.decode(allocator, output.items);
        defer image.deinit();

        for (0..4) |y| {
            const row = (try image.getRow(@intCast(y)));
            try std.testing.expectEqualSlices(u8, &rows[y], row);
        }
    }
}

test "StreamEncoder larger image" {
    const allocator = std.testing.allocator;

    const header = critical.Header{
        .width = 64,
        .height = 64,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var encoder = try StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        null,
        output.writer(allocator),
        .{},
    );
    defer encoder.deinit();

    // Generate and encode rows
    var row_buffer: [64 * 3]u8 = undefined;
    for (0..64) |y| {
        for (0..64) |x| {
            const idx = x * 3;
            row_buffer[idx] = @intCast(x * 4); // R
            row_buffer[idx + 1] = @intCast(y * 4); // G
            row_buffer[idx + 2] = @intCast((x + y) * 2); // B
        }
        try encoder.writeRow(&row_buffer);
    }

    try encoder.finish();

    // Verify
    var image = try png.decode(allocator, output.items);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 64), image.width());
    try std.testing.expectEqual(@as(u32, 64), image.height());

    // Check a few pixels
    const pixel_0_0 = (try image.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 0), pixel_0_0[0]);
    try std.testing.expectEqual(@as(u8, 0), pixel_0_0[1]);

    const pixel_63_63 = (try image.getPixel(63, 63));
    try std.testing.expectEqual(@as(u8, 252), pixel_63_63[0]);
    try std.testing.expectEqual(@as(u8, 252), pixel_63_63[1]);
}
