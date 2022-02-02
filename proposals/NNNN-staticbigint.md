# StaticBigInt

* Proposal: [SE-NNNN](NNNN-staticbigint.md)
* Author: [Ben Rimmington](https://github.com/benrimmington)
* Review Manager: TBD
* Status: **Pitch**
* Implementation: [apple/swift#40722](https://github.com/apple/swift/pull/40722)

## Introduction

Arbitrary-precision integer literals were implemented in Swift 5.0, but they're currently unavailable to types outside of the standard library. This proposal would [productize][] them into a `StaticBigInt` type (reminiscent of the `StaticString` type).

Swift-evolution thread: [Pitch](https://forums.swift.org/t/staticbigint/54545)

## Motivation

There are two compiler-intrinsic protocols for integer literals.

```swift
public protocol _ExpressibleByBuiltinIntegerLiteral {
    init(_builtinIntegerLiteral value: Builtin.IntLiteral)
}

public protocol ExpressibleByIntegerLiteral {
    associatedtype IntegerLiteralType: _ExpressibleByBuiltinIntegerLiteral
    init(integerLiteral value: IntegerLiteralType)
}
```

- All integer (and floating-point) types in the standard library conform to both protocols.
- Types outside of the standard library can only conform to the second protocol.
- Therefore, the associated `IntegerLiteralType` must be a standard library type.

For example, if larger fixed-width integers (such as `UInt256`) were added to the [Swift Numerics][] package, they would currently have to use smaller literals (such as `UInt64`).

```swift
let value: UInt256 = 0x1_0000_0000_0000_0000
//                   ^
// error: integer literal '18446744073709551616' overflows when stored into 'UInt256'
```

## Proposed solution

Swift Numerics could (perhaps conditionally) use `StaticBigInt` as an associated type.

```swift
extension UInt256: ExpressibleByIntegerLiteral {

#if compiler(>=9999) && COMPILATION_CONDITION
    public typealias IntegerLiteralType = StaticBigInt
#else
    public typealias IntegerLiteralType = UInt64
#endif

    public init(integerLiteral value: IntegerLiteralType) {
        precondition(
            value.signum() >= 0 && value.bitWidth <= 257,
            "integer literal overflows when stored into 'UInt256'"
        )
        // Copy the elements of `value.words` into this instance.
        // Avoid numeric APIs that may trigger infinite recursion.
    }
}
```

Overflow would be a runtime error, unless [compile-time][] evaluation can be used in the future.

## Detailed design

`StaticBigInt` is an *immutable* arbitrary-precision signed integer. It can't conform to any [numeric protocols][], but it does implement some numeric APIs: `signum()`, `bitWidth`, and `words`.

```swift
public struct StaticBigInt: Sendable, _ExpressibleByBuiltinIntegerLiteral {
    public init(_builtinIntegerLiteral value: Builtin.IntLiteral)
}

// `Self` Literals
extension StaticBigInt: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Self)
    public static prefix func + (_ rhs: Self) -> Self
}

// Numeric APIs
extension StaticBigInt {
    public func signum() -> Int
    public var bitWidth: Int { get }
    public var words: Words { get }
}

// Collection APIs
extension StaticBigInt {
    public struct Words: RandomAccessCollection, Sendable {
        public typealias Element = UInt
        public typealias Index = Int
    }
}
```

## Alternatives considered

A *mutable* `BigInt: SignedInteger` type could (eventually) be implemented in the standard library.

## Future directions

`StaticBigInt` (or a similar type) might be useful for [auto-generated][] constant data, if we also had *multiline* integer literals.

```swift
let _swift_stdlib_graphemeBreakProperties: StaticBigInt = (((0x_
    0x____________________________3DEE0100_0FEE0080_2BEE0020_03EE0000_B701F947_ // 620...616
    0x_8121F93C_85C1F90C_8A21F8AE_80E1F888_80A1F85A_80E1F848_8061F80C_8541F7D5_ // 615...608
    /* [74 lines redacted] */
    0x_2280064B_0000061C_21400610_40A00600_200005C7_202005C4_202005C1_200005BF_ // 15...8
    0x_25800591_20C00483_2DE00300_800000AE_000000AD_800000A9_0400007F_03E00000_ // 7...0
)))
```

## Acknowledgments

John McCall implemented arbitrary-precision integer literals (in Swift 5.0).

`StaticBigInt` is a thin wrapper around the existing `Builtin.IntLiteral` type.

<!----------------------------------------------------------------------------->

[auto-generated]: <https://github.com/apple/swift/blob/4a451829f889a09b18a0d88bec234029c51cea9c/stdlib/public/stubs/Unicode/Common/GraphemeData.h>

[compile-time]: <https://forums.swift.org/t/pitch-compile-time-constant-values/53606>

[numeric protocols]: <https://developer.apple.com/documentation/swift/swift_standard_library/numbers_and_basic_values/numeric_protocols>

[productize]: <https://forums.swift.org/t/how-to-find-rounding-error-in-floating-point-integer-literal-initializer/42039/8>

[Swift Numerics]: <https://github.com/apple/swift-numerics/issues/4>
