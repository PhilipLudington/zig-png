//! Adam7 interlacing support for PNG images.
//!
//! PNG uses the Adam7 interlacing method, which divides the image into
//! 7 passes. Each pass contains a subset of the pixels, arranged in a
//! specific pattern that allows progressive display of the image.
//!
//! Pass layout for an 8x8 block:
//! ```
//! 1 6 4 6 2 6 4 6
//! 7 7 7 7 7 7 7 7
//! 5 6 5 6 5 6 5 6
//! 7 7 7 7 7 7 7 7
//! 3 6 4 6 3 6 4 6
//! 7 7 7 7 7 7 7 7
//! 5 6 5 6 5 6 5 6
//! 7 7 7 7 7 7 7 7
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const color = @import("color.zig");
const critical = @import("chunks/critical.zig");

/// Number of passes in Adam7 interlacing.
pub const pass_count: u3 = 7;

/// Adam7 interlacing constants and functions.
pub const Adam7 = struct {
    /// Starting column for each pass (0-indexed).
    pub const x_origin = [7]u8{ 0, 4, 0, 2, 0, 1, 0 };

    /// Starting row for each pass (0-indexed).
    pub const y_origin = [7]u8{ 0, 0, 4, 0, 2, 0, 1 };

    /// Column spacing (step) for each pass.
    pub const x_spacing = [7]u8{ 8, 8, 4, 4, 2, 2, 1 };

    /// Row spacing (step) for each pass.
    pub const y_spacing = [7]u8{ 8, 8, 8, 4, 4, 2, 2 };

    /// Calculate the width of a pass (number of pixels per row).
    ///
    /// For a given pass and image width, returns how many columns
    /// are included in that pass.
    pub fn passWidth(pass: u3, image_width: u32) u32 {
        if (image_width == 0) return 0;
        const origin = x_origin[pass];
        const spacing = x_spacing[pass];
        // Calculate ceiling of (image_width - origin) / spacing
        if (image_width <= origin) return 0;
        return (image_width - origin + spacing - 1) / spacing;
    }

    /// Calculate the height of a pass (number of rows).
    ///
    /// For a given pass and image height, returns how many rows
    /// are included in that pass.
    pub fn passHeight(pass: u3, image_height: u32) u32 {
        if (image_height == 0) return 0;
        const origin = y_origin[pass];
        const spacing = y_spacing[pass];
        // Calculate ceiling of (image_height - origin) / spacing
        if (image_height <= origin) return 0;
        return (image_height - origin + spacing - 1) / spacing;
    }

    /// Calculate bytes per row for a pass (not including filter byte).
    pub fn passRowBytes(pass: u3, header: critical.Header) usize {
        const pass_w = passWidth(pass, header.width);
        if (pass_w == 0) return 0;
        return color.bytesPerRow(pass_w, header.color_type, header.bit_depth);
    }

    /// Calculate bytes per row for a pass (including filter byte).
    pub fn passRowBytesWithFilter(pass: u3, header: critical.Header) usize {
        const row_bytes = passRowBytes(pass, header);
        if (row_bytes == 0) return 0;
        return row_bytes + 1;
    }

    /// Calculate total raw bytes for a pass (including filter bytes).
    pub fn passRawBytes(pass: u3, header: critical.Header) usize {
        const pass_h = passHeight(pass, header.height);
        if (pass_h == 0) return 0;
        return passRowBytesWithFilter(pass, header) * pass_h;
    }

    /// Calculate total raw bytes for all passes combined.
    pub fn totalInterlacedBytes(header: critical.Header) usize {
        var total: usize = 0;
        for (0..pass_count) |p| {
            total += passRawBytes(@intCast(p), header);
        }
        return total;
    }

    /// Get the X coordinate in the final image for a pixel position in a pass.
    pub fn passToImageX(pass: u3, pass_x: u32) u32 {
        return x_origin[pass] + pass_x * x_spacing[pass];
    }

    /// Get the Y coordinate in the final image for a row position in a pass.
    pub fn passToImageY(pass: u3, pass_y: u32) u32 {
        return y_origin[pass] + pass_y * y_spacing[pass];
    }

    /// Deinterlace raw pass data into a final image buffer.
    ///
    /// Takes the raw decompressed and unfiltered data from all passes
    /// and scatters the pixels to their correct positions in the output.
    ///
    /// `pass_data` is an array of slices, one per pass. Each slice contains
    /// the unfiltered pixel data (without filter bytes) for that pass.
    /// Passes with no pixels should have empty slices.
    ///
    /// `output` must be pre-allocated to header.bytesPerRow() * header.height bytes.
    pub fn deinterlace(
        pass_data: [7][]const u8,
        output: []u8,
        header: critical.Header,
    ) void {
        const bpp = header.bytesPerPixel();
        const output_row_bytes = header.bytesPerRow();
        const bits_per_pixel = header.bitsPerPixel();

        for (0..pass_count) |p| {
            const pass: u3 = @intCast(p);
            const data = pass_data[p];
            if (data.len == 0) continue;

            const pass_w = passWidth(pass, header.width);
            const pass_h = passHeight(pass, header.height);
            if (pass_w == 0 or pass_h == 0) continue;

            const pass_row_bytes = passRowBytes(pass, header);

            for (0..pass_h) |pass_y| {
                const src_row_start = pass_y * pass_row_bytes;
                const image_y = passToImageY(pass, @intCast(pass_y));
                const dst_row_start = image_y * output_row_bytes;

                if (bits_per_pixel >= 8) {
                    // Byte-aligned pixels - straightforward copy
                    for (0..pass_w) |pass_x| {
                        const image_x = passToImageX(pass, @intCast(pass_x));
                        const src_offset = src_row_start + pass_x * bpp;
                        const dst_offset = dst_row_start + image_x * bpp;
                        @memcpy(output[dst_offset..][0..bpp], data[src_offset..][0..bpp]);
                    }
                } else {
                    // Sub-byte pixels - need bit manipulation
                    deinterlaceSubByte(
                        data[src_row_start..][0..pass_row_bytes],
                        output[dst_row_start..][0..output_row_bytes],
                        pass,
                        pass_w,
                        bits_per_pixel,
                        header.width,
                    );
                }
            }
        }
    }

    /// Handle sub-byte pixel deinterlacing (1, 2, or 4 bits per pixel).
    fn deinterlaceSubByte(
        src_row: []const u8,
        dst_row: []u8,
        pass: u3,
        pass_w: u32,
        bits_per_pixel: u8,
        image_width: u32,
    ) void {
        _ = image_width;
        const pixels_per_byte = 8 / bits_per_pixel;
        const mask: u8 = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;

        for (0..pass_w) |pass_x| {
            // Extract pixel from source
            const src_byte_idx = pass_x / pixels_per_byte;
            const src_bit_offset: u3 = @intCast(8 - bits_per_pixel - (pass_x % pixels_per_byte) * bits_per_pixel);
            const pixel_value = (src_row[src_byte_idx] >> src_bit_offset) & mask;

            // Calculate destination position
            const image_x = passToImageX(pass, @intCast(pass_x));
            const dst_byte_idx = image_x / pixels_per_byte;
            const dst_bit_offset: u3 = @intCast(8 - bits_per_pixel - (image_x % pixels_per_byte) * bits_per_pixel);

            // Clear and set the pixel in destination
            const clear_mask = ~(@as(u8, mask) << dst_bit_offset);
            dst_row[dst_byte_idx] = (dst_row[dst_byte_idx] & clear_mask) | (@as(u8, pixel_value) << dst_bit_offset);
        }
    }

    /// Interlace a full image into separate passes.
    ///
    /// This is the inverse of deinterlace - it takes a complete image
    /// and extracts the pixels for each Adam7 pass.
    ///
    /// Each pass buffer in `pass_output` must be pre-allocated to
    /// passRowBytes(pass, header) * passHeight(pass, header) bytes.
    /// Passes with no pixels should have empty slices.
    pub fn interlace(
        input: []const u8,
        pass_output: *[7][]u8,
        header: critical.Header,
    ) void {
        const bpp = header.bytesPerPixel();
        const input_row_bytes = header.bytesPerRow();
        const bits_per_pixel = header.bitsPerPixel();

        for (0..pass_count) |p| {
            const pass: u3 = @intCast(p);
            const data = pass_output[p];
            if (data.len == 0) continue;

            const pass_w = passWidth(pass, header.width);
            const pass_h = passHeight(pass, header.height);
            if (pass_w == 0 or pass_h == 0) continue;

            const pass_row_bytes = passRowBytes(pass, header);

            for (0..pass_h) |pass_y| {
                const dst_row_start = pass_y * pass_row_bytes;
                const image_y = passToImageY(pass, @intCast(pass_y));
                const src_row_start = image_y * input_row_bytes;

                if (bits_per_pixel >= 8) {
                    // Byte-aligned pixels
                    for (0..pass_w) |pass_x| {
                        const image_x = passToImageX(pass, @intCast(pass_x));
                        const src_offset = src_row_start + image_x * bpp;
                        const dst_offset = dst_row_start + pass_x * bpp;
                        @memcpy(data[dst_offset..][0..bpp], input[src_offset..][0..bpp]);
                    }
                } else {
                    // Sub-byte pixels
                    interlaceSubByte(
                        input[src_row_start..][0..input_row_bytes],
                        data[dst_row_start..][0..pass_row_bytes],
                        pass,
                        pass_w,
                        bits_per_pixel,
                    );
                }
            }
        }
    }

    /// Handle sub-byte pixel interlacing (1, 2, or 4 bits per pixel).
    fn interlaceSubByte(
        src_row: []const u8,
        dst_row: []u8,
        pass: u3,
        pass_w: u32,
        bits_per_pixel: u8,
    ) void {
        const pixels_per_byte = 8 / bits_per_pixel;
        const mask: u8 = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;

        // Clear destination row
        @memset(dst_row, 0);

        for (0..pass_w) |pass_x| {
            // Calculate source position in full image
            const image_x = passToImageX(pass, @intCast(pass_x));
            const src_byte_idx = image_x / pixels_per_byte;
            const src_bit_offset: u3 = @intCast(8 - bits_per_pixel - (image_x % pixels_per_byte) * bits_per_pixel);
            const pixel_value = (src_row[src_byte_idx] >> src_bit_offset) & mask;

            // Place in destination pass row
            const dst_byte_idx = pass_x / pixels_per_byte;
            const dst_bit_offset: u3 = @intCast(8 - bits_per_pixel - (pass_x % pixels_per_byte) * bits_per_pixel);
            dst_row[dst_byte_idx] |= pixel_value << dst_bit_offset;
        }
    }
};

