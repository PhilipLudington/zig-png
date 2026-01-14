//! Huffman coding for DEFLATE compression.
//!
//! Implements Huffman tree construction and decoding as specified in RFC 1951.
//! Supports both fixed and dynamic Huffman codes used in DEFLATE.

const std = @import("std");
const BitReader = @import("../utils/bit_reader.zig").BitReader;

/// Maximum number of bits in a Huffman code.
pub const max_bits = 15;

/// Maximum code length for code length alphabet.
pub const max_code_length_bits = 7;

/// Number of literal/length codes (0-285, but 286-287 are not used).
pub const literal_count = 286;

/// Number of distance codes (0-29).
pub const distance_count = 30;

/// Number of code length codes.
pub const code_length_count = 19;

/// Huffman decoding errors.
pub const HuffmanError = error{
    InvalidCodeLengths,
    InvalidCode,
    IncompleteCode,
};

/// A Huffman tree for decoding compressed data.
///
/// Uses a lookup table approach for efficient decoding. For codes up to
/// `fast_bits` in length, decoding is a single table lookup. Longer codes
/// use secondary tables.
pub const HuffmanTree = struct {
    /// Lookup table: indexed by reversed code bits.
    /// Entry format: lower 9 bits = symbol, upper 7 bits = code length.
    /// If code length is 0, the entry is invalid.
    table: [1 << max_bits]u16,

    /// Number of symbols in this tree.
    symbol_count: u16,

    const Self = @This();

    /// Sentinel value for invalid table entries.
    const invalid_entry: u16 = 0;

    /// Build a Huffman tree from code lengths.
    ///
    /// Code lengths of 0 indicate symbols not present in the tree.
    /// This implements the algorithm from RFC 1951 section 3.2.2.
    pub fn build(code_lengths: []const u4) HuffmanError!Self {
        var self = Self{
            .table = [_]u16{invalid_entry} ** (1 << max_bits),
            .symbol_count = @intCast(code_lengths.len),
        };

        // Count codes of each length
        var bl_count: [max_bits + 1]u16 = [_]u16{0} ** (max_bits + 1);
        for (code_lengths) |len| {
            bl_count[len] += 1;
        }

        // Check for valid code lengths (bl_count[0] symbols have no code)
        bl_count[0] = 0;

        // Find the numerical value of the smallest code for each code length
        var next_code: [max_bits + 1]u16 = [_]u16{0} ** (max_bits + 1);
        var code: u16 = 0;
        for (1..max_bits + 1) |bits| {
            code = (code + bl_count[bits - 1]) << 1;
            next_code[bits] = code;
        }

        // Validate: check that the tree is complete or empty
        // Sum of 2^(max_bits - len) for all codes should equal 2^max_bits
        // for a complete tree, or 0 for an empty tree.
        var total: u32 = 0;
        for (1..max_bits + 1) |bits| {
            total += @as(u32, bl_count[bits]) << @intCast(max_bits - bits);
        }
        // total should be 0 (empty) or 2^max_bits (complete) or less (incomplete but valid for deflate)
        if (total > (1 << max_bits)) {
            return error.InvalidCodeLengths;
        }

        // Assign codes to symbols and populate lookup table
        for (code_lengths, 0..) |len, symbol| {
            if (len != 0) {
                const huffman_code = next_code[len];
                next_code[len] += 1;

                // Reverse bits for table lookup (DEFLATE reads LSB first)
                const reversed = bitReverse(huffman_code, len);

                // Fill all table entries that match this code
                // (entries where extra bits beyond code length vary)
                const fill_count = @as(usize, 1) << @intCast(max_bits - len);
                const fill_step = @as(usize, 1) << @intCast(len);

                var idx: usize = reversed;
                for (0..fill_count) |_| {
                    // Entry: symbol in lower 9 bits, length in upper 7 bits
                    self.table[idx] = @as(u16, @intCast(symbol)) | (@as(u16, len) << 9);
                    idx += fill_step;
                }
            }
        }

        return self;
    }

    /// Decode one symbol from a bit reader.
    ///
    /// Reads bits LSB-first and looks up the symbol in the table.
    pub fn decode(self: *const Self, reader: anytype) !u16 {
        // Peek max_bits bits
        const bits = try reader.peekBits(max_bits);
        const entry = self.table[bits];

        if (entry == invalid_entry) {
            return error.InvalidCode;
        }

        const symbol = entry & 0x1FF;
        const len = entry >> 9;

        // Consume the bits we used
        reader.consumeBits(@intCast(len));

        return symbol;
    }
};

