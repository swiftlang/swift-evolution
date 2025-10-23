# Polling Confirmations

* Proposal: [ST-NNNN](NNNN-polling-confirmations.md)
* Authors: [Rachel Brindle](https://github.com/younata)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-testing#1115](https://github.com/swiftlang/swift-testing/pull/1115)
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

Consider the following class, `Aquarium`, modeling raising dolphins:

```swift
@MainActor
final class Aquarium {
    private(set) var isRaising = false
    var hasFunding = true

    func raiseDolphins() {
        Task {
            if hasFunding {
                isRaising = true

                // Long running work that I'm not qualified to describe.
                // ...

                isRaising = false
            }
        }
    }
}
```

As is, it is extremely difficult to check that `isRaising` is correctly set to
true once `raiseDolphins` is called. The system offers test authors no
control for when the created task runs, leaving test authors add arbitrary sleep
calls. Like this example:

```swift
@Test func `raiseDolphins if hasFunding sets isRaising to true`() async throws {
    let subject = Aquarium()
    subject.hasFunding = true

    subject.raiseDolphins()

    try await Task.sleep(for: .seconds(1))

    #expect(subject.isRaising == true)
}
```

This requires test authors to have to figure out how long to wait so that
`isRaising` will reliably be set to true, while not waiting too long, such that
the test suite is not unnecessarily delayed or task itself finishes.

As another example, imagine a test author wants to verify that no dolphins are
raised when there isn't any funding. There isn't and can't be a mechanism for
verifying that `isRaising` is never set to `true`, but if we constrain the
problem to within a given timeframe, then we can have a reasonable assumption
that `isRaising` remains set to false. Again, without some other mechanism to
notify the test when to check `isRaising`, test authors are left to add
arbitrary sleep calls, when having the ability to fail fast would save a not
insignificant amount of time in the event that `isRaising` is mistakenly set to
true.

This proposal introduces polling to help test authors address these cases. In
this and other similar cases, polling makes these tests practical or even
possible, as well as speeding up the execution of individual tests as well as
the entire test suite.

## Proposed solution

This proposal introduces new members of the `confirmation` family of functions:
`confirmation(_:until:within:pollingEvery:isolation:sourceLocation:_:)`. These
functions take in a closure to be repeatedly evaluated until the specific
condition passes, waiting at least some amount of time - specified by
`pollingEvery`/`interval` and defaulting to 1 millisecond - before evaluating
the closure again.

Both of these use the new `PollingStopCondition` enum to determine when to end
polling: `PollingStopCondition.firstPass` configures polling to stop as soon
as the `body` closure returns `true` or a non-`nil` value. At this point,
the confirmation will be marked as passing.
`PollingStopCondition.stopsPassing` configures polling to stop once the `body`
closure returns `false` or a `nil` value. At this point, the confirmation will
be marked as failing: an error will be thrown, and an issue will be recorded.

Under both `PollingStopCondition` cases, when the early stop condition isn't
reached, polling will continue up until approximately the `within`/`duration`
value has elapsed. When `PollingStopCondition.firstPass` is specified, reaching
the duration stop point will mark the confirmation as failing.
When `PollingStopCondition.stopsPassing` is specified, reaching the duration
stop point will mark the confirmation as passing.

Tests will now be able to poll code updating in the background using either of
the stop conditions. For the example of `Aquarium.raiseDolphins`, valid tests
might look like:

```swift
@Test func `raiseDolphins if hasFunding sets isRaising to true`() async throws {
    let subject = Aquarium()
    subject.hasFunding = true

    subject.raiseDolphins()

    try await confirmation(until: .firstPass) { subject.isRaising == true }
}

@Test func `raiseDolphins if no funding keeps isRaising false`() async throws {
    let subject = Aquarium()
    subject.hasFunding = false

    subject.raiseDolphins()

    try await confirmation(until: .stopsPassing) { subject.isRaising == false }
}
```

## Detailed design

### New confirmation functions

We will introduce 2 new members of the confirmation family of functions to the
testing library:

```swift
/// Poll expression within the duration based on the given stop condition
///
/// - Parameters:
///   - comment: An optional comment to apply to any issues generated by this
///     function.
///   - stopCondition: When to stop polling.
///   - duration: The expected length of time to continue polling for.
///     This value may not correspond to the wall-clock time that polling lasts
///     for, especially on highly-loaded systems with a lot of tests running.
///     If nil, this uses whatever value is specified under the last
///     ``PollingConfirmationConfigurationTrait`` added to the test or suite
///     with a matching stopCondition.
///     If no such trait has been added, then polling will be attempted for
///     about 1 second before recording an issue.
///     `duration` must be greater than 0.
///   - interval: The minimum amount of time to wait between polling attempts.
///     If nil, this uses whatever value is specified under the last
///     ``PollingConfirmationConfigurationTrait`` added to the test or suite
///     with a matching stopCondition.
///     If no such trait has been added, then polling will wait at least
///     1 millisecond between polling attempts.
///     `interval` must be greater than 0.
///   - isolation: The actor to which `body` is isolated, if any.
///   - sourceLocation: The source location to whych any recorded issues should
///     be attributed.
///   - body: The function to invoke.
///
/// - Throws: A `PollingFailedError` if the `body` does not return true within
///   the polling duration.
///
/// Use polling confirmations to check that an event while a test is running in
/// complex scenarios where other forms of confirmation are insufficient. For
/// example, waiting on some state to change that cannot be easily confirmed
/// through other forms of `confirmation`.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func confirmation(
  _ comment: Comment? = nil,
  until stopCondition: PollingStopCondition,
  within duration: Duration? = nil,
  pollingEvery interval: Duration? = nil,
  isolation: isolated (any Actor)? = #isolation,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ body: @escaping () async throws -> Bool
) async throws

/// Confirm that some expression eventually returns a non-nil value
///
/// - Parameters:
///   - comment: An optional comment to apply to any issues generated by this
///     function.
///   - stopCondition: When to stop polling.
///   - duration: The expected length of time to continue polling for.
///     This value may not correspond to the wall-clock time that polling lasts
///     for, especially on highly-loaded systems with a lot of tests running.
///     If nil, this uses whatever value is specified under the last
///     ``PollingConfirmationConfigurationTrait`` added to the test or suite
///     with a matching stopCondition.
///     If no such trait has been added, then polling will be attempted for
///     about 1 second before recording an issue.
///     `duration` must be greater than 0.
///   - interval: The minimum amount of time to wait between polling attempts.
///     If nil, this uses whatever value is specified under the last
///     ``PollingConfirmationConfigurationTrait`` added to the test or suite
///     with a matching stopCondition.
///     If no such trait has been added, then polling will wait at least
///     1 millisecond between polling attempts.
///     `interval` must be greater than 0.
///   - isolation: The actor to which `body` is isolated, if any.
///   - sourceLocation: The source location to whych any recorded issues should
///     be attributed.
///   - body: The function to invoke.
///
/// - Throws: A `PollingFailedError` if the `body` does not return true within
///   the polling duration.
///
/// - Returns: The last non-nil value returned by `body`.
///
/// Use polling confirmations to check that an event while a test is running in
/// complex scenarios where other forms of confirmation are insufficient. For
/// example, waiting on some state to change that cannot be easily confirmed
/// through other forms of `confirmation`.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@discardableResult
public func confirmation<R>(
  _ comment: Comment? = nil,
  until stopCondition: PollingStopCondition,
  within duration: Duration? = nil,
  pollingEvery interval: Duration? = nil,
  isolation: isolated (any Actor)? = #isolation,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ body: @escaping () async throws -> sending R?
) async throws -> R
```

### New `PollingStopCondition` enum

A new enum type, `PollingStopCondition` will be defined, specifying when to stop
polling before the duration has elapsed. Additionally, if the early stop
condition isn't fulfilled before the duration elapses, then this also defines
how the confirmation should be handled.

```swift
/// A type defining when to stop polling early.
/// This also determines what happens if the duration elapses during polling.
public enum PollingStopCondition: Sendable, Equatable {
  /// Evaluates the expression until the first time it returns true.
  /// If it does not pass once by the time the timeout is reached, then a
  /// failure will be reported.
  case firstPass

  /// Evaluates the expression until the first time it returns false.
  /// If the expression returns false, then a failure will be reported.
  /// If the expression only returns true before the timeout is reached, then
  /// no failure will be reported.
  /// If the expression does not finish evaluating before the timeout is
  /// reached, then a failure will be reported.
  case stopsPassing
}
```

### New `PollingFailedError` Error Type and `PollingFailedError.Reason` enum

A new error type, `PollingFailedError` to be thrown when the polling
confirmation doesn't pass. This contains a nested enum expressing the 2 reasons
why polling confirmations can fail: the stop condition failed, or the
confirmation was cancelled during the run:

```swift
/// A type describing an error thrown when polling fails.
public struct PollingFailedError: Error, Sendable {
  /// A type describing why polling failed
  public enum Reason: Sendable, Codable {
    /// The polling failed because it was cancelled using `Task.cancel`.
    case cancelled

    /// The polling failed because the stop condition failed.
    case stopConditionFailed(PollingStopCondition)
  }

  /// A user-specified comment describing this confirmation
  public var comment: Comment? { get }

  /// Why polling failed, either cancelled, or because the stop condition failed.
  public var reason: Reason { get }
}
```

### New `Issue.Kind` case

A new issue kind will be added to report specifically when a test fails due to
a failed polling confirmation.

```swift
public struct Issue {
  // ...
  public enum Kind {
    // ...

    /// An issue due to a polling confirmation having failed.
    ///
    /// - Parameters:
    ///   - reason: The ``PollingFailureReason`` behind why the polling
    ///     confirmation failed.
    ///
    /// This issue can occur when calling ``confirmation(_:until:within:pollingEvery:isolation:sourceLocation:_:)-455gr``
    /// or
    /// ``confirmation(_:until:within:pollingEvery:isolation:sourceLocation:_:)-5tnlk``
    /// whenever the polling fails, as described in ``PollingStopCondition``.
    case pollingConfirmationFailed(reason: PollingFailureReason)

    // ...
  }

  // ...
}
```

### New Trait

A new trait will be added to change the default values for the
`duration` and `interval` arguments for matching `PollingStopCondition`s.
Test authors will often want to poll for the `firstPass` stop condition for
longer than they poll for the `stopsPassing` stop condition, which is why there
are separate traits for configuring defaults for these functions.

```swift
/// A trait to provide a default polling configuration to all usages of
/// ``confirmation(_:until:within:pollingEvery:isolation:sourceLocation:_:)-455gr``
/// and
/// ``confirmation(_:until:within:pollingEvery:isolation:sourceLocation:_:)-5tnlk``
/// within a test or suite using the specified stop condition.
///
/// To add this trait to a test, use the ``Trait/pollingConfirmationDefaults``
/// function.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct PollingConfirmationConfigurationTrait: TestTrait, SuiteTrait {
  /// The stop condition to this configuration is valid for
  public var stopCondition: PollingStopCondition { get }

  /// How long to continue polling for. If nil, this will fall back to the next
  /// inner-most `PollingUntilStopsPassingConfigurationTrait.duration` value.
  /// If no non-nil values are found, then it will use 1 second.
  public var duration: Duration? { get }

  /// The minimum amount of time to wait between polling attempts. If nil, this
  /// will fall back to earlier `PollingUntilStopsPassingConfigurationTrait.interval`
  /// values. If no non-nil values are found, then it will use 1 millisecond.
  public var interval: Duration? { get }

  /// This trait will be recursively applied to all children.
  public var isRecursive: Bool { get }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension Trait where Self == PollingConfirmationConfigurationTrait {
  /// Specifies defaults for polling confirmations in the test or suite.
  ///
  /// - Parameters:
  ///   - stopCondition: The `PollingStopCondition` this trait applies to.
  ///   - duration: The expected length of time to continue polling for.
  ///     This value may not correspond to the wall-clock time that polling
  ///     lasts for, especially on highly-loaded systems with a lot of tests
  ///     running.
  ///     if nil, polling will be attempted for approximately 1 second.
  ///     `duration` must be greater than 0.
  ///   - interval: The minimum amount of time to wait between polling
  ///     attempts.
  ///     If nil, polling will wait at least 1 millisecond between polling
  ///     attempts.
  ///     `interval` must be greater than 0.
  public static func pollingConfirmationDefaults(
    until stopCondition: PollingStopCondition,
    within duration: Duration? = nil,
    pollingEvery interval: Duration? = nil
  ) -> Self
}
```

Specifying `duration` or `interval` directly on either new `confirmation`
function will override any value provided by the relevant trait. Additionally,
when multiple of these configuration traits with matching stop conditions are
specified, the innermost or last trait will be applied. When no trait with a
matching stop condition is found and no `duration` or `interval` values are
specified at the callsite, then the Testing library will use some default
values.

### Platform Availability

Polling confirmations will not be available on platforms that do not support
Swift Concurrency.

Polling confirmations will also not be available on platforms that do not
have the `Clock`, `Duration`, and related types. For Apple platforms, this
requires macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0 and visionOS 1.0.

### Duration and Concurrent Execution

Directly using the `duration` to determine when to stop polling is incredibly
unreliable in a
parallel execution environment, like most platforms Swift Testing runs on. The
fundamental issue is that if polling were to directly use a timeout to determine
when to stop execution, such as:

```swift
let end = ContinuousClock.now + timeout
while ContinuousClock.now < end {
    if await runPollAndCheckIfShouldStop() {
        // alert the user!
    }
    await Task.yield()
}
```

With enough system load, the polling check might only run a handful of times, or
even once, before the timeout is triggered. In this case, the component being
polled might not have had time to update its status such that polling could
pass. Using the `Aquarium.raiseDolphins` example from earlier: On the first time
that `runPollAndCheckIfShouldStop` executes the background task created by
`raiseDolphins` might not have started executing its closure, leading the
polling to continue. If the system is under sufficiently high load, which can
be caused by having a very large amount of tests in the test suite, then once
the `Task.yield` finishes and the while condition is checked again, then it
might now be past the timeout. Or the task created by `Aquarium.runDolphins`
might have started and the closure run to completion before the next time
`runPollAndCheckIfShouldStop()` is executed. Or both. This approach of using
a clock to check when to stop is inherently unreliable, and becomes increasingly
unreliable as the load on the system increases and as the size of the test suite
increases.

To prevent this, the Testing library will calculate how many times to poll the
`body`. This can be done by dividing the `duration` by the `interval`. For example,
with the default 1 second duration and 1 millisecond interval, the Testing
library could poll 1000 times, waiting 1 millisecond between polling attempts.
This is immune to the issues posed by concurrent execution, allowing it to
scale with system load and test suite size.
This is also very easy for test authors to understand and predict, even if it is
not fully accurate to wall-clock time - each poll attempt takes some amount of
time, even for very  fast `body` closures. Which means that the real-time
duration of a polling confirmation will always be longer than the value
specified in the `duration` argument.

### Usage

These functions can be used with an async test function:

```swift
@Test func `The aquarium's dolphin nursery works`() async {
    let subject = Aquarium()
    Task {
        await subject.raiseDolphins()
    }
    await confirmation(until: .firstPass) {
        await subject.dolphins.count == 1
    }
}
```

With the definition of `Aquarium` above, the closure may only need to be
evaluated a few times before it starts returning true. At which point polling
will end, and no failure will be reported.

Polling will be stopped when either:

- the specified `duration` has elapsed,
- the task that started the polling is cancelled,
- the closure returns a value that satisfies the stopping condition, or
- the closure throws an error.

### When Polling should not be used

Polling is not a silver bullet, and should not be abused. In many cases, the
problems that polling solves can be solved through other, better means. Such as
the observability system, using Async sequences, callbacks, or delegates. When
possible, implementation code which requires polling to be tested should be
refactored to support other means. Polling exists for the case where such
refactors are either not possible or require a large amount of overhead.

Polling introduces a small amount of instability to the tests - in the example
of waiting for `Aquarium.isRaising` to be set to true, it is entirely possible
that, unless the code covered by
`// Long running work that I'm not qualified to describe` has a test-controlled
means to block further execution, the created `Task` could finish between
polling attempts - resulting `Aquarium.isRaising` to always be read as false,
and failing the test despite the code having done the right thing.

