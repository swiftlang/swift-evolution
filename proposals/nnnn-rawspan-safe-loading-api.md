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

We propose the introduction of a set of safe API to load and store values of certain safe types from the memory represented by `RawSpan`, `MutableSpan` and `OutputRawSpan` instances. This will bolster the value of Swift in contexts where a process needs the ability to send data to other running processes via untyped buffers, as well as provide a set of building blocks for parsing utilities.

## Motivation

In [SE-0447][SE-0447], we introduced `RawSpan` along with some unsafe functions to load values of arbitrary types. While it is safe to load some types with those functions, for example the native integer types, the `unsafe` annotation introduces an element of doubt for users of the standard library. This proposal aims to provide clarity for safe uses of byte-loading operations. In order to define safe byte-loading operations, we also need to clarify what are safe byte-storing operations, and this proposal tackles those as well.

## Proposed solution

We propose two new protocols, supporting the conversion between initialized typed values and initialized raw bytes. The first will be conformed to by types that can always safely be read as raw bytes: `ConvertibleToRawBytes`. The second will be conformed to by types that can always be safely interpreted from raw bytes: `ConvertibleFromRawBytes`.

##### `ConvertibleToRawBytes`

When initializing memory to any value of a type conforming to `ConvertibleToRawBytes`, every byte underlying the type's [stride](https://developer.apple.com/documentation/swift/memorylayout/stride) must be initialized.

```swift
@_marker public protocol ConvertibleToRawBytes: Copyable {}
```

A type can conform to `ConvertibleToRawBytes` if its memory representation includes no padding. In other words, the sum of the size of its stored properties is equal to its stride. For example, an `Optional<Int16>` is stored in 3 bytes out of a stride of 4, and therefore `Optional<Int16>` cannot conform. A `struct Pair { var a, b: Int16 }` could conform to `ConvertibleToRawBytes`, as its size and stride are equal.

A type that conforms to `ConvertibleToRawBytes` must have:

- one or more stored properties,
- all of its stored properties have types conforming to `ConvertibleToRawBytes`,
- its stored properties are stored contiguously in memory, with no padding.
- none of its values disregards a subset of its bytes (this makes most enums ineligible.)

Many basic types in the standard library will conform to this protocol, but types outside the standard library will not initially be able to conform to `ConvertibleToRawBytes`.

A conformance to `ConvertibleToRawBytes` can only be declared by a type's containing module.

##### `ConvertibleFromRawBytes`

```swift
@_marker public protocol ConvertibleFromRawBytes: BitwiseCopyable {}
```

A type can conform to `ConvertibleFromRawBytes` if every bit pattern for every byte of its stored properties is valid. Note that this allows conformances for types with internal or trailing padding. A conformer to `ConvertibleFromRawBytes` must not have semantic constraints on the values of its stored properties. All its stored properties must themselves conform to `ConvertibleFromRawBytes`.

For example, a type representing two-dimensional Cartesian coordinates, such as `struct Point { var x, y: Int }` could conform to `ConvertibleFromRawBytes`. Its stored properties are `Int`, which is `ConvertibleFromRawBytes`. There are no semantic constraints between the `x` and `y` properties: any combination of `Int` values can represent a valid `Point`.

In contrast, `Range<Int>` could not conform to `ConvertibleFromRawBytes`, even though on the surface it has the same composition as `Point`. There is a semantic constraint between two two stored properties of `Range`: `lowerBound` must be less than or equal to `upperBound`. This makes it unable to conform to `ConvertibleFromRawBytes`.

Other examples of types that cannot conform to `ConvertibleFromRawBytes` are `UnicodeScalar` (some bit patterns are invalid,) a hypothetical UTF8-encoded `SmallString` (the sequencing of the constituent bytes matters for validity,) and `UnsafeRawPointer`. The case of pointers is illuminating: the semantic validity of a value is unknown until runtime, since the runtime environment determines the actual set of valid values.

