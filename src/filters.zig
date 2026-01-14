//! PNG filter reconstruction (unfiltering).
//!
//! Implements the five PNG filter types for reconstructing scanlines.
//! Each filter type uses a different prediction method to improve compression.

const std = @import("std");

/// PNG filter types as specified in the PNG specification.
pub const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,

    /// Convert a byte to a FilterType, returning null for invalid values.
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

/// Errors that can occur during filter operations.
pub const FilterError = error{
    InvalidFilterType,
    RowTooShort,
};

/// Unfilter a scanline in place.
///
/// The row must include the filter type byte at position 0.
/// The previous row should be the already-unfiltered previous scanline,
/// or null for the first row (which is treated as if previous row was all zeros).
///
/// After unfiltering, row[0] still contains the filter byte, and row[1..] contains
/// the unfiltered pixel data.
pub fn unfilterRow(row: []u8, prev_row: ?[]const u8, bytes_per_pixel: u8) FilterError!void {
    if (row.len < 1) {
        return error.RowTooShort;
    }

    const filter_type = FilterType.fromByte(row[0]) orelse return error.InvalidFilterType;
    const pixels = row[1..];
    const prev_pixels: ?[]const u8 = if (prev_row) |p| p[1..] else null;

    switch (filter_type) {
        .none => {}, // No reconstruction needed
        .sub => unfilterSub(pixels, bytes_per_pixel),
        .up => unfilterUp(pixels, prev_pixels),
        .average => unfilterAverage(pixels, prev_pixels, bytes_per_pixel),
        .paeth => unfilterPaeth(pixels, prev_pixels, bytes_per_pixel),
    }
}

/// Unfilter using Sub filter: add left neighbor.
/// Sub(x) = Raw(x) + Raw(x-bpp)
fn unfilterSub(row: []u8, bpp: u8) void {
    for (bpp..row.len) |i| {
        row[i] = row[i] +% row[i - bpp];
    }
}

/// Unfilter using Up filter: add above neighbor.
/// Up(x) = Raw(x) + Prior(x)
fn unfilterUp(row: []u8, prev_row: ?[]const u8) void {
    if (prev_row) |prev| {
        for (row, 0..) |*byte, i| {
            if (i < prev.len) {
                byte.* = byte.* +% prev[i];
            }
        }
    }
    // If no previous row, the filter reduces to None (prior is all zeros)
}

/// Unfilter using Average filter: add average of left and above.
/// Average(x) = Raw(x) + floor((Raw(x-bpp) + Prior(x))/2)
fn unfilterAverage(row: []u8, prev_row: ?[]const u8, bpp: u8) void {
    for (row, 0..) |*byte, i| {
        const left: u16 = if (i >= bpp) row[i - bpp] else 0;
        const above: u16 = if (prev_row) |prev| (if (i < prev.len) prev[i] else 0) else 0;
        byte.* = byte.* +% @as(u8, @intCast((left + above) >> 1));
    }
}

/// Unfilter using Paeth filter: add Paeth predictor.
/// Paeth(x) = Raw(x) + PaethPredictor(Raw(x-bpp), Prior(x), Prior(x-bpp))
fn unfilterPaeth(row: []u8, prev_row: ?[]const u8, bpp: u8) void {
    for (row, 0..) |*byte, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0; // left
        const b: u8 = if (prev_row) |prev| (if (i < prev.len) prev[i] else 0) else 0; // above
        const c: u8 = if (i >= bpp and prev_row != null) blk: {
            const prev = prev_row.?;
            break :blk if (i - bpp < prev.len) prev[i - bpp] else 0;
        } else 0; // upper-left

        byte.* = byte.* +% paethPredictor(a, b, c);
    }
}

/// Paeth predictor function.
/// Returns the value (a, b, or c) that is closest to p = a + b - c.
pub fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    // Use signed arithmetic for the prediction
    const p: i16 = @as(i16, a) + @as(i16, b) - @as(i16, c);

    const pa = @abs(p - @as(i16, a));
    const pb = @abs(p - @as(i16, b));
    const pc = @abs(p - @as(i16, c));

    if (pa <= pb and pa <= pc) {
        return a;
    } else if (pb <= pc) {
        return b;
    } else {
        return c;
    }
}

// Tests

test "FilterType.fromByte" {
    try std.testing.expectEqual(FilterType.none, FilterType.fromByte(0).?);
    try std.testing.expectEqual(FilterType.sub, FilterType.fromByte(1).?);
    try std.testing.expectEqual(FilterType.up, FilterType.fromByte(2).?);
    try std.testing.expectEqual(FilterType.average, FilterType.fromByte(3).?);
    try std.testing.expectEqual(FilterType.paeth, FilterType.fromByte(4).?);
    try std.testing.expect(FilterType.fromByte(5) == null);
}

