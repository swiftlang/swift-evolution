# Replace `protocol<P1,P2>` syntax with `P1 & P2` syntax

* Proposal: [SE-0095](0095-any-as-existential.md)
* Authors: [Adrian Zubarev](https://github.com/DevAndArtist), [Austin Zheng](https://github.com/austinzheng)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000198.html)
* Bug: [SR-1938](https://bugs.swift.org/browse/SR-1938)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/a4356fee94c06181715fad83aa61e923eb73f8ec/proposals/0095-any-as-existential.md)

## Introduction

The current `protocol<>` construct, which defines an existential type consisting of zero or more protocols, should be replaced by an infix `&` type operator joining bare protocol type names.

Discussion threads: 
[pre-proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/018109.html), 
[review thread 1](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/021713.html),
[return for revision thread](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000182.html)

## Motivation

A stated goal for Swift 3.0 is making breaking changes to prepare the way for features to be introduced in future features, especially those involving the enhancements to the generics system detailed in [*Completing Generics*](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md).

One such change described in *Completing Generics* is improving the existing `protocol<>` syntax in order to allow it to serve as a syntactic foundation for more generalized existential types. This is a straightforward change which will allow a later version of Swift to introduce better handling for existential types without making breaking changes, or changes whose functionality overlaps with that of existing features.

## Proposed solution

The `protocol<...>` construct should be removed. In its place, an infix type operator `&` will be introduced.

An existential type comprised of more than one protocol will be defined by listing its types, separated by the `&` operator, as shown below in the examples.

The existing `Any` typealias, which represents all types that conform to zero or more protocols (i.e. all types), will become a keyword. Its meaning will not change.

Trivial example:

```swift
protocol A { }
protocol B { }
protocol C { }

struct Foo : A, B, C { }

let a : A & B & C = Foo()
```

Example with functions:

```swift
protocol A { }
protocol B { }

// Existential
func firstFunc(x: A & B) { ... }

// Generic
func secondFunc<T : A & B>(x: T) { ... }
```

The use of `&` instead of `,` more clearly conveys the intent of the syntactic construct: defining a composite type formed from the conjunction of two or more protocol types.

## Impact on existing code

Programmers will need to update any code using `protocol<...>`. Code that uses `Any`, but no protocol composition, will be unaffected. Code that happens to use `protocol<>` must be changed to use `Any` instead.

## Future directions

Whenever a [generalized existential](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#generalized-existentials) proposal is prepared, the syntax established by this proposal can be extended as appropriate to cover additional functionality (such as `where` clauses).

## Alternatives considered

The original proposal suggested replacing `protocol<>` with either `Any<>` or `any<>`.

## Acknowledgements

[Matthew Johnson](https://github.com/anandabits) and [Brent Royal-Gordon](https://github.com/brentdax) provided valuable input which helped shape the first version of this proposal.

