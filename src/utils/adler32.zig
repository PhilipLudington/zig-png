//! Adler32 checksum implementation for zlib.
//!
//! Adler32 is used in the zlib compressed data stream to verify data integrity.
//! It consists of two 16-bit sums: s1 is the sum of all bytes plus 1,
//! s2 is the running sum of s1 values. Both are taken modulo 65521.

const std = @import("std");

/// Largest prime less than 2^16, used as modulus.
const adler_mod: u32 = 65521;

/// Number of bytes we can process before overflow risk.
/// With max byte value 255, s1 can increase by 255*n without exceeding 2^31.
/// s2 increases faster, so we use a conservative batch size.
const nmax: usize = 5552;

/// Compute Adler32 checksum of data in one shot.
pub fn adler32(data: []const u8) u32 {
    var checksum = Adler32.init();
    checksum.update(data);
    return checksum.final();
}

/// Streaming Adler32 calculator for incremental updates.
pub const Adler32 = struct {
    s1: u32,
    s2: u32,

    const Self = @This();

    /// Initialize a new Adler32 calculator.
    /// Initial value is 1 (s1=1, s2=0).
    pub fn init() Self {
        return .{ .s1 = 1, .s2 = 0 };
    }

    /// Update the checksum with additional data.
    pub fn update(self: *Self, data: []const u8) void {
        var s1 = self.s1;
        var s2 = self.s2;
        var remaining = data;

        // Process in batches to avoid overflow
        while (remaining.len > 0) {
            const batch_len = @min(remaining.len, nmax);
            const batch = remaining[0..batch_len];
            remaining = remaining[batch_len..];

            for (batch) |byte| {
                s1 += byte;
                s2 += s1;
            }

            s1 %= adler_mod;
            s2 %= adler_mod;
        }

        self.s1 = s1;
        self.s2 = s2;
    }

    /// Finalize and return the Adler32 value.
    /// Format: (s2 << 16) | s1
    pub fn final(self: Self) u32 {
        return (self.s2 << 16) | self.s1;
    }

    /// Reset to initial state for reuse.
    pub fn reset(self: *Self) void {
        self.s1 = 1;
        self.s2 = 0;
    }
};

// Tests

test "adler32 empty data" {
    // Adler32 of empty data is 1 (initial s1=1, s2=0)
    try std.testing.expectEqual(@as(u32, 1), adler32(&.{}));
}

test "adler32 known values" {
    // Standard test vectors
    // "a" -> s1 = 1 + 97 = 98, s2 = 0 + 98 = 98 -> (98 << 16) | 98 = 0x00620062
    try std.testing.expectEqual(@as(u32, 0x00620062), adler32("a"));

    // "abc" -> calculated manually
    // s1: 1 -> 98 -> 196 -> 295
    // s2: 0 -> 98 -> 294 -> 589
    // Result: (589 << 16) | 295 = 0x024d0127
    try std.testing.expectEqual(@as(u32, 0x024d0127), adler32("abc"));

    // Standard test string "123456789"
    try std.testing.expectEqual(@as(u32, 0x091E01DE), adler32("123456789"));
}

test "adler32 Wikipedia example" {
    // From Wikipedia Adler-32 article
    try std.testing.expectEqual(@as(u32, 0x11E60398), adler32("Wikipedia"));
}

test "streaming adler32 matches one-shot" {
    const data = "The quick brown fox jumps over the lazy dog";
    const expected = adler32(data);

    // Update all at once
    {
        var checksum = Adler32.init();
        checksum.update(data);
        try std.testing.expectEqual(expected, checksum.final());
    }

    // Update byte by byte
    {
        var checksum = Adler32.init();
        for (data) |byte| {
            checksum.update(&[_]u8{byte});
        }
        try std.testing.expectEqual(expected, checksum.final());
    }

    // Update in chunks
    {
        var checksum = Adler32.init();
        checksum.update(data[0..10]);
        checksum.update(data[10..20]);
        checksum.update(data[20..]);
        try std.testing.expectEqual(expected, checksum.final());
    }
}

test "adler32 large data" {
    // Test with data larger than nmax to verify batching
    var data: [10000]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const one_shot = adler32(&data);

    // Verify streaming produces same result
    var checksum = Adler32.init();
    checksum.update(data[0..1000]);
    checksum.update(data[1000..5000]);
    checksum.update(data[5000..]);
    try std.testing.expectEqual(one_shot, checksum.final());
}

test "adler32 reset" {
    var checksum = Adler32.init();
    checksum.update("abc");
    const first = checksum.final();

    checksum.reset();
    checksum.update("abc");
    try std.testing.expectEqual(first, checksum.final());
}
