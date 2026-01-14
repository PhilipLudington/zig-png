//! LZ77 string matching for DEFLATE compression.
//!
//! Implements hash chain-based string matching for finding repeated
//! sequences in data. Used by the DEFLATE compressor to achieve compression.

const std = @import("std");

/// Minimum match length (DEFLATE requirement).
pub const min_match_length: u16 = 3;

/// Maximum match length (DEFLATE limit: length codes 257-285).
pub const max_match_length: u16 = 258;

/// Maximum look-back distance (32KB sliding window).
pub const max_distance: u16 = 32768;

/// Hash table size (power of 2).
pub const hash_table_size: usize = 32768;
pub const hash_mask: u16 = hash_table_size - 1;

/// Sentinel value for empty hash chain entries.
pub const null_pos: u16 = 0xFFFF;

/// A length/distance match found by LZ77.
pub const Match = struct {
    length: u16, // 3-258
    distance: u16, // 1-32768

    /// Check if this match is better than another (longer = better).
    pub fn isBetterThan(self: Match, other: ?Match) bool {
        if (other) |o| {
            return self.length > o.length;
        }
        return true;
    }
};

/// Length code extra bits (codes 257-285, index by code - 257).
pub const length_extra_bits = [_]u4{
    0, 0, 0, 0, 0, 0, 0, 0, // 257-264
    1, 1, 1, 1, // 265-268
    2, 2, 2, 2, // 269-272
    3, 3, 3, 3, // 273-276
    4, 4, 4, 4, // 277-280
    5, 5, 5, 5, // 281-284
    0, // 285
};

/// Length base values (codes 257-285, index by code - 257).
pub const length_base = [_]u16{
    3,  4,  5,  6,  7,  8,  9,  10, // 257-264
    11, 13, 15, 17, // 265-268
    19, 23, 27, 31, // 269-272
    35, 43, 51, 59, // 273-276
    67, 83, 99, 115, // 277-280
    131, 163, 195, 227, // 281-284
    258, // 285
};

/// Distance code extra bits (codes 0-29).
pub const distance_extra_bits = [_]u4{
    0,  0,  0,  0,  // 0-3
    1,  1,  // 4-5
    2,  2,  // 6-7
    3,  3,  // 8-9
    4,  4,  // 10-11
    5,  5,  // 12-13
    6,  6,  // 14-15
    7,  7,  // 16-17
    8,  8,  // 18-19
    9,  9,  // 20-21
    10, 10, // 22-23
    11, 11, // 24-25
    12, 12, // 26-27
    13, 13, // 28-29
};

/// Distance base values (codes 0-29).
pub const distance_base = [_]u16{
    1,     2,     3,     4,     // 0-3
    5,     7,     // 4-5
    9,     13,    // 6-7
    17,    25,    // 8-9
    33,    49,    // 10-11
    65,    97,    // 12-13
    129,   193,   // 14-15
    257,   385,   // 16-17
    513,   769,   // 18-19
    1025,  1537,  // 20-21
    2049,  3073,  // 22-23
    4097,  6145,  // 24-25
    8193,  12289, // 26-27
    16385, 24577, // 28-29
};

/// Convert a match length (3-258) to a length code (257-285).
pub fn lengthToCode(length: u16) u9 {
    if (length < 3) return 257; // Invalid, but return base code
    if (length == 258) return 285;

    // Binary search through length_base to find the right code
    var code: u9 = 257;
    for (length_base, 0..) |base, i| {
        if (length < base) {
            break;
        }
        code = @intCast(257 + i);
    }
    return code;
}

/// Get extra bits value for a length.
pub fn lengthExtraValue(length: u16, code: u9) u16 {
    const base = length_base[code - 257];
    return length - base;
}

/// Convert a distance (1-32768) to a distance code (0-29).
pub fn distanceToCode(distance: u16) u5 {
    if (distance < 1) return 0; // Invalid

    // Binary search through distance_base to find the right code
    var code: u5 = 0;
    for (distance_base, 0..) |base, i| {
        if (distance < base) {
            break;
        }
        code = @intCast(i);
    }
    return code;
}

/// Get extra bits value for a distance.
pub fn distanceExtraValue(distance: u16, code: u5) u16 {
    const base = distance_base[code];
    return distance - base;
}

