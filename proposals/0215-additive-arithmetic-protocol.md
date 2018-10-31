# Make  `Numeric`  Refine a new  `AdditiveArithmetic`  Protocol

* Proposal: TBD
* Author: [Richard Wei](https://github.com/rxwei)
* Review Manager: TBD
* Status:  **Awaiting review**
* Implementation: [apple/swift#19989](https://github.com/apple/swift/pull/19989)

## Introduction

This proposal introduces a weakening of the existing  `Numeric`  protocol named  `AdditiveArithmetic` , which defines additive arithmetic operators and a zero, making conforming types roughly correspond to the mathematic notion of an [additive group](https://en.wikipedia.org/wiki/Additive_group). This makes it possible for vector types to share additive arithmetic operators with scalar types, which enables generic algorithms over `AdditiveArithmetic` to apply to both scalars and vectors.

Discussion thread: [Should Numeric not refine ExpressibleByIntegerLiteral](https://forums.swift.org/t/should-numeric-not-refine-expressiblebyintegerliteral/15106)

## Motivation

The  `Numeric`  protocol today refines  `ExpressibleByIntegerLiteral`  and defines all arithmetic operators. The design makes it easy for scalar types to adopt arithmetic operators, but makes it hard for vector types to adopt arithmetic operators by conforming to this protocol.

What's wrong with `Numeric`? Assuming that we need to conform to `Numeric` to get basic arithmetic operators and generic algorithms, we have three problems.

### 1. Vectors conforming to `Numeric` would be mathematically incorrect.

`Numeric` roughly corresponds to a [ring](https://en.wikipedia.org/wiki/Ring_(mathematics)). Vector spaces are not rings. Multiplication is not defined between vectors. Requirements `*` and `*=` below would make vector types inconsistent with the mathematical definition.

```
static func * (lhs: Self, rhs: Self) -> Self
static func *= (lhs: inout Self, rhs: Self)
```

### 2. Literal conversion is undefined for dynamically shaped vectors.

Vectors can be dynamically shaped, in which case the the shape needs to be provided when we initialize a vector from a scalar. Dynamically shaped vector types often have an initializer `init(repeating:shape:)`.

Conforming to `Numeric` requires a conformance to `ExpressibleByIntegerLiteral`, which requires `init(integerLiteral:)`. However, the conversion from a scalar to a dynamically shaped vector is not defined when there is no given shape.

```swift
struct Vector<Scalar: Numeric>: Numeric {
  // Okay!
  init(repeating: Scalar, shape: [Int]) { ... }

  // What's the shape?
  init(integerLiteral: Int)
}
```

### 3. Common operator overloading causes type checking ambiguity.

Vector types mathematically represent [vector spaces](https://en.wikipedia.org/wiki/Vector_space). Vectors by definition do not have multiplication between each other, but they come with scalar multiplication.

```swift
static func * (lhs: Vector, rhs: Scalar) -> Vector { ... }
```

By established convention in numerical computing communities such as machine learning, many libraries define a multiplication operator `*` between vectors as element-wise multiplication. Given that scalar multiplication has to exist by definition, element-wise multiplication and scalar multiplication would overload the `*` operator.

```swift
static func * (lhs: Vector, rhs: Vector) -> Vector { ... }
static func * (lhs: Vector, rhs: Scalar) -> Vector { ... }
```

This compiles, but does not work in practice. The following trivial use case would fail to compile, because literal  `1`  can be implicitly converted to both a  `Scalar`  and a  `Vector` , and  `*`  is overloaded for both  `Vector`  and  `Scalar` .

```swift
let x = Vector<Int>(...)
x * 1 // Ambiguous! Can be both `x * Vector(integerLiteral: 1)` and `x * (1 as Int)`.
```

## Proposed solution

We keep  `Numeric` 's behavior and requirements intact, and introduce a new protocol that
- does not require `ExpressibleByIntegerLiteral` conformance, and
- share common properties and operators between vectors and scalars.

To achieve these, we can try to find a mathematical concept that is close enough to makes practical sense without depending on unnecessary algebraic abstractions. This concept is additive group, containing a zero and all additive operators that are defined on `Numeric` today. `Numeric` will refine this new protocol, and vector types/protocols will conform to/refine the new protocol as well.

## Detailed design

We define a new protocol called  `AdditiveArithmetic` . This protocol requires all additive arithmetic operators that today's `Numeric` requires, and a zero. Zero is a fundamental property of an additive group.

```swift
public protocol AdditiveArithmetic: Equatable {
  static var zero: Self { get }
  prefix static func + (x: Self) -> Self
  static func + (lhs: Self, rhs: Self) -> Self
  static func += (lhs: inout Self, rhs: Self) -> Self
  static func - (lhs: Self, rhs: Self) -> Self
  static func -= (lhs: inout Self, rhs: Self) -> Self
}
```

Remove arithmetic operator requirements from  `Numeric` , and make  `Numeric`  refine  `AdditiveArithmetic` .

```swift
public protocol Numeric: AdditiveArithmetic, ExpressibleByIntegerLiteral  {
  associatedtype Magnitude: Comparable, Numeric
  init?<T>(exactly source: T) where T : BinaryInteger
  var magnitude: Self.Magnitude { get }
  static func * (lhs: Self, rhs: Self) -> Self
  static func *= (lhs: inout Self, rhs: Self) -> Self
}
```

To make sure today's  `Numeric` -conforming types do not have to define a  `zero` , we provide an extension to  `AdditiveArithmetic` constrained on  `Self: ExpressibleByIntegerLiteral` .

```swift
public extension AdditiveArithmetic where Self: ExpressibleByIntegerLiteral {
  static var zero: Self {
    return 0
  }
}
```

## Source compatibility

The proposed change is fully source-compatible.

## Effect on ABI stability

The proposed change will affect the existing ABI of the standard library, because it changes the protocol hierarchy and protocol requirements. As such, this protocol must be considered before the Swift 5 branching date.

## Effect on API resilience

The proposed change will affect the existing ABI, and there is no way to make it not affect the ABI because it changes the protocol hierarchy and protocol requirements.

## Alternatives considered

1. Make  `Numeric`  no longer refine  `ExpressibleByIntegerLiteral`  and not introduce any new protocol. This can solve the type checking ambiguity problem in vector protocols, but will break existing code: Functions generic over  `Numeric`  may use integer literals for initialization. Plus, Steve Canon also pointed out that it is not mathematically accurate -- there's a canonical homomorphism from the integers to every ring with unity. Moreover, it makes sense for vector types to conform to  `Numeric`  to get arithmetic operators, but it is uncommon to make vectors, esp. fixed-rank vectors, be expressible by integer literal.

2. On top of `AdditiveArithmetic`, add a `MultiplicativeArithmetic` protocol that refines `AdditiveArithmetic`, and make `Numeric` refine `MultiplicativeArithmetic`. This would be a natural extension to `AdditiveArithmetic`, but the practical benefit of this is unclear.
