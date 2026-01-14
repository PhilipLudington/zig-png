# Zig PNG Library Design Document

A full-featured, pure Zig implementation of the PNG specification (ISO/IEC 15948).

## Goals

- **Full PNG spec compliance** - All color types, bit depths, interlacing, and chunk types
- **Pure Zig** - No C dependencies, including compression (deflate/zlib)
- **General purpose** - Suitable for games, image tools, web services, embedded
- **Streaming support** - Process images without loading entirely into memory
- **Idiomatic Zig** - Allocator-aware, error unions, comptime where beneficial

## Non-Goals

- APNG (animated PNG) support (could be added later)
- Image manipulation (resizing, color conversion) - separate concern
- Lossy compression modes

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                      Public API                         │
│  (decode, encode, StreamDecoder, StreamEncoder)         │
└─────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────┐
│                    PNG Layer                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   Chunks    │  │   Filters   │  │   Interlacing   │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────┐
│                 Compression Layer                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   Deflate   │  │   Inflate   │  │  Zlib Wrapper   │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────┐
│                   Utilities                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │    CRC32    │  │   Adler32   │  │   Bit Streams   │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## Module Structure

```
src/
├── png.zig                 # Public API, re-exports
├── decoder.zig             # PNG decoding logic
├── encoder.zig             # PNG encoding logic
├── chunks/
│   ├── chunks.zig          # Chunk parsing/writing framework
│   ├── critical.zig        # IHDR, PLTE, IDAT, IEND
│   └── ancillary.zig       # All optional chunks
├── filters.zig             # Filter encode/decode, heuristics
├── interlace.zig           # Adam7 implementation
├── color.zig               # Color types, bit depth handling
├── compression/
│   ├── deflate.zig         # Deflate compressor
│   ├── inflate.zig         # Deflate decompressor
│   ├── zlib.zig            # Zlib framing (header, adler32)
│   ├── huffman.zig         # Huffman tree building/decoding
│   └── lz77.zig            # LZ77 matching engine
├── utils/
│   ├── crc32.zig           # CRC32 with table
│   ├── adler32.zig         # Adler32 checksum
│   └── bit_reader.zig      # Bit-level I/O
└── testing/
    └── test_images/        # PNG test suite images
```

---

## Data Structures

### Core Types

```zig
pub const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

pub const BitDepth = enum(u8) {
    @"1" = 1,
    @"2" = 2,
    @"4" = 4,
    @"8" = 8,
    @"16" = 16,
};

pub const InterlaceMethod = enum(u8) {
    none = 0,
    adam7 = 1,
};

pub const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
};
```

### Image Header

```zig
pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: BitDepth,
    color_type: ColorType,
    interlace_method: InterlaceMethod,

    pub fn bytesPerPixel(self: Header) u8 {
        // Calculate based on color_type and bit_depth
    }

    pub fn bytesPerRow(self: Header) usize {
        // Width * bytes per pixel, accounting for sub-byte depths
    }

    pub fn isValid(self: Header) bool {
        // Validate color_type + bit_depth combinations per spec
    }
};
```

### Decoded Image

```zig
pub const Image = struct {
    header: Header,
    pixels: []u8,              // Raw pixel data, row-major
    palette: ?[]RGB,           // For indexed color
    transparency: ?Transparency,
    gamma: ?f32,
    chromaticity: ?Chromaticity,
    text_chunks: []TextChunk,

    allocator: Allocator,

    pub fn deinit(self: *Image) void {
        // Free all allocated memory
    }

    pub fn getPixel(self: Image, x: u32, y: u32) Pixel {
        // Access pixel at coordinates
    }

    pub fn rowBytes(self: Image, y: u32) []u8 {
        // Get raw bytes for row y
    }
};

pub const RGB = struct { r: u8, g: u8, b: u8 };
pub const RGBA = struct { r: u8, g: u8, b: u8, a: u8 };

pub const Pixel = union(enum) {
    grayscale: u16,
    grayscale_alpha: struct { v: u16, a: u16 },
    rgb: struct { r: u16, g: u16, b: u16 },
    rgba: struct { r: u16, g: u16, b: u16, a: u16 },
    indexed: u8,
};
```

### Transparency

