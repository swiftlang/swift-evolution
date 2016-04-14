# Enhanced Floating Point Protocols

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Stephen Canon](https://github.com/stephentyrone)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

The current FloatingPoint protocol is quite limited, and provides only a small
subset of the features expected of an IEEE 754 conforming type.  This proposal
expands the protocol to cover most of the expected basic operations, and adds
a second protocol, BinaryFloatingPoint, that provides a number of useful tools
for generic programming with FloatingPoint types.

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution)

## Motivation

Beside the high-level motivation provided by the introduction, the proposed
prototype schema addresses a number of issues that have been reported:

- FloatingPoint should conform to Equatable, and Comparable
- FloatingPoint should conform to FloatLiteralConvertible
- Deprecate the `%` operator for floating-point types
- Provide basic constants (analogues of C's DBL_MAX, etc.)
- Make Float80 conform to FloatingPoint
- Add public initializer and property for integer representation

It also puts FloatingPoint much more tightly in sync with the work that is
being done on protocols for Integers, which will make it easier to provide
a uniform interface for arithmetic scalar types.

## Detailed design

A new protocol, `Arithmetic`, is introduced that provides the most basic
operations (add, subtract, multiply and divide) as well as `Equatable` and
`IntegerLiteralConvertible`, and is conformed to by both integer and floating-
point types.

There has been some resistance to adding such a protocol, owing to differences
in behavior between floating point and integer arithmetic.  While these
differences make it difficult to write correct generic code that operates
on all "arithmetic" types, it is nonetheless convenient to provide a single
protocol that guarantees the availability of these basic operations.  It is
intended that "number-like" types should provide these APIs.

```swift
/// Arithmetic protocol declares methods backing binary arithmetic operators,
/// such as  `+`, `-` and `*`; and their mutating counterparts. These methods
/// operate on arguments of the same type.
///
/// Both mutating and non-mutating operations are declared in the protocol, but
/// only the mutating ones are required. Should conforming type omit
/// non-mutating implementations, they will be provided by a protocol extension.
/// Implementation in that case will copy `self`, perform a mutating operation
/// on it and return the resulting value.
public protocol Arithmetic: Equatable, IntegerLiteralConvertible {
  /// Initialize to zero
  init()

  /// The sum of `self` and `rhs`.
  //  Arithmetic provides a default implementation of this method in terms
  //  of the mutating `add` operation.
  @warn_unused_result
  func adding(rhs: Self) -> Self

  /// Adds `rhs` to `self`.
  mutating func add(rhs: Self)

  /// The result of subtracting `rhs` from `self`.
  //  Arithmetic provides a default implementation of this method in terms
  //  of the mutating `subtract` operation.
  @warn_unused_result
  func subtracting(rhs: Self) -> Self

  /// Subtracts `rhs` from `self`.
  mutating func subtract(rhs: Self)

  /// The product of `self` and `rhs`.
  //  Arithmetic provides a default implementation of this method in terms
  //  of the mutating `multiply` operation.
  @warn_unused_result
  func multiplied(by rhs: Self) -> Self

  /// Multiplies `self` by `rhs`.
  mutating func multiply(by rhs: Self)

  /// The quotient of `self` dividing by `rhs`.
  //  Arithmetic provides a default implementation of this method in terms
  //  of the mutating `divide` operation.
  @warn_unused_result
  func divided(by rhs: Self) -> Self

  /// Divides `self` by `rhs`.
  mutating func divide(by rhs: Self)
}

/// SignedArithmetic protocol will only be conformed to by signed numbers,
/// otherwise it would be possible to negate an unsigned value.
///
/// The only method of this protocol has the default implementation in an
/// extension, that uses a parameterless initializer and subtraction.
public protocol SignedArithmetic : Arithmetic {
  func negate() -> Self
}
```

The arithmetic operators are then defined in terms of the implementation hooks
provided by `Arithmetic` and `SignedArithmetic`, so providing those operations
are all that is necessary for a type to present a "number-like" interface.

The `FloatingPoint` protocol is split into two parts; `FloatingPoint` and
`BinaryFloatingPoint`, which conforms to `FloatingPoint`.  If decimal
types were added at some future point, they would conform to
`DecimalFloatingPoint`.

`FloatingPoint` is expanded to contain most of the IEEE 754 basic
operations, as well as conformance to `SignedArithmetic` and `Comparable`.

```swift
/// A floating-point type that provides most of the IEEE 754 basic (clause 5)
/// operations.  The base, precision, and exponent range are not fixed in
/// any way by this protocol, but it enforces the basic requirements of
/// any IEEE 754 floating-point type.
///
/// The BinaryFloatingPoint protocol refines these requirements and provides
/// some additional useful operations as well.
public protocol FloatingPoint: SignedArithmetic, Comparable {

  /// An unsigned integer type that can represent any significand.
  associatedtype RawSignificand: UnsignedInteger

  /// 2 for binary floating-point types, 10 for decimal.
  ///
  /// A conforming type may use any integer radix, but values other than
  /// 2 or 10 are extraordinarily rare in practice.
  static var radix: Int { get }

  /// Positive infinity.  Compares greater than all finite numbers.
  static var infinity: Self { get }

  /// A quiet NaN (not-a-number).  Compares not equal to every value,
  /// including itself.
  static var nan: Self { get }

  /// NaN with specified `payload`.
  ///
  /// Compares not equal to every value, including itself.  Most operations
  /// with a NaN operand will produce a NaN result.  Note that it is generally
  /// not the case that all possible significand values are valid
  /// NaN `payloads`.  `FloatingPoint` types should either treat inadmissible
  /// payloads as zero, or mask them to create an admissible payload.
  @warn_unused_result
  static func nan(payload payload: RawSignificand, signaling: Bool) -> Self

  /// The greatest finite number.
  ///
  /// Compares greater than or equal to all finite numbers, but less than
  /// infinity.
  static var greatestFiniteMagnitude: Self { get }

  // NOTE: Rationale for "ulp" instead of "epsilon":
  // We do not use that name because it is ambiguous at best and misleading
  // at worst:
  //
  // - Historically several definitions of "machine epsilon" have commonly
  //   been used, which differ by up to a factor of two or so.  By contrast
  //   "ulp" is a term with a specific unambiguous definition.
  //
  // - Some languages have used "epsilon" to refer to wildly different values,
  //   such as `leastMagnitude`.
  //
  // - Inexperienced users often believe that "epsilon" should be used as a
  //   tolerance for floating-point comparisons, because of the name.  It is
  //   nearly always the wrong value to use for this purpose.

  /// The unit in the last place of 1.0.
  ///
  /// This is the weight of the least significant bit of the significand of 1.0,
  /// or the positive difference between 1.0 and the next greater representable
  /// number.
  static var ulp: Self { get }

  /// The unit in the last place of `self`.
  ///
  /// This is the unit of the least significant digit in the significand of
  /// `self`.  For most numbers `x`, this is the difference between `x` and
  /// the next greater (in magnitude) representable number.  There are some
  /// edge cases to be aware of:
  ///
  /// - `greatestFiniteMagnitude.ulp` is a finite number, even though
  ///   the next greater representable value is `infinity`.
  /// - `x.ulp` is `NaN` if `x` is not a finite number.
  /// - If `x` is very small in magnitude, then `x.ulp` may be a subnormal
  ///   number.  On targets that do not support subnormals, `x.ulp` may be
  ///   flushed to zero.
  ///
  /// This quantity, or a related quantity is sometimes called "[machine]
  /// epsilon".  We avoid that term because it has different meanings in
  /// different languages, which can lead to confusion.
  /// (see https://en.wikipedia.org/wiki/Machine_epsilon)
  var ulp: Self { get }

  /// The least positive normal number.
  ///
  /// Compares less than or equal to all positive normal numbers.  There may
  /// be smaller positive numbers, but they are "subnormal", meaning that
  /// they are represented with less precision than normal numbers.
  static var leastNormalMagnitude: Self { get }

  /// The least positive number.
  ///
  /// Compares less than or equal to all positive numbers, but greater than
  /// zero.  If the target supports subnormal values, this is smaller than
  /// `leastNormalMagnitude`; otherwise they are equal.
  static var leastMagnitude: Self { get }

  /// `true` iff the signbit of `self` is set.  Implements the IEEE 754
  /// `signbit` operation.
  ///
  /// Note that this is not the same as `self < 0`.  In particular, this
  /// property is true for `-0` and some NaNs, both of which compare not
  /// less than zero.
  var isSignMinus: Bool { get }

  /// The integer part of the base-r logarithm of the magnitude of `self`,
  /// where r is the radix (2 for binary, 10 for decimal).  Implements the
  /// IEEE 754 `logB` operation.
  ///
  /// Edge cases:
  ///
  /// - If `x` is zero, then `x.exponent` is `Int.min`.
  /// - If `x` is +/-infinity or NaN, then `x.exponent` is `Int.max`
  var exponent: Int { get }

  /// The mathematical `significand` (sometimes erroneously called the
  /// "mantissa").
  ///
  /// `significand` is computed as though the exponent range of `Self` were
  /// unbounded; if `x` is a finite non-zero number, then `1 <= x.significand`
  /// and `x.significand < 2`.
  ///
  /// For other values of `x`, `x.significand` is defined as follows:
  ///
  /// - If `x` is zero, then `x.significand` is 0.0.
  /// - If `x` is infinity, then `x.significand` is 1.0.
  /// - If `x` is NaN, then `x.significand` is NaN.
  ///
  /// For all floating-point `x`, if we define y by:
  ///
  /// ~~~
  ///    let y = Self(signBit: x.isSignMinus, exponent: x.exponent,
  ///                 significand: x.significand)
  /// ~~~
  ///
  /// then `y` is equivalent to `x`, meaning that `y` is `x` canonicalized.
  /// For types that do not have non-canonical encodings, this implies that
  /// `y` has the same encoding as `x`.  Note that this is a stronger
  /// statement than `x == y`, as it implies that both the sign of zero and
  /// the payload of NaN are preserved.
  var significand: Self { get }

  /// Initialize from signBit, exponent, and significand.
  ///
  /// The result is:
  ///
  /// ~~~
  /// (isSignMinus ? -1 : 1) * significand * r**exponent
  /// ~~~
  ///
  /// (where `r` is the floating-point radix--2 for binary formats-- and `**`
  /// is exponentiation) computed as if by a single correctly-rounded floating-
  /// point operation.  If this value is outside the representable range of
  /// `Self`, overflow or underflow will occur, and zero, a subnormal value,
  /// or infinity is returned, as with any basic operation.  Other edge cases:
  ///
  /// - If `significand` is zero or infinite, the result is zero or infinite,
  ///   regardless of the value of `exponent`.
  ///
  /// - If `significand` is NaN, the result is NaN.
  ///
  /// Note that for any floating-point `x` the result of
  ///
  ///   `Self(signBit: x.signBit,
  ///         exponent: x.exponent,
  ///         significand: x.significand)`
  ///
  /// is "the same" as `x` (if `x` is NaN, then this result is also `NaN`, but
  /// it might be a different NaN).
  ///
  /// Because of these properties, this initializer also implements the
  /// IEEE 754 `scaleB` operation.
  init(signBit: Bool, exponent: Int, significand: Self)

  /// A floating point value whose exponent and signficand are taken from
  /// `magnitude` and whose signBit is taken from `signOf`.  Implements the
  /// IEEE 754 `copysign` operation.
  //  Note: are there better argument names here?
  init(magnitudeOf magnitude: Self, signOf: Self)

  /// The least representable value that compares greater than `self`.
  ///
  /// - If `x` is `-infinity`, then `x.nextUp` is `-greatestMagnitude`.
  /// - If `x` is `-leastMagnitude`, then `x.nextUp` is `-0.0`.
  /// - If `x` is zero, then `x.nextUp` is `leastMagnitude`.
  /// - If `x` is `greatestMagnitude`, then `x.nextUp` is `infinity`.
  /// - If `x` is `infinity` or `NaN`, then `x.nextUp` is `x`.
  var nextUp: Self { get }

  /// The greatest representable value that compares less than `self`.
  ///
  /// `x.nextDown` is equivalent to `-(-x).nextUp`
  var nextDown: Self { get }

  /// Remainder of `self` divided by `other`.
  ///
  /// For finite `self` and `other`, the remainder `r` is defined by
  /// `r = self - other*n`, where `n` is the integer nearest to `self/other`.
  /// (Note that `n` is *not* `self/other` computed in floating-point
  /// arithmetic, and that `n` may not even be representable in any available
  /// integer type).  If `self/other` is exactly halfway between two integers,
  /// `n` is chosen to be even.
  ///
  /// It follows that if `self` and `other` are finite numbers, the remainder
  /// `r` satisfies `-|other|/2 <= r` and `r <= |other|/2`.
  ///
  /// `formRemainder` is always exact, and therefore is not affected by
  /// rounding modes.
  mutating func formRemainder(dividingBy other: Self)

  /// Remainder of `self` divided by `other` using truncating division.
  ///
  /// If `self` and `other` are finite numbers, the truncating remainder
  /// `r` has the same sign as `other` and is strictly smaller in magnitude.
  /// It satisfies `r = self - other*n`, where `n` is the integral part
  /// of `self/other`.
  ///
  /// `formTruncatingRemainder` is always exact, and therefore is not
  /// affected by rounding modes.
  mutating func formTruncatingRemainder(dividingBy other: Self)

  /// Mutating form of square root.
  mutating func formSquareRoot( )

  /// Fused multiply-add, accumulating the product of `lhs` and `rhs` to `self`.
  mutating func addProduct(lhs: Self, _ rhs: Self)

  /// Remainder of `self` divided by `other`.
  @warn_unused_result
  func remainder(dividingBy other: Self) -> Self

  /// Remainder of `self` divided by `other` using truncating division.
  @warn_unused_result
  func truncatingRemainder(dividingBy other: Self) -> Self

  /// Square root of `self`.
  @warn_unused_result
  func squareRoot( ) -> Self

  /// `self + lhs*rhs` computed without intermediate rounding.
  @warn_unused_result
  func addingProduct(lhs: Self, _ rhs: Self) -> Self

  /// The minimum of `x` and `y`.  Implements the IEEE 754 `minNum` operation.
  ///
  /// Returns `x` if `x <= y`, `y` if `y < x`, and whichever of `x` or `y`
  /// is a number if the other is NaN.  The result is NaN only if both 
  /// arguments are NaN.
  ///
  /// This function is an implementation hook to be used by the free function
  /// min(Self, Self) -> Self so that we get the IEEE 754 behavior with regard
  /// to NaNs.
  @warn_unused_result
  static func minimum(x: Self, _ y: Self) -> Self
  
  /// The maximum of `x` and `y`.  Implements the IEEE 754 `maxNum` operation.
  ///
  /// Returns `x` if `x >= y`, `y` if `y > x`, and whichever of `x` or `y`
  /// is a number if the other is NaN.  The result is NaN only if both
  /// arguments are NaN.
  ///
  /// This function is an implementation hook to be used by the free function
  /// max(Self, Self) -> Self so that we get the IEEE 754 behavior with regard
  /// to NaNs.
  @warn_unused_result
  static func maximum(x: Self, _ y: Self) -> Self
  
  /// Whichever of `x` or `y` has lesser magnitude.  Implements the IEEE 754
  /// `minNumMag` operation.
  ///
  /// Returns `x` if abs(x) <= abs(y), `y` if abs(y) < abs(x), and whichever of
  /// `x` or `y` is a number if the other is NaN.  The result is NaN
  /// only if both arguments are NaN.
  @warn_unused_result
  static func minimumMagnitude(x: Self, _ y: Self) -> Self
  
  /// Whichever of `x` or `y` has greater magnitude.  Implements the IEEE 754
  /// `maxNumMag` operation.
  ///
  /// Returns `x` if abs(x) >= abs(y), `y` if abs(y) > abs(x), and whichever of
  /// `x` or `y` is a number if the other is NaN.  The result is NaN
  /// only if both arguments are NaN.
  @warn_unused_result
  static func maximumMagnitude(x: Self, _ y: Self) -> Self

  /// IEEE 754 equality predicate.
  ///
  /// -0 compares equal to +0, and NaN compares not equal to anything,
  /// including itself.
  @warn_unused_result
  func isEqual(to other: Self) -> Bool
  
  /// IEEE 754 less-than predicate.
  ///
  /// NaN compares not less than anything.  -infinity compares less than
  /// all values except for itself and NaN.  Everything except for NaN and
  /// +infinity compares less than +infinity.
  @warn_unused_result
  func isLess(than other: Self) -> Bool
  
  /// IEEE 754 less-than-or-equal predicate.
  ///
  /// NaN compares not less than or equal to anything, including itself.
  /// -infinity compares less than or equal to everything except NaN.
  /// Everything except NaN compares less than or equal to +infinity.
  ///
  /// Because of the existence of NaN in FloatingPoint types, trichotomy does
  /// not hold, which means that `x < y` and `!(y <= x)` are not equivalent.
  /// This is why `isLessThanOrEqual(to:)` is a separate implementation hook
  /// in the protocol.
  ///
  /// Note that this predicate does not impose a total order.  The `totalOrder`
  /// predicate provides a refinement satisfying that criteria.
  @warn_unused_result
  func isLessThanOrEqual(to other: Self) -> Bool
  
  /// IEEE 754 unordered predicate.  True if either `self` or `other` is NaN,
  /// and false otherwise.
  @warn_unused_result
  func isUnordered(with other: Self) -> Bool

  /// True if and only if `self` is normal.
  ///
  /// A normal number uses the full precision available in the format.  Zero
  /// is not a normal number.
  var isNormal: Bool { get }

  /// True if and only if `self` is finite.
  ///
  /// If `x.isFinite` is `true`, then one of `x.isZero`, `x.isSubnormal`, or
  /// `x.isNormal` is also `true`, and `x.isInfinite` and `x.isNan` are
  /// `false`.
  var isFinite: Bool { get }

  /// True iff `self` is zero.  Equivalent to `self == 0`.
  var isZero: Bool { get }

  /// True if and only if `self` is subnormal.
  ///
  /// A subnormal number does not use the full precision available to normal
  /// numbers of the same format.  Zero is not a subnormal number.
  var isSubnormal: Bool { get }

  /// True if and only if `self` is infinite.
  ///
  /// Note that `isFinite` and `isInfinite` do not form a dichotomy, because
  /// they are not total.  If `x` is `NaN`, then both properties are `false`.
  var isInfinite: Bool { get }

  /// True if and only if `self` is NaN ("not a number").
  var isNan: Bool { get }

  /// True if and only if `self` is a signaling NaN.
  var isSignalingNan: Bool { get }

  /// The IEEE 754 "class" of this type.
  var floatingPointClass: FloatingPointClassification { get }

  /// True if and only if `self` is canonical.
  ///
  /// Every floating-point value of type Float or Double is canonical, but
  /// non-canonical values of type Float80 exist, and non-canonical values
  /// may exist for other types that conform to FloatingPoint.
  ///
  /// The non-canonical Float80 values are known as "pseudo-denormal",
  /// "unnormal", "pseudo-infinity", and "pseudo-NaN".
  /// (https://en.wikipedia.org/wiki/Extended_precision#x86_Extended_Precision_Format)
  var isCanonical: Bool { get }

  /// True if and only if `self` preceeds `other` in the IEEE 754 total order
  /// relation.
  ///
  /// This relation is a refinement of `<=` that provides a total order on all
  /// values of type `Self`, including non-canonical encodings, signed zeros,
  /// and NaNs.  Because it is used much less frequently than the usual
  /// comparisons, there is no operator form of this relation.
  @warn_unused_result
  func totalOrder(with other: Self) -> Bool
  
  /// True if and only if `abs(self)` preceeds `abs(other)` in the IEEE 754
  /// total order relation.
  @warn_unused_result
  func totalOrderMagnitude(with other: Self) -> Bool

  /// The closest representable value to the argument.
  init<Source: Integer>(_ value: Source)

  /// Fails if the argument cannot be exactly represented.
  init?<Source: Integer>(exactly value: Source)
}
```

The `BinaryFloatingPoint` protocol provides a number of additional APIs
that only make sense for types with fixed radix 2:

```swift
/// A radix-2 (binary) floating-point type that follows the IEEE 754 encoding
/// conventions.
public protocol BinaryFloatingPoint: FloatingPoint {

  /// The number of bits used to represent the exponent.
  ///
  /// Following IEEE 754 encoding convention, the exponent bias is:
  ///
  ///   bias = 2**(exponentBitCount-1) - 1
  ///
  /// The least normal exponent is `1-bias` and the largest finite exponent
  /// is `bias`.  The all-zeros exponent is reserved for subnormals and zeros,
  /// and the all-ones exponent is reserved for infinities and NaNs.
  static var exponentBitCount: Int { get }

  /// For fixed-width floating-point types, this is the number of fractional
  /// significand bits.
  ///
  /// Note that `Float80.significandBitCount` is 63, even though 64 bits
  /// are used to store the significand in the memory representation of a
  /// `Float80` (unlike other floating-point types, `Float80` explicitly
  /// stores the leading integral significand bit, but the
  /// `BinaryFloatingPoint` APIs provide an abstraction so that users don't
  /// need to be aware of this detail).
  ///
  /// For extensible floating-point types, `significandBitCount` should be
  /// the maximum allowed significand width (without counting any leading
  /// integral bit of the significand).  If there is no upper limit, then
  /// `significandBitCount` should be `Int.max`.
  static var significandBitCount: Int { get }

  /// The raw encoding of the exponent field of the floating-point value.
  var exponentBitPattern: UInt { get }

  /// The raw encoding of the significand field of the floating-point value.
  ///
  /// `significandBitPattern` does *not* include the leading integral bit of
  /// the significand, even for types like `Float80` that store it explicitly.
  var significandBitPattern: RawSignificand { get }

  /// Combines `signBit`, `exponent` and `significand` bit patterns to produce
  /// a floating-point value.
  ///
  /// The bit patterns are masked before being assembled, clamping them to the
  /// allowed range of the floating-point type.
  init(signBit: Bool,
       exponentBitPattern: UInt,
       significandBitPattern: RawSignificand)

  /// The least-magnitude member of the binade of `self`.
  ///
  /// If `x` is `+/-significand * 2**exponent`, then `x.binade` is
  /// `+/- 2**exponent`; i.e. the floating point number with the same sign
  /// and exponent, but a significand of 1.0.
  var binade: Self { get }

  /// The number of bits required to represent significand.
  ///
  /// If `self` is not a finite non-zero number, `significandWidth` is
  /// `-1`.  Otherwise, it is the number of bits required to represent the
  /// significand exactly (less `1` because common formats represent one bit
  /// implicitly).
  var significandWidth: Int { get }

  @warn_unused_result
  func isEqual<Other: BinaryFloatingPoint>(to other: Other) -> Bool
  
  @warn_unused_result
  func isLess<Other: BinaryFloatingPoint>(than other: Other) -> Bool
  
  @warn_unused_result
  func isLessThanOrEqual<Other: BinaryFloatingPoint>(to other: Other) -> Bool
  
  @warn_unused_result
  func isUnordered<Other: BinaryFloatingPoint>(with other: Other) -> Bool

  @warn_unused_result
  func totalOrder<Other: BinaryFloatingPoint>(with other: Other) -> Bool

  /// `value` rounded to the closest representable value.
  init<Source: BinaryFloatingPoint>(_ value: Source)

  /// Fails if `value` cannot be represented exactly as `Self`.
  init?<Source: BinaryFloatingPoint>(exactly value: Source)
}
```

Finally, the necessary support is added to `Float`, `Double`, `Float80` and
`CGFloat` to conform to these protocols.

A small portion of the implementation of these APIs is dependent on new
Integer protocols that will be proposed separately.  Everything else is
implemented in draft from on the branch floating-point-revision of
[my fork](https://github.com/stephentyrone/swift).

## Impact on existing code

1. The `%` operator is no longer available for FloatingPoint types.  We don't
believe that it was widely used correctly, and the operation is still available
via the `formTruncatingRemainder` method for people who need it.

2. To follow the naming guidelines, `NaN` and `isNaN` are replaced with `nan`
and `isNan`.

3. The redundant property `quietNaN` is removed.

4. `isSignaling` is renamed `isSignalingNan`.

## Alternatives considered

N/A.
