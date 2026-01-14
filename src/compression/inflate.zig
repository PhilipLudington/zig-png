//! DEFLATE decompression (RFC 1951).
//!
//! Implements the inflate algorithm for decompressing DEFLATE streams.
//! Used by PNG (via zlib) for image data decompression.

const std = @import("std");
const Allocator = std.mem.Allocator;
const BitReader = @import("../utils/bit_reader.zig").BitReader;
const huffman = @import("huffman.zig");
const HuffmanTree = huffman.HuffmanTree;

/// Inflate decompression errors.
pub const InflateError = error{
    InvalidBlockType,
    InvalidStoredLength,
    InvalidHuffmanCode,
    InvalidLengthCode,
    InvalidDistanceCode,
    InvalidDistance,
    InvalidDynamicHeader,
    UnexpectedEndOfStream,
    OutputBufferFull,
    OutOfMemory,
};

/// Length code extra bits and base values (codes 257-285).
/// Index by (length_code - 257).
const length_extra_bits = [_]u4{
    0, 0, 0, 0, 0, 0, 0, 0, // 257-264
    1, 1, 1, 1, // 265-268
    2, 2, 2, 2, // 269-272
    3, 3, 3, 3, // 273-276
    4, 4, 4, 4, // 277-280
    5, 5, 5, 5, // 281-284
    0, // 285
};

const length_base = [_]u16{
    3, 4, 5, 6, 7, 8, 9, 10, // 257-264
    11, 13, 15, 17, // 265-268
    19, 23, 27, 31, // 269-272
    35, 43, 51, 59, // 273-276
    67, 83, 99, 115, // 277-280
    131, 163, 195, 227, // 281-284
    258, // 285
};

/// Distance code extra bits and base values (codes 0-29).
const distance_extra_bits = [_]u4{
    0, 0, 0, 0, // 0-3
    1, 1, // 4-5
    2, 2, // 6-7
    3, 3, // 8-9
    4, 4, // 10-11
    5, 5, // 12-13
    6, 6, // 14-15
    7, 7, // 16-17
    8, 8, // 18-19
    9, 9, // 20-21
    10, 10, // 22-23
    11, 11, // 24-25
    12, 12, // 26-27
    13, 13, // 28-29
};

const distance_base = [_]u16{
    1, 2, 3, 4, // 0-3
    5, 7, // 4-5
    9, 13, // 6-7
    17, 25, // 8-9
    33, 49, // 10-11
    65, 97, // 12-13
    129, 193, // 14-15
    257, 385, // 16-17
    513, 769, // 18-19
    1025, 1537, // 20-21
    2049, 3073, // 22-23
    4097, 6145, // 24-25
    8193, 12289, // 26-27
    16385, 24577, // 28-29
};

/// Order of code length alphabet codes in dynamic Huffman header.
const code_length_order = [_]u5{
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
};

/// Maximum sliding window size (32KB).
pub const window_size = 32768;

