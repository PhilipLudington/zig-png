//! Bit-level writer for deflate compression.
//!
//! Writes bits to a byte buffer in LSB-first order as required by
//! the DEFLATE specification (RFC 1951).

const std = @import("std");

pub const BitWriterError = error{
    BufferOverflow,
};

/// Bit writer that outputs bits in LSB-first order to a buffer.
/// This is the order required by DEFLATE (RFC 1951).
pub const BitWriter = struct {
    buffer: []u8,
    pos: usize,
    bit_buffer: u32,
    bits_in_buffer: u5,

    const Self = @This();

    /// Initialize a BitWriter with an output buffer.
    pub fn init(buffer: []u8) Self {
        return .{
            .buffer = buffer,
            .pos = 0,
            .bit_buffer = 0,
            .bits_in_buffer = 0,
        };
    }

    /// Write n bits to the stream (LSB first).
    /// n can be 0-16.
    pub fn writeBits(self: *Self, value: u16, n: u5) BitWriterError!void {
        // Add bits to buffer
        self.bit_buffer |= @as(u32, value) << self.bits_in_buffer;
        self.bits_in_buffer += n;

        // Flush complete bytes
        while (self.bits_in_buffer >= 8) {
            if (self.pos >= self.buffer.len) {
                return error.BufferOverflow;
            }
            self.buffer[self.pos] = @intCast(self.bit_buffer & 0xFF);
            self.pos += 1;
            self.bit_buffer >>= 8;
            self.bits_in_buffer -= 8;
        }
    }

    /// Write a single bit.
    pub fn writeBit(self: *Self, bit: u1) BitWriterError!void {
        try self.writeBits(@intCast(bit), 1);
    }

    /// Write an aligned byte. Pads with zeros to byte boundary first.
    pub fn writeByte(self: *Self, byte: u8) BitWriterError!void {
        try self.flush();
        if (self.pos >= self.buffer.len) {
            return error.BufferOverflow;
        }
        self.buffer[self.pos] = byte;
        self.pos += 1;
    }

    /// Write multiple aligned bytes. Pads to byte boundary first.
    pub fn writeBytes(self: *Self, bytes: []const u8) BitWriterError!void {
        try self.flush();
        if (self.pos + bytes.len > self.buffer.len) {
            return error.BufferOverflow;
        }
        @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    /// Flush any remaining bits, padding with zeros to byte boundary.
    /// Returns the number of bytes written total.
    pub fn flush(self: *Self) BitWriterError!void {
        if (self.bits_in_buffer > 0) {
            if (self.pos >= self.buffer.len) {
                return error.BufferOverflow;
            }
            self.buffer[self.pos] = @intCast(self.bit_buffer & 0xFF);
            self.pos += 1;
            self.bit_buffer = 0;
            self.bits_in_buffer = 0;
        }
    }

    /// Get the written data as a slice.
    /// Note: Call flush() first to ensure all bits are written.
    pub fn getWritten(self: Self) []u8 {
        return self.buffer[0..self.pos];
    }

    /// Get the number of bytes written (after flush).
    pub fn bytesWritten(self: Self) usize {
        return self.pos;
    }

    /// Reset the writer for reuse.
    pub fn reset(self: *Self) void {
        self.pos = 0;
        self.bit_buffer = 0;
        self.bits_in_buffer = 0;
    }
};

// Tests

test "writeBits basic" {
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Write 4 bits: 0b0100 = 4
    try writer.writeBits(0x4, 4);
    // Write 4 bits: 0b1011 = 11
    try writer.writeBits(0xB, 4);
    // Should combine to 0b10110100 = 0xB4
    try writer.flush();

    try std.testing.expectEqual(@as(usize, 1), writer.bytesWritten());
    try std.testing.expectEqual(@as(u8, 0xB4), writer.getWritten()[0]);
}

test "writeBits 16 bits" {
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    try writer.writeBits(0x1234, 16);
    try writer.flush();

    try std.testing.expectEqual(@as(usize, 2), writer.bytesWritten());
    // LSB first: 0x34, 0x12
    try std.testing.expectEqual(@as(u8, 0x34), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x12), buffer[1]);
}

test "writeBit" {
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Write bits: 0, 0, 1, 0, 1, 1, 0, 1 -> 0b10110100 = 0xB4
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(1);
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(1);
    try writer.flush();

    try std.testing.expectEqual(@as(u8, 0xB4), buffer[0]);
}

test "writeByte aligned" {
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    try writer.writeByte(0xAB);
    try writer.writeByte(0xCD);
    try writer.writeByte(0xEF);

    try std.testing.expectEqual(@as(usize, 3), writer.bytesWritten());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD, 0xEF }, writer.getWritten());
}

test "writeByte after partial bits" {
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Write 3 bits
    try writer.writeBits(0b101, 3);
    // writeByte should pad remaining 5 bits with zeros
    try writer.writeByte(0xAB);

    // First byte should be 0b00000101 = 0x05
    try std.testing.expectEqual(@as(u8, 0x05), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), buffer[1]);
}

test "writeBytes" {
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    try writer.writeBytes(&[_]u8{ 0x01, 0x02, 0x03, 0x04 });

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, writer.getWritten());
}

test "flush pads with zeros" {
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Write 5 bits
    try writer.writeBits(0b10101, 5);
    try writer.flush();

    // Should be padded to 0b00010101 = 0x15
    try std.testing.expectEqual(@as(u8, 0x15), buffer[0]);
    try std.testing.expectEqual(@as(usize, 1), writer.bytesWritten());
}

test "buffer overflow" {
    var buffer: [1]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    try writer.writeByte(0xFF);
    try std.testing.expectError(error.BufferOverflow, writer.writeByte(0x00));
}

test "reset" {
    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    try writer.writeByte(0xFF);
    writer.reset();
    try writer.writeByte(0xAA);

    try std.testing.expectEqual(@as(usize, 1), writer.bytesWritten());
    try std.testing.expectEqual(@as(u8, 0xAA), buffer[0]);
}

test "round trip with BitReader" {
    const bit_reader = @import("bit_reader.zig");

    var buffer: [10]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Write various bit patterns
    try writer.writeBits(0x5, 4);
    try writer.writeBits(0xA, 4);
    try writer.writeBits(0x123, 12);
    try writer.flush();

    // Read back
    var reader = bit_reader.BitReader.init(writer.getWritten());
    try std.testing.expectEqual(@as(u16, 0x5), try reader.readBits(4));
    try std.testing.expectEqual(@as(u16, 0xA), try reader.readBits(4));
    try std.testing.expectEqual(@as(u16, 0x123), try reader.readBits(12));
}
