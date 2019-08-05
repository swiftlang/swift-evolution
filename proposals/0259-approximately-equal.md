# Approximate Equality for Floating Point

* Proposal: [SE-0259](0259-approximately-equal.md)
* Author: [Stephen Canon](https://github.com/stephentyrone)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Returned for revision**
* Implementation: [apple/swift#23839](https://github.com/apple/swift/pull/23839)

## Introduction

The internet is full advice about what not to do when comparing floating-point values:

- "Never compare floats for equality."
- "Always use an epsilon."
- "Floating-point values are always inexact."

Much of this advice is false, and most of the rest is technically correct but misleading.
Almost none of it provides specific and correct recommendations for what you *should*
do if you need to compare floating-point numbers.

There is no uniformly correct notion of "approximate equality", and there is no uniformly
correct tolerance that can be applied without careful analysis, but we can define
approximate equality functions that are better than what most people will come up with
without assistance from the standard library.

Pitch thread: [Approximate equality for floating-point](https://forums.swift.org/t/approximate-equality-for-floating-point/22420)

## Motivation

Almost all floating-point computations incur rounding error, and many additionally need
to account for model errors (numerical solutions for physical problems are often best
analyzed as solving a *related* equation exactly, rather than approximately solving the
original equation, for example). Because of this, it is frequently desirable to consider two
results to be equivalent if they are equal within an approximate tolerance.

However, people tend to blindly apply this notion without careful analysis, and without
much understanding of the mechanics of floating-point. This leads to a lot of C-family
code that looks like:
```C
if (fabs(x - y) < DBL_EPSILON) {
  // equal enough!
}
```
This is almost surely incorrect, however. One of the key features of floating-point arithmetic
is *scale invariance*, which means that comparing with an *absolute* tolerance will
essentially always be incorrect. Further, in the most likely scaling (x and y are both of
roughly unit scale), the tolerance `DBL_EPSILON` is *far* too small for any nontrivial
computation.

Even though these are relatively simple things to account for, people get them wrong more
often than they get them right, so it's a great opportunity for the standard library to help
improve software quality with a small well-considered API.

## Proposed solution
```Swift
if x.isAlmostEqual(to: y) {
  // equal enough!
}
```
This predicate is reflexive (except for NaN, like all floating-point comparisons) and
symmetric (many implementations of approximately equality you'll find on the internet
are not, which sets people up for hard to find bugs or broken tests). It gracefully handles
subnormal numbers in the only sensible fashion possible, and uses a tolerance that is
acceptable for most computations. For cases that want to manually specify another
tolerance, we have:
```Swift
if x.isAlmostEqual(to: y, tolerance: 0.001) {
  // equal enough!
}
```
Both of the aforementioned functions use a *relative* tolerance. There is a single value
for which that's unsuitable--comparison with zero (because no number will ever
compare equal to zero with a sensible relative tolerance applied). To address this, we
provide one additional function:
```Swift
if x.isAlmostZero( ) {
  // zero enough!
}
```
## Detailed design
```swift
extension FloatingPoint {
  /// Test approximate equality with relative tolerance.
  ///
  /// Do not use this function to check if a number is approximately
  /// zero; no reasoned relative tolerance can do what you want for
  /// that case. Use `isAlmostZero` instead for that case.
  ///
  /// The relation defined by this predicate is symmetric and reflexive
  /// (except for NaN), but *is not* transitive. Because of this, it is
  /// often unsuitable for use for key comparisons, but it can be used
  /// successfully in many other contexts.
  ///
  /// The internet is full advice about what not to do when comparing
  /// floating-point values:
  ///
  /// - "Never compare floats for equality."
  /// - "Always use an epsilon."
  /// - "Floating-point values are always inexact."
  ///
  /// Much of this advice is false, and most of the rest is technically
  /// correct but misleading. Almost none of it provides specific and
  /// correct recommendations for what you *should* do if you need to
  /// compare floating-point numbers.
  ///
  /// There is no uniformly correct notion of "approximate equality", and
  /// there is no uniformly correct tolerance that can be applied without
  /// careful analysis. This function considers two values to be almost
  /// equal if the relative difference between them is smaller than the
  /// specified `tolerance`.
  ///
  /// The default value of `tolerance` is `sqrt(.ulpOfOne)`; this value
  /// comes from the common numerical analysis wisdom that if you don't
  /// know anything about a computation, you should assume that roughly
  /// half the bits may have been lost to rounding. This is generally a
  /// pretty safe choice of tolerance--if two values that agree to half
  /// their bits but are not meaningfully almost equal, the computation
  /// is likely ill-conditioned and should be reformulated.
  ///
  /// For more complete guidance on an appropriate choice of tolerance,
  /// consult with a friendly numerical analyst.
  ///
  /// - Parameters:
  ///   - other: the value to compare with `self`
  ///   - tolerance: the relative tolerance to use for the comparison.
  ///     Should be in the range (.ulpOfOne, 1).
  ///
  /// - Returns: `true` if `self` is almost equal to `other`; otherwise
  ///   `false`.
  @inlinable
  public func isAlmostEqual(
    to other: Self,
    tolerance: Self = Self.ulpOfOne.squareRoot()
  ) -> Bool {
    // tolerances outside of [.ulpOfOne,1) yield well-defined but useless results,
    // so this is enforced by an assert rathern than a precondition.
    assert(tolerance >= .ulpOfOne && tolerance < 1, "tolerance should be in [.ulpOfOne, 1).")
    // The simple computation below does not necessarily give sensible
    // results if one of self or other is infinite; we need to rescale
    // the computation in that case.
    guard self.isFinite && other.isFinite else {
      return rescaledAlmostEqual(to: other, tolerance: tolerance)
    }
    // This should eventually be rewritten to use a scaling facility to be
    // defined on FloatingPoint suitable for hypot and scaled sums, but the
    // following is good enough to be useful for now.
    let scale = max(abs(self), abs(other), .leastNormalMagnitude)
    return abs(self - other) < scale*tolerance
  }
  
  /// Test if this value is nearly zero with a specified `absoluteTolerance`.
  ///
  /// This test uses an *absolute*, rather than *relative*, tolerance,
  /// because no number should be equal to zero when a relative tolerance
  /// is used.
  ///
  /// Some very rough guidelines for selecting a non-default tolerance for
  /// your computation can be provided:
  ///
  /// - If this value is the result of floating-point additions or
  ///   subtractions, use a tolerance of `.ulpOfOne * n * scale`, where
  ///   `n` is the number of terms that were summed and `scale` is the
  ///   magnitude of the largest term in the sum.
  ///
  /// - If this value is the result of floating-point multiplications,
  ///   consider each term of the product: what is the smallest value that
  ///   should be meaningfully distinguished from zero? Multiply those terms
  ///   together to get a tolerance.
  ///
  /// - More generally, use half of the smallest value that should be
  ///   meaningfully distinct from zero for the purposes of your computation.
  ///
  /// For more complete guidance on an appropriate choice of tolerance,
  /// consult with a friendly numerical analyst.
  ///
  /// - Parameter absoluteTolerance: values with magnitude smaller than
  ///   this value will be considered to be zero. Must be greater than
  ///   zero.
  ///
  /// - Returns: `true` if `abs(self)` is less than `absoluteTolerance`.
  ///            `false` otherwise.
  @inlinable
  public func isAlmostZero(
    absoluteTolerance tolerance: Self = Self.ulpOfOne.squareRoot()
  ) -> Bool {
    assert(tolerance > 0)
    return abs(self) < tolerance
  }
  
  /// Rescales self and other to give meaningful results when one of them
  /// is infinite. We also handle NaN here so that the fast path doesn't
  /// need to worry about it.
  @usableFromInline
  internal func rescaledAlmostEqual(to other: Self, tolerance: Self) -> Bool {
    // NaN is considered to be not approximately equal to anything, not even
    // itself.
    if self.isNaN || other.isNaN { return false }
    if self.isInfinite {
      if other.isInfinite { return self == other }
      // Self is infinite and other is finite. Replace self with the binade
      // of the greatestFiniteMagnitude, and reduce the exponent of other by
      // one to compensate.
      let scaledSelf = Self(sign: self.sign,
                            exponent: Self.greatestFiniteMagnitude.exponent,
                            significand: 1)
      let scaledOther = Self(sign: .plus,
                             exponent: -1,
                             significand: other)
       // Now both values are finite, so re-run the naive comparison.
       return scaledSelf.isAlmostEqual(to: scaledOther, tolerance: tolerance)
    }
    // If self is finite and other is infinite, flip order and use scaling
    // defined above, since this relation is symmetric.
    return other.rescaledAlmostEqual(to: self, tolerance: tolerance)
  }
}
```

## Source compatibility

This is a purely additive change. These operations may collide with existing extensions
that users have defined with the same names, but the user-defined definitions will win, so
there is no ambiguity introduced, and it will not change the behavior of existing programs.
Those programs can opt-in to the stdlib notion of approximate equality by removing their
existing definitions.

## Effect on ABI stability

Additive change only.

## Effect on API resilience

This introduces two leaf functions that will become part of the public API for the 
FloatingPoint protocol, and one `@usableFromInline` helper function. We may make small
changes to these implementations over time for the purposes of performance optimization,
but the APIs are expected to be stable.

## Alternatives considered

**Why not change the behavior of `==`?**
Approximate equality is useful to have, but is a terrible default because it isn't transitive,
and does not imply substitutability under any useful model of floating-point values. This
breaks all sorts of implicit invariants that programs depend on.

**Why not introduce a fancy new operator like `a ≅ b` or `a == b ± t`?**
There's a bunch of clever things that one might do in this direction, but it's not at all
obvious which (if any) of them is actually a good idea. Defining good semantics for
approximate equality via a method in the standard library makes it easy for people
to experiment with clever operators if they want to, and provides very useful functionality
now.

**Why is a relative tolerance used?**
Because--as a library--we do not know the scaling of user's inputs a priori, a relative
tolerance is the only sensible option. Any absolute tolerance will be wrong more often
than it is right.

**Why do we need a special comparison for zero?**
Because zero is the one and only value with which a relative comparison tolerance is
essentially never useful. For well-scaled values, `x.isAlmostEqual(to: 0, tolerance: t)` 
will be false for any valid `t`.

**Why not a single function using a hybrid relative/absolute tolerance?**
Because--as a library--we do not know the scaling of user's inputs a priori, this will be
wrong more often than right. The scale invariance (up to underflow) of the main
`isAlmostEqual` function is a highly-desirable property, because it mirrors the way
the rest of the floating-point number system works.
