# Add `MutableCollection.swap(_:with:)`

* Proposal: [SE-0173](0173-swap-indices.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Active review (April 25...28, 2017)**

## Introduction

As part of the introduction of the Law of Exclusivity, the current `swap(_:_:)`
function must be addressed, as this most common uses of `swap` directly violate
the law. This proposal introduces an alternative: a method on
`MutableCollection` that takes two indices for swapping two elements in the
same collection,.

## Motivation

The primary purpose of the current `swap` function is to swap two elements
within a mutable collection. It was originally created to support the sort
algorithm, which is why it is declared in `stdlib/sort.swift.gyb`. Here is
some typical usage from that file:

```swift
  while hi != lo {
    swap(&elements[lo], &elements[hi])
```

Under changes proposed as part of the ownership manfifesto, this will no longer
be legal Swift: a single variable (in this case, `elements`) cannot be passed
as two different `inout` arguments to the same function.

For more background on exclusivity and ownership, see the [manfiesto](https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md)

## Proposed solution

Introduce a new method on `MutableCollection` to the standard library that swaps 
the elements from two indices:

```swift
  while hi != lo {
    elements.swap(lo, with: hi)
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
extension MutableCollection {
  /// Exchange the values at indices `a` and `b`.
  ///
  /// Has no effect when `a` and `b` are equal.
  public mutating func swap(_ i: Index, with b: Index)
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

This is purely additive so should not be source breaking. However, due to
current compiler behavior, it may be necessary to declare a version of the
old `swap` on `MutableCollection` for Swift 3 compatibility purposes. This
version will forward to the free function.

## Effect on ABI stability

None.

## Effect on API resilience

N/A

## Alternatives considered

Instead of `elements.swap(i, with: j)`, the following were considered:

```swift
elements.swap(at: i, j)
elements.swapElements(i, j)
elements.swap(elements: i, j)
```

