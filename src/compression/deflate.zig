//! DEFLATE compression (RFC 1951).
//!
//! Implements the deflate compression algorithm for creating compressed
//! streams that can be decompressed by the inflate implementation.

const std = @import("std");
const BitWriter = @import("../utils/bit_writer.zig").BitWriter;
const BitWriterError = @import("../utils/bit_writer.zig").BitWriterError;
const huffman = @import("huffman.zig");
const lz77 = @import("lz77.zig");
const inflate_mod = @import("inflate.zig");

pub const DeflateError = error{
    BufferOverflow,
    InvalidInput,
} || BitWriterError;

/// Block type for DEFLATE.
pub const BlockType = enum(u2) {
    stored = 0b00,
    fixed = 0b01,
    dynamic = 0b10,
    reserved = 0b11, // Invalid
};

/// Compression level affects compression ratio vs speed.
pub const CompressionLevel = enum(u4) {
    /// No compression - stored blocks only
    store = 0,
    /// Fastest compression
    fastest = 1,
    /// Fast compression
    fast = 3,
    /// Default compression (good balance)
    default = 6,
    /// Best compression (slowest)
    best = 9,

    /// Get maximum hash chain length for this level.
    pub fn maxChainLength(self: CompressionLevel) u16 {
        return switch (self) {
            .store => 0,
            .fastest => 4,
            .fast => 16,
            .default => 64,
            .best => 256,
        };
    }

    /// Whether to use lazy matching at this level.
    pub fn useLazyMatching(self: CompressionLevel) bool {
        return @intFromEnum(self) >= 4;
    }
};

