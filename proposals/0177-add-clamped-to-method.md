# Add clamp(to:) to the stdlib

* Proposal: [SE-0177](0177-add-clamped-to-method.md)
* Authors: [Nicholas Maccharoli](https://github.com/Nirma)
* Review Manager: TBD
* Status: **Returned for revision**

## Introduction

This proposal aims to add functionality to the standard library for clamping a value to a provided `Range`.
The proposed function would allow the user to specify a range to clamp a value to where if the value fell within the range, the value would be returned as is, if the value being clamped exceeded the upper or lower bound then the upper or lower bound would be returned respectively.

Swift-evolution thread: [Add a `clamp` function to Algorithm.swift](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170306/thread.html#33674)

## Motivation

There have been quite a few times in my professional and personal programming life where I reached for a function to limit a value to a given range and was disappointed that it was not part of the standard library.

There already exists an extension to `CountableRange` in the standard library  implementing `clamped(to:)` that will limit the calling range to that of the provided range, so having the same functionality but just for types that conform to the `Comparable` protocol would be conceptually consistent.

Having functionality like `clamped(to:)` added to `Comparable` as a protocol extension would benefit users of the Swift language who wish
to guarantee that a value is kept within bounds, perhaps one example of this coming in handy would be to limit the result of some calculation between two acceptable numerical limits, say the bounds of a coordinate system.

## Proposed solution

The proposed solution is to add a `clamped(to:)` function to the Swift Standard Library as an extension to `Comparable` and to `Strideable`.
The function would return a value within the bounds of the provided range, if the value `clamped(to:)` is being called on falls within the provided range then the original value would be returned.
If the value was less or greater than the bounds of the provided range then the respective lower or upper bound of the range would be returned.

Clamping on an empty range simply returns the value clamped to the `lowerBound` / `upperBound` of the `Range` no different from clamping on a non-empty range.

Given a `clamped(to:)` function existed it could be called in the following way, yielding the results in the adjacent comments:

```swift
// Closed range variant

100.clamped(to: 0...50) // 50
100.clamped(to: 200...300) // 200
100.clamped(to: 0...150) // 100

// Half-Open range variant

100.clamped(to: 0..<50) // 49
100.clamped(to: 200..<300) // 200
100.clamped(to: 0..<150) // 100
100.clamped(to: 42..<42) // 42
```

## Detailed design

The implementation of `clamped(to:)` that is being proposed is composed of two protocol extensions; one protocol extension on `Comparable` and another on `Strideable`.

The implementation for `clamped(to:)` as an extension to `Comparable` accepting a range of type `ClosedRange<Self>` would look like the following:

```swift
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        if self > range.upperBound {
            return range.upperBound
        } else if self < range.lowerBound {
            return range.lowerBound
        } else {
            return self
        }
    }
}
```

The implementation of `clamped(to:)` as an extension on `Strideable` would be confined to cases where the stride is of type `Integer`.
The implementation would be as follows:

```swift
extension Strideable where Stride: Integer {
    func clamped(to range: Range<Self>) -> Self {
        let clampRange: ClosedRange<Self>

        if range.lowerBound == range.upperBound {
            clampRange = range.lowerBound...range.upperBound
        } else {
            clampRange = range.lowerBound...(range.upperBound - 1)
        }

        return clamped(to: clampRange)
    }
}
```

## Source compatibility

This feature is purely additive; it has no effect on source compatibility.

## Effect on ABI stability

This feature is purely additive; it has no effect on ABI stability.

## Effect on API resilience

The proposed function would become part of the API but purely additive.

## Alternatives considered

Aside from doing nothing, no other alternatives were considered.
