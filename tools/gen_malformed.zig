//! Malformed PNG generator for fuzz testing.
//!
//! Creates intentionally malformed PNG files to test error handling paths.
//! These files exercise edge cases that valid PNGs wouldn't trigger.
//!
//! Categories of malformed inputs:
//!   - Truncated files (cut off at various points)
//!   - Invalid signatures
//!   - Bad CRC checksums
//!   - Invalid chunk types
//!   - Invalid IHDR values
//!   - Corrupted IDAT data
//!   - Missing required chunks
//!   - Out-of-order chunks
//!   - Oversized dimensions

const std = @import("std");
const Allocator = std.mem.Allocator;

// PNG signature
const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var output_dir: []const u8 = "fuzz_corpus/malformed";

    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            try printUsage();
            return;
        }
        output_dir = args[1];
    }

    // Create output directory
    std.fs.cwd().makePath(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    std.debug.print("Generating malformed PNGs in {s}/\n\n", .{output_dir});

    var count: usize = 0;

    // Generate each category of malformed files
    count += try generateTruncatedFiles(allocator, output_dir);
    count += try generateBadSignatures(allocator, output_dir);
    count += try generateBadCRCs(allocator, output_dir);
    count += try generateInvalidChunkTypes(allocator, output_dir);
    count += try generateInvalidIHDR(allocator, output_dir);
    count += try generateCorruptedIDAT(allocator, output_dir);
    count += try generateMissingChunks(allocator, output_dir);
    count += try generateOutOfOrderChunks(allocator, output_dir);
    count += try generateOversizedDimensions(allocator, output_dir);
    count += try generateEdgeCases(allocator, output_dir);

    std.debug.print("\nGenerated {d} malformed PNG files\n", .{count});
}

fn getStdout() std.fs.File {
    return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

fn printUsage() !void {
    const stdout = getStdout();
    try stdout.writeAll(
        \\Malformed PNG Generator
        \\
        \\Generates intentionally malformed PNG files for fuzz testing.
        \\
        \\Usage:
        \\  gen-malformed [output_dir]    Generate malformed PNGs (default: fuzz_corpus/malformed)
        \\  gen-malformed --help          Show this help
        \\
        \\Categories generated:
        \\  - Truncated files
        \\  - Invalid signatures
        \\  - Bad CRC checksums
        \\  - Invalid chunk types
        \\  - Invalid IHDR values
        \\  - Corrupted IDAT data
        \\  - Missing required chunks
        \\  - Out-of-order chunks
        \\  - Oversized dimensions
        \\
    );
}

fn writeFile(output_dir: []const u8, name: []const u8, data: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ output_dir, name });

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);

    std.debug.print("  Created {s} ({d} bytes)\n", .{ name, data.len });
}

// Create a minimal valid PNG for modification
fn createMinimalPNG(allocator: Allocator) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    // PNG signature
    try buffer.appendSlice(allocator, &png_signature);

    // IHDR chunk (13 bytes of data)
    const ihdr_data = [_]u8{
        0, 0, 0, 8, // width = 8
        0, 0, 0, 8, // height = 8
        8, // bit depth
        2, // color type = RGB
        0, // compression method
        0, // filter method
        0, // interlace method
    };
    try appendChunk(allocator, &buffer, "IHDR", &ihdr_data);

    // Minimal IDAT chunk (compressed single row of pixels)
    // This is a valid zlib stream with minimal RGB data
    const idat_data = [_]u8{
        0x78, 0x9C, // zlib header (deflate, 32K window)
        0x62, 0x60, 0x60, 0x60, // compressed data (filter byte + some pixels)
        0x60, 0x60, 0x60, 0x60,
        0x60, 0x00, 0x00,
        0x00, 0xC1, 0x00, 0x01, // adler32 checksum
    };
    try appendChunk(allocator, &buffer, "IDAT", &idat_data);

    // IEND chunk (0 bytes of data)
    try appendChunk(allocator, &buffer, "IEND", &.{});

    return buffer.toOwnedSlice(allocator);
}

fn appendChunk(allocator: Allocator, buffer: *std.ArrayListUnmanaged(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    // Length (4 bytes, big-endian)
    const len: u32 = @intCast(data.len);
    try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, len)));

    // Chunk type (4 bytes)
    try buffer.appendSlice(allocator, chunk_type);

    // Data
    try buffer.appendSlice(allocator, data);

    // CRC32 (over type + data)
    var crc_data: [512]u8 = undefined;
    @memcpy(crc_data[0..4], chunk_type);
    @memcpy(crc_data[4..][0..data.len], data);
    const crc = std.hash.Crc32.hash(crc_data[0 .. 4 + data.len]);
    try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, crc)));
}

