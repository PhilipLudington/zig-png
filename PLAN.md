# Zig PNG Library Implementation Plan

This plan breaks down the implementation into concrete, actionable tasks based on the architecture defined in DESIGN.md.

---

## Phase 1: Foundation

### 1.1 Project Setup
- [ ] Create `src/png.zig` - Main entry point with public API re-exports
- [ ] Create `build.zig` - Build configuration with test support
- [ ] Add `.gitignore` for Zig cache directories

### 1.2 CRC32 Implementation
- [ ] Create `src/utils/crc32.zig`
- [ ] Implement CRC32 lookup table (precomputed at comptime)
- [ ] Implement `crc32(data: []const u8) u32` function
- [ ] Implement streaming `Crc32` struct with `update()` and `final()`
- [ ] Add unit tests for known CRC32 values

### 1.3 Adler32 Implementation
- [ ] Create `src/utils/adler32.zig`
- [ ] Implement `adler32(data: []const u8) u32` function
- [ ] Implement streaming `Adler32` struct with `update()` and `final()`
- [ ] Add unit tests for known Adler32 values

### 1.4 Bit Reader
- [ ] Create `src/utils/bit_reader.zig`
- [ ] Implement `BitReader` struct wrapping any reader
- [ ] Implement `readBits(n: u4) !u16` - read n bits (LSB first for deflate)
- [ ] Implement `readByte() !u8` - read aligned byte
- [ ] Implement `alignToByte()` - skip to next byte boundary
- [ ] Add unit tests

### 1.5 Bit Writer
- [ ] Create `src/utils/bit_writer.zig`
- [ ] Implement `BitWriter` struct wrapping any writer
- [ ] Implement `writeBits(value: u16, n: u4) !void`
- [ ] Implement `flush() !void` - flush partial byte
- [ ] Add unit tests

### 1.6 Core Types
- [ ] Create `src/color.zig`
- [ ] Define `ColorType` enum (grayscale, rgb, indexed, grayscale_alpha, rgba)
- [ ] Define `BitDepth` enum (1, 2, 4, 8, 16)
- [ ] Define `InterlaceMethod` enum (none, adam7)
- [ ] Define `FilterType` enum (none, sub, up, average, paeth)
- [ ] Implement `isValidColorBitDepthCombo()` validation
- [ ] Add `bytesPerPixel()` helper

### 1.7 Chunk Framework
- [ ] Create `src/chunks/chunks.zig`
- [ ] Define `Chunk` struct (length, type, data, crc)
- [ ] Implement `readChunk(reader) !Chunk` - parse chunk from stream
- [ ] Implement `writeChunk(writer, type, data) !void`
- [ ] Implement chunk property methods (`isCritical`, `isPublic`, `isSafeToCopy`)
- [ ] Add CRC validation
- [ ] Add unit tests

### 1.8 IHDR Parsing
- [ ] Create `src/chunks/critical.zig`
- [ ] Define `Header` struct with all IHDR fields
- [ ] Implement `parseIhdr(data: []const u8) !Header`
- [ ] Implement `Header.bytesPerPixel()`, `Header.bytesPerRow()`
- [ ] Implement `Header.isValid()` - validate field combinations
- [ ] Add unit tests

### 1.9 PNG Signature
- [ ] Add PNG signature constant: `{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }`
- [ ] Implement signature validation in decoder

---

## Phase 2: Decompression (Inflate)

### 2.1 Huffman Decoding
- [ ] Create `src/compression/huffman.zig`
- [ ] Define `HuffmanTree` struct
- [ ] Implement `HuffmanTree.build(code_lengths: []const u4) !HuffmanTree`
- [ ] Implement `HuffmanTree.decode(bit_reader) !u16`
- [ ] Add fixed literal/length tree (RFC 1951 section 3.2.6)
- [ ] Add fixed distance tree
- [ ] Add unit tests

