# Public API to evaluate ConditionTrait

* Proposal: [ST-0010](0010-evaluate-condition.md)
* Authors: [David Catmull](https://github.com/Uncommon)
* Review Manager: [Stuart Montgomery](https://github.com/stmontgomery)
* Status: **Implemented (Swift 6.2)**
* Bug: [swiftlang/swift-testing#903](https://github.com/swiftlang/swift-testing/issues/903)
* Implementation: [swiftlang/swift-testing#909](https://github.com/swiftlang/swift-testing/pull/909), [swiftlang/swift-testing#1097](https://github.com/swiftlang/swift-testing/pull/1097)
* Review: ([pitch](https://forums.swift.org/t/pitch-introduce-conditiontrait-evaluate/77242)) ([review](https://forums.swift.org/t/st-0010-public-api-to-evaluate-conditiontrait/79232)) ([acceptance](https://forums.swift.org/t/accepted-st-0010-public-api-to-evaluate-conditiontrait/79577))

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
extension ConditionTrait {
  /// Evaluate this instance's underlying condition.
  ///
  /// - Returns: The result of evaluating this instance's underlying condition.
  ///
  /// The evaluation is performed each time this function is called, and is not
  /// cached.
  public func evaluate() async throws -> Bool
}
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
