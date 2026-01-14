//! PNG chunk handling framework.
//!
//! Provides types and functions for reading and writing PNG chunks.
//! Each chunk has a 4-byte length, 4-byte type, data, and 4-byte CRC.

const std = @import("std");
const crc32 = @import("../utils/crc32.zig");

/// PNG chunk type (4 bytes).
pub const ChunkType = [4]u8;

/// Known critical chunk types.
pub const chunk_types = struct {
    pub const IHDR: ChunkType = "IHDR".*;
    pub const PLTE: ChunkType = "PLTE".*;
    pub const IDAT: ChunkType = "IDAT".*;
    pub const IEND: ChunkType = "IEND".*;
};

/// Known ancillary chunk types.
pub const ancillary_types = struct {
    pub const tRNS: ChunkType = "tRNS".*;
    pub const gAMA: ChunkType = "gAMA".*;
    pub const cHRM: ChunkType = "cHRM".*;
    pub const sRGB: ChunkType = "sRGB".*;
    pub const iCCP: ChunkType = "iCCP".*;
    pub const tEXt: ChunkType = "tEXt".*;
    pub const zTXt: ChunkType = "zTXt".*;
    pub const iTXt: ChunkType = "iTXt".*;
    pub const bKGD: ChunkType = "bKGD".*;
    pub const pHYs: ChunkType = "pHYs".*;
    pub const sBIT: ChunkType = "sBIT".*;
    pub const tIME: ChunkType = "tIME".*;
};

/// Errors that can occur during chunk operations.
pub const ChunkError = error{
    InvalidLength,
    InvalidCrc,
    UnexpectedEndOfData,
    InvalidChunkType,
};

/// A raw PNG chunk with its type, data, and CRC.
pub const Chunk = struct {
    chunk_type: ChunkType,
    data: []const u8,
    crc: u32,

    /// Check if this is a critical chunk (uppercase first letter).
    pub fn isCritical(self: Chunk) bool {
        return self.chunk_type[0] & 0x20 == 0;
    }

    /// Check if this is a public chunk (uppercase second letter).
    pub fn isPublic(self: Chunk) bool {
        return self.chunk_type[1] & 0x20 == 0;
    }

    /// Check if this chunk is safe to copy when editing (uppercase fourth letter).
    pub fn isSafeToCopy(self: Chunk) bool {
        return self.chunk_type[3] & 0x20 != 0;
    }

    /// Verify the CRC of this chunk.
    pub fn verifyCrc(self: Chunk) bool {
        return self.crc == calculateCrc(self.chunk_type, self.data);
    }
};

/// Calculate CRC for a chunk (type + data).
pub fn calculateCrc(chunk_type: ChunkType, data: []const u8) u32 {
    var crc_calc = crc32.Crc32.init();
    crc_calc.update(&chunk_type);
    crc_calc.update(data);
    return crc_calc.final();
}

/// Read a chunk from a byte buffer.
/// Returns the chunk and the number of bytes consumed.
pub fn readChunk(buffer: []const u8) ChunkError!struct { chunk: Chunk, bytes_consumed: usize } {
    // Minimum chunk size: 4 (length) + 4 (type) + 0 (data) + 4 (crc) = 12 bytes
    if (buffer.len < 12) {
        return error.UnexpectedEndOfData;
    }

    // Read length (big-endian)
    const length = std.mem.readInt(u32, buffer[0..4], .big);

    // Validate length doesn't exceed reasonable bounds
    if (length > 0x7FFFFFFF) {
        return error.InvalidLength;
    }

    // Check we have enough data
    const total_size = 4 + 4 + length + 4;
    if (buffer.len < total_size) {
        return error.UnexpectedEndOfData;
    }

    // Read type
    const chunk_type: ChunkType = buffer[4..8].*;

    // Validate chunk type (all bytes must be ASCII letters)
    for (chunk_type) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'))) {
            return error.InvalidChunkType;
        }
    }

    // Read data
    const data_start: usize = 8;
    const data_end: usize = data_start + length;
    const data = buffer[data_start..data_end];

    // Read CRC (big-endian)
    const crc_offset = data_end;
    const crc = std.mem.readInt(u32, buffer[crc_offset..][0..4], .big);

    return .{
        .chunk = .{
            .chunk_type = chunk_type,
            .data = data,
            .crc = crc,
        },
        .bytes_consumed = total_size,
    };
}

