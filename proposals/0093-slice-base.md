# Adding a public `base` property to slices

* Proposal: [SE-0093](0093-slice-base.md)
* Author: [Max Moiseev](https://github.com/moiseev)
* Review Manager: [Dave Abrahams](https://github.com/dabrahams)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160523/019109.html)
* Implementation: [apple/swift#2929](https://github.com/apple/swift/pull/2929)

## Introduction

Slice types [provided by the standard library](https://github.com/apple/swift/blob/master/stdlib/public/core/Slice.swift.gyb) should allow public readonly access to their base collections to make efficient implementations of protocol requirements possible in conforming types.

## Motivation

The `MutableCollection` protocol conformance requires providing an implementation of the following subscript:

```swift
subscript(bounds: Range<Index>) -> SubSequence { get set }
```

If the collection chooses to use one of a variety of slice types from the standard library as its `SubSequence`, the default implementation of a setter for this subscript will use the algorithm provided by the [`_writeBackMutableSlice`](https://github.com/apple/swift/blob/master/stdlib/public/core/WriteBackMutableSlice.swift) function. This approach is fine for forward collections. It is quite possible, however, that the most efficient implementation of this setter would be to simply call the `memcpy` function. Unfortunately, slice API does not provide any way to reach to the underlying base collection, even though reference to it is stored in an internal property.


## Proposed solution

We propose to export a public readonly property `base`, that will enable optimizations mentioned above. Here is how `MutableRandomAccessSlice` definition would look like:

```swift
public struct MutableRandomAccessSlice<
  Base : protocol<RandomAccessIndexable, MutableIndexable>
> : RandomAccessCollection, MutableCollection {

  /// The underlying collection of the slice
  public var base: Base { get }
}
```

The same change is applicable to both mutable and immutable slice types.


## Impact on existing code

The proposed change is purely additive and does not affect existing code.

## Alternatives considered

An alternative for the immutable slices would be to simply rename the already read-only `_base` property to `base` and make it public, but this way the change is not purely additive and might cause some damage inside the standard library code.