```zig
pub const Transparency = union(ColorType) {
    grayscale: u16,                    // Single transparent gray value
    rgb: struct { r: u16, g: u16, b: u16 },  // Single transparent color
    indexed: []u8,                     // Alpha for each palette entry
    grayscale_alpha: void,             // N/A - has full alpha channel
    rgba: void,                        // N/A - has full alpha channel
};
```

---

## Public API

### Simple API (Load Entire Image)

```zig
const png = @import("png");

// Decode from file
pub fn decodeFile(allocator: Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return decode(allocator, file.reader());
}

// Decode from any reader
pub fn decode(allocator: Allocator, reader: anytype) !Image

// Decode from memory
pub fn decodeBuffer(allocator: Allocator, buffer: []const u8) !Image

// Encode to file
pub fn encodeFile(image: Image, path: []const u8) !void

// Encode to any writer
pub fn encode(image: Image, writer: anytype) !void

// Encode to allocated buffer
pub fn encodeBuffer(allocator: Allocator, image: Image) ![]u8
```

### Usage Example

```zig
const std = @import("std");
const png = @import("png");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Decode
    var image = try png.decodeFile(allocator, "input.png");
    defer image.deinit();

    std.debug.print("Image: {}x{} {s}\n", .{
        image.header.width,
        image.header.height,
        @tagName(image.header.color_type),
    });

    // Modify pixels...

    // Encode
    try png.encodeFile(image, "output.png");
}
```

### Streaming Decoder

For large images or memory-constrained environments:

```zig
pub const StreamDecoder = struct {
    allocator: Allocator,
    state: State,
    header: ?Header,

    const State = enum {
        reading_signature,
        reading_chunk_header,
        reading_chunk_data,
        decompressing,
        unfiltering,
        done,
        err,
    };

    pub fn init(allocator: Allocator) StreamDecoder

    /// Feed bytes to the decoder. Returns decoded rows if any are complete.
    pub fn feed(self: *StreamDecoder, data: []const u8) !?[]Row

    /// Get header once available (after IHDR parsed)
    pub fn getHeader(self: StreamDecoder) ?Header

    /// Signal end of input
    pub fn finish(self: *StreamDecoder) !void

    pub fn deinit(self: *StreamDecoder) void
};

pub const Row = struct {
    y: u32,
    pass: ?u8,      // For interlaced: 0-6, null for non-interlaced
    pixels: []u8,
};
```

### Streaming Encoder

```zig
pub const StreamEncoder = struct {
    allocator: Allocator,
    writer: anytype,
    header: Header,
    current_row: u32,

    pub fn init(allocator: Allocator, writer: anytype, header: Header, options: EncodeOptions) !StreamEncoder

    /// Write a row of pixels
    pub fn writeRow(self: *StreamEncoder, pixels: []const u8) !void

    /// Finish encoding, write IEND
    pub fn finish(self: *StreamEncoder) !void

    pub fn deinit(self: *StreamEncoder) void
};

pub const EncodeOptions = struct {
    compression_level: u4 = 6,           // 0-9
    filter_strategy: FilterStrategy = .adaptive,
    interlace: bool = false,

    // Optional metadata
    gamma: ?f32 = null,
    text_chunks: []const TextChunk = &.{},
};

pub const FilterStrategy = enum {
    none,       // Always use filter 0
    adaptive,   // Choose best per row (default)
    fixed,      // Use single specified filter
};
```

---

## Chunk Handling

### Chunk Structure

```zig
pub const Chunk = struct {
    length: u32,
    chunk_type: [4]u8,
    data: []const u8,
    crc: u32,

    pub fn isCritical(self: Chunk) bool {
        return self.chunk_type[0] & 0x20 == 0;
    }

    pub fn isPublic(self: Chunk) bool {
        return self.chunk_type[1] & 0x20 == 0;
    }

    pub fn isSafeToCopy(self: Chunk) bool {
        return self.chunk_type[3] & 0x20 != 0;
    }
};
```

### Critical Chunks

| Chunk | Purpose | Notes |
|-------|---------|-------|
| IHDR  | Image header | Must be first, exactly one |
| PLTE  | Palette | Required for indexed, optional for RGB/RGBA |
| IDAT  | Image data | Compressed, filtered pixel data. May be multiple |
| IEND  | Image end | Must be last, empty |

### Ancillary Chunks (All Optional)