/// Write a chunk to a buffer.
/// Returns the number of bytes written, or error if buffer too small.
pub fn writeChunk(buffer: []u8, chunk_type: ChunkType, data: []const u8) error{BufferTooSmall}!usize {
    const total_size = 4 + 4 + data.len + 4;
    if (buffer.len < total_size) {
        return error.BufferTooSmall;
    }

    // Write length (big-endian)
    std.mem.writeInt(u32, buffer[0..4], @intCast(data.len), .big);

    // Write type
    @memcpy(buffer[4..8], &chunk_type);

    // Write data
    if (data.len > 0) {
        @memcpy(buffer[8..][0..data.len], data);
    }

    // Calculate and write CRC
    const crc = calculateCrc(chunk_type, data);
    const crc_offset = 8 + data.len;
    std.mem.writeInt(u32, buffer[crc_offset..][0..4], crc, .big);

    return total_size;
}

/// Iterator for reading chunks from a buffer.
pub const ChunkIterator = struct {
    buffer: []const u8,
    pos: usize,

    const Self = @This();

    pub fn init(buffer: []const u8) Self {
        return .{
            .buffer = buffer,
            .pos = 0,
        };
    }

    /// Get the next chunk, or null if at end.
    pub fn next(self: *Self) ChunkError!?Chunk {
        if (self.pos >= self.buffer.len) {
            return null;
        }

        const result = try readChunk(self.buffer[self.pos..]);
        self.pos += result.bytes_consumed;
        return result.chunk;
    }

    /// Skip to the next chunk without returning data.
    pub fn skip(self: *Self) ChunkError!bool {
        if (self.pos >= self.buffer.len) {
            return false;
        }

        const result = try readChunk(self.buffer[self.pos..]);
        self.pos += result.bytes_consumed;
        return true;
    }
};

// Tests

test "chunk type properties" {
    // IHDR: critical, public, not safe to copy
    const ihdr = Chunk{ .chunk_type = "IHDR".*, .data = &.{}, .crc = 0 };
    try std.testing.expect(ihdr.isCritical());
    try std.testing.expect(ihdr.isPublic());
    try std.testing.expect(!ihdr.isSafeToCopy());

    // tEXt: ancillary, public, safe to copy
    const text = Chunk{ .chunk_type = "tEXt".*, .data = &.{}, .crc = 0 };
    try std.testing.expect(!text.isCritical());
    try std.testing.expect(text.isPublic());
    try std.testing.expect(text.isSafeToCopy());

    // Private chunk example (lowercase second letter)
    const priv = Chunk{ .chunk_type = "prIv".*, .data = &.{}, .crc = 0 };
    try std.testing.expect(!priv.isCritical());
    try std.testing.expect(!priv.isPublic());
}

test "calculateCrc" {
    const chunk_type: ChunkType = "IEND".*;
    const empty: []const u8 = &.{};
    const crc = calculateCrc(chunk_type, empty);

    // IEND with no data has a known CRC
    try std.testing.expectEqual(@as(u32, 0xAE426082), crc);
}

