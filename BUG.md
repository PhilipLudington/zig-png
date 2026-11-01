# Project Bugs

## [ ] Bug 1: getPixel returns wrong data for 1-, 2- and 4-bit images

**Status:** Open

**System:** pixel access — `Image.getPixel`, `Image.getRow` in `src/decoder.zig`

**Description:** `getPixel` offsets by `x * bytesPerPixel()`, and `bytesPerPixel()` is 1
for every sub-byte depth, while a row holds only `ceil(width * bits / 8)` bytes. It returns
a byte that packs 2, 4 or 8 pixels, reads into later rows past the row's real width, and
on the last rows returns `error.BufferOutOfBounds` for in-bounds pixels. Reported by
zig-png-examples (mail 2026-10-26): 69 PngSuite files at 1/2/4 bits render magenta in its
folder browser.

**Steps to reproduce:**
1. Decode an 8x2 1-bit grayscale PNG (rows `0xAA`, `0x55`).
2. Call `image.getPixel(7, 1)` and `image.getPixel(1, 0)`.

**Expected:** Each call gives the single pixel value (1 and 0), or a clear error saying
this accessor cannot return one bit.

**Actual:** `getPixel(7, 1)` returns `error.BufferOutOfBounds`; `getPixel(1, 0)` returns
the packed byte `0xAA`.
