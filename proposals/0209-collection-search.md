# Collection search
* Proposal: SE-XXXX
* Authors: [Lance Parker](https://forums.swift.org/u/lancep) & [Anthony Latsis](https://forums.swift.org/u/anthonylatsis)
* Implementation: [apple/swift#15854](https://github.com/apple/swift/pull/15854)
* Review Manager: TBD
* Status: TBD

## Summary
Searching through a collection's contents is extremely useful (and would fill some holes in today's String API as well). We should add facilities to `Collection`,  `BidirectionalCollection` and `RangeReplaceableCollection` that allow users to do this.

## Motivation
Searching a collection for occurrences of smaller collections is a common thing to do, and finding the range(s) at which the smaller collection is located allows you to count occurrences, or replace/remove those parts from the main collection. 

## Proposed Solution
```swift
protocol Collection {
  public func firstRange<C: BidirectionalCollection>(of pattern: C) -> Range<Index>? where C.Element == Element, Element: Equatable
}

extension Collection where Element: Equatable {
  public func count<C: BidirectionalCollection>(occurrencesOf pattern: C, allowOverlapping: Bool = false) -> Int where C.Element == Element
  public func contains<C: BidirectionalCollection>(occurrenceOf pattern: C) -> Bool where C.Element == Element
  public func firstRange<C: BidirectionalCollection>(of pattern: C) -> Range<Index>? where C.Element == Element { ... } //default implementation for the new protocol requirement on Collection
}

extension BidirectionalCollection where Element: Equatable {
  public func lastRange<C: BidirectionalCollection>(of pattern: C) -> Range<Index>? where C.Element == Element
}

extension RangeReplaceableCollection where Element: Equatable {
  public mutating func removeFirst<C: BidirectionalCollection>(occurrenceOf pattern: C) where C.Element == Element
  public mutating func removeAll<C: BidirectionalCollection>(occurrencesOf pattern: C) where C.Element == Element
  public mutating func replaceAll<C: BidirectionalCollection, R: Collection>(occurrencesOf pattern: C, with replacement: R) where C.Element == Element, R.Element == Element
  public mutating func replaceFirst<C: BidirectionalCollection, R: Collection>(occurrenceOf pattern: C, with replacement: R) where C.Element == Element, R.Element == Element
}

extension RangeReplaceableCollection where Self: BidirectionalCollection, Element: Equatable {
  public mutating func removeLast<C: BidirectionalCollection>(occurrenceOf pattern: C) where C.Element == Element
  public mutating func replaceLast<C: BidirectionalCollection, R: Collection>(occurrenceOf pattern: C, with replacement: R) where C.Element == Element, R.Element == Element
}
```

`firstRange(of:)` is a new requirement for `Collection`, with a default implementation provided. This allows types like `String` to provide a faster implementation of `firstRange(of:)`. We don't need customization points for the other methods because they are all implemented in terms of `firstRange(of:)`.

## Impact on String
Under this proposal, the following `String` method would be deprecated as its functionality is replaced by the above methods:

```swift
extension String {
  public func contains<T : StringProtocol>(_ other: T) -> Bool
}
```

## Source compatibility
This change is purely additive so has no source compatibility consequences.

## Effect on ABI stability
This change is purely additive so has no ABI stability consequences.

## Effect on API resilience
This change is purely additive so has no API resilience consequences.

## Alternatives considered
We could put all the `Collection` methods on `Sequence`, however, `firstRange(of:)` (which all the others are based on) returns a `Range<Index>`, and sequences don't have indices, and thus, ranges of indices. The return type for `Sequence`'s `findFirst(occurrenceOf:)` would have to be some `AnySequence` like thing which is far less useful than a range is for a collection, and doesn't allow you to build up the other pieces as easily.  The implementation for the `Sequence` version would also need to allocate a buffer to store a sliding window of the sequences' elements as it searched through them which is not ideal.

We could propose each of these individually, or at least in smaller batches, however:
* all of the other APIs are implemented in terms of `firstRange(of:)`, so we might as well do them all at once
*  it's useful to design these methods together so that they are all uniform in shape and terminology