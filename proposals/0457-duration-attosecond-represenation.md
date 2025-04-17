# Expose attosecond representation of `Duration`

* Proposal: [SE-0457](0457-duration-attosecond-represenation.md)
* Authors: [Philipp Gabriel](https://github.com/ph1ps)
* Review Manager: [Stephen Canon](https://github.com/stephentyrone)
* Status: **Implemented (Swift 6.2)**
* Implementation: [swiftlang/swift#78202](https://github.com/swiftlang/swift/pull/78202)
* Review: ([pitch](https://forums.swift.org/t/pitch-adding-int128-support-to-duration))([review](https://forums.swift.org/t/se-0457-expose-attosecond-representation-of-duration/77249))

## Introduction
This proposal introduces public APIs to enable seamless integration of `Int128` into the `Duration` type. Specifically, it provides support for directly accessing a `Duration`'s attosecond representation via the newly available `Int128` type and simplifies the creation of `Duration` values from attoseconds.

## Motivation
The `Duration` type currently offers two ways to construct and decompose itself:

**Low and high bits**
```swift
public struct Duration: Sendable {
  public var _low: UInt64
  public var _high: Int64
  public init(_high: Int64, low: UInt64) { ... }
}
```
**Components**
```swift
extension Duration {
  public var components: (seconds: Int64, attoseconds: Int64) { ... }
  public init(secondsComponent: Int64, attosecondsComponent: Int64) { ... }
}
```
However, both approaches have limitations when it comes to exposing `Duration`'s total attosecond representation:
- The `_low` and `_high` properties are underscored, indicating that their direct use is discouraged.
- The `components` property decomposes the value into seconds and attoseconds, requiring additional arithmetic operations for many use cases.

This gap becomes particularly evident in scenarios like generating a random `Duration`, which currently requires verbose and potentially inefficient code:
```swift
func randomDuration(upTo maxDuration: Duration) -> Duration {
  let attosecondsPerSecond: Int128 = 1_000_000_000_000_000_000
  let upperRange = Int128(maxDuration.components.seconds) * attosecondsPerSecond + Int128(maxDuration.components.attoseconds)
  let (seconds, attoseconds) = Int128.random(in: 0..<upperRange).quotientAndRemainder(dividingBy: attosecondsPerSecond)
  return .init(secondsComponent: Int64(seconds), attosecondsComponent: Int64(attoseconds))
}
```

By introducing direct `Int128` support to `Duration`, this complexity is eliminated. Developers can write concise and efficient code instead:
```swift
func randomDuration(upTo maxDuration: Duration) -> Duration {
  return Duration(attoseconds: Int128.random(in: 0..<maxDuration.attoseconds))
}
```
This addition reduces boilerplate, minimizes potential errors, and improves performance for use cases requiring high-precision time calculations.

## Proposed solution
This proposal complements the existing construction and decomposition options by introducing a third approach, leveraging the new `Int128` type:

- A new computed property `attoseconds`, which exposes the total attoseconds of a `Duration` as an `Int128`.
- A new initializer `init(attoseconds: Int128)`, which allows creating a `Duration` directly from a single 128-bit value.

These additions provide a direct and efficient mechanism for working with `Duration` values while maintaining full compatibility with existing APIs.

## Detailed design
Internally, the `Duration` type represents its value using the underscored `_high` and `_low` properties, which encode attoseconds as a 128-bit integer split into two 64-bit values. The proposed APIs unify these components into a single `Int128` representation:
```swift
@available(SwiftStdlib 6.0, *)
extension Duration {
  /// The duration represented in attoseconds.
  public var attoseconds: Int128 {
    Int128(_low: _low, _high: _high)
  }
  
  /// Initializes a `Duration` from the given number of attoseconds.
  public init(attoseconds: Int128) {
    self.init(_high: attoseconds._high, low: attoseconds._low)
  }
}
```

## Source compatibility
This proposal is additive and source-compatible with existing code.

## ABI compatibility
This proposal is additive and ABI-compatible with existing code.

## Implications on adoption
The additions described in this proposal require a new version of the standard library.

## Alternatives considered
### Static factory instead of or in addtion to initializer
An alternative approach to the proposed `init(attoseconds:)` initializer is a static factory method. This design aligns with existing methods like `nanoseconds`, `microseconds`, etc., and provides a consistent naming pattern for creating `Duration` values.

```swift
@available(SwiftStdlib 6.0, *)
extension Duration {
  public static func attoseconds(_ attoseconds: Int128) -> Duration { ... }
}
```

However, this approach would introduce asymmetry to other factory methods which support both `Double` and `BinaryInteger` overloads:
```swift
extension Duration {
  public static func microseconds<T: BinaryInteger>(_ microseconds: T) -> Duration { ... }
  public static func microseconds(_ microseconds: Double) -> Duration { ... }
}
```
For attoseconds, adding these overloads would lead to practical issues:

1. A `Double` overload is nonsensical because sub-attoseconds are not supported, meaning the method cannot represent fractional attoseconds.
2. A `BinaryInteger` overload introduces additional complexity. Since it would need to support types other than `Int128`, arithmetic operations would be necessary to ensure correct scaling and truncation, negating the simplicity and precision that the `Int128`-specific initializer aims to provide.

Ultimately, the static func `attoseconds(_:)` would likely end up as a one-off method with only an `Int128` overload. This inconsistency diminishes the appeal of the factory method approach. The proposed `init(attoseconds:)` initializer avoids these issues, offering a direct and clear way to work with attoseconds, while remaining symmetrical with the existing `Duration` API structure.
