# Safe loading API for `RawSpan`

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Previous Proposal: follows [SE-0447][SE-0447]
* Previous Revision: *none*
* Review: ([pitch](https://forums.swift.org/...))

[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[swift-binary-parsing]: https://github.com/apple/swift-binary-parsing

## Introduction

We propose the introduction of a set of safe API to load values of numeric types from the memory represented by `RawSpan` instances, as well as safe conversions from `RawSpan` to `Span` for the same numeric types.

## Motivation

In [SE-0447][SE-0447], we introduced `RawSpan` along with some unsafe functions to load values of arbitrary types. While it is safe to load any of the native integer types with those functions, the `unsafe` annotation introduces an element of doubt for users of the standard library. Furthermore, since byte ordering is dependent on context, it is desirable to control the byte order of a loading operation. This proposal adds the ability to safely load integer values with ergonomic byte order control, without the doubt introduced by unsafe functions.

## Proposed solution

##### `RawSpan`

`RawSpan` will gain a series of concretely typed `load(as:)` functions to obtain numeric values from the underlying memory, with no alignment requirement. These `load(as:)` functions can be safe because they return values from fully-inhabited types, meaning that these types have a valid value for every bit pattern of their underlying bytes.

The `load(as:)` functions will be bounds-checked, being a safe `RawSpan` API. For example,

```swift
extension RawSpan {
  func load(fromByteOffset: Int = 0, as: UInt8.Type) -> UInt8

  func load(
    fromByteOffset: Int = 0, as: UInt16.Type, _ byteOrder: ByteOrder = .native
  ) -> UInt16
}

@frozen
public enum ByteOrder: Equatable, Hashable, Sendable {
  case bigEndian, littleEndian
  
  static var native: Self { get }
}
```

The loadable types will be `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64`, `Int64`, `UInt`, `Int`, `Float32` (aka `Float`) and `Float64` (aka `Double`). On platforms that support them, loading `Float16`, `Float80`, `UInt128`, and `Int128`  values will also be supported. These are not atomic operations.

The concrete `load(as:)` functions will not have equivalents with unchecked byte offset. If that functionality is needed, the generic `unsafeLoad(fromUncheckedByteOffset:as:)` is already available.

The `load(as:)` functions will also be available for `MutableRawSpan` and `OutputRawSpan`.

##### `MutableRawSpan` and `OutputRawSpan`

`MutableRawSpan` will gain a series of concretely typed `storeBytes()` functions that accept a byte order parameter, while `OutputRawSpan` will have matching `append()` functions:

```swift
extension MutableRawSpan {
  mutating func storeBytes(
    of value: UInt16,
    toByteOffset offset: Int = 0,
    as type: UInt16.Type,
    _ byteOrder: ByteOrder
  )
}

extension OutputRawSpan {
  mutating func append(
    _ value: UInt16,
    as type: UInt16.Type,
    _ byteOrder: ByteOrder
  )
}
```

These functions do not have a default value for their `byteOrder` parameter, as the existing generic `MutableSpan.storeBytes(of:toByteOffset:as:)` and `OutputRawSpan.append(_:as:)` functions use the native byte order, and address this need.

These concrete implementations will support `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64`, `Int64`, `UInt`, `Int`, `Float32` (aka `Float`) and `Float64` (aka `Double`). On platforms that support them, `Float16`, `Float80`, `UInt128`, and `Int128`  values will also be supported. These are not atomic operations.

The concrete `storeBytes(of:as:)` functions will not have an equivalent with unchecked byte offset. If that functionality is needed, the generic `storeBytes(of:toUncheckedByteOffset:as:)` is already available.

##### `Span`

`Span` will gain a series of concrete initializers `init(viewing: RawSpan)` to allow viewing a range of untyped memory as a typed `Span`, when `Span.Element` is a numeric type. These conversions will check for alignment and bounds. For example,

```swift
extension Span {
  @_lifetime(borrow span)
  init(viewing bytes: borrowing RawSpan) where Element == UInt32
}
```

The supported element types will be `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64`, `Int64`, `UInt`, `Int`, `Float32` (aka `Float`) and `Float64` (aka `Double`). On platforms that support them, initializing `Span` instances with `Float16`, `Float80`, `UInt128`, and `Int128` elements will also be implemented.

The conversions from `RawSpan` to `Span` only support well-aligned views with the native byte order. The [swift-binary-parsing][swift-binary-parsing] package provides a more fully-featured `ParserSpan` type.

## Detailed design

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

```swift
extension RawSpan {
  /// Returns a value constructed from the raw memory at the specified offset.
  ///
  /// - Parameters:
  ///   - offset: The offset from the beginning of this span, in bytes.
  ///     `offset` must be nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new value of type `UInt8`, read from `offset`.
  func load(fromByteOffset: Int = 0, as: UInt8.Type) -> UInt8

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Int8.Type) -> Int8

  /// Returns a value constructed from the raw memory at the specified offset.
  ///
  /// The range of bytes required to construct an `UInt16` starting at `offset`
  /// must be completely within the span. `offset` is not required to be aligned
  /// for `UInt16`.
  ///
  /// - Parameters:
  ///   - offset: The offset from the beginning of this span, in bytes.
  ///     `offset` must be nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes will be decoded from the
  ///       span, or the native byte order.
  /// - Returns: A new value of type `UInt16`, read from `offset`.
  func load(fromByteOffset: Int = 0, as: UInt16.Type, _ byteOrder: ByteOrder = .native) -> UInt16

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Int16.Type, _ byteOrder: ByteOrder = .native) -> Int16

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: UInt32.Type, _ byteOrder: ByteOrder = .native) -> UInt32

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Int32.Type, _ byteOrder: ByteOrder = .native) -> Int32

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: UInt64.Type, _ byteOrder: ByteOrder = .native) -> UInt64

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Int64.Type, _ byteOrder: ByteOrder = .native) -> Int64

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: UInt.Type, _ byteOrder: ByteOrder = .native) -> UInt

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Int.Type, _ byteOrder: ByteOrder = .native) -> Int


  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Float32.Type, _ byteOrder: ByteOrder = .native) -> Float32

  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Float64.Type, _ byteOrder: ByteOrder = .native) -> Float64

  // available on platforms that support `Float16`
  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Float16.Type, _ byteOrder: ByteOrder = .native) -> Float16

  // available on platforms that support `Float80`
  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Float80.Type, _ byteOrder: ByteOrder = .native) -> Float80

  // available on platforms that support `UInt128`
  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: UInt128.Type, _ byteOrder: ByteOrder = .native) -> UInt128

  // available on platforms that support `Int128`
  /// Returns a value constructed from the raw memory at the specified offset.
  func load(fromByteOffset: Int = 0, as: Int128.Type, _ byteOrder: ByteOrder = .native) -> Int128
}
```
> **Note:** the `load()` functions will also be available on `MutableRawSpan` and `OutputRawSpan`.

```swift
extension MutableRawSpan {
  /// Stores a value's bytes into the span's memory at the specified byte offset.
  ///
  /// The range of bytes required to store an `UInt16` starting at `offset`
  /// must be completely within the span.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - offset: The offset in bytes into the buffer pointer's memory to begin
  ///     writing bytes from the value. The default is zero.
  ///   - type: The type of the instance to create.
  ///   - byteOrder: The order in which the bytes will be encoded to the span.
  mutating func storeBytes(
    of value: UInt16, toByteOffset offset: Int = 0,
    as type: UInt16.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Int16, toByteOffset offset: Int = 0,
    as type: Int16.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: UInt32, toByteOffset offset: Int = 0,
    as type: UInt32.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Int32, toByteOffset offset: Int = 0,
    as type: Int32.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: UInt64, toByteOffset offset: Int = 0,
    as type: UInt64.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Int64, toByteOffset offset: Int = 0,
    as type: Int64.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: UInt, toByteOffset offset: Int = 0,
    as type: UInt.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Int, toByteOffset offset: Int = 0,
    as type: Int.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Float32, toByteOffset offset: Int = 0,
    as type: Float32.Type, _ byteOrder: ByteOrder
  )

  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Float64, toByteOffset offset: Int = 0,
    as type: Float64.Type, _ byteOrder: ByteOrder
  )

  // available on platforms that support `Float16`
  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Float16, toByteOffset offset: Int = 0,
    as type: Float16.Type, _ byteOrder: ByteOrder
  )

  // available on platforms that support `Float80`
  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Float80, toByteOffset offset: Int = 0,
    as type: Float80.Type, _ byteOrder: ByteOrder
  )

  // available on platforms that support `UInt128`
  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: UInt128, toByteOffset offset: Int = 0,
    as type: UInt128.Type, _ byteOrder: ByteOrder
  )

  // available on platforms that support `Int128`
  /// Stores a value's bytes into the span's memory at the specified byte offset.
  mutating func storeBytes(
    of value: Int128, toByteOffset offset: Int = 0,
    as type: Int128.Type, _ byteOrder: ByteOrder
  )
}
```
> **Note:** the new `storeBytes(of:as:_ byteOrder:)` functions do not need a defaulted `ByteOrder` parameter, since the existing `storeBytes(of:as:)` effectively fulfills that purpose.

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
  mutating func append(
    _ value: UInt16, as type: UInt16.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Int16, as type: Int16.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: UInt32, as type: UInt32.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Int32, as type: Int32.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: UInt64, as type: UInt64.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Int64, as type: Int64.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: UInt, as type: UInt.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Int, as type: Int.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Float32, as type: Float32.Type, _ byteOrder: ByteOrder
  )

  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Float64, as type: Float64.Type, _ byteOrder: ByteOrder
  )

  // available on platforms that support `Float16`
  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Float16, as type: Float16.Type, _ byteOrder: ByteOrder
  )

  // available on platforms that support `Float80`
  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Float80, as type: Float80.Type, _ byteOrder: ByteOrder
  )

  // available on platforms that support `UInt128`
  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: UInt128, as type: UInt128.Type, _ byteOrder: ByteOrder
  )

  // available on platforms that support `Int128`
  /// Appends a value's bytes to the span's memory.
  mutating func append(
    _ value: Int128, as type: Int128.Type, _ byteOrder: ByteOrder
  )
}
```
> **Note:** the new `append(_:as:_ byteOrder:)` functions do not need a defaulted `ByteOrder` parameter, since the existing `append(_:as:)` effectively fulfills that purpose.

```swift
extension Span {
  /// View initialized memory as a span of integers.
  ///
  /// - Parameters:
  ///   - bytes: a buffer to initialized memory.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == UInt8

  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Int8

