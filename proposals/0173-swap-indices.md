# Add `MutableCollection.swapAt(_:_:)`

* Proposal: [SE-0173](0173-swap-indices.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170424/036229.html)
* Implementation: [apple/swift#9119](https://github.com/apple/swift/pull/9119)

## Introduction

As part of the introduction of the Law of Exclusivity, the current `swap(_:_:)`
function must be addressed, as this most common uses of `swap` directly violate
the law. This proposal introduces an alternative: a method on
`MutableCollection` that takes two indices for swapping two elements in the
same collection.

## Motivation

The primary purpose of the current `swap` function is to swap two elements
within a mutable collection. It was originally created to support the sort
algorithm, which is why it is declared in `stdlib/sort.swift.gyb`. Here is
some typical usage from that file:

```swift
  while hi != lo {
    swap(&elements[lo], &elements[hi])
```

Under changes proposed as part of the ownership manifesto, this will no longer
be legal Swift: a single variable (in this case, `elements`) cannot be passed
as two different `inout` arguments to the same function.

For more background on exclusivity and ownership, see the [manifesto](https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md)

## Proposed solution

Introduce a new method on `MutableCollection` to the standard library that swaps 
the elements from two indices:

```swift
  while hi != lo {
    elements.swapAt(lo, hi)
```

As well as resolving the conflict with the proposed language change, this
appears to improve readability.

Existing usage on two elements in a collection will need to be migrated to the
new method.

While `swap` was only intended to be used on collections, it is possible to use
it on other variables. However, the recommended style for these uses is to not
use a function at all:

```swift
var a = 0
var b = 1

swap(&a,&b)
// can be rewritten as:
(a,b) = (b,a)
```

The existing `swap` method will remain, as under some circumstances it may
result in a performance gain, particularly if move-only types are introduced
in a later release.

## Detailed design

Add the following method to the standard library:

```swift
protocol MutableCollection {
  /// Exchange the values at indices `i` and `j`.
  ///
  /// Has no effect when `i` and `j` are equal.
  public mutating func swapAt(_ i: Index, _ j: Index)
}
```

The current `swap` is required to `fatalError` on attempts to swap an element
with itself for implementation reasons. This pushes the burden to check this
first onto the caller. While swapping an element with itself is often a logic
errror (for example, in a `sort` algorithm where you have a fenceposts bug), it
is occasionally a valid situation (for example, it can occur easily in an
implementation of `shuffle`). This implementation removes the precondition.

Deprecate the existing `swap`, and obsolete it in a later version of Swift.

## Source compatibility

This is purely additive so should not be source breaking.

## Effect on ABI stability

None.

## Effect on API resilience

N/A

## Alternatives considered

A number of possible alternative names for this method were considered:

```swift
elements.swap(i, with: j)
elements.swap(at: i, j)
elements.swapElements(i, j)
elements.swap(elements: i, j)
```

`elements.swapAt(i, with: j)` was chosen on the basis of it reading most fluently, combined with adhering to the relevant parts of the naming guidelines:

> "Omit all labels when arguments can’t be usefully distinguished”
 
and:

> "When the first argument forms part of a prepositional phrase, give it an argument label...An exception arises when the first two arguments represent parts of a single abstraction….In such cases, begin the argument label after the preposition, to keep the abstraction clear."


