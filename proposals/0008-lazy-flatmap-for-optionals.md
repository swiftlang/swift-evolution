# Add a Lazy flatMap for Sequences of Optionals #

* Proposal: [SE-0008](0008-lazy-flatmap-for-optionals.md)
* Author: [Oisin Kidney](https://github.com/oisdk)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151221/004418.html)
* Bug: [SR-361](https://bugs.swift.org/browse/SR-361)

## Introduction ##

Currently, the Swift standard library has two versions of `flatMap`. One which flattens a sequence of sequences after a transformation:

```swift
[1, 2, 3]
  .flatMap { n in n..<5 } 
// [1, 2, 3, 4, 2, 3, 4, 3, 4]
```

And another which flattens a sequence of `Optional`s:

```swift
(1...10)
  .flatMap { n in n % 2 == 0 ? n/2 : nil }
// [1, 2, 3, 4, 5]
```

However, there is only a lazy implementation for the first version:

```swift
[1, 2, 3]
  .lazy
  .flatMap { n in n..<5 }
// LazyCollection<FlattenBidirectionalCollection<LazyMapCollection<Array<Int>, Range<Int>>>>

(1...10)
  .lazy
  .flatMap { n in n % 2 == 0 ? n/2 : nil }
// [1, 2, 3, 4, 5]
```

Swift Evolution Discussions: [Lazy flatMap for Optionals](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151130/000534.html), [Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002592.html)

## Motivation ##

Seeing as the already-existing `flatMap` has a lazy version for nested sequences, a missing lazy version for sequences of `Optional`s seems like a gap. The usefulness of lazy sequences is well documented, especially when refactoring imperative nested for-loops into chains of methods, which can unnecessarily allocate intermediate arrays if done eagerly.

## Proposed Approach ##

Making use of already-existing types in the standard library, `flatMap`'s functionality can be achieved with a `map`-`filter`-`map` chain:

```swift
extension LazySequenceType {
  
  @warn_unused_result
  public func flatMap<T>(transform: Elements.Generator.Element -> T?)
    -> LazyMapSequence<LazyFilterSequence<LazyMapSequence<Elements, T?>>, T> {
      return self
        .map(transform)
        .filter { opt in opt != nil }
        .map { notNil in notNil! }
  }
}
```

## Detailed Design ##

A version for `LazyCollectionType`s is almost identical:

```swift
extension LazyCollectionType {
  
  @warn_unused_result
  public func flatMap<T>(transform: Elements.Generator.Element -> T?)
    -> LazyMapCollection<LazyFilterCollection<LazyMapCollection<Elements, T?>>, T> {
      return self
        .map(transform)
        .filter { opt in opt != nil }
        .map { notNil in notNil! }
  }
}
```

However, a "bidirectional" version cannot be written in this way, since no `FilterBidirectionalCollection` exists.

The other form of `flatMap` uses a `flatten` method on nested sequences, which has both a `CollectionType` form and a form for `CollectionType`s with `BidirectionalIndexType`s. 

However, Swift's current type system doesn't allow a similar method to be defined on sequences of `Optional`s. This means we have to rely on `filter`, which only has a `SequenceType` and `CollectionType` implementation.

## Impact on existing code ##

## Alternatives considered ##

### Custom struct ###

It would also be possible to add a new struct, and a method on `LazySequenceType`:

```swift
public struct FlatMapOptionalGenerator<G: GeneratorType, Element>: GeneratorType {
  private let transform: G.Element -> Element?
  private var generator: G
  public mutating func next() -> Element? {
    while let next = generator.next() {
      if let transformed = transform(next) {
        return transformed
      }
    }
    return nil
  }
}

public struct FlatMapOptionalSequence<S: LazySequenceType, Element>: LazySequenceType {
  private let transform: S.Generator.Element -> Element?
  private let sequence: S
  public func generate() -> FlatMapOptionalGenerator<S.Generator, Element> {
    return FlatMapOptionalGenerator(transform: transform, generator: sequence.generate())
  }
}

extension LazySequenceType {
  public func flatMap<T>(transform: Generator.Element -> T?) -> FlatMapOptionalSequence<Self, T> {
    return FlatMapOptionalSequence(transform: transform, sequence: self)
  }
}
```

However, this implementation does not have a `LazyCollectionType` version. To add one, and a bidirectional implementation, six new types (three `SequenceType`s, three `GeneratorType`s) would have to be added to the standard library. 

### New Filter struct ###

This would involve adding a `FilterBidirectionalCollection` to the standard library. Arguably, this is a gap currently. It would allow both `flatMap` versions to mirror each other, with minimal new types.

### Make Optional Conform to SequenceType ###

This is a far-reaching, separate proposal, but it would solve the issue that this proposal seeks to solve. It's worth bearing in mind, though, that `Optional` *probably* wouldn't have a `BidirectionalIndexType`, so the bidirectional version of `flatMap` wouldn't exist on `Optional`s, anyway.