fn generateTruncatedFiles(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Truncated Files ===\n", .{});

    const valid_png = try createMinimalPNG(allocator);
    defer allocator.free(valid_png);

    var count: usize = 0;

    // Truncate at various points
    const truncate_points = [_]struct { len: usize, name: []const u8 }{
        .{ .len = 0, .name = "trunc_empty.png" },
        .{ .len = 1, .name = "trunc_1byte.png" },
        .{ .len = 4, .name = "trunc_4bytes.png" },
        .{ .len = 7, .name = "trunc_7bytes.png" }, // Partial signature
        .{ .len = 8, .name = "trunc_sig_only.png" }, // Just signature
        .{ .len = 12, .name = "trunc_sig_plus4.png" }, // Signature + partial IHDR length
        .{ .len = 20, .name = "trunc_partial_ihdr.png" }, // Partial IHDR
        .{ .len = 33, .name = "trunc_after_ihdr.png" }, // After IHDR, no IDAT
    };

    for (truncate_points) |tp| {
        if (tp.len <= valid_png.len) {
            try writeFile(output_dir, tp.name, valid_png[0..tp.len]);
            count += 1;
        }
    }

    return count;
}

fn generateBadSignatures(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Bad Signatures ===\n", .{});
    _ = allocator;

    var count: usize = 0;

    // Various bad signatures
    const bad_sigs = [_]struct { data: []const u8, name: []const u8 }{
        .{ .data = &[_]u8{ 0x00, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }, .name = "badsig_first_byte.png" },
        .{ .data = &[_]u8{ 0x89, 'X', 'N', 'G', '\r', '\n', 0x1A, '\n' }, .name = "badsig_not_png.png" },
        .{ .data = &[_]u8{ 0x89, 'P', 'N', 'G', '\n', '\n', 0x1A, '\n' }, .name = "badsig_wrong_crlf.png" },
        .{ .data = &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x00, '\n' }, .name = "badsig_no_eof.png" },
        .{ .data = &[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F' }, .name = "badsig_jpeg.png" }, // JPEG signature
        .{ .data = &[_]u8{ 'G', 'I', 'F', '8', '9', 'a', 0x01, 0x00 }, .name = "badsig_gif.png" }, // GIF signature
    };

    for (bad_sigs) |bs| {
        try writeFile(output_dir, bs.name, bs.data);
        count += 1;
    }

    return count;
}

fn generateBadCRCs(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Bad CRCs ===\n", .{});

    var count: usize = 0;

    // Valid PNG with bad IHDR CRC
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);

        // IHDR with intentionally wrong CRC
        const ihdr_data = [_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        };
        // Length
        try buffer.appendSlice(allocator, &[_]u8{ 0, 0, 0, 13 });
        // Type
        try buffer.appendSlice(allocator, "IHDR");
        // Data
        try buffer.appendSlice(allocator, &ihdr_data);
        // Bad CRC (all zeros)
        try buffer.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });

        try writeFile(output_dir, "badcrc_ihdr_zeros.png", buffer.items);
        count += 1;
    }

    // Valid PNG with bad IHDR CRC (all 0xFF)
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);

        const ihdr_data = [_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        };
        try buffer.appendSlice(allocator, &[_]u8{ 0, 0, 0, 13 });
        try buffer.appendSlice(allocator, "IHDR");
        try buffer.appendSlice(allocator, &ihdr_data);
        try buffer.appendSlice(allocator, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF });

        try writeFile(output_dir, "badcrc_ihdr_ffff.png", buffer.items);
        count += 1;
    }

    // Valid PNG with off-by-one CRC
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);

        const ihdr_data = [_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        };
        try buffer.appendSlice(allocator, &[_]u8{ 0, 0, 0, 13 });
        try buffer.appendSlice(allocator, "IHDR");
        try buffer.appendSlice(allocator, &ihdr_data);

        // Calculate real CRC and add 1
        var crc_input: [4 + 13]u8 = undefined;
        @memcpy(crc_input[0..4], "IHDR");
        @memcpy(crc_input[4..], &ihdr_data);
        const real_crc = std.hash.Crc32.hash(&crc_input);
        const bad_crc = real_crc +% 1;
        try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, bad_crc)));

        try writeFile(output_dir, "badcrc_ihdr_off_by_one.png", buffer.items);
        count += 1;
    }

    return count;
}

fn generateInvalidChunkTypes(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Invalid Chunk Types ===\n", .{});

    var count: usize = 0;

    // PNG starting with wrong chunk type (not IHDR)
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{ 0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 });

        try writeFile(output_dir, "badchunk_idat_first.png", buffer.items);
        count += 1;
    }

    // Chunk with non-ASCII type
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);

        // Length
        try buffer.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
        // Invalid type (non-ASCII)
        try buffer.appendSlice(allocator, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF });
        // CRC
        try buffer.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });

        try writeFile(output_dir, "badchunk_nonascii_type.png", buffer.items);
        count += 1;
    }

    // Chunk with lowercase critical chunk type
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "ihdr", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });

        try writeFile(output_dir, "badchunk_lowercase_ihdr.png", buffer.items);
        count += 1;
    }

    // Chunk with numeric type
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);

        try buffer.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
        try buffer.appendSlice(allocator, "1234");
        try buffer.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });

        try writeFile(output_dir, "badchunk_numeric_type.png", buffer.items);
        count += 1;
    }

    return count;
}