// Tests

test "passWidth 8x8 image" {
    // For an 8x8 image:
    // Pass 0: x=0, spacing=8 -> 1 pixel (x=0)
    // Pass 1: x=4, spacing=8 -> 1 pixel (x=4)
    // Pass 2: x=0, spacing=4 -> 2 pixels (x=0,4)
    // Pass 3: x=2, spacing=4 -> 2 pixels (x=2,6)
    // Pass 4: x=0, spacing=2 -> 4 pixels (x=0,2,4,6)
    // Pass 5: x=1, spacing=2 -> 4 pixels (x=1,3,5,7)
    // Pass 6: x=0, spacing=1 -> 8 pixels (all)
    try std.testing.expectEqual(@as(u32, 1), Adam7.passWidth(0, 8));
    try std.testing.expectEqual(@as(u32, 1), Adam7.passWidth(1, 8));
    try std.testing.expectEqual(@as(u32, 2), Adam7.passWidth(2, 8));
    try std.testing.expectEqual(@as(u32, 2), Adam7.passWidth(3, 8));
    try std.testing.expectEqual(@as(u32, 4), Adam7.passWidth(4, 8));
    try std.testing.expectEqual(@as(u32, 4), Adam7.passWidth(5, 8));
    try std.testing.expectEqual(@as(u32, 8), Adam7.passWidth(6, 8));
}

