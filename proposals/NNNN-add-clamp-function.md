# Add clamp(to:) to the stdlib

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Nicholas Maccharoli](https://github.com/Nirma)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

This proposal aims to add functionality to the standard library for clamping a value to a `ClosedRange`.
The proposed function would allow the user to specify a range to clamp a value to where if the value fell within the range, the value would be returned as is, if the value being clamped exceeded the upper or lower bound in value the value of the boundary the value exceeded would be returned.   

Swift-evolution thread: [Add a `clamp` function to Algorithm.swift](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170306/thread.html#33674)

## Motivation

There have been quite a few times in my professional and personal programming life where I reached for a `clamped` function and was disappointed it was not part of the standard library.

Having functionality like `clamped(to:)` added to `Comparable` as a protocol extension would benefit users of the Swift language who wish
to guarantee that a value is kept within bounds.

## Proposed solution

The solution proposed is simply that there be a `clamped(to:)` function added to the Swift Standard Library.
The function would behave much like its name describes.

Given a `clamped(to:)` function existed it could be called in the following way, yielding the results in the adjacent comments:

```swift
var foo = 100

// Closed range variant

foo.clamped(to: 0...50) // 50
foo.clamped(to: 200...300) // 200
foo.clamped(to: 0...150) // 100

// Half-Open range variant

foo.clamped(to: 0..<50) // 49
foo.clamped(to: 200..<300) // 200
foo.clamped(to: 0..<150) // 100
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
        return clamped(to: range.lowerBound...(range.upperBound - 1))
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
