//! CRC32 implementation for PNG chunk validation.
//!
//! Uses the polynomial 0xEDB88320 (reflected form of 0x04C11DB7)
//! as specified in the PNG specification.

const std = @import("std");

/// Precomputed CRC32 lookup table (computed at compile time).
const crc_table = generateCrcTable();

fn generateCrcTable() [256]u32 {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if (crc & 1 == 1) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
        table[i] = crc;
    }
    return table;
}

/// Compute CRC32 checksum of data in one shot.
pub fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

/// Streaming CRC32 calculator for incremental updates.
pub const Crc32 = struct {
    crc: u32,

    const Self = @This();

    /// Initialize a new CRC32 calculator.
    pub fn init() Self {
        return .{ .crc = 0xFFFFFFFF };
    }

    /// Update the CRC with additional data.
    pub fn update(self: *Self, data: []const u8) void {
        for (data) |byte| {
            self.crc = crc_table[(self.crc ^ byte) & 0xFF] ^ (self.crc >> 8);
        }
    }

    /// Finalize and return the CRC32 value.
    pub fn final(self: Self) u32 {
        return ~self.crc;
    }

    /// Reset to initial state for reuse.
    pub fn reset(self: *Self) void {
        self.crc = 0xFFFFFFFF;
    }
};

// Tests

test "crc32 empty data" {
    try std.testing.expectEqual(@as(u32, 0x00000000), crc32(&.{}));
}

test "crc32 known values" {
    // Standard test vectors
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0xE8B7BE43), crc32("a"));
    try std.testing.expectEqual(@as(u32, 0x352441C2), crc32("abc"));
}

test "crc32 PNG chunk type" {
    // CRC of chunk type names (not the full chunk CRC which includes data)
    // These are just the CRC of the 4-byte type string
    const ihdr_crc = crc32("IHDR");
    const idat_crc = crc32("IDAT");
    const iend_crc = crc32("IEND");

    // Verify they're consistent (not magic values, just sanity check)
    try std.testing.expect(ihdr_crc != 0);
    try std.testing.expect(idat_crc != 0);
    try std.testing.expect(iend_crc != 0);
    try std.testing.expect(ihdr_crc != idat_crc);
    try std.testing.expect(idat_crc != iend_crc);
}

test "streaming crc32 matches one-shot" {
    const data = "The quick brown fox jumps over the lazy dog";
    const expected = crc32(data);

    // Update all at once
    {
        var crc = Crc32.init();
        crc.update(data);
        try std.testing.expectEqual(expected, crc.final());
    }

    // Update byte by byte
    {
        var crc = Crc32.init();
        for (data) |byte| {
            crc.update(&[_]u8{byte});
        }
        try std.testing.expectEqual(expected, crc.final());
    }

    // Update in chunks
    {
        var crc = Crc32.init();
        crc.update(data[0..10]);
        crc.update(data[10..20]);
        crc.update(data[20..]);
        try std.testing.expectEqual(expected, crc.final());
    }
}

test "streaming crc32 reset" {
    var crc = Crc32.init();
    crc.update("abc");
    const first = crc.final();

    crc.reset();
    crc.update("abc");
    try std.testing.expectEqual(first, crc.final());
}

test "crc_table is valid" {
    // Verify a few known table entries
    try std.testing.expectEqual(@as(u32, 0x00000000), crc_table[0]);
    try std.testing.expectEqual(@as(u32, 0x77073096), crc_table[1]);
    try std.testing.expectEqual(@as(u32, 0xEE0E612C), crc_table[2]);
    try std.testing.expectEqual(@as(u32, 0x990951BA), crc_table[3]);
}