  /// View initialized memory as a span of integers.
  ///
  /// `bytes` must be correctly aligned for accessing
  /// an element of type `UInt16`, and its length in bytes
  /// must be an exact multiple of `UInt16`'s stride.
  ///
  /// - Parameters:
  ///   - bytes: a buffer to initialized memory.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == UInt16

  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Int16

  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == UInt32

  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Int32

  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == UInt64

  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Int64

  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == UInt

  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Int

  /// View initialized memory as a span of floating-point values.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Float32

  /// View initialized memory as a span of floating-point values.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Float64

  // available on platforms that support `Float16`
  /// View initialized memory as a span of floating-point values.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Float16

  // available on platforms that support `Float80`
  /// View initialized memory as a span of floating-point values.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Float80

  // available on platforms that support `UInt128`
  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == UInt128

  // available on platforms that support `Int128`
  /// View initialized memory as a span of integers.
  @_lifetime(borrow bytes)
  public init(viewing bytes: borrowing RawSpan) where Element == Int128
}
```
> **Note:** we are not proposing mutable versions of these initializers for `MutableSpan`.

## Source compatibility

This proposal consists only of additions, and should therefore be source compatible.
Adding overloads is risky, and it is possible these additions might affect some existing valid code. Testing is required to rule out significant compatibility issues.

## ABI compatibility

The functions in this proposal will be implemented in such a way as to avoid creating additional ABI.

These functions require the existence of `Span`, so have a minimum deployment target on Darwin-based platforms where the Swift standard library is distributed with the operating system.

## Implications on adoption

## Future directions

#### <a name="constraint"></a>A "fully inhabited" layout constraint or marker protocol

This document proposes functions to load numeric values only. The salient property they share is that no possible bit pattern loaded into them is invalid. We could try to encode this property in a "fully inhabited" layout constraint, or in a more limited way in a marker protocol. We note that loading an aggregate that contains padding bytes is not inherently unsafe. However, attempting to load a value that has invalid bit patterns is inherently unsafe. Enums generally fall into the second category.

#### Loading homogeneous aggregates

Homogeneous aggregates of safely loadable types should also be loadable. For example, an `InlineArray` such as `[5 of Int16]` should be as safe to load as a single `Int16`. This consideration also includes single-value wrappers, such as swift-system's `FileDescriptor`, which wraps a single `Int32` value.

#### Utilities to examine the alignment of a `RawSpan`

The `Span` initializers require a correctly-aligned `RawSpan`; there should be a safe way to find out.

## Alternatives considered

#### Encoding the name of the type being loaded into the function names

Having a series of functions such as `loadInt32(fromByteOffset:_:)` and `storeBytes(int32:toByteOffset:as:_:)` would be easier on the type checker, by avoiding the problem of overloaded symbols.

#### Waiting for a "fully inhabited" layout constraint

The need for the functionality in this proposal is urgent and can be achieved with standard library additions. The fully-inhabited layout constraint would also require significant compiler work, and we believe that it is not worth waiting for it. It is also unclear whether the layout constraint might is a sound approach.

#### Making these additions generic over `FixedWidthInteger & BitwiseCopyable` and `BinaryFloatingPoint & BitwiseCopyable`

These are not sufficient constraints, since they do not mandate that their conformers must be fully inhabited. This approach would also require extremely defensive implementations to account for the existence of conformers from outside of the standard library. It would be possible to make the additions generic over a new protocol, which would have to be public. Two new issues arise from creating a new protocol: backdeployment and the possibility of unsafety due to future defective conformers from outside the standard library. A [layout constraint](#constraint) would achieve a similar outcome while being less risky.

#### Having sets of `load(as:)` functions with and without a `ByteOrder` parameter

We could have distinct `load(fromByteOffset:as:)` and `load(fromByteOffset:as:_:)` with no defaulted byte order argument. This achieves the same shape as the proposed defaulted `ByteOrder` parameter. It is possible the generated code might be better in one form than the other, and that will inform the final proposal.

#### Omitting the `ByteOrder` parameters

The standard library's `FixedWidthInteger` protocol includes computed properties `var .bigEndian: Self` and `var .littleEndian: Self`. These could be used to modify the arguments of `storeBytes()`, or to modify the return values from `load()`. Unfortunately these properties are not clear, because they return `Self`. This proposal applies the consideration of _ byteOrder: to the operation where it belongs: serialization.

#### Having `load()` functions default to aligned operations

`UnsafeRawPointer`'s original `load()` function requires correct alignment, and the less restrictive  `loadUnaligned()` was added later. We have long considered this unfortunate, and this proposal seeks to improve on the status quo by making our new safe `load()` functions perform unaligned operations.

## Acknowledgments

Thanks to Karoy Lorentey and Nate Cook for taking the time to discuss this topic.
Enums to represent the byte order have previously been pitched by Michael Ilseman ([Unicode Processing APIs](https://forums.swift.org/t/69294)) and by (YOCKOW)[https://gist.github.com/YOCKOW] ((ByteOrder type)[https://forums.swift.org/t/74027)].