/// Reverse the low `bits` bits of `value`.
fn bitReverse(value: u16, bits: u4) u16 {
    if (bits == 0) return 0;

    var result: u16 = 0;
    var v = value;
    for (0..bits) |_| {
        result = (result << 1) | (v & 1);
        v >>= 1;
    }
    return result;
}

/// Fixed Huffman codes for literals/lengths as defined in RFC 1951 section 3.2.6.
///
/// Literals 0-143: 8 bits (codes 00110000-10111111)
/// Literals 144-255: 9 bits (codes 110010000-111111111)
/// Lengths 256-279: 7 bits (codes 0000000-0010111)
/// Lengths 280-287: 8 bits (codes 11000000-11000111)
pub const fixed_literal_tree: HuffmanTree = blk: {
    @setEvalBranchQuota(100_000);
    var lengths: [288]u4 = undefined;

    // 0-143: 8 bits
    for (0..144) |i| {
        lengths[i] = 8;
    }
    // 144-255: 9 bits
    for (144..256) |i| {
        lengths[i] = 9;
    }
    // 256-279: 7 bits
    for (256..280) |i| {
        lengths[i] = 7;
    }
    // 280-287: 8 bits
    for (280..288) |i| {
        lengths[i] = 8;
    }

    break :blk HuffmanTree.build(&lengths) catch unreachable;
};

/// Fixed Huffman codes for distances as defined in RFC 1951 section 3.2.6.
///
/// All 32 distance codes use 5 bits.
pub const fixed_distance_tree: HuffmanTree = blk: {
    @setEvalBranchQuota(100_000);
    var lengths: [32]u4 = undefined;
    for (0..32) |i| {
        lengths[i] = 5;
    }
    break :blk HuffmanTree.build(&lengths) catch unreachable;
};

// Tests

test "bitReverse" {
    try std.testing.expectEqual(@as(u16, 0b0), bitReverse(0b0, 1));
    try std.testing.expectEqual(@as(u16, 0b1), bitReverse(0b1, 1));
    try std.testing.expectEqual(@as(u16, 0b01), bitReverse(0b10, 2));
    try std.testing.expectEqual(@as(u16, 0b10), bitReverse(0b01, 2));
    try std.testing.expectEqual(@as(u16, 0b1010), bitReverse(0b0101, 4));
    try std.testing.expectEqual(@as(u16, 0b11001010), bitReverse(0b01010011, 8));
}

test "HuffmanTree.build simple" {
    // Simple tree: symbol 0 = code 0 (1 bit), symbol 1 = code 1 (1 bit)
    const lengths = [_]u4{ 1, 1 };
    const tree = try HuffmanTree.build(&lengths);

    // Check that both codes decode correctly
    // Code 0 (1 bit) -> symbol 0
    const entry0 = tree.table[0];
    try std.testing.expectEqual(@as(u16, 0), entry0 & 0x1FF); // symbol
    try std.testing.expectEqual(@as(u16, 1), entry0 >> 9); // length

    // Code 1 (1 bit) -> symbol 1
    const entry1 = tree.table[1];
    try std.testing.expectEqual(@as(u16, 1), entry1 & 0x1FF); // symbol
    try std.testing.expectEqual(@as(u16, 1), entry1 >> 9); // length
}

test "HuffmanTree.build varying lengths" {
    // A = 0 (1 bit), B = 10 (2 bits), C = 110 (3 bits), D = 111 (3 bits)
    // Code lengths: A=1, B=2, C=3, D=3
    const lengths = [_]u4{ 1, 2, 3, 3 };
    const tree = try HuffmanTree.build(&lengths);

    // Verify codes (reversed for table lookup):
    // A: code 0, reversed 0 -> symbol 0
    // B: code 10, reversed 01 -> symbol 1
    // C: code 110, reversed 011 -> symbol 2
    // D: code 111, reversed 111 -> symbol 3

    const entry_a = tree.table[0b0];
    try std.testing.expectEqual(@as(u16, 0), entry_a & 0x1FF);
    try std.testing.expectEqual(@as(u16, 1), entry_a >> 9);

    const entry_b = tree.table[0b01];
    try std.testing.expectEqual(@as(u16, 1), entry_b & 0x1FF);
    try std.testing.expectEqual(@as(u16, 2), entry_b >> 9);

    const entry_c = tree.table[0b011];
    try std.testing.expectEqual(@as(u16, 2), entry_c & 0x1FF);
    try std.testing.expectEqual(@as(u16, 3), entry_c >> 9);

    const entry_d = tree.table[0b111];
    try std.testing.expectEqual(@as(u16, 3), entry_d & 0x1FF);
    try std.testing.expectEqual(@as(u16, 3), entry_d >> 9);
}

