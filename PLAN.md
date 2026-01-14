# Zig PNG Library Implementation Plan

This plan breaks down the implementation into concrete, actionable tasks based on the architecture defined in DESIGN.md.

---

## Phase 1: Foundation ✅

### 1.1 Project Setup ✅
- [x] Create `src/png.zig` - Main entry point with public API re-exports
- [x] Create `build.zig` - Build configuration with test support
- [x] Add `.gitignore` for Zig cache directories

### 1.2 CRC32 Implementation ✅
- [x] Create `src/utils/crc32.zig`
- [x] Implement CRC32 lookup table (precomputed at comptime)
- [x] Implement `crc32(data: []const u8) u32` function
- [x] Implement streaming `Crc32` struct with `update()` and `final()`
- [x] Add unit tests for known CRC32 values

### 1.3 Adler32 Implementation ✅
- [x] Create `src/utils/adler32.zig`
- [x] Implement `adler32(data: []const u8) u32` function
- [x] Implement streaming `Adler32` struct with `update()` and `final()`
- [x] Add unit tests for known Adler32 values

### 1.4 Bit Reader ✅
- [x] Create `src/utils/bit_reader.zig`
- [x] Implement `BitReader` struct wrapping any reader
- [x] Implement `readBits(n: u4) !u16` - read n bits (LSB first for deflate)
- [x] Implement `readByte() !u8` - read aligned byte
- [x] Implement `alignToByte()` - skip to next byte boundary
- [x] Add unit tests

### 1.5 Bit Writer ✅
- [x] Create `src/utils/bit_writer.zig`
- [x] Implement `BitWriter` struct wrapping any writer
- [x] Implement `writeBits(value: u16, n: u4) !void`
- [x] Implement `flush() !void` - flush partial byte
- [x] Add unit tests

### 1.6 Core Types ✅
- [x] Create `src/color.zig`
- [x] Define `ColorType` enum (grayscale, rgb, indexed, grayscale_alpha, rgba)
- [x] Define `BitDepth` enum (1, 2, 4, 8, 16)
- [x] Define `InterlaceMethod` enum (none, adam7)
- [x] Define `FilterType` enum (none, sub, up, average, paeth)
- [x] Implement `isValidColorBitDepthCombo()` validation
- [x] Add `bytesPerPixel()` helper

### 1.7 Chunk Framework ✅
- [x] Create `src/chunks/chunks.zig`
- [x] Define `Chunk` struct (length, type, data, crc)
- [x] Implement `readChunk(reader) !Chunk` - parse chunk from stream
- [x] Implement `writeChunk(writer, type, data) !void`
- [x] Implement chunk property methods (`isCritical`, `isPublic`, `isSafeToCopy`)
- [x] Add CRC validation
- [x] Add unit tests

### 1.8 IHDR Parsing ✅
- [x] Create `src/chunks/critical.zig`
- [x] Define `Header` struct with all IHDR fields
- [x] Implement `parseIhdr(data: []const u8) !Header`
- [x] Implement `Header.bytesPerPixel()`, `Header.bytesPerRow()`
- [x] Implement `Header.isValid()` - validate field combinations
- [x] Add unit tests

### 1.9 PNG Signature ✅
- [x] Add PNG signature constant: `{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }`
- [x] Implement signature validation in decoder

---

## Phase 2: Decompression (Inflate) ✅

### 2.1 Huffman Decoding ✅
- [x] Create `src/compression/huffman.zig`
- [x] Define `HuffmanTree` struct
- [x] Implement `HuffmanTree.build(code_lengths: []const u4) !HuffmanTree`
- [x] Implement `HuffmanTree.decode(bit_reader) !u16`
- [x] Add fixed literal/length tree (RFC 1951 section 3.2.6)
- [x] Add fixed distance tree
- [x] Add unit tests

### 2.2 Inflate Core ✅
- [x] Create `src/compression/inflate.zig`
- [x] Define `Inflate` struct with 32KB sliding window
- [x] Implement block header parsing (BFINAL, BTYPE)
- [x] Implement uncompressed block handling (BTYPE=00)
- [x] Implement fixed Huffman block decoding (BTYPE=01)
- [x] Add unit tests with known compressed data

