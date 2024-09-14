# Feature name

* Proposal: [SE-NNNN](0NNN-unstructured-task-error-handling.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Matt Massicotte](https://github.com/mattmassicotte)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift/pull/74110](https://github.com/swiftlang/swift/pull/74110)
* Upcoming Feature Flag: `TaskInitTypedThrows`
* Review: ([pitch](https://forums.swift.org/t/pitch-non-discardable-throwing-tasks/74138))

## Introduction

This proposal modifies the API of `Task` to adopt typed throws and changes the
default so it is no longer possible to passively ignore any thrown errors.

## Motivation

The purpose of the `Task` APIs is to capture the outcome of an asynchronous
operation, either as a resulting value or an error.
The actual error type, however, is not available to callers that access this
result via the `value` accessor.
This is exactly the kind of problem that [typed throws][] can address.

```swift
let task = Task {
  throw MyError.somethingBadHappened
}

do {
  _ = try await task.value
} catch {
  // type information has been lost and error is now `any Error`
}
```

Additionally, all the `Task` creation APIs are annotated with
`@discardableResult`, including those that permit failure.
This makes it extremely easy for the code creating the task to
unintentionally ignore errors thrown in the body.
This default has proven to be surprising, error-prone, and difficult to debug.

```swift
Task {
  try first()
  try second()
  try third()
}
```

Because the creating site has not captured a reference to the task,
this code is ignoring any failure. This *could* be the author's intention,
but it not really possible to determine this by looking the code. 

[typed throws]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md

## Proposed solution

We propose two changes to the `Task` initialization functions to address these problems:

- adopt typed throws
- remove the use of `@discardableResult` unless `Failure` is `Never`

## Detailed design

`Task` now has new initializers and matching detached variants.
In the case where `Failure` is `Never`,
these do not permit a throwing body and preserve the ability to ignore the
created `Task` instance.

```swift
extension Task where Failure == Never {
  @discardableResult
  @_alwaysEmitIntoClient
  public init(
    priority: TaskPriority? = nil,
    @_inheritActorContext @_implicitSelfCapture operation: __owned sending @escaping @isolated(any) () async -> Success
  ) {
    // ...
  }

  @discardableResult
  @_alwaysEmitIntoClient
  public static func detached(
    priority: TaskPriority? = nil,
    operation: __owned sending @escaping @isolated(any) () async -> Success
  ) -> Task<Success, Never> {
    // ...
  }
}
```

However, for a non-`Never` `Failure`, the `throws` cause exposes the type
and the `@discardableResult` is dropped.

```swift
extension Task {
  @_alwaysEmitIntoClient
  public init(
    priority: TaskPriority? = nil,
    @_inheritActorContext @_implicitSelfCapture operation: __owned sending @escaping @isolated(any) () async throws(Failure) -> Success
  ) {
    // ...
  }

  @_alwaysEmitIntoClient
  public static func detached(
    priority: TaskPriority? = nil,
    operation: __owned sending @escaping @isolated(any) () async throws(Failure) -> Success
  ) -> Task<Success, Failure> {
    // ...
  }
}
```

The `value` property used a typed throws clause to expose the `Failure` at
the site of access.

```swift
extension Task {
  public var value: Success {
    get async throws(Failure) {
      // ...
    }
  }
}
```

## Source compatibility

This proposal should not affect the behavior of existing code.

However, it does intentionally introduce a warning into code that is
ignoring errors produced by a `Task`.
The developer's intention in this situation is inherently ambigous,
and one of the purposes of this proposal is to resolve this ambiguity.
The expectation is this will catch real mistakes.

Explicitly expressing the intention to actually ignore errors is also
very straightforward:

```swift
let = Task {
  throw MyError.somethingBadHappened
}
```

## ABI compatibility

This proposal does not change how any existing code is compiled.

## Implications on adoption

No new types are being introduced, and the APIs that require change are all
annotated with `@_alwaysEmitIntoClient`.
This propsoal can be implemented purely in the compiler.

## Alternatives considered

It is completely possible to adopt typed throws for these APIs without
changing the behavior of the throwing case.
Further, introducing a warning in cases where ignoring errors is intentionally
could be an annoyance.

However, choosing a surprising and potentially error-prone behavior as the
default goes against Swift's general philosophy of safety.
Changing this default feels like a much better balance, especially since
re-expressing the existing behavior involves such a familar language pattern.

## Acknowledgments

Thanks to John McCall for engaging with the community on this topic and helping
to articulate the history and reasoning around the design.
