//! Core PNG types for color representation.
//!
//! Defines the fundamental types used throughout the PNG library:
//! ColorType, BitDepth, InterlaceMethod, FilterType, and helper functions.

const std = @import("std");

/// PNG color types as defined in the PNG specification.
pub const ColorType = enum(u8) {
    /// Grayscale (1, 2, 4, 8, or 16 bits per sample)
    grayscale = 0,
    /// RGB truecolor (8 or 16 bits per sample)
    rgb = 2,
    /// Indexed-color with palette (1, 2, 4, or 8 bits per sample)
    indexed = 3,
    /// Grayscale with alpha (8 or 16 bits per sample)
    grayscale_alpha = 4,
    /// RGB with alpha (8 or 16 bits per sample)
    rgba = 6,

    /// Convert from raw byte value.
    pub fn fromByte(byte: u8) ?ColorType {
        return switch (byte) {
            0 => .grayscale,
            2 => .rgb,
            3 => .indexed,
            4 => .grayscale_alpha,
            6 => .rgba,
            else => null,
        };
    }

    /// Number of samples (channels) per pixel for this color type.
    pub fn sampleCount(self: ColorType) u8 {
        return switch (self) {
            .grayscale => 1,
            .rgb => 3,
            .indexed => 1, // Palette index is single value
            .grayscale_alpha => 2,
            .rgba => 4,
        };
    }

    /// Whether this color type uses a palette.
    pub fn usesPalette(self: ColorType) bool {
        return self == .indexed;
    }

    /// Whether this color type has an alpha channel.
    pub fn hasAlpha(self: ColorType) bool {
        return self == .grayscale_alpha or self == .rgba;
    }
};

/// PNG bit depths as defined in the PNG specification.
pub const BitDepth = enum(u8) {
    @"1" = 1,
    @"2" = 2,
    @"4" = 4,
    @"8" = 8,
    @"16" = 16,

    /// Convert from raw byte value.
    pub fn fromByte(byte: u8) ?BitDepth {
        return switch (byte) {
            1 => .@"1",
            2 => .@"2",
            4 => .@"4",
            8 => .@"8",
            16 => .@"16",
            else => null,
        };
    }

    /// Get the numeric value.
    pub fn toInt(self: BitDepth) u8 {
        return @intFromEnum(self);
    }
};

/// PNG interlacing methods.
pub const InterlaceMethod = enum(u8) {
    /// No interlacing
    none = 0,
    /// Adam7 interlacing (7-pass progressive)
    adam7 = 1,

    /// Convert from raw byte value.
    pub fn fromByte(byte: u8) ?InterlaceMethod {
        return switch (byte) {
            0 => .none,
            1 => .adam7,
            else => null,
        };
    }
};

/// PNG filter types applied to each scanline.
pub const FilterType = enum(u8) {
    /// No filtering
    none = 0,
    /// Difference from byte to the left
    sub = 1,
    /// Difference from byte above
    up = 2,
    /// Difference from average of left and above
    average = 3,
    /// Paeth predictor
    paeth = 4,

    /// Convert from raw byte value.
    pub fn fromByte(byte: u8) ?FilterType {
        return switch (byte) {
            0 => .none,
            1 => .sub,
            2 => .up,
            3 => .average,
            4 => .paeth,
            else => null,
        };
    }
};

/// Compression method (only deflate/inflate is defined).
pub const CompressionMethod = enum(u8) {
    deflate = 0,

    pub fn fromByte(byte: u8) ?CompressionMethod {
        return switch (byte) {
            0 => .deflate,
            else => null,
        };
    }
};

/// Filter method (only adaptive filtering is defined).
pub const FilterMethod = enum(u8) {
    adaptive = 0,

    pub fn fromByte(byte: u8) ?FilterMethod {
        return switch (byte) {
            0 => .adaptive,
            else => null,
        };
    }
};

/// Check if a color type and bit depth combination is valid per PNG spec.
pub fn isValidColorBitDepthCombo(color_type: ColorType, bit_depth: BitDepth) bool {
    const depth = bit_depth.toInt();
    return switch (color_type) {
        .grayscale => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        .rgb => depth == 8 or depth == 16,
        .indexed => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        .grayscale_alpha => depth == 8 or depth == 16,
        .rgba => depth == 8 or depth == 16,
    };
}

