# Protocol-oriented integers

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-updated-integers.md)
* Author(s): [Dave Abrahams](https://github.com/dabrahams), [Dmitri Gribenko](https://github.com/gribozavr), [Maxim Moiseev](https://github.com/moiseev)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal cleans up Swifts integer APIs and makes them more useful for
generic programming. At the same time it is **not** meant to solve the problem
of mixed-type arithmetic, which is a much more complicated topic, that we would
like to address with a different proposal some time in the future.

## Motivation

Various parts of Swifts integer APIs generate confusion. See
[this blog post](http://blog.krzyzanowskim.com/2015/03/01/swift_madness_of_generic_integer/)
for an example of an attempt to write an algorithm that is generic on any
integer.

`Integer` and `Arithmetic` protocols are not of much use, as they define all
binary operations on pairs of arguments with the same concrete type, thus
making generic programming impossible at the same time slowing down the type
checker, due to a large number of overloads.

There is no safe way to reliably convert an instance of any integer type to an
instance of any other integer type. One can only use `toIntMax` and then
`init(_: IntMax)`, but the initializer will trap if the value is not
representable in the target type.

Another annoying problem is the inability to use integers of different types in
comparison and bit-shift operations. For example, the following snippets won't
compile:

```Swift
var x: Int8 = 42
x << (1 as Int16) // error: binary operator '<<' cannot be applied to operands of type 'Int8' and 'Int16'
x > (0 as Int)    // error: binary operator '>' cannot be applied to operands of type 'Int8' and 'Int'
```

Current design predates many of the improvements that came in Swift 2, and
hasn't been revised since then.

<!--
Here is the basic layout of integer protocols as of Swift 2 and operations
defined by them:

```
         +---------------------+   +---------------------+
         |  IntegerArithmetic  |   |  BitwiseOperations  |
         +------------------+--+   ++--------------------+
                            ^       ^
                            |       |
+---------------------+   +-+-------+--+   +----------------+
|  RandomAccessIndex  |   |  _Integer  |   |  SignedNumber  |
+----------------+----+   +---+--------+   +------+---------+
                 ^            ^    ^---------+    ^
                 |            |              |    |
                 |        +---+-------+  +---+----+---------+
                 +--------+  Integer  |  |  _SignedInteger  |
                          ++----------+  +-----+------------+
                           ^          ^        |
                           |          |        |
         +-----------------+-+       ++--------+-------+
         |  UnsignedInteger  |       |  SignedInteger  |
         +-------------------+       +-----------------+
```

### `IntegerArithmetic`

- `+`
- `-`
- `*`
- `/`
- `%`
- `toIntMax`


### `BitwiseOperations`

- `&`
- `|`
- `^`
- `prefix ~`
- `static var allZeros`

### `RandomAccessIndex`

- GONE

### `SignedNumber`

- `prefix -`
- `-`
- `~>`

### `_Integer`

- combines other protocols

### `Integer`

- `_Integer` + `Strideable`

### `_SignedInteger`

- `toIntMax`
- `init(_:)`


### `SignedInteger`

- `_SignedInteger` + `Integer`

### `UnsignedInteger`

- `toUIntMax`

-->

## Proposed solution

We propose the new model that does not have above mentioned problems and is
more easily extendable.

~~~~
                +--------------+  +----------+
        +------>+  Arithmetic  |  |Comparable|
        |       +-------------++  +---+------+
        |                     ^       ^
+-------+------------+        |       |
|  SignedArithmetic  |      +-+-------+-+
+------+-------------+      |  Integer  |
       ^                    +----+------+
       |         +-----------^   ^     ^-----------+
       |         |               |                 |
+------+---------++    +---------+-----------+    ++------------------+
|  SignedInteger  |    |  FixedWidthInteger  |    |  UnsignedInteger  |
+---------------+-+    +-+-----------------+-+    ++------------------+
                ^        ^                 ^       ^
                |        |                 |       |
                |        |                 |       |
               ++--------+-+             +-+-------+-+
               |Int family |             |UInt family|
               +-----------+             +-----------+
~~~~

<!--
### `Arithmetic`

- `adding`
- `add`
- `subtracting`
- `subtract`
- `multiplied`
- `multiply`
- `divided`
- `divide`

### `SignedArithmetic`

- `negate`

### `Integer`

- `init<T : Integer>(_:T)`
- `init<T : Integer>(extendingOrTruncating:)`
- `init<T : Integer>(clamping:)`
- `absoluteValue`
- `isEqual(to:)`
- `isLess(than:)`
- `nthWord`
- `bitWidth`
- `remainder`
- `formRemainder`
- `quotientAndRemainder`

### `SignedInteger`

- `Integer` + `SignedArithmetic`

### `UnsignedInteger`

- `Integer`

### `FixedWidthInteger`

- `bitWidth`
- `min`
- `max`
- `addingWithOverflow`
- `subtractingWithOverflow`
- `multipliedWithOverflow`
- `dividedWithOverflow`
- `remainderWithOverflow`
- `and`
- `or`
- `xor`
- `maskingShiftRight`
- `maskingShiftLeft`
- `doubleWidthMultiply`
-->

There are several benefits provided by this model over the old one:

- It allows using integers in generic functions.

  The possibility to initialize instances of any concrete integer type with
values of any other concrete integer type enables writing functions that
operate on more than one type conforming to `Integer`, like, for example,
heterogeneous comparisons or bit shifts, described later.
  
- It removes the overload resolution overhead.

  Arithmetic and bitwise operations can now be defined as free functions
delegating work to the concrete types. This approach significantly reduces the
number of overloads for those operations, that used to be defined for every
single concrete integer type.
  
- It enables protocol sharing between integer and floating point types.

  Note the exclusion of the `%` operation from `Arithmetic`. Its behavior for
floating point numbers is sufficiently different from the one for integers, so
that using it in generic context would lead to confusion.
  
- It makes future extensions possible.

  The proposed model eliminates the 'largest integer type' concept (see
`toIntMax` in the current model), and instead operates on the level of machine
words. It also introduces the `doubleWidthMultiply` and `quotientAndRemainder`
methods. Together these changes can be used to provide an efficient
implementation of bignums, that would be hard to achieve otherwise.


## Detailed design

<!--
Prototype implementation can be found at
https://github.com/apple/swift/blob/master/test/Prototypes/Integers.swift.gyb
-->

### Protocols

#### `Arithmetic`

The `Arithmetic` protocol declares methods backing binary arithmetic operators,
such as `+`, `-` and `*`; and their mutating counterparts.

Both mutating and non-mutating operations are declared in the protocol, however
only the mutating ones are required, as non-mutating are provided by the
protocol extension.

```Swift
public protocol Arithmetic : Equatable, IntegerLiteralConvertible {
  init()

  func adding( rhs: Self) -> Self
  func subtracting( rhs: Self) -> Self
  func multiplied(by rhs: Self) -> Self
  func divided(by rhs: Self) -> Self

  mutating func add( rhs: Self)
  mutating func subtract( rhs: Self)
  mutating func multiply(by rhs: Self)
  mutating func divide(by rhs: Self)
}
```

#### `SignedArithmetic`

The `SignedArithmetic` is for the numbers that can be negated.
 
```Swift
public protocol SignedArithmetic : Arithmetic {
  func negate() -> Self
}
```

#### `Integer`

The `Integer` protocol is the basis for all the integer types provided by the
standard library.

The `isEqual(to:)` and `isLess(than:)` methods provide implementations for the
`Equatable` and `Comparable` protocol conformances. Similar to how arithmetic
operations are dispatched in `Arithmetic`, `==` and `<` operators for
homogeneous comparisons are implemented as generic free functions invoking
`isEqual(to:)` and `isLess(than:)` protocol methods respectively.

This protocol adds 3 new initializers to the parameterless one, inherited from
`Arithmetic`. These initializers allow to construct values of type from
instances of any other type, conforming to `Integer`, using different
strategies:

  - Perform checks whether the value is representable in `Self`
  
  - Try to represent the value without bounds checks
  
  - Substitute values beyond `Self` bounds with maximum/minimum value of
    `Self` respectively

The `Absolutevalue` associated type refers to the type that is able to hold an
absolute value of any possible value of `Self`.

Concrete types do not have to provide a typealias for it as it can be inferred
from the `absoluteValue` property. This property can be useful in operations
that are simpler to implement in terms of unsigned values, for example,
printing a value of an integer, which is just printing a '-' character in front
of an absolute value.

Please note, that `absoluteValue` property *should not* be preferred to the
`abs` function, who's return value is of the same type as its argument.

```Swift
public protocol Integer:
  Comparable, Arithmetic,
  IntegerLiteralConvertible, CustomStringConvertible {

  associatedtype AbsoluteValue : Integer // this is not the actual code

  static var isSigned: Bool { get }

  var absoluteValue: AbsoluteValue { get }

  func isEqual(to rhs: Self) -> Bool
  func isLess(than rhs: Self) -> Bool

  /// Creates an instance of `Self` from `source` if it is representable.
  ///
  /// - Precondition: the value of `source` is representable in `Self`.
  init<T : Integer>(_ source: T)

  /// Creates in instance of `Self` from `source` by sign-extending it
  /// indefinitely and then truncating to fit `Self`.
  init<T : Integer>(extendingOrTruncating source: T)

  /// Creates in instance of `Self` containing the closest representable
  /// value of `source`.
  init<T : Integer>(clamping source: T)

  /// Returns n-th word, counting from the right, of the underlying
  /// representation of `self`.
  func nthWord(n: Int) -> UInt

  /// The number of bits in current representation of `self`
  /// Will be constant for fixed-width integer types.
  var bitWidth : Int { get }

  /// TODO: check me
  /// If `self` is negative, returns the index of the least significant bit of
  /// its representation such that all more-significant bits are 1.
  /// Has the value -1 if `self` is 0.
  var signBitIndex: Int { get }

  /// Returns the remainder of division of `self` by `rhs`.
  func remainder(dividingBy rhs: Self) -> Self
  
  /// Replaces `self` with the remainder of division of `self` by `rhs`.
  mutating func formRemainder(dividingBy rhs: Self)

  /// Returns a pair of values, containing the quotient and the remainder of
  /// division of `self` by `rhs`.
  ///
  /// The default implementation simply invokes `divided(by:)` and
  /// `remainder(dividingBy:)`, which in case of built-in types will be fused
  /// into a single instruction by the compiler.
  ///
  /// Conforming types can override the default behavior in order to
  /// provide a more efficient implementation.
  func quotientAndRemainder(dividingBy rhs: Self) -> (Self, Self)
}
```

#### `FixedWidthInteger`

The `FixedWidthInteger` adds binary bitwise operations and bit shifts to the
`Integer` protocol.
 
The `WithOverflow` family of methods is used in default implementations of
mutating arithmetic methods (see `Arithmetic` protocol). Having these methods
allows to provide both safe implementations, that would check bounds, and
unsafe ones without duplicating code.
 
Bitwise binary and shift operators are implemented the same way as arithmetic
operations: free function dispatches a call to a corresponding protocol method.
 
The `doubleWidthMultiply` method is a necessary building block to implement
support for integer types of a greater width and, as a consequence, arbitrary
precision integers.

```Swift
public protocol FixedWidthInteger : Integer {
  /// Returns the bit width of the underlying binary
  /// representation of values of `self`.
  static var bitWidth : Int { get }

  /// Returns the maximum value representable by `Self`.
  static var max: Self { get }
  /// Returns the minimum value representable by 'Self'.
  static var min: Self { get }

  /// Adds `rhs` to `self` returning a pair containing the partial result
  /// of addition and an overflow flag.
  func addingWithOverflow(
     rhs: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Subtracts `rhs` from `self` returning a pair containing the partial
  /// result of subtraction and an overflow flag.
  func subtractingWithOverflow(
     rhs: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Multiplies `self` by `rhs` returning a pair containing the partial
  /// result of multiplication and an overflow flag.
  func multipliedWithOverflow(
    by rhs: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Divides `self` by `rhs` returning a pair containing the partial
  /// result of division and an overflow flag.
  func dividedWithOverflow(
    by rhs: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Returns the partial result of getting a remainder of division of `self`
  /// by `rhs`, and an overflow flag.
  func remainderWithOverflow(
    dividingBy rhs: Self
  ) -> (partialValue: Self, overflow: ArithmeticOverflow)

  /// Returns the result of the 'bitwise and' operation, applied
  /// to `self` and `rhs`.
  func and(rhs: Self) -> Self
  
  /// Returns the result of the 'bitwise or' operation, applied
  /// to `self` and `rhs`.
  func or(rhs: Self) -> Self
  
  /// Returns the result of the 'bitwise exclusive or' operation, applied
  /// to `self` and `rhs`.
  func xor(rhs: Self) -> Self
  
  /// Returns the result of shifting the binary representation
  /// of `self` by `rhs` binary digits to the right.
  func maskingShiftRight(rhs: Self) -> Self
  
  /// Returns the result of shifting the binary representation
  /// of `self` by `rhs` binary digits to the left.
  func maskingShiftLeft(rhs: Self) -> Self

  /// Returns a pair containing the `high` and `low` parts of the result
  /// of `self` multiplied by `rhs`.
  func doubleWidthMultiply(other: Self) -> (high: Self, low: AbsoluteValue)
}
```

#### Auxiliary protocols

```Swift
public protocol UnsignedInteger : Integer {
  associatedtype AbsoluteValue : Integer
}
public protocol SignedInteger : Integer, SignedArithmetic {
  associatedtype AbsoluteValue : Integer
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
public func % <T: Arithmetic>(lhs: T, rhs: T) -> T
public func %= <T: Arithmetic>(lhs: inout T, rhs: T)
```

##### Implementation example

_Only homogeneous arithmetic operations are supported._

The `+` operator is defined as a free function of two arguments of the same
type, conforming to the `Arithmetic` protocol, and is implemented in terms of
copying the left operand and calling `add` on it, returning the result. The
`FixedWidthInteger` protocol provides a default implementation for `add`, that
delegates work to `addingWithOverflow`, which is implemented efficiently by
every concrete type using intrinsics.


#### Masking arithmetics

```Swift
public func &* <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &- <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &+ <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
```

##### Implementation

These operators call `WithOverflow` family of methods from `FixedWidthInteger`
and simply return the `partialValue` part, ignoring the possible overflow.


#### Homogeneous comparison

```Swift
public func == <T : Integer>(lhs:T, rhs: T) -> Bool
public func != <T : Integer>(lhs:T, rhs: T) -> Bool
public func < <T : Integer>(lhs: T, rhs: T) -> Bool
public func > <T : Integer>(lhs: T, rhs: T) -> Bool
public func >= <T : Integer>(lhs: T, rhs: T) -> Bool
public func <= <T : Integer>(lhs: T, rhs: T) -> Bool
```

Implementation is similar to the homogeneous arithmetic operators above.


#### Heterogeneous comparison

```Swift
public func == <T : Integer, U : Integer>(lhs:T, rhs: U) -> Bool
public func != <T : Integer, U : Integer>(lhs:T, rhs: U) -> Bool
public func < <T : Integer, U : Integer>(lhs: T, rhs: U) -> Bool
public func > <T : Integer, U : Integer>(lhs: T, rhs: U) -> Bool
public func >= <T : Integer, U : Integer>(lhs: T, rhs: U) -> Bool
public func <= <T : Integer, U : Integer>(lhs: T, rhs: U) -> Bool
```

##### Implementation example

The overloaded version of `==` operator accepts two arguments of different
types both conforming to `Integer` protocol. One of the arguments then gets
transformed into the value of the type of another using the
`extendingOrTruncating` initializer, introduced by the `Integer` protocol, and
a homogeneous version of `==` is called, which, as in the example above,
delegates all the work to `isEqual(to:)` method, implemented by every concrete
type.


#### Shifts

```Swift
public func << <T: FixedWidthInteger, U: Integer>(lhs: T, rhs: U) -> T
public func << <T: FixedWidthInteger>(lhs: T, rhs: Word) -> T
public func <<= <T: FixedWidthInteger, U: Integer>(lhs: inout T, rhs: U)
public func <<= <T: FixedWidthInteger>(lhs: inout T, rhs: T)

public func >> <T: FixedWidthInteger, U: Integer>(lhs: T, rhs: U) -> T
public func >> <T: FixedWidthInteger>(lhs: T, rhs: Word) -> T
public func >>= <T: FixedWidthInteger>(lhs: inout T, rhs: T)
public func >>= <T: FixedWidthInteger, U: Integer>(lhs: inout T, rhs: U)

public func &<< <T: FixedWidthInteger, U: Integer>(lhs: T, rhs: U) -> T
public func &<< <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &<<= <T: FixedWidthInteger, U: Integer>(lhs: inout T, rhs: U)
public func &<<= <T: FixedWidthInteger>(lhs: inout T, rhs: T)

public func &>> <T: FixedWidthInteger, U: Integer>(lhs: T, rhs: U) -> T
public func &>> <T: FixedWidthInteger>(lhs: T, rhs: T) -> T
public func &>>= <T: FixedWidthInteger, U: Integer>(lhs: inout T, rhs: U)
public func &>>= <T: FixedWidthInteger>(lhs: inout T, rhs: T)
```

##### Implementation example (mixed-type left shift)

The implementation is similar to the heterogeneous comparison. The only
difference is that it is hard to define what a left shift would mean to an
infinitely large integer, therefore we only allow shifts where left operand
conforms to the `FixedWidthInteger` protocol. Right operand, however, can be an
arbitrary `Integer`. Other than that, the implementation technique should
already be familiar from the sections above: generic function delegates task to
a non-generic one, implemented efficiently on a concrete type.


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

Existing code that does not implement its own integer types (or rely on
existing protocol hierarchy in any other way) should not be affected. It will
be slightly wordier due to all the type conversions that are no longer
required, but will continue to work. Migration is possible but not strictly
necessary.


## Non-goals

This proposal:

- *DOES NOT* solve the integer promotion problem, which would allow mixed-type
  arithmetic. However, we believe that it is an important step in the right
  direction.

- *DOES NOT* include the implementation of a `BigInt` type, but allows it
  to be implemented in the future.
