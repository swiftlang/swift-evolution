# Conform `Never` to `Codable`
 
* Proposal: [SE-0396](0396-never-codable.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Active Review (April 18...May 3, 2023)**
* Implementation: [apple/swift#64899](https://github.com/apple/swift/pull/64899)
* Review: ([pitch](https://forums.swift.org/t/pitch-conform-never-to-codable/64056)) ([review](https://forums.swift.org/t/se-0396-conform-never-to-codable/64469))

## Introduction

Extend `Never` so that it conforms to the `Encodable` and `Decodable` protocols, together known as `Codable`.

## Motivation

Swift can synthesize `Codable` conformance for any type that has `Codable` members. Generic types often participate in this synthesized conformance by constraining their generic parameters, like this `Either` type:

```swift
enum Either<A, B> {
    case left(A)
    case right(B)
}

extension Either: Codable where A: Codable, B: Codable {}
```

In this way, `Either` instances where both generic parameters are `Codable` are `Codable` themselves, such as an `Either<Int, Double>`. However, since `Never` isn't `Codable`, using `Never` as one of the parameters blocks the conditional conformance, even though it would be perfectly fine to encode or decode a type like `Either<Int, Never>`.

## Proposed solution

The standard library should add `Encodable` and `Decodable` conformance to the `Never` type.

## Detailed design

The `Encodable` conformance is simple — since it's impossible to have a `Never` instance, the `encode(to:)` method can simply be empty.

The `Decodable` protocol requires the `init(from:)` initializer, which clearly can't create a `Never` instance. Because trying to decode invalid input isn't a programmer error, a fatal error would be inappropriate. Instead, the implementation throws a `DecodingError.dataCorrupted` error if decoding is attempted.

## Source compatibility

If existing code already declares `Codable` conformance, that code will begin to emit a warning: e.g. `Conformance of 'Never' to protocol 'Encodable' was already stated in the type's module 'Swift'`.

The new conformance shouldn't differ from existing conformances, since it isn't possible to construct an instance of `Never`.

## ABI compatibility

The proposed change is additive and does not change any existing ABI.

## Implications on adoption

The new conformance will have availability annotations.

## Future directions

None.

## Alternatives considered

None.
