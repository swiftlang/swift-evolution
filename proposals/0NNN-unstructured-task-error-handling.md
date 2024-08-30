# Feature name

* Proposal: [SE-NNNN](0NNN-unstructured-task-error-handling.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Matt Massicotte](https://github.com/mattmassicotte)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift/pull/74110](https://github.com/swiftlang/swift/pull/74110)
* Upcoming Feature Flag: *if applicable* `MyFeatureName`
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

TBD

## Detailed design

TBD

## Source compatibility

TBD

## ABI compatibility

TBD

## Implications on adoption

TBD

## Future directions

TBD

## Alternatives considered

TBD

## Acknowledgments

TBD