/// Inflate decompressor state.
pub const Inflate = struct {
    reader: *BitReader,
    output: []u8,
    output_pos: usize,

    /// Sliding window for LZ77 backreferences.
    /// Points to output buffer (which serves as the window).
    window_start: usize,

    const Self = @This();

    /// Initialize inflater with a bit reader and output buffer.
    pub fn init(reader: *BitReader, output: []u8) Self {
        return .{
            .reader = reader,
            .output = output,
            .output_pos = 0,
            .window_start = 0,
        };
    }

    /// Decompress all blocks until final block is processed.
    pub fn decompress(self: *Self) InflateError!usize {
        var is_final = false;

        while (!is_final) {
            // Read block header
            is_final = (self.reader.readBit() catch return error.UnexpectedEndOfStream) == 1;
            const btype = self.reader.readBits(2) catch return error.UnexpectedEndOfStream;

            switch (@as(u2, @intCast(btype))) {
                0b00 => try self.decompressStored(),
                0b01 => try self.decompressFixed(),
                0b10 => try self.decompressDynamic(),
                0b11 => return error.InvalidBlockType,
            }
        }

        return self.output_pos;
    }

    /// Decompress a stored (uncompressed) block.
    fn decompressStored(self: *Self) InflateError!void {
        // Align to byte boundary
        self.reader.alignToByte();

        // Read LEN and NLEN
        const len = self.reader.readBits(16) catch return error.UnexpectedEndOfStream;
        const nlen = self.reader.readBits(16) catch return error.UnexpectedEndOfStream;

        // Validate: NLEN should be one's complement of LEN
        if (len != (~nlen & 0xFFFF)) {
            return error.InvalidStoredLength;
        }

        // Copy bytes directly
        for (0..len) |_| {
            const byte = self.reader.readByte() catch return error.UnexpectedEndOfStream;
            try self.outputByte(byte);
        }
    }

    /// Decompress a block using fixed Huffman codes.
    fn decompressFixed(self: *Self) InflateError!void {
        try self.decompressHuffman(&huffman.fixed_literal_tree, &huffman.fixed_distance_tree);
    }

    /// Decompress a block using dynamic Huffman codes.
    fn decompressDynamic(self: *Self) InflateError!void {
        // Read header
        const hlit = (self.reader.readBits(5) catch return error.UnexpectedEndOfStream) + 257;
        const hdist = (self.reader.readBits(5) catch return error.UnexpectedEndOfStream) + 1;
        const hclen = (self.reader.readBits(4) catch return error.UnexpectedEndOfStream) + 4;

        // Validate ranges
        if (hlit > 286 or hdist > 30) {
            return error.InvalidDynamicHeader;
        }

        // Read code length code lengths
        var code_length_lengths: [19]u4 = [_]u4{0} ** 19;
        for (0..hclen) |i| {
            code_length_lengths[code_length_order[i]] =
                @intCast(self.reader.readBits(3) catch return error.UnexpectedEndOfStream);
        }

        // Build code length Huffman tree
        const code_length_tree = HuffmanTree.build(&code_length_lengths) catch
            return error.InvalidDynamicHeader;

        // Read literal/length and distance code lengths
        var all_lengths: [286 + 30]u4 = [_]u4{0} ** (286 + 30);
        const total_codes = hlit + hdist;
        var i: usize = 0;

        while (i < total_codes) {
            const sym = code_length_tree.decode(self.reader) catch
                return error.InvalidHuffmanCode;

            if (sym < 16) {
                // Literal code length
                all_lengths[i] = @intCast(sym);
                i += 1;
            } else if (sym == 16) {
                // Copy previous length 3-6 times
                if (i == 0) return error.InvalidDynamicHeader;
                const repeat = (self.reader.readBits(2) catch return error.UnexpectedEndOfStream) + 3;
                const prev_len = all_lengths[i - 1];
                for (0..repeat) |_| {
                    if (i >= total_codes) return error.InvalidDynamicHeader;
                    all_lengths[i] = prev_len;
                    i += 1;
                }
            } else if (sym == 17) {
                // Repeat zero 3-10 times
                const repeat = (self.reader.readBits(3) catch return error.UnexpectedEndOfStream) + 3;
                for (0..repeat) |_| {
                    if (i >= total_codes) return error.InvalidDynamicHeader;
                    all_lengths[i] = 0;
                    i += 1;
                }
            } else if (sym == 18) {
                // Repeat zero 11-138 times
                const repeat = (self.reader.readBits(7) catch return error.UnexpectedEndOfStream) + 11;
                for (0..repeat) |_| {
                    if (i >= total_codes) return error.InvalidDynamicHeader;
                    all_lengths[i] = 0;
                    i += 1;
                }
            } else {
                return error.InvalidHuffmanCode;
            }
        }

        // Build literal/length and distance trees
        const literal_tree = HuffmanTree.build(all_lengths[0..hlit]) catch
            return error.InvalidDynamicHeader;
        const distance_tree = HuffmanTree.build(all_lengths[hlit..][0..hdist]) catch
            return error.InvalidDynamicHeader;

        try self.decompressHuffman(&literal_tree, &distance_tree);
    }

    /// Decompress using given Huffman trees.
    fn decompressHuffman(
        self: *Self,
        literal_tree: *const HuffmanTree,
        distance_tree: *const HuffmanTree,
    ) InflateError!void {
        while (true) {
            const sym = literal_tree.decode(self.reader) catch
                return error.InvalidHuffmanCode;

            if (sym < 256) {
                // Literal byte
                try self.outputByte(@intCast(sym));
            } else if (sym == 256) {
                // End of block
                return;
            } else if (sym <= 285) {
                // Length/distance pair
                const length = try self.decodeLength(@intCast(sym));
                const dist_sym = distance_tree.decode(self.reader) catch
                    return error.InvalidHuffmanCode;
                const distance = try self.decodeDistance(@intCast(dist_sym));

                // Copy from sliding window
                try self.copyFromWindow(distance, length);
            } else {
                return error.InvalidLengthCode;
            }
        }
    }

    /// Decode a length value from a length code (257-285).
    fn decodeLength(self: *Self, code: u16) InflateError!u16 {
        if (code < 257 or code > 285) {
            return error.InvalidLengthCode;
        }

        const index = code - 257;
        const base = length_base[index];
        const extra = length_extra_bits[index];

        if (extra == 0) {
            return base;
        }

        const extra_val = self.reader.readBits(extra) catch return error.UnexpectedEndOfStream;
        return base + extra_val;
    }

    /// Decode a distance value from a distance code (0-29).
    fn decodeDistance(self: *Self, code: u16) InflateError!u16 {
        if (code > 29) {
            return error.InvalidDistanceCode;
        }

        const base = distance_base[code];
        const extra = distance_extra_bits[code];

        if (extra == 0) {
            return base;
        }

        const extra_val = self.reader.readBits(extra) catch return error.UnexpectedEndOfStream;
        return base + extra_val;
    }

    /// Output a single byte.
    fn outputByte(self: *Self, byte: u8) InflateError!void {
        if (self.output_pos >= self.output.len) {
            return error.OutputBufferFull;
        }
        self.output[self.output_pos] = byte;
        self.output_pos += 1;
    }

    /// Copy bytes from sliding window (LZ77 backreference).
    fn copyFromWindow(self: *Self, distance: u16, length: u16) InflateError!void {
        if (distance > self.output_pos) {
            return error.InvalidDistance;
        }

        // Source position in output buffer
        var src_pos = self.output_pos - distance;

        // Copy byte-by-byte (handles overlapping copies correctly)
        for (0..length) |_| {
            if (self.output_pos >= self.output.len) {
                return error.OutputBufferFull;
            }
            self.output[self.output_pos] = self.output[src_pos];
            self.output_pos += 1;
            src_pos += 1;
        }
    }
};

