# Result: Codable conformance & async init

* Proposal: SE-NNNN
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Pending implementation**
* Implementation: TBD

## Introduction

The `Result` type in Swift is often used to bridge between async and not async contexts, and could use some minor convenience improcements for both `async` contexts as well as encoding/decoding.

## Motivation

The Result type is often used to bridge between async and not async contexts, and it may be useful to initialize a `Result` from the result of an async computation, to then pass it along to other non-async code without unwrapping it first. This is currently inconvenitnt because the `init(catching:)` initializer is missing an `async` overload.

The Result type also is often reached for to encode a success or failure situation. As Swift gained typed throws, it became possible to write a catching initializer using typed throws, that would capture a `Codable` error and this makes it nice to express catching errors which are intended to be encoded as a result.

Those two changes allow us to write code like this:

```swift
func accept<A: Codable>(_: A) { ... }

enum SomeCodableError: Error, Codable { ... } 
func compute() throws(SomeCodableError) -> Int { ... }

let result: Result<Int, SomeCodableError> = Result { 
  try await compute()
}

accept(result)
```

## Detailed design

We propose two additions to the Result type in the standard library:

### Async catching initializer

We propose to add an async "catching" initializer that is equivalent to the existing synchronous version of this initializer:

```swift
extension Result where Success: ~Copyable {
  /// Creates a new result by evaluating a throwing closure, capturing the
  /// returned value as a success, or any thrown error as a failure.
  ///
  /// - Parameter body: A potentially throwing asynchronous closure to evaluate.
  @_alwaysEmitIntoClient
  public init(catching body: () async throws(Failure) -> Success) async {
    do {
      self = .success(try await body())
    } catch {
      self = .failure(error)
    }
  }
}
```

### Conditional `Codable` conformance

We propose to add a conditional Codable conformance, as follows:

```swift
extension Result: Codable where Success: Codable, Failure: Codable {}
```

The `Codable` implementation is the default, synthesized, one which was defined in [SE-0295: Codable synthesis for enums with associated values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0295-codable-synthesis-for-enums-with-associated-values.md).

## Source compatibility

This proposal is source compatible. Retroactive conformances are already warned about which would be the case for manual Codable conformances declared in adopter codebases.

## Effect on ABI stability

The proposal is purely additive.

The initializer can be backdeployed.

## Alternatives considered

### Don't provide these additions

In practice this means developers have to write their own `Result` types frequently, which is managable but ineffective, especially as the shape and utility of those types is generally a 1:1 copy of the existing `Result` type.