/// Hash chain-based string matcher for LZ77.
///
/// Uses a hash table to quickly find potential matches and chains
/// positions with the same hash together.
pub const HashChain = struct {
    /// Head of hash chain for each hash value.
    /// Points to position in window, or null_pos if empty.
    head: [hash_table_size]u16,

    /// Previous position in chain for each window position.
    /// Forms linked list of positions with same hash.
    prev: [max_distance]u16,

    const Self = @This();

    /// Initialize a new hash chain (all entries empty).
    pub fn init() Self {
        return .{
            .head = [_]u16{null_pos} ** hash_table_size,
            .prev = [_]u16{null_pos} ** max_distance,
        };
    }

    /// Reset the hash chain for reuse.
    pub fn reset(self: *Self) void {
        @memset(&self.head, null_pos);
        @memset(&self.prev, null_pos);
    }

    /// Compute hash of 3 bytes at the given position.
    pub fn hash3(data: []const u8, pos: usize) u16 {
        if (pos + 2 >= data.len) return 0;
        // Simple hash combining 3 bytes
        const h: u32 = @as(u32, data[pos]) |
            (@as(u32, data[pos + 1]) << 8) |
            (@as(u32, data[pos + 2]) << 16);
        // Knuth multiplicative hash
        return @truncate((h *% 2654435761) >> 17);
    }

    /// Insert position into hash chain.
    pub fn insert(self: *Self, data: []const u8, pos: u32) void {
        if (pos + 2 >= data.len) return;

        const h = hash3(data, pos);
        const window_pos: u16 = @intCast(pos & (max_distance - 1));

        // Link to previous head of this hash chain
        self.prev[window_pos] = self.head[h];
        self.head[h] = window_pos;
    }

    /// Find best match at current position.
    ///
    /// Searches the hash chain for the longest match within the sliding window.
    /// Returns null if no match >= min_match_length found.
    pub fn findMatch(
        self: *Self,
        data: []const u8,
        pos: u32,
        max_chain: u16,
        prev_match_length: u16,
    ) ?Match {
        if (pos + 2 >= data.len) return null;

        const h = hash3(data, pos);
        var chain_pos = self.head[h];
        var best_match: ?Match = null;
        var chain_count: u16 = 0;

        // Only look for matches longer than previous
        const min_len = @max(min_match_length, prev_match_length + 1);

        while (chain_pos != null_pos and chain_count < max_chain) {
            // Calculate actual position from window position
            const window_base = pos & ~@as(u32, max_distance - 1);
            var match_pos: u32 = window_base | chain_pos;

            // Handle wraparound - if match_pos >= pos, it's from previous window
            if (match_pos >= pos) {
                if (match_pos >= max_distance) {
                    match_pos -= max_distance;
                } else {
                    // Position is invalid (ahead of current)
                    chain_pos = self.prev[chain_pos];
                    chain_count += 1;
                    continue;
                }
            }

            const distance: u32 = pos - match_pos;

            // Check distance is valid
            if (distance > 0 and distance <= max_distance) {
                // Compare strings to find match length
                // Note: compute min in usize first to avoid overflow when data.len - pos > 65535
                const remaining = data.len - pos;
                const max_len: u16 = @intCast(@min(@as(usize, max_match_length), remaining));
                var length: u16 = 0;

                while (length < max_len and
                    data[match_pos + length] == data[pos + length])
                {
                    length += 1;
                }

                if (length >= min_len) {
                    const m = Match{
                        .length = length,
                        .distance = @intCast(distance),
                    };
                    if (m.isBetterThan(best_match)) {
                        best_match = m;
                        // If we found max length, stop searching
                        if (length >= max_match_length) break;
                    }
                }
            }

            chain_pos = self.prev[chain_pos];
            chain_count += 1;
        }

        return best_match;
    }

    /// Insert multiple positions into hash chain (for skipping over matches).
    pub fn insertRange(self: *Self, data: []const u8, start: u32, count: u32) void {
        var pos = start;
        const end = @min(start + count, @as(u32, @intCast(data.len)));
        while (pos < end) : (pos += 1) {
            self.insert(data, pos);
        }
    }
};

/// Token represents a compression decision: literal byte or length/distance match.
pub const Token = union(enum) {
    literal: u8,
    match: Match,
};

// Tests