### 2.3 Dynamic Huffman ✅
- [x] Implement dynamic Huffman header parsing (BTYPE=10)
- [x] Parse HLIT, HDIST, HCLEN
- [x] Decode code length alphabet
- [x] Build literal/length and distance trees
- [x] Add unit tests

### 2.4 LZ77 Decoding ✅
- [x] Implement length/distance decoding in inflate
- [x] Handle extra bits for lengths (257-285)
- [x] Handle extra bits for distances (0-29)
- [x] Copy from sliding window
- [x] Add unit tests

### 2.5 Zlib Wrapper ✅
- [x] Create `src/compression/zlib.zig`
- [x] Implement `ZlibReader` wrapping inflate
- [x] Parse CMF/FLG header bytes
- [x] Validate compression method (CM=8)
- [x] Validate window size (CINFO)
- [x] Verify Adler32 checksum at end
- [x] Add unit tests

---

## Phase 3: Basic Decoding ✅

### 3.1 Filter Reconstruction ✅
- [x] Create `src/filters.zig`
- [x] Implement `unfilterNone()` - no-op
- [x] Implement `unfilterSub(row, bpp)` - add left neighbor
- [x] Implement `unfilterUp(row, prev_row)` - add above neighbor
- [x] Implement `unfilterAverage(row, prev_row, bpp)` - add average
- [x] Implement `unfilterPaeth(row, prev_row, bpp)` - Paeth predictor
- [x] Implement `paethPredictor(a, b, c) u8`
- [x] Implement `unfilter(filter_type, row, prev_row, bpp)` dispatcher
- [x] Add unit tests for each filter type

### 3.2 Image Structure ✅
- [x] Define `Image` struct in `src/decoder.zig`
- [x] Fields: header, pixels, palette, allocator
- [x] Implement `Image.deinit()`
- [x] Implement `Image.getPixel(x, y) []u8`
- [x] Implement `Image.getRow(y) []u8`
- [ ] Define `Pixel` union type (deferred - not needed for core functionality)

### 3.3 Decoder Core ✅
- [x] Create `src/decoder.zig`
- [x] Implement signature verification
- [x] Implement chunk iteration loop
- [x] Collect IDAT chunks into single compressed stream
- [x] Decompress IDAT data
- [x] Unfilter each row
- [x] Store pixels in Image struct
- [x] Handle all bit depths (1, 2, 4, 8, 16)
- [x] Handle all color types (grayscale, RGB, indexed, grayscale+alpha, RGBA)

### 3.4 Palette Handling ✅
- [x] Parse PLTE chunk (in `critical.zig`)
- [x] Validate palette size (1-256 entries, divisible by 3)
- [x] Store palette in Image
- [ ] Expand indexed pixels to RGB on demand (deferred - optional convenience)

### 3.5 Simple Decode API ✅
- [x] Implement `decoder.decode(allocator, buffer) !Image`
- [x] Implement `decoder.decodeFile(allocator, path) !Image`
- [x] Wire up to `png.decode()` public API
- [x] Re-export public types (Image, Header, ColorType, BitDepth, etc.)
- [x] Add decode tests for all bit depths (1, 2, 4, 8, 16)
- [x] Add decode tests for all color types

### 3.6 Test Images
- [ ] Create `src/testing/` directory
- [ ] Download PngSuite test images
- [ ] Add integration tests with real PNG files

---

## Phase 4: Adam7 Interlacing ✅

### 4.1 Interlace Support ✅
- [x] Create `src/interlace.zig`
- [x] Define `Adam7` constants (origins, spacings)
- [x] Implement `Adam7.passWidth(pass, image_width) u32`
- [x] Implement `Adam7.passHeight(pass, image_height) u32`
- [x] Implement `Adam7.passRowBytes(pass, header) usize`
- [x] Add unit tests for pass dimension calculations

### 4.2 Deinterlacing ✅
- [x] Implement pass extraction from compressed data
- [x] Each pass is filtered independently
- [x] Implement `Adam7.deinterlace(passes, output, header)`
- [x] Scatter pass pixels to correct positions in output
- [x] Add integration tests with interlaced PNGs