The compiler cannot enforce the semantic requirements of `ConvertibleFromRawBytes`, therefore types outside the standard library can only conform with an unsafe conformance.

```swift
extension MyType: @unsafe ConvertibleFromRawBytes {}
```

A conformance to `ConvertibleFromRawBytes` can only be declared by a type's containing module.

##### `FullyInhabited`

```swift
typealias FullyInhabited = ConvertibleToRawBytes & ConvertibleFromRawBytes
```

`FullyInhabited` is the intersection of `ConvertibleToRawBytes` and `ConvertibleFromRawBytes`.

##### `RawSpan` and `MutableRawSpan`

`RawSpan` and `MutableRawSpan` will have a new, generic `load(as:)` function that return `ConvertibleFromRawBytes` values read from the underlying memory, with no pointer-alignment restriction. Because the returned values are `ConvertibleFromRawBytes` and the request is bounds-checked, this `load(as:)` function is safe.

```swift
extension RawSpan {
  func load<T: ConvertibleFromRawBytes>(
    fromByteOffset: Int = 0,
    as: T.Type = T.self
  ) -> T
}
```

Additionally, a special version of `load(as:)` will have an additional argument to control the byte order of the value being loaded, for values of types conforming to both `ConvertibleFromRawBytes` and `FixedWidthInteger`:

```swift
extension RawSpan {
  func load<T: ConvertibleFromRawBytes & FixedWidthInteger>(
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

The list of standard library types to conform to `ConvertibleFromRawBytes & FixedWidthInteger` is `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64`, `Int64`, `UInt`, `Int`, `UInt128`, and `Int128`.

The `load(as:)` functions are not atomic operations.

The `load(as:)` functions will not have equivalents with unchecked byte offset. If that functionality is needed, the `unsafeLoad(fromUncheckedByteOffset:as:)`function is already available.

As a convenience for the specific case of `UInt8`, we will define subscripts for `RawSpan` and `MutableRawSpan`, similar to the existing `Span` and `MutableSpan` subscripts:
```swift
extension RawSpan {
  subscript(_ byteOffset: Int) -> UInt8 { get }
  
  @unsafe
  subscript(unchecked byteOffset: Int) -> UInt8 { get }
}

extension MutableRawSpan {
  subscript(_ byteOffset: Int) -> UInt8 { get set }

  @unsafe
  subscript(unchecked byteOffset: Int) -> UInt8 { get set }
}
```

##### `MutableRawSpan` and `OutputRawSpan`

`MutableRawSpan` will gain new overloads of `storeBytes()`:
```swift
extension MutableRawSpan {
  mutating func storeBytes<T: ConvertibleToRawBytes>(
    of value: T,
    toByteOffset offset: Int = 0,
    as type: T.Type
  )

  mutating func storeBytes<T: ConvertibleToRawBytes & FixedWidthInteger>(
    of value: T,
    toByteOffset offset: Int = 0,
    as type: T.Type,
    _ byteOrder: ByteOrder
  )
}
```
The existing `storeBytes` function constrained to `T: BitwiseCopyable` will be marked `@unsafe`.

`OutputRawSpan` will have matching `append()` functions:
```swift
extension OutputRawSpan {
  mutating func append<T: ConvertibleToRawBytes>(
    _ value: T, as type: T.Type
  )

mutating func append<T: ConvertibleToRawBytes & FixedWidthInteger>(
    _ value: T, as type: T.Type, _ byteOrder: ByteOrder
  )
}
```
The existing `append` function constrained to `T: BitwiseCopyable` will be marked `@unsafe`.

##### Loading and storing in-memory types

The memory layout of many of the types eligible for `ConvertibleFromRawBytes` and/or `ConvertibleToRawBytes` is not guaranteed to be stable across compiler and library versions. This is not an issue for the use case envisioned for these API, where data is sent among running processes, or stored for later use by the same process. For more elaborate needs such as serializing for network communications or file system storage, the API proposed here can only be considered as a building block.

##### `Span` and `MutableSpan`

`Span` will have a new initializer `init(viewing: RawSpan)` to allow viewing a range of untyped memory as a typed `Span`, when `Span.Element` conforms to `ConvertibleFromRawBytes`. These conversions will check for alignment and bounds.

```swift
extension Span where Element: ConvertibleFromRawBytes {
  @_lifetime(copy bytes)
  init(viewing bytes: RawSpan)
}
```

`MutableSpan` will have new initializers to mutate the memory of  a `MutableRawSpan` as a typed `MutableSpan`, when its `Element` conforms to both `ConvertibleFromRawBytes` and to `ConvertibleToRawBytes`. These conversions will check for alignment and bounds.
```swift
extension MutableSpan {
  @_lifetime(&mutableBytes)
  init(mutating mutableBytes: inout MutableRawSpan)
    where Element: ConvertibleFromRawBytes & ConvertibleToRawBytes

