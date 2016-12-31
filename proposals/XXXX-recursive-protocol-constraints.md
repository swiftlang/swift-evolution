# Support recursive constraints on associated types

* Proposal: [SE-NNNN](XXXX-recursive-protocol-constraints.md)
* Authors: [Douglas Gregor](https://github.com/DougGregor), Austin Zheng
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

Swift supports defining _associated types_ on protocols. It also supports defining _constraints_ on those associated types. However, Swift does not currently support defining _constraints that recursively reference the enclosing type_ on an associated type. We propose this restriction be lifted.

More specifically, we propose that **associated type constraints should be able to reference the enclosing protocol, or any protocol descended from the enclosing protocol.**

Further reading: [swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161107/028805.html)

## Motivation

Consider Swift's `Sequence` protocol:

```swift
protocol Sequence {
	associatedtype SubSequence

	// Returns a subsequence containing all but the first 'n' items
	// in the original sequence.
	func dropFirst(_ n: Int) -> Self.SubSequence
}
```

It would make sense for `SubSequence` to be constrained to be a `Sequence` as well, since all subsequences are themselves sequences. In particular, a concrete type conforming to `Sequence` might want to implement `dropFirst()` in such a way that it returns a different type of sequence, perhaps for performance reasons.

However, Swift currently disallows this behavior. Instead of explicitly specifying the "`SubSequence` must itself be a `Sequence`" requirement at the point where `SubSequence` is declared, we must specify it at each site of use instead. This results in more verbose code and obscures our intent.

For additional context, please consult the [Completing Generics document](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#recursive-protocol-constraints-).

## Proposed solution

The first part of the solution we propose is to lift this restriction. This is a very simple change from the perspective of the end user. It is only a new feature in the sense that certain associated type definitions which were previously disallowed will now be accepted by the compiler.

Implementation details regarding recursive protocol constraints can be found in [this document](https://gist.github.com/DougGregor/e7c4e7bb4465d6f5fa2b59be72dbdba6).

The second part of the solution involves updating the standard library to take advantage of the removal of this restriction. Such changes are made with [SE-0142](https://github.com/apple/swift-evolution/blob/master/proposals/0142-associated-types-constraints.md) in mind, and incorporate both recursive constraints and `where` clauses. The changes necessary for this are described in the _Detailed Design_ section below.

## Detailed design

The following standard library types and protocols will be removed:

* `_BidirectionalIndexable`
* `_Indexable`
* `_IndexableBase`
* `_MutableIndexable`
* `_RandomAccessIndexable`
* `_RangeReplaceableIndexable`

The following standard library protocols and types will change.

Note that since the specific collection types inherit from `Collection`, and `Collection` inherits from `Sequence`, not all the constraints need to be defined on every collection-related associated type.

Default values of all changed associated types remain the same, unless explicitly noted otherwise.

### `Any*Collection` (all variants)

* Remove all `C.Subsequence` and `C.Indices` constraints from public `init`

### `Arithmetic`

* Change associated type: `associatedtype Magnitude : Arithmetic`

### `BidirectionalCollection`

* Remove conformance to `_BidirectionalIndexable`
* Change associated type: `associatedtype SubSequence : BidirectionalCollection`
* Change associated type: `associatedtype Indices : BidirectionalCollection`

### `Collection`

* Remove conformance to `_Indexable`
* Change associated type: `associatedtype SubSequence : Collection where SubSequence.Index == Index, SubSequence.Indices == Indices`
* Change associated type: `associatedtype Indices : Collection where Indices.Iterator.Element == Index, Indices.Index == Index, Indices.SubSequence == Indices`

### `Default*Indices` (all variants)

* Declarations changed to `public struct Default*Indices<Elements : *Collection> : *Collection`

### `IndexingIterator`

* Declaration changed to `public struct IndexingIterator<Elements : Collection> : IteratorProtocol, Sequence`

### `LazyFilter*Collection` (all variants)

* Add default associated type conformance: `typealias SubSequence = ${Self}<Base.SubSequence>`

### `LazyMap*Collection` (all variants)

* Add default associated type conformance: `typealias SubSequence = ${Self}<Base.SubSequence>`

### `Mirror`

* Remove all `C.Subsequence` and `C.Indices` constraints from `init<Subject, C : Collection>(_ subject: Subject, children: C, displayStyle: DisplayStyle?, ancestorRepresentation: AncestorRepresentation)`
* Remove all `C.Subsequence` and `C.Indices` constraints from `init<Subject, C : Collection>(_ subject: Subject, unlabeledChildren: C, displayStyle: DisplayStyle?, ancestorRepresentation: AncestorRepresentation)`

### `MutableCollection`

* Change associated type: `associatedtype SubSequence : MutableCollection`

### `RandomAccessCollection`

* Change associated type: `associatedtype SubSequence : RandomAccessCollection`
* Change associated type: `associatedtype Indices : RandomAccessCollection`

### `RangeReplaceableCollection`

* Change associated type: `associatedtype SubSequence : RangeReplaceableCollection`

### `Sequence`

* Change associated type: `associatedtype SubSequence : Sequence where Iterator.Element == SubSequence.Iterator.Element, SubSequence.SubSequence == SubSequence`

### `*Slice` (all variants)

* Add default associated type conformance: `typealias Indices = Base.Indices`

## Source compatibility

From a source compatibility perspective, this is a purely additive change if the user's code is correctly written. It is possible that users may have written code which defines semantically incorrect associated types, which the compiler now rejects because of the additional constraints. We do not consider this scenario "source-breaking".

## Effect on ABI stability

Since this proposal involves modifying the standard library, it changes the ABI. In particular, ABI changes enabled by this proposal are critical to getting the standard library to a state where it more closely resembles the design envisioned by its engineers.

## Effect on API resilience

This feature cannot be removed without breaking API compatibility, but since it forms a necessary step in crystallizing the standard library for future releases, it is very unlikely that it will be removed after being accepted.

## Alternatives considered

n/a
