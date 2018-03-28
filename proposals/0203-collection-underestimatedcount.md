# Require `Sequence.underestimatedCount` be O(1)

* Proposal: [SE-0203](0203-collection-underestimatedcount.md)
* Authors: [Max Moiseev](https://github.com/moiseev)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Evolution pitch: [Require Sequence.underestimatedCount be O(1)][pitch]

<!--
*During the review process, add the following fields as needed:*
-->

* Implementation: [apple/swift#14994][impl]

<!--
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

Currently the `underestimatedCount` property requirement of the `Sequence`
protocol has the following complexity definition:

```swift
/// - Complexity: O(1), except if the sequence also conforms to `Collection`.
///   In this case, see the documentation of `Collection.underestimatedCount`.
```

The `Collection` exception makes this API not very useful for generic algorithms
over `Sequence`, where there is no static knowledge of other conformances.

Swift-evolution thread: [Require Sequence.underestimatedCount be O(1)][pitch]

## Motivation

The `underestimatedCount` property, as name suggests, is meant to be a way of
obtaining the approximate number of elements in a `Sequence`, and intended to be
used as an optimization to, for example, pre-allocate capacity for its elements.
One use case can be found in the implementation of
[`RangeReplaceableCollection.append(contentsOf:)`][contentsOf].

With the complexity guarantees of `underestimatedCount` as they are stated now,
this will no longer be an optimization, and `append(contentsOf:)` would iterate
over its argument twice in some cases.

In order to statically guarantee the constant time complexity of
`underestimatedCount`, generic algorithms should be constrained to
`RandomAccessCollection` instead of `Sequence`, which unnecessarily narrows the
scope of their application. Take, for example, `String` or `Set` which don't
conform to `RandomAccessCollection`, but are perfectly fine `Sequence`s.

## Proposed solution

We propose to change the complexity guarantee of `Sequence.underestimatedCount`
to be unconditionally O(1).

## Detailed design

Apart from an obvious code comment/documentation change, there are a few changes
to the standard library code that need to be made.

First of all the default implementation of `Collection.underestimatedCount`,
which now simply returns `count` and thus can take linear time, need to be
replaced by the following:

```swift
extension Collection {
  public var underestimatedCount: Int { return 0 }
}

extension RandomAccessCollection {
  public var underestimatedCount: Int { return count }
}
```

Other collection types that don't conform to `RandomAccessCollection` but whose
`count` property is O(1) should override `underestimatedCount` to return `count`
as well. Here is the list of such types:

* `Dictionary`
* `Dictionary.Keys`
* `Dictionary.Values`
* `Words` for all the integer types
* `ReversedCollection`
* `Set`

According to the audit of the standard library types performed as part of
[implementing this proposal][impl], other
collection types either conform to `RandomAccessCollection` or already overide
`underestimatedCount`.

## Source compatibility

The proposed change is source compatible, as it does not remove/change/add any
new APIs. It can change the performance of some generic algorithms that used
`underestimatedCount` as an optimization, however the time complexity of said
algorithms will only become worse by a small constant factor.

## Effect on ABI stability

This proposal does not affect ABI.

## Effect on API resilience

This proposal does not change the API.

## Alternatives considered

During the evolution discussion it was proposed to modify the default
implementation of `Collection.underestimatedCount` as following:

```swift
extension Collection {
  public var underestimatedCount: Int { return isEmpty ? 0 : 1 }
}
```

We believe this would only result in only marginally better performance (in the
case of `RangeReplaceableCollection.append(contentsOf:)` it will potentially
reduce the number of allocations by 1). On the other hand, since it invokes
`isEmpty` that is also a protocol requirement, and can have a non-linear
implementation, it can easily violate the requirement being established by this
very proposal. Besides, being an *under*-estimate, 1 is not better than 0.

[pitch]:
https://forums.swift.org/t/require-sequence-underestimatedcount-be-o-1/10613
[contentsOf]:
https://github.com/apple/swift/blob/master/stdlib/public/core/RangeReplaceableCollection.swift#L442-L451
[impl]: https://github.com/apple/swift/pull/14994