  @_lifetime(copy mutableBytes)
  init(_ mutableBytes: consuming MutableRawSpan)
    where Element: ConvertibleFromRawBytes
}
```

The conversions from `RawSpan` to `Span` only support well-aligned views with the native byte order. The [swift-binary-parsing][swift-binary-parsing] package provides a more fully-featured `ParserSpan` type for use cases beyond reinterpreting memory in-place.

The existing `bytes` and `mutableBytes` accessors will have safe overloads for when `Element` conforms to `ConvertibleToRawBytes`.

##### `OutputRawSpan` and `OutputSpan`

`OutputRawSpan` will provide a way to append to a portion of its uninitialized memory using a typed `OutputSpan`, for `Element` types which conform to `ConvertibleToRawBytes`.
```swift
extension OutputRawSpan {
  @_lifetime(copy self)
  mutating func append<T: ConvertibleToRawBytes, E: Error>(
    elements n: Int,
    as type: T.self,
    initializingWith initializer: (inout OutputSpan<T>) throws(E) -> Void
  ) throws(E)
}
```
`append(byteCount:as:initializingWith)` will perform bounds-checking and alignment-checking before executing the closure.

Similarly,, `OutputSpan` will provide a way to initialize a portion of its uninitialized storage using an `OutputRawSpan`, when its `Element` type conforms to `ConvertibleFromRawBytes`.
```swift
extension OutputSpan where Element: ConvertibleFromRawBytes {
  @_lifetime(copy self)
  mutating func append<E: Error>(
    elements n: Int,
    initializingWith initializer: (inout OutputRawSpan) throws(E) -> Void
  ) throws(E)
}
```
`append(elements:initializingWith:)` will perform bounds-checking before executing the closure and, after it returns, will ensure that the number of bytes initialized is correct for the the type of `Element`.

## Detailed design

##### `ConvertibleToRawBytes`

A `ConvertibleToRawBytes` type has at least one stored property, and all its stored properties are values of  `ConvertibleToRawBytes` types. 

The memory representation of a `ConvertibleToRawBytes` type must include no padding. For example, `struct A { var v: [3 of Int8]; var n: Int64 }` has two stored properties, both `ConvertibleToRawBytes`, but it has five bytes of padding. <!-- `MemoryLayout<A>.stride - (MemoryLayout<[3 of Int8]>.stride + MemoryLayout<Int64>.stride)` equals 5 -->

```swift
@_marker protocol ConvertibleToRawBytes: Copyable {}
```

Custom types will not be allowed to declare a conformance to `ConvertibleToRawBytes` at this time.

##### `ConvertibleFromRawBytes`

A `ConvertibleFromRawBytes` type has a valid value for every bit pattern of every byte of its stored properties. This precludes any semantic constraints, whether static or dynamic, on the values of a type conforming to `ConvertibleFromRawBytes`.

```swift
@_marker protocol ConvertibleFromRawBytes: BitwiseCopyable {}
```

Custom types will be allowed to declare an unsafe conformance to `ConvertibleFromRawBytes`.

Types that do not fully use a byte, such as `Bool`, are disallowed. Undefined behaviour can result when an invalid bit pattern is loaded as such a value.

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
  func load<T: ConvertibleFromRawBytes>(
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
  func load<T: ConvertibleFromRawBytes & FixedWidthInteger>(
    fromByteOffset offset: Int = 0,
    as: T.Type = T.self,
    _ byteOrder: ByteOrder
  ) -> T
  
  /// Accesses the byte at the specified offset in the span.
  ///
  /// - Parameter byteOffset: The offset of the byte to access. `byteOffset`
  ///     must be greater or equal to zero, and less than `byteCount`.
  subscript(_ byteOffset: Int) -> UInt8 { get }

  /// Accesses the byte at the specified offset in the span.
  ///
  /// This subscript does not validate `byteOffset`. Using this subscript
  /// with an invalid `byteOffset` results in undefined behaviour.
  ///
  /// - Parameter byteOffset: The offset of the byte to access. `byteOffset`
  ///     must be greater or equal to zero, and less than `count`.
  subscript(unchecked byteOffset: Int) -> UInt8 { get }
  
  /// Convert a typed span to a raw span.
  @_lifetime(copy span)
  init<T: ConvertibleToRawBytes>(_ span: consuming Span<T>)
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
  mutating func storeBytes<T>(
    of value: T,
    toByteOffset offset: Int = 0,
    as type: T.Type
  )

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
  mutating func storeBytes<T: ConvertibleToRawBytes & FixedWidthInteger>(
    of value: T,
    toByteOffset offset: Int = 0,
    as type: T.Type,
    _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes repeatedly into this span's memory.
  ///
  /// There must be at least `count * MemoryLayout<T>.stride` bytes
  /// available in the span.
  ///
  /// - Parameters:
  ///   - repeatedValue: The value to store as raw bytes.
  ///   - count: The number of copies of `value` to append to this span.
  ///   - type: The type of the instance to create.
  mutating func storeBytes<T>(
    repeating repeatedValue: T, count: Int, as type: T.Type
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
  func load<T: ConvertibleFromRawBytes>(
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
  func load<T: ConvertibleFromRawBytes & FixedWidthInteger>(
    fromByteOffset offset: Int = 0,
    as: T.Type = T.self,
    _ byteOrder: ByteOrder
  ) -> T

  /// Accesses the byte at the specified offset in the span.
  ///
  /// - Parameter byteOffset: The offset of the byte to access. `byteOffset`
  ///     must be greater or equal to zero, and less than `byteCount`.
  subscript(_ byteOffset: Int) -> UInt8 { get set }

  /// Accesses the byte at the specified offset in the span.
  ///
  /// This subscript does not validate `byteOffset`. Using this subscript
  /// with an invalid `byteOffset` results in undefined behaviour.
  ///
  /// - Parameter byteOffset: The offset of the byte to access. `byteOffset`
  ///     must be greater or equal to zero, and less than `count`.
  subscript(unchecked byteOffset: Int) -> UInt8 { get set }
  
  /// Mutate the elements of a typed span as raw bytes.
  @_lifetime(&mutableSpan)
  init<T>(mutating mutableSpan: inout MutableSpan<T>)
    where T: ConvertibleFromRawBytes & ConvertibleToRawBytes

  /// Convert a typed span to a raw span.
  @_lifetime(copy span)
  init<T: ConvertibleToRawBytes>(_ span: consuming MutableSpan<T>)
}
```

