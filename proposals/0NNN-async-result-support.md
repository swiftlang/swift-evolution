# Async Result Support

* Proposal: SE-NNNN
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Matt Massicotte](https://github.com/mattmassicotte)
* Review Manager: TBD
* Status: **Pending implementation**
* Implementation: TBD
* Review: ([First Pitch](https://forums.swift.org/t/pitch-result-codable-conformance-and-async-catching-init/78566))

## Introduction

The `Result` type is a very useful tool for managing code that can throw. However, it is missing some feature that make using the type with asynchronous code inconvenient.

## Motivation

The existing `Result.init(catching:)` initializer is a useful tool for transforming throwing code into a `Result` instance. However, there's no equivalent overload that can do this for asynchronous code. While this isn't particularly difficult to write, because of the utility, it ends up being manually duplicated in many code bases.

Such an initializer would make the following possible:

```swift
let result = Result {
  try await asyncWork()
}
```

It could be useful to take this even further. A `Task` wraps up possibly-throwing asynchronous work, the output of which is exposed with an accessor. A programmer might want to transform this output, a thrown error, or possibly both. These are exactly the kinds of operations that the `Result` API is intended to express.

Having an asynchronous initializer helps make these two types more compatible. But, a `Result`-based accessor provides a more streamlined interface. It also matches the continuation overloads that accept `Result` types nicely.

Here's how that might look in practice:

```swift
let result = await Task {
    try await asyncWork()
  }
  .result
  .flatMap { transformValue($0) }
```

## Proposed solution

Both problems can be solved with additions to the standard library. First, by adding an async overload of the catching initializer. And second, a convenience property on `Task` that provides access to a `Result`-based output.

## Detailed design

Here are the two proposed API changes.

### Result initializer

```swift
extension Result where Success: ~Copyable {
  /// Creates a new result by evaluating a throwing closure, capturing the
  /// returned value as a success, or any thrown error as a failure.
  ///
  /// - Parameter body: A potentially throwing asynchronous closure to evaluate.
  @_alwaysEmitIntoClient
  public nonisolated(nonsending) init(catching body: () async throws(Failure) -> Success) async {
    do {
      self = .success(try await body())
    } catch {
      self = .failure(error)
    }
  }
}
```

### Task accessor

```swift
extension Task {
  @_alwaysEmitIntoClient
  public var result: Result<Success, Failure> {
    async get {
      Result { try await self.value }
    }
  }
}
```

## Source compatibility

This proposal is purely additive and will not have any source compatibility implications.

## Effect on ABI stability

The proposal is purely additive.

Both the initializer and accessor can be backdeployed.

## Alternatives considered

It would be possible to add `map`, `mapError`, and other transformation operations directly on the `Task` type. And doing this could potentially make it possible to defer awaiting for the output. However, this would largely be a duplication of existing functionality in `Result` while also making it incompatible with other APIs that make use of `Result` types today.

Adding a result accessor is a small thing, particularly with the availability of an async initializer. But doing so does help keep longer chains of transformation code tidy and similar constructs are found in many existing Swift APIs.
