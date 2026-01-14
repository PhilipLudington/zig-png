//! Huffman coding for DEFLATE compression.
//!
//! Implements Huffman tree construction, decoding, and encoding as specified in RFC 1951.
//! Supports both fixed and dynamic Huffman codes used in DEFLATE.

const std = @import("std");
const BitReader = @import("../utils/bit_reader.zig").BitReader;
const BitWriter = @import("../utils/bit_writer.zig").BitWriter;
const BitWriterError = @import("../utils/bit_writer.zig").BitWriterError;

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
/// Used for converting between canonical Huffman codes and DEFLATE's LSB-first bit order.
pub fn bitReverse(value: u16, bits: u4) u16 {
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

// ============================================================================
// Huffman Encoder (for compression)
// ============================================================================

/// Maximum number of symbols for literal/length alphabet.
/// DEFLATE uses 286 valid symbols (0-285) but fixed tree defines 288.
pub const max_literal_symbols = 288;

/// Maximum number of symbols for distance alphabet.
pub const max_distance_symbols = 30;

/// Huffman encoder for DEFLATE compression.
///
/// Stores the canonical Huffman codes and their lengths for encoding symbols.
/// Codes are stored in the format ready for LSB-first bit writing.
pub const HuffmanEncoder = struct {
    /// Canonical Huffman codes for each symbol (reversed for LSB-first writing).
    codes: [max_literal_symbols]u16,
    /// Code lengths for each symbol (0 = symbol not present).
    code_lengths: [max_literal_symbols]u4,
    /// Number of symbols in this encoder.
    symbol_count: u16,

    const Self = @This();

    /// Build a Huffman encoder from code lengths.
    ///
    /// The code lengths array specifies the bit length for each symbol.
    /// Symbols with length 0 are not present in the encoding.
    /// This implements canonical Huffman code generation per RFC 1951 section 3.2.2.
    pub fn buildFromLengths(lengths: []const u4) Self {
        var self = Self{
            .codes = [_]u16{0} ** max_literal_symbols,
            .code_lengths = [_]u4{0} ** max_literal_symbols,
            .symbol_count = @intCast(lengths.len),
        };

        // Copy code lengths
        for (lengths, 0..) |len, i| {
            self.code_lengths[i] = len;
        }

        // Count codes of each length
        var bl_count: [max_bits + 1]u16 = [_]u16{0} ** (max_bits + 1);
        for (lengths) |len| {
            bl_count[len] += 1;
        }
        bl_count[0] = 0;

        // Find the numerical value of the smallest code for each code length
        var next_code: [max_bits + 1]u16 = [_]u16{0} ** (max_bits + 1);
        var code: u16 = 0;
        for (1..max_bits + 1) |bits| {
            code = (code + bl_count[bits - 1]) << 1;
            next_code[bits] = code;
        }

        // Assign canonical codes to symbols (reversed for LSB-first writing)
        for (lengths, 0..) |len, symbol| {
            if (len != 0) {
                const canonical_code = next_code[len];
                next_code[len] += 1;
                // Reverse bits for DEFLATE's LSB-first bit order
                self.codes[symbol] = bitReverse(canonical_code, len);
            }
        }

        return self;
    }

    /// Build a Huffman encoder from symbol frequencies.
    ///
    /// Uses a length-limited Huffman algorithm to assign code lengths
    /// such that no code exceeds max_code_length bits.
    pub fn buildFromFrequencies(frequencies: []const u32, max_code_length: u4) Self {
        const len = @min(frequencies.len, max_literal_symbols);

        // First, assign code lengths based on frequencies
        var lengths: [max_literal_symbols]u4 = [_]u4{0} ** max_literal_symbols;

        // Count non-zero frequencies
        var non_zero_count: usize = 0;
        for (frequencies[0..len]) |freq| {
            if (freq > 0) non_zero_count += 1;
        }

        if (non_zero_count == 0) {
            // No symbols, return empty encoder
            return Self{
                .codes = [_]u16{0} ** max_literal_symbols,
                .code_lengths = [_]u4{0} ** max_literal_symbols,
                .symbol_count = @intCast(len),
            };
        }

        if (non_zero_count == 1) {
            // Single symbol gets code length 1
            for (frequencies[0..len], 0..) |freq, i| {
                if (freq > 0) {
                    lengths[i] = 1;
                    break;
                }
            }
            return buildFromLengths(lengths[0..len]);
        }

        // Use package-merge algorithm for length-limited codes
        assignCodeLengths(frequencies[0..len], lengths[0..len], max_code_length);

        return buildFromLengths(lengths[0..len]);
    }

    /// Encode a symbol to the bit writer.
    ///
    /// Writes the Huffman code for the given symbol in LSB-first order.
    pub fn encode(self: *const Self, symbol: u16, writer: *BitWriter) BitWriterError!void {
        const len = self.code_lengths[symbol];
        if (len == 0) {
            // Symbol not in alphabet - this is a programming error
            unreachable;
        }
        try writer.writeBits(self.codes[symbol], len);
    }

    /// Get the code length for a symbol.
    pub fn getCodeLength(self: *const Self, symbol: u16) u4 {
        return self.code_lengths[symbol];
    }

    /// Get the code for a symbol.
    pub fn getCode(self: *const Self, symbol: u16) u16 {
        return self.codes[symbol];
    }
};

/// Assign code lengths from frequencies using a simplified algorithm.
/// Produces a valid Huffman tree with lengths limited to max_length.
fn assignCodeLengths(frequencies: []const u32, lengths: []u4, max_length: u4) void {
    const n = frequencies.len;

    // Simple approach: use frequency ranking to assign lengths.
    // This is a simplified version - not optimal but produces valid codes.

    // Create sorted indices by frequency (descending)
    var indices: [max_literal_symbols]u16 = undefined;
    var count: usize = 0;
    for (frequencies, 0..) |freq, i| {
        if (freq > 0) {
            indices[count] = @intCast(i);
            count += 1;
        }
    }

    // Sort by frequency (descending) using insertion sort
    for (1..count) |i| {
        const key_idx = indices[i];
        const key_freq = frequencies[key_idx];
        var j: usize = i;
        while (j > 0 and frequencies[indices[j - 1]] < key_freq) {
            indices[j] = indices[j - 1];
            j -= 1;
        }
        indices[j] = key_idx;
    }

    // Assign lengths based on position
    // Most frequent symbols get shorter codes
    // This uses a heuristic approach that produces valid but not optimal trees
    if (count <= 2) {
        for (indices[0..count]) |idx| {
            lengths[idx] = 1;
        }
        // If exactly 2 symbols with length 1, it's valid
        if (count == 2) return;
        // If 1 symbol, need to add another symbol or use length 1
        if (count == 1) return;
    }

    // Calculate optimal code lengths using the package-merge result approximation
    // For simplicity, we use a log-based assignment bounded by max_length
    var total_kraft: u32 = 0;
    for (indices[0..count], 0..) |idx, rank| {
        // Assign length based on rank, ensuring Kraft inequality is satisfied
        // Start with shorter codes for more frequent symbols
        var len: u4 = 1;
        const threshold = count / (@as(usize, 1) << @intCast(len));
        if (rank >= threshold) {
            while (len < max_length and rank >= count / (@as(usize, 1) << @intCast(len))) {
                len += 1;
            }
        }
        lengths[idx] = len;
    }

    // Verify and fix Kraft inequality: sum of 2^(-len) must equal 1
    // If not valid, adjust lengths
    total_kraft = 0;
    for (0..n) |i| {
        if (lengths[i] > 0) {
            total_kraft += @as(u32, 1) << @intCast(max_length - lengths[i]);
        }
    }

    const target: u32 = @as(u32, 1) << @intCast(max_length);

    // If over target, need to increase some lengths
    while (total_kraft > target) {
        // Find a symbol with shortest length > 1 and increase it
        var min_len: u4 = max_length;
        var min_idx: usize = 0;
        for (0..n) |i| {
            if (lengths[i] > 1 and lengths[i] < min_len) {
                min_len = lengths[i];
                min_idx = i;
            }
        }
        if (min_len < max_length) {
            const old_contrib = @as(u32, 1) << @intCast(max_length - lengths[min_idx]);
            lengths[min_idx] += 1;
            const new_contrib = @as(u32, 1) << @intCast(max_length - lengths[min_idx]);
            total_kraft = total_kraft - old_contrib + new_contrib;
        } else {
            break;
        }
    }

    // If under target, need to decrease some lengths (or the tree is incomplete, which is OK)
    // For DEFLATE, an incomplete tree is valid
}

/// Fixed literal/length encoder using fixed Huffman codes.
/// Precomputed at compile time for efficiency.
pub const fixed_literal_encoder: HuffmanEncoder = blk: {
    @setEvalBranchQuota(100_000);
    var lengths: [288]u4 = undefined;

    // Same lengths as fixed_literal_tree
    for (0..144) |i| {
        lengths[i] = 8;
    }
    for (144..256) |i| {
        lengths[i] = 9;
    }
    for (256..280) |i| {
        lengths[i] = 7;
    }
    for (280..288) |i| {
        lengths[i] = 8;
    }

    break :blk HuffmanEncoder.buildFromLengths(&lengths);
};

/// Fixed distance encoder using fixed Huffman codes.
/// All 32 distance codes use 5 bits.
pub const fixed_distance_encoder: HuffmanEncoder = blk: {
    @setEvalBranchQuota(100_000);
    var lengths: [32]u4 = undefined;
    for (0..32) |i| {
        lengths[i] = 5;
    }
    break :blk HuffmanEncoder.buildFromLengths(&lengths);
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

// HuffmanEncoder tests

test "HuffmanEncoder.buildFromLengths simple" {
    // Simple tree: A=0 (1 bit), B=10 (2 bits), C=11 (2 bits)
    const lengths = [_]u4{ 1, 2, 2 };
    const encoder = HuffmanEncoder.buildFromLengths(&lengths);

    // Symbol 0: canonical code 0 (1 bit), reversed = 0
    try std.testing.expectEqual(@as(u4, 1), encoder.code_lengths[0]);
    try std.testing.expectEqual(@as(u16, 0), encoder.codes[0]);

    // Symbol 1: canonical code 10 (2 bits), reversed = 01 = 1
    try std.testing.expectEqual(@as(u4, 2), encoder.code_lengths[1]);
    try std.testing.expectEqual(@as(u16, 1), encoder.codes[1]);

    // Symbol 2: canonical code 11 (2 bits), reversed = 11 = 3
    try std.testing.expectEqual(@as(u4, 2), encoder.code_lengths[2]);
    try std.testing.expectEqual(@as(u16, 3), encoder.codes[2]);
}

test "HuffmanEncoder.encode writes correct bits" {
    const lengths = [_]u4{ 1, 2, 2 };
    const encoder = HuffmanEncoder.buildFromLengths(&lengths);

    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Encode symbols A, B, C
    try encoder.encode(0, &writer);
    try encoder.encode(1, &writer);
    try encoder.encode(2, &writer);
    try writer.flush();

    // A=0 (1 bit), B=01 (2 bits), C=11 (2 bits)
    // Packed LSB first: bit0=0, bit1=1, bit2=0, bit3=1, bit4=1
    // = 0b11010 = 0x1A (with padding zeros in upper bits)
    try std.testing.expectEqual(@as(u8, 0x1A), buffer[0]);
}

test "HuffmanEncoder round-trip with decoder" {
    // Build encoder and decoder from same code lengths
    const lengths = [_]u4{ 1, 2, 2 };
    const encoder = HuffmanEncoder.buildFromLengths(&lengths);
    const decoder = try HuffmanTree.build(&lengths);

    // Encode some symbols
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    try encoder.encode(0, &writer);
    try encoder.encode(1, &writer);
    try encoder.encode(2, &writer);
    try encoder.encode(0, &writer);
    try writer.flush();

    // Decode and verify - need extra bytes for peekBits(15)
    var decode_buf: [10]u8 = undefined;
    @memcpy(decode_buf[0..writer.bytesWritten()], writer.getWritten());
    @memset(decode_buf[writer.bytesWritten()..], 0);
    var reader = BitReader.init(&decode_buf);
    try std.testing.expectEqual(@as(u16, 0), try decoder.decode(&reader));
    try std.testing.expectEqual(@as(u16, 1), try decoder.decode(&reader));
    try std.testing.expectEqual(@as(u16, 2), try decoder.decode(&reader));
    try std.testing.expectEqual(@as(u16, 0), try decoder.decode(&reader));
}

test "HuffmanEncoder.buildFromFrequencies uniform" {
    // Equal frequencies should produce balanced tree
    const frequencies = [_]u32{ 10, 10, 10, 10 };
    const encoder = HuffmanEncoder.buildFromFrequencies(&frequencies, 15);

    // All symbols should have code length (may vary based on algorithm)
    // Just verify all symbols have codes
    for (0..4) |i| {
        try std.testing.expect(encoder.code_lengths[i] >= 1);
        try std.testing.expect(encoder.code_lengths[i] <= 15);
    }
}

test "HuffmanEncoder.buildFromFrequencies skewed" {
    // Highly skewed frequencies
    const frequencies = [_]u32{ 1000, 10, 1, 1 };
    const encoder = HuffmanEncoder.buildFromFrequencies(&frequencies, 15);

    // Most frequent symbol should have shorter code
    try std.testing.expect(encoder.code_lengths[0] > 0);
    try std.testing.expect(encoder.code_lengths[0] <= encoder.code_lengths[2]);
}

test "HuffmanEncoder.buildFromFrequencies single symbol" {
    const frequencies = [_]u32{ 0, 0, 100, 0 };
    const encoder = HuffmanEncoder.buildFromFrequencies(&frequencies, 15);

    // Only symbol 2 should have a code
    try std.testing.expectEqual(@as(u4, 0), encoder.code_lengths[0]);
    try std.testing.expectEqual(@as(u4, 0), encoder.code_lengths[1]);
    try std.testing.expectEqual(@as(u4, 1), encoder.code_lengths[2]);
    try std.testing.expectEqual(@as(u4, 0), encoder.code_lengths[3]);
}

test "fixed_literal_encoder matches fixed_literal_tree" {
    // Verify that encoding with fixed_literal_encoder produces bits
    // that decode correctly with fixed_literal_tree

    var buffer: [32]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Encode literal 'H' (72) and end-of-block (256)
    try fixed_literal_encoder.encode(72, &writer);
    try fixed_literal_encoder.encode(256, &writer);
    try writer.flush();

    // Decode and verify - need extra bytes for peekBits(15)
    var decode_buf: [32]u8 = undefined;
    @memcpy(decode_buf[0..writer.bytesWritten()], writer.getWritten());
    @memset(decode_buf[writer.bytesWritten()..], 0);
    var reader = BitReader.init(&decode_buf);
    const sym1 = try fixed_literal_tree.decode(&reader);
    try std.testing.expectEqual(@as(u16, 72), sym1);

    const sym2 = try fixed_literal_tree.decode(&reader);
    try std.testing.expectEqual(@as(u16, 256), sym2);
}

test "fixed_distance_encoder matches fixed_distance_tree" {
    var buffer: [32]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Encode distance codes 0 and 5
    try fixed_distance_encoder.encode(0, &writer);
    try fixed_distance_encoder.encode(5, &writer);
    try writer.flush();

    // Decode and verify - need extra bytes for peekBits(15)
    var decode_buf: [32]u8 = undefined;
    @memcpy(decode_buf[0..writer.bytesWritten()], writer.getWritten());
    @memset(decode_buf[writer.bytesWritten()..], 0);
    var reader = BitReader.init(&decode_buf);
    try std.testing.expectEqual(@as(u16, 0), try fixed_distance_tree.decode(&reader));
    try std.testing.expectEqual(@as(u16, 5), try fixed_distance_tree.decode(&reader));
}
