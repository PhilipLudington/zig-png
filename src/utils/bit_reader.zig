//! Bit-level reader for deflate/inflate decompression.
//!
//! Reads bits from a byte stream in LSB-first order as required by
//! the DEFLATE specification (RFC 1951).

const std = @import("std");

pub const BitReaderError = error{
    EndOfStream,
};

/// Bit reader that wraps a byte slice and reads bits in LSB-first order.
/// This is the order required by DEFLATE (RFC 1951).
pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    bit_buffer: u32,
    bits_in_buffer: u5,

    const Self = @This();

    /// Initialize a BitReader from a byte slice.
    pub fn init(data: []const u8) Self {
        return .{
            .data = data,
            .pos = 0,
            .bit_buffer = 0,
            .bits_in_buffer = 0,
        };
    }

    /// Read n bits from the stream (LSB first).
    /// n can be 0-16.
    pub fn readBits(self: *Self, n: u5) BitReaderError!u16 {
        // Fill buffer if needed
        while (self.bits_in_buffer < n) {
            if (self.pos >= self.data.len) {
                if (self.bits_in_buffer >= n) break;
                return error.EndOfStream;
            }
            self.bit_buffer |= @as(u32, self.data[self.pos]) << self.bits_in_buffer;
            self.pos += 1;
            self.bits_in_buffer += 8;
        }

        // Extract n bits
        const mask: u32 = (@as(u32, 1) << n) - 1;
        const result: u16 = @intCast(self.bit_buffer & mask);
        self.bit_buffer >>= n;
        self.bits_in_buffer -= n;

        return result;
    }

    /// Read a single bit.
    pub fn readBit(self: *Self) BitReaderError!u1 {
        return @intCast(try self.readBits(1));
    }

    /// Read an aligned byte. Discards any partial bits.
    pub fn readByte(self: *Self) BitReaderError!u8 {
        self.alignToByte();
        if (self.pos >= self.data.len) {
            return error.EndOfStream;
        }
        const byte = self.data[self.pos];
        self.pos += 1;
        return byte;
    }

    /// Read multiple aligned bytes. Discards any partial bits first.
    pub fn readBytes(self: *Self, dest: []u8) BitReaderError!void {
        self.alignToByte();
        for (dest) |*b| {
            b.* = try self.readByte();
        }
    }

    /// Skip to the next byte boundary, discarding any buffered bits.
    pub fn alignToByte(self: *Self) void {
        self.bit_buffer = 0;
        self.bits_in_buffer = 0;
    }

    /// Peek at up to 16 bits without consuming them.
    /// Fills the buffer as needed to satisfy the request.
    pub fn peekBits(self: *Self, n: u5) BitReaderError!u16 {
        // Fill buffer if needed
        while (self.bits_in_buffer < n) {
            if (self.pos >= self.data.len) {
                if (self.bits_in_buffer >= n) break;
                return error.EndOfStream;
            }
            self.bit_buffer |= @as(u32, self.data[self.pos]) << self.bits_in_buffer;
            self.pos += 1;
            self.bits_in_buffer += 8;
        }

        // Extract n bits without consuming
        const mask: u32 = (@as(u32, 1) << n) - 1;
        return @intCast(self.bit_buffer & mask);
    }

    /// Consume n bits that were previously peeked.
    pub fn consumeBits(self: *Self, n: u5) void {
        self.bit_buffer >>= n;
        self.bits_in_buffer -= n;
    }

    /// Check if we've reached the end of the stream.
    pub fn isAtEnd(self: Self) bool {
        return self.pos >= self.data.len and self.bits_in_buffer == 0;
    }

    /// Get the number of remaining bits (approximate, doesn't count buffer precisely for unaligned).
    pub fn remainingBytes(self: Self) usize {
        return self.data.len - self.pos;
    }
};

// Tests

test "readBits basic" {
    // 0b10110100 = 0xB4, 0b11001010 = 0xCA
    const data = [_]u8{ 0xB4, 0xCA };
    var reader = BitReader.init(&data);

    // Read 4 bits: should get 0b0100 = 4 (LSB first from 0xB4)
    try std.testing.expectEqual(@as(u16, 0x4), try reader.readBits(4));

    // Read 4 more bits: should get 0b1011 = 11
    try std.testing.expectEqual(@as(u16, 0xB), try reader.readBits(4));

    // Read 8 bits: should get 0xCA
    try std.testing.expectEqual(@as(u16, 0xCA), try reader.readBits(8));
}