Polling also only offers a snapshot in time of the state. When
`PollingStopCondition.firstPass` is used, polling will stop and return a pass
after the first time the `body` returns true, even if any subsequent calls
would've returned false.

Furthermore, polling introduces delays to the running code. This isn't that
much of a concern for `PollingStopCondition.firstPass`, where the passing
case minimizes test execution time. However, the
passing case when using `PollingStopCondition.stopsPassing` utilizes the full
duration specified. If the test author specifies the polling duration to be
10 minutes, then the test will poll for approximately that long, so long as the
polling body keeps returning true.

Despite all this, we think that polling is an extremely valuable tool, and is
worth adding to the Testing library.

## Source compatibility

This is a new interface that is unlikely to collide with any existing
client-provided interfaces. The typical Swift disambiguation tools can be used
if needed.

## Future directions

### More `confirmation` types

We plan to add support for more push-based monitoring, such as integrating with
the Observation module to monitor changes to `@Observable` objects during some
lifetime.

These are out of scope for this proposal, and may be part of future proposals.

### Adding timeouts to existing `confirmation` APIs

One common request for the existing `confirmation` APIs is a timeout: wait
either until the condition is met, or some amount of time has passed. Adding
that would require additional consideration outside of the context of this
proposal. As such, adding timeouts to the existing (or future) `confirmation`
APIs may be part of a future proposal.