### 4.3 Interlacing (for encoder) ✅
- [x] Implement `Adam7.interlace(input, passes, header)`
- [x] Extract pixels for each pass from full image
- [x] Add unit tests

---

## Phase 5: Compression (Deflate) ✅

### 5.1 Huffman Encoding ✅
- [x] Extend `src/compression/huffman.zig`
- [x] Define `HuffmanEncoder` struct
- [x] Implement `HuffmanEncoder.buildFromFrequencies(freq) HuffmanEncoder`
- [x] Implement canonical Huffman code generation
- [x] Implement `HuffmanEncoder.encode(symbol, bit_writer)`
- [x] Add unit tests

### 5.2 LZ77 Matching ✅
- [x] Create `src/compression/lz77.zig`
- [x] Define `HashChain` struct for 3-byte hash chains
- [x] Implement `HashChain.insert(pos, data)`
- [x] Implement `HashChain.findMatch(pos, data, max_chain) ?Match`
- [x] Support different compression levels via maxChainLength
- [x] Add unit tests

### 5.3 Deflate Core ✅
- [x] Create `src/compression/deflate.zig`
- [x] Define `Deflate` struct with compression options
- [x] Implement stored block output (level 0)
- [x] Implement fixed Huffman encoding (levels 1-9)
- [ ] Implement dynamic Huffman encoding (deferred - fixed provides good compression)
- [x] Implement `Deflate.compress(data)`
- [x] Add round-trip tests with inflate

### 5.4 Zlib Compression ✅
- [x] Extend `src/compression/zlib.zig`
- [x] Implement `compress()` function wrapping deflate
- [x] Write CMF/FLG header with `generateHeader()`
- [x] Calculate and append Adler32
- [x] Add round-trip tests

---

## Phase 6: Encoding ✅

### 6.1 Filter Selection ✅
- [x] Extend `src/filters.zig`
- [x] Implement `filterNone(src, dst)`
- [x] Implement `filterSub(src, dst, bpp)`
- [x] Implement `filterUp(src, prev, dst)`
- [x] Implement `filterAverage(src, prev, dst, bpp)`
- [x] Implement `filterPaeth(src, prev, dst, bpp)`
- [x] Implement `filterRow(filter, src, prev, dst, bpp)` dispatcher
- [x] Implement `selectBestFilter(row, prev, bpp, scratch)` with sum-of-absolutes heuristic
- [x] Add `FilterStrategy` enum (none, sub, up, average, paeth, adaptive)
- [x] Add unit tests

### 6.2 Chunk Writing ✅
- [x] Use existing `writeChunk()` in `src/chunks/chunks.zig`
- [x] Use existing `Header.serialize()` in `src/chunks/critical.zig`
- [x] Implement `serializePlte(palette, buffer)` in `src/chunks/critical.zig`
- [x] All write functions compute and append CRC via writeChunk

### 6.3 Encoder Core ✅
- [x] Create `src/encoder.zig`
- [x] Define `EncodeOptions` struct (compression_level, filter_strategy)
- [x] Write PNG signature
- [x] Write IHDR chunk
- [x] Write PLTE chunk if indexed
- [x] Filter and compress pixel data (non-interlaced and interlaced)
- [x] Write IDAT chunk(s) with 32KB splitting
- [x] Write IEND chunk

### 6.4 Simple Encode API ✅
- [x] Implement `png.encode(allocator, image, output, options) !usize`
- [x] Implement `png.encodeRaw(allocator, header, pixels, palette, output, options) !usize`
- [x] Implement `png.encodeFile(allocator, image, path, options) !void`
- [x] Implement `png.maxEncodedSize(header) usize`
- [x] Add round-trip tests (decode -> encode -> decode)

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

**Completed:**
- Phase 1: Foundation ✅
- Phase 2: Decompression (Inflate) ✅
- Phase 3: Basic Decoding ✅ (all bit depths and color types supported)
- Phase 4: Adam7 Interlacing ✅
- Phase 5: Compression (Deflate) ✅ (stored and fixed Huffman blocks)
- Phase 6: Encoding ✅ (full PNG encoder with filtering and compression)

**Next Task:** Phase 7 - Streaming API (optional, for incremental processing)

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