### 2.2 Inflate Core
- [ ] Create `src/compression/inflate.zig`
- [ ] Define `Inflate` struct with 32KB sliding window
- [ ] Implement block header parsing (BFINAL, BTYPE)
- [ ] Implement uncompressed block handling (BTYPE=00)
- [ ] Implement fixed Huffman block decoding (BTYPE=01)
- [ ] Add unit tests with known compressed data

### 2.3 Dynamic Huffman
- [ ] Implement dynamic Huffman header parsing (BTYPE=10)
- [ ] Parse HLIT, HDIST, HCLEN
- [ ] Decode code length alphabet
- [ ] Build literal/length and distance trees
- [ ] Add unit tests

### 2.4 LZ77 Decoding
- [ ] Implement length/distance decoding in inflate
- [ ] Handle extra bits for lengths (257-285)
- [ ] Handle extra bits for distances (0-29)
- [ ] Copy from sliding window
- [ ] Add unit tests

### 2.5 Zlib Wrapper
- [ ] Create `src/compression/zlib.zig`
- [ ] Implement `ZlibReader` wrapping inflate
- [ ] Parse CMF/FLG header bytes
- [ ] Validate compression method (CM=8)
- [ ] Validate window size (CINFO)
- [ ] Verify Adler32 checksum at end
- [ ] Add unit tests

---

## Phase 3: Basic Decoding

### 3.1 Filter Reconstruction
- [ ] Create `src/filters.zig`
- [ ] Implement `unfilterNone()` - no-op
- [ ] Implement `unfilterSub(row, bpp)` - add left neighbor
- [ ] Implement `unfilterUp(row, prev_row)` - add above neighbor
- [ ] Implement `unfilterAverage(row, prev_row, bpp)` - add average
- [ ] Implement `unfilterPaeth(row, prev_row, bpp)` - Paeth predictor
- [ ] Implement `paethPredictor(a, b, c) u8`
- [ ] Implement `unfilter(filter_type, row, prev_row, bpp)` dispatcher
- [ ] Add unit tests for each filter type

### 3.2 Image Structure
- [ ] Define `Image` struct in `src/png.zig`
- [ ] Fields: header, pixels, palette, transparency, allocator
- [ ] Implement `Image.deinit()`
- [ ] Implement `Image.getPixel(x, y) Pixel`
- [ ] Implement `Image.rowBytes(y) []u8`
- [ ] Define `Pixel` union type

### 3.3 Decoder Core
- [ ] Create `src/decoder.zig`
- [ ] Implement signature verification
- [ ] Implement chunk iteration loop
- [ ] Collect IDAT chunks into single compressed stream
- [ ] Decompress IDAT data
- [ ] Unfilter each row
- [ ] Store pixels in Image struct
- [ ] Handle all bit depths (1, 2, 4, 8, 16)
- [ ] Handle all color types

### 3.4 Palette Handling
- [ ] Parse PLTE chunk (in `critical.zig`)
- [ ] Validate palette size (1-256 entries, divisible by 3)
- [ ] Store palette in Image
- [ ] Expand indexed pixels to RGB on demand

### 3.5 Simple Decode API
- [ ] Implement `png.decode(allocator, reader) !Image`
- [ ] Implement `png.decodeBuffer(allocator, buffer) !Image`
- [ ] Implement `png.decodeFile(allocator, path) !Image`
- [ ] Add integration tests with real PNG files

### 3.6 Test Images
- [ ] Create `src/testing/` directory
- [ ] Download PngSuite test images
- [ ] Add decode tests for basic images (basn*.png)
- [ ] Add decode tests for different bit depths
- [ ] Add decode tests for different color types

---

## Phase 4: Adam7 Interlacing

### 4.1 Interlace Support
- [ ] Create `src/interlace.zig`
- [ ] Define `Adam7` constants (origins, spacings)
- [ ] Implement `Adam7.passWidth(pass, image_width) u32`
- [ ] Implement `Adam7.passHeight(pass, image_height) u32`
- [ ] Implement `Adam7.passRowBytes(pass, header) usize`
- [ ] Add unit tests for pass dimension calculations

