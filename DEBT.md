# Project Debt

## [ ] Debt 1: tools/ executables do not build on Zig 0.16

**Status:** Open
**Kind:** tooling
**Where:** `tools/validate.zig`, `tools/pngsuite.zig`, `tools/cross_validate.zig`, `tools/realworld_test.zig`, `tools/gen_malformed.zig`, `tools/afl_harness.zig`
**Due when:** touching `tools/` · before the next release

**Description:** `zig build` fails on Zig 0.16: every tool uses
`std.heap.GeneralPurposeAllocator` (removed) and the old file, argument and
`ArrayListUnmanaged{}` APIs. The library and `zig build test` were ported on
`mail/2026-10-31-getpixel-subbyte-depth`; the tools were left because each needs the
0.16 file-I/O rework, which is unrelated to that fix.

**Payment:** Port each tool to the 0.16 std APIs (allocator, `std.Io` file and
process-argument access, `.empty` list init) until `zig build` and `zig build pngsuite`
pass.

**Found by:** /mail on mail/2026-10-31-getpixel-subbyte-depth, 2026-10-31 — main session.
