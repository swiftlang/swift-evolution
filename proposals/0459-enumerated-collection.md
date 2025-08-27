# Add `Collection` conformances for `enumerated()`

* Proposal: [SE-0459](0459-enumerated-collection.md)
* Author: [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 6.2)**
* Implementation: [swiftlang/swift#78092](https://github.com/swiftlang/swift/pull/78092)
* Previous Proposal: [SE-0312](0312-indexed-and-enumerated-zip-collections.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-add-collection-conformance-for-enumeratedsequence/76680)) ([review](https://forums.swift.org/t/se-0459-add-collection-conformances-for-enumerated/77509)) ([acceptance](https://forums.swift.org/t/accepted-with-modification-se-0459-add-collection-conformances-for-enumerated/78082))

## Introduction

This proposal aims to fix the lack of `Collection` conformance of the sequence returned by `enumerated()`, preventing it from being used in a context that requires a `Collection`.

## Motivation

Currently, `EnumeratedSequence` type conforms to `Sequence`, but not to any of the collection protocols. Adding these conformances was impossible before [SE-0234 Remove `Sequence.SubSequence`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0234-remove-sequence-subsequence.md), and would have been an ABI breaking change before the language allowed `@available` annotations on protocol conformances ([PR](https://github.com/apple/swift/pull/34651)). Now we can add them!

Conformance to the collection protocols can be beneficial in a variety of ways, for example:
* `(1000..<2000).enumerated().dropFirst(500)` becomes a constant time operation.
* `"abc".enumerated().reversed()` will return a `ReversedCollection` rather than allocating a new array.
* SwiftUI’s `List` and `ForEach` views will be able to directly take an enumerated collection as their data.

## Detailed design

Conditionally conform `EnumeratedSequence` to `Collection`, `BidirectionalCollection`, `RandomAccessCollection`.

```swift
@available(SwiftStdlib 6.1, *)
extension EnumeratedSequence: Collection where Base: Collection {
  // ...
}

@available(SwiftStdlib 6.1, *)
extension EnumeratedSequence: BidirectionalCollection
  where Base: BidirectionalCollection
{
  // ...
}

@available(SwiftStdlib 6.1, *)
extension EnumeratedSequence: RandomAccessCollection
  where Base: RandomAccessCollection {}
```

## Source compatibility

All protocol conformances of an existing type to an existing protocol are potentially source breaking because users could have added the exact same conformances themselves. However, given that `EnumeratedSequence` do not expose their underlying sequences, there is no reasonable way anyone could have conformed to `Collection` themselves.

## Effect on ABI stability

These conformances are additive to the ABI, but will affect runtime casting mechanisms like `is` and `as`. On ABI stable platforms, the result of these operations will depend on the OS version of said ABI stable platforms. Similarly, APIs like `underestimatedCount` may return a different result depending on if the OS has these conformances or not.

## Alternatives considered

#### Add `LazyCollectionProtocol` conformance for `EnumeratedSequence`.

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

We chose to keep this proposal very small to prevent any such potential headaches of source breaks.

#### Keep `EnumeratedSequence` the way it is and add an `enumerated()` overload to `Collection` that returns a `Zip2Sequence<Range<Int>, Self>`.

This is tempting because `enumerated()` is little more than `zip(0..., self)`, but this would cause an unacceptable amount of source breakage due to the lack of `offset` and `element` tuple labels that `EnumeratedSequence` provides.

#### Only conform `EnumeratedSequence` to `BidirectionalCollection` when the base collection conforms to `RandomAccessCollection` rather than `BidirectionalCollection`.

Here’s what the `Collection` conformance could look like:

```swift
extension EnumeratedSequence: Collection where Base: Collection {
    struct Index {
        let base: Base.Index
        let offset: Int
    }
    var startIndex: Index {
        Index(base: _base.startIndex, offset: 0)
    }
    var endIndex: Index {
        Index(base: _base.endIndex, offset: 0)
    }
    func index(after index: Index) -> Index {
        Index(base: _base.index(after: index.base), offset: index.offset + 1)
    }
    subscript(index: Index) -> (offset: Int, element: Base.Element) {
        (index.offset, _base[index.base])
    }
}

extension EnumeratedSequence.Index: Comparable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.base == rhs.base
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        return lhs.base < rhs.base
    }
}
```

Here’s what the `Bidirectional` conformance could look like. The question is: should `Base` be required to conform to `BidirectionalCollection` or `RandomAccessCollection`?

```swift
extension EnumeratedSequence: BidirectionalCollection where Base: ??? {
    func index(before index: Index) -> Index {
        let currentOffset = index.base == _base.endIndex ? _base.count : index.offset
        return Index(base: _base.index(before: index.base), offset: currentOffset - 1)
    }
}
```

Notice that calling `index(before:)` with the end index requires computing the `count` of the base collection. This is an O(1) operation if the base collection is `RandomAccessCollection`, but O(n) if it's `BidirectionalCollection`.

##### Option 1: `where Base: BidirectionalCollection`

A direct consequence of `index(before:)` being O(n) when passed the end index is that some operations like `last` are also O(n):

```swift
extension BidirectionalCollection {
    var last: Element? {
        isEmpty ? nil : self[index(before: endIndex)]
    }
}

// A bidirectional collection that is not random-access.
let evenNumbers = (0 ... 1_000_000).lazy.filter { $0.isMultiple(of: 2) }
let enumerated = evenNumbers.enumerated()

// This is still O(1), ...
let endIndex = enumerated.endIndex

// ...but this is O(n).
let lastElement = enumerated.last!
print(lastElement) // (offset: 500000, element: 1000000)
```

However, since this performance pitfall only applies to the end index, iterating over a reversed enumerated collection stays O(n):

```swift
// A bidirectional collection that is not random-access.
let evenNumbers = (0 ... 1_000_000).lazy.filter { $0.isMultiple(of: 2) }

// Reaching the last element is O(n), and reaching every other element is another combined O(n).
for (offset, element) in evenNumbers.enumerated().reversed() {
    // ...
}
```

In other words, this could make some operations unexpectedly O(n), but it’s not likely to make operations unexpectedly O(n²).

##### Option 2: `where Base: RandomAccessCollection`

If `EnumeratedSequence`’s conditional conformance to `BidirectionalCollection` is restricted to when `Base: RandomAccessCollection`, then operations like `last` and `last(where:)` will only be available when they’re guaranteed to be O(1):

```swift
// A bidirectional collection that is not random-access.
let str = "Hello"

let lastElement = str.enumerated().last! // error: value of type 'EnumeratedSequence<String>' has no member 'last'
```

That said, some algorithms that can benefit from bidirectionality such as `reversed()` and `suffix(_:)` are also available on regular collections, but with a less efficient implementation. That means that the code would still compile if the enumerated sequence is not bidirectional, it would just perform worse — the most general version of `reversed()` on `Sequence` allocates an array and adds every element to that array before reversing it:

```swift
// A bidirectional collection that is not random-access.
let str = "Hello"

// This no longer conforms to `BidirectionalCollection`.
let enumerated = str.enumerated()

// As a result, this now returns a `[(offset: Int, element: Character)]` instead
// of a more efficient `ReversedCollection<EnumeratedSequence<String>>`.
let reversedElements = enumerated.reversed()
```

The base collection needs to be traversed twice either way, but the defensive approach of giving the `BidirectionalCollection` conformance a stricter bound ultimately results in an extra allocation.

Taking all of this into account, we've gone with option 1 for the sake of giving collections access to more algorithms and more efficient overloads of some algorithms. Conforming this collection to `BidirectionalCollection` when the base collection conforms to the same protocol is less surprising. We don’t think the possible performance pitfalls pose a large enough risk in practice to negate these benefits.
