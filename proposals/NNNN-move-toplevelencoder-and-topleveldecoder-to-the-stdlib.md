# Move `TopLevelEncoder` and `TopLevelDecoder` to the standard library

* Proposal: [SE-NNNN](NNNN-move-toplevelencoder-and-topleveldecoder-to-the-stdlib.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Bug: rdar://182341717
<!-- * Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN) or [swiftlang/swift-evolution-staging#NNNNN](https://github.com/swiftlang/swift-evolution-staging/pull/NNNNN) -->
* Review: ([pitch](https://forums.swift.org/t/pitch-move-toplevelencoder-and-topleveldecoder-to-the-standard-library/88318))

## Summary of changes

Moves the [`TopLevelEncoder`][] and [`TopLevelDecoder`][] protocols from the
Apple-specific Combine framework to the standard library (across all platforms).

## Motivation

The [`TopLevelEncoder`][] and [`TopLevelDecoder`][] protocols serve as abstract
representations of encoders (as used with [`Encodable`][] and [`Decodable`][]
respectively) as used by developers. These protocols are useful when designing
code that encodes or decodes values, but isn't picky about the format used.

However, these protocols are declared in Combine, an Apple-specific framework
that has not been ported to the other platforms that Swift supports. Combine is
not a natural home for these protocols and there is no specific technical
requirement that they be declared there.

## Proposed solution

I propose moving these protocols to the standard library (with the appropriate
ABI-preserving attributes on Apple platforms).

## Detailed design

These protocols are declared in the standard library instead of in Combine:

```swift
/// A type that defines methods for decoding.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public protocol TopLevelDecoder {

    /// The type this decoder accepts.
    associatedtype Input

    /// Decodes an instance of the indicated type.
    func decode<T>(_ type: T.Type, from: Self.Input) throws -> T where T : Decodable
}

/// A type that defines methods for encoding.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public protocol TopLevelEncoder {

    /// The type this encoder produces.
    associatedtype Output

    /// Encodes an instance of the indicated type.
    ///
    /// - Parameter value: The instance to encode.
    func encode<T>(_ value: T) throws -> Self.Output where T : Encodable
}
```

## Source compatibility

There should be no source compatibility impact in the general case. Swift
packages and libraries that declare their own types with these names may need to
rename them.

## ABI compatibility

On Apple platforms where we guarantee ABI stability, we will need to annotate
the protocols appropriately so that they are correctly linked from the Combine
framework when code runs on older Apple systems.

Any changes to Apple's frameworks to remove the protocol declarations are beyond
the scope of Swift Evolution. (I'll ask nicely though.)

There is no ABI impact on non-Apple, non-ABI-stable platforms.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no
deployment constraints and without affecting source or ABI compatibility.

## Future directions

N/A

## Alternatives considered

- **Adopting typed throws.** If this were new API, it would make perfect sense
  for the error thrown from `encode()` and `decode()` to be typed. Because the
  API already exists and does not use typed throws, it is ABI-breaking on Apple
  platforms to change the signature. Adding a new associated type with
  availability and then defaulting it to `any Error` does not satisfy the
  compiler unless `encode()` and `decode()` also have availability annotations,
  which would prevent them from being used on older Apple OSes.

- **Adopting typed throws only on non-Apple platforms.** This would not cause
  ABI breakage as non-Apple platforms do not have a stable Swift API, but it
  would make it more difficult to write cross-platform code that uses these
  protocols and wants to take advantage of the typed throws feature.
[`TopLevelEncoder`]: https://developer.apple.com/documentation/combine/toplevelencoder
[`TopLevelDecoder`]: https://developer.apple.com/documentation/combine/topleveldecoder
[`Encodable`]: https://developer.apple.com/documentation/swift/encodable
[`Decodable`]: https://developer.apple.com/documentation/swift/decodable