| Chunk | Purpose | Order Constraint |
|-------|---------|------------------|
| cHRM  | Chromaticity | Before PLTE, IDAT |
| gAMA  | Gamma | Before PLTE, IDAT |
| iCCP  | ICC profile | Before PLTE, IDAT |
| sBIT  | Significant bits | Before PLTE, IDAT |
| sRGB  | Standard RGB | Before PLTE, IDAT |
| bKGD  | Background color | After PLTE, before IDAT |
| hIST  | Histogram | After PLTE, before IDAT |
| tRNS  | Transparency | After PLTE, before IDAT |
| pHYs  | Pixel dimensions | Before IDAT |
| sPLT  | Suggested palette | Before IDAT |
| tIME  | Modification time | Any |
| iTXt  | International text | Any |
| tEXt  | Text | Any |
| zTXt  | Compressed text | Any |

---

## Filter Implementation

### Decoding (Reconstruction)

```zig
pub fn unfilter(
    filter_type: FilterType,
    current_row: []u8,
    previous_row: ?[]const u8,
    bytes_per_pixel: u8,
) void {
    switch (filter_type) {
        .none => {},
        .sub => unfilterSub(current_row, bytes_per_pixel),
        .up => unfilterUp(current_row, previous_row),
        .average => unfilterAverage(current_row, previous_row, bytes_per_pixel),
        .paeth => unfilterPaeth(current_row, previous_row, bytes_per_pixel),
    }
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + @as(i16, b) - @as(i16, c);
    const pa = @abs(p - @as(i16, a));
    const pb = @abs(p - @as(i16, b));
    const pc = @abs(p - @as(i16, c));

    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}
```

### Encoding (Filter Selection)

Adaptive filtering tries all filters and picks the one with smallest sum of absolute values (good heuristic for compression):

```zig
pub fn selectFilter(
    current_row: []const u8,
    previous_row: ?[]const u8,
    bytes_per_pixel: u8,
    scratch: *[5][]u8,  // Pre-allocated buffers for each filter type
) FilterType {
    var best_filter: FilterType = .none;
    var best_sum: u64 = computeFilteredSum(scratch[0]);

    inline for ([_]FilterType{ .sub, .up, .average, .paeth }) |filter| {
        applyFilter(filter, current_row, previous_row, bytes_per_pixel, scratch[@intFromEnum(filter)]);
        const sum = computeFilteredSum(scratch[@intFromEnum(filter)]);
        if (sum < best_sum) {
            best_sum = sum;
            best_filter = filter;
        }
    }

    return best_filter;
}
```

---

## Interlacing (Adam7)

### Pass Layout

```
Pass 1: Starting at (0,0), every 8th pixel, every 8th row
Pass 2: Starting at (4,0), every 8th pixel, every 8th row
Pass 3: Starting at (0,4), every 4th pixel, every 8th row
Pass 4: Starting at (2,0), every 4th pixel, every 4th row
Pass 5: Starting at (0,2), every 2nd pixel, every 4th row
Pass 6: Starting at (1,0), every 2nd pixel, every 2nd row
Pass 7: Starting at (0,1), every pixel, every 2nd row

1 6 4 6 2 6 4 6
7 7 7 7 7 7 7 7
5 6 5 6 5 6 5 6
7 7 7 7 7 7 7 7
3 6 4 6 3 6 4 6
7 7 7 7 7 7 7 7
5 6 5 6 5 6 5 6
7 7 7 7 7 7 7 7
```

### Implementation

```zig
pub const Adam7 = struct {
    // Starting column for each pass
    const x_origin = [7]u8{ 0, 4, 0, 2, 0, 1, 0 };
    // Starting row for each pass
    const y_origin = [7]u8{ 0, 0, 4, 0, 2, 0, 1 };
    // Column increment for each pass
    const x_spacing = [7]u8{ 8, 8, 4, 4, 2, 2, 1 };
    // Row increment for each pass
    const y_spacing = [7]u8{ 8, 8, 8, 4, 4, 2, 2 };

    pub fn passWidth(pass: u3, image_width: u32) u32 {
        if (image_width == 0) return 0;
        return (image_width + x_spacing[pass] - x_origin[pass] - 1) / x_spacing[pass];
    }

    pub fn passHeight(pass: u3, image_height: u32) u32 {
        if (image_height == 0) return 0;
        return (image_height + y_spacing[pass] - y_origin[pass] - 1) / y_spacing[pass];
    }

    /// Deinterlace: scatter reduced images into full image
    pub fn deinterlace(
        passes: [7]?[]const u8,
        output: []u8,
        header: Header,
    ) void

    /// Interlace: extract passes from full image
    pub fn interlace(
        input: []const u8,
        passes: *[7][]u8,
        header: Header,
    ) void
};
```

