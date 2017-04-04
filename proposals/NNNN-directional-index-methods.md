# Directional Index Methods

* Proposal: [SE-NNNN](NNNN-directional-index-methods.md)
* Author: [Haravikk](https://github.com/haravikk), Thorsten Seitz
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is for the introduction of direction-specific index methods as counterparts to the direction-specific `.index(after:)` and `.index(before:)` methods.

Swift-evolution thread: [Discussion thread](http://thread.gmane.org/gmane.comp.lang.swift.evolution/19185/focus=19613)

## Motivation

In the current Swift indexing model the `index(before:)` method is not available on non-bidirectional collections, however for offsets greater than one this is not the case, we have a single bidirectional method on all collections, including forward-only types that may have drastically different performance charactertistics for reverse offsets.
The main drawback of this is that it lacks the explicit intent of the before/after methods, and lacks some safety as a result, especially if distances are obtained via the `distance(from:to:)` method using arbitrary indices.

## Proposed solution

The proposed solution is to provide methods that are more direct counterparts of the `index(after:)` and `index(before:)` methods, leaving the bidirectional method for more specialist cases.
This will also be combined with a non-negative (unsigned) distance type, helping to catch errors, while the method choice will clarify exactly the intended offset direction.

## Detailed design

The proposed methods will resemble the following, however naming is very much up for debate:

```
public protocol Collection {
  /// The non-negative distance between indices in a fixed direction
  associatedtype IndexNonNegativeDistance:UnsignedInteger = UInt
  /// - returns: the forward-only distance from `start` to `end`, or `nil` if `end < start`
  func distance(from start:Index, advancedTo end:Index) -> IndexNonNegativeDistance?
  /// Advances an index forward by the specified distance
  func formIndex(_ i:inout Index, advancedBy n:IndexNonNegativeDistance)
  /// Creates a new index advanced forward by the specified distance
  func index(_ i:Index, advancedBy n:IndexNonNegativeDistance) -> Index
}

public protocol BidirectionalCollection : Collection {
  /// - returns: the reverse-only distance from `start` to `end`, or `nil` if `end > start`
  func distance(from start:Index, reversedTo end:Index) -> IndexNonNegativeDistance?
  /// Reverses an index by the specified distance
  func formIndex(_ i:inout Index, reversedBy n:IndexNonNegativeDistance)
  /// Creates a new index reversed by the specified distance
  func index(_ i:Index, reversedBy n:IndexNonNegativeDistance) -> Index
}
```

These methods can then be used for greater clarity of intent, and safety from unexpected negative offsets.

The following example implements a binary search with strictly forward-only offsets avoiding possible mistakes:

```
extension Collection {
  /// Searches for the index nearest to a target as identified by a unary predicate
  /// - returns: the insertion/partitioning index for the predicate (to determine if it was a match, test the returned index for equality if it is less than `.endIndex`)
  func binarySearch(isOrderedBeforeTarget:(Self.Iterator.Element) -> Bool) -> Self.Index {
    var low = self.startIndex, high = self.endIndex
    while low != high {
      let mid = self.index(low, advancedBy: self.distance(from: low, advancedTo: high)! / 2)
      if isOrderedBeforeTarget(self[mid]) { low = self.index(after: mid) }
      else { high = mid }
    }
    return low
  }
}
```

## Impact on existing code

None, this is an additive change. Though it recommends changing to the new methods where possible.

## Alternatives considered

Continue using bidirectional methods that do not clarify intent, or  could hide differing performance characteristics on different types.
