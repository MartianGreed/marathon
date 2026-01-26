# Zig Best Practices Guide

Comprehensive reference for writing performant, idiomatic Zig code in the Marathon project.

## Memory Management

### Allocator Selection (in order of preference)

1. **No allocation** - Stack variables, comptime, slices of existing data
2. **FixedBufferAllocator** - Pre-sized buffer, no heap, ideal for known bounds
3. **BoundedArray** - Compile-time max size, runtime length, no allocator needed
4. **ArenaAllocator** - Batch allocations, single bulk free at scope end
5. **GeneralPurposeAllocator** - Debug builds, leak detection, safety checks
6. **SmpAllocator** - Maximum performance multithreaded allocation

### Allocation Patterns

```zig
// Slices: alloc/free
var arr = try allocator.alloc(usize, count);
defer allocator.free(arr);

// Single items: create/destroy
var item = try allocator.create(T);
defer allocator.destroy(item);

// Arena pattern - batch free
var arena = std.heap.ArenaAllocator.init(backing_allocator);
defer arena.deinit();
const aa = arena.allocator();

// Arena reset with retention (for request loops)
defer _ = arena.reset(.{ .retain_with_limit = 8192 });

// Fixed buffer - no heap
var buf: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);
```

### Memory Rules

- **Always defer cleanup** immediately after allocation
- **errdefer for partial cleanup** when multiple allocations can fail
- **Never double-free** - causes crashes
- **Track ownership** - memory must be freed by code holding reference
- **Prefer bufPrint over format** when output size is bounded

```zig
// errdefer pattern for multiple allocations
var players = try allocator.alloc(Player, count);
errdefer allocator.free(players);
var history = try allocator.alloc(Move, count * 10);
// If history alloc fails, players is freed by errdefer
```

## Error Handling

### Error Union Patterns

```zig
// Return error union
fn process() !Result { ... }
fn mayFail() error{OutOfMemory, InvalidInput}!void { ... }

// Propagate with try
const result = try mayFail();

// Handle with catch
const value = mayFail() catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
    error.InvalidInput => default_value,
};

// Catch with default
const value = mayFail() catch default_value;
```

### Error Set Composition

```zig
const FileError = error{ NotFound, PermissionDenied };
const IoError = error{ ReadError, WriteError };
const AllErrors = FileError || IoError;
```

### Best Practices

- Use `try` to propagate, `catch` to handle locally
- Never mix `try` and `catch` on same expression
- `errdefer` for cleanup on error paths only
- Panics don't trigger defer/errdefer

## Comptime & Generics

### Comptime Execution

```zig
// Compile-time constants
const PI = comptime @acos(-1.0);
const TABLE = comptime generateLookupTable();

// Comptime blocks
const x = comptime blk: {
    var result: u32 = 0;
    for (0..10) |i| result += i;
    break :blk result;
};
```

### Generic Patterns

```zig
// Generic struct
fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .items = &.{}, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }
    };
}

// Generic function
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

// anytype inference
fn print(value: anytype) void {
    const T = @TypeOf(value);
    // ...
}
```

### Type Reflection

```zig
fn isNumeric(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}
```

## Data Structures

### ArrayList

```zig
var list = std.ArrayList(u32).init(allocator);
defer list.deinit();

try list.append(42);
try list.appendSlice(&[_]u32{ 1, 2, 3 });
const slice = list.items;
```

### HashMap

```zig
// Auto hash map (most types)
var map = std.AutoHashMap(u32, []const u8).init(allocator);
defer map.deinit();

try map.put(1, "one");
if (map.get(1)) |value| { ... }

// String keys
var smap = std.StringHashMap(u32).init(allocator);

// Iteration
var iter = map.iterator();
while (iter.next()) |entry| {
    _ = entry.key_ptr.*;
    _ = entry.value_ptr.*;
}
```

### BoundedArray

```zig
// No allocator needed, fixed max size
var buf = std.BoundedArray(u8, 256){};
try buf.append('a');
try buf.appendSlice("hello");
const slice = buf.slice();

// Warning: copies entire array on assignment/function call
```

## Performance Optimization

### Build Modes

- `Debug` - Safety checks, no optimization
- `ReleaseSafe` - Optimized with safety checks
- `ReleaseFast` - Maximum speed, minimal safety
- `ReleaseSmall` - Optimized for binary size

### Techniques

```zig
// Prefer stack allocation
var buf: [1024]u8 = undefined;

// Inline hot functions
inline fn hotPath(x: u32) u32 { ... }

// SIMD vectors
const Vec4 = @Vector(4, f32);
const a: Vec4 = .{ 1, 2, 3, 4 };
const b: Vec4 = .{ 5, 6, 7, 8 };
const c = a + b; // Single SIMD instruction

// Avoid bounds checks in hot loops (when safe)
const ptr = slice.ptr;
for (0..slice.len) |i| {
    ptr[i] = value;
}

// Use sentinels to avoid length tracking
const str: [:0]const u8 = "hello";
```

### What to Avoid

- Heap allocation in hot paths
- Unnecessary copies (BoundedArray, large structs by value)
- Virtual dispatch in tight loops
- Excessive error checking in inner loops

## Slices & Pointers

### Prefer Slices

```zig
// Slice (fat pointer with length) - preferred
fn process(data: []const u8) void { ... }

// Many-pointer (no length) - use when interfacing with C
fn cProcess(data: [*]const u8, len: usize) void { ... }

// Single pointer
fn modify(ptr: *u32) void { ... }
```

### Slice Operations

```zig
const arr = [_]u8{ 1, 2, 3, 4, 5 };
const slice = arr[1..4];      // [2, 3, 4]
const from_start = arr[0..3]; // [1, 2, 3]
const to_end = arr[2..];      // [3, 4, 5]

// Sentinel-terminated
const str: [:0]const u8 = "hello";
```

## Testing

```zig
const testing = std.testing;

test "example" {
    // Use testing allocator for leak detection
    var list = std.ArrayList(u32).init(testing.allocator);
    defer list.deinit();

    try list.append(42);
    try testing.expectEqual(@as(u32, 42), list.items[0]);
    try testing.expect(list.items.len == 1);
}

// Skip test
test "skip me" {
    return error.SkipZigTest;
}
```

## Idioms

### Struct Initialization

```zig
const Config = struct {
    timeout: u32 = 30,
    retries: u8 = 3,
    host: []const u8,
};

// Partial initialization with defaults
const cfg: Config = .{ .host = "localhost" };
```

### Optional Handling

```zig
const maybe: ?u32 = getValue();

// orelse for default
const value = maybe orelse 0;

// if for conditional
if (maybe) |v| {
    process(v);
}

// .? for unwrap (panics on null)
const value = maybe.?;
```

### Iteration

```zig
// Index and value
for (items, 0..) |item, i| { ... }

// Just values
for (items) |item| { ... }

// Just index
for (0..items.len) |i| { ... }
```

## Sources

- [Zig Documentation](https://ziglang.org/documentation/master/)
- [zig.guide](https://zig.guide/)
- [Learning Zig](https://www.openmymind.net/learning_zig/)
- [Zig Allocators Guide](https://zig.guide/standard-library/allocators/)
- [Leveraging Zig's Allocators](https://www.openmymind.net/Leveraging-Zigs-Allocators/)
