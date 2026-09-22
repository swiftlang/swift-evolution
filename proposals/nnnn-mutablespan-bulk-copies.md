# Bulk copying operations for `MutableSpan` and `MutableRawSpan`

* Proposal: [SE-NNNN](nnnn-mutablespan-bulk-copies.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Awaiting review**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Implementation: [swiftlang/swift#92466](https://github.com/swiftlang/swift/pull/92466)
* Previous Proposal: Follow-up to [SE-0467](0467-MutableSpan.md)
* Review: ([pitch](https://forums.swift.org/...))

[SE-0370]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0370-pointer-family-initialization-improvements.md
[SE-0467]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md
[SE-0485]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0485-outputspan.md
[SE-0516]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0516-borrowing-sequence.md
[SE-0527]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md

## Summary of changes

Adds bulk-update operations to `MutableSpan` and `MutableRawSpan`, which overwrite a span (or a subrange thereof) with a repeated value, or with the elements of another span or an `Iterable`.

## Motivation

[SE-0467][SE-0467] introduced `MutableSpan` and `MutableRawSpan` as the safe, composable replacements for `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer`. Bulk operations were missing from their original implementation, and they are necessary for the safe types to supersede their unsafe predecessors in most uses.

We propose adding bulk copy operations that overwrite elements of a `MutableSpan`. With the proposed changes, copying elements from a `Span` to a `MutableSpan` becomes a single call that uses bulk memory operations:

```swift
// was (when using exclusively safe code):
precondition(source.count == destination.count)
for i in destination.indices {
  destination[i] = source[i]
}

// proposed:
destination.updateAll(copying: source)
```

## Proposed solution

We propose a family of `update` operations on `MutableSpan` and `MutableRawSpan`.

The family is composed of three base method names:

- `updateAll(...)` overwrites every element of the destination span. The source must contain exactly as many elements as the destination.
- `updateSubrange(_:...)` overwrites every element in the given range of indices. The source must contain exactly as many elements as the range does.
- `updateElements(from:...)` overwrites the destination's elements starting at the given index, and reports the index after the last element updated.

The source argument of these methods can have three different labels, depending on the kind of source:

- `repeating:` sets every destination element to the same value.
- `copying:` copies elements from a source.
- `moving:` moves elements from an `OutputSpan`, leaving its memory uninitialized.

For example:

```swift
var destination = array.mutableSpan

destination.updateAll(repeating: 0)
destination.updateSubrange(2..<6, repeating: -1)
destination.updateAll(copying: source.span)
destination.updateSubrange(2..<6, copying: source.span)
```

`updateAll` and `updateSubrange` require the source count to match the destination count or the subrange count, and trap when the counts don't match.

#### Copying from an `Iterable` source

`updateElements(from:copying:)` handles the case where the amount of data from the source is not known ahead of time. It takes any [`Iterable`][SE-0516] source, such as `Span`, `InlineArray`, and `UniqueArray`:

```swift
var destination = array.mutableSpan
var index = 0
destination.updateElements(from: &index, copying: header)
destination.updateElements(from: &index, copying: payload)
destination.updateElements(from: &index, copying: checksum)
precondition(index == destination.count)
```

The overload used above accepts any `Iterable`, including one whose iteration can throw. The `index` is taken as an `inout` parameter because a thrown error must not leave the destination in an unknown state: when the function returns, either normally or by throwing, `index` is updated to the index after the last element updated.

When using an `Iterable` whose `Failure` is `Never`, a convenience overload of `updateElements` is available. It returns the index after the last element updated:

```swift
var end = destination.updateElements(from: 0, copying: header)
end = destination.updateElements(from: end, copying: payload)
```

The overloads that take `some Iterable` copy their source completely, and trap if the span cannot contain every element from the source. The source can be shorter than the remaining space.

A third overload mutates a [`BorrowingIteratorProtocol`][SE-0516] source, and stops as soon as either the iterator has provided all its elements or the end of the destination span is reached, whichever comes first. When the function returns (normally or by throwing), the iterator is positioned after the last element it provided to the destination.

```swift
var iterator = source.makeBorrowingIterator()
var i = 0
first.updateElements(from: &i, copying: &iterator)
if i == first.count {
  i = 0
  second.updateElements(from: &i, copying: &iterator)
}
```

#### Moving elements

`updateAll(moving:)` and `updateSubrange(_:moving:)` mutate an [`OutputSpan`][SE-0485], and move its elements into the destination. The source `OutputSpan` is empty afterwards, with its memory uninitialized.

```swift
var destination = storage.mutableSpan
source.edit { output in
  destination.updateSubrange(2..<4, moving: &output)
}
assert(source.isEmpty)
```

Moving an element doesn't require its type to be copyable, so the `moving:` variants are available when `Element: ~Copyable`.

## Detailed design

### `MutableSpan`

```swift
extension MutableSpan {
  /// Overwrites every element of this span with the given value.
  ///
  /// - Parameter repeatedValue: The value to set for every element.
  mutating func updateAll(repeating repeatedValue: consuming Element)

  /// Overwrites every element within a range of indices with the given value.
  ///
  /// - Parameters:
  ///   - subrange: A valid range of indices. Every index in this range
  ///      must be within the bounds of this `MutableSpan`.
  ///   - repeatedValue: The value to set for every element in `subrange`.
  mutating func updateSubrange(
    _ subrange: Range<Index>, repeating repeatedValue: consuming Element
  )

  mutating func updateSubrange(
    _ subrange: some RangeExpression<Index>, repeating repeatedValue: consuming Element
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, repeating repeatedValue: consuming Element
  )

  /// Overwrites every element of this span by copying the elements
  /// of the source.
  ///
  /// `source` must have exactly as many elements as this span.
  ///
  /// - Parameter source: The elements to copy into this span.
  mutating func updateAll(copying source: Span<Element>)

  /// Overwrites the elements within a range of indices by copying
  /// the elements of the source.
  ///
  /// `source` must have exactly as many elements as `subrange`.
  ///
  /// - Parameters:
  ///   - subrange: A valid range of indices. Every index in this range
  ///      must be within the bounds of this `MutableSpan`.
  ///   - source: The elements to copy into `subrange`.
  mutating func updateSubrange(
    _ subrange: Range<Index>, copying source: Span<Element>
  )

  mutating func updateSubrange(
    _ subrange: some RangeExpression<Index>, copying source: Span<Element>
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, copying source: Span<Element>
  )
}

extension MutableSpan where Element: ~Copyable {
  /// Overwrites every element of this span by moving the elements
  /// from the source.
  ///
  /// `source` must have exactly as many initialized elements as this span.
  /// When this function returns, `source` is empty, and its memory has been
  /// returned to the uninitialized state.
  ///
  /// - Parameter source: The elements to move into this span.
  mutating func updateAll(moving source: inout OutputSpan<Element>)

  /// Overwrites the elements within a range of indices by moving
  /// the elements from the source.
  ///
  /// `source` must have exactly as many initialized elements as `subrange`.
  /// When this function returns, `source` is empty, and its memory has been
  /// returned to the uninitialized state.
  ///
  /// - Parameters:
  ///   - subrange: A valid range of indices. Every index in this range
  ///      must be within the bounds of this `MutableSpan`.
  ///   - source: The elements to move into `subrange`.
  mutating func updateSubrange(
    _ subrange: Range<Index>, moving source: inout OutputSpan<Element>
  )

  mutating func updateSubrange(
    _ subrange: some RangeExpression<Index>, moving source: inout OutputSpan<Element>
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, moving source: inout OutputSpan<Element>
  )
}

@available(SwiftStdlib 6.4, *)
extension MutableSpan {
  /// Overwrites elements of this span, starting at an index, by copying
  /// every element of the source.
  ///
  /// This span must have enough space from `index` to its end
  /// (`index..<count`) for every element provided by `source`.
  ///
  /// If reading from `source` throws an error, the elements copied before
  /// the error occurred remain in this span, and `index` is updated to
  /// the index after the last element updated before the error.
  ///
  /// - Parameters:
  ///   - index: The index at which to start copying. It must be a valid
  ///      index of this span, or equal to its `count`. On return, it is
  ///      updated to the index after the last element updated.
  ///   - source: The elements to copy into this span.
  /// - Throws: Any error thrown while reading from `source`.
  mutating func updateElements<
    I: Iterable & ~Escapable & ~Copyable
  >(
    from index: inout Index, copying source: borrowing I
  ) throws(I.Failure) where I.Element == Element

  /// Overwrites elements of this span, starting at an index, by copying
  /// every element of the source.
  ///
  /// This span must have enough space from `index` to its end
  /// (`index..<count`) for every element provided by `source`.
  ///
  /// - Parameters:
  ///   - index: The index at which to start copying. It must be a valid
  ///      index of this span, or equal to its `count`.
  ///   - source: The elements to copy into this span.
  /// - Returns: The index after the last element updated.
  mutating func updateElements<
    I: Iterable & ~Escapable & ~Copyable
  >(
    from index: Index, copying source: borrowing I
  ) -> Index where I.Element == Element, I.Failure == Never

  /// Overwrites elements of this span, starting at an index, by copying
  /// elements from an iterator.
  ///
  /// Copying stops as soon as `source` has provided all its elements,
  /// or the end of this span is reached, whichever comes first.
  ///
  /// If reading from `source` throws an error, the elements copied before
  /// the error occurred remain in this span, and `index` is updated to
  /// the index after the last element updated before the error.
  ///
  /// - Parameters:
  ///   - index: The index at which to start copying. It must be a valid
  ///      index of this span, or equal to its `count`. On return, it is
  ///      updated to the index after the last element updated.
  ///   - source: An iterator over the elements to copy into this span. On
  ///      return, it is positioned after the last element copied.
  /// - Throws: Any error thrown while reading from `source`.
  mutating func updateElements<
    I: BorrowingIteratorProtocol & ~Escapable & ~Copyable
  >(
    from index: inout Index, copying source: inout I
  ) throws(I.Failure) where I.Element == Element
}
```

### `MutableRawSpan`

The `MutableRawSpan` operations are the same as the typed ones, replacing typed sources with `RawSpan` and `OutputRawSpan`. The `updateElements` overloads use an `Iterable` with an element type of `UInt8`.

```swift
extension MutableRawSpan {

  /// Overwrites every byte of this span with the given value.
  ///
  /// - Parameter repeatedByte: The value to set for every byte.
  mutating func updateAll(repeating repeatedByte: UInt8)

  /// Overwrites every byte within a range of offsets with the given value.
  ///
  /// - Parameters:
  ///   - subrange: A valid range of offsets. Every offset in this range
  ///      must be within the bounds of this `MutableRawSpan`.
  ///   - repeatedByte: The value to set for every byte in `subrange`.
  mutating func updateSubrange(
    _ subrange: Range<Int>, repeating repeatedByte: UInt8
  )

  mutating func updateSubrange(
    _ subrange: some RangeExpression<Int>, repeating repeatedByte: UInt8
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, repeating repeatedByte: UInt8
  )

  /// Overwrites every byte of this span by copying the bytes of the source.
  ///
  /// `source` must have exactly as many bytes as this span.
  ///
  /// - Parameter source: The bytes to copy into this span.
  mutating func updateAll(copying source: RawSpan)

  /// Overwrites the bytes within a range of offsets by copying
  /// the bytes of the source.
  ///
  /// `source` must have exactly as many bytes as `subrange`.
  ///
  /// - Parameters:
  ///   - subrange: A valid range of offsets. Every offset in this range
  ///      must be within the bounds of this `MutableRawSpan`.
  ///   - source: The bytes to copy into `subrange`.
  mutating func updateSubrange(
    _ subrange: Range<Int>, copying source: RawSpan
  )

  mutating func updateSubrange(
    _ subrange: some RangeExpression<Int>, copying source: RawSpan
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, copying source: RawSpan
  )

  /// Overwrites every byte of this span by moving the bytes from the source.
  ///
  /// `source` must have exactly as many initialized bytes as this span.
  /// When this function returns, `source` is empty, and its memory has been
  /// returned to the uninitialized state.
  ///
  /// - Parameter source: The bytes to move into this span.
  mutating func updateAll(moving source: inout OutputRawSpan)

  /// Overwrites the bytes within a range of offsets by moving
  /// the bytes from the source.
  ///
  /// `source` must have exactly as many initialized bytes as `subrange`.
  /// When this function returns, `source` is empty, and its memory has been
  /// returned to the uninitialized state.
  ///
  /// - Parameters:
  ///   - subrange: A valid range of offsets. Every offset in this range
  ///      must be within the bounds of this `MutableRawSpan`.
  ///   - source: The bytes to move into `subrange`.
  mutating func updateSubrange(
    _ subrange: Range<Int>, moving source: inout OutputRawSpan
  )

  mutating func updateSubrange(
    _ subrange: some RangeExpression<Int>, moving source: inout OutputRawSpan
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, moving source: inout OutputRawSpan
  )
}

@available(SwiftStdlib 6.4, *)
extension MutableRawSpan {

  /// Overwrites bytes of this span, starting at a byte offset, by copying
  /// every byte of the source.
  ///
  /// This span must have enough space from `byteOffset` to its end
  /// (`byteOffset..<byteCount`) for every byte provided by `source`.
  ///
  /// If reading from `source` throws an error, the bytes copied before
  /// the error occurred remain in this span, and `byteOffset` is updated to
  /// the offset after the last byte updated before the error.
  ///
  /// - Parameters:
  ///   - byteOffset: The offset at which to start copying. It must be a valid
  ///      offset into this span, or equal to its `byteCount`. On return, it
  ///      is updated to the offset after the last byte updated.
  ///   - source: The bytes to copy into this span.
  /// - Throws: Any error thrown while reading from `source`.
  mutating func updateElements<
    I: Iterable & ~Escapable & ~Copyable
  >(
    from byteOffset: inout Int, copying source: borrowing I
  ) throws(I.Failure) where I.Element == UInt8

  /// Overwrites bytes of this span, starting at a byte offset, by copying
  /// every byte of the source.
  ///
  /// This span must have enough space from `byteOffset` to its end
  /// (`byteOffset..<byteCount`) for every byte provided by `source`.
  ///
  /// - Parameters:
  ///   - byteOffset: The offset at which to start copying. It must be a valid
  ///      offset into this span, or equal to its `byteCount`.
  ///   - source: The bytes to copy into this span.
  /// - Returns: The offset after the last byte updated.
  mutating func updateElements<
    I: Iterable & ~Escapable & ~Copyable
  >(
    from byteOffset: Int, copying source: borrowing I
  ) -> Int where I.Element == UInt8, I.Failure == Never

  /// Overwrites bytes of this span, starting at a byte offset, by copying
  /// bytes from an iterator.
  ///
  /// Copying stops as soon as `source` has provided all its elements,
  /// or the end of this span is reached, whichever comes first.
  ///
  /// If reading from `source` throws an error, the bytes copied before
  /// the error occurred remain in this span, and `byteOffset` is updated to
  /// the offset after the last byte updated before the error.
  ///
  /// - Parameters:
  ///   - byteOffset: The offset at which to start copying. It must be a valid
  ///      offset into this span, or equal to its `byteCount`. On return, it
  ///      is updated to the offset after the last byte updated.
  ///   - source: An iterator over the bytes to copy into this span. On
  ///      return, it is positioned after the last byte copied.
  /// - Throws: Any error thrown while reading from `source`.
  mutating func updateElements<
    I: BorrowingIteratorProtocol & ~Escapable & ~Copyable
  >(
    from byteOffset: inout Int, copying source: inout I
  ) throws(I.Failure) where I.Element == UInt8
}
```

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

The additions in this proposal will be implemented without creating additional ABI.

These additions require the existence of `Span` or `Iterable`. On ABI-stable platforms, they have a minimum deployment target that matches the availability of `Span` or `Iterable`.

## Implications on adoption

The additions described in this proposal require a new version of the Swift standard library.

## Future directions

#### Bulk initialization for `OutputSpan`

Bulk append operations for `OutputSpan` and `OutputRawSpan` are similar to the operations proposed here, but we are deferring them to a future proposal. The outcome of this proposal will inform a bulk-initialization proposal.

#### Piecewise updating from a container of noncopyable elements

We are proposing `updateElements(from:copying:)` to copy elements from an `Iterable`, but this is limited to copyable elements. The proposal doesn't include an `updateElements(from:moving:)` that would update a `MutableSpan` from a `UniqueDeque<ExecutorJob>`, for example. The `DrainableContainer` protocol from the `ContainersPreview` module of [swift-collections](https://github.com/apple/swift-collections) is a prototype of the functionality needed for `updateElements(from:moving:)`.

#### Generalized container protocols

We need a generalization of the `Collection` family of protocols for noncopyable (and nonescapable) elements. In such a generalized family of protocols, the functions described here would become method requirements for a successor to `MutableCollection`.

## Alternatives considered

#### Using only `update` as the base name

`updateAll(repeating:)` is a synonym for the existing `update(repeating:)`, and we considered using names such as `update(subrange:copying:)` for the methods proposed here. We went with `updateAll` and `updateSubrange` for two reasons.

First, there are precedents in `replaceSubrange(_:with:)` and `removeSubrange(_:)` (in `RangeReplaceableCollection`), and `replaceSubrange(_:copying:)` (in [`UniqueArray`][SE-0527]), for situations that require a range parameter. `removeSubrange` is paired with `removeAll`.

Second, the name of `update(repeating:)` came from the equivalent method of `UnsafeMutableBufferPointer` ([SE-0370][SE-0370]). `UnsafeMutableBufferPointer`'s `update` method doesn't need a "subrange" parameter because its slicing syntax is so compact. Unfortunately, that compact slicing syntax does not work with noncopyable containers. Given the requirement to pass a range as the first argument, we propose a naming model similar to `replaceSubrange` and `removeSubrange`.

#### Deprecating the existing `update(repeating:)`

`update(repeating:)` shipped in Swift 6.2 and now has a synonym in `updateAll(repeating:)`. The extra spelling is harmless, so we choose not to deprecate it.

#### Closure-based bulk updates

A `withMutableSubrange(_:) { ... }` form would scope the sub-span automatically and avoid needing to insert an explicit `consume` to end accesses. As discussed in [SE-0467][SE-0467], the `Span` family is deliberately avoiding new closure-taking APIs, as they compose poorly with each other and with new language features.

#### Returning an iterator from `updateElements(from:copying:)`

`UnsafeMutableBufferPointer.update(from:)` ([SE-0370][SE-0370]) is a close counterpart to `updateElements(from:copying:)`. The return type of the older method is a tuple of an iterator and an index. Returning state in this way is viable in non-throwing situations, but iteration over an `Iterable` can throw, and the state would be lost when an error is thrown. When the thrown type is `Never`, we would like to return the iterator in addition to the index, but we cannot do so at this time because tuples cannot contain nonescapable types. We provide an overload that takes an `inout some BorrowingIteratorProtocol` as a replacement for a tuple-returning function.

## Acknowledgements

Thanks to Karoy Lorentey for his work on prototyping the container protocols in the [swift-collections](https://github.com/apple/swift-collections) package.
