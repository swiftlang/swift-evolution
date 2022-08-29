# StaticBigInt

* Proposal: [SE-0368](0368-staticbigint.md)
* Author: [Ben Rimmington](https://github.com/benrimmington)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Accepted**
* Implementation: [apple/swift#40722](https://github.com/apple/swift/pull/40722)
* Review: ([pitch](https://forums.swift.org/t/staticbigint/54545))([review](https://forums.swift.org/t/se-0368-staticbigint/59421))
* Decision notes: [Acceptance](https://forums.swift.org/t/accepted-se-0368-staticbigint/59962)

<details>
<summary><b>Revision history</b></summary>

|            |                                                   |
| ---------- | ------------------------------------------------- |
| 2022-01-10 | Initial pitch.                                    |
| 2022-02-01 | Updated with an "ABI-neutral" abstraction.        |
| 2022-04-23 | Updated with an "infinitely-sign-extended" model. |
| 2022-08-18 | Updated with a "non-generic" subscript.           |

</details>

## Introduction

Integer literals in Swift source code can express an arbitrarily large value. However, types outside of the standard library which conform to `ExpressibleByIntegerLiteral` are restricted in practice in how large of a literal value they can be built with, because the value passed to `init(integerLiteral:)` must be of a type supported by the standard library. This makes it difficult to write new integer types outside of the standard library.

## Motivation

Types in Swift that want to be buildable with an integer literal can conform to the following protocol:

```swift
public protocol ExpressibleByIntegerLiteral {
  associatedtype IntegerLiteralType: _ExpressibleByBuiltinIntegerLiteral
  init(integerLiteral value: IntegerLiteralType)
}
```

The value passed to `init(integerLiteral:)` must have a type that knows how to manage the primitive interaction with the Swift compiler so that it can be built from an arbitrary literal value. That constraint is expressed with the `_ExpressibleByBuiltinIntegerLiteral` protocol, which cannot be implemented outside of the standard library. All of the integer types in the standard library conform to `_ExpressibleByBuiltinIntegerLiteral` as well as `ExpressibleByIntegerLiteral`. A type outside of the standard library must select one of those types as the type it takes in `init(integerLiteral:)`. As a result, such types cannot be built from an integer literal if there isn't a type in the standard library big enough to express that integer.

For example, if larger fixed-width integers (such as `UInt256`) were added to the [Swift Numerics][] package, they would currently have to use smaller literals (such as `UInt64`).

```swift
let value: UInt256 = 0x1_0000_0000_0000_0000
//                   ^
// error: integer literal '18446744073709551616' overflows when stored into 'UInt256'
```

## Proposed solution

We propose adding a new type to the standard library called `StaticBigInt` which is capable of expressing any integer value. This can be used as the associated type of an `ExpressibleByIntegerLiteral` conformance. For example:

```swift
extension UInt256: ExpressibleByIntegerLiteral {

  public init(integerLiteral value: StaticBigInt) {
    precondition(
      value.signum() >= 0 && value.bitWidth <= Self.bitWidth + 1,
      "integer literal '\(value)' overflows when stored into '\(Self.self)'"
    )
    self.words = Words()
    for wordIndex in 0..<Words.count {
      self.words[wordIndex] = value[wordIndex]
    }
  }
}
```

The implementation of `init(integerLiteral:)` must avoid calling APIs that may use `Self`-typed literals, which would trigger infinite recursion.

## Detailed design

`StaticBigInt` models a mathematical integer, where distinctions visible in source code (such as the base/radix and leading zeros) are erased. It doesn't conform to any [numeric protocols][] because new values of the type can't be built at runtime. Instead, it provides a limited API which can be used to extract the integer value it represents.

```swift
/// An immutable arbitrary-precision signed integer.
public struct StaticBigInt:
  CustomDebugStringConvertible,
  CustomReflectable,
  _ExpressibleByBuiltinIntegerLiteral,
  ExpressibleByIntegerLiteral,
  Sendable
{
  /// Returns the given value unchanged.
  public static prefix func + (_ rhs: Self) -> Self

  /// Returns `-1`, `0`, or `+1` to indicate whether this value is less than,
  /// equal to, or greater than zero.
  ///
  /// The return type is `Int` rather than `Self`.
  public func signum() -> Int

  /// Returns the minimal number of bits in this value's binary representation,
  /// including the sign bit, and excluding the sign extension.
  ///
  /// The following examples show the least significant byte of each value's
  /// binary representation, separated into excluded and included bits. Negative
  /// values are in two's complement.
  ///
  /// * `-4` (`0b11111_100`) is 3 bits.
  /// * `-3` (`0b11111_101`) is 3 bits.
  /// * `-2` (`0b111111_10`) is 2 bits.
  /// * `-1` (`0b1111111_1`) is 1 bit.
  /// * `+0` (`0b0000000_0`) is 1 bit.
  /// * `+1` (`0b000000_01`) is 2 bits.
  /// * `+2` (`0b00000_010`) is 3 bits.
  /// * `+3` (`0b00000_011`) is 3 bits.
  public var bitWidth: Int { get }

  /// Returns a 32-bit or 64-bit word of this value's binary representation.
  ///
  /// The words are ordered from least significant to most significant, with
  /// an infinite sign extension. Negative values are in two's complement.
  ///
  ///     let negative: StaticBigInt = -0x0011223344556677_8899AABBCCDDEEFF
  ///     negative.signum()  //-> -1
  ///     negative.bitWidth  //-> 118
  ///     negative[0]        //-> 0x7766554433221101
  ///     negative[1]        //-> 0xFFEEDDCCBBAA9988
  ///     negative[2]        //-> 0xFFFFFFFFFFFFFFFF
  ///
  ///     let positive: StaticBigInt = +0x0011223344556677_8899AABBCCDDEEFF
  ///     positive.signum()  //-> +1
  ///     positive.bitWidth  //-> 118
  ///     positive[0]        //-> 0x8899AABBCCDDEEFF
  ///     positive[1]        //-> 0x0011223344556677
  ///     positive[2]        //-> 0x0000000000000000
  ///
  /// - Parameter wordIndex: A nonnegative zero-based offset.
  public subscript(_ wordIndex: Int) -> UInt { get }
}
```

## Effect on ABI stability

This feature adds to the ABI of the standard library, and it won't back-deploy (by default).

The integer literal type has to be selected statically as the associated type. There is currently no way to conditionally use a different integer literal type depending on the execution environment. Types will not be able to adopt this and use the most flexible possible literal type dynamically available.

## Alternatives considered

- Modeling the original source text instead of a mathematical value would allow this type to support a wide range of use cases, such as fractional values, decimal values, and other things such as arbitrary binary strings expressed in hexadecimal. However, it is not a goal of Swift's integer literals design to support these use cases. Supporting them would burden integer types with significant code size, dynamic performance, and complexity overheads. For example, either the emitted code would need to contain both the original source text and a more optimized representation used by ordinary integer types, or ordinary integer types would need to fall back on parsing numeric values from source at runtime.

- Along similar lines, it is intentional that `StaticBigInt` cannot represent fractional values. Integer types should not be constructible with fractional literals, and allowing that simply adds unnecessary costs and introduces a new way for construction to fail. It is still a language goal for Swift to someday support dynamically flexible floating-point literals the way it does for integer literals, but that is a separable project from introducing `StaticBigInt`.

- A prior design had a `words` property, initially as a contiguous buffer, subsequently as a custom collection. John McCall requested an "ABI-neutral" abstraction, and suggested the current "infinitely-sign-extended" model. Xiaodi Wu convincingly argued for a "non-generic" subscript, rather than over-engineering a choice of element type.

- Xiaodi Wu [suggested](https://forums.swift.org/t/staticbigint/54545/23) that a different naming scheme and API design be chosen to accommodate other similar types, such as IEEE 754 interchange formats. However, specific alternatives weren't put forward for consideration. Using non-arithmetic types for interchange formats would seem to be a deliberate choice; whereas for `StaticBigInt` it's because of an inherent limitation.

## Future directions

- It may be possible to diagnose integer literal overflow at compile-time, if constant evaluation is added to the language.

- A mutable `BigInt: SignedInteger` type (in the standard library) would either complement or [obsolete][] `StaticBigInt`:

  > … there is very little reason to use `StaticString` these days over a regular `String`, as the regular `String` is initialized with a pointer to a string in the const section and won't perform any reference counting.

- `StaticBigInt` (or a similar type) might be useful for [auto-generated][] constant data, if we also had *multiline* integer literals:

  ```swift
  let _swift_stdlib_graphemeBreakProperties: StaticBigInt = (((0x_
    0x____________________________3DEE0100_0FEE0080_2BEE0020_03EE0000_B701F947_
    0x_8121F93C_85C1F90C_8A21F8AE_80E1F888_80A1F85A_80E1F848_8061F80C_8541F7D5_
    /* [74 lines redacted] */
    0x_2280064B_0000061C_21400610_40A00600_200005C7_202005C4_202005C1_200005BF_
    0x_25800591_20C00483_2DE00300_800000AE_000000AD_800000A9_0400007F_03E00000_
  )))
  ```

- The unary `+` operator function isn't sufficient for all use cases:

  ```swift
  let a: StaticBigInt = -42  // OK
  let b: StaticBigInt = +42  // OK
  
  let c = -42 as StaticBigInt  // OK
  let d = +42 as StaticBigInt  // OK
  
  let e = StaticBigInt(-42)  // OK
  let f = StaticBigInt(+42)  // error
  ```

  Could the plus sign be added to the language grammar of integer (and floating-point) literals?

## Acknowledgments

John McCall made significant improvements to this proposal; and (in Swift 5.0) implemented arbitrary-precision integer literals. `StaticBigInt` is a thin wrapper around the existing [`Builtin.IntLiteral`][] type.

<!----------------------------------------------------------------------------->

[auto-generated]: <https://github.com/apple/swift/blob/4a451829f889a09b18a0d88bec234029c51cea9c/stdlib/public/stubs/Unicode/Common/GraphemeData.h>

[`Builtin.IntLiteral`]: <https://forums.swift.org/t/how-to-find-rounding-error-in-floating-point-integer-literal-initializer/42039/8>

[numeric protocols]: <https://developer.apple.com/documentation/swift/numeric-protocols>

[obsolete]: <https://forums.swift.org/t/pitch-compile-time-constant-values/53606/9>

[Swift Numerics]: <https://github.com/apple/swift-numerics/issues/4>