##### `OutputRawSpan`
```swift
extension OutputRawSpan {
  /// Appends a value's bytes to this span's bytes.
  ///
  /// There must be at least `MemoryLayout<T>.size` bytes available
  /// in the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - type: The type of the instance to create.
  mutating func append<T: ConvertibleToRawBytes>(
    _ value: T, as type: T.Type,
  )

  /// Appends a value's bytes to the span's memory.
  ///
  /// There must be at least `MemoryLayout<T>.size` bytes available
  /// in the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes will be encoded to the span.
  mutating func append<T: ConvertibleToRawBytes & FixedWidthInteger>(
    _ value: T, as type: T.Type, _ byteOrder: ByteOrder
  )
  
  /// Appends the given value's bytes repeatedly to this span's bytes.
  ///
  /// There must be at least `count * MemoryLayout<T>.stride` bytes
  /// available in the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - count: The number of copies of `value` to append to this span.
  ///   - type: The type of the instance to create.
  mutating func append<T: ConvertibleToRawBytes>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  )

  /// Append to the span as elements of a specific type.
  ///
  /// There must be at least `n * MemoryLayout<T>.stride` bytes
  /// available in the span.
  ///
  /// Inside the closure, initialize elements by appending to `typedSpan`.
  /// After the closure returns, the number of bytes initialized will be
  /// correctly updated.
  ///
  /// If the closure throws an error, the bytes for the elements appended
  /// until that point will remain initialized.
  ///
  /// - Parameters:
  ///   - n: The number of `T` elements to initialize
  ///   - type: The type of the instance to create.
  ///   - initializer: A closure that initializes new elements.
  ///     - Parameters:
  ///       - typedSpan: An `OutputSpan` over enough bytes to initialize
  ///         the specified number of additional elements.
  mutating func append<T: ConvertibleToRawBytes, E: Error>(
    elements n: Int,
    as type: T.self,
    initializingWith initializer:
      (_ typedSpan: inout OutputSpan<T>) throws(E) -> Void
  ) throws(E)
}
```