test "lengthToCode basic" {
    // Length 3 -> code 257
    try std.testing.expectEqual(@as(u9, 257), lengthToCode(3));
    // Length 4 -> code 258
    try std.testing.expectEqual(@as(u9, 258), lengthToCode(4));
    // Length 10 -> code 264
    try std.testing.expectEqual(@as(u9, 264), lengthToCode(10));
    // Length 258 -> code 285
    try std.testing.expectEqual(@as(u9, 285), lengthToCode(258));
}

test "distanceToCode basic" {
    // Distance 1 -> code 0
    try std.testing.expectEqual(@as(u5, 0), distanceToCode(1));
    // Distance 4 -> code 3
    try std.testing.expectEqual(@as(u5, 3), distanceToCode(4));
    // Distance 5 -> code 4
    try std.testing.expectEqual(@as(u5, 4), distanceToCode(5));
    // Distance 32768 -> code 29
    try std.testing.expectEqual(@as(u5, 29), distanceToCode(32768));
}

test "lengthToCode and distanceToCode round-trip" {
    // Verify that code -> base + extra_value gives back original length
    const test_lengths = [_]u16{ 3, 4, 5, 10, 11, 18, 19, 34, 35, 66, 67, 130, 131, 257, 258 };
    for (test_lengths) |len| {
        const code = lengthToCode(len);
        const base = length_base[code - 257];
        const extra = lengthExtraValue(len, code);
        try std.testing.expectEqual(len, base + extra);
    }

    const test_distances = [_]u16{ 1, 2, 4, 5, 8, 9, 16, 17, 32, 33, 64, 65, 256, 257, 1024, 32768 };
    for (test_distances) |dist| {
        const code = distanceToCode(dist);
        const base = distance_base[code];
        const extra = distanceExtraValue(dist, code);
        try std.testing.expectEqual(dist, base + extra);
    }
}

test "HashChain.hash3" {
    const data = "abcdef";
    const h1 = HashChain.hash3(data, 0);
    const h2 = HashChain.hash3(data, 1);
    // Different positions should (usually) have different hashes
    try std.testing.expect(h1 != h2);

    // Same 3 bytes should have same hash
    const data2 = "abcabc";
    const h3 = HashChain.hash3(data2, 0);
    const h4 = HashChain.hash3(data2, 3);
    try std.testing.expectEqual(h3, h4);
}

test "HashChain.findMatch basic" {
    var chain = HashChain.init();
    const data = "abcdefabcdefghij";

    // Insert first occurrence of "abc"
    chain.insert(data, 0);
    chain.insert(data, 1);
    chain.insert(data, 2);
    chain.insert(data, 3);
    chain.insert(data, 4);
    chain.insert(data, 5);

    // Try to find match at position 6 ("abc...")
    const match = chain.findMatch(data, 6, 100, 0);
    try std.testing.expect(match != null);
    if (match) |m| {
        // Should find "abcdef" = length 6, distance 6
        try std.testing.expectEqual(@as(u16, 6), m.length);
        try std.testing.expectEqual(@as(u16, 6), m.distance);
    }
}

test "HashChain.findMatch no match" {
    var chain = HashChain.init();
    const data = "abcdefxyz";

    // Insert some positions
    chain.insert(data, 0);
    chain.insert(data, 1);
    chain.insert(data, 2);

    // "xyz" doesn't match "abc"
    const match = chain.findMatch(data, 6, 100, 0);
    try std.testing.expect(match == null);
}

test "HashChain.findMatch respects min_match_length" {
    var chain = HashChain.init();
    const data = "abXabY"; // "ab" repeats but only 2 chars

    chain.insert(data, 0);
    chain.insert(data, 1);
    chain.insert(data, 2);

    // Position 3 has "ab" which only matches 2 chars - below min
    const match = chain.findMatch(data, 3, 100, 0);
    // Should return null since match < 3 bytes
    try std.testing.expect(match == null);
}

test "Match.isBetterThan" {
    const m1 = Match{ .length = 5, .distance = 10 };
    const m2 = Match{ .length = 3, .distance = 5 };
    const m3 = Match{ .length = 5, .distance = 20 };

    try std.testing.expect(m1.isBetterThan(m2)); // 5 > 3
    try std.testing.expect(!m2.isBetterThan(m1)); // 3 < 5
    try std.testing.expect(!m1.isBetterThan(m3)); // equal length
    try std.testing.expect(m1.isBetterThan(null)); // anything better than null
}
