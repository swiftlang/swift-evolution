# Add an `all` algorithm to `Sequence`

* Proposal: [SE-NNNN](0162-all-algorithm.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

It is common to want to confirm that every element of a sequence equals a
value, or matches a certain criteria. Many implementations of this can be found
in use on github. This proposal adds such a method to `Sequence`.

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

Introduce two algorithms on `Sequence` which test every element and return
`true` if they match:

```swift
nums.all(equal: 9)
nums.all(match: isOdd)
```

## Detailed design

Add the following extensions to `Sequence`:

```swift
extension Sequence {
  /// Returns a Boolean value indicating whether every element of the sequence
  /// satisfies the given predicate.
  func all(match criteria: (Iterator.Element) throws -> Bool) rethrows -> Bool
}

extension Sequence where Iterator.Element: Equatable {
  /// Returns a Boolean value indicating whether every element of the sequence
  /// equals the given element.
  func all(equal element: Iterator.Element) -> Bool
}
```

## Source compatibility

This change is purely additive so has no source compatibility consequences.

## Effect on ABI stability

This change is purely additive so has no ABI stability consequences.

## Effect on API resilience

This change is purely additive so has no API resilience consequences.

## Alternatives considered

Not adding it.

