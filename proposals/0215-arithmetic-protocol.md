# Make `Numeric` Refine a new `Arithmetic` Protocol

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Richard Wei](https://github.com/rxwei)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#19989](https://github.com/apple/swift/pull/19989)

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

This proposal introduces a weakening of the existing `Numeric` protocol named
`Arithmetic`, which defines arithmetic operators and a zero, making conforming
types roughly correspond to the mathematic notion of
[rng](https://en.wikipedia.org/wiki/Rng_(algebra)). This makes it possible for
vector types to share arithmetic operators with scalar types.

Discussion thread: [Should Numeric not refine
ExpressibleByIntegerLiteral](https://forums.swift.org/t/should-numeric-not-refine-expressiblebyintegerliteral/15106)

## Motivation

The `Numeric` protocol today refines `ExpressibleByIntegerLiteral` and defines
all arithmetic operators. The design makes it easy for scalar types to adopt
arithmetic operators, but makes it *impossible* for vector types to adopt
arithmetic operators by conforming to this protocol.

Vector types mathematically represent [vector
spaces](https://en.wikipedia.org/wiki/Vector_space). Vectors by definition come
with a primitive operation: scalar multiplication. Ideally, one would naturally
want to conform to the `Numeric` protocol to get generalized arithmetic
operators, and define an extra `*` for scalar multiplication:

```swift
struct Vector<Scalar: Numeric>: Numeric {
  ...
  init(integerLiteral: Int) { ... }
  static func * (lhs: Vector, rhs: Vector) -> Vector { ... }
  static func * (lhs: Vector, rhs: Scalar) -> Vector { ... }
}
```

This compiles, but does not work in practice. The following trivial use case
would fail, because literal `1` can be implicitly converted to both a `Scalar`
and a `Vector`, and `*` is overloaded for both `Vector` and `Scalar`.

```swift
let x = Vector<Int>(...)
x * 1
```

This fundamental issue makes it impossible for vector types in libraries such as [SIMD
Vectors](https://github.com/apple/swift-evolution/blob/master/proposals/0229-simd.md)
and [TensorFlow](https://www.tensorflow.org/swift/api_docs/) to obtain
generalized arithmetic operator through the Swift standard library.

## Proposed solution

We keep `Numeric`'s behavior and requirements intact, and introduce a new
protocol to take ownership of `Numeric`'s arithmetic operators. `Numeric` will
refine this new protocol. The new protocol will roughly correspond to the
mathematical notion of [rng](https://en.wikipedia.org/wiki/Rng_(algebra)), i.e.
ring without unity. This idea comes from [Steve Canon's
response](https://forums.swift.org/t/should-numeric-not-refine-expressiblebyintegerliteral/15106/6?u=rxwei)
on an earlier thread about this issue.

Vector protocols or types will then conform to `Arithmetic`, sharing arithmetic
operators with scalar types without being prone to type-checking ambiguity.

## Detailed design

We define a new protocol called `Arithmetic`. This protocol requires all
arithmetic operators that today's `Numeric` requires, and a zero. Zero is a
fundamental property of a ring without unity.

```swift
public protocol Arithmetic {
  static var zero: Self { get }
  prefix static func + (x: Self) -> Self
  static func + (lhs: Self, rhs: Self) -> Self
  static func += (lhs: inout Self, rhs: Self) -> Self
  static func - (lhs: Self, rhs: Self) -> Self
  static func -= (lhs: inout Self, rhs: Self) -> Self
  static func * (lhs: Self, rhs: Self) -> Self
  static func *= (lhs: inout Self, rhs: Self) -> Self
}
```

Remove arithmetic operator requirements from `Numeric`, and make `Numeric`
refine `Arithmetic`.

```swift
public protocol Numeric: Arithmetic, Equatable, ExpressibleByIntegerLiteral  {
  associatedtype Magnitude: Comparable, Numeric 
  init?<T>(exactly source: T) where T : BinaryInteger
  var magnitude: Self.Magnitude { get }
}
```

To make sure today's `Numeric`-conforming types do not have to define a `zero`,
we provide an extension to `Arithmetic` constrained on `Self: ExpressibleByIntegerLiteral`.

```swift
public extension Arithmetic where Self: ExpressibleByIntegerLiteral {
  static var zero: Self {
    return 0
  }
}
```

## Source compatibility

The proposed change is fully source-compatible.

## Effect on ABI stability

The proposed change will affect the existing ABI of the standard library,
because it changes the protocol hierarchy and protocol requirements. As such,
this protocol must be considered before the Swift 5 branching date.

## Effect on API resilience

The proposed change will affect the ABI, and there is no way to make it not affect
the ABI because it changes the protocol hierarchy and protocol requirements.

## Alternatives considered

1. Make `Numeric` no longer refine `ExpressibleByIntegerLiteral` and not
   introduce any new protocol. This can solve the type checking ambiguity
   problem in vector protocols, but will break existing code: Functions generic
   over `Numeric` may use integer literals for initialization. Plus, Steve Canon
   also pointed out that it is not mathematically accurate -- there's a
   canonical homomorphism from the integers to every ring with unity. Moreover,
   it makes sense for vector types to conform to `Numeric` to get arithmetic
   operators, but it is uncommon to make vectors, esp. fixed-rank vectors,
   be expressible by integer literal.
