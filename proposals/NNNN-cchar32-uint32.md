# Change `CChar32` to `UInt32`

* Proposal: [SE-NNNN](NNNN-cchar32-uint32.md)
* Authors: [John Hui](https://github.com/j-hui)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#92870](https://github.com/swiftlang/swift/pull/92870)
* Review: ([pitch](https://forums.swift.org/t/pitch-change-cchar32-to-uint32/89962))

## Summary of changes

Changes `CChar32`, the Swift type for C++ `char32_t`, from `Unicode.Scalar` to `UInt32`.

## Motivation

`Unicode.Scalar` always holds a valid Unicode scalar value
(`0...0xD7FF` or `0xE000...0x10FFFF`).
C and C++ make no such guarantee for `char32_t`,
which can hold any 32-bit integer value:

```cpp
// C++
char32_t make_char(uint32_t i) { return i; } // Valid C++
```

With C++ interoperability enabled,
Swift imports `char32_t` as `CChar32`, which resolves to `Unicode.Scalar`.
This lets C++ pass invalid Unicode values into Swift:

```swift
// Swift
let c: Unicode.Scalar = make_char(0xD800)  // Holds an invalid value
```

The imported type also depends on the interoperability mode.
In C and Objective-C, `char32_t` is a typedef of a 32-bit integer type,
so it already imports as `UInt32`.
In C++, `char32_t` is a built-in type that Swift maps to `CChar32`.
The same header therefore produces different Swift types
depending on whether C++ interoperability is enabled.
This proposal makes C++ interoperability consistent with C and Objective-C.

`CChar8` is `UInt8` and `CChar16` is `UInt16`;
`CChar32` is the only sized character type alias in this family
that does not resolve to an integer type.
`CWideChar` is also `Unicode.Scalar` on non-Windows platforms,
but is out of scope (see [Future directions](#future-directions)).

## Proposed solution

```diff
-/// The C++11 'char32_t' type, which has UTF-32 encoding.
-public typealias CChar32 = Unicode.Scalar
+/// The C++11 'char32_t' type.
+public typealias CChar32 = UInt32
```

C++ declarations that use `char32_t` continue to import as `CChar32`,
which now resolves to `UInt32`, consistent with C interoperability.

## Detailed design

The standard library's `CChar32` type alias changes from `Unicode.Scalar` to `UInt32`.

ClangImporter's mapping of C++ `char32_t` to `CChar32` is unchanged.
Every C++ API spelled with `char32_t` therefore imports with `UInt32`,
including pointers and buffers such as `UnsafePointer<CChar32>`
and the element type of `std::u32string`.

Swift declarations that use `CChar32` and are exposed to C++
still use `char32_t` in the generated header.

The standard library's module interface continues to show `Unicode.Scalar`
to compilers that predate this change.

`CWideChar` is unchanged.

## Source compatibility

This change breaks code that treats `CChar32`,
or `char32_t` imported from C++, as `Unicode.Scalar`.
For projects built without C++ interoperability,
only code that names `CChar32` directly is affected.

| Code                       | Result after this change                 |
|----------------------------|------------------------------------------|
| `let c: CChar32 = "a"`     | error: `UInt32` has no scalar literals   |
| `CChar32(42)!`             | error: result is not optional            |
| `make_char(42).value`      | error: no member `value`                 |
| `u32str.push_back(scalar)` | error: expects `UInt32`                  |
| `print(make_char(97))`     | before: prints `a`; after: prints `97`   |
| `CChar32("a")`             | before: `a`; after: `nil`                |

The source compatibility suite passes with this change.

This proposal does not use an upcoming feature flag or a new language mode.
`CChar32` is a single, rarely used type alias.
Making its meaning depend on each module's language mode would need special handling in the compiler,
and a library and its clients built in different modes would disagree on what `CChar32` means.

## ABI compatibility

`UInt32` and `Unicode.Scalar` have the same size, alignment, and calling convention.

Mangled names change.
A Swift function with `CChar32` in its signature gets a new symbol when recompiled.
Rebuilding an ABI-stable library that exposes `CChar32` in public API changes its symbols,
which breaks clients compiled against the old version.
Such libraries can keep their existing symbols
by writing `Unicode.Scalar` instead of `CChar32` in those declarations.
Clients that build against an existing binary library's `.swiftinterface` mentioning `CChar32`
refer to symbols the library does not export.

The standard library's own ABI does not change, since `CChar32` appears only in the type alias itself.

The Objective-C type encoding for `CChar32` in `@objc` methods changes from `int` (`i`) to `unsigned int` (`I`).

## Implications on adoption

This change has no runtime component and does not depend on the deployment target.

`CChar32` is `UInt32` only when both the compiler
and the standard library it builds against include this change.
On platforms where the standard library ships separately from the compiler,
such as Apple SDKs, the two can differ.
Conditional compilation on the compiler cannot tell which definition is in effect.

Affected code can instead migrate to forms that build with either definition:

```swift
// Before
let c: CChar32 = "a"
let s: Unicode.Scalar = make_char(97)
u32str.push_back(scalar)

// After
let c: CChar32 = .init("a" as Unicode.Scalar)
let s: Unicode.Scalar? = Unicode.Scalar(UInt32(make_char(97)))
u32str.push_back(.init(scalar))
```

ABI-stable libraries that expose `CChar32` in public API
should write `Unicode.Scalar` explicitly to keep their existing symbols
(see [ABI compatibility](#abi-compatibility)).

## Future directions

`CWideChar` (`wchar_t`) is also `Unicode.Scalar` on non-Windows platforms and has the same problem.
`wchar_t` is more widely used, so changing it would break more code.
A separate proposal could address it.

## Alternatives considered

### Keep `Unicode.Scalar` and validate at the language boundary

Function arguments and results can be checked,
but `char32_t` data often crosses the boundary in buffers where no check is possible,
such as `std::u32string::data()` or `UnsafePointer<CChar32>`.

### Import `char32_t` as `UInt32`, but keep `CChar32` as `Unicode.Scalar`

This keeps the meaning and mangling of code that names `CChar32`,
but `CChar32` would no longer be the Swift type for `char32_t`.
Code that uses `CChar32` for `char32_t` values,
like `let c: CChar32 = make_char(97)`, would break instead.

### Use an upcoming feature flag or a new language mode

See [Source compatibility](#source-compatibility).