### 4.2 Deinterlacing
- [ ] Implement pass extraction from compressed data
- [ ] Each pass is filtered independently
- [ ] Implement `Adam7.deinterlace(passes, output, header)`
- [ ] Scatter pass pixels to correct positions in output
- [ ] Add integration tests with interlaced PNGs

### 4.3 Interlacing (for encoder)
- [ ] Implement `Adam7.interlace(input, passes, header)`
- [ ] Extract pixels for each pass from full image
- [ ] Add unit tests

---

## Phase 5: Compression (Deflate)

### 5.1 Huffman Encoding
- [ ] Extend `src/compression/huffman.zig`
- [ ] Define `HuffmanEncoder` struct
- [ ] Implement `HuffmanEncoder.buildFromFrequencies(freq) HuffmanEncoder`
- [ ] Implement canonical Huffman code generation
- [ ] Implement `HuffmanEncoder.encode(symbol, bit_writer)`
- [ ] Add unit tests

### 5.2 LZ77 Matching
- [ ] Create `src/compression/lz77.zig`
- [ ] Define `HashTable` struct for 3-byte hash chains
- [ ] Implement `HashTable.insert(pos, data)`
- [ ] Implement `HashTable.findMatch(pos, data, max_len) ?Match`
- [ ] Tune for different compression levels
- [ ] Add unit tests

### 5.3 Deflate Core
- [ ] Create `src/compression/deflate.zig`
- [ ] Define `Deflate` struct with sliding window
- [ ] Implement stored block output (level 0)
- [ ] Implement fixed Huffman encoding (levels 1-3)
- [ ] Implement dynamic Huffman encoding (levels 4-9)
- [ ] Implement `Deflate.write(data)`
- [ ] Implement `Deflate.finish()`
- [ ] Add round-trip tests with inflate

### 5.4 Zlib Compression
- [ ] Extend `src/compression/zlib.zig`
- [ ] Implement `ZlibWriter` wrapping deflate
- [ ] Write CMF/FLG header
- [ ] Calculate and append Adler32
- [ ] Add round-trip tests

---

## Phase 6: Encoding

### 6.1 Filter Selection
- [ ] Extend `src/filters.zig`
- [ ] Implement `applyFilterNone(src, dst)`
- [ ] Implement `applyFilterSub(src, dst, bpp)`
- [ ] Implement `applyFilterUp(src, prev, dst)`
- [ ] Implement `applyFilterAverage(src, prev, dst, bpp)`
- [ ] Implement `applyFilterPaeth(src, prev, dst, bpp)`
- [ ] Implement `selectFilter(row, prev, bpp, strategy) FilterType`
- [ ] Implement sum-of-absolutes heuristic for adaptive selection
- [ ] Add unit tests

### 6.2 Chunk Writing
- [ ] Extend `src/chunks/critical.zig`
- [ ] Implement `writeIhdr(writer, header)`
- [ ] Implement `writePlte(writer, palette)`
- [ ] Implement `writeIdat(writer, data)`
- [ ] Implement `writeIend(writer)`
- [ ] All write functions compute and append CRC

### 6.3 Encoder Core
- [ ] Create `src/encoder.zig`
- [ ] Define `EncodeOptions` struct (compression_level, filter_strategy, etc.)
- [ ] Write PNG signature
- [ ] Write IHDR chunk
- [ ] Write PLTE chunk if indexed
- [ ] Filter and compress pixel data
- [ ] Write IDAT chunk(s)
- [ ] Write IEND chunk

### 6.4 Simple Encode API
- [ ] Implement `png.encode(image, writer) !void`
- [ ] Implement `png.encodeBuffer(allocator, image) ![]u8`
- [ ] Implement `png.encodeFile(image, path) !void`
- [ ] Add round-trip tests (decode -> encode -> decode)

---

## Phase 7: Streaming API

