# Decoupling Floating Point Strides from Generic Implementations

* Proposal: SE-0050
* Authors: [Erica Sadun](http://github.com/erica), [Xiaodi Wu](http://github.com/xwu)
* Status: **Awaiting Review**
* Review manager: TBD

Swift strides create progressions along "notionally continuous one-dimensional values" using a series of offset values. This proposal supplements Swift's generic stride implementation with separate algorithms for floating point strides that avoid error accumulation.

This proposal was discussed on-list in the ["\[Discussion\] stride behavior and a little bit of a call-back to digital numbers"](http://article.gmane.org/gmane.comp.lang.swift.evolution/8014) thread.

## Motivation

`Strideable` is genericized across both integer and floating point types. Writing a single piece of code to operate on both integer and floating point types is rarely a good idea. Swift's current implementation causes floating point strides to accumulate errors when repeatedly adding `by` intervals. Floating point types deserve a separate floating point-aware implementation that minimizes errors.

## Current Art

A `StrideTo` sequence returns a sequence of values (`self`, `self + stride`, `self + stride + stride`, ... *last*) where *last* is the last value in the progression that is less than `end`. A `StrideThrough` sequence returns a sequence of values (`self`, `self + stride`, `self + stride + stride`, ... *last*) where *last* is the last value in the progression less than or equal to `end`. There is no guarantee that `end` is an element of the sequence.

While floating point calls present an extremely common use case, they use integer-style math that accumulates errors during execution. Consider this example (using Swift 2.2 syntax):

```swift
let ideal = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]
print(zip(Array(1.0.stride(through: 2.01, by: 0.1)), ideal).map(-))
// prints [0.0, 0.0, 2.2204460492503131e-16, 2.2204460492503131e-16, 
// 4.4408920985006262e-16, 4.4408920985006262e-16, 4.4408920985006262e-16, 
// 6.6613381477509392e-16, 6.6613381477509392e-16, 8.8817841970012523e-16, 
// 8.8817841970012523e-16]
```

* To create an array containing values from 1.0 to 2.0, the developer must add
  an epsilon value to the `through` argument. Otherwise the stride progression ends 
  near 1.9. Increasing the argument from `2.0` to `2.01` is sufficient to include 
  the end value.
* The errors in the sequence increase over time. You see this as 
  errors become larger towards the end of the progress. This is an artifact of
  the generic implementation.

The same issues occur with C-style for loops. This problem is a fundamental artifact of floating point math and is not specific to Swift statements.

## Detail Design

Floating point strides are inherently dissimilar to and should not be genericized with integer strides. We propose that `BinaryFloatingPointStrideTo` and `BinaryFloatingPointStrideThrough` should each return a sequence of values (`self`, `self + 1.0 * stride`, `self + 2.0 * stride`, ... *last*). The following example provides a rough sketch at what a revamp for `BinaryFloatingPointStrideTo` might look like (incorporating the `BinaryFloatingPoint` protocol as adopted in SE-0067):

```swift
/// An iterator for the result of `stride(to:...)` that advances without
/// accumulating error for binary floating point types.
///
/// - Note: The total number of steps required to stride over the interval
///   cannot exceed 2 ** `(Element.Stride.significandBitCount + 1)`, where
///   ** represents exponentiation.
public struct BinaryFloatingPointStrideToIterator<
  Element : Strideable where Element.Stride : BinaryFloatingPoint
> : IteratorProtocol {
  internal var _step: Element.Stride = 0
  internal let _start: Element
  internal let _end: Element
  internal let _stride: Element.Stride

  /// Advance to the next element and return it, or `nil` if no next
  /// element exists.
  public mutating func next() -> Element? {
    let current = _start + _step * _stride
    if _stride > 0 ? current >= _end : current <= _end {
      return nil
    }
    _step += 1
    return current
  }

  internal init(_start: Element, end: Element, stride: Element.Stride) {
    // Attempting to compute the exact number of steps from start to end
    // by stride is inadvisable because that result may not be exactly
    // representable if it is too large; instead, determine if 2 ** 
    // `(Element.Stride.significandBitCount + 1)` steps would advance past
    // the end
    let steps = Element.Stride(sign: .plus,
      exponent: Element.Stride.Exponent(Element.Stride.significandBitCount + 1),
      significand: 1)
    let limit = _start + steps * stride
    _precondition(
      stride > 0 ? limit >= end : limit <= end,
      "can't construct BinaryFloatingPointStrideToIterator: maximum supported number of steps exceeded")
    self._start = _start
    self._end = end
    self._stride = stride
  }
}

/// A `Sequence` of values formed by striding over a binary floating point
/// half-open interval without accumulating error.
public struct BinaryFloatingPointStrideTo<
  Element : Strideable where Element.Stride : BinaryFloatingPoint
> : Sequence, CustomReflectable {
  // FIXME: should really be a CollectionType, as it is multipass

  /// Returns an iterator over the elements of this sequence.
  ///
  /// - Complexity: O(1).
  public func makeIterator() -> BinaryFloatingPointStrideToIterator<Element> {
    return BinaryFloatingPointStrideToIterator(
      _start: _start, end: _end, stride: _stride)
  }

  internal init(_start: Element, end: Element, stride: Element.Stride) {
    // The endpoint is constrained by a step counter of type Element.Stride
    // in BinaryFloatingPointStrideToIterator, but it does not otherwise need
    // to be finite.
    _precondition(
      stride.isFinite && !stride.isZero,
      "stride size must be finite and non-zero")
    self._start = _start
    self._end = end
    self._stride = stride
  }

  internal let _start: Element
  internal let _end: Element
  internal let _stride: Element.Stride

  public var customMirror: Mirror {
    return Mirror(self, children: ["from": _start, "to": _end, "by": _stride])
  }
}

/// Returns the sequence of values (`self`, `self + 1.0 * stride`, `self +
/// 2.0 * stride`, ... *last*) where *last* is the last value in
/// the progression that is less than `end`.
@warn_unused_result
public func stride<T : Strideable where T.Stride : BinaryFloatingPoint>(
  from start: T, to end: T, by stride: T.Stride
) -> BinaryFloatingPointStrideTo<T> {
  return BinaryFloatingPointStrideTo(_start: start, end: end, stride: stride)
}
```

Some salient design points deserve mention:

* We propose that only floating point types use this slightly more computationally intensive "new" stride; all other types retain the "classic" stride. If accepted, this new code could be appended to Stride.swift.gyb and exist alongside current code, which does not need to be modified.

* It has become clear (based on some of Dave Abrahams's insights) that what determines whether a `StrideTo<T>` accumulates error isn't `T` but rather `T.Stride`; thus, we determine that "new" stride applies where `T.Stride : BinaryFloatingPoint`.

* With newly adopted `FloatingPoint` and `BinaryFloatingPoint` protocols, `Float80` will conform to `BinaryFloatingPoint` and so will be opted into "new" stride.

* We have considered Dave Abrahams's suggestion to explore whether we could avoid introducing new types, instead modifying the existing `StrideToIterator` and `StrideThroughIterator` and relying on compiler optimization to transform "new" stride into "classic" stride for `StrideTo<Int>`; however, because the differences between "classic" stride and "new" stride
extend beyond the iterator's `next()` method (see below), we determined it would be best to keep the floating point logic in distinct types.

* This "new" stride algorithm must take a different approach to handling the edge case of strides requiring an excessively large number of iterations. Consensus feedback has been that such strides should not devolve into infinite loops. As a result, the number of steps required to stride from start to end is computed during initialization. A "BigInt" step counter could remove this limitation, but use of such a type would degrade performance for more common use cases, and of course no such type exists in the Standard Library. Thus, we have settled on the use of a floating point step counter.

* One implication of using a floating point step counter is that the maximum supported number of iterations for endpoints of type `Double` is 2<sup>53</sup>. That number of steps should be indistinguishable from an infinite loop for currently available consumer systems. Alternatives include a step counter of type `Int`, but as Stephen Canon has pointed out, there is a performance hit involved in performing an integer-to-floating point conversion at every iteration and in using multi-word arithmetic on 32-bit systems.

* For endpoints of type `Float`, meaningful loops may exist with more than 2<sup>31</sup> iterations and catastrophic cancellation is a realistic concern; therefore, it is a decision to be made on review if it is advisable to implement `Float`-specific versions of these algorithms where internal state is represented using `Double`, thus improving precision beyond that obtainable by manually computing (`self`, `self + 1.0 * stride`, `self + 2.0 * stride`, ... *last*) using `Float`.

### Out of Scope

We (and others) intend to propose further changes to striding under separate cover. The following topics remain under discussion but are orthogonal to this proposal:

* Adding a method to be named `striding(by:)` or `by(_:)` to `Range`
* Conforming strides to `Collection` rather than `Sequence`, and enabling striding over all types conforming to `Collection` (or even all types conforming to `Sequence`)

Other out-of-scope suggestions that may no longer apply to Swift 3 include:

* Changing the name of parameter labels `to:` and `through:` to clarify their meaning
* Changing internal implementation details of `StrideToIterator` and `StrideThroughIterator` to reduce the number of branches without relying on compiler optimizations to elide them
* Merging `Range` and stride types

## Alternatives Considered

Converting floating point values to integer math can produce more precise results. This approach works by calculating a precision multiplier. The multiplier is derived from the whole and fractional parts of the start value, end value, and stride value, enabling fully integer math that guards against lost precision. We do not recommend this solution because it introduces significant overhead both during initialization and at each step. This overhead limits real-world utility beyond trivial stride progressions. A fast, well-implemented decimal type would be a better fit than this jerry-rigged alternative.

#### Integer Math

```swift
/// An `Iterator` for `DoubleStrideThrough`.
public struct DoubleStrideThroughIterator : Iterator {
    let start: Int
    let end: Int
    let stride: Int
    let multiplier: Int
    var iteration: Int = 0
    var done: Bool = false
    
    public init(start: Double, end: Double, stride: Double) {
        
        // Calculate the number of places needed
        // Account for zero whole or fractions
        let wholes = [abs(start), abs(end), abs(stride)].map(floor)
        let fracs = zip([start, end, stride], wholes).map(-)
        
        let wholeplaces = wholes
            .filter({$0 > 0}) // drop all zeros
            .map({log10($0)}) // count places
            .map(ceil) // round up
        
        let fracplaces = fracs
            .filter({$0 > 0.0}) // drop all zeroes
            .map({log10($0)}) // count places
            .map(abs) // flip negative log for fractions
            .map(ceil) // round up
        
        // Extend precision by 10^2
        let places = 2.0
            + (wholeplaces.maxElement() ?? 0.0)
            + (fracplaces.maxElement() ?? 0.0)
        
        // Compute floating point multiplier
        let fpMultiplier = pow(10.0, places)
        
        // Convert all values to Int
        self.multiplier = lrint(fpMultiplier)
        let adjusted = [start, end, stride]
            .map({$0 * fpMultiplier})
            .map(lrint)
        (self.start, self.end, self.stride) =
            (adjusted[0], adjusted[1], adjusted[2])
    }
    
    /// Advance to the next element and return it, or `nil` if no next
    /// element exists.
    public mutating func next() -> Double? {
        if done {
            return nil
        }
        let current = start + iteration * stride; iteration += 1
        if stride > 0 ? current >= end : current <= end {
            if current == end {
                done = true
                // Convert back from Int to Double
                return Double(current) / Double(multiplier)
            }
            return nil
        }
        
        // Convert back from Int to Double
        return Double(current) / Double(multiplier)
    }
}
```

#### Computed Epsilon Values

Computed epsilon values help compare a current value to a floating-point endpoint. The following code tests whether the current value lies within 5% of the stride of the endpoint.

```swift
/// An `Iterator` for `DoubleStrideThrough`.
public struct DoubleStrideThroughIterator : Iterator {
    let start: Double
    let end: Double
    let stride: Double
    var iteration: Int = 0
    var done: Bool = false
    let epsilon: Double
    
    public init(start: Double, end: Double, stride: Double) {
        (self.start, self.end, self.stride) = (start, end, stride)
        epsilon = self.stride * 0.05 // an arbitrary epsilon of 5% of stride
    }
    
    /// Advance to the next element and return it, or `nil` if no next
    /// element exists.
    public mutating func next() -> Double? {
        if done {
            return nil
        }
        let current = start + Double(iteration) * stride; iteration += 1
        if abs(current - end) < epsilon {
            done = true
            return current
        }
        if signbit(current - end) == signbit(stride) {
            done = true
            return nil
        }
        return current
    }
}
```

#### Other Solutions

While precision math for decimal numbers would be better addressed by introducing a decimal type and/or warnings for at-risk floating point numbers, those features lie outside the scope of this proposal.
