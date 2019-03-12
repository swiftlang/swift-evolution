# SIMD additions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Stephen Canon](https://github.com/stephentyrone)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

A few teams within Apple have requested additions to the new SIMD types 
and protocols to better support their use cases. In addition, there are some features
we punted out of the original review because we were up against a hard time
deadline to which we would like to give further consideration.

## Motivation

This is a bit of a grab bag of SIMD features, so it's hard to present a single coherent
motivation for their addition. Basically, they are features that people who are writing
a significant amount of code against the existing SIMD types have found they are
missing. I'll attempt to motivate each new API individually in the proposed solution
section below.

## Proposed solution

### Extending vectors
Add the following initializers:
```swift
extension SIMD3 {
  /// The vector (xy.x, xy.y, z)
  public init(_ xy: SIMD2<Scalar>, _ z: Scalar)
}

extension SIMD4 {
  /// The vector (xyz.x, xyz.y, xyz.z, w)
  public init(_ xyz: SIMD3<Scalar>, _ w: Scalar)
}
```
These are broadly useful in graphics contexts for working with homogeneous coordinates,
where the last component needs to be treated separately, and where you frequently want
to extend vectors by adding an additional component at API boundaries. These could
alternatively be spelled like `xy.appending(z)`; there are two reasons that I'm avoiding
that:
- I would expect `appending( )` to return the same type; here the result type is different.
- I would expect `appending( )` to be available on all SIMD types, but it breaks down
beyond `SIMD4`, because there is no `SIMD5` in the standard library.

### Loading and storing from collections
Add the following:
```swift
extension SIMD {
  /// Extracts a vector with consecutive elements taken from `collection`
  /// beginning at the index `start`.
  ///
  /// - Precondition: `collection` contains enough elements to fill the
  ///   vector.
  public init<C>(_ collection: C, start: C.Index)
  where C: Collection, C.Element == Scalar
  
  /// Replaces the elements of `collection` beginning at the index
  /// `start` with the elements of this vector.
  ///
  /// - Precondition: `collection` has space for all elements of the
  ///   vector.
  public func store<C>(into collection: inout C, start: C.Index)
  where C: MutableCollection, C.Element == Scalar
}
```
These are primarily useful for working with arrays or UBP of vector data, such as are used
to marshal vertex or color data to and from the GPU. They are especially useful with
3-element vector types, where we may want to avoid the extra padding element that
`Array<SIMD3<T>>` or `UnsafeBufferPointer<SIMD3<T>>` would incur.

The `init` is pretty clear; I am not really sold on the naming of `store` at this point, and
would love to hear other suggestions. If `SIMD` types conformed to `Sequence`, this would
nearly be `collection.replaceSubrange(start...start+v.count, with: v)` for 
`RRC`, but we would like to enforce that this doesn't grow the collection; it should only
replace exactly `count` elements, so it's slightly different--the `RRC` interface would be
redundant.

The intention is that these should codegen to vector loads when the elements are actually
contiguous in memory, but still work with collections that are not contiguous. Early
experimentation suggests that we get the desired codgen even with fully generic
implementations of these operations.

### Horizontal operations
Generally in SIMD programming you try to avoid horizontal operations as much as
possible, but frequently you need to do a few of them at the end of a chain of
computations. The reductions that we most often need to perform are:
```swift
extension SIMD where Scalar: Comparable {
  func min() -> Scalar
  func max() -> Scalar
}

extension SIMD where Scalar: BinaryFloatingPoint {
  func sum() -> Scalar
}

extension SIMD where Scalar: FixedWidthInteger {
  func sum() -> Scalar
}
```
One might reasonably ask why the last two are not collapsed onto `AdditiveArithmetic`.
The answer is that we want to use `&+` for reduction on integer vectors, which isn't defined
on `AdditiveArithmetic`. One might follow-up with "isn't that prone to overflow?" The
answer is yes, but it's the operation you generally want in a SIMD context; to get the
"safe" sum you widen to the double-width type, then sum that. We might reasonably use
a different name for this operation though, like `wrappingSum`, to be explicit.

In addition, we would provide the following two reductions on Mask vectors:
```swift
/// True if any lane of the mask is true
func any<S>(_ mask: SIMDMask<S>) -> Bool

/// True if every lane of the mask is true
func all<S>(_ mask: SIMDMask<S>) -> Bool
```
These two are defined as free functions, because at use sites they read significantly more
clearly like `if any(x .< 0)` than, e.g. `if (x .< 0).any()`. We could consider using a
more verbose spelling like `if (x .< 0).anyIsTrue( )`, but these functions are used
quite heavily, and there's a strong preference from the teams we've been working with for
the concise free function spellings.

We would also like to add:
```swift
extension SIMD where Scalar: Comparable {
  func indexOfMinValue() -> Int
  func indexOfMaxValue() -> Int
}
```
The exact spelling of these is not super important to our would-be clients, and I'm not
really wedded to these names. I would love to get some suggestions for them.

### Min, max, clamp
```swift
extension SIMD where Scalar: Comparable {
  static func min(_ lhs: Self, _ rhs: Self) -> Self
  static func max(_ lhs: Self, _ rhs: Self) -> Self
  mutating func clamp(to range: ClosedRange<Scalar>)
  func clamped(to range: ClosedRange<Scalar>) -> Self
  mutating func clamp(lowerBound: Self, upperBound: Self)
  func clamped(lowerBound: Self, upperBound: Self) -> Self
}
```
These are all fairly simple to implement in terms of the existing
`replacing(with: where:)`, but for two factors: first, getting them right for floating-point
types is a little bit subtle, and second these are so heavily used that it makes sense to
have an actual API for them, rather than leaving each developer to implement them on their
own.

### "Swizzles" aka "Permutes"
Early drafts of the previous proposal for SIMD had the following initializer:
```swift
init<D, I>(gathering source: D, at index: I)
where D : SIMDVector, D.Element == Element,
      I : SIMDIntegerVector & SIMDVectorN {
  self.init()
  for i in 0 ..< count {
    if index[i] >= 0 && index[i] < source.count {
      self[i] = source[Int(index[i])]
    }
  }
}
```
it was removed from later drafts because the naming wasn't quite right, but it's also not
quite implementable with the "generic" SIMD structure that the community settled on. In
particular, we can't enforce the constraint that the index vector (`I`) has the same number
of elements as the vector type being initialized, because rather than having a
`SIMDVectorN` protocol conformance, we just have the `SIMDN<T>` type.

We can work around this by moving the init down to the types themselves, at the cost
of some code repetition. This is a critical operation for writing efficient SIMD code,
so we definitely want to provide it. In addition, we hope that it can eventually form the
backing implementation for arbitrary named compile-time swizzles like `v.xyxy`.

I'm exploring a few ways to add this functionality now, but I'm interested in getting other
thoughts from the community.

### "one"
One last requestion from internal developers is
```swift
extension SIMD where Scalar: ExpressibleByIntegerLiteral {
  static var one: Self { return Self(repeating: 1) }
}
```
This is a fairly niche feature, but gets used heavily enough that folks would really
appreciate having a short name for it. `.zero` already exists from `AdditiveArithmetic`,
which makes this seem somewhat reasonable to me.