---

## Compression Layer

### Zlib Format

```
+--------+--------+=====================+--------+--------+--------+--------+
| CMF    | FLG    | ...compressed data...|    ADLER32 checksum              |
+--------+--------+=====================+--------+--------+--------+--------+

CMF (Compression Method and Flags):
  bits 0-3: CM = 8 (deflate)
  bits 4-7: CINFO = 7 (32K window)

FLG (Flags):
  bits 0-4: FCHECK (makes CMF*256+FLG divisible by 31)
  bit 5:    FDICT (preset dictionary, not used in PNG)
  bits 6-7: FLEVEL (compression level hint)
```

### Deflate Implementation Strategy

The deflate format uses LZ77 + Huffman coding. Key components:

#### Inflate (Decompression)

```zig
pub const Inflate = struct {
    bit_reader: BitReader,
    window: [32768]u8,      // Sliding window
    window_pos: u15,
    state: State,

    const State = enum {
        block_header,
        uncompressed,
        fixed_huffman,
        dynamic_huffman,
        done,
    };

    pub fn init(reader: anytype) Inflate

    /// Decompress into output buffer, returns bytes written
    pub fn read(self: *Inflate, output: []u8) !usize

    /// Read all remaining data
    pub fn readAll(self: *Inflate, allocator: Allocator) ![]u8
};
```

#### Deflate (Compression)

```zig
pub const Deflate = struct {
    level: u4,
    window: [32768]u8,
    hash_table: HashTable,      // For LZ77 string matching
    bit_writer: BitWriter,

    pub fn init(writer: anytype, level: u4) Deflate

    /// Compress input data
    pub fn write(self: *Deflate, data: []const u8) !void

    /// Flush and finalize
    pub fn finish(self: *Deflate) !void
};

const HashTable = struct {
    // 3-byte hash -> position chain
    head: [65536]u16,
    prev: [32768]u16,

    pub fn insert(self: *HashTable, pos: u16, data: []const u8) void
    pub fn findMatch(self: *HashTable, pos: u16, data: []const u8, max_len: u16) ?Match
};

const Match = struct {
    distance: u16,  // 1-32768
    length: u16,    // 3-258
};
```

#### Huffman Coding

```zig
pub const HuffmanTree = struct {
    // Decoding table (for inflate)
    symbols: [288]u16,
    lengths: [288]u4,

    pub fn build(code_lengths: []const u4) !HuffmanTree
    pub fn decode(self: *HuffmanTree, bits: *BitReader) !u16
};

pub const HuffmanEncoder = struct {
    // Encoding table (for deflate)
    codes: [288]u16,
    lengths: [288]u4,

    pub fn buildFromFrequencies(frequencies: []const u32) HuffmanEncoder
    pub fn encode(self: *HuffmanEncoder, symbol: u16, bits: *BitWriter) void
};
```

---

## Error Handling

```zig
pub const Error = error{
    // Format errors
    InvalidSignature,
    InvalidChunkType,
    InvalidChunkCrc,
    ChunkTooLarge,
    MissingIhdr,
    MissingIdat,
    MissingIend,
    DuplicateChunk,
    ChunkOrderViolation,

    // Header errors
    InvalidWidth,
    InvalidHeight,
    InvalidBitDepth,
    InvalidColorType,
    InvalidCompressionMethod,
    InvalidFilterMethod,
    InvalidInterlaceMethod,
    InvalidColorBitDepthCombo,

    // Data errors
    InvalidFilterType,
    DecompressionFailed,
    InvalidHuffmanCode,
    InvalidDistance,
    InvalidLength,
    ChecksumMismatch,
    UnexpectedEof,
    DataAfterIend,

    // Resource errors
    OutOfMemory,
    ImageTooLarge,
};
```

---

## Testing Strategy

### Unit Tests

Each module should have comprehensive unit tests:

```zig
test "CRC32 known values" {
    try std.testing.expectEqual(crc32(""), 0x00000000);
    try std.testing.expectEqual(crc32("123456789"), 0xCBF43926);
}

test "Paeth predictor" {
    try std.testing.expectEqual(paethPredictor(10, 20, 15), 20);
}

test "Adam7 pass dimensions" {
    // 8x8 image should have specific pass sizes
    try std.testing.expectEqual(Adam7.passWidth(0, 8), 1);
    try std.testing.expectEqual(Adam7.passHeight(0, 8), 1);
}
```

