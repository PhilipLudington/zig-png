//! Critical PNG chunk parsing (IHDR, PLTE, IDAT, IEND).
//!
//! These chunks are required for correct PNG rendering.

const std = @import("std");
const color = @import("../color.zig");

const ColorType = color.ColorType;
const BitDepth = color.BitDepth;
const InterlaceMethod = color.InterlaceMethod;
const CompressionMethod = color.CompressionMethod;
const FilterMethod = color.FilterMethod;

/// Errors that can occur during header parsing.
pub const HeaderError = error{
    InvalidLength,
    InvalidWidth,
    InvalidHeight,
    InvalidBitDepth,
    InvalidColorType,
    InvalidCompressionMethod,
    InvalidFilterMethod,
    InvalidInterlaceMethod,
    InvalidColorBitDepthCombo,
};

/// PNG image header containing all IHDR information.
pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: BitDepth,
    color_type: ColorType,
    compression_method: CompressionMethod,
    filter_method: FilterMethod,
    interlace_method: InterlaceMethod,

    const Self = @This();

    /// Parse IHDR data into a Header struct.
    pub fn parse(data: []const u8) HeaderError!Self {
        if (data.len != 13) {
            return error.InvalidLength;
        }

        // Width (4 bytes, big-endian)
        const width = std.mem.readInt(u32, data[0..4], .big);
        if (width == 0 or width > color.max_dimension) {
            return error.InvalidWidth;
        }

        // Height (4 bytes, big-endian)
        const height = std.mem.readInt(u32, data[4..8], .big);
        if (height == 0 or height > color.max_dimension) {
            return error.InvalidHeight;
        }

        // Check total pixel count doesn't exceed limit
        const total_pixels = @as(u64, width) * @as(u64, height);
        if (total_pixels > color.max_pixels) {
            return error.InvalidHeight; // Use existing error for dimensions too large
        }

        // Bit depth (1 byte)
        const bit_depth = BitDepth.fromByte(data[8]) orelse {
            return error.InvalidBitDepth;
        };

        // Color type (1 byte)
        const color_type = ColorType.fromByte(data[9]) orelse {
            return error.InvalidColorType;
        };

        // Validate color type / bit depth combination
        if (!color.isValidColorBitDepthCombo(color_type, bit_depth)) {
            return error.InvalidColorBitDepthCombo;
        }

        // Compression method (1 byte) - must be 0
        const compression_method = CompressionMethod.fromByte(data[10]) orelse {
            return error.InvalidCompressionMethod;
        };

        // Filter method (1 byte) - must be 0
        const filter_method = FilterMethod.fromByte(data[11]) orelse {
            return error.InvalidFilterMethod;
        };

        // Interlace method (1 byte) - 0 or 1
        const interlace_method = InterlaceMethod.fromByte(data[12]) orelse {
            return error.InvalidInterlaceMethod;
        };

        return Self{
            .width = width,
            .height = height,
            .bit_depth = bit_depth,
            .color_type = color_type,
            .compression_method = compression_method,
            .filter_method = filter_method,
            .interlace_method = interlace_method,
        };
    }

    /// Calculate bits per pixel for this header's format.
    pub fn bitsPerPixel(self: Self) u8 {
        return color.bitsPerPixel(self.color_type, self.bit_depth);
    }

    /// Calculate bytes per pixel (minimum 1 for sub-byte formats).
    pub fn bytesPerPixel(self: Self) u8 {
        return color.bytesPerPixel(self.color_type, self.bit_depth);
    }

    /// Calculate bytes per row (not including filter byte).
    /// Returns error.Overflow if the calculation would overflow.
    pub fn bytesPerRow(self: Self) color.SizeError!usize {
        return color.bytesPerRow(self.width, self.color_type, self.bit_depth);
    }

    /// Calculate total bytes per row including filter byte.
    /// Returns error.Overflow if the calculation would overflow.
    pub fn bytesPerRowWithFilter(self: Self) color.SizeError!usize {
        const row_bytes = try self.bytesPerRow();
        return std.math.add(usize, row_bytes, 1) catch return error.Overflow;
    }

    /// Calculate total raw image data size (after decompression, before unfiltering).
    /// This is the size of all scanlines including filter bytes.
    /// Returns error.Overflow if the calculation would overflow.
    pub fn rawDataSize(self: Self) color.SizeError!usize {
        const row_with_filter = try self.bytesPerRowWithFilter();
        return std.math.mul(usize, row_with_filter, self.height) catch return error.Overflow;
    }

    /// Check if this header represents an interlaced image.
    pub fn isInterlaced(self: Self) bool {
        return self.interlace_method == .adam7;
    }

    /// Serialize header back to IHDR chunk data.
    pub fn serialize(self: Self) [13]u8 {
        var data: [13]u8 = undefined;
        std.mem.writeInt(u32, data[0..4], self.width, .big);
        std.mem.writeInt(u32, data[4..8], self.height, .big);
        data[8] = self.bit_depth.toInt();
        data[9] = @intFromEnum(self.color_type);
        data[10] = @intFromEnum(self.compression_method);
        data[11] = @intFromEnum(self.filter_method);
        data[12] = @intFromEnum(self.interlace_method);
        return data;
    }
};

