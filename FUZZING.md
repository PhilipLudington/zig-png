# Fuzz Testing for zig-png

This document describes how to run fuzz tests on the zig-png library.

## Overview

The library provides two fuzzing options:

1. **Zig Built-in Fuzzer** - Native integration with `zig build fuzz --fuzz` (Linux only)
2. **AFL++ Harness** - External fuzzer support for macOS, Linux, and other platforms

Both options test four targets:
- **decode** - Full PNG decoding with arbitrary input
- **chunks** - Chunk parsing and CRC validation
- **inflate** - Zlib/DEFLATE decompression
- **roundtrip** - Decode → Encode → Decode consistency

## Option 1: Zig Built-in Fuzzer

### Quick Test (All Platforms)

Run fuzz tests once to validate the harness:

```bash
zig build fuzz
```

### Continuous Fuzzing (Linux Only)

```bash
zig build fuzz --fuzz
```

**Note**: The `--fuzz` flag currently only works on Linux. See [ziglang/zig#20986](https://github.com/ziglang/zig/issues/20986) for macOS support status.

## Option 2: AFL++ Harness (Recommended for macOS)

### Install AFL++

```bash
# macOS
brew install aflplusplus

# Ubuntu/Debian
sudo apt install afl++

# From source
git clone https://github.com/AFLplusplus/AFLplusplus
cd AFLplusplus && make && sudo make install
```

### Build the Harness

```bash
zig build afl-harness
```

### Create Seed Corpus

```bash
mkdir -p fuzz_corpus
cp test_data/*.png fuzz_corpus/
```

### Run AFL++

```bash
# Basic fuzzing
afl-fuzz -i fuzz_corpus -o fuzz_output -- ./zig-out/bin/afl-harness --decode

# With multiple cores (parallel fuzzing)
afl-fuzz -i fuzz_corpus -o fuzz_output -M main -- ./zig-out/bin/afl-harness --decode &
afl-fuzz -i fuzz_corpus -o fuzz_output -S secondary1 -- ./zig-out/bin/afl-harness --decode &
afl-fuzz -i fuzz_corpus -o fuzz_output -S secondary2 -- ./zig-out/bin/afl-harness --decode &
```

### Fuzz Different Targets

```bash
# PNG decoder (default)
afl-fuzz -i fuzz_corpus -o fuzz_output -- ./zig-out/bin/afl-harness --decode

# Chunk parsing
afl-fuzz -i fuzz_corpus -o fuzz_output -- ./zig-out/bin/afl-harness --chunks

# Zlib decompression
afl-fuzz -i fuzz_corpus -o fuzz_output -- ./zig-out/bin/afl-harness --inflate

# Roundtrip testing
afl-fuzz -i fuzz_corpus -o fuzz_output -- ./zig-out/bin/afl-harness --roundtrip
```

### AFL++ Tips

1. **Minimize corpus first**:
   ```bash
   afl-cmin -i fuzz_corpus -o fuzz_corpus_min -- ./zig-out/bin/afl-harness --decode
   ```

2. **Check coverage**:
   ```bash
   afl-showmap -o /dev/null -- ./zig-out/bin/afl-harness --decode < test_data/basi0g08.png
   ```

3. **Resume fuzzing**:
   ```bash
   afl-fuzz -i- -o fuzz_output -- ./zig-out/bin/afl-harness --decode
   ```

## What Gets Tested

### Decode Target (`--decode`)
- PNG signature validation
- Chunk parsing and CRC verification
- IHDR header validation
- Zlib decompression
- Filter reconstruction
- Interlacing support
- Memory allocation bounds

### Chunks Target (`--chunks`)
- Chunk length validation
- Chunk type validation (ASCII letters)
- Chunk boundary handling
- CRC calculation

### Inflate Target (`--inflate`)
- Zlib header validation
- DEFLATE decompression
- Checksum verification

### Roundtrip Target (`--roundtrip`)
- Full decode → encode → decode cycle
- Pixel-perfect preservation
- Dimension preservation

## Interpreting Results

- **Normal exits**: Expected for invalid input (decode errors)
- **Crashes**: Indicate bugs - check `fuzz_output/crashes/`
- **Hangs**: Check `fuzz_output/hangs/` - may indicate infinite loops
- **Unique crashes**: AFL++ deduplicates crashes automatically

## Reproducing Crashes

```bash
# Reproduce a crash
./zig-out/bin/afl-harness --decode < fuzz_output/crashes/id:000000,sig:06,...

# Debug with GDB (Linux)
gdb --args ./zig-out/bin/afl-harness --decode < crash_input

# Debug with LLDB (macOS)
lldb -- ./zig-out/bin/afl-harness --decode < crash_input
```

## CI Integration

```yaml
# GitHub Actions example
jobs:
  fuzz:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Zig
        uses: goto-bus-stop/setup-zig@v2

      - name: Build fuzz harness
        run: zig build fuzz

      - name: Build AFL harness
        run: zig build afl-harness

      - name: Test harness with sample input
        run: ./zig-out/bin/afl-harness --decode < test_data/basi0g08.png
```

## Files

- `src/fuzz.zig` - Zig built-in fuzzer tests
- `tools/afl_harness.zig` - AFL++ harness
- `fuzz_corpus/` - Seed corpus (gitignored, create from test_data/)
- `fuzz_output/` - AFL++ output directory (gitignored)
