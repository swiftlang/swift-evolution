# Async Result Support

* Proposal: [SE-0530](0530-async-result-support.md)
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Matt Massicotte](https://github.com/mattmassicotte)
* Review Manager: [Doug Gregor](https://github.com/douggregor)
* Status: **Active Review (April 28-May 12, 2026)**
* Implementation: [swiftlang/swift#88465](https://github.com/swiftlang/swift/pull/88465)
* Review: ([First Pitch](https://forums.swift.org/t/pitch-result-codable-conformance-and-async-catching-init/78566))([Review](https://forums.swift.org/t/se-0530-async-result-support/86346))

## Introduction

The `Result` type is a very useful tool for managing code that can throw. However, it is missing an initializer that makes using the type with asynchronous code inconvenient.

## Motivation

The existing `Result.init(catching:)` initializer is a useful tool for transforming throwing code into a `Result` instance. However, there's no equivalent overload that can do this for asynchronous code. While this isn't particularly difficult to write, because of the utility, it ends up being manually duplicated in many code bases.

Such an initializer would make the following possible:

```swift
let result = await Result {
  try await asyncWork()
}
```

## Proposed solution

This problem can be solved by adding an async overload of the catching initializer.

## Detailed design

Here is the proposed API change:

```swift
extension Result where Success: ~Copyable {
  /// Creates a new result by evaluating a throwing closure, capturing the
  /// returned value as a success, or any thrown error as a failure.
  ///
  /// - Parameter body: A potentially throwing asynchronous closure to evaluate.
  @_alwaysEmitIntoClient
  public nonisolated(nonsending) init(catching body: nonisolated(nonsending) () async throws(Failure) -> Success) async {
    do {
      self = .success(try await body())
    } catch {
      self = .failure(error)
    }
  }
}
```

## Source compatibility

This is purely additive and will not have any source compatibility implications.

## Effect on ABI stability

The proposal is purely additive and the initializer can be backdeployed.