test "passHeight 8x8 image" {
    // For an 8x8 image:
    // Pass 0: y=0, spacing=8 -> 1 row (y=0)
    // Pass 1: y=0, spacing=8 -> 1 row (y=0)
    // Pass 2: y=4, spacing=8 -> 1 row (y=4)
    // Pass 3: y=0, spacing=4 -> 2 rows (y=0,4)
    // Pass 4: y=2, spacing=4 -> 2 rows (y=2,6)
    // Pass 5: y=0, spacing=2 -> 4 rows (y=0,2,4,6)
    // Pass 6: y=1, spacing=2 -> 4 rows (y=1,3,5,7)
    try std.testing.expectEqual(@as(u32, 1), Adam7.passHeight(0, 8));
    try std.testing.expectEqual(@as(u32, 1), Adam7.passHeight(1, 8));
    try std.testing.expectEqual(@as(u32, 1), Adam7.passHeight(2, 8));
    try std.testing.expectEqual(@as(u32, 2), Adam7.passHeight(3, 8));
    try std.testing.expectEqual(@as(u32, 2), Adam7.passHeight(4, 8));
    try std.testing.expectEqual(@as(u32, 4), Adam7.passHeight(5, 8));
    try std.testing.expectEqual(@as(u32, 4), Adam7.passHeight(6, 8));
}

