//! Zig PNG Library
//!
//! A pure Zig implementation of PNG image encoding and decoding.
//! Supports all standard PNG color types, bit depths, and interlacing methods.

const std = @import("std");

// Re-export public types
// TODO: Uncomment as modules are implemented
// pub const Image = @import("decoder.zig").Image;
// pub const Header = @import("chunks/critical.zig").Header;
// pub const ColorType = @import("color.zig").ColorType;
// pub const BitDepth = @import("color.zig").BitDepth;
// pub const FilterType = @import("color.zig").FilterType;
// pub const InterlaceMethod = @import("color.zig").InterlaceMethod;

/// PNG file signature
pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

/// Decode a PNG image from a reader
pub fn decode(allocator: std.mem.Allocator, reader: anytype) !void {
    _ = allocator;
    _ = reader;
    @panic("Not implemented");
}

/// Decode a PNG image from a memory buffer
pub fn decodeBuffer(allocator: std.mem.Allocator, buffer: []const u8) !void {
    _ = allocator;
    _ = buffer;
    @panic("Not implemented");
}

/// Decode a PNG image from a file path
pub fn decodeFile(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    _ = path;
    @panic("Not implemented");
}

test {
    // Import all test modules
    _ = @import("color.zig");
    // _ = @import("filters.zig");
    // _ = @import("decoder.zig");
    // _ = @import("encoder.zig");
    // _ = @import("interlace.zig");
    _ = @import("chunks/chunks.zig");
    _ = @import("chunks/critical.zig");
    // _ = @import("chunks/ancillary.zig");
    // _ = @import("compression/huffman.zig");
    // _ = @import("compression/inflate.zig");
    // _ = @import("compression/deflate.zig");
    // _ = @import("compression/zlib.zig");
    // _ = @import("compression/lz77.zig");
    _ = @import("utils/crc32.zig");
    _ = @import("utils/adler32.zig");
    _ = @import("utils/bit_reader.zig");
    _ = @import("utils/bit_writer.zig");
}

test "png signature is correct" {
    try std.testing.expectEqual(@as(usize, 8), signature.len);
    try std.testing.expectEqual(@as(u8, 0x89), signature[0]);
    try std.testing.expectEqual(@as(u8, 'P'), signature[1]);
    try std.testing.expectEqual(@as(u8, 'N'), signature[2]);
    try std.testing.expectEqual(@as(u8, 'G'), signature[3]);
}
