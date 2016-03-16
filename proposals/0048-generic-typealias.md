# Generic Type Aliases

* Proposal: [SE-0048: Generic Type Aliases](0048-generic-typealias.md)
* Author: [Chris Lattner](https://github.com/lattner)
* Status: **To be scheduled**
* Review manager: [Doug Gregor](https://github.com/DougGregor)

## Introduction

This proposal aims to add generic typealiases to Swift.

Swift-evolution thread: [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012289.html)

## Motivation

Generic typealiases are an obvious generalization of the existing Swift model
for type aliases, which allow you to provide a name for an existing nominal
generic type, or to provide a name for a non-nominal type (e.g. tuples,
functions, etc) with generic parameters.

## Proposed Solution

The solution solution is straight-forward: allow type aliases to introduce type
parameters, which are in scope for their definition.  This allows one to express
things like:

```swift
typealias StringDictionary<T> = Dictionary<String, T>
typealias IntFunction<T> = (T) -> Int
typealias Vec3<T> = (T, T, T)
typealias BackwardTriple<T1,T2,T3> = (T3, T2, T1)
```

This is consistent with the rest of Swift's approach to generics, and slots
directly into the model.

## Detail Design

This is a minimal proposal for introducing type aliases into Swift, and
intentionally chooses to keep them limited to being "aliases".  As such,
additional constraints are not allowed in this base proposal, e.g. you can't
write:

```swift
typealias StringDictionary<T where T : Hashable> = Dictionary<String, T>
```

If there is a compelling reason to add this, we can consider extending the
model to support them in the future.

Otherwise, generic type aliases follow the model of type aliases and the
precedent of the other generic declarations in Swift.  For example, they allow
the usual access control features that type aliases support.  Similarly, like
non-generic type aliases, generic type aliases cannot be "resilient".

## Impact on existing code

This is a new feature, so there is no impact on existing code.