/// Convenience function to inflate data into a buffer.
pub fn inflate(input: []const u8, output: []u8) InflateError!usize {
    var reader = BitReader.init(input);
    var inflater = Inflate.init(&reader, output);
    return inflater.decompress();
}

// Tests

test "inflate stored block" {
    // Stored block: BFINAL=1, BTYPE=00, LEN=5, NLEN=~5, data="hello"
    // BFINAL=1 (1 bit), BTYPE=00 (2 bits) = 0b001 in bits 0-2
    // Followed by padding to byte boundary, then LEN/NLEN/data

    // Byte 0: 0b00000_001 = 0x01 (BFINAL=1, BTYPE=00, then 5 bits padding)
    // Bytes 1-2: LEN = 5 (little-endian) = 0x05 0x00
    // Bytes 3-4: NLEN = ~5 = 0xFFFA (little-endian) = 0xFA 0xFF
    // Bytes 5-9: "hello"
    const input = [_]u8{
        0x01, // BFINAL=1, BTYPE=00
        0x05, 0x00, // LEN = 5
        0xFA, 0xFF, // NLEN = ~5
        'h', 'e', 'l', 'l', 'o',
    };

    var output: [16]u8 = undefined;
    const len = try inflate(&input, &output);

    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualSlices(u8, "hello", output[0..5]);
}

test "inflate fixed huffman simple" {
    // This tests a simple fixed Huffman compressed block.
    // We'll use zlib/gzip to generate test data for validation.
    //
    // For now, test that we can at least parse a minimal fixed block.
    // A block with just end-of-block symbol (256):
    // Fixed code for 256 is 7 bits: 0000000
    // BFINAL=1, BTYPE=01, then code for 256
    // Bits: 1 01 0000000 = 0b0000000_01_1 = low bits first
    // = 0x03 0x00
    // Need extra padding bytes for peekBits(15)

    const input = [_]u8{ 0x03, 0x00, 0x00, 0x00 };
    var output: [16]u8 = undefined;
    const len = try inflate(&input, &output);

    try std.testing.expectEqual(@as(usize, 0), len);
}

test "inflate length/distance decode" {
    // Test the length and distance decoding functions directly
    var reader = BitReader.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF });
    var inflater = Inflate.init(&reader, &[_]u8{});

    // Code 257 = length 3, no extra bits
    const len3 = try inflater.decodeLength(257);
    try std.testing.expectEqual(@as(u16, 3), len3);

    // Code 285 = length 258, no extra bits
    const len258 = try inflater.decodeLength(285);
    try std.testing.expectEqual(@as(u16, 258), len258);
}

test "inflate distance decode" {
    // Test distance decoding
    var reader = BitReader.init(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    var inflater = Inflate.init(&reader, &[_]u8{});

    // Code 0 = distance 1, no extra bits
    const dist1 = try inflater.decodeDistance(0);
    try std.testing.expectEqual(@as(u16, 1), dist1);

    // Code 3 = distance 4, no extra bits
    const dist4 = try inflater.decodeDistance(3);
    try std.testing.expectEqual(@as(u16, 4), dist4);
}

test "inflate real deflate data" {
    // Raw deflate of "hello world" generated by zlib
    // Note: padding bytes added at end for peekBits(15) at end of stream
    const input = [_]u8{
        0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0x28, 0xCF,
        0x2F, 0xCA, 0x49, 0x01, 0x00, 0x00, 0x00,
    };

    var output: [32]u8 = undefined;
    const len = try inflate(&input, &output);

    try std.testing.expectEqual(@as(usize, 11), len);
    try std.testing.expectEqualSlices(u8, "hello world", output[0..11]);
}
