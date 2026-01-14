---
globs: ["*.zig"]
---

# Memory Management Rules

## M1: Allocator Injection
- ALWAYS accept `Allocator` as a parameter for functions that allocate
- NEVER use global allocators like `std.heap.page_allocator` directly
- Store allocator in struct if needed for deinit

```zig
// GOOD
pub fn init(allocator: Allocator) !Self

// BAD
pub fn init() !Self  // Hidden allocation
```

## M2: Ownership Documentation
- Document who owns returned pointers/slices
- Use "Caller owns" or "Valid until" patterns

```zig
/// Caller owns the returned slice and must free it.
pub fn duplicate(allocator: Allocator, data: []const u8) ![]u8
```

## M3: Immediate Cleanup
- Place `defer` immediately after resource acquisition
- Use `errdefer` for cleanup on error paths only

```zig
const buffer = try allocator.alloc(u8, size);
defer allocator.free(buffer);  // Immediately after

const file = try openFile(path);
errdefer file.close();  // Only on error
```

## M4: Struct Lifecycle
- Use `init/deinit` for stack-allocated structs
- Use `create/destroy` for heap-allocated structs
- Set `self.* = undefined` at end of deinit to poison

## M5: Arena for Batch Operations
- Use `ArenaAllocator` when many allocations share lifetime
- Frees everything at once, simpler code

## M6: Testing Allocator
- Use `std.testing.allocator` in tests (checks leaks)
- Use `std.heap.GeneralPurposeAllocator` for debug builds

## M7: ArrayList Patterns (Zig 0.15+)
- `std.ArrayListUnmanaged` is now the default/simpler pattern
- `std.ArrayList` (managed) requires allocator per method call
- Prefer unmanaged when allocator is stored in parent struct

```zig
// Unmanaged (preferred in 0.15+): simpler, allocator passed to methods
var list = std.ArrayListUnmanaged(u8){};
defer list.deinit(allocator);
try list.append(allocator, value);

// Managed: allocator stored in list, passed per method
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.append(allocator, value);  // Still needs allocator in 0.15!
```

## M8: Avoid undefined in Arithmetic
- Zig 0.15 disallows `undefined` in arithmetic operations
- Initialize variables explicitly before use

```zig
// BAD (Zig 0.15 compile error)
var x: u32 = undefined;
x += 1;

// GOOD
var x: u32 = 0;
x += 1;
```
