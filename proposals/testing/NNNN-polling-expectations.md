# Polling Expectations

* Proposal: [ST-NNNN](NNNN-polling-expectations.md)
* Authors: [Rachel Brindle](https://github.com/younata)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: (Working on it)
* Review: ([Pitch](https://forums.swift.org/t/pitch-polling-expectations/79866))

## Introduction

Test authors frequently need to wait for some background activity to complete
or reach an expected state before continuing. This proposal introduces a new API
to enable polling for an expected state.

## Motivation

Test authors can currently utilize the existing [`confirmation`](https://swiftpackageindex.com/swiftlang/swift-testing/main/documentation/testing/confirmation(_:expectedcount:isolation:sourcelocation:_:)-5mqz2)
APIs or awaiting on an `async` callable in order to block test execution until
a callback is called, or an async callable returns. However, this requires the
code being tested to support callbacks or return a status as an async callable.

This proposal adds another avenue for waiting for code to update to a specified
value, by proactively polling the test closure until it passes or a timeout is
reached.

More concretely, we can imagine a type that updates its status over an
indefinite timeframe:

```swift
actor Aquarium {
    var dolphins: [Dolphin]
    
    func raiseDolphins() async {
        // over a very long timeframe
        dolphins.append(Dolphin())
    }
}
```

## Proposed solution

This proposal introduces new overloads of the `#expect()` and `#require()`
macros that take, as arguments, a closure and a timeout value. When called,
these macros will continuously evaluate the closure until either the specific
condition passes, or the timeout has passed. The timeout period will default
to 1 second.

There are 2 Polling Behaviors that we will add: Passes Once and Passes Always.
Passes Once will continuously evaluate the expression until the expression
returns true. If the timeout passes without the expression ever returning true,
then a failure will be reported. Passes Always will continuously execute the
expression until the first time expression returns false or the timeout passes.
If the expression ever returns false, then a failure will be reported.

Tests will now be able to poll code updating in the background using
either of the new overloads:

```swift
let subject = Aquarium()
Task {
    await subject.raiseDolphins()
}
await #expect(until: .passesOnce) {
    await subject.dolphins.count == 1
}
```

## Detailed design

### New expectations

We will introduce the following new overloads of `#expect()` and `#require()` to
the testing library:

```swift
/// Continuously check an expression until it matches the given PollingBehavior
///
/// - Parameters:
///   - until: The desired PollingBehavior to check for.
///   - timeout: How long to run poll the expression until stopping.
///   - comment: A comment describing the expectation.
///   - sourceLocation: The source location to which the recorded expectations
///     and issues should be attributed.
///   - expression: The expression to be evaluated.
///
/// Use this overload of `#expect()` when you wish to poll whether a value
/// changes as the result of activity in another task/queue/thread.
@freestanding(expression) public macro expect(
    until pollingBehavior: PollingBehavior,
    timeout: Duration = .seconds(1),
    _ comment: @autoclosure () -> Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    expression: @Sendable () async throws -> Bool
) = #externalMacro(module: "TestingMacros", type: "PollingExpectMacro")

/// Continuously check an expression until it matches the given PollingBehavior
///
/// - Parameters:
///   - until: The desired PollingBehavior to check for.
///   - timeout: How long to run poll the expression until stopping.
///   - comment: A comment describing the expectation.
///   - sourceLocation: The source location to which the recorded expectations
///     and issues should be attributed.
///   - expression: The expression to be evaluated.
///
/// Use this overload of `#expect()` when you wish to poll whether a value
/// changes as the result of activity in another task/queue/thread, and you
/// expect the expression to throw an error as part of succeeding
@freestanding(expression) public macro expect<E>(
    until pollingBehavior: PollingBehavior,
    throws error: E,
    timeout: Duration = .seconds(1),
    _ comment: @autoclosure () -> Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    expression: @Sendable () async throws(E) -> Bool
) -> E = #externalMacro(module: "TestingMacros", type: "PollingExpectMacro")
where E: Error & Equatable

@freestanding(expression) public macro expect<E>(
    until pollingBehavior: PollingBehavior,
    timeout: Duration = .seconds(1),
    _ comment: @autoclosure () -> Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    performing expression: @Sendable () async throws(E) -> Bool,
    throws errorMatcher: (E) async throws -> Bool
) -> E = #externalMacro(module: "TestingMacros", type: "PollingExpectMacro")
where E: Error

/// Continuously check an expression until it matches the given PollingBehavior
///
/// - Parameters:
///   - until: The desired PollingBehavior to check for.
///   - timeout: How long to run poll the expression until stopping.
///   - comment: A comment describing the expectation.
///   - sourceLocation: The source location to which the recorded expectations
///     and issues should be attributed.
///   - expression: The expression to be evaluated.
///
/// Use this overload of `#require()` when you wish to poll whether a value
/// changes as the result of activity in another task/queue/thread.
@freestanding(expression) public macro require(
    until pollingBehavior: PollingBehavior,
    timeout: Duration = .seconds(1),
    _ comment: @autoclosure () -> Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    expression: @Sendable () async throws -> Bool
) = #externalMacro(module: "TestingMacros", type: "PollingRequireMacro")

@freestanding(expression) public macro require<R>(
    until pollingBehavior: PollingBehavior,
    timeout: Duration = .seconds(1),
    _ comment: @autoclosure () -> Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    expression: @Sendable () async throws -> R?
) = #externalMacro(module: "TestingMacros", type: "PollingRequireMacro")
where R: Sendable

@freestanding(expression) public macro require<E>(
    until pollingBehavior: PollingBehavior,
    throws error: E,
    timeout: Duration = .seconds(1),
    _ comment: @autoclosure () -> Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    expression: @Sendable () async throws(E) -> Bool
) = #externalMacro(module: "TestingMacros", type: "PollingRequireMacro")
where E: Error & Equatable

@freestanding(expression) public macro require<E>(
    until pollingBehavior: PollingBehavior,
    timeout: Duration = .seconds(1),
    _ comment: @autoclosure () -> Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    expression: @Sendable () async throws(E) -> Bool,
    throwing errorMatcher: (E) async throws -> Bool,
) = #externalMacro(module: "TestingMacros", type: "PollingRequireMacro")
where E: Error
```

### Polling Behavior

A new type, `PollingBehavior`, to represent the behavior of a polling
expectation:

```swift
public enum PollingBehavior {
    /// Continuously evaluate the expression until the first time it returns
    /// true.
    /// If it does not pass once by the time the timeout is reached, then a
    /// failure will be reported.
    case passesOnce
    
    /// Continuously evaluate the expression until the first time it returns
    /// false.
    /// If the expression returns false, then a failure will be reported.
    /// If the expression only returns true before the timeout is reached, then
    /// no failure will be reported.
    /// If the expression does not finish evaluating before the timeout is
    /// reached, then a failure will be reported.
    case passesAlways
}
```

### Usage

These macros can be used with an async test function:

```swift
@Test func `The aquarium's dolphin nursery works`() async {
    let subject = Aquarium()
    Task {
        await subject.raiseDolphins()
    }
    await #expect(until: .passesOnce) {
        await subject.dolphins.count == 1
    }
}
```

With the definition of `Aquarium` above, the closure will only need to be
evaluated a few times before it starts returning true. At which point the macro
will end, and no failure will be reported.

If the expression never returns a value within the timeout period, then a
failure will be reported, noting that the expression was unable to be evaluated
within the timeout period:

```swift
await #expect(until: .passesOnce, timeout: .seconds(1)) {
    // Failure: The expression timed out before evaluation could finish.
    try await Task.sleep(for: .seconds(10))
}
```

In the case of `#require` where the expression returns an optional value, under
`PollingBehavior.passesOnce`, the expectation is considered to have passed the
first time the expression returns a non-nil value, and that value will be
returned by the expectation. Under `PollingBehavior.passesAlways`, the
expectation is considered to have passed if the expression always returns a
non-nil value. If it passes, the value returned by the last time the
expression is evaluated will be returned by the expectation.

When no error is expected, then the first time the expression throws any error
will cause the polling expectation to stop & report the error as a failure.

When an error is expected, then the expression is not considered to pass
unless it throws an error that equals the expected error or returns true when
evaluated by the `errorMatcher`. After which the polling continues under the
specified PollingBehavior.

## Source compatibility

This is a new interface that is unlikely to collide with any existing
client-provided interfaces. The typical Swift disambiguation tools can be used
if needed.

## Integration with supporting tools

We will expose the polling mechanism under ForToolsIntegrationOnly spi so that
tools may integrate with them.

## Future directions

The timeout default could be configured as a Suite or Test trait. Additionally,
it could be configured in some future global configuration tool.

## Alternatives considered

### Remove `PollingBehavior` in favor of more macros

Instead of creating the `PollingBehavior` type, we could have introduced more
macros to cover that situation: `#expect(until:)` and `#expect(always:)`.
However, this would have resulted in confusion for the compiler and test authors
when trailing closure syntax is used.

### `PollingBehavior.passesOnce` continues to evaluate expression after passing

Under `PollingBehavior.passesOnce`, we thought about requiring the expression
to continue to pass after it starts passing. The idea is to prevent test
flakiness caused by an expectation that initially passes, but stops passing as
a result of (intended) background activity. For example:

```swift
@Test func `The aquarium's dolphin nursery works`() async {
    let subject = Aquarium()
    await subject.raiseDolphins()
    Task {
        await subject.raiseDolphins()
    }
    await #expect(until: .passesOnce) {
        await subject.dolphins.count == 1
    }
}
```

This test is flaky, but will pass more often than not. However, it is still
incorrect. If we were to change `PollingBehavior.passesOnce` to instead check
that the expression continues to pass after the first time it succeeds until the
timeout is reached, then this test would correctly be flagged as failing each
time it's ran.

We chose to address this by using the name `passesOnce` instead of changing the
behavior. `passesOnce` makes it clear the exact behavior that will happen: the
expression will be evaluated until the first time it passes, and no more. We
hope that this will help test authors to better recognize these situations.

## Acknowledgments

This proposal is heavily inspired by Nimble's [Polling Expectations](https://quick.github.io/Nimble/documentation/nimble/pollingexpectations/).
In particular, thanks to [Jeff Hui](https://github.com/jeffh) for writing the
original implementation of Nimble's Polling Expectations.