test "HuffmanTree.build with zero lengths" {
    // Only symbols 1 and 3 are present
    const lengths = [_]u4{ 0, 1, 0, 1 };
    const tree = try HuffmanTree.build(&lengths);

    // Symbol 1: code 0 (1 bit)
    // Symbol 3: code 1 (1 bit)
    const entry1 = tree.table[0];
    try std.testing.expectEqual(@as(u16, 1), entry1 & 0x1FF);

    const entry3 = tree.table[1];
    try std.testing.expectEqual(@as(u16, 3), entry3 & 0x1FF);
}

test "HuffmanTree.decode" {
    // Simple tree: A=0 (1 bit), B=10 (2 bits), C=11 (2 bits)
    // After canonical Huffman:
    //   Symbol 0: code 0 (1 bit), reversed for lookup = 0
    //   Symbol 1: code 10 (2 bits), reversed for lookup = 01 = 1
    //   Symbol 2: code 11 (2 bits), reversed for lookup = 11 = 3
    const lengths = [_]u4{ 1, 2, 2 };
    const tree = try HuffmanTree.build(&lengths);

    // Build bit stream for decoding A, B, C in sequence:
    // A needs LSBs = 0 (1 bit)
    // B needs LSBs = 01 (2 bits), which is value 1
    // C needs LSBs = 11 (2 bits), which is value 3
    //
    // Packed LSB first: bit0=0(A), bit1=1(B), bit2=0(B), bit3=1(C), bit4=1(C)
    // = 0b11_01_0 = 0x1A at low bits
    // Need enough bytes for peekBits(15) - at least 2 bytes needed
    const data = [_]u8{ 0x1A, 0x00, 0x00 };
    var reader = BitReader.init(&data);

    // Decode A (symbol 0)
    const sym_a = try tree.decode(&reader);
    try std.testing.expectEqual(@as(u16, 0), sym_a);

    // Decode B (symbol 1)
    const sym_b = try tree.decode(&reader);
    try std.testing.expectEqual(@as(u16, 1), sym_b);

    // Decode C (symbol 2)
    const sym_c = try tree.decode(&reader);
    try std.testing.expectEqual(@as(u16, 2), sym_c);
}

test "fixed literal tree structure" {
    // Verify some known fixed Huffman codes
    // These are standard codes from RFC 1951

    // Symbol 0 should decode from 8-bit code 00110000 (reversed: 00001100 = 12)
    const entry0 = fixed_literal_tree.table[0b00001100];
    try std.testing.expectEqual(@as(u16, 0), entry0 & 0x1FF);
    try std.testing.expectEqual(@as(u16, 8), entry0 >> 9);

    // Symbol 256 (end of block) should use 7 bits
    // Code pattern for 256-279 starts at 0000000
    // Symbol 256 = code 0000000 (7 bits), reversed = 0000000
    const entry256 = fixed_literal_tree.table[0b0000000];
    try std.testing.expectEqual(@as(u16, 256), entry256 & 0x1FF);
    try std.testing.expectEqual(@as(u16, 7), entry256 >> 9);
}

test "fixed distance tree structure" {
    // All distance codes are 5 bits
    // Code 0 = 00000 (distance 1)
    const entry0 = fixed_distance_tree.table[0];
    try std.testing.expectEqual(@as(u16, 0), entry0 & 0x1FF);
    try std.testing.expectEqual(@as(u16, 5), entry0 >> 9);

    // Code 1 = 00001, reversed = 10000
    const entry1 = fixed_distance_tree.table[0b10000];
    try std.testing.expectEqual(@as(u16, 1), entry1 & 0x1FF);
    try std.testing.expectEqual(@as(u16, 5), entry1 >> 9);
}