##### `OutputSpan`

```swift
extension OutputSpan where Element: ConvertibleFromRawBytes {
  /// Append to the span as raw bytes.
  ///
  /// Inside the closure, initialize elements by appending to `rawSpan`.
  /// After the closure returns, the number of bytes initialized
  /// must match a whole number of `Element` instances.
  ///
  /// If the closure throws an error, the elements appended
  /// until that point will remain initialized.
  ///
  /// - Parameters:
  ///   - n: The number of `T` elements to initialize
  ///   - initializer: A closure that initializes new elements.
  ///     - Parameters:
  ///       - rawSpan: An `OutputRawSpan` with enough bytes to initialize
  ///         the specified number of additional elements.
  mutating func append<E: Error>(
    elements n: Int,
    initializingWith initializer:
      (_ rawSpan: inout OutputRawSpan) throws(E) -> Void
  ) throws(E) where Element: ConvertibleFromRawBytes
}
```

##### `Span`

```swift
extension Span where Element: ConvertibleFromRawBytes {
  /// View initialized raw memory as a typed span.
  @_lifetime(copy bytes)
  public init(viewing bytes: consuming RawSpan)
}

extension Span where Element: ConvertibleToRawBytes {
  /// Construct a raw span over the memory represented by this span.
  ///
  /// - Returns: a RawSpan over the memory represented by this span
  var bytes: RawSpan { get }
}
```
##### `MutableSpan`

```swift
extension MutableSpan {
  /// Mutate the elements of this span as raw bytes.
  @_lifetime(&mutableBytes)
  init(mutating mutableBytes: inout MutableRawSpan)
    where Element: ConvertibleFromRawBytes & ConvertibleToRawBytes

  /// Convert a raw span to a typed span.
  @_lifetime(copy mutableBytes)
  init(_ mutableBytes: consuming MutableRawSpan)
    where Element: ConvertibleFromRawBytes
}

extension MutableSpan where Element: ConvertibleToRawBytes & ConvertibleFromRawBytes {
  /// Construct a mutable raw span over the memory represented by this span.
  ///
  /// - Returns: a MutableRawSpan over the memory represented by this span
  @_lifetime(&self)
  var mutableBytes: MutableRawSpan { mutating get }
}
```



