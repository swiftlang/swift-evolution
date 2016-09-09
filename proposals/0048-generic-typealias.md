# Generic Type Aliases

* Proposal: [SE-0048](0048-generic-typealias.md)
* Author: [Chris Lattner](https://github.com/lattner)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000098.html)


## Introduction

This proposal aims to add generic typealiases to Swift.

Swift-evolution thread: [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012289.html)

## Motivation

Generic typealiases are an obvious generalization of the existing Swift model
for type aliases, which allow you to provide a name for an existing nominal
generic type, or to provide a name for a non-nominal type (e.g. tuples,
functions, etc) with generic parameters.

## Proposed Solution

The solution is straight-forward: allow type aliases to introduce type
parameters, which are in scope for their definition.  This allows one to express
things like:

```swift
typealias StringDictionary<T> = Dictionary<String, T>
typealias DictionaryOfStrings<T : Hashable> = Dictionary<T, String>
typealias IntFunction<T> = (T) -> Int
typealias Vec3<T> = (T, T, T)
typealias BackwardTriple<T1,T2,T3> = (T3, T2, T1)
```

This is consistent with the rest of Swift's approach to generics, and slots
directly into the model.

## Detail Design

This is a minimal proposal for introducing type aliases into Swift, and
intentionally chooses to keep them limited to being "aliases".  These aliases
are required to declare the constraints of the aliasee (e.g. the 
`DictionaryOfStrings` example above redeclares the Hashable constraint) to make
the requirements of the declaration obvious.  Leaving off the constraint would
produce the expected error (potentially with a Fixit hint to add it):

```swift
typealias DictionaryOfStrings<T>  = Dictionary<T, String>
  // error: type 'T' does not conform to protocol 'Hashable'
```

However, because this proposal is targeted at supporting aliases, it does not
allow *additional* constraints to be added to type parameters.  For example, you
can't write:

```swift
typealias ComparableArray<T where T : Comparable> = Array<T>
```

If there is a compelling reason to add this, we can consider extending the
model to support them in the future, based on the merits of those reasons.

Otherwise, generic type aliases follow the model of type aliases and the
precedent of the other generic declarations in Swift.  For example, they allow
the usual access control features that type aliases support.  Similarly, like
non-generic type aliases, generic type aliases cannot be "resilient".

## Impact on existing code

This is a new feature, so there is no impact on existing code.