/// RGB color entry for palette.
pub const PaletteEntry = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Parse PLTE (palette) chunk data.
pub fn parsePlte(data: []const u8) error{ InvalidLength, InvalidPaletteSize }![]const PaletteEntry {
    if (data.len == 0 or data.len % 3 != 0) {
        return error.InvalidLength;
    }

    const count = data.len / 3;
    if (count > 256) {
        return error.InvalidPaletteSize;
    }

    // Return as slice of PaletteEntry (reinterpret the bytes)
    // Note: This works because PaletteEntry is packed RGB
    const entries: [*]const PaletteEntry = @ptrCast(@alignCast(data.ptr));
    return entries[0..count];
}

// Tests

test "Header.parse valid IHDR" {
    // 16x16 RGB 8-bit non-interlaced
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // width = 16
        0x00, 0x00, 0x00, 0x10, // height = 16
        0x08, // bit depth = 8
        0x02, // color type = RGB
        0x00, // compression = 0
        0x00, // filter = 0
        0x00, // interlace = 0
    };

    const header = try Header.parse(&data);
    try std.testing.expectEqual(@as(u32, 16), header.width);
    try std.testing.expectEqual(@as(u32, 16), header.height);
    try std.testing.expectEqual(BitDepth.@"8", header.bit_depth);
    try std.testing.expectEqual(ColorType.rgb, header.color_type);
    try std.testing.expectEqual(InterlaceMethod.none, header.interlace_method);
}

test "Header.parse with interlace" {
    const data = [_]u8{
        0x00, 0x00, 0x01, 0x00, // width = 256
        0x00, 0x00, 0x00, 0x80, // height = 128
        0x08, // bit depth = 8
        0x06, // color type = RGBA
        0x00, // compression = 0
        0x00, // filter = 0
        0x01, // interlace = Adam7
    };

    const header = try Header.parse(&data);
    try std.testing.expectEqual(@as(u32, 256), header.width);
    try std.testing.expectEqual(@as(u32, 128), header.height);
    try std.testing.expectEqual(ColorType.rgba, header.color_type);
    try std.testing.expect(header.isInterlaced());
}

test "Header.parse invalid length" {
    const data = [_]u8{ 0x00, 0x00 }; // Too short
    try std.testing.expectError(error.InvalidLength, Header.parse(&data));
}

test "Header.parse zero dimensions" {
    var data = [_]u8{
        0x00, 0x00, 0x00, 0x00, // width = 0 (invalid)
        0x00, 0x00, 0x00, 0x10,
        0x08, 0x02, 0x00, 0x00,
        0x00,
    };
    try std.testing.expectError(error.InvalidWidth, Header.parse(&data));

    data[0..4].* = .{ 0x00, 0x00, 0x00, 0x10 };
    data[4..8].* = .{ 0x00, 0x00, 0x00, 0x00 }; // height = 0 (invalid)
    try std.testing.expectError(error.InvalidHeight, Header.parse(&data));
}

test "Header.parse invalid bit depth" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10,
        0x00, 0x00, 0x00, 0x10,
        0x03, // bit depth = 3 (invalid)
        0x02,
        0x00,
        0x00,
        0x00,
    };
    try std.testing.expectError(error.InvalidBitDepth, Header.parse(&data));
}

test "Header.parse invalid color/depth combo" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10,
        0x00, 0x00, 0x00, 0x10,
        0x04, // bit depth = 4
        0x02, // color type = RGB (doesn't support 4-bit)
        0x00,
        0x00,
        0x00,
    };
    try std.testing.expectError(error.InvalidColorBitDepthCombo, Header.parse(&data));
}

test "Header helper methods" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x64, // width = 100
        0x00, 0x00, 0x00, 0x32, // height = 50
        0x08, // bit depth = 8
        0x06, // color type = RGBA (4 samples)
        0x00,
        0x00,
        0x00,
    };

    const header = try Header.parse(&data);

    // RGBA 8-bit = 32 bits = 4 bytes per pixel
    try std.testing.expectEqual(@as(u8, 32), header.bitsPerPixel());
    try std.testing.expectEqual(@as(u8, 4), header.bytesPerPixel());

    // 100 pixels * 4 bytes = 400 bytes per row
    try std.testing.expectEqual(@as(usize, 400), try header.bytesPerRow());

    // Including filter byte
    try std.testing.expectEqual(@as(usize, 401), try header.bytesPerRowWithFilter());

    // Total raw data = 401 * 50 = 20050 bytes
    try std.testing.expectEqual(@as(usize, 20050), try header.rawDataSize());
}

