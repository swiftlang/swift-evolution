# Bulk update operations for `MutableSpan` and `MutableRawSpan`

* Proposal: [SE-0558](0558-mutablespan-bulk-updates.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Active review (October 13...28, 2026)**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Implementation: [swiftlang/swift#92466](https://github.com/swiftlang/swift/pull/92466)
* Previous Proposal: [SE-0467](0467-MutableSpan.md)
* Review: ([pitch](https://forums.swift.org/t/89843)) ([review](https://forums.swift.org/t/90048))

[SE-0370]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0370-pointer-family-initialization-improvements.md
[SE-0467]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md
[SE-0485]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0485-outputspan.md
[SE-0516]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0516-borrowing-sequence.md
[SE-0527]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md

## Summary of changes

Adds bulk update operations to `MutableSpan` and `MutableRawSpan`, which overwrite a span (or a subrange thereof) with a repeated value, or with the elements of another span or an `Iterable`.

## Motivation

[SE-0467][SE-0467] introduced `MutableSpan` and `MutableRawSpan` as the safe, composable replacements for `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer`. Bulk operations were deferred[^1] from the original proposal, yet they are necessary for the safe types to supersede their unsafe predecessors.

[^1]: [SE-0467][SE-0467] proposed bulk update functions, but [SE-0485][SE-0485] withdrew them in favor of proposing a better naming scheme at a later time.

We propose adding bulk update operations that overwrite existing elements of a `MutableSpan`. With the proposed changes, copying elements from a `Span` to a `MutableSpan` becomes a single call that uses bulk memory operations:

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

We propose a family of `update` operations on `MutableSpan` and `MutableRawSpan`. They overwrite a range of contiguous elements, deinitializing the overwritten values.

The family is composed of three base method names:

- `updateAll(...)` overwrites every element of the destination span. The source must contain exactly as many elements as the destination.
- `updateSubrange(_:...)` overwrites every element in the given range of indices. The source must contain exactly as many elements as the range does.
- `updateElements(startingAt:...)` overwrites the destination's elements starting at the given index, and reports the index after the last element updated.

The source argument of each method can have three different labels, depending on the kind of source:

- `repeating:` sets every destination element to the same value.
- `copying:` copies elements from a source.
- `moving:` moves elements from an `OutputSpan`, leaving its memory uninitialized.

The names we propose establish a nomenclature for bulk operations that specifies both what happens with the destination and how the source is to be handled.

The first part of each of the names proposed here is "update", because the functions change values in place in the container. Other related bulk operations include removing elements (`removeAll`, `removeSubrange`) and replacing subranges of elements (`replaceSubrange`)[^2]. These actions, as well as `insert` and `append`, should be proposed as part of a range-replaceable container protocol, and we would like the methods proposed here to have a family resemblance with them.

The label for the source, either `copying:` or `moving:`, will also apply to all of the above base function names. We expect a type like `UniqueArray` to be usable with both `copying:` and `moving:` overloads, providing control over runtime overhead in ways the `Collection` protocols cannot provide.

[^2]: The related operations `remove`, `replace`, `insert` and `append` are part of `UniqueArray`'s API ([SE-0527][SE-0527]).

#### Copying from a `Span`

```swift
var destination = array.mutableSpan

destination.updateAll(copying: source.span)
destination.updateSubrange(2..<6, copying: source.span.extracting(first: 4))
```

`updateAll` and `updateSubrange` require the source count to match the destination count or the subrange count, and trap when the counts don't match.

#### Copying from an `Iterable` source

`updateElements(startingAt:copyingAll:)` handles cases where the amount of data from a source is not known ahead of time. It takes any [`Iterable`][SE-0516] source, such as `Span`, `InlineArray`, and `UniqueArray`:

```swift
var destination = array.mutableSpan
var index = 0
destination.updateElements(startingAt: &index, copyingAll: header)
destination.updateElements(startingAt: &index, copyingAll: payload)
destination.updateElements(startingAt: &index, copyingAll: checksum)
precondition(index == destination.count)
```

`copyingAll:` copies every element of the source, and traps if the source has more elements than fit between the index and the end of the destination. If the source has fewer, the remaining elements of the destination are unchanged.

The overload used above accepts any `Iterable`, including one whose iteration can throw. The index is taken as an `inout` parameter because a thrown error must not leave the state of the destination unknown to the caller. When the function returns, either normally or by throwing, `index` is updated to the index after the last element updated.

`updateElements(startingAt:copying:)` handles sources that might not fit. Copying stops as soon as the source has provided all its elements, or the end of the destination span is reached, whichever comes first. The function returns the iterator it used to read from the source, positioned after the last element copied.

If reading from the `Iterable` source throws an error, no iterator is returned, but `index` still reports the progress made.

A second `copying:` overload mutates a [`BorrowingIteratorProtocol`][SE-0516] source, to continue using an iterator returned by the first.

```swift
var index = 0
var iterator = destination1.updateElements(startingAt: &index, copying: source)
if index == destination1.count {
  var index2 = 0
  destination2.updateElements(startingAt: &index2, copying: &iterator)
  // ...
}
```

We expect the `updateElements` functions to become part of a new protocol family generalizing the `Collection` protocol family. As such, we propose the same name (`updateElements`) for `MutableRawSpan` as for `MutableSpan`, with an element type of `UInt8`.

#### Moving elements

`updateAll(moving:)` and `updateSubrange(_:moving:)` mutate an [`OutputSpan`][SE-0485], and move its elements into the destination. The source `OutputSpan` is empty afterwards, with its memory uninitialized.

```swift
var destination = storage.mutableSpan
source.edit { output in
  assert(output.count == 2)
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
    _ subrange: some RangeExpression<Index>,
    repeating repeatedValue: consuming Element
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, repeating repeatedValue: consuming Element
  )

  /// Overwrites every element of this span by copying the elements
  /// of the source.
  ///
  /// `source` must have exactly as many elements as this span.
  ///
  /// - Note: When `Element: BitwiseCopyable`, this function lowers
  ///     to LLVM's `memcpy` primitive.
  ///
  /// - Parameter source: The elements to copy into this span.
  mutating func updateAll(copying source: Span<Element>)

  /// Overwrites every element within a range of indices by copying
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

  /// Overwrites every element within a range of indices by moving
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
    _ subrange: some RangeExpression<Index>,
    moving source: inout OutputSpan<Element>
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, moving source: inout OutputSpan<Element>
  )
}

extension MutableSpan {
  /// Overwrites elements of this span, starting at an index, by copying
  /// elements from the source.
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
  ///   - source: The elements to copy into this span.
  /// - Returns: An iterator over `source`, positioned after the last
  ///     element copied.
  /// - Throws: Any error thrown while reading from `source`.
  mutating func updateElements<
    I: Iterable & ~Escapable & ~Copyable
  >(
    startingAt index: inout Index, copying source: borrowing I
  ) throws(I.Failure) -> I.BorrowingIterator where I.Element == Element

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
  ///   - source: An iterator over the elements to copy into this span.
  ///      On normal return, it is positioned after the last element copied.
  /// - Throws: Any error thrown while reading from `source`.
  mutating func updateElements<
    I: BorrowingIteratorProtocol & ~Escapable & ~Copyable
  >(
    startingAt index: inout Index, copying source: inout I
  ) throws(I.Failure) where I.Element == Element

  /// Overwrites elements of this span, starting at an index, by copying
  /// every element of the source.
  ///
  /// `source` must not have more elements than fit between `index` and
  /// the end of this span. If it has fewer, the remaining elements of
  /// this span are unchanged.
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
    startingAt index: inout Index, copyingAll source: borrowing I
  ) throws(I.Failure) where I.Element == Element
}
```

### `MutableRawSpan`

The `MutableRawSpan` operations are the same as the typed ones, replacing typed sources with `RawSpan` and `OutputRawSpan`, or an element type of `UInt8`.

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

  /// Overwrites every byte within a range of offsets by copying
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

  /// Overwrites every byte within a range of offsets by moving
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

extension MutableRawSpan {
  /// Overwrites bytes of this span, starting at a byte offset, by copying
  /// bytes from the source.
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
  ///   - source: The bytes to copy into this span.
  /// - Returns: An iterator over `source`, positioned after the last
  ///     byte copied.
  /// - Throws: Any error thrown while reading from `source`.
  mutating func updateElements<
    I: Iterable & ~Escapable & ~Copyable
  >(
    startingAt byteOffset: inout Int, copying source: borrowing I
  ) throws(I.Failure) -> I.BorrowingIterator where I.Element == UInt8

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
  ///   - source: An iterator over the bytes to copy into this span.
  ///      On normal return, it is positioned after the last byte copied.
  /// - Throws: Any error thrown while reading from `source`.
  mutating func updateElements<
    I: BorrowingIteratorProtocol & ~Escapable & ~Copyable
  >(
    startingAt byteOffset: inout Int, copying source: inout I
  ) throws(I.Failure) where I.Element == UInt8

  /// Overwrites bytes of this span, starting at a byte offset, by copying
  /// every byte of the source.
  ///
  /// `source` must not have more bytes than fit between `byteOffset` and
  /// the end of this span. If it has fewer, the remaining bytes of
  /// this span are unchanged.
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
    startingAt byteOffset: inout Int, copyingAll source: borrowing I
  ) throws(I.Failure) where I.Element == UInt8
}
```

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

The additions in this proposal will be implemented without creating additional ABI.

These additions require the existence of `Span` or `Iterable`. On ABI-stable platforms, they have a minimum deployment target that matches the availability of `Iterable` (`updateElements`) or `Span` (the rest).

## Implications on adoption

The additions described in this proposal require a new version of the Swift standard library.

## Future directions

#### Bulk appending for `OutputSpan`

Bulk append operations for `OutputSpan` and `OutputRawSpan` are similar to the operations proposed here, but we are deferring them to a future proposal. The outcome of this proposal will inform a proposal centered around `OutputSpan` and `OutputRawSpan`.

#### Bulk copying within a `MutableSpan`

Due to the law of exclusivity, the source and the destination cannot be within the same span. Future improvements could provide a method specifically for this purpose, or provide a safe method to split an existing span into two disjoint accesses.

#### Piecewise updating from a container of noncopyable elements

We are proposing `updateElements(startingAt:copying:)` to copy elements from an `Iterable`, but this is limited to copyable elements. The proposal doesn't include an `updateElements(startingAt:moving:)` that would update a `MutableSpan` from a `UniqueDeque<ExecutorJob>`, for example. The `DrainableContainer` protocol from the `ContainersPreview` module of [swift-collections](https://github.com/apple/swift-collections) is a prototype of the functionality needed for `updateElements(startingAt:moving:)`.

#### Generalized container protocols

We need a generalization of the `Collection` family of protocols for noncopyable (and nonescapable) elements. In such a generalized family of protocols, the functions proposed here would become method requirements for a successor to `MutableCollection`.

#### Bulk copying from `Collection` and `Sequence` conformers

It is possible to construct a `BorrowingIteratorAdapter` from an `IteratorProtocol` instance, and use it with the matching overload of `updateElements`. [SE-0516][SE-0516] deferred conforming existing `Sequence` types to `Iterable`. Once they conform, they will work directly with `updateElements(startingAt:copying:)`.

#### Returning an index and an iterator together

Once tuples can contain nonescapable types, we could add a convenience overload of `updateElements(startingAt:copying:)` for sources where `Failure` is `Never`. It would take the index by value and, like `UnsafeMutableBufferPointer.update(from:)`, would return a tuple of the iterator with the index after the last element updated.

## Alternatives considered

#### Using only `update` as the base name

We considered using names such as `update(subrange:copying:)` for the methods proposed here, but we went with `updateAll` and `updateSubrange` for two reasons.

First, there are precedents in `replaceSubrange(_:with:)` and `removeSubrange(_:)` (in `RangeReplaceableCollection`), and `replaceSubrange(_:copying:)` (in [`UniqueArray`][SE-0527]), for situations that require a range parameter. `removeSubrange` is paired with `removeAll`.

Second, the name of `update(repeating:)` came from the equivalent method of `UnsafeMutableBufferPointer` ([SE-0370][SE-0370]). `UnsafeMutableBufferPointer`'s `update` method doesn't need a "subrange" parameter because its slicing syntax is very compact. Unfortunately, that compact slicing syntax does not work with noncopyable containers. Given the requirement to pass a range as the first argument, we propose a naming model similar to `replaceSubrange` and `removeSubrange`.

#### Deprecating the existing `update(repeating:)`

The new `MutableSpan.updateAll(repeating:)` is a synonym for the existing `MutableSpan.update(repeating:)`. The extra spelling is harmless, so we choose not to deprecate it to avoid unnecessary churn.

#### Providing `updateSubrange(_:moving:)` for `UnsafeMutableBufferPointer` sources

We do not propose an overload of `updateSubrange(_:moving:)` that takes an `UnsafeMutableBufferPointer`, because it would add little functionality at the cost of expanding the `@unsafe` API surface. With pre-existing functionality, it is possible to use `MutableSpan.withUnsafeMutableBufferPointer` and call `UnsafeMutableBufferPointer`'s `moveUpdate(fromContentsOf:)` method within the closure passed to it. This proposal adds the ability to do the same operation via an `OutputSpan` that has been created from an `UnsafeMutableBufferPointer`.

#### Generic overloads for `updateSubrange`

The `updateElements(startingAt:copying:)` methods take a generic `Iterable` or `BorrowingIteratorProtocol` argument because these are the only span-friendly protocols in the standard library. Later, when newer container protocols are added, `updateSubrange(_:copying:)` and `updateSubrange(_:moving:)` could gain generic overloads that admit arguments such as `UniqueArray`. This proposal defines the fundamental forms for `updateSubrange` and `updateAll`, which can be used to build protocol default implementations in the future.

#### Returning a tuple from `updateElements(startingAt:copying:)`

`UnsafeMutableBufferPointer.update(from:)` ([SE-0370][SE-0370]) is a close counterpart to `updateElements(startingAt:copying:)`. The return type of the older method is a tuple of an iterator and an index. Iteration over an `Iterable` can throw, and the index would be lost when an error is thrown. As a result, `updateElements` must take the index as an `inout` argument.

#### Using `from` as the label for the starting index of `updateElements`

An earlier version of this proposal used `from` as the label of the index at which `updateElements` starts updating, as in `updateElements(from:copying:)`. The preposition describes the starting position well, but `UnsafeMutableBufferPointer.update(from:)` ([SE-0370][SE-0370]) uses the same word to denote the source of the copied elements. The label `startingAt` better describes the role of the index. It would also suit a future method that returns spans from a piecewise-contiguous container, such as `nextSpan(startingAt: &index, maxCount: Int)`.

## Revision history

* Changes in review:
  * Renamed the `from` label of the `updateElements` functions of `MutableSpan` and `MutableRawSpan` to `startingAt`.
  * Restructured the `updateElements` functions of `MutableSpan` and `MutableRawSpan`. The `copying:` overload for an `Iterable` source now stops when the destination is full, and returns the iterator. The `copyingAll:` overload traps if the source has more elements than can fit in the destination. The convenience overload for sources where `Failure` is `Never` is removed.

## Acknowledgements

Thanks to Karoy Lorentey for his work on prototyping the container protocols in the [swift-collections](https://github.com/apple/swift-collections) package. Thanks to Xiaodi Wu for naming suggestions.