/// DEFLATE compressor.
///
/// Compresses data using the DEFLATE algorithm with configurable
/// compression level.
pub const Deflate = struct {
    writer: *BitWriter,
    level: CompressionLevel,
    hash_chain: lz77.HashChain,

    const Self = @This();

    /// Initialize a deflate compressor.
    pub fn init(writer: *BitWriter, level: CompressionLevel) Self {
        return .{
            .writer = writer,
            .level = level,
            .hash_chain = lz77.HashChain.init(),
        };
    }

    /// Compress data and write to output.
    ///
    /// Writes a single DEFLATE block (marked as final) containing
    /// the compressed data.
    pub fn compress(self: *Self, data: []const u8) DeflateError!void {
        if (self.level == .store) {
            try self.writeStoredBlock(data, true);
        } else {
            try self.writeFixedBlock(data, true);
        }
    }

    /// Write a stored (uncompressed) block.
    pub fn writeStoredBlock(self: *Self, data: []const u8, is_final: bool) DeflateError!void {
        // Block header: BFINAL (1 bit) + BTYPE (2 bits) = stored (00)
        const header: u16 = if (is_final) 0b001 else 0b000;
        try self.writer.writeBits(header, 3);

        // Align to byte boundary
        try self.writer.flush();

        // For stored blocks, we may need to split into multiple 65535-byte chunks
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_len = @min(data.len - offset, 65535);
            const len: u16 = @intCast(chunk_len);
            const nlen: u16 = ~len;

            // Write LEN (little-endian)
            try self.writer.writeBits(len, 16);
            // Write NLEN (little-endian)
            try self.writer.writeBits(nlen, 16);

            // Write raw data
            try self.writer.writeBytes(data[offset..][0..chunk_len]);

            offset += chunk_len;

            // If not last chunk and not final block, write another stored block header
            if (offset < data.len) {
                try self.writer.writeBits(0b000, 3); // Not final, stored
                try self.writer.flush();
            }
        }

        // Handle empty data
        if (data.len == 0) {
            try self.writer.writeBits(0, 16); // LEN = 0
            try self.writer.writeBits(0xFFFF, 16); // NLEN = ~0
        }
    }

    /// Write a fixed Huffman block.
    pub fn writeFixedBlock(self: *Self, data: []const u8, is_final: bool) DeflateError!void {
        // Block header: BFINAL (1 bit) + BTYPE (2 bits) = fixed (01)
        const header: u16 = if (is_final) 0b011 else 0b010;
        try self.writer.writeBits(header, 3);

        // Reset hash chain for this block
        self.hash_chain.reset();

        // Compress using LZ77 and fixed Huffman codes
        var pos: u32 = 0;
        while (pos < data.len) {
            // Try to find a match
            var match: ?lz77.Match = null;
            if (self.level != .store and pos + lz77.min_match_length <= data.len) {
                match = self.hash_chain.findMatch(
                    data,
                    pos,
                    self.level.maxChainLength(),
                    0, // No previous match for lazy matching (simplified)
                );
            }

            if (match) |m| {
                // Encode length/distance pair
                try self.encodeLengthDistance(m.length, m.distance);

                // Insert all positions in the match into hash chain
                self.hash_chain.insertRange(data, pos, m.length);
                pos += m.length;
            } else {
                // Encode literal
                try huffman.fixed_literal_encoder.encode(data[pos], self.writer);
                self.hash_chain.insert(data, pos);
                pos += 1;
            }
        }

        // Write end-of-block symbol (256)
        try huffman.fixed_literal_encoder.encode(256, self.writer);
    }

    /// Encode a length/distance pair using fixed Huffman codes.
    fn encodeLengthDistance(self: *Self, length: u16, distance: u16) DeflateError!void {
        // Encode length
        const len_code = lz77.lengthToCode(length);
        try huffman.fixed_literal_encoder.encode(len_code, self.writer);

        // Write extra bits for length if needed
        const len_extra_bits = lz77.length_extra_bits[len_code - 257];
        if (len_extra_bits > 0) {
            const len_extra_val = lz77.lengthExtraValue(length, len_code);
            try self.writer.writeBits(len_extra_val, len_extra_bits);
        }

        // Encode distance
        const dist_code = lz77.distanceToCode(distance);
        try huffman.fixed_distance_encoder.encode(dist_code, self.writer);

        // Write extra bits for distance if needed
        const dist_extra_bits = lz77.distance_extra_bits[dist_code];
        if (dist_extra_bits > 0) {
            const dist_extra_val = lz77.distanceExtraValue(distance, dist_code);
            try self.writer.writeBits(dist_extra_val, dist_extra_bits);
        }
    }
};

/// Convenience function: compress data to buffer in one shot.
pub fn deflate(
    input: []const u8,
    output: []u8,
    level: CompressionLevel,
) DeflateError!usize {
    var writer = BitWriter.init(output);
    var compressor = Deflate.init(&writer, level);
    try compressor.compress(input);
    try writer.flush();
    return writer.bytesWritten();
}

// Tests

test "deflate stored block empty" {
    var output: [32]u8 = undefined;
    const len = try deflate("", &output, .store);

    // Should produce: header (3 bits padded to 1 byte) + LEN (2) + NLEN (2) = 5 bytes
    try std.testing.expectEqual(@as(usize, 5), len);

    // Verify we can decompress it
    var decompressed: [32]u8 = undefined;
    const dec_len = try inflate_mod.inflate(output[0..len], &decompressed);
    try std.testing.expectEqual(@as(usize, 0), dec_len);
}

test "deflate stored block hello" {
    var output: [64]u8 = undefined;
    const len = try deflate("hello", &output, .store);

    // Verify we can decompress it
    var decompressed: [64]u8 = undefined;
    const dec_len = try inflate_mod.inflate(output[0..len], &decompressed);
    try std.testing.expectEqual(@as(usize, 5), dec_len);
    try std.testing.expectEqualSlices(u8, "hello", decompressed[0..dec_len]);
}