##### Conformances in the standard library

The following conformances will be implemented in the standard library, depending on the platform availability of the base types:

```swift
extension UInt8:   ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension Int8:    ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension UInt16:  ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension Int16:   ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension UInt32:  ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension Int32:   ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension UInt64:  ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension Int64:   ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension UInt128: ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension Int128:  ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension UInt:    ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension Int:     ConvertibleToRawBytes, ConvertibleFromRawBytes {}

extension Float16: ConvertibleToRawBytes, ConvertibleFromRawBytes {}
extension Float32: ConvertibleToRawBytes, ConvertibleFromRawBytes {} // `Float`
extension Float64: ConvertibleToRawBytes, ConvertibleFromRawBytes {} // `Double`

extension Duration: ConvertibleToRawBytes, ConvertibleFromRawBytes {}

extension InlineArray: ConvertibleToRawBytes where Element: ConvertibleToRawBytes {}
extension InlineArray: ConvertibleFromRawBytes where Element: ConvertibleFromRawBytes {}

extension CollectionOfOne: ConvertibleToRawBytes where Element: ConvertibleToRawBytes {}
extension CollectionOfOne: ConvertibleFromRawBytes where Element: ConvertibleFromRawBytes {}

extension ClosedRange: ConvertibleToRawBytes where Bound: ConvertibleToRawBytes {}
extension Range: ConvertibleToRawBytes where Bound: ConvertibleToRawBytes {}
extension PartialRangeFrom: ConvertibleToRawBytes where Bound: ConvertibleToRawBytes {}
extension PartialRangeFrom.Iterator: ConvertibleToRawBytes
  where Bound: ConvertibleToRawBytes {}
extension PartialRangeThrough: ConvertibleToRawBytes where Bound: ConvertibleToRawBytes {}
extension PartialRangeUpTo: ConvertibleToRawBytes where Bound: ConvertibleToRawBytes {}

extension Bool: ConvertibleToRawBytes {}
extension ObjectIdentifier: ConvertibleToRawBytes {}
extension AnyObject: ConvertibleToRawBytes {}

extension UnsafePointer: ConvertibleToRawBytes {}
extension UnsafeMutablePointer: ConvertibleToRawBytes {}
extension UnsafeRawPointer: ConvertibleToRawBytes {}
extension UnsafeMutableRawPointer: ConvertibleToRawBytes {}
extension OpaquePointer: ConvertibleToRawBytes {}

extension UnsafeBufferPointer: ConvertibleToRawBytes {}
extension UnsafeMutableBufferPointer: ConvertibleToRawBytes {}
extension UnsafeRawBufferPointer: ConvertibleToRawBytes {}
extension UnsafeMutableRawBufferPointer: ConvertibleToRawBytes {}
```

> **Note:** any of the types in the list above which is missing a prerequisite `BitwiseCopyable` conformance will gain one. 

##### Top-level safe `bitCast` function

With the two protocols we have defined, we gain the ability to define a safe function to reinterpret types:

```swift
/// Returns the bits of the given instance, interpreted as having the specified
/// type.
///
/// Parameters:
///   - x: The instance to cast to `type`.
///   - type: The type to cast `x` to. `type` and the type of `x` must have the
///     same size of memory representation and compatible memory layout.
/// Returns: A new instance of type `U`, cast from `x`.
func bitCast<T, U>(_ original: T, to: U.self) -> U
  where T: ConvertibleToRawBytes, U: ConvertibleFromRawBytes
```



## Source compatibility

This proposal consists only of additions, and should therefore be source compatible.
Adding overloads is risky, and it is possible these additions might affect some existing valid code. Testing is required to rule out significant compatibility issues.

## ABI compatibility

The functions in this proposal will be implemented in such a way as to avoid creating additional ABI.

These functions require the existence of `Span`, and have a minimum deployment target on Darwin-based platforms, where the Swift standard library is distributed with the operating system.

