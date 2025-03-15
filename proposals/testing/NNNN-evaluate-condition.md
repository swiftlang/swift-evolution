# Public API to evaluate ConditionTrait

* Proposal: [SWT-NNNN](NNNN-evaluate-condition.md)
* Authors: [David Catmull](https://github.com/Uncommon)
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-testing#909](https://github.com/swiftlang/swift-testing/pull/909)
* Review: ([pitch](https://forums.swift.org/t/pitch-introduce-conditiontrait-evaluate/77242))

## Introduction

This adds an `evaluate()` method to `ConditionTrait` to evaluate the condition
without requiring a `Test` instance.

## Motivation

Currently, the only way a `ConditionTrait` is evaluated is inside the
`prepare(for:)` method. This makes it difficult for third-party libraries to
utilize these traits because evaluating a condition would require creating a
dummy `Test` to pass to that method.

## Proposed solution

The proposal is to add a `ConditionTrait.evaluate()` method which returns the
result of the evaluation. The existing `prepare(for:)` method is updated to call
`evaluate()` so that the logic is not duplicated.

## Detailed design

The `evaluate()` method is as follows, containing essentially the same logic
as was in `prepare(for:)`:

```swift
public func evaluate() async throws -> EvaluationResult {
  switch kind {
  case let .conditional(condition):
    try await condition()
  case let .unconditional(unconditionalValue):
    (unconditionalValue, nil)
  }
}
```

`EvaluationResult` is a `typealias` for the tuple already used as the result
of the callback in `Kind.conditional`:

```swift
public typealias EvaluationResult = (wasMet: Bool, comment: Comment?)
```

## Source compatibility

This change is purely additive.

## Integration with supporting tools

This change allows third-party libraries to apply condition traits at other
levels than suites or whole test functions, for example if tests are broken up
into smaller sections.

## Future directions

This change seems sufficient for third party libraries to make use of
`ConditionTrait`. Changes for other traits can be tackled in separate proposals.

## Alternatives considered

Exposing `ConditionTrait.Kind` and `.kind` was also considered, but it seemed
unnecessary to go that far, and it would encourage duplicating the logic that
already exists in `prepare(for:)`.

In the first draft implementation, the `EvaluationResult` type was an enum that
only contained the comment in the failure case. It was changed to match the
existing tuple to allow for potentially including comments for the success case
without requiring a change to the API.
