# TaskLocal test trait

* Proposal: [ST-NNNN](NNNN-task-local-test-trait.md)
* Authors: [Brandon Williams](https://github.com/mbrandonw), [Stephen Celis](https://github.com/stephencelis)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-testing#NNNNN](https://github.com/swiftlang/swift-testing/compare/main...pointfreeco:swift-testing:task-local-test-trait)
* Review: ([pitch](https://forums.swift.org/...))

# Introduction

A `.taskLocal` test trait is added to Testing that allows overriding a task local for a suite
or test.

# Motivation

In [ST-0007], test scoping traits were introduced to allow wrapping the execution
of tests so that code could be run before and after each test. The main
motivation for this feature is overriding `[TaskLocal]`s for tests, and the
proposal mentions a [future direction][task-local-future-direction] to add a 
convenience trait specifically for overriding task locals. This proposal adds that
convenience.

[TaskLocals]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0311-task-locals.md
[ST-0007]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0007-test-scoping-traits.md
[task-local-future-direction]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0007-test-scoping-traits.md#convenience-trait-for-setting-task-locals

There are two primary motivations for adding this convenience:

* Task locals are by far the [most common] reason to define custom `TestScoping` 
  conformances. However, it takes quite a bit of repetitive work to define such
  conformances. For example, a trait to override a boolean task local looks like this:

  [most common]: https://github.com/search?q=testscoping+language%3ASwift+&type=code

  ```swift
  struct IsEnabledTrait: SuiteTrait, TestScoping, TestTrait {
    let isEnabled: Bool
    let isRecursive = true
    func provideScope(
      for test: Test,
      testCase: Test.Case?,
      performing function: () async throws -> Void
    ) async throws {
      try await FeatureFlags.$isEnabled.withValue(isEnabled) {
        try await function()
      }
    }
  }
  extension Trait where Self == IsEnabledTrait {
    static func isEnabled(_ isEnabled: Bool) -> Self {
      Self(isEnabled: isEnabled)
    }
  }
  ```

  Ideally, we can drastically streamline overriding task locals in test with a dedicated convenience
  trait.

* When a task local is defined in a reusable library, the library maintainer cannot easily define a
  test trait for overriding the task local. Non-test targets cannot access Testing symbols, and so
  such a helper needs to be defined in a dedicated "test support" library. This introduces more
  inconvenience when shipping task locals in libraries. A dedicated `.taskLocal` trait allows one
  to override task locals in tests without creating a dedicated test support library.

# Proposed solution

A `.taskLocal` trait will be defined in Testing that allows overriding a task local for a single
test or a whole suite:

```swift
@Suite(.taskLocal(FeatureFlags.$isEnabled, true))
struct MySuite {
  // ...
}
```

# Detailed design

A new type will be defined to conform to `TestScoping`, as well as a static function for ease of
constructing the trait:

```swift
extension Trait {
  /// Constructs a trait that binds a task local value for the duration of a test
  /// or suite.
  ///
  /// - Parameters:
  ///   - taskLocal: The task local to bind the value to.
  ///   - value: The value to set.
  ///
  /// ```swift
  /// @Suite(.taskLocal($myValue, 42))
  /// struct MyTests {
  ///   // ...
  /// }
  /// ```
  ///
  /// - Note: The task local must be defined outside the test target where the trait is used.
  public static func taskLocal<Value>(
    _ taskLocal: TaskLocal<Value>,
    _ value: Value
  ) -> Self
  where Self == TaskLocalTrait<Value> {
    TaskLocalTrait(taskLocal: taskLocal, value: value)
  }
}

/// A type that that overrides a task local value for the scope of a test.
///
/// To add this trait to a test, use ``Trait/taskLocal(_:_:)``.
public struct TaskLocalTrait<Value: Sendable>: SuiteTrait, TestScoping, TestTrait {
  public var isRecursive: Bool { true }

  fileprivate let taskLocal: TaskLocal<Value>
  fileprivate let value: Value

  public func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @concurrent () async throws -> Void
  ) async throws {
    try await taskLocal.withValue(value, operation: function)
  }
}
```

An important caveat to note (and is detailed in the documentation) is that the task local being
overridden _must_ be defined outside the test target. One cannot override a task local like so:

```swift
@TaskLocal var isEnabled = false

@Test(.taskLocal($isEnabled, true))  // 🛑 Cannot find '$isEnabled' in scope
func test() {
 // ...
}
```

This is because currently the `@Test` macro cannot see the `$isEnabled` symbol created by the 
`@TaskLocal` macro. There are use cases for defining task locals in the test target along side tests
that want to override them, but it's not common, and you always have the option to move the task
local to a separate target.

## Source compatibility

The proposed APIs are purely additive.

## Alternatives considered

A few other spellings have been proposed:

* `.set($isEnabled, true)`
* `.withValue(true, for: $isEnabled)`
* `.binding($isEnabled, to: true)`

We could also decide to not add the trait since technically it is possible to implement its 
functionality manually for each task local.

## Future directions

If Swift macros gain the ability to see symbols defined by other macros, we will be able to drop
the restriction that task locals be defined outside the test target.