/// Calculate bytes per pixel for a given color type and bit depth.
/// Returns 0 for sub-byte depths (1, 2, 4 bit).
/// For sub-byte depths, use bitsPerPixel() and handle packing separately.
pub fn bytesPerPixel(color_type: ColorType, bit_depth: BitDepth) u8 {
    const bits = bitsPerPixel(color_type, bit_depth);
    if (bits < 8) return 1; // For filtering, sub-byte is treated as 1
    return bits / 8;
}

/// Calculate bits per pixel for a given color type and bit depth.
pub fn bitsPerPixel(color_type: ColorType, bit_depth: BitDepth) u8 {
    return color_type.sampleCount() * bit_depth.toInt();
}

/// Calculate bytes per row (scanline) for given dimensions and color info.
/// Does not include the filter type byte.
pub fn bytesPerRow(width: u32, color_type: ColorType, bit_depth: BitDepth) usize {
    const bits_per_row = @as(usize, width) * bitsPerPixel(color_type, bit_depth);
    return (bits_per_row + 7) / 8; // Round up to nearest byte
}

// Tests

test "ColorType fromByte" {
    try std.testing.expectEqual(ColorType.grayscale, ColorType.fromByte(0).?);
    try std.testing.expectEqual(ColorType.rgb, ColorType.fromByte(2).?);
    try std.testing.expectEqual(ColorType.indexed, ColorType.fromByte(3).?);
    try std.testing.expectEqual(ColorType.grayscale_alpha, ColorType.fromByte(4).?);
    try std.testing.expectEqual(ColorType.rgba, ColorType.fromByte(6).?);
    try std.testing.expect(ColorType.fromByte(1) == null);
    try std.testing.expect(ColorType.fromByte(5) == null);
    try std.testing.expect(ColorType.fromByte(7) == null);
}

test "ColorType sampleCount" {
    try std.testing.expectEqual(@as(u8, 1), ColorType.grayscale.sampleCount());
    try std.testing.expectEqual(@as(u8, 3), ColorType.rgb.sampleCount());
    try std.testing.expectEqual(@as(u8, 1), ColorType.indexed.sampleCount());
    try std.testing.expectEqual(@as(u8, 2), ColorType.grayscale_alpha.sampleCount());
    try std.testing.expectEqual(@as(u8, 4), ColorType.rgba.sampleCount());
}

test "BitDepth fromByte" {
    try std.testing.expectEqual(BitDepth.@"1", BitDepth.fromByte(1).?);
    try std.testing.expectEqual(BitDepth.@"2", BitDepth.fromByte(2).?);
    try std.testing.expectEqual(BitDepth.@"4", BitDepth.fromByte(4).?);
    try std.testing.expectEqual(BitDepth.@"8", BitDepth.fromByte(8).?);
    try std.testing.expectEqual(BitDepth.@"16", BitDepth.fromByte(16).?);
    try std.testing.expect(BitDepth.fromByte(0) == null);
    try std.testing.expect(BitDepth.fromByte(3) == null);
    try std.testing.expect(BitDepth.fromByte(32) == null);
}

test "InterlaceMethod fromByte" {
    try std.testing.expectEqual(InterlaceMethod.none, InterlaceMethod.fromByte(0).?);
    try std.testing.expectEqual(InterlaceMethod.adam7, InterlaceMethod.fromByte(1).?);
    try std.testing.expect(InterlaceMethod.fromByte(2) == null);
}

test "FilterType fromByte" {
    try std.testing.expectEqual(FilterType.none, FilterType.fromByte(0).?);
    try std.testing.expectEqual(FilterType.sub, FilterType.fromByte(1).?);
    try std.testing.expectEqual(FilterType.up, FilterType.fromByte(2).?);
    try std.testing.expectEqual(FilterType.average, FilterType.fromByte(3).?);
    try std.testing.expectEqual(FilterType.paeth, FilterType.fromByte(4).?);
    try std.testing.expect(FilterType.fromByte(5) == null);
}

