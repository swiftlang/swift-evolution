# Add `indexed()` and `Collection` conformances for `enumerated()` and `zip(_:_:)`

* Proposal: [SE-0312](0312-indexed-and-enumerated-zip-collections.md)
* Author: [Tim Vermeulen](https://github.com/timvermeulen)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Returned for revision**
* Implementation: [apple/swift#36851](https://github.com/apple/swift/pull/36851)

## Introduction
This proposal aims to fix the lack of `Collection` conformance of the sequences returned by `zip(_:_:)` and `enumerated()`, preventing them from being used in a context that requires a `Collection`. Also included is the addition of the `indexed()` method on `Collection` as a more ergonomic, efficient, and correct alternative to `c.enumerated()` and `zip(c.indices, c)`.

Swift-evolution thread: [Pitch](https://forums.swift.org/t/pitch-add-indexed-and-collection-conformances-for-enumerated-and-zip/47288)

## Motivation
Currently, the `Zip2Sequence` and `EnumeratedSequence` types conform to `Sequence`, but not to any of the collection protocols. Adding these conformances was impossible before [SE-0234 Remove `Sequence.SubSequence`](https://github.com/apple/swift-evolution/blob/main/proposals/0234-remove-sequence-subsequence.md), and would have been an ABI breaking change before the language allowed `@available` annotations on protocol conformances ([PR](https://github.com/apple/swift/pull/34651)). Now we can add them!

Conformance to the collection protocols can be beneficial in a variety of ways, for example:
* `(1000..<2000).enumerated().dropFirst(500)` becomes a constant time operation.
* `zip("abc", [1, 2, 3]).reversed()` will return a `ReversedCollection` rather than allocating a new array.
* SwiftUI’s `List` and `ForEach` views will be able to directly take an enumerated or zipped collection as their data.

This proposal also includes the addition of the `indexed()` method (which can already be found in the [Swift Algorithms](https://github.com/apple/swift-algorithms) package) as an alternative for many use cases of `zip(_:_:)` and `enumerated()`. When the goal is to iterate over a collection’s elements and indices at the same time, `enumerated()` is often inadequate because it provides an offset, not a true index. For many collections this integer offset is different from the `Index` type, and in the case of `ArraySlice` in particular this offset is a common source of bugs when the slice’s `startIndex` isn’t `0`. `zip(c.indices, c)` solves these problems, but it is less ergonomic than `indexed()` and potentially less performant when traversing the indices of a collection is computationally expensive.

## Detailed design
Conditionally conform `Zip2Sequence` to `Collection`, `BidirectionalCollection`, and `RandomAccessCollection`.

> **Note**: OS version 9999 is a placeholder and will be replaced with whatever actual OS versions this functionality will be introduced in.

```swift
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Zip2Sequence: Collection
  where Sequence1: Collection, Sequence2: Collection
{
  // ...
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Zip2Sequence: BidirectionalCollection
  where Sequence1: BidirectionalCollection, Sequence2: BidirectionalCollection
{
  // ...
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Zip2Sequence: RandomAccessCollection
  where Sequence1: RandomAccessCollection, Sequence2: RandomAccessCollection {}
```

Conditionally conform `EnumeratedSequence` to `Collection`, `BidirectionalCollection`, `RandomAccesCollection`, and `LazyCollectionProtocol`.

```swift
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension EnumeratedSequence: Collection where Base: Collection {
  // ...
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension EnumeratedSequence: BidirectionalCollection
  where Base: BidirectionalCollection
{
  // ...
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension EnumeratedSequence: RandomAccessCollection
  where Base: RandomAccessCollection {}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension EnumeratedSequence: LazySequenceProtocol
  where Base: LazySequenceProtocol {}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension EnumeratedSequence: LazyCollectionProtocol
  where Base: LazyCollectionProtocol {}
```

Add an `indexed()` method to `Collection` that returns a collection over (index, element) pairs of the original collection.

```swift
extension Collection {
  @available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
  public func indexed() -> Indexed<Self> {
    Indexed(_base: self)
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public struct Indexed<Base: Collection> {
  // ...
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Indexed: Collection {
  // ...
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Indexed: BidirectionalCollection where Base: BidirectionalCollection {
  // ...
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Indexed: RandomAccessCollection where Base: RandomAccessCollection {}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Indexed: LazySequenceProtocol where Base: LazySequenceProtocol {}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Indexed: LazyCollectionProtocol where Base: LazyCollectionProtocol {}
```

## Source compatibility
Adding `LazySequenceProtocol` conformance for `EnumeratedSequence` is a breaking change for code that relies on the `enumerated()` method currently not propagating `LazySequenceProtocol` conformance in a lazy chain:

```swift
extension Sequence {
  func everyOther_v1() -> [Element] {
    let x = self.lazy
      .enumerated()
      .filter { $0.offset.isMultiple(of: 2) }
      .map(\.element)
    
    // error: Cannot convert return expression of type 'LazyMapSequence<...>' to return type '[Self.Element]'
    return x
  }
  
  func everyOther_v2() -> [Element] {
    // will keep working, the eager overload of `map` is picked
    return self.lazy
      .enumerated()
      .filter { $0.offset.isMultiple(of: 2) }
      .map(\.element)
  }
}
```

All protocol conformances of an existing type to an existing protocol are potentially source breaking because users could have added the exact same conformances themselves. However, given that `Zip2Sequence` and `EnumeratedSequence` do not expose their underlying sequences, there is no reasonable way anyone could have conformed either type to `Collection` themselves. The only sensible conformance that could conflict with one of the conformances added in this proposal is the conformance of `EnumeratedSequence` to `LazySequenceProtocol`.

## Effect on ABI stability
This proposal does not affect ABI stability.

## Alternatives considered
#### Don’t add `LazyCollectionProtocol` conformance for `EnumeratedSequence` for the sake of source compatibility.
We consider it a bug that `enumerated()` currently does not propagate laziness in a lazy chain.

#### Only conform `Zip2Sequence` and `EnumeratedSequence` to `BidirectionalCollection` when the base collections conform to `RandomAccessCollection`.
Traversing an `EnumeratedSequence` backwards requires computing the `count` of the collection upfront in order to determine the correct offsets, which is an O(count) operation when the base collection does not conform to `RandomAccessCollection`. This is a one-time cost incurred when `c.index(before: c.endIndex)` is called, and does not affect the overall time complexity of an entire backwards traversal. Besides, `index(before:)` does not have any performance requirements that need to be adhered to.

Similarly, `Zip2Sequence` requires finding the index of the longer of the two collections that corresponds to the end index of the shorter collection, when doing a backwards traversal. As with `EnumeratedSequence`, this adds a one-time O(n) cost that does not violate any performance requirements.

#### Keep `EnumeratedSequence` the way it is and add an `enumerated()` overload to `Collection` that returns a `Zip2Sequence<Range<Int>, Self>`.
This is tempting because `enumerated()` is little more than `zip(0..., self)`, but this would cause an unacceptable amount of source breakage due to the lack of `offset` and `element` tuple labels that `EnumeratedSequence` provides.