test "pass dimensions for small images" {
    // 1x1 image: only pass 0 has pixels
    try std.testing.expectEqual(@as(u32, 1), Adam7.passWidth(0, 1));
    try std.testing.expectEqual(@as(u32, 1), Adam7.passHeight(0, 1));
    // Other passes have no pixels
    try std.testing.expectEqual(@as(u32, 0), Adam7.passWidth(1, 1));
    try std.testing.expectEqual(@as(u32, 0), Adam7.passHeight(2, 1));

    // 4x4 image
    try std.testing.expectEqual(@as(u32, 1), Adam7.passWidth(0, 4));
    try std.testing.expectEqual(@as(u32, 0), Adam7.passWidth(1, 4)); // x=4 >= width
    try std.testing.expectEqual(@as(u32, 1), Adam7.passWidth(2, 4));
    try std.testing.expectEqual(@as(u32, 1), Adam7.passWidth(3, 4));
    try std.testing.expectEqual(@as(u32, 2), Adam7.passWidth(4, 4));
    try std.testing.expectEqual(@as(u32, 2), Adam7.passWidth(5, 4));
    try std.testing.expectEqual(@as(u32, 4), Adam7.passWidth(6, 4));
}

test "passWidth and passHeight with zero" {
    try std.testing.expectEqual(@as(u32, 0), Adam7.passWidth(0, 0));
    try std.testing.expectEqual(@as(u32, 0), Adam7.passHeight(0, 0));
}

test "passToImageX and passToImageY" {
    // Pass 0 pixel 0 -> image x=0
    try std.testing.expectEqual(@as(u32, 0), Adam7.passToImageX(0, 0));
    // Pass 1 pixel 0 -> image x=4
    try std.testing.expectEqual(@as(u32, 4), Adam7.passToImageX(1, 0));
    // Pass 2 pixel 1 -> image x=4 (0 + 1*4)
    try std.testing.expectEqual(@as(u32, 4), Adam7.passToImageX(2, 1));
    // Pass 6 pixel 3 -> image x=3 (0 + 3*1)
    try std.testing.expectEqual(@as(u32, 3), Adam7.passToImageX(6, 3));

    // Pass 0 row 0 -> image y=0
    try std.testing.expectEqual(@as(u32, 0), Adam7.passToImageY(0, 0));
    // Pass 2 row 0 -> image y=4
    try std.testing.expectEqual(@as(u32, 4), Adam7.passToImageY(2, 0));
    // Pass 6 row 2 -> image y=5 (1 + 2*2)
    try std.testing.expectEqual(@as(u32, 5), Adam7.passToImageY(6, 2));
}

