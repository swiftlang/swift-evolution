# Add integral rounding functions to FloatingPoint

* Proposal: [SE-0113](0113-rounding-functions-on-floatingpoint.md)
* Author: [Karl Wagner](https://github.com/karwa)
* Status: **Accepted** ([Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000217.html))
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction, Motivation

The standard library lacks equivalents to the `floor()` and `ceil()` functions found in the standard libraries of most other languages. Currently, we need to import `Darwin` or `Glibc` in order to access the C standard library versions.

In general, rounding of floating-point numbers for predictable conversion in to integers is something we should provide natively.

Swift-evolution initial discussion thread: [\[Proposal\] Add floor() and ceiling() functions to FloatingPoint
](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/022146.html)

## Proposed Solution

The proposed rounding API consists of a `RoundingRule` enum and new `round` and `rounded` methods on `FloatingPoint`


```swift

/// Describes a rule for rounding a floating-point number.
public enum FloatingPointRoundingRule {

  /// The result is the closest allowed value; if two values are equally close,
  /// the one with greater magnitude is chosen.  Also known as "schoolbook
  /// rounding".
  case toNearestOrAwayFromZero

  /// The result is the closest allowed value; if two values are equally close,
  /// the even one is chosen.  Also known as "bankers rounding".
  case toNearestOrEven

  /// The result is the closest allowed value that is greater than or equal
  /// to the source.
  case up

  /// The result is the closest allowed value that is less than or equal to
  /// the source.
  case down

  /// The result is the closest allowed value whose magnitude is less than or
  /// equal to that of the source.
  case towardZero

  /// The result is the closest allowed value whose magnitude is greater than
  /// or equal to that of the source.
  case awayFromZero
}
	
protocol FloatingPoint {

    ...
    
    /// Returns a rounded representation of `self`, according to the specified rounding rule.
    func rounded(_ rule: RoundingRule = toNearestOrAwayFromZero) -> Self

    /// Mutating form of `rounded`
    mutating func round(_ rule: RoundingRule = toNearestOrAwayFromZero)
}
```

Calls such as `rounded(.up)` or `rounded(.down)` are equivalent to C standard library `ceil()` and `floor()` functions.
- `(4.4).rounded() == 4.0`
- `(4.5).rounded() == 5.0`
- `(4.0).rounded(.up) == 4.0`
- `(4.0).rounded(.down) == 4.0`

Note: the rounding rules in the `RoundingRule` enum correspond to those in IEEE 754.

## Impact on existing code

This change is additive, although we may consider suppressing the imported, global-level C functions, or perhaps automatically migrating them to the new instance-method calls.

## Alternatives considered

* `floor()` and `ceiling()`. The mailing list discussion indicated more nuanced forms of rounding were desired, and that it would be nice to abandon these technical names for what is a pretty common operation.
* `floor()` and `ceil()` or `ceiling()` are [mathematical terms of art](http://mathworld.wolfram.com/CeilingFunction.html). But most people who want to round a floating point are not mathematicians.
* `nextIntegralUp()` and `nextIntegralDown()` are more descriptive, and perhaps a better fit with the rest of the `FloatingPoint` API, but possibly misleading as `(4.0).nextIntegralUp() == 4.0`

## Changes introduced in implementation
* `RoundingRule` was renamed `FloatingPointRoundingRule`, based on a suggestion from the standard library team.  We may want to introduce rounding operations that operate on other types in the future, and they may not want the same set of rules.  Also, this type name will be very rarely used, so a long precise typename doesn't add burden.
* Added `.awayFromZero`, which is trivial to implement and was requested by several people during the review period.

