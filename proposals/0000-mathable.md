# Generic Math(s) Functions

* Proposal: [SE-NNNN](NNNN-mathable.md)
* Author: [Stephen Canon](https://github.com/stephentyrone)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)

## Introduction

This proposal would introduce a new `Mathable` protocol that provides generic access
to "basic math functions" (the functionality of math.h that is not implied by
`FloatingPoint` and `BinaryFloatingPoint`).

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

`BinaryFloatingPoint` (and the protocols it refines) provides a powerful set of
abstractions for writing numerical code, but it does not include the transcendental
operations defined by the C math library, which are instead imported by the platform
overlay as a set of overloaded concrete free functions. This makes it impossible to
write generic code that uses, say `exp` or `sin` without defining your own trampolines
or converting everything to and from `Double`, neither of which is very satisfying.

## Proposed solution

Introduce a new protocol, `Mathable`, that provides basic math functions as static
functions defined under a `Math` namespace:
```swift
let x: Float = 1
let y = Float.Math.exp(x) // 2.7182817
```
Additionally, introduce a new *module*, `Math`, that provides the "customary" free 
functions:
```swift
import Math
let z = exp(x) // 2.7182817
```
By doing this, the free functions are not defined in the global namespace unless
this module is explicitly imported, but the functionality is always available via the static
functions defined in the standard library.

## Detailed design

The `Mathable` protocol is implemented as follows:
```swift
public protocol Mathable : Numeric {
  associatedtype Math: MathImplementations where Math.Value == Self
  func /(lhs: Self, rhs: Self) -> Self
  func /=(lhs: inout Self, rhs: Self)
  func squareRoot() -> Self
  mutating func formSquareRoot()
}

public protocol MathImplementations {
  associatedtype Value
  static func cos(_ x: Value) -> Value
  static func sin(_ x: Value) -> Value
  static func tan(_ x: Value) -> Value
  ...
}
```
`Float`, `Double` and `Float80` (when defined) all conform to `Mathable`, as do SIMD
vector types when the underlying Scalar type is `Mathable`. `Float16`, `Decimal`, and
`Complex` types are all expected to conform as well if and when they become available.

Square root and division are treated separately because they are "basic arithmetic"
operations rather than transcendental functions.

The `Math` module interfaces are even simpler:
```swift
public func cos<T>(_ x: T) -> T where T: Mathable {
  return T.Math.cos(x)
}

public func sin<T>(_ x: T) -> T where T: Mathable {
  return T.Math.sin(x)
}

...
```

### Functions defined on Mathable
`cos`, `sin`, `tan`, `acos`, `asin`, `atan`, `atan2`, `exp`, `exp2`, `exp10`, `expm1`, `log`, `log2`,
`log10`, `logp1`, `pow`, `root`, `cosh`, `sinh`, `tanh`, `acosh`, `asinh`, `atanh`, `erf`, `erfc`,
`gamma`, `lgamma`.

Most of these directly shim the C math library equivalents. A few warrant special discussion:
- `exp10` does not exist on all targets; we'll fall back on implementing it as `pow(10, x)`
in those cases. On platforms where `pow` has sub-ulp accuracy this always yields correct
results for exact powers of ten, but it may result in small but noticeable rounding errors
on platforms where `pow` does not have adequate quality of implementation. This should
be considered a bug for Swift to address in the future.
- We will adjust the edge cases of `pow` somewhat from the C library definition.
Specifically, we will provide two overloads: `pow(_ x: T, _ y: T) -> T` and 
`pow(_ x: T, _ n: Int) -> T`, corresponding to the IEEE-754 "powr" and "pown"
operations.
- There are two things that are weird about `atan2`. First, the argument order is trap.
The signature is `atan2(_ y: T, _ x: T) -> T`, and it computes `atan(y/x)` with
some fixup around how the sign is handled, which makes it equivalent to getting the
angle of the polar representation of the vector `(x, y)`. Second, it doesn't really make
sense for complex types, which Mathable is intended to support; I don't know of
another language that provides it on complex `T`. We can define it as `atan(y/x)` in
those cases, but it's slightly weird. Ultimately, a Swiftier interface should be provided
on a two-dimensional vector type as `polar` and on complex types as `arg`
to avoid this confusion, but we will retain `atan2` as a convenience for users familiar
with it.

### Functions not defined on Mathable
The following functions are exported by <math.h>, but will not be defined on Mathable:
`frexp`, `ilogb`, `ldexp`, `logb`, `modf`, `scalbn`, `scalbln`, `fabs`, `cbrt`, `hypot`, `ceil`,
`floor`, `nearbyint`, `rint`, `lrint`, `llrint`, `round`, `lround`, `llround`, `trunc`, `fmod`,
`remainder`, `remquo`, `copysign`, `nan`, `nextafter`, `nexttoward`, `fdim`, `fmin`, `fmax`,
`fma`.

Most of these are not defined on Mathable because they are inherently bound to the
semantics of `FloatingPoint` or `BinaryFloatingPoint`, and so cannot be defined for
types such as Complex or Decimal. Equivalents to many of them are already defined on
`[Binary]FloatingPoint` anyway--in those cases free functions are be defined by
the Math module, but will be generic over `FloatingPoint` or `BinaryFloatingPoint`.
E.g.:
```swift
public func floor<T>(_ x: T) -> T where T: FloatingPoint {
  return x.rounded(.down)
}
```
A few (`nearbyint`, `rint`, `lrint`, `llrint`) are fundamentally tied to the C language
notion of dynamic floating-point rounding-modes, which is not modeled by Swift (and
which we do not have plans to support--even if Swift adds rounding-mode control, we
should avoid the C fenv model).

### Future expansion
The following functions recommended by IEEE 754 are not provided at this point
(because implementations are not widely available), but are planned for future expansion,
possibly with implementation directly in Swift: `cospi`, `sinpi`, `tanpi`, `acospi`, `asinpi,
atanpi`, `exp2m1`, `exp10m1`, `log2p1`, `log10p1`, `compound`, `root` (obviously, some of
these names are bad; we're not locked into using the IEEE-754 names for Swift).

## Source compatibility
This is an additive change, but it entails some changes for platform modules; the existing
platform implementations provided by the Darwin or GLibc should be deprecated and
made to redirect people to the new operations.

## Effect on ABI stability
For the standard library, this is an additive change. We'll need to continue to support the
old platform hooks to provide binary stability, but will mark them deprecated or obsoleted.

## Effect on API resilience
This is an additive change.

## Alternatives considered
1. The name `Mathable` is at least not obviously great. So far, I have not come up with a
better name for this protocol. There are more technical choices that we might opt
for (things in the direction of `Analytic`, `TranscendentalFunctions`, `Calculus`,
`CompleteField`, `ElementaryFunctions` etc), but these are not sufficiently better to
justify unfamiliarity to most  users. We could go more explicit (`HasMathFunctions`), but
that's not great either. Perhaps the best alternative would be simply `Math`.

2. The names of these functions are strongly conserved across languages, but they are
not universal; we *could* consider more verbose names inline with Swift usual patterns.
`sine`, `cosine`, `inverseTangent`, etc. This holds some appeal especially for the more
niche functions (like `expm1`), but the weight of common practice is pretty strong here;
almost all languages use essentially the same names for these operations. Another
alternative would be to break these up into `TrigonometricFunctions`, 
`HyperbolicFunctions`, `ExponentialFunctions`, etc, but I don't think that actually
buys us very much.

3. We may also want to add `log(_ base: T, _ x: T) -> T` at some future point as a
supplement to the existing `log`, `log2`, and `log10` functions. Python and Julia both
provide a similar interface. Doing this correctly requires a building block that the C math
library doesn't provide (an extra-precise `log` or `log2` that returns a head-tail
representation of the result); without this building block rounding errors creep in even for
exact cases:
```python
>>> from math import log
>>> log(3**20, 3)
19.999999999999996
```
Julia includes a warning about this in their documentation that basically says "Use log2
or log10 instead if base is 2 or 10". We could take that approach, but base 2 and 10
cover 99% of uses, so I would rather wait to provide this function until we have time to
do it correctly.

4. We could have `Mathable` not inherit from `Numeric` and *only* provide the math
implementations (leaving out division and square root). In practice, this would mean that
generic algorithms would almost always end up needing to be constrained to something
like `BinaryFloatingPoint & Mathable` or `Numeric & Mathable`. That's not terrible,
but a fairly large body of code can be written directly against `Mathable` if we follow the
proposal.

5. We could put the free functions into the standard library instead of a separate module.
Having them in a separate module helps avoid adding stuff to the global namespace
unless you're actually using it, which is generally nice, and the precedent from other
languages is pretty strong here: `#include <cmath>`, `import math`, etc. Having the 
implementation hooks defined in the standard lib makes them available in modules that
only need them in a few places or want to use them in inlinable functions but don't want
to have them in the global namespace or re-export them.