test "readChunk valid" {
    // Construct an IEND chunk (empty data)
    var buffer: [12]u8 = undefined;
    std.mem.writeInt(u32, buffer[0..4], 0, .big); // length = 0
    @memcpy(buffer[4..8], "IEND"); // type
    std.mem.writeInt(u32, buffer[8..12], 0xAE426082, .big); // CRC

    const result = try readChunk(&buffer);
    try std.testing.expectEqualSlices(u8, "IEND", &result.chunk.chunk_type);
    try std.testing.expectEqual(@as(usize, 0), result.chunk.data.len);
    try std.testing.expectEqual(@as(u32, 0xAE426082), result.chunk.crc);
    try std.testing.expectEqual(@as(usize, 12), result.bytes_consumed);
    try std.testing.expect(result.chunk.verifyCrc());
}

test "readChunk with data" {
    // IHDR chunk with 13 bytes of data
    var buffer: [25]u8 = undefined;
    std.mem.writeInt(u32, buffer[0..4], 13, .big); // length = 13
    @memcpy(buffer[4..8], "IHDR"); // type
    // Fill with sample IHDR data
    const ihdr_data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // width = 16
        0x00, 0x00, 0x00, 0x10, // height = 16
        0x08, // bit depth = 8
        0x02, // color type = RGB
        0x00, // compression = 0
        0x00, // filter = 0
        0x00, // interlace = 0
    };
    @memcpy(buffer[8..21], &ihdr_data);
    // Calculate and write CRC
    const crc = calculateCrc("IHDR".*, &ihdr_data);
    std.mem.writeInt(u32, buffer[21..25], crc, .big);

    const result = try readChunk(&buffer);
    try std.testing.expectEqualSlices(u8, "IHDR", &result.chunk.chunk_type);
    try std.testing.expectEqual(@as(usize, 13), result.chunk.data.len);
    try std.testing.expectEqual(@as(usize, 25), result.bytes_consumed);
    try std.testing.expect(result.chunk.verifyCrc());
}

test "readChunk invalid type" {
    var buffer: [12]u8 = undefined;
    std.mem.writeInt(u32, buffer[0..4], 0, .big);
    @memcpy(buffer[4..8], "1234"); // Invalid: digits not allowed
    std.mem.writeInt(u32, buffer[8..12], 0, .big);

    try std.testing.expectError(error.InvalidChunkType, readChunk(&buffer));
}

test "readChunk truncated" {
    const buffer = [_]u8{ 0, 0, 0, 10 }; // Length says 10 but only 4 bytes total
    try std.testing.expectError(error.UnexpectedEndOfData, readChunk(&buffer));
}

test "writeChunk" {
    var buffer: [25]u8 = undefined;
    const data = [_]u8{ 1, 2, 3, 4, 5 };

    const written = try writeChunk(&buffer, "tESt".*, &data);
    try std.testing.expectEqual(@as(usize, 17), written);

    // Verify by reading back
    const result = try readChunk(buffer[0..written]);
    try std.testing.expectEqualSlices(u8, "tESt", &result.chunk.chunk_type);
    try std.testing.expectEqualSlices(u8, &data, result.chunk.data);
    try std.testing.expect(result.chunk.verifyCrc());
}

test "writeChunk buffer too small" {
    var buffer: [10]u8 = undefined;
    const data = [_]u8{ 1, 2, 3, 4, 5 };

    try std.testing.expectError(error.BufferTooSmall, writeChunk(&buffer, "tESt".*, &data));
}

test "ChunkIterator" {
    // Build buffer with two chunks: tESt and IEND
    var buffer: [30]u8 = undefined;
    var pos: usize = 0;

    pos += try writeChunk(buffer[pos..], "tESt".*, &[_]u8{ 1, 2, 3 });
    pos += try writeChunk(buffer[pos..], "IEND".*, &.{});

    var iter = ChunkIterator.init(buffer[0..pos]);

    // First chunk
    const chunk1 = (try iter.next()).?;
    try std.testing.expectEqualSlices(u8, "tESt", &chunk1.chunk_type);

    // Second chunk
    const chunk2 = (try iter.next()).?;
    try std.testing.expectEqualSlices(u8, "IEND", &chunk2.chunk_type);

    // No more chunks
    try std.testing.expect(try iter.next() == null);
}
