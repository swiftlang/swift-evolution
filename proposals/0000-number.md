# Number

* Proposal: [SE-NNNN](NNNN-number.md)
* Author: [C. Heath](https://github.com/hexleytheplatypus)
* Review Manager: TBD
* Status: [Pitch](https://forums.swift.org/t/pitch-comprehensive-number/70682/1)
* Implementation: [Package](https://github.com/hexleytheplatypus/swift-se0000-number)
* Review: TBD

<details>
<summary><b>Revision history</b></summary>

| Date       | Changelog                                         |
| ---------- | ------------------------------------------------- |
| 2024-02-29 | Invite special guests                             |
| 2024-03-14 | Initial pitch (𝜋-day + 𝜋-calculator)              |

</details>

## Introduction

`Numeric` types are messy. Swift has a [multitude of](https://developer.apple.com/documentation/swift/special-use-numeric-types) [`Numeric` types](https://developer.apple.com/documentation/swift/numbers-and-basic-values#numeric-values): `UInt8`, `UInt16`, `UInt32`, `UInt64`, `Int8`, `Int16`, `Int32`, `Int64`, `Float`, `Float16`, `Double`. As well as types that take on platform-specific meaning (`UInt`, `Int`) or may not even exist on some platforms or architectures, such as: `Float80`. All of this before we even look outside the standard library to types such as: `CGFloat`, `Decimal` or `NSNumber`. These types are not interoperable and often require explicit conversions or coercions to perform arithmetic operations or to pass them as arguments to functions.

This proposal introduces a comprehensive [`Number`][] type with `String`-like simplicity for numeric values, dramatically simplifying the use of numbers and enabling advanced scientific computation.

## Motivation

The current numeric types in Swift have several limitations and inconveniences that adversely affect the expressivity and usability of the language.

Existing number types have their specific uses for performance and optimization, much like `StaticString` offers for `String`. Therefore, this proposal does ***NOT*** suggest removing any existing `Numeric` types. Instead, this proposal focuses on the Swift Language idea of Progressive Disclosure, where users of the language don't have to know everything at once.

### Numeric Coercion
The arithmetic operators (+, -, *, /, etc.) are not compatible across the different numeric types, for reasons of type-safety. This prevents these operators from potentially performing implicit conversions between types or causing overflow and triggering an assertion. However, this also creates a major disconnect in a new programmer’s mind. For example, the following code will not compile:
```swift
func test_Int_Double_Addition() {
    let lhs: Int = 2
    let rhs: Double = 2.4
    // ERROR - Binary operator '+' cannot be applied to operands of type 'Int' and 'Double'.
    AssertEqual(lhs + rhs, 4.4)
}
```

To make this code work, the programmer has to explicitly convert one of the operands to match the type of the other, implicitly choosing between loss-of-precision or not being able to perform the operation:
```swift
func test_Int_Double_Addition_Loss-Of-Precision() {
    let lhs: Int = 2
    let rhs: Double = 2.4
    
    // Conversion of 'Double' to 'Int' guarantees loss-of-precision.
    let double2Int = lhs + Int(rhs)    // 4
    
    // Conversion of 'Int' to 'Double' can introduce floating-point errors.
    let int2Double = Double(lhs) + rhs // 4.4?
}
```

These conversions are not only tedious and prone to runtime assertions, but introduce potential inconsistencies or overflow. Type-safety isn't a hinderance, it is key to `Number`s simplicity.
```swift
func test_Number_Addition() {
    let lhs: Number = 2
    let rhs: Number = 2.4
    AssertEqual(lhs + rhs, 22 / 5) // 4.4
}
```

### API Expressivity
Swift defines `Int` as the primary numeric type to use for integers and `Double` for decimal numbers, but there are places where this doesn't actually express the API’s intent. For example, the `count` property of any `Collection` returns an `Int` value, even though the count can never be negative.
```swift
var count: Int { get }
```
This can be better expressed with `Number`s `WholeNumber` component, which explicitly fits `Collection`s intent of expressing `zero` or a natural number.
```swift
var count: WholeNumber { get }
```

Existing numeric types are designed to support basic arithmetic operations, but they are not well-suited for more advanced or specialized numeric computation, such as scientific, engineering, or financial calculations. For example, Swift does not have a built-in type for `ComplexNumber`s, which are essential for many fields of mathematics and physics.
The goal of `Number` is to provide a single, simple, and consistent tool for all numeric needs in Swift. `Number` also enables numeric concepts that are currently unsupported, provides interoperability with Swift’s exisiting numeric types and allowing users to dig deeper if they so choose.

## Proposed solution

`Number` itself is a `String`-like type, built around a simple enumeration responsible for marshalling work to a series of specialized components.

```swift
enum Number {
    case real(RealNumber)
    case imaginary(ImaginaryNumber)
    case complex(ComplexNumber)
}
```

`String` does this with `Character` and `StaticString`. `String` does not care what the underlying `Character`s are, whether Latin script, Arabic, Kanji or Emoji; one can quickly and easily compose a `String` containing all of them. `Number` embraces this paradigm. Whether actually a `NaturalNumber`, `IrrationalNumber` or `ComplexNumber`; `Number`'s operations return a `Number` containing the *exact result*, every time.

### Progressive Disclosure

> Progressive disclosure requires that language features should be added in a way that doesn't complicate the rest of the language. This means that Swift aims to be simple for simple tasks, and only as complex as needed for complex tasks. - *[George Lyon](https://gist.github.com/GeorgeLyon/c7b07923f7a800674bc9745ae45ddc7f#)*

This idea is paramount to the success of new and long-time developers alike. As Swift users, we should all strive to reach for the simplest tool first and work our way down as testing and evidence-based optimization become priority. As Swift contributors, we should continue to do the work that makes the simplest tools, absolutely incredible.

At any point a user may access any of `Number`'s components and find the delightful simplicity of a narrower focus for each component and interoperability with all other components, as well as `Number` itself.

## Detailed design

- `Number` represents any kind of numeric value, and conforms to the `Numeric` protocol.

Composed as a set of structs and enums grouped at various levels, `Number` is an enum with [Associated Values](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/enumerations/#Associated-Values).
```
              ┌struct─────────┐                              ┌struct──────────┐
           ┌─▶│ ComplexNumber │                           ┌─▶│ SimpleFraction │
           │  └───────────────┘                           │  └────────────────┘
┌enum────┐ │  ┌struct───────────┐    ┌enum──────────────┐ │  ┌struct───┐       
│ Number │─┼─▶│ ImaginaryNumber │ ┌─▶│ IrrationalNumber │ ├─▶│ Integer │       
└────────┘ │  └─────────────────┘ │  └──────────────────┘ │  └─────────┘       
           │  ┌enum────────┐      │  ┌enum────────────┐   │  ┌struct───────┐   
           └─▶│ RealNumber │──────┴─▶│ RationalNumber │───┼─▶│ WholeNumber │   
              └────────────┘         └────────────────┘   │  └─────────────┘   
                                                          │  ┌struct─────────┐ 
                                                          └─▶│ NaturalNumber │ 
                                                             └───────────────┘ 
```

Each of these components represents the classification of a number:
- Natural Numbers are positive whole values, excluding zero.
- Whole Numbers are positive whole values, including zero.
- Integers are positive or negative whole values.
- Simple Fractions are the ratio of an Integer over another Integer.
- Rational Numbers are Natural Numbers, Whole Numbers, Integers, and Simple Fractions.
- Irrational Numbers are non-terminating, non-repeating values that cannot be expressed as a ratio of Integers. ***(Developer Note: Discussion Needed)***
- Real Numbers are all Rational and Irrational Numbers.
- Imaginary Numbers are Real Numbers multiplied by the imaginary unit *i*.
- Complex Numbers are composed of a Real and Imaginary Number.

Swift's existing numeric types only represent up to Simple Fractions. `Number` dramatically simplifies use and expands the mathematical space covered by the Standard Library using 6 simple structs and 4 basic enums.

### Advanced Arithmetic Beyond `Numeric`

— ***Developer Note: While decently performant, operations are not written in the most efficient way. Further enhancements by experts in mathematics are greatly desired and consideration for `async` and `throws` are available in [Performance Enhancements](#performance-enhancements).***

`Number` adds support for advanced arithmetic:
- Exponentation      ***(Developer Note: Work In-progress)***
- Factorization      ***(Developer Note: Complete)***
- Factorialization   ***(Developer Note: Work In-progress)***
- Primality          ***(Developer Note: Complete)***
- Rooting/Radication ***(Developer Note: Discussion Needed)***
- Logarithm          ***(Developer Note: Not Started)***

### Arithmetic Accuracy
`Number` always returns the *exact result* of an operation. `Number` never introduces `FloatingPoint` errors or loss-of-precision because its component types only use Arbitrary Precision Integer implementations.

### Arbitrary Precision Integers
As an internal implementation detail, `Number` relies on `ArbitraryPrecisionSignedInteger` and `ArbitraryPrecisionUnsignedInteger` types, which are used by various components for storage of their numeric values. As these types conform to `BinaryInteger` and have variable-length storage, they can grow up to the physical limitations of the machine upon which the allocation is created.

Both `ArbitraryPrecisionSignedInteger` and `ArbitraryPrecisionUnsignedInteger` implementations are built upon an array of unsigned, fixed-width integers of the machine's register width (UInt-size). When an arithmetic operation causes an overflow or underflow of the current storage space, the array either appends new units to accommodate the overflow or removes unused units.

#### Internal Behavioral Differences:
Left-shifts cannot be overshifted. As these Arbitrary Precision Integers can grow to fit whatever value they contain, there is no cut-off point at which a left-shift will cause bits to be dropped. Take the example of an 8-bit number:
```swift
func test_UInt8_overshift() {
    let x: UInt8 = 0b10000000 // 128
    AssertEqual(x << 1, 0)    // PASS
}
```
In this 8-bit example, the singular 1 will be shifted left and out of the 8-bit bounds, resulting in all zeroes. However, in a 16-bit number type:
```swift
func test_UInt16_overshift() {
    let x: UInt16 = 0b00000000_10000000 // 128
    AssertEqual(x << 1, 0)              // FAIL - 256
}
```
The test fails because the 16-bit integer can move the 1 bit over to the 9th position, resulting in 256. However, the same issue persists; this time, the cut-off occurs between the 16th and 17th bit positions.
    
Arbitrary Precision Integers do not replicate this behavior, as they grow infinitely to contain the value they hold.
```swift
func test_ArbitraryPrecisionUnsignedInteger_overshift() {
    let x = 0b{CAN_GROW}_10000000 // 128
    AssertNotEqual(x << 77, 0)    // PASS - 19_342_813_113_834_066_795_298_816
}
```

## Effect on ABI stability

This feature primarily adds to the standard library.

- However, if `Number` is to become the default Type-Inference for `IntegerLiteral`s and `FloatLiteral`s (and possibly a `FractionLiteral` [See Future directions]()) and values such as [`Array.count`](https://developer.apple.com/documentation/swift/array/count) are to move from [`Int`][] to [`WholeNumber`][], this change would be breaking and migration diagnostics are required.

- This proposal's position is that such changes land with Swift 6.0, removing non-descript declarations of [`Int`][] which do not actually describe the API intent, i.e. [`Array.count: Int`](https://developer.apple.com/documentation/swift/array/count). [`Number`][] usage would make these sites more expressive while simplifying operations between these types.

## Future directions

### Language Literals
#### StaticBigFloat:
- A `StaticBigInt`-like type, with the decimal point location reported. (Not an IEEE 754 representation)

#### Fraction literal: 
- Two `StaticBigInt`, `StaticBigFloat` or any combination thereof, seperated by /. (Type inferred to `Number`)

### Performance Enhancements
#### Async Operations
`Number` and its component types are `Sendable`. There might be performance to be gained in complex arithmetic by having operations be `async`.

#### Throwing Operations
A great idea for division, which could throw a `DivisionError.divideByZero`. However throwing functions do not fulfill protocol requirements of non-throwing functions; potentially breaking `Numeric` conformance. If a throwing function gains the ability to fulfill these protocol requirements (or if the protocol adds `throws` to it’s declarations, which [a non-throwing can fulfill](https://www.swiftbysundell.com/tips/implementing-throwing-protocol-functions-as-non-throwing/)) then asserting on `precondition` that `rhs == .zero` is no longer required and the program can safely recover by throwing an error. (This behavior may also be preferred to the current `precondition` assertions in Swift's numeric types, should those numeric types become more for optimization.)
```swift
enum Number {
    public static func / (lhs: Self, rhs: Self) throws -> Self {
        if rhs == .zero { throw DivisionError.divideByZero }
        // ...
    }
}
```

#### Vectorized Operations
`Number` and its component types may see performance gains in extremely-large value arithmetic by having operations use `SIMD`.

### Scientific Additions
#### Precision Tracking
`Number` always returns the exact result of an operation, but this is subject to imprecision or error if:
- `Number` was instantiated from a `FloatingPoint` type that had already suffered from loss-of-precision or floating-point errors. Or;
- `Number` performed an operation with another `Number` that was instantiated from a `FloatingPoint` type that had already suffered from loss-of-precision or floating-point errors.

*Performing operations only with `Number`s initialized with `BinaryInteger` or literals guarantees this does not occur.* 

`Number` itself could gain a flag, `.precisionGuaranteed` which reports whether either of these situations has occured.

#### Widest Operand
Beyond the scope of this proposal, `Number` would benefit from the ability to ensure the precision always maintains or exceeds the length (in digits) of the widest operand. Difficulties here lay in whether the compiler would be able to determine such a thing or if tooling to make it possible would be significantly difficult to produce.

## Acknowledgments

Thanks to [Xiaodi Wu](https://github.com/xwu) for [insight into numerics](https://numerics.diploid.ca).

Thanks to[Ben Rimmington](https://github.com/benrimmington) and [John McCall](https://github.com/rjmccall) for implementations of [StaticBigInt](https://developer.apple.com/documentation/swift/staticbigint) and [Builtin.IntLiteral](https://forums.swift.org/t/how-to-find-rounding-error-in-floating-point-integer-literal-initializer/42039/8).

Special thanks to [Nate Cook](https://github.com/natecook1000), [Max Moiseev](https://github.com/moiseev) and all other contributors for their extensive work over the years on [BigInt.swift](https://github.com/apple/swift/commits/main/test/Prototypes/BigInt.swift), from which a lot of [`ArbitraryPrecisionSignedInteger`][] and [`ArbitraryPrecisionUnsignedInteger`][] is derived.


<!----------------------------------------------------------------------------->

[`async`]: <https://developer.apple.com/documentation/swift/concurrency>

[`Int`]: <https://developer.apple.com/documentation/swift/Int>
[`Int8`]: <https://developer.apple.com/documentation/swift/Int8>
[`Int16`]: <https://developer.apple.com/documentation/swift/Int16>
[`Int32`]: <https://developer.apple.com/documentation/swift/Int32>
[`Int64`]: <https://developer.apple.com/documentation/swift/Int64>
[`UInt`]: <https://developer.apple.com/documentation/swift/UInt>
[`UInt8`]: <https://developer.apple.com/documentation/swift/UInt8>
[`UInt16`]: <https://developer.apple.com/documentation/swift/UInt16>
[`UInt32`]: <https://developer.apple.com/documentation/swift/UInt32>
[`UInt64`]: <https://developer.apple.com/documentation/swift/UInt64>
[`Float`]: <https://developer.apple.com/documentation/swift/Float>
[`Float16`]: <https://developer.apple.com/documentation/swift/Float16>
[`Float80`]: <https://developer.apple.com/documentation/swift/Float80>
[`Double`]: <https://developer.apple.com/documentation/swift/Double>
[`String`]: <https://developer.apple.com/documentation/swift/String>
[`Character`]: <https://developer.apple.com/documentation/swift/Character>
[`StaticString`]: <https://developer.apple.com/documentation/swift/StaticString>

[`BinaryInteger`]: <https://developer.apple.com/documentation/swift/BinaryInteger>
[`FloatingPoint`]: <https://developer.apple.com/documentation/swift/FloatingPoint>
[`Numeric`]: <https://developer.apple.com/documentation/swift/Numeric>
[`SIMD`]: <https://developer.apple.com/documentation/swift/simd>

[`CGFloat`]: <https://developer.apple.com/documentation/corefoundation/cgfloat>
[`Decimal`]: <https://developer.apple.com/documentation/foundation/decimal>
[`NSNumber`]: <https://developer.apple.com/documentation/foundation/nsnumber>

[`Number`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/Number.swift>
[`NaturalNumber`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/z_NaturalNumber.swift>
[`WholeNumber`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/y_WholeNumber.swift>
[`Integer`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/x_Integer.swift>
[`SimpleFraction`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/w_SimpleFraction.swift>
[`RationalNumber`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/v_RationalNumber.swift>
[`IrrationalNumber`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/u_IrrationalNumber.swift>
[`RealNumber`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/t_RealNumber.swift>
[`ImaginaryNumber`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/s_ImaginaryNumber.swift>
[`ComplexNumber`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/Number/Sources/Number/Classifications/r_ComplexNumber.swift>

[`ArbitraryPrecisionSignedInteger`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/ArbitraryPrecisionIntegers/Sources/ArbitraryPrecisionIntegers/ArbitraryPrecisionSignedInteger.swift>
[`ArbitraryPrecisionUnsignedInteger`]: <https://github.com/hexleytheplatypus/swift-experimental-number/blob/main/ArbitraryPrecisionIntegers/Sources/ArbitraryPrecisionIntegers/ArbitraryPrecisionUnsignedInteger.swift>
