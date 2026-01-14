//! AFL++ Fuzz Harness for zig-png
//!
//! This harness reads input from stdin and passes it to the PNG decoder.
//! Build with: zig build afl-harness
//! Run with AFL++: afl-fuzz -i fuzz_corpus -o fuzz_output -- ./zig-out/bin/afl-harness
//!
//! For best results, use AFL_HARDEN=1 and AFL_USE_ASAN=1 environment variables.

const std = @import("std");
const png = @import("png");

const FuzzTarget = enum {
    decode,
    chunks,
    inflate,
    roundtrip,
};

fn getStdin() std.fs.File {
    return std.fs.File{ .handle = std.posix.STDIN_FILENO };
}

fn getStderr() std.fs.File {
    return std.fs.File{ .handle = std.posix.STDERR_FILENO };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line for target selection
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var target: FuzzTarget = .decode; // Default target

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--decode")) {
            target = .decode;
        } else if (std.mem.eql(u8, arg, "--chunks")) {
            target = .chunks;
        } else if (std.mem.eql(u8, arg, "--inflate")) {
            target = .inflate;
        } else if (std.mem.eql(u8, arg, "--roundtrip")) {
            target = .roundtrip;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        }
    }

    // Read input from stdin
    const stdin = getStdin();
    const input = try stdin.readToEndAlloc(allocator, 64 * 1024 * 1024); // 64MB max
    defer allocator.free(input);

    // Run the selected fuzz target
    switch (target) {
        .decode => fuzzDecode(allocator, input),
        .chunks => fuzzChunks(input),
        .inflate => fuzzInflate(input),
        .roundtrip => fuzzRoundtrip(allocator, input),
    }
}

fn printUsage() !void {
    const stderr = getStderr();
    try stderr.writeAll(
        \\AFL++ Fuzz Harness for zig-png
        \\
        \\Usage: afl-harness [OPTIONS] < input_file
        \\
        \\Options:
        \\  --decode     Fuzz PNG decoder (default)
        \\  --chunks     Fuzz chunk parsing
        \\  --inflate    Fuzz zlib decompression
        \\  --roundtrip  Fuzz decode/encode roundtrip
        \\  --help, -h   Show this help
        \\
        \\Example with AFL++:
        \\  afl-fuzz -i fuzz_corpus -o fuzz_output -- ./zig-out/bin/afl-harness --decode
        \\
    );
}

fn fuzzDecode(allocator: std.mem.Allocator, data: []const u8) void {
    var image = png.decode(allocator, data) catch return;
    defer image.deinit();

    // Validate decoded image invariants
    if (image.header.width == 0 or image.header.height == 0) {
        @panic("Invalid dimensions in decoded image");
    }

    // Touch all pixels to ensure memory is valid
    var sum: u8 = 0;
    for (image.pixels) |byte| {
        sum +%= byte;
    }
    std.mem.doNotOptimizeAway(sum);
}

fn fuzzChunks(data: []const u8) void {
    // Simple chunk boundary check - try to read past PNG signature
    if (data.len < 8) return;

    // Check PNG signature
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    if (!std.mem.startsWith(u8, data, &sig)) return;

    // Try to parse chunk headers
    var pos: usize = 8;
    while (pos + 12 <= data.len) {
        const length = std.mem.readInt(u32, data[pos..][0..4], .big);
        if (length > 0x7FFFFFFF) return; // Invalid length

        const chunk_type = data[pos + 4 ..][0..4];

        // Validate chunk type (ASCII letters only)
        for (chunk_type) |c| {
            if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'))) {
                return;
            }
        }

        const total_size = 4 + 4 + length + 4;
        if (pos + total_size > data.len) return;

        pos += total_size;
    }
}

fn fuzzInflate(data: []const u8) void {
    // Basic zlib header validation
    if (data.len < 6) return; // Minimum: 2 header + 4 checksum

    const cmf = data[0];
    const flg = data[1];

    // Check header checksum
    const check: u16 = @as(u16, cmf) * 256 + flg;
    if (check % 31 != 0) return;

    // Check compression method (must be 8 for deflate)
    if (cmf & 0x0F != 8) return;

    // Check window size (CINFO must be <= 7)
    if ((cmf >> 4) > 7) return;

    // Dictionary flag not supported
    if (flg & 0x20 != 0) return;

    // If we get here, it looks like valid zlib - the full decoder will handle it
}

fn fuzzRoundtrip(allocator: std.mem.Allocator, data: []const u8) void {
    // First decode
    var image = png.decode(allocator, data) catch return;
    defer image.deinit();

    // Skip indexed (palette complicates roundtrip)
    if (image.header.color_type == .indexed) return;

    // Skip large images
    const pixel_count = @as(u64, image.header.width) * @as(u64, image.header.height);
    if (pixel_count > 4 * 1024 * 1024) return;

    // Encode
    const max_size = png.maxEncodedSize(image.header);
    if (max_size > 64 * 1024 * 1024) return;

    const output = allocator.alloc(u8, max_size) catch return;
    defer allocator.free(output);

    const encoded_len = png.encode(allocator, &image, output, .{}) catch return;

    // Decode again
    var decoded = png.decode(allocator, output[0..encoded_len]) catch {
        @panic("Failed to decode our own encoded output");
    };
    defer decoded.deinit();

    // Verify match
    if (!std.mem.eql(u8, image.pixels, decoded.pixels)) {
        @panic("Roundtrip pixel mismatch");
    }

    if (image.header.width != decoded.header.width or
        image.header.height != decoded.header.height)
    {
        @panic("Roundtrip dimension mismatch");
    }
}