### More Stop Conditions

One possible future direction is adding additional stop conditions. For example,
a stop condition where we expect the body closure to initially be false, but to
continue passing once it starts passing. Or a `custom` stop condition, allowing
test authors to define their own stop conditions.

In order to keep this proposal focused, I chose not to add them yet. They may
be added as part of future proposals.

### Curved polling rates

As initially specified, the polling rate is flat: poll, sleep for the
specified polling interval, repeat until the stop condition or timeout is
reached.

Instead, polling could be implemented as a curve. For example, poll very
frequently at first, but progressively wait longer and longer between poll
attempts. Or the opposite: poll sporadically at first, increasing in frequency
as polling continues. We could even offer custom curve options.

For this initial implementation, I wanted to keep this simple. As such, while
a curve is promising, I think it is better considered on its own as a separate
proposal.

## Alternatives considered

### Use separate functions instead of the `PollingStopCondition` enum

Instead of the `PollingStopCondition` enum, we could have created different
functions for each stop condition. This would double the number new confirmation
functions being added, and require additional `confirmation` functions to be
added as we define new stop conditions. In addition to ballooning the number
of `confirmation` functions, this would also harm usability: to differentiate
polling confirmations from the other `confirmation` functions, there needs to be
at least one named argument without a default which isn't the `body` closure.
I was unwilling to compromise on the `duration` and `interval` arguments,
because being able to fall back to defaults is important to usability.
Instead, I created the `stopCondition` argument as the one named argument
without a default.

