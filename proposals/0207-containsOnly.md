# Add an `allSatisfy` algorithm to `Sequence`

* Proposal: [SE-0207](0207-containsOnly.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Dave Abrahams](https://github.com/dabrahams)
* Implementation: [apple/swift#15120](https://github.com/apple/swift/pull/15120)
* Status: **Implemented (Swift 4.2)**
* Decision Notes: [Rationale](https://forums.swift.org/t/se-0207-add-a-containsonly-algorithm-to-sequence/11686/102)

## Introduction

It is common to want to confirm that every element of a sequence equals a
value, or matches certain criteria. Many implementations of this can be found
in use on GitHub. This proposal adds such a method to `Sequence`.

## Motivation

You can achieve this in Swift 3 with `contains` by negating both the criteria
and the result:

```swift
// every element is 9
!nums.contains { $0 != 9 }
// every element is odd
!nums.contains { !isOdd($0) }
```

but these are a readability nightmare. Additionally, developers may not make
the leap to realize `contains` can be used this way, so may hand-roll their own
`for` loop, which could be buggy, or compose other inefficient alternatives:

```swift
// misses opportunity to bail early
nums.reduce(true) { $0.0 && $0.1 == 9 }
// the most straw-man travesty I could think of...
Set(nums).count == 1 && Set(nums).first == 9
```

## Proposed solution

Introduce an algorithm on `Sequence` which tests every element and returns
`true` if they all match a given predicate:

```swift
nums.allSatisfy(isOdd)
```

on the basis that it aids readability and avoids performance pitfalls from the composed alternatives.

## Detailed design

Add the following extensions to `Sequence`:

```swift
extension Sequence {
  /// Returns a Boolean value indicating whether every element of the sequence
  /// satisfies the given predicate.
  func allSatisfy(_ predicate: (Element) throws -> Bool) rethrows -> Bool
}
```

## Source compatibility

This change is purely additive so has no source compatibility consequences.

## Effect on ABI stability

This change is purely additive so has no ABI stability consequences.

## Effect on API resilience

This change is purely additive so has no API resilience consequences.

## Alternatives considered

Not adding it, since it can be trivially (if confusingly) composed.

Much name bikeshedding has ensued. Names considered included `containsOnly` and `all`. `all` has strong precedent in other languages, but was considered unclear at the call site (adding an argument label does not help here given trailing closures omit them). Naming it `all` suggests a renaming of `contains` to `any` would be appropriate – but this is already a fairly heavily-used term elsewhere in Swift, and is less explicit. `containsOnly` is more explicit, and echoes the existing `contains`, but is too easily misread at the use-site as “contains one instance equal to,” especially when considering empty collections. `contains(only:)` was discounted due to trailing closures dropping the argument label, rendering it indistinguishable from `contains(where:)`.