test "passRowBytes" {
    const header = critical.Header{
        .width = 8,
        .height = 8,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    // 8-bit grayscale: 1 byte per pixel
    try std.testing.expectEqual(@as(usize, 1), Adam7.passRowBytes(0, header)); // 1 pixel
    try std.testing.expectEqual(@as(usize, 1), Adam7.passRowBytes(1, header)); // 1 pixel
    try std.testing.expectEqual(@as(usize, 2), Adam7.passRowBytes(2, header)); // 2 pixels
    try std.testing.expectEqual(@as(usize, 2), Adam7.passRowBytes(3, header)); // 2 pixels
    try std.testing.expectEqual(@as(usize, 4), Adam7.passRowBytes(4, header)); // 4 pixels
    try std.testing.expectEqual(@as(usize, 4), Adam7.passRowBytes(5, header)); // 4 pixels
    try std.testing.expectEqual(@as(usize, 8), Adam7.passRowBytes(6, header)); // 8 pixels
}

test "passRowBytes RGB" {
    const header = critical.Header{
        .width = 8,
        .height = 8,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    // 8-bit RGB: 3 bytes per pixel
    try std.testing.expectEqual(@as(usize, 3), Adam7.passRowBytes(0, header)); // 1 pixel
    try std.testing.expectEqual(@as(usize, 6), Adam7.passRowBytes(2, header)); // 2 pixels
    try std.testing.expectEqual(@as(usize, 24), Adam7.passRowBytes(6, header)); // 8 pixels
}

test "totalInterlacedBytes" {
    const header = critical.Header{
        .width = 8,
        .height = 8,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    // Pass 0: 1x1 = 2 bytes (1 + filter)
    // Pass 1: 1x1 = 2 bytes
    // Pass 2: 2x1 = 3 bytes (2 + filter)
    // Pass 3: 2x2 = 6 bytes (2*3)
    // Pass 4: 4x2 = 10 bytes (2*5)
    // Pass 5: 4x4 = 20 bytes (4*5)
    // Pass 6: 8x4 = 36 bytes (4*9)
    // Total: 2+2+3+6+10+20+36 = 79 bytes
    const total = Adam7.totalInterlacedBytes(header);
    try std.testing.expectEqual(@as(usize, 79), total);
}

test "deinterlace 8x8 grayscale" {
    // Create a simple 8x8 grayscale image where each pixel's value
    // is its linear index (0-63)
    const header = critical.Header{
        .width = 8,
        .height = 8,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    // Expected pattern from pass numbers:
    // 1 6 4 6 2 6 4 6   row 0
    // 7 7 7 7 7 7 7 7   row 1
    // 5 6 5 6 5 6 5 6   row 2
    // 7 7 7 7 7 7 7 7   row 3
    // 3 6 4 6 3 6 4 6   row 4
    // 7 7 7 7 7 7 7 7   row 5
    // 5 6 5 6 5 6 5 6   row 6
    // 7 7 7 7 7 7 7 7   row 7

    // Pass 0: (0,0) = pixel 0
    const pass0 = [_]u8{0};

    // Pass 1: (4,0) = pixel 4
    const pass1 = [_]u8{4};

    // Pass 2: (0,4), (4,4) = pixels 32, 36
    const pass2 = [_]u8{ 32, 36 };

    // Pass 3: row 0 (2,6), row 4 (2,6)
    // (2,0)=2, (6,0)=6, (2,4)=34, (6,4)=38
    const pass3 = [_]u8{ 2, 6, 34, 38 };

    // Pass 4: rows 2,6, cols 0,2,4,6
    // (0,2)=16, (2,2)=18, (4,2)=20, (6,2)=22
    // (0,6)=48, (2,6)=50, (4,6)=52, (6,6)=54
    const pass4 = [_]u8{ 16, 18, 20, 22, 48, 50, 52, 54 };

    // Pass 5: rows 0,2,4,6, cols 1,3,5,7
    // row 0: (1,0)=1, (3,0)=3, (5,0)=5, (7,0)=7
    // row 2: (1,2)=17, (3,2)=19, (5,2)=21, (7,2)=23
    // row 4: (1,4)=33, (3,4)=35, (5,4)=37, (7,4)=39
    // row 6: (1,6)=49, (3,6)=51, (5,6)=53, (7,6)=55
    const pass5 = [_]u8{ 1, 3, 5, 7, 17, 19, 21, 23, 33, 35, 37, 39, 49, 51, 53, 55 };

    // Pass 6: rows 1,3,5,7, all cols
    // row 1: 8-15
    // row 3: 24-31
    // row 5: 40-47
    // row 7: 56-63
    const pass6 = [_]u8{ 8, 9, 10, 11, 12, 13, 14, 15, 24, 25, 26, 27, 28, 29, 30, 31, 40, 41, 42, 43, 44, 45, 46, 47, 56, 57, 58, 59, 60, 61, 62, 63 };

    var output: [64]u8 = undefined;
    @memset(&output, 0xFF); // Fill with sentinel to detect errors

    Adam7.deinterlace(.{
        &pass0,
        &pass1,
        &pass2,
        &pass3,
        &pass4,
        &pass5,
        &pass6,
    }, &output, header);

    // Verify all pixels are in correct positions
    for (0..64) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), output[i]);
    }
}

test "interlace roundtrip" {
    const header = critical.Header{
        .width = 8,
        .height = 8,
        .bit_depth = .@"8",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    // Create sequential pixel values
    var original: [64]u8 = undefined;
    for (0..64) |i| {
        original[i] = @intCast(i);
    }

    // Allocate pass buffers
    var pass0: [1]u8 = undefined;
    var pass1: [1]u8 = undefined;
    var pass2: [2]u8 = undefined;
    var pass3: [4]u8 = undefined;
    var pass4: [8]u8 = undefined;
    var pass5: [16]u8 = undefined;
    var pass6: [32]u8 = undefined;

    var passes = [7][]u8{
        &pass0,
        &pass1,
        &pass2,
        &pass3,
        &pass4,
        &pass5,
        &pass6,
    };

    // Interlace
    Adam7.interlace(&original, &passes, header);

    // Deinterlace back
    var recovered: [64]u8 = undefined;
    @memset(&recovered, 0xFF);

    Adam7.deinterlace(.{
        &pass0,
        &pass1,
        &pass2,
        &pass3,
        &pass4,
        &pass5,
        &pass6,
    }, &recovered, header);

    // Should match original
    try std.testing.expectEqualSlices(u8, &original, &recovered);
}

test "sub-byte interlace roundtrip 4-bit" {
    const header = critical.Header{
        .width = 8,
        .height = 8,
        .bit_depth = .@"4",
        .color_type = .grayscale,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    // 4-bit grayscale: 8 pixels = 4 bytes per row, 32 bytes total
    var original: [32]u8 = undefined;
    // Fill with pattern: each pixel = position mod 16
    for (0..8) |y| {
        for (0..8) |x| {
            const idx = y * 4 + x / 2;
            const val: u8 = @intCast((y * 8 + x) % 16);
            if (x % 2 == 0) {
                original[idx] = val << 4;
            } else {
                original[idx] |= val;
            }
        }
    }

    // Calculate pass sizes for 4-bit
    // Pass 0: 1x1 = 1 byte (1 pixel, rounded up)
    // Pass 1: 1x1 = 1 byte
    // Pass 2: 2x1 = 1 byte (2 pixels)
    // Pass 3: 2x2 = 2 bytes (2 rows * 1 byte)
    // Pass 4: 4x2 = 4 bytes (2 rows * 2 bytes)
    // Pass 5: 4x4 = 8 bytes (4 rows * 2 bytes)
    // Pass 6: 8x4 = 16 bytes (4 rows * 4 bytes)
    var pass0: [1]u8 = undefined;
    var pass1: [1]u8 = undefined;
    var pass2: [1]u8 = undefined;
    var pass3: [2]u8 = undefined;
    var pass4: [4]u8 = undefined;
    var pass5: [8]u8 = undefined;
    var pass6: [16]u8 = undefined;

    var passes = [7][]u8{
        &pass0,
        &pass1,
        &pass2,
        &pass3,
        &pass4,
        &pass5,
        &pass6,
    };

    Adam7.interlace(&original, &passes, header);

    var recovered: [32]u8 = undefined;
    @memset(&recovered, 0);

    Adam7.deinterlace(.{
        &pass0,
        &pass1,
        &pass2,
        &pass3,
        &pass4,
        &pass5,
        &pass6,
    }, &recovered, header);

    try std.testing.expectEqualSlices(u8, &original, &recovered);
}
