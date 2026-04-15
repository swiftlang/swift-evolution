# Safe loading API for `RawSpan`

* Proposal: [SE-0525](0525-rawspan-safe-loading-api.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Active Review (April 3...16, 2026)**
* Implementation: [swiftlang/swift#88304](https://github.com/swiftlang/swift/pull/88304)
* Related Proposals: [SE-0447](0447-span-access-shared-contiguous-storage.md)
* Review: ([pitch 1](https://forums.swift.org/t/83966)) ([pitch 2](https://forums.swift.org/t/84144)) ([review](https://forums.swift.org/t/se-0525-safe-loading-api-for-rawspan/85811))

[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[swift-binary-parsing]: https://github.com/apple/swift-binary-parsing

## Summary of changes

We introduce a set of safe API to load and store values of certain safe types from the memory represented by `RawSpan`, `MutableSpan` and `OutputRawSpan` instances. This will bolster the value of Swift in contexts where a process needs the ability to send data to other running processes via untyped buffers, as well as provide a set of building blocks for parsing utilities.

## Motivation

In [SE-0447][SE-0447], we introduced `RawSpan` along with some unsafe functions to load values of arbitrary types. While it is safe to load some types with those functions, for example the native integer types, the `unsafe` annotation introduces an element of doubt for users of the standard library. This proposal aims to provide clarity for safe uses of byte-loading operations. In order to define safe byte-loading operations, we also need to clarify what are safe byte-storing operations, and this proposal tackles those as well.

## Proposed solution

We propose two new protocols, supporting the conversion between initialized typed values and initialized raw bytes. The first will be conformed to by types that can always safely be read as raw bytes: `ConvertibleToBytes`. The second will be conformed to by types that can always be safely interpreted from raw bytes: `ConvertibleFromBytes`.

##### `ConvertibleToBytes`

When initializing memory to any value of a type conforming to `ConvertibleToBytes`, every byte underlying the type's [stride](https://developer.apple.com/documentation/swift/memorylayout/stride) must be initialized.

```swift
@_marker public protocol ConvertibleToBytes: Copyable {}
```

A type can conform to `ConvertibleToBytes` if its memory representation includes no padding. In other words, the sum of the size of its stored properties is equal to its stride. For example, an `Optional<Int16>` is stored in 3 bytes out of a stride of 4, and therefore `Optional<Int16>` cannot conform. A `struct Pair { var a, b: Int16 }` could conform to `ConvertibleToBytes`, as its size and stride are equal.

A type that conforms to `ConvertibleToBytes` must have:

- one or more stored properties,
- all of its stored properties have types conforming to `ConvertibleToBytes`,
- its stored properties are stored contiguously in memory, with no padding.
- none of its values disregards a subset of its bytes (this makes most enums ineligible.)

Many basic types in the standard library will conform to this protocol, but types outside the standard library will not initially be able to conform to `ConvertibleToBytes`.

A conformance to `ConvertibleToBytes` can only be declared by a type's containing module.

##### `ConvertibleFromBytes`

```swift
@_marker public protocol ConvertibleFromBytes: BitwiseCopyable {}
```

A type can conform to `ConvertibleFromBytes` if every bit pattern for every byte of its stored properties is valid. Note that this allows conformances for types with internal or trailing padding. A conformer to `ConvertibleFromBytes` must not have semantic constraints on the values of its stored properties. All its stored properties must themselves conform to `ConvertibleFromBytes`.

For example, a type representing two-dimensional Cartesian coordinates, such as `struct Point { var x, y: Int }` could conform to `ConvertibleFromBytes`. Its stored properties are `Int`, which is `ConvertibleFromBytes`. There are no semantic constraints between the `x` and `y` properties: any combination of `Int` values can represent a valid `Point`.

In contrast, `Range<Int>` could not conform to `ConvertibleFromBytes`, even though on the surface it has the same composition as `Point`. There is a semantic constraint between the two stored properties of `Range`: `lowerBound` must be less than or equal to `upperBound`. This makes it unable to conform to `ConvertibleFromBytes`.

Other examples of types that cannot conform to `ConvertibleFromBytes` are `UnicodeScalar` (some bit patterns are invalid,) a hypothetical UTF8-encoded `SmallString` (the sequencing of the constituent bytes matters for validity,) and `UnsafeRawPointer`. The case of pointers is illuminating: the semantic validity of a value is unknown until runtime, since the runtime environment determines the actual set of valid values.

The compiler cannot enforce the semantic requirements of `ConvertibleFromBytes`, therefore types outside the standard library can only conform with an unsafe conformance.

```swift
extension MyType: @unsafe ConvertibleFromBytes {}
```

A conformance to `ConvertibleFromBytes` can only be declared by a type's containing module.

##### `FullyInhabited`

```swift
typealias FullyInhabited = ConvertibleToBytes & ConvertibleFromBytes
```

`FullyInhabited` is the intersection of `ConvertibleToBytes` and `ConvertibleFromBytes`.

##### `RawSpan` and `MutableRawSpan`

`RawSpan` and `MutableRawSpan` will have a new, generic `load(as:)` function that return `ConvertibleFromBytes` values read from the underlying memory, with no pointer-alignment restriction. Because the returned values are `ConvertibleFromBytes` and the request is bounds-checked, this `load(as:)` function is safe.

```swift
extension RawSpan {
  func load<T: ConvertibleFromBytes>(
    fromByteOffset: Int = 0,
    as: T.Type = T.self
  ) -> T
}
```

Additionally, a special version of `load(as:)` will have an additional argument to control the byte order of the value being loaded, for values of types conforming to both `ConvertibleFromBytes` and `FixedWidthInteger`:

```swift
extension RawSpan {
  func load<T: ConvertibleFromBytes & FixedWidthInteger>(
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

The list of standard library types to conform to `ConvertibleFromBytes & FixedWidthInteger` is `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64`, `Int64`, `UInt`, `Int`, `UInt128`, and `Int128`.

The `load(as:)` functions are not atomic operations.

The `load(as:)` functions will not have equivalents with unchecked byte offset. If that functionality is needed, the `unsafeLoad(fromUncheckedByteOffset:as:)`function is already available.

##### Subscripts for the `RawSpan` family

As a convenience for the specific case of `UInt8`, we will define subscripts for `RawSpan`, `MutableRawSpan`, and `OutputRawSpan`, similar to the existing `Span`, `MutableSpan` and `OutputSpan` subscripts:
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

extension OutputRawSpan {
  subscript(_ byteOffset: Int) -> UInt8 { get set }

  @unsafe
  subscript(unchecked byteOffset: Int) -> UInt8 { get set }
}
```

##### `MutableRawSpan` and `OutputRawSpan`

`MutableRawSpan` will gain new overloads of `storeBytes()`:

```swift
extension MutableRawSpan {
  mutating func storeBytes<T>(
    of value: T,
    toByteOffset offset: Int = 0,
    as type: T.Type,
    _ byteOrder: ByteOrder
  ) where T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
  
  @unsafe
  mutating func storeBytes<T>(
    repeating repeatedValue: T,
    count: Int,
    as type: T.Type
  ) where T: BitwiseCopyable

  mutating func storeBytes<T>(
    repeating repeatedValue: T,
    count: Int,
    as type: T.Type,
    _ byteOrder: ByteOrder
  ) where T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
}
```
The existing `storeBytes` function constrained to `T: BitwiseCopyable` will be marked `@unsafe`, as it is possible for compiler optimizations to result in uninitialized bytes. The addition of a repeating variant corrects an omission; it is also marked `@unsafe`.

`OutputRawSpan` will have matching `append()` functions:

```swift
extension OutputRawSpan {
  mutating func append<T>(
    _ value: T, as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable

  mutating func append<T>(
    _ value: T, as type: T.Type, _ byteOrder: ByteOrder
  ) where T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
  
  mutating func append<T>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable
  
  mutating func append<T>(
    repeating repeatedValue: T, count: Int, as type: T.Type, _ byteOrder: ByteOrder
  ) where T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
}
```
The existing `append` function constrained to just `T: BitwiseCopyable` will be marked `@unsafe`.

##### Loading and storing in-memory types

The memory layout of many of the types eligible for `ConvertibleFromBytes` and/or `ConvertibleToBytes` is not guaranteed to be stable across compiler and library versions. This is not an issue for the use case envisioned for these API, where data is sent among running processes, or stored for later use by the same process. For more elaborate needs such as serializing for network communications or file system storage, the API proposed here can only be considered as a building block.

##### `Span` and `MutableSpan`

`Span` will have a new initializer `init(viewing: RawSpan)` to allow viewing a range of untyped memory as a typed `Span`, when `Span.Element` conforms to `ConvertibleFromBytes`. These conversions will check for alignment and bounds. When the `RawSpan`'s pointer alignment is incorrect for `Element`, this initializer will trap. When the bounds are not a multiple of the stride, this initializer will trap.

```swift
extension Span where Element: ConvertibleFromBytes {
  @_lifetime(copy bytes)
  init(viewing bytes: RawSpan)
}
```

`MutableSpan` will have new initializers to mutate the memory of  a `MutableRawSpan` as a typed `MutableSpan`, when its `Element` conforms to `ConvertibleFromBytes`. These conversions will check for alignment and bounds. When the `MutableRawSpan`'s pointer alignment is incorrect for `Element`, this initializer will trap. When the bounds are not a multiple of the stride, this initializer will trap.

```swift
extension MutableSpan {
  @_lifetime(&mutableBytes)
  init(mutating mutableBytes: inout MutableRawSpan)
    where Element: ConvertibleToBytes & ConvertibleFromBytes

  @_lifetime(copy mutableBytes)
  init(_ mutableBytes: consuming MutableRawSpan)
    where Element: ConvertibleToBytes & ConvertibleFromBytes
}
```

The conversions from `RawSpan` to `Span` only support well-aligned views with the native byte order. The [swift-binary-parsing][swift-binary-parsing] package provides a more fully-featured `ParserSpan` type for use cases beyond reinterpreting memory in-place. We expect a future proposal to include functionality to help determine the memory alignment of a `RawSpan` instance.

The existing `bytes` and `mutableBytes` accessors will have safe overloads for when `Element` conforms to `ConvertibleToBytes`.

##### `OutputRawSpan` and `OutputSpan`

`OutputRawSpan` will provide a way to append to a portion of its uninitialized memory using a typed `OutputSpan`, for `Element` types which conform to `ConvertibleToBytes`.
```swift
extension OutputRawSpan {
  @_lifetime(copy self)
  mutating func append<T, E: Error>(
    elements n: Int,
    as type: T.self,
    initializingWith initializer: (inout OutputSpan<T>) throws(E) -> Void
  ) throws(E) where T: ConvertibleToBytes & BitwiseCopyable
}
```
`append(byteCount:as:initializingWith)` will perform bounds-checking and alignment-checking before executing the closure, trapping at runtime if the alignment is incorrect or if available space is insufficient.

Similarly, `OutputSpan` will provide a way to initialize a portion of its uninitialized storage using an `OutputRawSpan`, when its `Element` type conforms to `ConvertibleFromBytes`.
```swift
extension OutputSpan where Element: ConvertibleFromBytes {
  @_lifetime(copy self)
  mutating func append<E: Error>(
    elements n: Int,
    initializingWith initializer: (inout OutputRawSpan) throws(E) -> Void
  ) throws(E)
}
```
`append(elements:initializingWith:)` will perform bounds-checking before executing the closure and, after it returns, will ensure that the number of bytes initialized is correct for the type of `Element`.

## Detailed design

##### `ConvertibleToBytes`

A `ConvertibleToBytes` type has at least one stored property, and all its stored properties are values of  `ConvertibleToBytes` types. 

The memory representation of a `ConvertibleToBytes` type must include no padding. For example, `struct A { var v: [3 of Int8]; var n: Int64 }` has two stored properties, both `ConvertibleToBytes`, but it has five bytes of padding. <!-- `MemoryLayout<A>.stride - (MemoryLayout<[3 of Int8]>.stride + MemoryLayout<Int64>.stride)` equals 5 -->

```swift
@_marker protocol ConvertibleToBytes: Copyable {}
```

Custom types will not be allowed to declare a conformance to `ConvertibleToBytes` at this time.

##### `ConvertibleFromBytes`

A `ConvertibleFromBytes` type has a valid value for every bit pattern of every byte of its stored properties. This precludes any semantic constraints, whether static or dynamic, on the values of a type conforming to `ConvertibleFromBytes`.

```swift
@_marker protocol ConvertibleFromBytes: BitwiseCopyable {}
```

Custom types will be allowed to declare an unsafe conformance to `ConvertibleFromBytes`.

Types that do not fully use a byte, such as `Bool`, are disallowed. Undefined behaviour can result when an invalid bit pattern is interpreted as such a value.

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
  func load<T: ConvertibleFromBytes>(
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
  func load<T: ConvertibleFromBytes & FixedWidthInteger>(
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
  @unsafe
  subscript(unchecked byteOffset: Int) -> UInt8 { get }
  
  /// View a typed span as a raw span.
  @_lifetime(copy elements)
  init<T: ConvertibleToBytes>(elements: consuming Span<T>)
  
  /// Unsafely view a typed span as a raw span.
  @unsafe
  @_lifetime(copy unsafeElements)
  init<T>(unsafeElements: consuming Span<T>)  
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
  ///   - type: The type of the instance to store.
  ///   - byteOrder: The order in which the bytes will be encoded to the span.
  mutating func storeBytes<T>(
    of value: T,
    toByteOffset offset: Int = 0,
    as type: T.Type,
    _ byteOrder: ByteOrder
  ) where T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger

  /// Stores a value's bytes repeatedly into this span's memory.
  ///
  /// There must be at least `count * MemoryLayout<T>.stride` bytes
  /// available in the span.
  ///
  /// - Parameters:
  ///   - repeatedValue: The value to store as raw bytes.
  ///   - count: The number of copies of `value` to append to this span.
  ///   - type: The type of the instance to store.
  @unsafe
  mutating func storeBytes<T>(
    repeating repeatedValue: T,
    count: Int,
    as type: T.Type
  ) where T: BitwiseCopyable

  /// Stores a value's bytes repeatedly into this span's memory.
  ///
  /// There must be at least `count * MemoryLayout<T>.stride` bytes
  /// available in the span.
  ///
  /// - Parameters:
  ///   - repeatedValue: The value to store as raw bytes.
  ///   - count: The number of copies of `value` to append to this span.
  ///   - type: The type of the instance to store.
  ///   - byteOrder: The order in which the bytes will be encoded to the span.
  mutating func storeBytes<T>(
    repeating repeatedValue: T,
    count: Int,
    as type: T.Type,
    _ byteOrder: ByteOrder
  ) where T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger

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
  func load<T: ConvertibleFromBytes>(
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
  func load<T: ConvertibleFromBytes & FixedWidthInteger>(
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
  @unsafe
  subscript(unchecked byteOffset: Int) -> UInt8 { get set }
  
  /// Mutate the elements of a typed span as bytes.
  @_lifetime(&mutableSpan)
  init<T>(mutating mutableSpan: inout MutableSpan<T>)
    where T: ConvertibleToBytes & ConvertibleFromBytes

  /// Convert a typed span to a raw span.
  @_lifetime(copy elements)
  init<T>(elements: consuming MutableSpan<T>)
    where T: ConvertibleToBytes & ConvertibleFromBytes
  
  /// Unsafely convert a typed span to a raw span.
  @unsafe
  @_lifetime(copy unsafeElements)
  init<T>(unsafeElements: consuming MutableSpan<T>)
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
  mutating func append<T>(
    _ value: T,
    as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable

  /// Appends a value's bytes to the span's memory.
  ///
  /// There must be at least `MemoryLayout<T>.size` bytes available
  /// in the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes will be encoded to the span.
  mutating func append<T>(
    _ value: T,
    as type: T.Type,
    _ byteOrder: ByteOrder
  ) where T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
  
  /// Appends the given value's bytes repeatedly to this span's bytes.
  ///
  /// There must be at least `count * MemoryLayout<T>.stride` bytes
  /// available in the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - count: The number of copies of `value` to append to this span.
  ///   - type: The type of the instance to create.
  mutating func append<T>(
    repeating repeatedValue: T,
    count: Int,
    as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable

  /// Appends the given value's bytes repeatedly to this span's bytes.
  ///
  /// There must be at least `count * MemoryLayout<T>.stride` bytes
  /// available in the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - count: The number of copies of `value` to append to this span.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes will be encoded to the span.
  mutating func append<T>(
    repeating repeatedValue: T,
    count: Int,
    as type: T.Type,
    _ byteOrder: ByteOrder
  ) where T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
  
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
  mutating func append<T, E: Error>(
    elements n: Int,
    as type: T.self,
    initializingWith initializer:
      (_ typedSpan: inout OutputSpan<T>) throws(E) -> Void
  ) throws(E) where T: ConvertibleToBytes & BitwiseCopyable

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
  @unsafe
  subscript(unchecked byteOffset: Int) -> UInt8 { get set }
}
```

##### `OutputSpan`

```swift
extension OutputSpan where Element: ConvertibleFromBytes {
  /// Append to the span as raw bytes.
  ///
  /// Inside the closure, initialize elements by appending to `rawSpan`.
  /// If the available memory in `self` is less than `n`, this
  /// function will trap before calling the closure.
  /// After the closure returns, the number of bytes initialized
  /// determines the number of `Element` instances added to `self`.
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
  ) throws(E) where Element: ConvertibleFromBytes
}
```

##### `Span`

```swift
extension Span where Element: ConvertibleFromBytes {
  /// View initialized raw memory as a typed span.
  ///
  /// The `byteCount` of `bytes` must be a multiple of `Element`'s stride,
  /// and the starting address of `bytes` must be well-aligned for the type
  /// of `Element`. If either of these requirements is not met, this initializer
  /// will trap at runtime.
  @_lifetime(copy bytes)
  public init(viewing bytes: consuming RawSpan)
}

extension Span where Element: ConvertibleToBytes {
  /// Construct a raw span over the memory represented by this span.
  ///
  /// - Returns: a RawSpan over the memory represented by this span
  @_lifetime(copy self)
  var bytes: RawSpan { get }
}
```
##### `MutableSpan`

```swift
extension MutableSpan {
  /// Mutate the elements of this span as raw bytes.
  ///
  /// The `byteCount` of `mutableBytes` must be a multiple of `Element`'s stride,
  /// and the starting address of `mutableBytes` must be well-aligned for
  /// the type of `Element`. If either of these requirements is not met,
  /// this initializer will trap at runtime.
  @_lifetime(&mutableBytes)
  init(mutating mutableBytes: inout MutableRawSpan)
    where Element: ConvertibleToBytes & ConvertibleFromBytes

  /// Convert a raw span to a typed span.
  ///
  /// The `byteCount` of `mutableBytes` must be a multiple of `Element`'s stride,
  /// and the starting address of `mutableBytes` must be well-aligned for
  /// the type of `Element`. If either of these requirements is not met,
  /// this initializer will trap at runtime.
  @_lifetime(copy bytes)
  init(bytes: consuming MutableRawSpan)
    where Element: ConvertibleToBytes & ConvertibleFromBytes
}

extension MutableSpan where Element: ConvertibleToBytes & ConvertibleFromBytes {
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
extension UInt8:   ConvertibleToBytes, ConvertibleFromBytes {}
extension Int8:    ConvertibleToBytes, ConvertibleFromBytes {}
extension UInt16:  ConvertibleToBytes, ConvertibleFromBytes {}
extension Int16:   ConvertibleToBytes, ConvertibleFromBytes {}
extension UInt32:  ConvertibleToBytes, ConvertibleFromBytes {}
extension Int32:   ConvertibleToBytes, ConvertibleFromBytes {}
extension UInt64:  ConvertibleToBytes, ConvertibleFromBytes {}
extension Int64:   ConvertibleToBytes, ConvertibleFromBytes {}
extension UInt:    ConvertibleToBytes, ConvertibleFromBytes {}
extension Int:     ConvertibleToBytes, ConvertibleFromBytes {}

extension UInt128: ConvertibleToBytes, ConvertibleFromBytes {}
extension Int128:  ConvertibleToBytes, ConvertibleFromBytes {}

extension Float16: ConvertibleToBytes, ConvertibleFromBytes {}
extension Float32: ConvertibleToBytes, ConvertibleFromBytes {} // `Float`
extension Float64: ConvertibleToBytes, ConvertibleFromBytes {} // `Double`

extension Duration: ConvertibleToBytes, ConvertibleFromBytes {}

extension InlineArray: ConvertibleToBytes where Element: ConvertibleToBytes {}
extension InlineArray: ConvertibleFromBytes where Element: ConvertibleFromBytes {}

extension CollectionOfOne: ConvertibleToBytes where Element: ConvertibleToBytes {}
extension CollectionOfOne: ConvertibleFromBytes where Element: ConvertibleFromBytes {}

extension ClosedRange: ConvertibleToBytes where Bound: ConvertibleToBytes {}
extension Range: ConvertibleToBytes where Bound: ConvertibleToBytes {}

extension PartialRangeFrom: ConvertibleToBytes where Bound: ConvertibleToBytes {}
extension PartialRangeFrom.Iterator: ConvertibleToBytes
  where Bound: ConvertibleToBytes {}
extension PartialRangeThrough: ConvertibleToBytes where Bound: ConvertibleToBytes {}
extension PartialRangeUpTo: ConvertibleToBytes where Bound: ConvertibleToBytes {}

extension Bool: ConvertibleToBytes {}
extension ObjectIdentifier: ConvertibleToBytes {}

extension UnsafePointer: ConvertibleToBytes {}
extension UnsafeMutablePointer: ConvertibleToBytes {}
extension UnsafeRawPointer: ConvertibleToBytes {}
extension UnsafeMutableRawPointer: ConvertibleToBytes {}
extension OpaquePointer: ConvertibleToBytes {}

extension UnsafeBufferPointer: ConvertibleToBytes {}
extension UnsafeMutableBufferPointer: ConvertibleToBytes {}
extension UnsafeRawBufferPointer: ConvertibleToBytes {}
extension UnsafeMutableRawBufferPointer: ConvertibleToBytes {}
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
func bitCast<T, U>(_ original: T, to: U.Type) -> U
  where T: ConvertibleToBytes, U: ConvertibleFromBytes
```



## Source compatibility

This proposal consists only of additions, and should therefore be source compatible.
Adding overloads is risky, and it is possible these additions might affect some existing valid code. Testing is required to rule out significant compatibility issues.

## ABI compatibility

The functions in this proposal will be implemented in such a way as to avoid creating additional ABI.

These functions require the existence of `Span`, and have a minimum deployment target on Darwin-based platforms, where the Swift standard library is distributed with the operating system.

## Implications on adoption

## Future directions

#### Validation for the `ConvertibleToBytes` protocol

`ConvertibleToBytes` conformances will undergo additional validation by the compiler at a later time. This protocol can be fully validated at compilation time, since it relies entirely on the layout of the type in addressable memory. It should be possible to automate `ConvertibleToBytes` conformances in a manner similar to `BitwiseCopyable`.

Alongside validation, we could consider automatically inserting stored null bytes instead of padding for types which elect it.

#### Partial validation for the `ConvertibleFromBytes` protocol

`ConvertibleFromBytes` conformances may undergo some validation by the compiler at a later time. The compiler can enforce that all of a type's stored properties conform to `ConvertibleFromBytes`. It cannot directly enforce the absence of semantic constraints on the type's fields, but we may choose to accept a roundabout way of supporting its absence, such as if all the stored properties are `public` and mutable (`var` bindings).

#### Support for types imported from C

The Clang importer could be taught which basic C types support these protocols. It would be useful to have a way to declare a conformance to these protocols for C types which are aggregates. For example, we could relax the restriction that these conformances can only be declared in a type's owning module, for imported C types only.

#### Support for tuples and SIMD types

Tuples composed of `ConvertibleToBytes` types should themselves be `ConvertibleToBytes`. The same applies to `ConvertibleFromBytes`. The standard library's SIMD types also seem to be naturally suited to these protocols.

#### Utilities to examine the alignment of a `RawSpan`

The `Span` initializers require a correctly-aligned `RawSpan`; there should be utilities to identify the offsets that are well-aligned for a given type.

#### Renaming of `@unsafe` functions and properties that do not explicitly include an unsafety marker

Some functions and properties introduced in earlier proposals have since been annotated as unsafe, but their names did not indicate unsafety. We should identify names that involve unsafety even when strict memory safety mode is disabled. We should plan carefully for the renaming of these symbols, and doing so in a separate proposal will be most conducive to a successful and minimally disruptive outcome.

## Alternatives considered

#### Encoding the name of the type being loaded into the function names

Having a series of concrete functions such as `loadInt32(fromByteOffset:_:)` and `storeBytes(int32:toByteOffset:as:_:)` would be easier on the type checker, by avoiding the problem of overloaded symbols.

#### Waiting for a compiler-validated `ConvertibleToBytes` layout constraint

The need for the functionality in this proposal is urgent and can be achieved with standard library additions. Validation of the `ConvertibleToBytes` layout constraint will require significant compiler work, and we believe that the API as proposed in this document will provide significant value on its own.

#### Making these additions generic over `FixedWidthInteger & BitwiseCopyable` and `BinaryFloatingPoint & BitwiseCopyable`

These are not sufficient constraints, since none of these three protocols mandate that their conformers must be fully inhabited.

#### Adding only a `FullyInhabited` protocol instead of the separate `ConvertibleToBytes` and `ConvertibleFromBytes` protocols.

The second pitch for this proposal proposed only `FullyInhabited`. The discussions showed that the pair of protocols would eventually be needed, and that the implementation burden would be similar. Implementing the pair of protocols seems to be the better option.

#### Omitting the `ByteOrder` parameters

The standard library's `FixedWidthInteger` protocol includes computed properties `var .bigEndian: Self` and `var .littleEndian: Self`. These could be used to modify the arguments of `storeBytes(_:as:)`, or to modify the return values from `load(as:)`. Unfortunately these properties are not clear, because they return `Self`, conflating byte ordering with otherwise valid values. This proposal applies the consideration of byte ordering to the operation where it belongs: serialization.

#### Defaulting to aligned operations for the safe `load()` functions

`UnsafeRawPointer`'s original `load()` function requires correct alignment, and the less restrictive  `loadUnaligned()` was added later. We have long considered this unfortunate, and this proposal seeks to improve on the status quo by making our new safe `load()` functions perform unaligned operations.

## Acknowledgments

Thanks to Karoy Lorentey, Nate Cook, and Stephen Canon for taking the time to discuss this topic.

Enums to represent the byte order have previously been pitched by Michael Ilseman ([Unicode Processing APIs](https://forums.swift.org/t/69294)) and by [YOCKOW]([https://gist.github.com/YOCKOW) ([ByteOrder type](https://forums.swift.org/t/74027)).
