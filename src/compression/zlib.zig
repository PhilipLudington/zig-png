//! Zlib compression and decompression (RFC 1950).
//!
//! Wraps DEFLATE with zlib header and Adler32 checksum.
//! This is the compression format used by PNG for image data.

const std = @import("std");
const adler32_mod = @import("../utils/adler32.zig");
const inflate_mod = @import("inflate.zig");
const deflate_mod = @import("deflate.zig");
const BitWriter = @import("../utils/bit_writer.zig").BitWriter;

/// Zlib decompression errors.
pub const ZlibError = error{
    InvalidHeader,
    InvalidCompressionMethod,
    InvalidWindowSize,
    InvalidChecksum,
    ChecksumMismatch,
    DictNotSupported,
} || inflate_mod.InflateError;

/// Zlib compression method (only deflate is supported).
pub const CompressionMethod = enum(u4) {
    deflate = 8,
};

/// Maximum window size for zlib (32KB, encoded as 7).
pub const max_window_bits = 15;

/// Parse zlib header and verify it.
pub fn parseHeader(data: []const u8) ZlibError!struct { window_size: u16, has_dict: bool } {
    if (data.len < 2) {
        return error.InvalidHeader;
    }

    const cmf = data[0];
    const flg = data[1];

    // Validate header checksum (CMF*256 + FLG must be multiple of 31)
    const check: u16 = @as(u16, cmf) * 256 + flg;
    if (check % 31 != 0) {
        return error.InvalidChecksum;
    }

    // Parse CMF: compression method (low 4 bits) and compression info (high 4 bits)
    const cm = cmf & 0x0F;
    const cinfo = (cmf >> 4) & 0x0F;

    // Only deflate (CM=8) is supported
    if (cm != 8) {
        return error.InvalidCompressionMethod;
    }

    // CINFO is log2(window_size) - 8, max value is 7 (32KB window)
    if (cinfo > 7) {
        return error.InvalidWindowSize;
    }

    // Calculate window size: 2^(cinfo + 8)
    const window_size = @as(u16, 1) << @intCast(cinfo + 8);

    // Check FDICT flag (bit 5 of FLG)
    const has_dict = (flg & 0x20) != 0;

    return .{
        .window_size = window_size,
        .has_dict = has_dict,
    };
}

/// Decompress zlib data into an output buffer.
///
/// The input must be complete zlib data including header and Adler32 checksum.
/// Returns the number of decompressed bytes.
pub fn decompress(input: []const u8, output: []u8) ZlibError!usize {
    // Parse and validate header
    const header = try parseHeader(input);

    // Dictionary not supported
    if (header.has_dict) {
        return error.DictNotSupported;
    }

    // Skip zlib header (2 bytes)
    var data_start: usize = 2;
    if (header.has_dict) {
        // Skip dictionary ID (4 bytes) - not supported but handle position
        data_start += 4;
    }

    if (input.len < data_start + 4) {
        return error.InvalidHeader;
    }

    // Decompress the deflate data
    // We need to leave room for the Adler32 checksum at the end (4 bytes)
    // But we can't know exactly where deflate ends until we decompress...
    // So we pass all remaining data and the inflate will stop at the right place

    // Create padded input for inflate (needs extra bytes for peekBits)
    // The Adler32 checksum acts as padding
    const deflate_data = input[data_start..];
    const decompressed_len = try inflate_mod.inflate(deflate_data, output);

    // Calculate Adler32 of decompressed data
    const computed_checksum = adler32_mod.adler32(output[0..decompressed_len]);

    // Read stored Adler32 from end of input (big-endian)
    if (input.len < 4) {
        return error.InvalidHeader;
    }
    const stored_checksum = std.mem.readInt(u32, input[input.len - 4 ..][0..4], .big);

    // Verify checksum
    if (computed_checksum != stored_checksum) {
        return error.ChecksumMismatch;
    }

    return decompressed_len;
}

// ============================================================================
// Zlib Compression
// ============================================================================

/// Zlib compression errors.
pub const ZlibCompressError = error{
    BufferOverflow,
} || deflate_mod.DeflateError;

/// Compression level for zlib.
pub const CompressionLevel = deflate_mod.CompressionLevel;

