# Protocol-oriented integers

* Proposal: [SE-0104](0104-improved-integers.md)
* Authors: [Dave Abrahams](https://github.com/dabrahams), [Dmitri Gribenko](https://github.com/gribozavr), [Maxim Moiseev](https://github.com/moiseev)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Accepted**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000206.html)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/0440700fc555a6c72abb4af807c8b79fb1bec592/proposals/0104-improved-integers.md)
* Bug: [SR-3196](https://bugs.swift.org/browse/SR-3196)

## Introduction

This proposal cleans up Swifts integer APIs and makes them more useful for
generic programming.

## Motivation

Swift's integer protocols don't currently provide a suitable basis for generic
programming. See [this blog post](http://blog.krzyzanowskim.com/2015/03/01/swift_madness_of_generic_integer/)
for an example of an attempt to implement a generic algorithm over integers.

The way the `Arithmetic` protocol is defined, it does not generalize to floating
point numbers and also slows down compilation by requiring every concrete
type to provide an implementation of arithmetic operators as free functions,
thus polluting the overload set.

Converting from one integer type to another is performed using the concept of
the 'maximum width integer' (see `MaxInt`), which is an artificial limitation.
The very existence of `MaxInt` makes it unclear what to do, should someone
implement `Int256`, for example.

Another annoying problem is the inability to use integers of different types in
comparison and bit-shift operations. For example, the following snippets won't
compile:

```Swift
var x: Int8 = 42
let y = 1
let z = 0

x <<= y   // error: binary operator '<<=' cannot be applied to operands of type 'Int8' and 'Int'
if x > z { ... }  // error: binary operator '>' cannot be applied to operands of type 'Int8' and 'Int'
```

Currently, bit-shifting a negative number of (or too many) bits causes a trap
on some platforms, which makes low-level bit manipulations needlessly dangerous
and unpredictable.

Finally, the current design predates many of the improvements that came in
Swift 2, and hasn't been revised since then.


## Proposed solution

We propose a new model that does not have above mentioned problems and is
more easily extensible.

~~~~
                +--------------+  +-------------+
        +------>+  Arithmetic  |  | Comparable  |
        |       |   (+,-,*,/)  |  | (==,<,>,...)|
        |       +-------------++  +---+---------+
        |                     ^       ^
+-------+------------+        |       |
|  SignedArithmetic  |      +-+-------+------+
|     (unary -)      |      |  BinaryInteger |
+------+-------------+      |  (words,%,...) |
       ^                    ++---+-----+-----+
       |         +-----------^   ^     ^-----------+
       |         |               |                 |
+------+---------++    +---------+-------------+  ++------------------+
|  SignedInteger  |    |  FixedWidthInteger    |  |  UnsignedInteger  |
|                 |    | (bitwise,overflow,...)|  |                   |
+---------------+-+    +-+-----------------+---+  ++------------------+
                ^        ^                 ^       ^
                |        |                 |       |
                |        |                 |       |
               ++--------+-+             +-+-------+-+
               |Int family |-+           |UInt family|-+
               +-----------+ |           +-----------+ |
                 +-----------+             +-----------+
~~~~


There are several benefits provided by this model over the old one:

- It allows mixing integer types in generic functions.

  The possibility to initialize instances of any concrete integer type with
values of any other concrete integer type enables writing functions that
operate on more than one type conforming to `BinaryInteger`, such as heterogeneous
comparisons or bit shifts, described later.

- It removes the overload resolution overhead.

  Arithmetic and bitwise operations can now be defined as free functions
delegating work to concrete types. This approach significantly reduces the
number of overloads for those operations, which used to be defined for every
single concrete integer type.

- It enables protocol sharing between integer and floating point types.

  Note the exclusion of the `%` operation from `Arithmetic`. Its behavior for
floating point numbers is sufficiently different from the one for integers that
using it in generic context would lead to confusion. The `FloatingPoint` protocol
introduced by
[SE-0067](https://github.com/apple/swift-evolution/blob/0440700fc555a6c72abb4af807c8b79fb1bec592/proposals/0104-improved-integers.md)
should now refine `SignedArithmetic`.

- It makes future extensions possible.

  The proposed model eliminates the 'largest integer type' concept previously used
to interoperate between integer types (see `toIntMax` in the current model) and
instead provides access to machine words. It also introduces the
`doubleWidthMultiply`, `doubleWidthDivide`, and `quotientAndRemainder` methods.
Together these changes can be used to provide an efficient implementation of
bignums that would be hard to achieve otherwise.

The prototype implementation, available
[here](https://github.com/apple/swift/blob/master/test/Prototypes/Integers.swift.gyb)
contains a `DoubleWidth` generic type that uses two values of any
`FixedInteger` type to represent a value of twice the width, demonstrating the
suitability of the proposed model for generic programming.


### A note on bit shifts

This proposal introduces the concepts of *smart shifts* and *masking shifts*.

The semantics of shift operations are
[often undefined](http://llvm.org/docs/LangRef.html#bitwise-binary-operations)
in under- or over-shift cases. *Smart shifts*, implemented by `>>` and `<<`,
are designed to address this problem and always behave in a well defined way,
as shown in the examples below:

- `x << -2` is equivalent to `x >> 2`

- `(1 as UInt8) >> 42)` will evaluate to `0`

- `(-128 as Int8) >> 42)` will evaluate to `0xff` or `-1`

In most scenarios, the right hand operand is a literal constant, and branches
for handling under- and over-shift cases can be optimized away.  For other
cases, this proposal provides *masking shifts*, implemented by `&>>` and `&<<`.
A masking shift logically preprocesses the right hand operand by masking its
bits to produce a value in the range `0...(x-1)` where `x` is the number of
bits in the left hand operand.  On most architectures this masking is already
performed by the CPU's shift instructions and has no cost.  Both kinds of shift
avoid undefined behavior and produce uniform semantics across architectures.


## Detailed design

### Protocols

#### `Arithmetic`

The `Arithmetic` protocol declares methods backing binary arithmetic
operators—such as `+`, `-` and `*`—and their mutating counterparts.

It provides a suitable basis for arithmetic on scalars such as integers and
floating point numbers.

Both mutating and non-mutating operations are declared in the protocol, however
only the mutating ones are required, as default implementations of the
non-mutating ones are provided by a protocol extension.

The `Magnitude` associated type is able to hold the absolute value of any
possible value of `Self`. Concrete types do not have to provide a typealias for
it, as it can be inferred from the `magnitude` property. This property can
be useful in operations that are simpler to implement in terms of unsigned
values, for example, printing a value of an integer, which is just printing a
'-' character in front of an absolute value.

Please note that for ordinary work, the `magnitude` property **should not**
be preferred to the `abs(_)` function, whose return value is of the same type
as its argument.


```Swift
public protocol Arithmetic : Equatable, IntegerLiteralConvertible {
  /// Initializes to the value of `source` if it is representable exactly,
  /// returns `nil` otherwise.
  init?<T : BinaryInteger>(exactly source: T)

  associatedtype Magnitude : Arithmetic
  var magnitude: Magnitude { get }

  func adding(_ other: Self) -> Self
  func subtracting(_ other: Self) -> Self
  func multiplied(by other: Self) -> Self
  func divided(by other: Self) -> Self

  mutating func add(_ other: Self)
  mutating func subtract(_ other: Self)
  mutating func multiply(by other: Self)
  mutating func divide(by other: Self)
}

extension Arithmetic {
  public init() { self = 0 }
}
```

#### `SignedArithmetic`

The `SignedArithmetic` protocol is for numbers that can be negated.

```Swift
public protocol SignedArithmetic : Arithmetic {
  func negated() -> Self
  mutating func negate()
}

extension SignedArithmetic {
  public func negated() -> Self {
    return Self() - self
  }
  public mutating func negate() {
    self = negated()
  }
}
```

#### `BinaryInteger`

The `BinaryInteger` protocol is the basis for all the integer types provided by the
standard library.

The `isEqual(to:)` and `isLess(than:)` methods provide implementations for
`Equatable` and `Comparable` protocol conformances. Similar to how arithmetic
operations are dispatched in `Arithmetic`, `==` and `<` operators for
homogeneous comparisons are implemented as generic free functions invoking the
`isEqual(to:)` and `isLess(than:)` protocol methods respectively.

This protocol adds 4 new initializers. One of them allows to create integers
from floating point numbers, if the value is representable exactly, others
support construction from instances of any type conforming to `BinaryInteger`, using
different strategies:

  - Initialze `Self` with the value, provided that the value is representable.
    The precondition should be satisfied by the caller.

  - Extend or truncate the value to fit into `Self`

  - Clamp the value to the representable range of `Self`

```Swift
public protocol BinaryInteger:
  Comparable, Arithmetic,
  IntegerLiteralConvertible, CustomStringConvertible {

  static var isSigned: Bool { get }

  func isEqual(to other: Self) -> Bool
  func isLess(than other: Self) -> Bool

  /// Creates an instance of `Self` that has the exact value of `source`,
  /// returns `nil` otherwise.
  init?<T : FloatingPoint>(exactly source: T)

  /// Truncates the `source` to the closest representable value of `Self`.
  init<T : FloatingPoint>(_ source: T)

  /// Creates an instance of `Self` from `source` if it is representable.
  ///
  /// - Precondition: the value of `source` is representable in `Self`.
  init<T : BinaryInteger>(_ source: T)

  /// Creates in instance of `Self` from `source` by sign-extending it
  /// indefinitely and then truncating to fit `Self`.
  init<T : BinaryInteger>(extendingOrTruncating source: T)

  /// Creates in instance of `Self` containing the closest representable
  /// value of `source`.
  init<T : BinaryInteger>(clamping source: T)

  /// Returns the n-th word, counting from the least significant to most
  /// significant, of the underlying representation of `self`.
  /// Should return `0` for positive numbers and `~0` for negative ones if `n`
  /// is greater than the number of words in current representation of `self`.
  func word(at n: Int) -> UInt

  /// The number of bits in current representation of `self`
  /// Will be constant for fixed-width integer types.
  var bitWidth : Int { get }

  /// The number of bits required to represent the value of `self` in a signed
  /// type using two's complement representation. The minimum value for this
  /// property should naturally be 1.
  var minimumSignedRepresentationBitWidth: Int { get }

  /// Returns the remainder of division of `self` by `other`.
  func remainder(dividingBy other: Self) -> Self

  /// Replaces `self` with the remainder of division of `self` by `other`.
  mutating func formRemainder(dividingBy other: Self)

  /// Returns a pair of values, containing the quotient and the remainder of
  /// division of `self` by `other`.
  ///
  /// The default implementation simply invokes `divided(by:)` and
  /// `remainder(dividingBy:)`, which in case of built-in types will be fused
  /// into a single instruction by the compiler.
  ///
  /// Conforming types can override the default behavior in order to
  /// provide a more efficient implementation.
  func quotientAndRemainder(dividingBy other: Self) -> (Self, Self)
}
```

#### `FixedWidthInteger`

The `FixedWidthInteger` protocol adds binary bitwise operations and bit shifts
to the `BinaryInteger` protocol.

The `WithOverflow` family of methods is used in default implementations of
mutating arithmetic methods (see the `Arithmetic` protocol). Having these
methods allows the library to provide both bounds-checked and masking
implementations of arithmetic operations, without duplicating code.

Bitwise binary and shift operators are implemented the same way as arithmetic
operations: a free function dispatches a call to a corresponding protocol
method.

The `doubleWidthMultiply` and `doubleWidthDivide` methods are necessary building
blocks to implement support for integer types of a greater width such as
arbitrary-precision integers.

```Swift
public protocol FixedWidthInteger : BinaryInteger {
  /// Returns the bit width of the underlying binary
  /// representation of values of `self`.
  static var bitWidth : Int { get }

  /// Returns the maximum value representable by `Self`.
  static var max: Self { get }
  /// Returns the minimum value representable by 'Self'.
  static var min: Self { get }

  /// Adds `other` to `self` returning a pair containing the partial result
  /// of addition and an overflow flag.
  func addingWithOverflow(
     other: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Subtracts `other` from `self` returning a pair containing the partial
  /// result of subtraction and an overflow flag.
  func subtractingWithOverflow(
     other: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Multiplies `self` by `other` returning a pair containing the partial
  /// result of multiplication and an overflow flag.
  func multipliedWithOverflow(
    by other: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Divides `self` by `other` returning a pair containing the partial
  /// result of division and an overflow flag.
  func dividedWithOverflow(
    by other: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Returns the partial result of getting a remainder of division of `self`
  /// by `other`, and an overflow flag.
  func remainderWithOverflow(
    dividingBy other: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Returns the result of the 'bitwise and' operation, applied
  /// to `self` and `other`.
  func bitwiseAnd(other: Self) -> Self

  /// Returns the result of the 'bitwise or' operation, applied
  /// to `self` and `other`.
  func bitwiseOr(other: Self) -> Self

  /// Returns the result of the 'bitwise exclusive or' operation, applied
  /// to `self` and `other`.
  func bitwiseXor(other: Self) -> Self

  /// Returns the result of shifting the binary representation
  /// of `self` by `other` binary digits to the right.
  func maskingShiftRight(other: Self) -> Self

  /// Returns the result of shifting the binary representation
  /// of `self` by `other` binary digits to the left.
  func maskingShiftLeft(other: Self) -> Self

  /// Returns a pair containing the `high` and `low` parts of the result
  /// of `lhs` multiplied by `rhs`.
  static func doubleWidthMultiply(_ lhs: Self, _ rhs: Self)
    -> (high: Self, low: Magnitude)

  /// Returns a pair containing a quotient and a remainder of `lhs` divided by
  /// `rhs`, where `lhs` is itself a pair of `high` and `low` words of a double
  /// width number.
  static func doubleWidthDivide(
    _ lhs: (high: Self, low: Magnitude), _ rhs: Self
  ) -> (quotient: Self, remainder: Self)


  /// Returns a number of set (i.e. equal to 1) bits in the representation of
  /// `self`.
  var popcount: Int { get }

  /// Returns the number of leading zeros in the representation of `self`.
  var leadingZeros: Int { get }
}
```

#### Auxiliary protocols

```Swift
public protocol UnsignedInteger : BinaryInteger {
  associatedtype Magnitude : BinaryInteger
}
public protocol SignedInteger : BinaryInteger, SignedArithmetic {
  associatedtype Magnitude : BinaryInteger
}
```


### Operators

#### Arithmetic

```Swift
public func + <T: Arithmetic>(lhs: T, rhs: T) -> T
public func += <T: Arithmetic>(lhs: inout T, rhs: T)
public func - <T: Arithmetic>(lhs: T, rhs: T) -> T
public func -= <T: Arithmetic>(lhs: inout T, rhs: T)
public func * <T: Arithmetic>(lhs: T, rhs: T) -> T
public func *= <T: Arithmetic>(lhs: inout T, rhs: T)
public func / <T: Arithmetic>(lhs: T, rhs: T) -> T
public func /= <T: Arithmetic>(lhs: inout T, rhs: T)
public func % <T: BinaryInteger>(lhs: T, rhs: T) -> T
public func %= <T: BinaryInteger>(lhs: inout T, rhs: T)
```

##### Implementation example

_Only homogeneous arithmetic operations are supported._

```Swift
public func + <T: Arithmetic>(lhs: T, rhs: T) -> T {
  return lhs.adding(rhs)
}

extension Arithmetic {
  public func adding(_ rhs: Self) -> Self {
    var lhs = self
    lhs.add(rhs)
    return lhs
  }
}

extension FixedWidthInteger {
  public mutating func add(_ rhs: Self) {
    let (result, overflow) = self.addingWithOverflow(rhs)
    self = result
  }
}

public struct Int8 {
  public func addingWithOverflow(_ rhs: DoubleWidth<T>)
    -> (partialValue: DoubleWidth<T>, overflow: ArithmeticOverflow) {
    // efficient implementation
  }
}
```


#### Masking arithmetic

```Swift
public func &* <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &- <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &+ <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
```

##### Implementation

These operators call `WithOverflow` family of methods from `FixedWidthInteger`
and simply return the `partialValue` part, ignoring the possible overflow.

```Swift
public func &+ <T: FixedWidthInteger>(lhs: T, rhs: T) -> T {
  return lhs.addingWithOverflow(rhs).partialValue
}

public struct Int8 {
  public func addingWithOverflow(_ other: DoubleWidth<T>)
    -> (partialValue: DoubleWidth<T>, overflow: ArithmeticOverflow) {
    // efficient implementation
  }
}
```


#### Homogeneous comparison

```Swift
public func == <T : BinaryInteger>(lhs:T, rhs: T) -> Bool
public func != <T : BinaryInteger>(lhs:T, rhs: T) -> Bool
public func < <T : BinaryInteger>(lhs: T, rhs: T) -> Bool
public func > <T : BinaryInteger>(lhs: T, rhs: T) -> Bool
public func >= <T : BinaryInteger>(lhs: T, rhs: T) -> Bool
public func <= <T : BinaryInteger>(lhs: T, rhs: T) -> Bool
```

The implementation is similar to the homogeneous arithmetic operators above.


#### Heterogeneous comparison

```Swift
public func == <T : BinaryInteger, U : BinaryInteger>(lhs:T, rhs: U) -> Bool
public func != <T : BinaryInteger, U : BinaryInteger>(lhs:T, rhs: U) -> Bool
public func < <T : BinaryInteger, U : BinaryInteger>(lhs: T, rhs: U) -> Bool
public func > <T : BinaryInteger, U : BinaryInteger>(lhs: T, rhs: U) -> Bool
public func >= <T : BinaryInteger, U : BinaryInteger>(lhs: T, rhs: U) -> Bool
public func <= <T : BinaryInteger, U : BinaryInteger>(lhs: T, rhs: U) -> Bool
```

##### Implementation example

```Swift
public func == <T : BinaryInteger, U : BinaryInteger>(lhs:T, rhs: U) -> Bool {
  return (lhs > 0) == (rhs > 0)
    && T(extendingOrTruncating: rhs) == lhs
    && U(extendingOrTruncating: lhs) == rhs
}

extension FixedWidthInteger {
  public init<T : BinaryInteger>(extendingOrTruncating source: T) {
    // converting `source` into the value of `Self`
  }
}
```


#### Shifts

```Swift
public func << <T: FixedWidthInteger, U: BinaryInteger>(lhs: T, rhs: U) -> T
public func << <T: FixedWidthInteger>(lhs: T, rhs: Word) -> T
public func <<= <T: FixedWidthInteger, U: BinaryInteger>(lhs: inout T, rhs: U)
public func <<= <T: FixedWidthInteger>(lhs: inout T, rhs: T)

public func >> <T: FixedWidthInteger, U: BinaryInteger>(lhs: T, rhs: U) -> T
public func >> <T: FixedWidthInteger>(lhs: T, rhs: Word) -> T
public func >>= <T: FixedWidthInteger>(lhs: inout T, rhs: T)
public func >>= <T: FixedWidthInteger, U: BinaryInteger>(lhs: inout T, rhs: U)

public func &<< <T: FixedWidthInteger, U: BinaryInteger>(lhs: T, rhs: U) -> T
public func &<< <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &<<= <T: FixedWidthInteger, U: BinaryInteger>(lhs: inout T, rhs: U)
public func &<<= <T: FixedWidthInteger>(lhs: inout T, rhs: T)

public func &>> <T: FixedWidthInteger, U: BinaryInteger>(lhs: T, rhs: U) -> T
public func &>> <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &>>= <T: FixedWidthInteger, U: BinaryInteger>(lhs: inout T, rhs: U)
public func &>>= <T: FixedWidthInteger>(lhs: inout T, rhs: T)
```

##### Notes on the implementation of mixed-type shifts

The implementation is similar to the heterogeneous comparison. The only
difference is that because shifting left truncates the high bits of fixed-width
integers, it is hard to define what a left shift would mean to an
arbitrary-precision integer.  Therefore we only allow shifts where the left
operand conforms to the `FixedWidthInteger` protocol. The right operand,
however, can be an arbitrary `BinaryInteger`.

#### Bitwise operations

```Swift
public func | <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func |= <T: FixedWidthInteger>(lhs: inout T, rhs: T)
public func & <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &= <T: FixedWidthInteger>(lhs: inout T, rhs: T)
public func ^ <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func ^= <T: FixedWidthInteger>(lhs: inout T, rhs: T)
```


## Impact on existing code

The new model is designed to be a drop-in replacement for the current one.  One
feature that has been deliberately removed is the concept of `the widest
integer type`, which will require a straightforward code migration.

Existing code that does not implement its own integer types (or rely on the
existing protocol hierarchy in any other way) should not be affected. It may
be slightly wordier than necessary due to all the type conversions that are
no longer required, but will continue to work.


## Non-goals

This proposal:

- *DOES NOT* solve the integer promotion problem, which would allow mixed-type
  arithmetic. However, we believe that it is an important step in the right
  direction.

- *DOES NOT* include the implementation of a `BigInt` type, but allows it
  to be implemented in the future.

- *DOES NOT* propose including a `DoubleWidth` integer type in the standard
  library, but provides a proof-of-concept implementation.