test "Header rejects dimensions exceeding limits" {
    // Width too large
    var data = [_]u8{
        0x40, 0x00, 0x00, 0x00, // width = 0x40000000 (> 1 billion)
        0x00, 0x00, 0x00, 0x10, // height = 16
        0x08, 0x02, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(error.InvalidWidth, Header.parse(&data));

    // Height too large
    data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // width = 16
        0x40, 0x00, 0x00, 0x00, // height = 0x40000000 (> 1 billion)
        0x08, 0x02, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(error.InvalidHeight, Header.parse(&data));

    // Total pixels too large (both dimensions valid individually but product too large)
    data = [_]u8{
        0x00, 0x01, 0x00, 0x00, // width = 65536
        0x00, 0x01, 0x00, 0x00, // height = 65536 (total = 4 billion+ pixels)
        0x08, 0x02, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(error.InvalidHeight, Header.parse(&data));
}

test "Header.serialize roundtrip" {
    const original = Header{
        .width = 1920,
        .height = 1080,
        .bit_depth = .@"16",
        .color_type = .rgba,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .adam7,
    };

    const serialized = original.serialize();
    const parsed = try Header.parse(&serialized);

    try std.testing.expectEqual(original.width, parsed.width);
    try std.testing.expectEqual(original.height, parsed.height);
    try std.testing.expectEqual(original.bit_depth, parsed.bit_depth);
    try std.testing.expectEqual(original.color_type, parsed.color_type);
    try std.testing.expectEqual(original.interlace_method, parsed.interlace_method);
}

test "parsePlte valid" {
    // 3 colors (9 bytes)
    const data = [_]u8{
        255, 0, 0, // Red
        0, 255, 0, // Green
        0, 0, 255, // Blue
    };

    const palette = try parsePlte(&data);
    try std.testing.expectEqual(@as(usize, 3), palette.len);
    try std.testing.expectEqual(@as(u8, 255), palette[0].r);
    try std.testing.expectEqual(@as(u8, 0), palette[0].g);
    try std.testing.expectEqual(@as(u8, 0), palette[0].b);
    try std.testing.expectEqual(@as(u8, 0), palette[2].r);
    try std.testing.expectEqual(@as(u8, 0), palette[2].g);
    try std.testing.expectEqual(@as(u8, 255), palette[2].b);
}

test "parsePlte invalid length" {
    // 4 bytes is not divisible by 3
    const data = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectError(error.InvalidLength, parsePlte(&data));

    // Empty is invalid
    try std.testing.expectError(error.InvalidLength, parsePlte(&[_]u8{}));
}

/// Serialize a palette to PLTE chunk data.
/// Returns a slice of the provided buffer containing the serialized palette.
pub fn serializePlte(palette: []const PaletteEntry, buffer: []u8) error{BufferTooSmall}![]u8 {
    const required_size = palette.len * 3;
    if (buffer.len < required_size) {
        return error.BufferTooSmall;
    }

    var pos: usize = 0;
    for (palette) |entry| {
        buffer[pos] = entry.r;
        buffer[pos + 1] = entry.g;
        buffer[pos + 2] = entry.b;
        pos += 3;
    }

    return buffer[0..pos];
}

test "serializePlte" {
    const palette = [_]PaletteEntry{
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
    };
    var buffer: [9]u8 = undefined;

    const result = try serializePlte(&palette, &buffer);
    try std.testing.expectEqual(@as(usize, 9), result.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 }, result);
}

test "serializePlte roundtrip" {
    const original = [_]PaletteEntry{
        .{ .r = 128, .g = 64, .b = 32 },
        .{ .r = 16, .g = 8, .b = 4 },
    };
    var buffer: [6]u8 = undefined;

    const serialized = try serializePlte(&original, &buffer);
    const parsed = try parsePlte(serialized);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(original[0].r, parsed[0].r);
    try std.testing.expectEqual(original[1].b, parsed[1].b);
}

test "serializePlte buffer too small" {
    const palette = [_]PaletteEntry{
        .{ .r = 255, .g = 0, .b = 0 },
    };
    var buffer: [2]u8 = undefined;

    try std.testing.expectError(error.BufferTooSmall, serializePlte(&palette, &buffer));
}