/// Generate zlib header bytes.
///
/// Returns CMF and FLG bytes with valid checksum.
pub fn generateHeader(level: CompressionLevel) [2]u8 {
    // CMF: CM=8 (deflate), CINFO=7 (32KB window)
    const cmf: u8 = 0x78;

    // FLG: FCHECK + FLEVEL
    // FDICT = 0 (no dictionary)
    // FLEVEL based on compression level
    const flevel: u8 = switch (level) {
        .store, .fastest => 0, // Fastest
        .fast => 1, // Fast
        .default => 2, // Default
        .best => 3, // Maximum
    };

    // Calculate FCHECK so (CMF * 256 + FLG) % 31 == 0
    var flg: u8 = (flevel << 6);
    const base: u16 = @as(u16, cmf) * 256 + flg;
    const fcheck: u8 = @intCast((31 - (base % 31)) % 31);
    flg |= fcheck;

    return .{ cmf, flg };
}

/// Compress data using zlib format.
///
/// Writes zlib header, deflate-compressed data, and Adler32 checksum.
/// Returns the number of bytes written to output.
pub fn compress(
    input: []const u8,
    output: []u8,
    level: CompressionLevel,
) ZlibCompressError!usize {
    if (output.len < 6) {
        return error.BufferOverflow;
    }

    var pos: usize = 0;

    // Write zlib header
    const header = generateHeader(level);
    output[pos] = header[0];
    output[pos + 1] = header[1];
    pos += 2;

    // Compress data using deflate
    var writer = BitWriter.init(output[pos..]);
    var compressor = deflate_mod.Deflate.init(&writer, level);
    try compressor.compress(input);
    try writer.flush();
    pos += writer.bytesWritten();

    // Calculate and write Adler32 checksum (big-endian)
    const checksum = adler32_mod.adler32(input);
    if (pos + 4 > output.len) {
        return error.BufferOverflow;
    }
    std.mem.writeInt(u32, output[pos..][0..4], checksum, .big);
    pos += 4;

    return pos;
}

// Tests

test "parseHeader valid" {
    // CMF=0x78 (deflate, window=32KB), FLG=0x9C (check passes)
    const header = [_]u8{ 0x78, 0x9C };
    const result = try parseHeader(&header);

    try std.testing.expectEqual(@as(u16, 32768), result.window_size);
    try std.testing.expect(!result.has_dict);
}

test "parseHeader with dict" {
    // CMF=0x78, FLG with FDICT set (need different FLG to pass checksum)
    // 0x78 * 256 + FLG must be divisible by 31
    // With FDICT=1 (bit 5), we need FLG where (0x78 * 256 + FLG) % 31 == 0
    // 0x7800 = 30720, 30720 % 31 = 15, so we need FLG where (FLG + 15) % 31 == 0
    // and FLG has bit 5 set. FLG = 0x20 + x where (0x20 + x + 15) % 31 == 0
    // 0x20 = 32, so (32 + 15 + x) % 31 == 0 => (47 + x) % 31 == 0 => x = 15 - 47%31 = 15 - 16 = -1
    // Let's try FLG = 0xBB: 30720 + 187 = 30907, 30907 % 31 = 0 ✓ but 0xBB & 0x20 = 0x20 ✓

    const header = [_]u8{ 0x78, 0xBB };
    const result = try parseHeader(&header);
    try std.testing.expect(result.has_dict);
}

test "parseHeader invalid checksum" {
    const header = [_]u8{ 0x78, 0x00 }; // Invalid: 0x7800 % 31 != 0
    try std.testing.expectError(error.InvalidChecksum, parseHeader(&header));
}

test "parseHeader invalid method" {
    // CM != 8
    // Need valid checksum first: CMF * 256 + FLG must be divisible by 31
    // CMF=0x79 has CM=9 (invalid), CINFO=7
    // 0x79 * 256 = 30976, 30976 % 31 = 7, need FLG = 24 = 0x18
    const header = [_]u8{ 0x79, 0x18 }; // CM=9, invalid
    try std.testing.expectError(error.InvalidCompressionMethod, parseHeader(&header));
}

