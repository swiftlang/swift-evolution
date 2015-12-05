# Add a Lazy flatMap for Sequences of Optionals #

* Proposal: [SE-NNNN](#)
* Author(s): [Oisin Kidney](https://github.com/oisdk)
* Status: **Review**
* Review Manager: TBD

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
[1, 2, 3, 4, 5]
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

## Proposed Approach ##

To mirror the already-existing lazy sequence methods, I propose adding a new struct, and a method on `LazySequenceType`:

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