test "deflate fixed block empty" {
    var output: [32]u8 = undefined;
    const len = try deflate("", &output, .fastest);

    // Should be very small (just header + end-of-block)
    try std.testing.expect(len <= 4);

    // Verify we can decompress it - add padding for peekBits(15)
    var padded: [32]u8 = undefined;
    @memcpy(padded[0..len], output[0..len]);
    @memset(padded[len..], 0);
    var decompressed: [32]u8 = undefined;
    const dec_len = try inflate_mod.inflate(&padded, &decompressed);
    try std.testing.expectEqual(@as(usize, 0), dec_len);
}

test "deflate fixed block hello" {
    var output: [64]u8 = undefined;
    const len = try deflate("hello", &output, .fastest);

    // Verify we can decompress it - add padding for peekBits(15)
    var padded: [64]u8 = undefined;
    @memcpy(padded[0..len], output[0..len]);
    @memset(padded[len..], 0);
    var decompressed: [64]u8 = undefined;
    const dec_len = try inflate_mod.inflate(&padded, &decompressed);
    try std.testing.expectEqual(@as(usize, 5), dec_len);
    try std.testing.expectEqualSlices(u8, "hello", decompressed[0..dec_len]);
}

test "deflate fixed block with repetition" {
    const input = "abcabcabcabcabcabc"; // Repetitive data
    var output: [64]u8 = undefined;
    const len = try deflate(input, &output, .default);

    // Should compress well due to repetition
    try std.testing.expect(len < input.len);

    // Verify round-trip - add padding for peekBits(15)
    var padded: [64]u8 = undefined;
    @memcpy(padded[0..len], output[0..len]);
    @memset(padded[len..], 0);
    var decompressed: [64]u8 = undefined;
    const dec_len = try inflate_mod.inflate(&padded, &decompressed);
    try std.testing.expectEqual(@as(usize, 18), dec_len);
    try std.testing.expectEqualSlices(u8, input, decompressed[0..dec_len]);
}

test "deflate round-trip hello world" {
    const input = "hello world";
    var output: [64]u8 = undefined;
    const len = try deflate(input, &output, .default);

    // Add padding for peekBits(15)
    var padded: [64]u8 = undefined;
    @memcpy(padded[0..len], output[0..len]);
    @memset(padded[len..], 0);
    var decompressed: [64]u8 = undefined;
    const dec_len = try inflate_mod.inflate(&padded, &decompressed);
    try std.testing.expectEqual(@as(usize, 11), dec_len);
    try std.testing.expectEqualSlices(u8, input, decompressed[0..dec_len]);
}

test "deflate round-trip all levels" {
    const input = "the quick brown fox jumps over the lazy dog";

    const levels = [_]CompressionLevel{ .store, .fastest, .fast, .default, .best };

    for (levels) |level| {
        var output: [128]u8 = undefined;
        const len = try deflate(input, &output, level);

        // Add padding for peekBits(15)
        var padded: [128]u8 = undefined;
        @memcpy(padded[0..len], output[0..len]);
        @memset(padded[len..], 0);
        var decompressed: [128]u8 = undefined;
        const dec_len = try inflate_mod.inflate(&padded, &decompressed);
        try std.testing.expectEqual(@as(usize, input.len), dec_len);
        try std.testing.expectEqualSlices(u8, input, decompressed[0..dec_len]);
    }
}

test "deflate larger data" {
    // Generate some test data with patterns
    var input: [1024]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @intCast((i * 7 + 13) % 256);
    }
    // Add some repetition
    @memcpy(input[256..512], input[0..256]);

    var output: [2048]u8 = undefined;
    const len = try deflate(&input, &output, .default);

    // Add padding for peekBits(15)
    var padded: [2048]u8 = undefined;
    @memcpy(padded[0..len], output[0..len]);
    @memset(padded[len..], 0);
    var decompressed: [1024]u8 = undefined;
    const dec_len = try inflate_mod.inflate(&padded, &decompressed);
    try std.testing.expectEqual(@as(usize, 1024), dec_len);
    try std.testing.expectEqualSlices(u8, &input, decompressed[0..dec_len]);
}