## Implications on adoption

## Future directions

#### Validation for the `ConvertibleToRawBytes` protocol

`ConvertibleToRawBytes` conformances will undergo additional validation by the compiler at a later time. This protocol can be fully validated at compilation time, since it relies entirely on the layout of the type in addressable memory. It should be automatable in a manner similar to `BitwiseCopyable`.

Alongside validation, we could consider automatically inserting stored null bytes instead of padding for types which elect it.

#### Partial validation for the `ConvertibleFromRawBytes`protocol

`ConvertibleFromRawBytes` conformances may undergo some validation by the compiler at a later time. The compiler can enforce that all of a type's stored properties conform to `ConvertibleFromRawBytes`. It cannot directly enforce the absence of semantic constraints on the type's fields, but we may choose to accept a roundabout way of supporting its absence, such as if all the stored properties are `public` and mutable (`var` bindings).

#### Support for types imported from C

The Clang importer should be taught which basic C types support these protocols. There should be a way to declare a conformance to the protocols for C types which are aggregates. For example, we could relax the restriction that these conformances can only be declared in a type's owning module, for imported C types only.

#### Support for tuples and SIMD types

Tuples composed of `ConvertibleToRawBytes` types should themselves be `ConvertibleToRawBytes`. The same applies to `ConvertibleFromRawBytes`. The standard library's SIMD types also seem to be naturally suited to these protocols.

#### Utilities to examine the alignment of a `RawSpan`

The `Span` initializers require a correctly-aligned `RawSpan`; there should be be utilities to identify the offsets that are well-aligned for a given type.

## Alternatives considered

#### Encoding the name of the type being loaded into the function names

Having a series of concrete functions such as `loadInt32(fromByteOffset:_:)` and `storeBytes(int32:toByteOffset:as:_:)` would be easier on the type checker, by avoiding the problem of overloaded symbols.

#### Waiting for a compiler-validated `ConvertibleToRawBytes` layout constraint

The need for the functionality in this proposal is urgent and can be achieved with standard library additions. Validation of the `ConvertibleToRawBytes` layout constraint will require significant compiler work, and we believe that the API as proposed in this document will provide significant value on its own.

#### Making these additions generic over `FixedWidthInteger & BitwiseCopyable` and `BinaryFloatingPoint & BitwiseCopyable`

These are not sufficient constraints, since none of these three protocols mandate that their conformers must be fully inhabited.

#### Adding only a `FullyInhabited` protocol instead of the separate `ConvertibleToRawBytes` and `ConvertibleFromRawBytes` protocols.

The second pitch for this proposal proposed only `FullyInhabited`. The discussions showed that the pair of protocols would eventually be needed, and that the implementation burden would be similar. Implementing the pair of protocols seems to be the better option.

#### Omitting the `ByteOrder` parameters

The standard library's `FixedWidthInteger` protocol includes computed properties `var .bigEndian: Self` and `var .littleEndian: Self`. These could be used to modify the arguments of `storeBytes(_:as:)`, or to modify the return values from `load(as:)`. Unfortunately these properties are not clear, because they return `Self`, conflating byte ordering with otherwise valid values. This proposal applies the consideration of byte ordering to the operation where it belongs: serialization.

#### Defaulting to aligned operations for the safe `load()` functions

`UnsafeRawPointer`'s original `load()` function requires correct alignment, and the less restrictive  `loadUnaligned()` was added later. We have long considered this unfortunate, and this proposal seeks to improve on the status quo by making our new safe `load()` functions perform unaligned operations.

## Acknowledgments

Thanks to Karoy Lorentey, Nate Cook, and Stephen Canon for taking the time to discuss this topic.

Enums to represent the byte order have previously been pitched by Michael Ilseman ([Unicode Processing APIs](https://forums.swift.org/t/69294)) and by [YOCKOW]([https://gist.github.com/YOCKOW) ([ByteOrder type](https://forums.swift.org/t/74027)).
