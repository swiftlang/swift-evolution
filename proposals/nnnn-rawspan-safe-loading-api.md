# Safe loading API for `RawSpan`

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Previous Proposal: follows [SE-0447][SE-0447]
* Previous Revision: *none*
* Review: ([pitch](https://forums.swift.org/...))

[SE-0447]: 0447-span-access-shared-contiguous-storage.md

## Introduction

We propose the introduction of a set of safe API to load values of numeric types from the memory represented by `RawSpan` instances, as well as safe conversions from `RawSpan` to `Span` for the same numeric types.

## Motivation

In [SE-0447][SE-0447], we introduced `RawSpan` along with some unsafe functions to load values of arbitrary types. This proposal adds the ability to load values more ergonomically, without the doubt introduced by unsafe functions.

## Proposed solution

##### `RawSpan`

`RawSpan` will gain a series of concretely typed `load(fromByteOffset:as:)` functions to obtain numeric values from the underlying memory. These will be bounds-checked and, since they always return values from fully-inhabited types, are fully safe. For example,

```swift
extension RawSpan {
  func load(fromByteOffset: Int = 0, as: UInt8.Type) -> UInt8
}
```

The loadable types will be `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64`, `Int64`, `UInt`, `Int`, `Float32` and `Float64`. On platforms that support them, loading `Float16`, `Float80`, `UInt128`, and `Int128`  values will also be implemented.

The `load(as:)` function will not have an equivalent with unchecked byte offset. If that functionality is needed, the function `unsafeLoad(fromUncheckedByteOffset:as:)` is already available.

The `load(as:)` functions will also be available for `MutableRawSpan` and `OutputRawSpan`.

##### `Span`

`Span` will gain a series of concrete initializers `init(viewing: RawSpan)` to allow viewing a range of untyped memory as a typed `Span`, when `Span.Element` is a numeric type. These conversions will be bounds-checked. For example,

```swift
extension Span {
  @_lifetime(borrow span)
  init(viewing bytes: consuming RawSpan) where Element == UInt8
}
```

The supported element types will be `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64`, `Int64`, `UInt`, `Int`, `Float32` and `Float64`. On platforms that support them, initializing `Span` instances with `Float16`, `Float80`, `UInt128`, and `Int128` elements will also be implemented.

## Detailed design

```swift
extension RawSpan {
  /// Returns a value of uint8, constructed from the raw memory
  /// at the specified offset.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create. The default is `UInt8.self`
  ///     if the return value can be inferred to be of type `UInt8`
  /// - Returns: A new value of type `UInt8`, read from `offset`.
  func load(fromByteOffset: Int = 0, as: UInt8.Type) -> UInt8

  func load(fromByteOffset: Int = 0, as: Int8.Type) -> Int8
  func load(fromByteOffset: Int = 0, as: UInt16.Type) -> UInt16
  func load(fromByteOffset: Int = 0, as: Int16.Type) -> Int16
  func load(fromByteOffset: Int = 0, as: UInt32.Type) -> UInt32
  func load(fromByteOffset: Int = 0, as: Int32.Type) -> Int32
  func load(fromByteOffset: Int = 0, as: UInt64.Type) -> UInt64
  func load(fromByteOffset: Int = 0, as: Int64.Type) -> Int64
  func load(fromByteOffset: Int = 0, as: UInt.Type) -> UInt
  func load(fromByteOffset: Int = 0, as: Int.Type) -> Int

  /// Returns a new float value, constructed from the raw memory
  /// at the specified offset.
  ///
  /// The range of memory from `offset` up to
  /// `offset + MemoryLayout<Float32>.size` must be within
  /// the bounds of `self`.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create. The default is 
  ///     `Float32.self` if the return value can be inferred to be
  ///      of type `Float32`
  /// - Returns: A new value of type `Float32`, read from `offset`.
  func load(fromByteOffset: Int = 0, as: Float32.Type) -> Float32
  func load(fromByteOffset: Int = 0, as: Float64.Type) -> Float64

  func load(fromByteOffset: Int = 0, as: Float16.Type) -> Float16
  func load(fromByteOffset: Int = 0, as: Float80.Type) -> Float80
  func load(fromByteOffset: Int = 0, as: UInt128.Type) -> UInt128
  func load(fromByteOffset: Int = 0, as: Int128.Type) -> Int128
}
```
Note: the `load()` functions should also be available as extensions to `MutableRawSpan` and `OutputRawSpan`.

```swift
extension Span {
  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == UInt8

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Int8

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == UInt16

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Int16

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == UInt32

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Int32

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == UInt64

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Int64

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == UInt

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Int

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Float32

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Float64

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Float16

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Float80

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == UInt128

  @lifetime(copy rawSpan)
  public init(viewing bytes: consuming RawSpan) where Element == Int128
}
```
Note: these initializers should not be available for `MutableSpan`.


## Source compatibility

This proposal consists only of additions, and is therefore source compatible.

## ABI compatibility

The functions in this proposal will be implemented in such a way as to avoid creating additional ABI.

These functions require the existence of `Span`, so have a minimum deployment target on Darwin-based platforms where the Swift standard library is distributed with the operating system.

## Implications on adoption

## Future directions

#### A "fully inhabited" layout constraint

## Alternatives considered

#### Waiting for a "fully inhabited" layout constraint

Waiting for a "fully inhabited" layout constraint for types is not viable.

#### Making these additions generic over `BinaryInteger` and `BinaryFloat`

These are not sufficient constraints; a binary integer can have a representation where not all the bits of its stride are used.

## Acknowledgments

