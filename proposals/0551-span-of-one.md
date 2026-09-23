# `Span` over a single value

* Proposal: [SE-0551](0551-span-of-one.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active review (September 22...October 6, 2026)**
* Implementation: [swiftlang/swift#88152](https://github.com/swiftlang/swift/pull/88152)
* Review: ([pitch](https://forums.swift.org/t/89189))

## Summary of changes

Add initializers to form a single-element `Span` over any value, and to form a single-element `MutableSpan` over any mutable value.

## Motivation

Occasionally, programmers need adaptors between single values and `Span`-taking API. Currently it is possible to use the `span` property of `CollectionOfOne` in order to pass a single value to a `Span` parameter, but it requires a copy that `Span` doesn't need, or that non-copyable values cannot support. We can provide initializers for `Span`, `RawSpan`, `MutableSpan` and `MutableRawSpan` that borrow single values in place.

These initializers will also act as safe versions of `withUnsafePointer(to:)`, `withUnsafeMutablePointer(to:)`, `withUnsafeBytes(of:)` and `withUnsafeMutableBytes(of:)`.

## Proposed solution

`Span` and `MutableSpan` gain new initializers that form a span of count 1
over a single value:

```swift
let header = PacketHeader(...)
let c = checksum(Span(ofOne: header).bytes) // borrows `header` in place

var timestamp = UInt64.zero
var span = MutableSpan(ofOne: &timestamp)
parser.read(into: span.mutableBytes)        // writes into `timestamp`
```

Similarly, `RawSpan` and `MutableRawSpan` gain initializers that form spans over the bytes of a single value:

```swift
let header = PacketHeader(...)
let c = checksum(RawSpan(bytesOf: header))

var timestamp = UInt64.zero
var bytes = MutableRawSpan(bytesOf: &timestamp)
parser.read(into: bytes)
```

## Detailed design

#### `Span`

```swift
extension Span where Element: ~Copyable {
  /// Create a span over the single value passed as a parameter.
  ///
  /// - Parameters:
  ///   - value: a value to be borrowed by the span
  @_lifetime(borrow value)
  public init(ofOne value: borrowing Element)
}
```

#### `MutableSpan`

```swift
extension MutableSpan where Element: ~Copyable {
  /// Create a mutable span over the single value passed as a parameter.
  ///
  /// The `MutableSpan` created by this initializer will represent a
  /// mutation of `value`.
  ///
  /// - Parameters:
  ///   - value: a value to be mutated through the span
  @_lifetime(&value)
  public init(ofOne value: inout Element)
}
```

#### `RawSpan`

```swift
extension RawSpan {
  /// Create a span over the bytes of the single value
  /// passed as a parameter.
  ///
  /// The `RawSpan` created by this initializer will have a `byteCount`
  /// of `MemoryLayout<Element>.size` bytes.
  ///
  /// - Parameters:
  ///   - value: a value to be borrowed by the span
  @_lifetime(borrow value)
  public init<Element: ConvertibleToBytes>(
    bytesOf value: borrowing Element
  )
}
```

#### `MutableRawSpan`

```swift
extension MutableRawSpan {
  /// Create a mutable span over the bytes of the single value
  /// passed as a parameter.
  ///
  /// The `MutableRawSpan` created by this initializer will represent a
  /// mutation of `value`. It will have a `byteCount` of
  /// `MemoryLayout<Element>.size` bytes.
  ///
  /// - Parameters:
  ///   - value: a value to be mutated through the span
  @_lifetime(&value)
  public init<Element: ConvertibleToBytes & ConvertibleFromBytes>(
    bytesOf value: inout Element
  )
}
```

## Source compatibility

This proposal is additive and is source-compatible, as the proposed initializers do not overload existing symbols.

## ABI compatibility

The initializers in this proposal will be implemented in such a manner as to avoid creating additional ABI.

These additions require the existence of `Span`, and have a minimum deployment target on Darwin-based platforms, where the Swift standard library is distributed with the operating system.

## Implications on adoption

These additions require the standard library in which they are introduced, but are back-deployable as much as their parent type.

## Alternatives considered

#### Keep relying on `CollectionOfOne`'s `span` property

`CollectionOfOne.span` and `CollectionOfOne.mutableSpan` already provide a
single-element span, but they are limited to values of copyable types. They are also limited to providing access to the storage of the collection, rather than to the storage of another binding.

#### Unlabeled initializers

These initializers were originally pitched without an argument label, as `Span(header)` and `MutableSpan(&timestamp)`. There were two objections to the unlabeled spelling. The first is that an unlabeled initializer in Swift conventionally denotes a conversion of its argument. The second is that users might expect `Span(someArray)` to produce the same thing as `someArray.span`.

The `ofOne:` label makes it obvious that the created `Span` is over 1 value, and references `CollectionOfOne`, which has filled a similar role for copyable values.

#### Same label for `RawSpan` and `Span` initializers

We could use the same `ofOne:` label used for the `Span` initializer with the `RawSpan`. We feel that `ofOne` connotes a single element, which for `RawSpan` means one byte. The `bytesOf:` label has an appropriately plural connotation.

#### Add a `RawSpan` initializer for unsafe byte views

The proposed `RawSpan`initializer is constrained to `some ConvertibleToBytes`. We could also add an unsafe initializer with no constraints, with a label such as `paddedBytesOf:`. We would prefer not to proliferate the initializers, and let the current API compose for the unsafe case. For example, one could obtain a `RawSpan` from a `SIMD3<UInt16>`instance as follows: `Span(ofOne: coordinates).unsafeBytes`.

## Acknowledgments

Thanks to Joe Groff for implementing the compiler feature that enables this proposal.