fn generateInvalidIHDR(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Invalid IHDR ===\n", .{});

    var count: usize = 0;

    // Zero width
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 0, // width = 0 (invalid)
            0, 0, 0, 8, // height = 8
            8, 2, 0, 0, 0,
        });

        try writeFile(output_dir, "badihdr_zero_width.png", buffer.items);
        count += 1;
    }

    // Zero height
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, // width = 8
            0, 0, 0, 0, // height = 0 (invalid)
            8, 2, 0, 0, 0,
        });

        try writeFile(output_dir, "badihdr_zero_height.png", buffer.items);
        count += 1;
    }

    // Invalid bit depth
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8,
            7, // bit depth = 7 (invalid, must be 1,2,4,8,16)
            2, 0, 0, 0,
        });

        try writeFile(output_dir, "badihdr_invalid_bitdepth.png", buffer.items);
        count += 1;
    }

    // Invalid color type
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8,
            8,
            5, // color type = 5 (invalid)
            0, 0, 0,
        });

        try writeFile(output_dir, "badihdr_invalid_colortype.png", buffer.items);
        count += 1;
    }

    // Invalid combination (RGB with bit depth 1)
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8,
            1, // bit depth = 1
            2, // color type = RGB (requires 8 or 16)
            0, 0, 0,
        });

        try writeFile(output_dir, "badihdr_rgb_1bit.png", buffer.items);
        count += 1;
    }

    // Invalid compression method
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8,
            8, 2,
            1, // compression method = 1 (must be 0)
            0, 0,
        });

        try writeFile(output_dir, "badihdr_invalid_compression.png", buffer.items);
        count += 1;
    }

    // Invalid filter method
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8,
            8, 2, 0,
            1, // filter method = 1 (must be 0)
            0,
        });

        try writeFile(output_dir, "badihdr_invalid_filter.png", buffer.items);
        count += 1;
    }

    // Invalid interlace method
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8,
            8, 2, 0, 0,
            2, // interlace = 2 (must be 0 or 1)
        });

        try writeFile(output_dir, "badihdr_invalid_interlace.png", buffer.items);
        count += 1;
    }

    // IHDR too short
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{ 0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0 }); // Only 11 bytes

        try writeFile(output_dir, "badihdr_too_short.png", buffer.items);
        count += 1;
    }

    // IHDR too long
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
            0xFF, 0xFF, // Extra bytes
        });

        try writeFile(output_dir, "badihdr_too_long.png", buffer.items);
        count += 1;
    }

    return count;
}

fn generateCorruptedIDAT(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Corrupted IDAT ===\n", .{});

    var count: usize = 0;

    // Invalid zlib header
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x00, 0x00, // Invalid zlib header
            0x00, 0x00, 0x00, 0x01,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "badidat_invalid_zlib.png", buffer.items);
        count += 1;
    }

    // Bad zlib checksum
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, // Valid zlib header
            0x01, 0x00, 0x00, 0xFF, 0xFF, // Stored block
            0x00, 0x00, 0x00, 0x00, // Wrong adler32
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "badidat_bad_adler32.png", buffer.items);
        count += 1;
    }

    // Invalid filter byte
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, // 1x1 RGB
        });
        // IDAT with filter byte = 5 (invalid, must be 0-4)
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, // zlib header
            0x62, 0x65, // compressed: filter=5 + 3 bytes
            0x60, 0x60, 0x60, 0x00, 0x00,
            0x00, 0x0D, 0x00, 0x07, // adler32
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "badidat_invalid_filter.png", buffer.items);
        count += 1;
    }

    // Empty IDAT
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IDAT", &.{}); // Empty!
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "badidat_empty.png", buffer.items);
        count += 1;
    }

    // Random garbage in IDAT
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "badidat_garbage.png", buffer.items);
        count += 1;
    }

    return count;
}

fn generateMissingChunks(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Missing Chunks ===\n", .{});

    var count: usize = 0;

    // Missing IHDR (signature only)
    {
        try writeFile(output_dir, "missing_ihdr.png", &png_signature);
        count += 1;
    }

    // Missing IDAT
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "missing_idat.png", buffer.items);
        count += 1;
    }

    // Missing IEND
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x60, 0x60,
            0x60, 0x60, 0x60, 0x60, 0x60, 0x00, 0x00,
            0x00, 0xC1, 0x00, 0x01,
        });
        // No IEND!

        try writeFile(output_dir, "missing_iend.png", buffer.items);
        count += 1;
    }

    // Indexed without PLTE
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8,
            8,
            3, // indexed color
            0, 0, 0,
        });
        // No PLTE chunk!
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "missing_plte_indexed.png", buffer.items);
        count += 1;
    }

    return count;
}