test "paethPredictor" {
    // Test cases from PNG specification
    try std.testing.expectEqual(@as(u8, 0), paethPredictor(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(10, 0, 0)); // a closest to 10
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(0, 10, 0)); // b closest to 10
    try std.testing.expectEqual(@as(u8, 0), paethPredictor(0, 0, 10)); // a=b=0, c=10, p=-10, closest is a or b

    // Edge case: all same
    try std.testing.expectEqual(@as(u8, 100), paethPredictor(100, 100, 100));
}

test "unfilterRow None" {
    var row = [_]u8{ 0, 10, 20, 30 }; // filter=None, then pixels
    try unfilterRow(&row, null, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 10, 20, 30 }, &row);
}

test "unfilterRow Sub" {
    // Sub filter: each byte += left byte
    // Input: [filter=1, 10, 5, 3] -> [filter=1, 10, 15, 18]
    var row = [_]u8{ 1, 10, 5, 3 };
    try unfilterRow(&row, null, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 10, 15, 18 }, &row);
}

test "unfilterRow Sub with bpp=3" {
    // With bpp=3, each byte += byte 3 positions left
    var row = [_]u8{ 1, 10, 20, 30, 5, 6, 7 };
    try unfilterRow(&row, null, 3);
    // Bytes 0-3 unchanged (no left neighbor at bpp=3)
    // Byte 4: 5 + 10 = 15
    // Byte 5: 6 + 20 = 26
    // Byte 6: 7 + 30 = 37
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 10, 20, 30, 15, 26, 37 }, &row);
}

test "unfilterRow Up" {
    // Up filter: each byte += corresponding byte in previous row
    var prev = [_]u8{ 0, 100, 50, 25 };
    var row = [_]u8{ 2, 10, 10, 10 };
    try unfilterRow(&row, &prev, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 110, 60, 35 }, &row);
}

test "unfilterRow Up first row" {
    // First row (no previous): Up reduces to None
    var row = [_]u8{ 2, 10, 20, 30 };
    try unfilterRow(&row, null, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 10, 20, 30 }, &row);
}

test "unfilterRow Average" {
    // Average filter: byte += floor((left + above) / 2)
    var prev = [_]u8{ 0, 10, 20, 30 };
    var row = [_]u8{ 3, 5, 5, 5 };
    try unfilterRow(&row, &prev, 1);
    // Byte 0 (pixel 0): 5 + floor((0 + 10)/2) = 5 + 5 = 10
    // Byte 1 (pixel 1): 5 + floor((10 + 20)/2) = 5 + 15 = 20
    // Byte 2 (pixel 2): 5 + floor((20 + 30)/2) = 5 + 25 = 30
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 10, 20, 30 }, &row);
}

test "unfilterRow Paeth" {
    // Paeth filter: byte += paethPredictor(left, above, upper-left)
    var prev = [_]u8{ 0, 10, 20, 30 };
    var row = [_]u8{ 4, 5, 5, 5 };
    try unfilterRow(&row, &prev, 1);

    // Byte 0: 5 + paeth(0, 10, 0) = 5 + 10 = 15 (a=0, b=10, c=0; p=10, closest to b)
    // Actually paeth(0,10,0): p=0+10-0=10, pa=10, pb=0, pc=10. pb<=pa, pb<=pc, return b=10

    // Let me recalculate for correctness
    // Pixel 0: left=0, above=10, upper_left=0
    //   p = 0+10-0 = 10, pa=|10-0|=10, pb=|10-10|=0, pc=|10-0|=10
    //   pb<=pa and pb<=pc, so return b=10
    //   row[0] = 5 + 10 = 15

    // Pixel 1: left=15, above=20, upper_left=10
    //   p = 15+20-10 = 25, pa=|25-15|=10, pb=|25-20|=5, pc=|25-10|=15
    //   pb<=pa and pb<=pc, so return b=20
    //   row[1] = 5 + 20 = 25

    // Pixel 2: left=25, above=30, upper_left=20
    //   p = 25+30-20 = 35, pa=|35-25|=10, pb=|35-30|=5, pc=|35-20|=15
    //   pb<=pa and pb<=pc, so return b=30
    //   row[2] = 5 + 30 = 35

    try std.testing.expectEqualSlices(u8, &[_]u8{ 4, 15, 25, 35 }, &row);
}

test "unfilterRow invalid filter" {
    var row = [_]u8{ 99, 10, 20 }; // Invalid filter type
    try std.testing.expectError(error.InvalidFilterType, unfilterRow(&row, null, 1));
}

test "unfilterRow wraparound" {
    // Test that byte arithmetic wraps around correctly
    var row = [_]u8{ 1, 200, 100 }; // Sub filter
    try unfilterRow(&row, null, 1);
    // 100 + 200 = 300 -> wraps to 44
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 200, 44 }, &row);
}
