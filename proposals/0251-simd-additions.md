# SIMD additions

* Proposal: [SE-0251](0251-simd-additions.md)
* Author: [Stephen Canon](https://github.com/stephentyrone)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented with Modifications (Swift 5.1)**
* Implementation: [apple/swift#23421](https://github.com/apple/swift/pull/23421) and [apple/swift#24136](https://github.com/apple/swift/pull/24136) 
* Review: ([review](https://forums.swift.org/t/se-0251-simd-additions/21957)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0251-simd-additions/22801))



## Introduction

Early adopters of SIMD types and protocols have encountered a few missing things as
they've started to write more code that uses them. In addition, there are some
features we punted out of the original review because we were up against a hard time
deadline to which we would like to give further consideration.

This is a bit of a grab bag of SIMD features, so I'm deviating from the usual proposal
structure. Each new addition has its own motivation, proposed solution, and alternatives
considered section.

## Table of Contents
1. [Static `scalarCount`](#scalarCount)
2. [Extending Vectors](#extending)
3. [Swizzling](#swizzling)
4. [Reductions](#reduction)
5. [Lanewise `min`, `max`, and `clamp`](#minMaxClamp)
6. [`.one`](#one)
7. [`any` and `all`](#anyAndAll)

<a name="scalarCount">

## Static scalarCount
### Motivation
In functions that construct new SIMD vectors, especially initializers, one frequently wants
to perform some validation involving `scalarCount` *before* doing the work to create the
vector. Currently, `scalarCount` is defined as an instance property (following the pattern
of `count` on collection).

However, all SIMD vectors of a given type have the same `scalarCount`, so semantically
it makes sense to have available as a static property as well. There's precedent for having
this duplication in the `.bitWidth` property on fixed-width integers.

### Detailed Design
```swift
extension SIMDStorage {
  /// The number of scalars, or elements, in a vector of this type.
  public static var scalarCount: Int {
    return Self().scalarCount
  }
}
```
The property is defined as an extension on SIMDStorage because it makes semantic
sense there (`SIMD` refines `SIMDStorage`). It is defined in terms of the existing member
property (instead of the apparently more-logical vise-versa) because that way it 
automatically works for all existing SIMD types with no changes. In practice this
introduces no extra overhead at runtime.

### Alternatives Considered
Not doing anything. Users can always fall back on the weird-but-effective
`Self().scalarCount`.

<a name="extending">

## Extending vectors
### Motivation
When working with homogeneous coordinates in graphics, the last component frequently
needs to be treated separately--this means that you frequently want to extract the first
(n-1) components, do arithmetic on them and the final component separately, and then
re-assemble them. At API boundaries, you frequently take in (n-1) component vectors,
immediately extend them to perform math, and then return out only the first (n-1)
components.

### Detailed design
In order to support extending vectors from (n-1) to n components, add the following two
initializers:
```swift
extension SIMD3 {
  public init(_ xy: SIMD2<Scalar>, _ z: Scalar) {
    self.init(xy.x, xy.y, z)
  }
}

extension SIMD4 {
  public init(_ xyz: SIMD3<Scalar>, _ w: Scalar) {
    self.init(xyz.x, xyz.y, xyz.z, w)
  }
}
```

### Alternatives Considered
These could alternatively be spelled like `xy.appending(z)`; there are two reasons that
I'm avoiding that:
- I would expect `appending( )` to return the same type; but the result type is different.
- I would expect `appending( )` to be available on all SIMD types, but it breaks down
beyond `SIMD4`, because there is no `SIMD5` in the standard library.

We could have also used an explicit parameter label.
```swift
let v = SIMD3(...)
let x = SIMD4(v, 1)            // proposed above
let y = SIMD4(v, appending: 1) // with parameter label
```
My feeling is that the behavior is clear without the label, but it's very reasonable to argue
for an explicit label instead.

<a name="swizzling">

## Swizzling
### Motivation
In C-family languages, clang defines "vector swizzles" (aka permutes, aka shuffles, ... )
that let you select and re-arrange elements from a vector:
```c
#import <simd/simd.h>
simd_float4 x = { 1, 2, 3, 4};
x.zyx; // (simd_float3){3, 2, 1};
```
This comes from an identical feature in graphics shader-languages, where it is very
heavily used.

### Detailed design
For Swift, we want to restrict the feature somewhat, but also make it more powerful.
In shader languages and clang extensions, you can even use swizzled vectors as *lvalues*,
so long as the same element does not appear twice. I proposed to define general
permutes as get-only subscripts. By restricting them from appearing as setters, we
gain the flexibility to not require they be compile-time constants:
```swift
extension SIMD {
  /// Extracts the scalars at specified indices to form a SIMD2.
	///
	/// The elements of the index vector are wrapped modulo the count of elements
	/// in this vector. Because of this, the index is always in-range and no trap
	/// can occur.
  public subscript<Index>(index: SIMD2<Index>) -> SIMD2<Scalar>
  where Index: FixedWidthInteger {
    var result = SIMD2<Scalar>()
    for i in result.indices {
      result[i] = self[Int(index[i]) % scalarCount]
    }
    return result
  }
}

let v = SIMD4<Float>(1,2,3,4)
let xyz = SIMD3(2,1,0)
let w = v[xyz] // SIMD3<Float>(3,2,1)
```
### Alternatives Considered
1. We might want an explicit label on this subscript, but as with the extending inits, I
believe that its use is generally clear enough in context.

2. The main question is "what should the behavior for out-of-range indices be?" The
definition I have chosen here is simple to explain and maps efficiently to the hardware,
but there are at least two other good options: it could be a precondition failure, or it
could fill the vector with zero in lanes that have out of range indices. The first option
(trapping) is undesirable because it's less efficient with dynamic indices. The second 
would be slightly more efficient on some architectures, but is also significantly more
magic. I believe that the proposed alternative has the best balance of explainable
behavior and efficiency.

<a name="reduction">

## Reductions (or "Horizontal Operations")
### Motivation
Generally in SIMD programming you try to avoid horizontal operations as much as
possible, but frequently you need to do a few of them at the end of a chain of
computations. For example, if you're summing an array, you would sum into a bank
of vector accumulators first, then sum those down to a single vector. Now you need
to get from that vector to a scalar by summing the elements. This is where reductions
enter.

`sum` is also a basic building block for things like the dot product (and hence matrix
multiplication), so it's very valuable to have an efficient implementation provided by the
standard library. Similarly you want to have `min` and `max` to handle things like rescaling
for computational geometry.

### Detailed design
```swift
extension SIMD where Scalar: Comparable {
  /// The least element in the vector.
  public func min() -> Scalar

  /// The greatest element in the vector.
  public func max() -> Scalar
}
 
extension SIMD where Scalar: FixedWidthInteger { 
  /// Returns the sum of the scalars in the vector, computed with
  /// wrapping addition.
  ///
  /// Equivalent to indices.reduce(into: 0) { $0 &+= self[$1] }.
  public func wrappedSum() -> Scalar
}

extension SIMD where Scalar: FloatingPoint {
  /// Returns the sum of the scalars in the vector.
  public func sum() -> Scalar
}
```

### Alternatives Considered
We could call the integer operation `sum` as well, but it seems better to reserve that name
for the trapping operation in case we ever want to add it (just like we use `&+` for integer
addition on vectors, even though there is no `+`). We may want to define a floating-point
sum with relaxed semantics for accumulation ordering at some point in the future (I plan
to define `sum` as the binary tree sum here--that's the best tradeoff between reproducibility
and performance).

I dropped `indexOfMinValue` and `indexOfMaxValue` from this proposal for two reasons:
- there's some disagreement about whether or not they're important enough to include
- it's not clear what we should name them; If they're sufficiently important, we probably
want to have them on Collection some day, too, so the bar for the naming pattern that we
establish is somewhat higher.

<a name="anyAndAll">

## `any` and `all`
### Motivation
`any` and `all` are special reductions that operate on boolean vectors (`SIMDMask`). They
return `true` if and only if *any* (or *all*) lanes of the boolean vector are `true`. These are
used to do things like branch around edge-case fixup:
```swift
if any(x .< 0) { // handle negative x }
```

### Detailed design
`any` and `all` are free functions:
```swift
public func any<Storage>(_ mask: SIMDMask<Storage>) -> Bool {
  return mask._storage.min() < 0
}

public func all<Storage>(_ mask: SIMDMask<Storage>) -> Bool {
  return mask._storage.max() < 0
}
```

### Alternatives Considered
*Why* are `any` and `all` free functions while `max` and `min` and `sum` are member
properties? Because of readability in their typical use sites. `min`, `max`, and `sum` are
frequently applied to a named value:
```swift
let accumulator = /* do some work */
return accumulator.sum
```
`any` and `all` are most often used with nameless comparison results:
```swift
if any(x .< minValue .| x .> maxValue) {
  // handle special cases
}
```
To my mind, this would read significantly less clearly as
```swift
if (x .< minValue .| x .> maxValue).any` {
```
or
```swift
if (x .< minValue .| x .> maxValue).anyIsTrue` {
```
because there's no "noun" that the property applies to. There was a proposal in the fall
to make them static functions on `Bool` so that one could write
```swift
if .any(x .< minValue) {
}
```
but I'm not convinced that's actually better than a free function.

<a name="minMaxClamp">

## `min`, `max`, and `clamp`
### Motivation
We have lanewise arithmetic on SIMD types, but we don't have lanewise `min` and `max`.
We're also missing `clamp` to restrict values to a specified range.

### Detailed design
```swift
extension SIMD where Scalar: Comparable {
  /// Replace any values less than lowerBound with lowerBound, and any
  /// values greater than upperBound with upperBound.
  ///
  /// For floating-point vectors, `.nan` is replaced with `lowerBound`.
  public mutating func clamp(lowerBound: Self, upperBound: Self) {
    self = self.clamped(lowerBound: lowerBound, upperBound: upperBound)
  }
  
  /// The vector formed by replacing any values less than lowerBound
  /// with lowerBound, and any values greater than upperBound with
  /// upperBound.
  ///
  /// For floating-point vectors, `.nan` is replaced with `lowerBound`.
  public func clamped(lowerBound: Self, upperBound: Self) -> Self {
    return Self.min(upperBound, Self.max(lowerBound, self))
  }
}

/// The lanewise minimum of two vectors.
///
/// Each element of the result is the minimum of the corresponding
/// elements of the inputs.
public func min<V>(_ lhs: V, _ rhs: V) -> V where V: SIMD, V.Scalar: Comparable

/// The lanewise maximum of two vectors.
///
/// Each element of the result is the maximum of the corresponding
/// elements of the inputs.
public func max<V>(_ lhs: V, _ rhs: V) -> V where V: SIMD, V.Scalar: Comparable
```

### Alternatives Considered
These could be spelled out `lanewiseMaximum` or similar, to clarify that they operate
lanewise (Chris suggested this in the pitch thread), but we don't spell out `+` as
"lanewise-plus", so it seems weird to do it here. The default assumption is that SIMD
operations are lanewise.

<a name="one">

## `.one`
### Motivation
SIMD types cannot be `ExpressibleByIntegerLiteral` (it results in type system
ambiguity for common expressions). We already have `.zero`, so adding `.one` makes
sense as a convenience.

### Detailed design
```swift
extension SIMD where Scalar: ExpressibleByIntegerLiteral {
  public static var one: Self {
    return Self(repeating: 1)
  }
}
```

### Alternatives Considered
- Do nothing. We don't *need* this, but it has turned out to be a useful convenience.
- Why stop at `one`? Why not `two`? Because that way lies madness.

## Source compatibility

These are all purely additive changes with no effect on source stability.

## Effect on ABI stability

These are all purely additive changes with no effect on source stability.

## Effect on API resilience

These are all purely additive changes with no effect on source stability.

## Alternatives Considered

The pitch for this proposal included some operations for loading and storing from a
collection. As Jordan pointed out in the pitch thread, we already have an init from
Sequence, which together with slices makes the load mostly irrelevant. The store
operation did not have satisfactory naming, and I would like to come up with a better
pattern for these that handles iterating over a sequence of SIMD vectors loaded from
a collection of scalars and storing them out as a single pattern, rather than building
it up one piece at a time.

## Implementation Notes

Due to a desire to avoid collision between the `min(u, v)` (pointwise minimum on SIMD vectors) and `min(u, v)` (minimum defined on `Comparable`, if a user adds a retroactive conformance), the core team decided to rename the SIMD operations to `pointwiseMin(u, v)` and `pointwiseMax(u, v)`.
