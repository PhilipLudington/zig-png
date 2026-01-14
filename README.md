# zig-png

A pure Zig implementation of PNG image encoding and decoding. No external dependencies.

## Features

- **Full PNG support**: All standard color types (grayscale, RGB, indexed, grayscale+alpha, RGBA)
- **All bit depths**: 1, 2, 4, 8, and 16 bits per channel
- **Interlacing**: Adam7 interlaced image support (decode and encode)
- **Filtering**: All PNG filter types with adaptive filter selection
- **Compression**: DEFLATE compression with configurable levels
- **Streaming API**: Incremental decode/encode for memory-efficient processing

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .png = .{
        .url = "https://github.com/PhilipLudington/zig-png/archive/main.tar.gz",
        .hash = "...", // Add hash after first build attempt
    },
},
```

Then in your `build.zig`:

```zig
const png = b.dependency("png", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("png", png.module("png"));
```

## Usage

### Decoding a PNG

```zig
const png = @import("png");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Decode from file
    var image = try png.decodeFile(allocator, "image.png");
    defer image.deinit();

    // Access image properties
    std.debug.print("Size: {}x{}\n", .{ image.width(), image.height() });
    std.debug.print("Color type: {}\n", .{image.header.color_type});

    // Access pixel data
    const pixel = image.getPixel(0, 0);
    std.debug.print("Top-left pixel: {any}\n", .{pixel});

    // Get a full row
    const row = image.getRow(0);
    _ = row;
}
```

### Decoding from memory

```zig
const png_data: []const u8 = // ... PNG file bytes
var image = try png.decode(allocator, png_data);
defer image.deinit();
```

### Encoding a PNG

```zig
const png = @import("png");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create image header
    const header = png.Header{
        .width = 256,
        .height = 256,
        .bit_depth = .@"8",
        .color_type = .rgb,
        .compression_method = .deflate,
        .filter_method = .adaptive,
        .interlace_method = .none,
    };

    // Create pixel data (RGB, 3 bytes per pixel)
    var pixels: [256 * 256 * 3]u8 = undefined;
    for (0..256) |y| {
        for (0..256) |x| {
            const i = (y * 256 + x) * 3;
            pixels[i] = @intCast(x);     // Red
            pixels[i + 1] = @intCast(y); // Green
            pixels[i + 2] = 128;         // Blue
        }
    }

    // Encode to buffer
    const max_size = png.maxEncodedSize(header);
    var output = try allocator.alloc(u8, max_size);
    defer allocator.free(output);

    const encoded_len = try png.encodeRaw(
        allocator,
        header,
        &pixels,
        null, // palette (for indexed images)
        output,
        .{},  // default options
    );

    // Write to file
    const file = try std.fs.cwd().createFile("output.png", .{});
    defer file.close();
    try file.writeAll(output[0..encoded_len]);
}
```

### Encoding options

```zig
const options = png.EncodeOptions{
    .compression_level = .best,  // .store, .fastest, .fast, .default, .best
    .filter_strategy = .adaptive, // .none, .sub, .up, .average, .paeth, .adaptive
};

const len = try png.encodeRaw(allocator, header, pixels, null, output, options);
```

### Streaming Decoder

For processing large images without loading everything into memory:

```zig
const png = @import("png");

pub fn processLargeImage(allocator: Allocator, data: []const u8) !void {
    var decoder = png.StreamDecoder.init(allocator);
    defer decoder.deinit();

    // Feed data (can be done in chunks)
    if (try decoder.feed(data)) |row| {
        processRow(row);
        row.deinit();
    }

    // Drain remaining rows
    while (try decoder.nextRow()) |row| {
        processRow(row);
        row.deinit();
    }

    // Or get complete image at end
    var image = try decoder.finish();
    defer image.deinit();
}
```

### Streaming Encoder

For encoding images row-by-row:

```zig
const png = @import("png");
const std = @import("std");

pub fn encodeStreaming(allocator: Allocator, header: png.Header) !void {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var encoder = try png.StreamEncoder(@TypeOf(output.writer(allocator))).init(
        allocator,
        header,
        null, // palette
        output.writer(allocator),
        .{},
    );
    defer encoder.deinit();

    // Write rows one at a time
    for (0..header.height) |y| {
        const row_pixels = generateRow(y);
        try encoder.writeRow(row_pixels);
    }

    // Finalize
    try encoder.finish();

    // output.items now contains the PNG data
}
```

## API Reference

### Types

| Type | Description |
|------|-------------|
| `Image` | Decoded PNG image with pixel data |
| `Header` | PNG image header (dimensions, color type, etc.) |
| `ColorType` | `.grayscale`, `.rgb`, `.indexed`, `.grayscale_alpha`, `.rgba` |
| `BitDepth` | `.@"1"`, `.@"2"`, `.@"4"`, `.@"8"`, `.@"16"` |
| `PaletteEntry` | RGB color for indexed images |

### Functions

| Function | Description |
|----------|-------------|
| `decode(allocator, data)` | Decode PNG from memory buffer |
| `decodeFile(allocator, path)` | Decode PNG from file |
| `encode(allocator, image, output, options)` | Encode Image to buffer |
| `encodeRaw(allocator, header, pixels, palette, output, options)` | Encode raw pixels |
| `encodeFile(allocator, image, path, options)` | Encode Image to file |
| `maxEncodedSize(header)` | Calculate max buffer size for encoding |

### Streaming Types

| Type | Description |
|------|-------------|
| `StreamDecoder` | Incremental PNG decoder |
| `StreamEncoder(WriterType)` | Incremental PNG encoder |
| `DecodedRow` | Single decoded row from stream decoder |

## Limitations

- Streaming API does not support Adam7 interlaced images
- Ancillary chunks (tEXt, gAMA, etc.) are currently ignored during decoding

## License

MIT License - see [LICENSE](LICENSE) for details.