test "decompress zlib data" {
    // Zlib-compressed "hello world" with header and Adler32
    // Generated with: python3 -c "import zlib; print([hex(b) for b in zlib.compress(b'hello world', 1)])"
    const input = [_]u8{
        0x78, 0x01, // zlib header
        0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0x28, 0xCF,
        0x2F, 0xCA, 0x49, 0x01, 0x00, // deflate data
        0x1A, 0x0B, 0x04, 0x5D, // Adler32 checksum
    };

    var output: [32]u8 = undefined;
    const len = try decompress(&input, &output);

    try std.testing.expectEqual(@as(usize, 11), len);
    try std.testing.expectEqualSlices(u8, "hello world", output[0..11]);
}

test "decompress checksum mismatch" {
    // Same as above but with wrong checksum
    const input = [_]u8{
        0x78, 0x01,
        0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0x28, 0xCF,
        0x2F, 0xCA, 0x49, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x00, // Wrong checksum
    };

    var output: [32]u8 = undefined;
    try std.testing.expectError(error.ChecksumMismatch, decompress(&input, &output));
}

// Compression tests

test "generateHeader produces valid header" {
    const levels = [_]CompressionLevel{ .store, .fastest, .fast, .default, .best };
    for (levels) |level| {
        const header = generateHeader(level);
        // Verify checksum: (CMF * 256 + FLG) % 31 == 0
        const check: u16 = @as(u16, header[0]) * 256 + header[1];
        try std.testing.expectEqual(@as(u16, 0), check % 31);
        // Verify deflate method
        try std.testing.expectEqual(@as(u8, 8), header[0] & 0x0F);
    }
}

test "compress empty data" {
    var output: [32]u8 = undefined;
    const len = try compress("", &output, .default);

    // Should have header (2) + deflate (small) + checksum (4)
    try std.testing.expect(len >= 6);
    try std.testing.expect(len <= 16);

    // Verify we can decompress it
    var decompressed: [32]u8 = undefined;
    const dec_len = try decompress(output[0..len], &decompressed);
    try std.testing.expectEqual(@as(usize, 0), dec_len);
}

test "compress hello world" {
    const input = "hello world";
    var output: [64]u8 = undefined;
    const len = try compress(input, &output, .default);

    // Verify we can decompress it
    var decompressed: [64]u8 = undefined;
    const dec_len = try decompress(output[0..len], &decompressed);
    try std.testing.expectEqual(@as(usize, 11), dec_len);
    try std.testing.expectEqualSlices(u8, input, decompressed[0..dec_len]);
}

test "compress round-trip all levels" {
    const input = "the quick brown fox jumps over the lazy dog";
    const levels = [_]CompressionLevel{ .store, .fastest, .fast, .default, .best };

    for (levels) |level| {
        var output: [128]u8 = undefined;
        const len = try compress(input, &output, level);

        var decompressed: [128]u8 = undefined;
        const dec_len = try decompress(output[0..len], &decompressed);
        try std.testing.expectEqual(@as(usize, input.len), dec_len);
        try std.testing.expectEqualSlices(u8, input, decompressed[0..dec_len]);
    }
}

test "compress repetitive data compresses well" {
    const input = "abcabcabcabcabcabcabcabcabcabcabcabc"; // 36 bytes
    var output: [64]u8 = undefined;
    const len = try compress(input, &output, .default);

    // Should compress significantly
    try std.testing.expect(len < input.len);

    // Verify round-trip
    var decompressed: [64]u8 = undefined;
    const dec_len = try decompress(output[0..len], &decompressed);
    try std.testing.expectEqualSlices(u8, input, decompressed[0..dec_len]);
}

test "compress larger data" {
    // Generate test data with patterns
    var input: [512]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @intCast((i * 7 + 13) % 256);
    }
    // Add repetition
    @memcpy(input[256..384], input[0..128]);

    var output: [1024]u8 = undefined;
    const len = try compress(&input, &output, .default);

    var decompressed: [512]u8 = undefined;
    const dec_len = try decompress(output[0..len], &decompressed);
    try std.testing.expectEqual(@as(usize, 512), dec_len);
    try std.testing.expectEqualSlices(u8, &input, decompressed[0..dec_len]);
}
