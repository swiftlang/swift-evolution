# TaskLocal test trait

* Proposal: [ST-0026](0026-task-local-test-trait.md)
* Authors: [Brandon Williams](https://github.com/mbrandonw), [Stephen Celis](https://github.com/stephencelis)
* Review Manager: [Stuart Montgomery](https://github.com/stmontgomery)
* Status: **Active Review (July 17...July 27, 2026)**
* Implementation: [swiftlang/swift-testing#1764](https://github.com/swiftlang/swift-testing/pull/1764)
* Review: ([pitch](https://forums.swift.org/t/pitch-add-a-tasklocal-trait-to-swift-testing/87603)) ([review](https://forums.swift.org/t/st-0026-tasklocal-test-trait/88358))

# Introduction

A `.taskLocal` test trait is added to Testing that allows binding a value to a task local for a suite
or test.

# Motivation

In [ST-0007], test scoping traits were introduced to allow wrapping the execution
of tests so that code could be run before and after each test. The main
motivation for this feature is overriding [`TaskLocal`s][SE-0311] for tests, and the
proposal mentions a [future direction][task-local-future-direction] to add a 
convenience trait specifically for binding task locals. This proposal adds that
convenience.

[SE-0311]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0311-task-locals.md
[ST-0007]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0007-test-scoping-traits.md
[task-local-future-direction]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0007-test-scoping-traits.md#convenience-trait-for-setting-task-locals

There are two primary motivations for adding this convenience:

* Task locals are by far the [most common] reason to define custom `TestScoping` 
  conformances. However, it takes quite a bit of repetitive work to define such
  conformances. For example, a trait to bind a boolean to a task local looks like this:

  [most common]: https://github.com/search?q=testscoping+language%3ASwift+&type=code

  ```swift
  struct IsEnabledTrait: SuiteTrait, TestTrait, TestScoping {
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
  to bind values to task locals in tests without creating a dedicated test support library.

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
  /// - Note: You must define the task local outside the test target where the trait is used.
  public static func taskLocal<Value: Sendable>(
    _ taskLocal: TaskLocal<Value>,
    _ value: @autoclosure @escaping @Sendable () throws -> Value
  ) -> Self
  where Self == TaskLocalTrait<Value>
}

/// A type that binds a task local value for the scope of a test.
///
/// To add this trait to a test, use ``Trait/taskLocal(_:_:)``.
public struct TaskLocalTrait<Value: Sendable>: SuiteTrait, TestTrait, TestScoping {
  /// This trait's task local.
  public var taskLocal: TaskLocal<Value> { get set }
  
  /// Evaluate this trait's bound value.
  public func evaluate() async throws -> Value

  public var isRecursive: Bool { get }
  
  public func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws
}
```

An important caveat to note (and is detailed in the documentation) is that the task local being
bound _must_ be defined outside the test target. One cannot bind a task local value like so:

```swift
@TaskLocal var isEnabled = false

@Test(.taskLocal($isEnabled, true))  // 🛑 Cannot find '$isEnabled' in scope
func test() {
 // ...
}
```

This is because currently the `@Test` macro cannot see the `$isEnabled` symbol created by the 
`@TaskLocal` macro (a [known issue] of macros). There are use cases for defining task locals in the
test target along side tests that want to override them, but it's not common, and you always have
the option to move the task local to a separate target.

[known issue]: https://forums.swift.org/t/macro-symbol-visibility-to-other-macros/87629

## Source compatibility

The proposed APIs are purely additive.

## Alternatives considered

A few other spellings have been proposed:

* `$isEnabled.set(true)`
* `.withValue(true, for: $isEnabled)`
* `.binding($isEnabled, to: true)`

We prefer the naming `.taskLocal(_:_:)` because it unambiguously refers to task locals, and keeps
the arguments in the same order as `withValue`.

We could also decide to not add the trait since technically it is possible to implement its 
functionality manually for each task local.

## Future directions

If Swift macros gain the ability to see symbols defined by other macros, this proposed API would
become usable in more contexts/situations.