### Integration Tests

Use the official PNG test suite (PngSuite):

```zig
test "decode PngSuite basn0g01" {
    const image = try png.decodeFile(testing.allocator, "test_images/basn0g01.png");
    defer image.deinit();

    try testing.expectEqual(image.header.width, 32);
    try testing.expectEqual(image.header.height, 32);
    try testing.expectEqual(image.header.bit_depth, .@"1");
    try testing.expectEqual(image.header.color_type, .grayscale);
}
```

### Fuzz Testing

```zig
test "fuzz decoder" {
    // Feed random/mutated bytes, should not crash
    const input = std.testing.random_bytes(1024);
    _ = png.decodeBuffer(testing.allocator, input) catch {};
}
```

### Round-Trip Tests

```zig
test "encode-decode round trip" {
    const original = try png.decodeFile(allocator, "test.png");
    defer original.deinit();

    const encoded = try png.encodeBuffer(allocator, original);
    defer allocator.free(encoded);

    const decoded = try png.decodeBuffer(allocator, encoded);
    defer decoded.deinit();

    try testing.expectEqualSlices(u8, original.pixels, decoded.pixels);
}
```

---

## Performance Considerations

### SIMD Opportunities

- **Filter operations**: Sub, Up, Average can be vectorized
- **CRC32**: Use PCLMULQDQ on x86, CRC instructions on ARM
- **Huffman decoding**: Table-based lookup

```zig
// Example: SIMD filter (conceptual)
const Vector = @Vector(16, u8);

fn unfilterSubSimd(row: []u8, bpp: u8) void {
    // Process 16 bytes at a time where possible
    // Fall back to scalar for remainder
}
```

### Memory Layout

- Row-major pixel storage for cache efficiency
- Consider alignment for SIMD operations
- Pool allocators for chunk parsing

### Compression Levels

| Level | Strategy | Speed | Ratio |
|-------|----------|-------|-------|
| 0 | Store only | Fastest | None |
| 1-3 | Fast LZ77, fixed Huffman | Fast | Low |
| 4-6 | Standard LZ77, dynamic Huffman | Medium | Medium |
| 7-9 | Exhaustive matching | Slow | Best |

---

## Implementation Phases

### Phase 1: Foundation
- [ ] CRC32, Adler32
- [ ] Bit reader/writer
- [ ] Basic chunk parsing
- [ ] IHDR parsing

### Phase 2: Decompression
- [ ] Inflate (fixed Huffman)
- [ ] Inflate (dynamic Huffman)
- [ ] Zlib wrapper

### Phase 3: Decoding
- [ ] Filter reconstruction
- [ ] Non-interlaced decoding
- [ ] All color types / bit depths
- [ ] Simple decode API

### Phase 4: Interlacing
- [ ] Adam7 deinterlacing
- [ ] Adam7 interlacing

### Phase 5: Compression
- [ ] Huffman encoding
- [ ] LZ77 matching
- [ ] Deflate implementation

### Phase 6: Encoding
- [ ] Filter selection
- [ ] Chunk writing
- [ ] Simple encode API

### Phase 7: Streaming
- [ ] StreamDecoder
- [ ] StreamEncoder

### Phase 8: Ancillary Chunks
- [ ] Text chunks (tEXt, zTXt, iTXt)
- [ ] Color chunks (gAMA, cHRM, sRGB, iCCP)
- [ ] Other chunks

### Phase 9: Polish
- [ ] SIMD optimizations
- [ ] Comprehensive test suite
- [ ] Documentation
- [ ] Benchmarks

---

## References

- [PNG Specification (W3C)](https://www.w3.org/TR/PNG/)
- [RFC 1950 - ZLIB Compressed Data Format](https://tools.ietf.org/html/rfc1950)
- [RFC 1951 - DEFLATE Compressed Data Format](https://tools.ietf.org/html/rfc1951)
- [PngSuite - Test Images](http://www.schaik.com/pngsuite/)
- [libpng](http://www.libpng.org/pub/png/libpng.html) - Reference implementation
- [stb_image.h](https://github.com/nothings/stb) - Simple reference
- [zlib](https://zlib.net/) - Reference compression