fn generateOutOfOrderChunks(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Out-of-Order Chunks ===\n", .{});

    var count: usize = 0;

    // IEND before IDAT
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01,
        });

        try writeFile(output_dir, "outoforder_iend_before_idat.png", buffer.items);
        count += 1;
    }

    // Multiple IHDR
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{ // Second IHDR!
            0, 0, 0, 16, 0, 0, 0, 16, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "outoforder_multiple_ihdr.png", buffer.items);
        count += 1;
    }

    // PLTE after IDAT
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 3, 0, 0, 0, // indexed
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01,
        });
        try appendChunk(allocator, &buffer, "PLTE", &[_]u8{ // PLTE after IDAT
            255, 0, 0, 0, 255, 0, 0, 0, 255,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "outoforder_plte_after_idat.png", buffer.items);
        count += 1;
    }

    return count;
}

fn generateOversizedDimensions(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Oversized Dimensions ===\n", .{});

    var count: usize = 0;

    // Maximum possible dimensions (2^31 - 1)
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0x7F, 0xFF, 0xFF, 0xFF, // width = 2^31 - 1
            0x7F, 0xFF, 0xFF, 0xFF, // height = 2^31 - 1
            8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "oversized_max_dims.png", buffer.items);
        count += 1;
    }

    // Overflow-inducing dimensions
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0x00, 0x01, 0x00, 0x00, // width = 65536
            0x00, 0x01, 0x00, 0x00, // height = 65536
            8, 6, 0, 0, 0, // RGBA = 4 bytes/pixel = 17GB!
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "oversized_overflow.png", buffer.items);
        count += 1;
    }

    // Very wide, single row
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0x00, 0x10, 0x00, 0x00, // width = 1048576
            0x00, 0x00, 0x00, 0x01, // height = 1
            8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "oversized_very_wide.png", buffer.items);
        count += 1;
    }

    return count;
}

fn generateEdgeCases(allocator: Allocator, output_dir: []const u8) !usize {
    std.debug.print("=== Edge Cases ===\n", .{});

    var count: usize = 0;

    // Chunk with maximum length field
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });

        // Chunk claiming huge length
        try buffer.appendSlice(allocator, &[_]u8{ 0x7F, 0xFF, 0xFF, 0xFF }); // length = 2^31-1
        try buffer.appendSlice(allocator, "tEXt");
        // But actually much smaller...
        try buffer.appendSlice(allocator, "test");

        try writeFile(output_dir, "edge_huge_chunk_length.png", buffer.items);
        count += 1;
    }

    // Many small IDAT chunks
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0, // 1x1 grayscale
        });

        // Split zlib data across many tiny IDAT chunks
        const zlib_data = [_]u8{
            0x78, 0x9C, // header
            0x62, // compressed
            0x60, // data
            0x00, // ...
            0x00, // ...
            0x00, 0x02, 0x00, 0x01, // adler32
        };

        for (zlib_data) |byte| {
            try appendChunk(allocator, &buffer, "IDAT", &[_]u8{byte});
        }

        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "edge_many_idat_chunks.png", buffer.items);
        count += 1;
    }

    // Unknown critical chunk
    {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &png_signature);
        try appendChunk(allocator, &buffer, "IHDR", &[_]u8{
            0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0,
        });
        try appendChunk(allocator, &buffer, "XYZW", &[_]u8{ 1, 2, 3, 4 }); // Unknown critical chunk
        try appendChunk(allocator, &buffer, "IDAT", &[_]u8{
            0x78, 0x9C, 0x62, 0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01,
        });
        try appendChunk(allocator, &buffer, "IEND", &.{});

        try writeFile(output_dir, "edge_unknown_critical.png", buffer.items);
        count += 1;
    }

    // All zeros file (same size as minimal PNG)
    {
        var zeros: [100]u8 = undefined;
        @memset(&zeros, 0);

        try writeFile(output_dir, "edge_all_zeros.png", &zeros);
        count += 1;
    }

    // All 0xFF file
    {
        var ones: [100]u8 = undefined;
        @memset(&ones, 0xFF);

        try writeFile(output_dir, "edge_all_ones.png", &ones);
        count += 1;
    }

    // Repeating pattern
    {
        var pattern: [256]u8 = undefined;
        for (&pattern, 0..) |*b, i| {
            b.* = @intCast(i);
        }

        try writeFile(output_dir, "edge_byte_pattern.png", &pattern);
        count += 1;
    }

    return count;
}
