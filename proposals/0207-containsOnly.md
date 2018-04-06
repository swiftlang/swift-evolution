# Add a `containsOnly` algorithm to `Sequence`

* Proposal: [SE-0207](0207-containsOnly.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Dave Abrahams](https://github.com/dabrahams)
* Implementation: [apple/swift#15120](https://github.com/apple/swift/pull/15120)
* Status: **Active review (April 4...13)**

## Introduction

It is common to want to confirm that every element of a sequence equals a
value, or matches certain criteria. Many implementations of this can be found
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
`true` if they all match:

```swift
nums.containsOnly(9)
nums.containsOnly(where: isOdd)
```

on the basis that it aids readability and avoids performance pitfalls from the composed alternatives.

## Detailed design

Add the following extensions to `Sequence`:

```swift
extension Sequence {
  /// Returns a Boolean value indicating whether every element of the sequence
  /// satisfies the given predicate.
  func containsOnly(where predicate: (Element) throws -> Bool) rethrows -> Bool
}

extension Sequence where Element: Equatable {
  /// Returns a Boolean value indicating whether every element of the sequence
  /// equals the given element.
  func containsOnly(_ element: Element) -> Bool
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

Much name bikeshedding has ensued. The primary rival for `containsOnly` is `all`. `containsOnly` is preferred as it is more explicit, and echoes the existing `contains`. Naming it `all` suggests a renaming of `contains` to `any` would be appropriate – but this is already a fairly heavily-used term elsewhere in Swift, and is less explicit.

`contains(only:)` is discounted due to trailing closures dropping the argument label, rendering it indistiguishable from `contains(where:)`.