### 7.1 Stream Decoder
- [ ] Create `StreamDecoder` in `src/decoder.zig`
- [ ] Implement state machine for incremental parsing
- [ ] Implement `StreamDecoder.feed(data) !?[]Row`
- [ ] Implement `StreamDecoder.getHeader() ?Header`
- [ ] Implement `StreamDecoder.finish()`
- [ ] Handle row-by-row callback
- [ ] Add tests with chunked input

### 7.2 Stream Encoder
- [ ] Create `StreamEncoder` in `src/encoder.zig`
- [ ] Implement `StreamEncoder.init(writer, header, options)`
- [ ] Implement `StreamEncoder.writeRow(pixels)`
- [ ] Implement `StreamEncoder.finish()`
- [ ] Buffer and compress rows incrementally
- [ ] Add tests

---

## Phase 8: Ancillary Chunks

### 8.1 Transparency
- [ ] Create `src/chunks/ancillary.zig`
- [ ] Parse tRNS chunk
- [ ] Handle grayscale transparency (single value)
- [ ] Handle RGB transparency (single color)
- [ ] Handle indexed transparency (alpha per palette entry)
- [ ] Store in Image.transparency

### 8.2 Text Chunks
- [ ] Parse tEXt chunk (keyword + text)
- [ ] Parse zTXt chunk (keyword + compressed text)
- [ ] Parse iTXt chunk (international text)
- [ ] Define `TextChunk` struct
- [ ] Store in Image.text_chunks
- [ ] Implement writing text chunks

### 8.3 Color Chunks
- [ ] Parse gAMA chunk (gamma)
- [ ] Parse cHRM chunk (chromaticity)
- [ ] Parse sRGB chunk (standard RGB)
- [ ] Parse iCCP chunk (ICC profile)
- [ ] Store in Image struct
- [ ] Implement writing color chunks

### 8.4 Other Chunks
- [ ] Parse pHYs chunk (pixel dimensions)
- [ ] Parse tIME chunk (modification time)
- [ ] Parse bKGD chunk (background color)
- [ ] Parse sBIT chunk (significant bits)
- [ ] Handle unknown ancillary chunks gracefully

---

## Phase 9: Polish

### 9.1 Error Handling
- [ ] Define comprehensive `Error` enum in `src/png.zig`
- [ ] Add descriptive error messages
- [ ] Ensure all error paths free allocated memory
- [ ] Add tests for error conditions

### 9.2 SIMD Optimizations
- [ ] Profile hot paths
- [ ] SIMD filter operations (Sub, Up, Average)
- [ ] Consider SIMD CRC32 (if beneficial)
- [ ] Benchmark improvements

### 9.3 Comprehensive Testing
- [ ] Full PngSuite coverage
- [ ] Fuzz testing with random/mutated input
- [ ] Memory leak testing
- [ ] Round-trip tests for all configurations
- [ ] Performance benchmarks vs libpng/stb_image

### 9.4 Documentation
- [ ] Doc comments on all public API
- [ ] Usage examples in README
- [ ] Example programs in `examples/` directory

---

## Current Status

**Next Task:** Phase 1.1 - Project Setup

---

## File Structure (Target)

```
zig-png/
├── build.zig
├── DESIGN.md
├── PLAN.md
├── README.md
├── src/
│   ├── png.zig
│   ├── decoder.zig
│   ├── encoder.zig
│   ├── color.zig
│   ├── filters.zig
│   ├── interlace.zig
│   ├── chunks/
│   │   ├── chunks.zig
│   │   ├── critical.zig
│   │   └── ancillary.zig
│   ├── compression/
│   │   ├── deflate.zig
│   │   ├── inflate.zig
│   │   ├── zlib.zig
│   │   ├── huffman.zig
│   │   └── lz77.zig
│   ├── utils/
│   │   ├── crc32.zig
│   │   ├── adler32.zig
│   │   ├── bit_reader.zig
│   │   └── bit_writer.zig
│   └── testing/
│       └── test_images/
└── examples/
    ├── decode.zig
    └── encode.zig
```