test "isValidColorBitDepthCombo" {
    // Valid grayscale depths
    try std.testing.expect(isValidColorBitDepthCombo(.grayscale, .@"1"));
    try std.testing.expect(isValidColorBitDepthCombo(.grayscale, .@"2"));
    try std.testing.expect(isValidColorBitDepthCombo(.grayscale, .@"4"));
    try std.testing.expect(isValidColorBitDepthCombo(.grayscale, .@"8"));
    try std.testing.expect(isValidColorBitDepthCombo(.grayscale, .@"16"));

    // Valid RGB depths (8, 16 only)
    try std.testing.expect(!isValidColorBitDepthCombo(.rgb, .@"1"));
    try std.testing.expect(!isValidColorBitDepthCombo(.rgb, .@"4"));
    try std.testing.expect(isValidColorBitDepthCombo(.rgb, .@"8"));
    try std.testing.expect(isValidColorBitDepthCombo(.rgb, .@"16"));

    // Valid indexed depths (1, 2, 4, 8 only, not 16)
    try std.testing.expect(isValidColorBitDepthCombo(.indexed, .@"1"));
    try std.testing.expect(isValidColorBitDepthCombo(.indexed, .@"4"));
    try std.testing.expect(isValidColorBitDepthCombo(.indexed, .@"8"));
    try std.testing.expect(!isValidColorBitDepthCombo(.indexed, .@"16"));

    // Valid grayscale+alpha depths (8, 16 only)
    try std.testing.expect(!isValidColorBitDepthCombo(.grayscale_alpha, .@"4"));
    try std.testing.expect(isValidColorBitDepthCombo(.grayscale_alpha, .@"8"));
    try std.testing.expect(isValidColorBitDepthCombo(.grayscale_alpha, .@"16"));

    // Valid RGBA depths (8, 16 only)
    try std.testing.expect(!isValidColorBitDepthCombo(.rgba, .@"4"));
    try std.testing.expect(isValidColorBitDepthCombo(.rgba, .@"8"));
    try std.testing.expect(isValidColorBitDepthCombo(.rgba, .@"16"));
}

test "bitsPerPixel" {
    try std.testing.expectEqual(@as(u8, 1), bitsPerPixel(.grayscale, .@"1"));
    try std.testing.expectEqual(@as(u8, 8), bitsPerPixel(.grayscale, .@"8"));
    try std.testing.expectEqual(@as(u8, 16), bitsPerPixel(.grayscale, .@"16"));
    try std.testing.expectEqual(@as(u8, 24), bitsPerPixel(.rgb, .@"8"));
    try std.testing.expectEqual(@as(u8, 48), bitsPerPixel(.rgb, .@"16"));
    try std.testing.expectEqual(@as(u8, 32), bitsPerPixel(.rgba, .@"8"));
    try std.testing.expectEqual(@as(u8, 64), bitsPerPixel(.rgba, .@"16"));
    try std.testing.expectEqual(@as(u8, 8), bitsPerPixel(.indexed, .@"8"));
}

test "bytesPerPixel" {
    try std.testing.expectEqual(@as(u8, 1), bytesPerPixel(.grayscale, .@"1")); // Sub-byte
    try std.testing.expectEqual(@as(u8, 1), bytesPerPixel(.grayscale, .@"8"));
    try std.testing.expectEqual(@as(u8, 2), bytesPerPixel(.grayscale, .@"16"));
    try std.testing.expectEqual(@as(u8, 3), bytesPerPixel(.rgb, .@"8"));
    try std.testing.expectEqual(@as(u8, 6), bytesPerPixel(.rgb, .@"16"));
    try std.testing.expectEqual(@as(u8, 4), bytesPerPixel(.rgba, .@"8"));
    try std.testing.expectEqual(@as(u8, 8), bytesPerPixel(.rgba, .@"16"));
}

test "bytesPerRow" {
    // 8-bit grayscale, 100 pixels = 100 bytes
    try std.testing.expectEqual(@as(usize, 100), bytesPerRow(100, .grayscale, .@"8"));

    // 1-bit grayscale, 10 pixels = 2 bytes (10 bits rounded up)
    try std.testing.expectEqual(@as(usize, 2), bytesPerRow(10, .grayscale, .@"1"));

    // 1-bit grayscale, 8 pixels = 1 byte
    try std.testing.expectEqual(@as(usize, 1), bytesPerRow(8, .grayscale, .@"1"));

    // 24-bit RGB, 100 pixels = 300 bytes
    try std.testing.expectEqual(@as(usize, 300), bytesPerRow(100, .rgb, .@"8"));

    // 32-bit RGBA, 100 pixels = 400 bytes
    try std.testing.expectEqual(@as(usize, 400), bytesPerRow(100, .rgba, .@"8"));
}
