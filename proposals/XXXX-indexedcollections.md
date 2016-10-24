# Introducing `indexed()` collections

* Proposal: TBD
* Author: [Erica Sadun](https://github.com/erica), [Nate Cook](https://github.com/natecook1000), [Jacob Bandes-Storch](https://github.com/jtbandes), [Kevin Ballard](https://github.com/kballard)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal introduces `indexed()` to the standard library, a method on collections that returns an (index, element) tuple sequence.

Swift-evolution thread:
[\[Proposal draft\] Introducing `indexed()` collections
](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160926/027355.html)

## Motivation

Indices have a specific fixed meaning in Swift. They are used to create valid collection subscripts. This proposal introduces `indexed()` to emit a semantically relevant sequence by pairing a collection's `indices` with its members. 

Our  motivations are: 

* Swift's `enumerated()` method is misleading to naive developers.  `enumerated()` is a method for the `Sequence` protocol, which doesn’t have any indices. Integers are the only thing that make sense there. 
* `zip(x.indices, x)` creates an attractive nuisance with suboptimal efficiency. 

### `enumerated()`

The standard library's `enumerated()` method returns a sequence of pairs enumerating a sequence. The pair's first member is a monotonically incrementing integer starting at zero, and the second member is the corresponding element of the sequence. When working with arrays, the integer is coincidentally the same type and value as an `Array` index but the enumerated value is not generated with index-specific semantics.  This may lead to confusion when developers attempt to subscript a non-array collection with enumerated integers. It can introduce serious bugs when developers use `enumerated()`-based integer subscripting with non-zero-based array slices.

### `zip()`

While it is trivial to create a solution in Swift, the most common developer approach shown here calculates indexes twice for any collection that uses IndexingIterator as its iterator. For collections that do not, it performs the moral equivalent in calculating an index offset along with whatever work the Iterator does to calculate the next element.

```
extension Collection {
    /// Returns a sequence of pairs (*idx*, *x*), where *idx* represents a
    /// consecutive collection index, and *x* represents an element of
    /// the sequence.
    func indexed() -> Zip2Sequence<Self.Indices, Self> {
        return zip(indices, self)
    }
}
```

### Indexing Costs

Incrementing an index in some collections can be unnecessarily costly. In a lazy filtered collection, an index increment is potentially O(N). We feel this is better addressed introducing a new function into the Standard Library to provide a more efficient design that avoids the attractive nuisance of the "obvious" solution.

Using an index should be cheap or free. Calculating the next index holds no such guarantee. Consider String.CharacterView. Calculating the next index may be arbitrarily complex since users can string as many combining marks together as desired. In practice, the next index will be pretty cheap but even "pretty cheap" is still work, and depending on the programming load carried by the loop, calculating character indices may be a significant fraction of the work performed.

## Detailed Design

Our vision of `indexed()` bypasses duplicated index generation with potentially high computation costs. We'd create an iterator that calculates each index once and then applies that index to subscript the collection. Implementation would take place through `IndexedSequence`, similar to `EnumeratedSequence` and look something like this, except implemented as a concrete type:

```swift
sequence(state: base.indices, next: {
    guard let idx = $0.next() else { return nil }
    return (idx, base[idx])
})
```

## Impact on Existing Code

This proposal is purely additive and has no impact on existing code.

## Alternatives Considered

* Alternative names discussed include: `enumeratedByIndex`
* Introducing a variant of `makeIterator()`
* Producing a collection instead of a sequence