### Directly use timeouts

Polling could be written in such a way that it stops after some amount of time
has passed. Naively, this could be written as:

```swift
func poll(timeout: Duration, expression: () -> Bool) -> Bool {
    let clock: Clock = // ...
    let endTimestamp = clock.now + timeout
    while clock.now < endTimestamp {
        if expression() { return true }
    }
    return false
}
```

Unfortunately, while this could work reasonably well in an environment where
tests are executed serially, the concurrent test runner the testing library uses
means that timeouts are inherently unreliable. Importantly, timeouts become more
unreliable the more tests in the test suite.

### Use polling iterations

Another option considered was using polling iterations, either solely or
combined with the interval value.

While this works and is resistant to many of the issues timeouts face
in concurrent testing environments - which is why polling is implemented using
iterations & sleep intervals - it is extremely difficult for test authors to
predict a good-enough polling iterations value, reducing the utility of this
feature. Most test authors think in terms of a duration, and I would expect test
authors to either not use this feature, or to add helpers to compute a polling
iteration count from a duration value anyway.

### Take in a `Clock` instance

Polling confirmations could take in and use an custom Clock by test authors.
This is not supported because Polling is often used to wait out other delays,
which may or may not use the specified Clock. By staying with the default
continuous clock, Polling confirmations will continue to work even if a test
author otherwise uses a non-standard clock, such as one that skips all sleep
calls, or a clock that allows test authors to specifically control how it
advances.

### Use macros instead of functions

Instead of adding new bare functions, polling could be written as additional
macros, something like:

```swift
#expectUntil { ... }
#expectAlways { ... }
```

However, there's no additional benefit to doing this, and it may even lead test
authors to use polling when other mechanisms would be more appropriate.

## Acknowledgements

This proposal is heavily inspired by Nimble's [Polling Expectations](https://quick.github.io/Nimble/documentation/nimble/pollingexpectations/).
In particular, thanks to [Jeff Hui](https://github.com/jeffh) for writing the
original implementation of Nimble's Polling Expectations.

Additionally, I'd like to thank [Jonathan Grynspan](https://github.com/grynspan)
for his help with API design during the pitch phase of this proposal.
