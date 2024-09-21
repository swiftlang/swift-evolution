# Improved error handling in unstructured Task initializers

* Proposal: [SE-NNNN](0NNN-unstructured-task-error-handling.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Matt Massicotte](https://github.com/mattmassicotte)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift/pull/74110](https://github.com/swiftlang/swift/pull/74110)
* Upcoming Feature Flag: `TaskInitTypedThrows`
* Review: ([pitch](https://forums.swift.org/t/pitch-non-discardable-throwing-tasks/74138))

## Introduction

This proposal modifies the API of `Task` to adopt typed throws and makes it
more difficult to ignore thrown errors accidentally.

## Motivation

The purpose of unstructured tasks is to create a new asynchronous context in
which computation may happen.
Unlike the structured constructs (async lets and task groups),
unstructured tasks to not have to be awaited.
Their results and thrown errors are simple to discard by just not storing and
not awaiting on the created task's `.value`.

Tasks are typed using both the `Success` and `Failure`.
However, until the recent introduction of [typed throws][] to the language,
the `Failure` type could only ever have been `Never` or `any Error`.

For example, the following snippet showcases how we lose the error type
information when throwing within a task:

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
this code is ignoring any failure.
This *could* be the author's intention, but it not really possible to
determine this by looking the code.
The community has frequently requested this be rectified,
such that ignoring an error requires a more explicit expression of intention.

[typed throws]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md

## Proposed solution

We propose two changes to the `Task` initialization functions to address
these problems:

- adopt typed throws
- remove the use of `@discardableResult` unless `Failure` is `Never`

## Detailed design

`Task` currently has two initializers and matching detached variants:
`.init` and `.detached`.

We propose to adjust these initializers in two ways.

### Non-throwing overloads

In these cases, the `@discardableResult` remains useful.
It is common to create fire-and-forget tasks that do not require access to the
result at the point of creation.

```swift
Task { await doSomething() }
```

These signatures would be unchanged.

```swift
extension Task where Failure == Never {
  @discardableResult
  public init(
    priority: TaskPriority? = nil,
    operation: sending @escaping @isolated(any) () async -> Success
  ) {
    // ...
  }

  @discardableResult
  public static func detached(
    priority: TaskPriority? = nil,
    operation: sending @escaping @isolated(any) () async -> Success
  ) -> Task<Success, Never> {
    // ...
  }
}
```

### Throwing overloads

In the cases of a non-`Never` error, the signatures would be adjusted by:

- removing the `@discardableResult` attribute
- adopting typed throws

We argue that the fact that accidentally forgetting to handle an error is
more common and "risky"
than forgetting to obtain the result value of an unstructured task.
If a task is created and it's result is important to handle,
developers naturally will store and await it.
However, ignoring errors even in the simple "fire-and-forget" task case,
may yield to unexpected and silent dropping of errors.

Therefore we argue that the discardable result behavior need only be dropped
from the throwing versions of these APIs.

These signatures would be modified:

```swift
extension Task {
  public init(
    priority: TaskPriority? = nil,
    operation: sending @escaping @isolated(any) () async throws(Failure) -> Success
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

This proposal is source compatible.

However, it does intentionally introduce a warning into code that is
ignoring errors that may be thrown by awaiting on an unstructured `Task`.

If the developer's intent was truly to ignore the task handle and the
potentially thrown error,
they can explicitly ignore it to silence the warning.

```swift
let _ = Task {
  throw MyError.somethingBadHappened
}
```

The should improve code quality by making it more obvious when potential
errors are being ignored.

## ABI compatibility

This proposal is ABI additive.

APIs that require change are all annotated with `@_alwaysEmitIntoClient`,
so there is no ABI impact on changing them.

## Alternatives considered

It is completely possible to adopt typed throws for these APIs without
changing the behavior of the throwing case.
Further, introducing a warning in cases where ignoring errors is intentionally
could be an annoyance.

However, choosing a surprising and potentially error-prone behavior as the
default goes against Swift's general philosophy of safety.
Changing this default feels like a much better balance, especially since
re-expressing the existing behavior involves such a familiar language pattern.

## Acknowledgments

Thanks to John McCall for engaging with the community on this topic and helping
to articulate the history and reasoning around the design.
