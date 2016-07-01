# Add integral rounding functions to FloatingPoint

* Proposal: [SE-0113](0113-rounding-functions-on-floatingpoint.md)
* Author: [Karl Wagner](https://github.com/karwa)
* Status: **Active review June 30 ... July 5**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction, Motivation

The standard library lacks equivalents to the `floor()` and `ceil()` functions found in the standard libraries of most other languages. Currently, we need to import `Darwin` or `Glibc` in order to access the C standard library versions.

In general, rounding of floating-point numbers for predictable conversion in to integers is something we should provide natively.

Swift-evolution initial discussion thread: [\[Proposal\] Add floor() and ceiling() functions to FloatingPoint
](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/022146.html)

## Proposed Solution

The proposed rounding API consists of a `RoundingRule` enum and new `round` and `rounded` methods on `FloatingPoint`


```swift

/// Describes a rule for rounding to an integral value.
enum RoundingRule {
	/// The result is the closest representable integral value; if two values are equally close, the one with greater magnitude is chosen.
	case toNearestOrAwayFromZero
	/// The result is the closest representable integral value; if two values are equally close, the even one is chosen.
	case toNearestOrEven
	/// The result is the closest representable integral value greater than or equal to the source.
	case up
	/// The result is the closest representable integral value less than or equal to the source.
	case down
	/// The result is the closest representable integral value whose magnitude is less than or equal to that of the source.
	case towardZero
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

## Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