test "readBits crosses byte boundary" {
    const data = [_]u8{ 0xFF, 0x00 };
    var reader = BitReader.init(&data);

    // Read 4 bits: 0xF
    try std.testing.expectEqual(@as(u16, 0xF), try reader.readBits(4));

    // Read 8 bits across boundary: 0x0F (4 bits from first byte, 4 from second)
    try std.testing.expectEqual(@as(u16, 0x0F), try reader.readBits(8));
}

test "readBit" {
    const data = [_]u8{0b10110100};
    var reader = BitReader.init(&data);

    // LSB first: 0, 0, 1, 0, 1, 1, 0, 1
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
}

test "readByte aligned" {
    const data = [_]u8{ 0xAB, 0xCD, 0xEF };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(u8, 0xAB), try reader.readByte());
    try std.testing.expectEqual(@as(u8, 0xCD), try reader.readByte());
    try std.testing.expectEqual(@as(u8, 0xEF), try reader.readByte());
}

test "readByte after partial bits" {
    const data = [_]u8{ 0xFF, 0xAB };
    var reader = BitReader.init(&data);

    // Read 3 bits
    _ = try reader.readBits(3);

    // readByte should discard remaining 5 bits and read next byte
    try std.testing.expectEqual(@as(u8, 0xAB), try reader.readByte());
}

test "alignToByte" {
    const data = [_]u8{ 0xFF, 0xAB };
    var reader = BitReader.init(&data);

    // Read some bits
    _ = try reader.readBits(5);

    // Align to byte boundary
    reader.alignToByte();

    // Should now read the second byte
    try std.testing.expectEqual(@as(u8, 0xAB), try reader.readByte());
}

test "readBits zero" {
    const data = [_]u8{0xFF};
    var reader = BitReader.init(&data);

    // Reading 0 bits should return 0
    try std.testing.expectEqual(@as(u16, 0), try reader.readBits(0));
}

test "readBits end of stream" {
    const data = [_]u8{0xFF};
    var reader = BitReader.init(&data);

    _ = try reader.readBits(8);

    // Should error on next read
    try std.testing.expectError(error.EndOfStream, reader.readBits(1));
}

test "readBytes" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var reader = BitReader.init(&data);

    var buf: [4]u8 = undefined;
    try reader.readBytes(&buf);
    try std.testing.expectEqualSlices(u8, &data, &buf);
}

test "isAtEnd" {
    const data = [_]u8{0xFF};
    var reader = BitReader.init(&data);

    try std.testing.expect(!reader.isAtEnd());
    _ = try reader.readBits(8);
    try std.testing.expect(reader.isAtEnd());
}

test "read 16 bits" {
    // Test reading full 16 bits at once
    const data = [_]u8{ 0x34, 0x12 }; // Little-endian 0x1234
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(u16, 0x1234), try reader.readBits(16));
}

test "peekBits and consumeBits" {
    const data = [_]u8{ 0xB4, 0xCA };
    var reader = BitReader.init(&data);

    // Peek 4 bits without consuming
    try std.testing.expectEqual(@as(u16, 0x4), try reader.peekBits(4));
    // Peek again - should return same value
    try std.testing.expectEqual(@as(u16, 0x4), try reader.peekBits(4));

    // Consume those 4 bits
    reader.consumeBits(4);

    // Now peek should return next 4 bits
    try std.testing.expectEqual(@as(u16, 0xB), try reader.peekBits(4));
    reader.consumeBits(4);

    // Peek more bits than remaining
    try std.testing.expectEqual(@as(u16, 0xCA), try reader.peekBits(8));
}

test "peekBits extended" {
    const data = [_]u8{ 0xFF, 0x00, 0xAA };
    var reader = BitReader.init(&data);

    // Peek 15 bits (needs to load multiple bytes)
    const peeked = try reader.peekBits(15);
    try std.testing.expectEqual(@as(u16, 0x00FF), peeked);
}
