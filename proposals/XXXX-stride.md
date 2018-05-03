# Adding Strideable Sequences

* Proposal: SE-TBD
* Author(s): [Erica Sadun](http://github.com/erica), [Soroush Khanlou](https://github.com/khanlou)
* Status: tbd 
* Review manager: tbd

## Introduction

This proposal extends `Sequence` to stride over a sequence, incorporating every nth element into the derived sequence.

*This proposal was first discussed in the Swift Forums on the [\[Pitch\] Adding Strideable Sequences](https://forums.swift.org/t/pitch-adding-strideable-sequences/12112/6) thread.*

## Motivation

A Swift `Sequence` may represent many kinds of sequential elements: natural numbers, word from a source text, hues in a color wheel, bytes in a memory allocation, and so forth. It is natural and common to stride through sequences, especially those that aren't necessarily numerical in nature. A stride allows you to collect or consume spaced-out values at a faster pace. For example, you might want to look at "every 4th byte" to process alpha channels, "every other row" for spreadsheet highlights, or "every two hundredth word" for frequency analysis.

This proposal extends `Sequence` to introduce strides across any base. 

### Infinite and Non-numerical Sequences

Swift's built-in `stride` functions are number based. They are useful for striding through integer and floating point numbers. They can act as integer-based collection indices. These functions aren't, however, suitable for skipping through non-numerical, possibly infinite sequences, which may or may not be multipass or otherwise indexable. 

* For example, you might create a color progression `Sequence` and parameterize how quickly to procede from, for example, red through orange, yellow, green, and beyond.

* You cannot use indexing features without creating an intermediate array.

### Collections

As `Collection` conforms to `Sequence`, this design adds strided array traversal. Therefore, you can stride through array members:

```swift
for value in myArray.striding(by: 5) {
    // process every 5th member, starting with the
    // first member of `myArray`:
    //
    // myArray[0], myArray[0 + strideLength], 
    // myArray[0 + 2 * strideLength], ...
    //
}
```

This proposal makes no provision for offsetting the start or end points of a strided array but you can easily stride an array slice:

```swift
let results = Array(myArray[5...20].striding(by: 5))
```

As collections, you can stride both sets and dictionaries. The internal implementation details of sets and dictionaries will return the same strided results each time, although these collections are theoretically unordered. The documentation for `striding(by:)` does not call this out or provide any guarantees of repeatability.

## Detailed Design

```swift
/// A strided non-contiguous sequence of elements that incorporates
/// every nth element of a base sequence.
///
/// When used with collections, the sequence includes the first element
/// followed by the element at the `startIndex` offset by the `stride`,
/// by 2 * the `stride`, etc.
///
/// ```
/// for value in myArray.striding(by: 5) {
///   // process every 5th member, starting with the
///   // first member of `myArray`:
///   //
///   // myArray[0], myArray[0 + strideLength],
///   // myArray[0 + 2 * strideLength], ...
/// }
/// ```
///
/// To stride across a subsequence, use a collection slice:
/// ```
/// let results = Array(myArray[5...20].striding(by: 2))
/// ```
///
public struct StridedSequence<BaseSequence: Sequence> : Sequence, IteratorProtocol {
  public typealias Stride = Int
  
  public mutating func next() -> BaseSequence.Element? {
    defer {
      for _ in 0 ..< _strideLength - 1 {
        let _ = _iterator.next()
      }
    }
    return _iterator.next()
  }
  
  /// Access only through `Sequence.striding(by:)`
  internal init(_ sequence: BaseSequence, stride strideLength: StridedSequence.Stride) {
    _iterator = sequence.makeIterator()
    _strideLength = strideLength
  }
  
  internal var _iterator: BaseSequence.Iterator
  internal var _strideLength: StridedSequence.Stride
}

extension Sequence {
  /// Returns a strided iterator of sequence elements. The
  /// stride length is set to incorporate every nth element.
  ///
  /// - Parameter strideLength: the distance for each stride
  /// - Returns: A strided sequence of values
  public func striding(by strideLength: StridedSequence<Self>.Stride) -> StridedSequence<Self> {
    guard strideLength > 0 else { fatalError("Stride must be positive")}
    return StridedSequence(self, stride: strideLength)
  }
}
```

A more performant implementation is established for `RandomAccessCollection`. This also eliminates trapping for an edge case when striding arrays by their `count`:

```swift
/// A strided non-contiguous sequence of elements that incorporates
/// every nth element of a base sequence.
///
/// For example:
///
/// ```swift
/// for x in [1, 2, 3, 4, 5, 6].striding(by: 2) {
///    print(x) // 1, 3, 5
/// }
/// ```
///
public struct RandomAccessStridedSequence<BaseCollection: RandomAccessCollection> : Collection {
  
  public typealias Stride = Int
  public typealias Index = BaseCollection.Index
  
  /// The position of the first element in a non-empty collection.
  ///
  /// In an empty collection, `startIndex == endIndex`.
  public var startIndex: Index {
    return _collection.startIndex
  }
  
  /// The collection's "past the end" position---that is, the position one
  /// greater than the last valid subscript argument.
  ///
  /// `endIndex` is always reachable from `startIndex` by zero or more
  /// applications of `index(after:)`.
  public var endIndex: Index {
    return _collection.endIndex
  }
  
  /// Returns the position immediately after the given index.
  ///
  /// The successor of an index must be well defined. For an index `i` into a
  /// collection `c`, calling `c.index(after: i)` returns the same index every
  /// time.
  ///
  /// - Parameter i: A valid index of the collection. `i` must be less than
  ///   `endIndex`.
  /// - Returns: The index value immediately after `i`.
  public func index(after i: Index) -> Index {
    return _collection.index(i, offsetBy: _strideLength, limitedBy: _collection.endIndex) ?? _collection.endIndex
  }
  
  /// Accesses the element indicated by `position`.
  ///
  /// - Precondition: `position` indicates a valid position in `self` and
  ///   `position != endIndex`.
  public subscript(i: Index) -> BaseCollection.Element {
    return _collection[i]
  }
  
  /// Access only through `RandomAccessCollection.striding(by:)`
  internal init(_ collection: BaseCollection, stride strideLength: RandomAccessStridedSequence.Stride) {
    _collection = collection
    _strideLength = strideLength
  }
  
  internal var _collection: BaseCollection
  internal var _strideLength: RandomAccessStridedSequence.Stride
}

extension RandomAccessCollection {
  /// Returns a strided sequence of collection elements. The
  /// stride length is set to incorporate every nth element.
  ///
  /// - Parameter strideLength: the distance for each stride
  /// - Returns: A strided sequence of values
  func striding(by strideLength: RandomAccessStridedSequence<Self>.Stride) -> RandomAccessStridedSequence<Self> {
    guard strideLength > 0 else { fatalError("Stride must be positive")}
    return RandomAccessStridedSequence(self, stride: strideLength)
  }
}
```

## Future Directions

Not at this time

## Source compatibility

Full. This change is fully additive

## Effect on ABI stability

None

## Effect on API resilience

None

## Alternatives and Future Directions

None
