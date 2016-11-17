# Commutative operators

* Proposal: [SE-NNNN](NNNN-commutative-operators.md)
* Authors: [Andrey Volodin](https://github.com/s1ddok)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

Swift currently does not allow creating symmetrical (commutative) operators. This proposal suggests to change that.

Swift-evolution thread: [Symmetrical operators](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161107/028803.html)

## Motivation

It is a common task to declare custom operators for some types in Swift. The most often cases are of course math libraries. Most of binary operators are meant to be commutative (`*`, `+`), some are not (`*` for `Matrix/Vector`). Currently it is needed to create two separate operators to ensure commutative feature of a operator.

## Proposed solution

Currently you declare commutative operators like so:

(code examples from our math library, declaring custom Angle struct for type-safety)

```swift
    @inline(__always)
    public static func *(lhs: Angle, rhs: Float) -> Angle {
        return Angle(lhs.degrees * rhs)
    }

    @inline(__always)
    public static func *(lhs: Float, rhs: Angle) -> Angle {
        return Angle(rhs.degrees * lhs)
    }
```

Most of the time you have to write your oprator twice, or proxy one operator to another. This doubles the necessary logic and should be avoided.

The proposed solution is to add `@commutative` attribute. This one should optional, because not everyone needs operator to be commutative (`Matrix * Vector`). All operators should be non-commutative by default.

So that operator can be declared like this:
```swift
    @inline(__always)
    @commutative
    public static func *(lhs: Angle, rhs: Float) -> Angle {
        return Angle(lhs.degrees * rhs)
    }
```

## Source compatibility

This should not affect existing code base as the feature is additive, old code should compile seamlessly.

## Effect on ABI stability

This potentially could break ABI stability when code using the operators which later become commutative.

## Effect on API resilience

API resilience could be reached by keeping the declarations of operators in both directions.
