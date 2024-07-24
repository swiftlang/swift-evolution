# Make  `Numeric`  Refine a new  `AdditiveArithmetic`  Protocol

* Proposal: [SE-0233](0233-additive-arithmetic-protocol.md)
* Author: [Richard Wei](https://github.com/rxwei)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status:  **Implemented (Swift 5.0)**
* Implementation: [apple/swift#20422](https://github.com/apple/swift/pull/20422)
* Decision Notes: [Rationale](https://forums.swift.org/t/accepted-se-0233-make-numeric-refine-a-new-additivearithmetic-protocol/17751)

## Introduction

This proposal introduces a weakening of the existing  `Numeric`  protocol named  `AdditiveArithmetic` , which defines additive arithmetic operators and a zero, making conforming types roughly correspond to the mathematic notion of an [additive group](https://en.wikipedia.org/wiki/Additive_group). This makes it possible for vector types to share additive arithmetic operators with scalar types, which enables generic algorithms over `AdditiveArithmetic` to apply to both scalars and vectors.

Discussion thread: [Should Numeric not refine ExpressibleByIntegerLiteral](https://forums.swift.org/t/should-numeric-not-refine-expressiblebyintegerliteral/15106)

## Motivation

The  `Numeric`  protocol today refines  `ExpressibleByIntegerLiteral`  and defines all arithmetic operators. The design makes it easy for scalar types to adopt arithmetic operators, but makes it hard for vector types to adopt arithmetic operators by conforming to this protocol.

What's wrong with `Numeric`? Assuming that we need to conform to `Numeric` to get basic arithmetic operators and generic algorithms, we have three problems.

### 1. Vectors conforming to `Numeric` would be mathematically incorrect.

`Numeric` roughly corresponds to a [ring](https://en.wikipedia.org/wiki/Ring_(mathematics)). Vector spaces are not rings. Multiplication is not defined between vectors. Requirements `*` and `*=` below would make vector types inconsistent with the mathematical definition.

```swift
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
- shares common properties and operators between vectors and scalars.

To achieve these, we can try to find a mathematical concept that is close enough to makes practical sense without depending on unnecessary algebraic abstractions. This concept is additive group, containing a zero and all additive operators that are defined on `Numeric` today. `Numeric` will refine this new protocol, and vector types/protocols will conform to/refine the new protocol as well.

## Detailed design

We define a new protocol called  `AdditiveArithmetic` . This protocol requires all additive arithmetic operators that today's `Numeric` requires, and a zero. Zero is a fundamental property of an additive group.

```swift
public protocol AdditiveArithmetic: Equatable {
  /// A zero value.
  static var zero: Self { get }

  /// Adds two values and produces their sum.
  ///
  /// The addition operator (`+`) calculates the sum of its two arguments. For
  /// example:
  ///
  ///     1 + 2                   // 3
  ///     -10 + 15                // 5
  ///     -15 + -5                // -20
  ///     21.5 + 3.25             // 24.75
  ///
  /// You cannot use `+` with arguments of different types. To add values of
  /// different types, convert one of the values to the other value's type.
  ///
  ///     let x: Int8 = 21
  ///     let y: Int = 1000000
  ///     Int(x) + y              // 1000021
  ///
  /// - Parameters:
  ///   - lhs: The first value to add.
  ///   - rhs: The second value to add.
  static func + (lhs: Self, rhs: Self) -> Self
  
  /// Adds two values and stores the result in the left-hand-side variable.
  ///
  /// - Parameters:
  ///   - lhs: The first value to add.
  ///   - rhs: The second value to add.
  static func += (lhs: inout Self, rhs: Self) -> Self
  
  /// Subtracts one value from another and produces their difference.
  ///
  /// The subtraction operator (`-`) calculates the difference of its two
  /// arguments. For example:
  ///
  ///     8 - 3                   // 5
  ///     -10 - 5                 // -15
  ///     100 - -5                // 105
  ///     10.5 - 100.0            // -89.5
  ///
  /// You cannot use `-` with arguments of different types. To subtract values
  /// of different types, convert one of the values to the other value's type.
  ///
  ///     let x: UInt8 = 21
  ///     let y: UInt = 1000000
  ///     y - UInt(x)             // 999979
  ///
  /// - Parameters:
  ///   - lhs: A numeric value.
  ///   - rhs: The value to subtract from `lhs`.
  static func - (lhs: Self, rhs: Self) -> Self
  
  /// Subtracts the second value from the first and stores the difference in the
  /// left-hand-side variable.
  ///
  /// - Parameters:
  ///   - lhs: A numeric value.
  ///   - rhs: The value to subtract from `lhs`.
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
extension AdditiveArithmetic where Self: ExpressibleByIntegerLiteral {
  public static var zero: Self {
    return 0
  }
}
```

In the existing standard library, prefix `+` is provided by an extension to
`Numeric`. Since additive arithmetics are now defined on `AdditiveArithmetic`,
we change this extension to apply to `AdditiveArithmetic`.

```swift
extension AdditiveArithmetic {
  /// Returns the given number unchanged.
  ///
  /// You can use the unary plus operator (`+`) to provide symmetry in your
  /// code for positive numbers when also using the unary minus operator.
  ///
  ///     let x = -21
  ///     let y = +21
  ///     // x == -21
  ///     // y == 21
  ///
  /// - Returns: The given argument without any changes.
  public static prefix func + (x: Self) -> Self {
    return x
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

3. Instead of a `zero` static computed property requirement, an `init()` could be used instead, and this would align well with Swift's preference for initializers. However, this would force conforming types to have an `init()`, which in some cases could be confusing or misleading. For example, it would be unclear whether `Matrix()` is creating a zero matrix or an identity matrix. Spelling it as `zero` eliminates that ambiguity.
