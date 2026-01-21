# Safe loading API for `RawSpan`

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Previous Proposal: follows [SE-0447][SE-0447]
* Previous Revision: [pitch 1](https://github.com/glessard/swift-evolution/blob/fdd9b855befea7071c43b774330a02b9cc173174/proposals/nnnn-rawspan-safe-loading-api.md)
* Review: ([pitch 1](https://forums.swift.org/t/83966)), ([pitch 2](https://forums.swift.org/t/84144))

[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[swift-binary-parsing]: https://github.com/apple/swift-binary-parsing

## Introduction

We propose the introduction of a set of safe API to load values of certain safe types from the memory represented by `RawSpan` instances, as well as safe conversions from `RawSpan` to `Span` for the same types.

## Motivation

In [SE-0447][SE-0447], we introduced `RawSpan` along with some unsafe functions to load values of arbitrary types. While it is safe to load any of the native integer types with those functions, the `unsafe` annotation introduces an element of doubt for users of the standard library. This proposal aims to provide clarity for safe uses of byte-loading operations.

## Proposed solution

##### `FullyInhabited`

We propose a new layout constraint, `FullyInhabited`, to refine `BitwiseCopyable`. A `FullyInhabited` type is a safe type with a valid value for every bit pattern that can fit in its stride. This means that a `FullyInhabited` type's size equals its stride, and has no internal padding bytes.

By conforming to `FullyInhabited`, a type declares that it has the following characteristics:

- It has one or more stored properties.
- The types of its stored properties all themselves conform to `FullyInhabited`.
- Its stored properties are stored contiguously in memory, with no padding.
- It is frozen if its containing module is resilient.
- There are no semantic constraints on the values of its stored properties.

The standard library's `FixedWidthInteger` and `BinaryFloatingPoint` types will conform to `FullyInhabited`.

For example, a type representing two-dimensional Cartesian coordinates, such as `struct Point { var x, y: Int }` could conform to `FullyInhabited`. Its stored properties are `Int`, which is `FullyInhabited`. There are no semantic constraints between the `x` and `y` properties: any combination of `Int` values can represent a valid `Point`.

In contrast, `Range<Int>` could not conform to `FullyInhabited`, even though on the surface it has the same composition as `Point`. There is a semantic constraint between two two stored properties of `Range`: `lowerBound` must be less than or equal to `upperBound`. This makes it unable to conform to `FullyInhabited`.

Other examples of types that cannot conform to `FullyInhabited` are `UnicodeScalar` (some bit patterns are invalid,) a hypothetical UTF8-encoded `SmallString` (the sequencing of the constituent bytes matters for validity,) and `UnsafeRawPointer` (it is marked with `@unsafe`.) `UnsafeRawPointer` is also an example of a type where semantic validity is unknown until runtime, since the runtime environment determines the actual range of valid values.

In the initial release of `FullyInhabited`, the compiler will not validate conformances to it. Validation of `FullyInhabited`s non-semantic requirements will be implemented in a later version of Swift.

##### `RawSpan` and `MutableRawSpan`

`RawSpan` and `MutableRawSpan` will have a new, generic `load(as:)` function that return `FullyInhabited` values read from the underlying memory, with no pointer-alignment restriction. Because the returned values are `FullyInhabited` and the request is bounds-checked, this `load(as:)` function is safe.

```swift
extension RawSpan {
  func load<T: FullyInhabited>(
    fromByteOffset: Int = 0,
    as: T.Type = T.self
  ) -> T
}
```

Additionally, a special version of `load()` will have an additional argument to control the byte order of the value being loaded, for values of types conforming to both `FullyInhabited` and `FixedWidthInteger`:

```swift
extension RawSpan {
  func load<T: FullyInhabited & FixedWidthInteger>(
    fromByteOffset: Int = 0,
    as: T.Type = T.self,
    _ byteOrder: ByteOrder
  ) -> T
}

@frozen
public enum ByteOrder: Equatable, Hashable, Sendable {
  case bigEndian, littleEndian
  
  static var native: Self { get }
}
```

The list of standard library types to conform to `FullyInhabited & FixedWidthInteger` is `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64`, `Int64`, `UInt`, `Int`, `UInt128`, and `Int128`.

The `load()` functions are not atomic operations.

The `load(as:)` functions will not have equivalents with unchecked byte offset. If that functionality is needed, the `unsafeLoad(fromUncheckedByteOffset:as:)`function is already available.

##### `MutableRawSpan` and `OutputRawSpan`

`MutableRawSpan` will gain a `storeBytes()` function that accepts a byte order parameter:

```swift
extension MutableRawSpan {
  mutating func storeBytes<T: FullyInhabited & FixedWidthInteger>(
    of value: T,
    toByteOffset offset: Int = 0,
    as type: T.Type,
    _ byteOrder: ByteOrder
  )
}
```
`OutputRawSpan` will have a matching `append()` function:
```swift
extension OutputRawSpan {
  mutating func append<T: FullyInhabited & FixedWidthInteger>(
    _ value: T,
    as type: T.Type,
    _ byteOrder: ByteOrder
  )
}
```

These functions do not need a default value for their `byteOrder` parameter, as the existing `MutableSpan.storeBytes(of:toByteOffset:as:)` and `OutputRawSpan.append(_:as:)` functions use the native byte order.

##### Loading and storing in-memory types

The memory layout of many of the types eligible for `FullyInhabited` is not guaranteed to be stable across compiler and library versions. This is not an issue for the use case envisioned for these API, where data is sent among running processes, or stored for later use in the same process. For more elaborate needs such as serializing for network communications or file system storage, the API propesd here can only be considered as a building block.

##### `Span` and `MutableSpan`

`Span` will have a new initializer `init(viewing: RawSpan)` to allow viewing a range of untyped memory as a typed `Span`, when `Span.Element` `FullyInhabited`. These conversions will check for alignment and bounds.

```swift
extension Span where Element: FullyInhabited {
  @_lifetime(borrow bytes)
  init(viewing bytes: borrowing RawSpan)
}
}
```

The conversions from `RawSpan` to `Span` only support well-aligned views with the native byte order. The [swift-binary-parsing][swift-binary-parsing] package provides a more fully-featured `ParserSpan` type for use cases beyond reinterpreting memory in-place.

## Detailed design

##### `ByteOrder`

```swift
@frozen
public enum ByteOrder: Equatable, Hashable, Sendable {
  /// Bytes are ordered with the most significant bits
  /// starting at the lowest memory address
  case bigEndian
  
  /// Bytes are ordered with the least significant bits
  /// starting at the lowest memory address
  case littleEndian

  /// The native byte order of the runtime target.
  static var native: Self { get }
}
```
Question: Would we prefer `ByteOrder` to not be a top-level type?

##### `RawSpan`

```swift
extension RawSpan {
  /// Returns a value constructed from the raw memory at the specified offset.
  ///
  /// The range of bytes required to construct a value of type `T` starting at
  /// `offset` must be completely within the span.
  /// `offset` is not required to be aligned for `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from the beginning of this span, in bytes.
  ///     `offset` must be nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new value of type `T`, read from `offset`.
  func load<T: FullyInhabited>(
    fromByteOffset offset: Int = 0,
    as: T.Type = T.self
  ) -> T

  /// Returns a value constructed from the raw memory at the specified offset.
  ///
  /// The range of bytes required to construct a value of type `T` starting at
  /// `offset` must be completely within the span.
  /// `offset` is not required to be aligned for `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from the beginning of this span, in bytes.
  ///     `offset` must be nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes should be decoded.
  /// - Returns: A new value of type `T`, read from `offset`.
  func load<T: FullyInhabited & FixedWidthInteger>(
    fromByteOffset offset: Int = 0,
    as: T.Type = T.self,
    _ byteOrder: ByteOrder
  ) -> T
}
```
##### `MutableRawSpan`

```swift
extension MutableRawSpan {
  /// Stores a value's bytes to the specified offset into the span's memory.
  ///
  /// The range of bytes required to store a value of `T` starting at
  /// byte offset `offset` must be completely within the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - offset: The offset in bytes into the buffer pointer's memory to begin
  ///     writing bytes from the value. The default is zero.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes will be encoded to the span.
  mutating func storeBytes<T: FullyInhabited & FixedWidthInteger>(
    of value: T,
    toByteOffset offset: Int = 0,
    as type: T.Type,
    _ byteOrder: ByteOrder
  )

  /// Returns a value constructed from the raw memory at the specified offset.
  ///
  /// The range of bytes required to construct a value of type `T` starting at
  /// `offset` must be completely within the span.
  /// `offset` is not required to be aligned for `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from the beginning of this span, in bytes.
  ///     `offset` must be nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new value of type `T`, read from `offset`.
  func load<T: FullyInhabited>(
    fromByteOffset offset: Int = 0,
    as: T.Type = T.self
  ) -> T

  /// Returns a value constructed from the raw memory at the specified offset.
  ///
  /// The range of bytes required to construct a value of type `T` starting at
  /// `offset` must be completely within the span.
  /// `offset` is not required to be aligned for `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from the beginning of this span, in bytes.
  ///     `offset` must be nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes should be decoded.
  /// - Returns: A new value of type `T`, read from `offset`.
  func load<T: FullyInhabited & FixedWidthInteger>(
    fromByteOffset offset: Int = 0,
    as: T.Type = T.self,
    _ byteOrder: ByteOrder
  ) -> T
}
```

##### `OutputRawSpan`
```swift
extension OutputRawSpan {
  /// Appends a value's bytes to the span's memory.
  ///
  /// There must be at least `MemoryLayout<UInt16>.size` bytes available
  /// in the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes will be encoded to the span.
  mutating func append<T: FullyInhabited & FixedWidthInteger>(
    _ value: T,
    as type: T.Type,
    _ byteOrder: ByteOrder
  )
}
```

##### `Span`
```swift
extension Span {
  /// View initialized raw memory as a typed span.
  ///
  /// - Parameters:
  ///   - bytes: a buffer to initialized memory.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element: FullyInhabited
}
```
> **Note:** we are not proposing mutable versions of these initializers for `MutableSpan`.

##### `FullyInhabited` and conformances in the standard library

A `FullyInhabited` type has at least one stored property, and all its stored properties are values of  `FullyInhabited` types. Types that do not fully use a byte, such as `Bool`, are disallowed. Undefined behaviour can result when an invalid bit pattern is loaded into such values.

The memory representation of a `FullyInhabited` type must include no padding. For example, `struct A { var v: [3 of Int8]; var n: Int64 }` has two `FullyInhabited` stored properties, with five bytes of padding.<!-- `MemoryLayout<A>.stride - (MemoryLayout<[3 of Int8]>.stride + MemoryLayout<Int64>.stride)` equals 5 -->

If a `FullyInhabited` type's module is resilient, i.e. compiled with the option `-enable-library-evolution`, a `FullyInhabited` type must be declared as frozen (`@frozen`).

There must be no semantic constraints for any of a `FullyInhabited` type's stored properties.

```swift
protocol FullyInhabited: BitwiseCopyable {}
```

The following conformances will be implemented in the standard library, depending on the platform availability of the base types:

```swift
extension UInt8:   FullyInhabited {}
extension Int8:    FullyInhabited {}
extension UInt16:  FullyInhabited {}
extension Int16:   FullyInhabited {}
extension UInt32:  FullyInhabited {}
extension Int32:   FullyInhabited {}
extension UInt64:  FullyInhabited {}
extension Int64:   FullyInhabited {}
extension UInt128: FullyInhabited {}
extension Int128:  FullyInhabited {}
extension UInt:    FullyInhabited {}
extension Int:     FullyInhabited {}

extension Float16: FullyInhabited {}
extension Float32: FullyInhabited {} // `Float`
extension Float64: FullyInhabited {} // `Double`

extension Duration: FullyInhabited {}

extension InlineArray: FullyInhabited where Element: FullyInhabited {}
extension CollectionOfOne: FullyInhabited where Element: FullyInhabited {}
```
> Can we make SIMD types conform?

## Source compatibility

This proposal consists only of additions, and should therefore be source compatible.
Adding overloads is risky, and it is possible these additions might affect some existing valid code. Testing is required to rule out significant compatibility issues.

## ABI compatibility

The functions in this proposal will be implemented in such a way as to avoid creating additional ABI.

These functions require the existence of `Span`, and have a minimum deployment target on Darwin-based platforms, where the Swift standard library is distributed with the operating system.

## Implications on adoption

## Future directions

#### Validation for the `FullyInhabited` layout constraint

`FullyInhabited` conformances will undergo additional validation by the compiler at a later time. The only characteristic of a `FullyInhabited` type that cannot be validated by the compiler is the absence of semantic constraints on the values of its stored properties.

#### Tuples as `FullyInhabited`

Tuples composed of `FullyInhabited` types should themselves be `FullyInhabited`.

#### Layout constraint to model "no padding bytes"

The true constraint for safe variants of `storeBytes(of:)` is to have no padding bytes in the source type's memory representation. This layout constraint is weaker than `FullyInhabited`, and should be automated in a manner similar to `BitwiseCopyable`. We could consider introducing it when validation of `FullyInhabited` is implemented.

#### Utilities to examine the alignment of a `RawSpan`

The `Span` initializers require a correctly-aligned `RawSpan`; there should be be utilities to identify the offsets that are well-aligned for a given type.

## Alternatives considered

#### Encoding the name of the type being loaded into the function names

Having a series of concrete functions such as `loadInt32(fromByteOffset:_:)` and `storeBytes(int32:toByteOffset:as:_:)` would be easier on the type checker, by avoiding the problem of overloaded symbols.

#### Waiting for a compiler-validated `FullyInhabited` layout constraint

The need for the functionality in this proposal is urgent and can be achieved with standard library additions. Validation of the `FullyInhabited` layout constraint will require significant compiler work, and we believe that the API as proposed in this document will provide significant value on its own.

#### Making these additions generic over `FixedWidthInteger & BitwiseCopyable` and `BinaryFloatingPoint & BitwiseCopyable`

These are not sufficient constraints, since they do not mandate that their conformers must be fully inhabited.

#### Separating the `FullyInhabited` protocol into separate `ConvertibleToRawBytes` and `ConvertibleFromRawBytes` protocols.

As described, `FullyInhabited` is a stronger constraint than is needed to prevent uninitialized bytes when initializing memory. The minimal constraint would simply be the absence of padding; this could be called `ConvertibleToRawBytes`. Similarly, `FullyInhabited` is a stronger constraint than is needed to exclude unsafety when loading bytes from a `RawSpan` instance. The minimal constraint would be similar to `FullyInhabited`, but would allow for padding bytes; this could be called `ConvertibleFromRawBytes`. Types that conform to both would meet the requirements of `FullyInhabited` as described here.

```swift
typealias FullyInhabited = ConvertibleToRawBytes & ConvertibleFromRawBytes
```

Separating `FullyInhabited` in this manner would make the system more flexible, at the cost of some simplicity. It would allow us to define a safe bitcast operation:

```swift
func bitCast<A,B>(_ original: consuming A, to: B.self) -> B
  where A: ConvertibleToRawBytes, B: ConvertibleFromRawBytes
```

#### Omitting the `ByteOrder` parameters

The standard library's `FixedWidthInteger` protocol includes computed properties `var .bigEndian: Self` and `var .littleEndian: Self`. These could be used to modify the arguments of `storeBytes(_:as:)`, or to modify the return values from `load(as:)`. Unfortunately these properties are not clear, because they return `Self`, conflating byte ordering with otherwise valid values. This proposal applies the consideration of byte ordering to the operation where it belongs: serialization.

#### Defaulting to aligned operations for the safe `load()` functions

`UnsafeRawPointer`'s original `load()` function requires correct alignment, and the less restrictive  `loadUnaligned()` was added later. We have long considered this unfortunate, and this proposal seeks to improve on the status quo by making our new safe `load()` functions perform unaligned operations.

## Acknowledgments

Thanks to Karoy Lorentey and Nate Cook for taking the time to discuss this topic.
Enums to represent the byte order have previously been pitched by Michael Ilseman ([Unicode Processing APIs](https://forums.swift.org/t/69294)) and by [YOCKOW]([https://gist.github.com/YOCKOW) ([ByteOrder type](https://forums.swift.org/t/74027)).
