# Constrain the granularity of test time limit durations

* Proposal: [ST-0004](0004-constrain-the-granularity-of-test-time-limit-durations.md)
* Authors: [Dennis Weissmann](https://github.com/dennisweissmann)
* Status: **Implemented (Swift 6.0)**
* Implementation: 
[swiftlang/swift-testing#534](https://github.com/swiftlang/swift-testing/pull/534)
* Review: 
([pitch](https://forums.swift.org/t/pitch-constrain-the-granularity-of-test-time-limit-durations/73146)),
([acceptance](https://forums.swift.org/t/pitch-constrain-the-granularity-of-test-time-limit-durations/73146/3))

> [!NOTE]
> This proposal was accepted before Swift Testing began using the Swift
> evolution review process. Its original identifier was
> [SWT-0004](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Proposals/0004-constrain-the-granularity-of-test-time-limit-durations.md).

## Introduction

Sometimes tests might get into a state (either due the test code itself or due 
to the code they're testing) where they don't make forward progress and hang.
Swift Testing provides a way to handle these issues using the TimeLimit trait:

```swift
@Test(.timeLimit(.minutes(60))
func testFunction() { ... }
```

Currently there exist multiple overloads for the `.timeLimit` trait: one that 
takes a `Swift.Duration` which allows for arbitrary `Duration` values to be 
passed, and one that takes a `TimeLimitTrait.Duration` which constrains the 
minimum time limit as well as the increment to 1 minute.

## Motivation

Small time limit values in particular cause more harm than good due to tests 
running in environments with drastically differing performance characteristics.
Particularly when running in CI systems or on virtualized hardware tests can 
run much slower than at desk.
Swift Testing should help developers use a reasonable time limit value in its 
API without developers having to refer to the documentation.

It is crucial to emphasize that unit tests failing due to exceeding their 
timeout should be exceptionally rare. At the same time, a spurious unit test 
failure caused by a short timeout can be surprisingly costly, potentially 
leading to an entire CI pipeline being rerun. Determining an appropriate 
timeout for a specific test can be a challenging task.

Additionally, when the system intentionally runs multiple tests simultaneously 
to optimize resource utilization, the scheduler becomes the arbiter of test 
execution. Consequently, the test may take significantly longer than 
anticipated, potentially due to external factors beyond the control of the code 
under test.

A unit test should be capable of failing due to hanging, but it should not fail 
due to being slow, unless the developer has explicitly indicated that it 
should, effectively transforming it into a performance test.

The time limit feature is *not* intended to be used to apply small timeouts to 
tests to ensure test runtime doesn't regress by small amounts. This feature is 
intended to be used to guard against hangs and pathologically long running 
tests.

## Proposed Solution

We propose changing the `.timeLimit` API to accept values of a new `Duration` 
type defined in `TimeLimitTrait` which only allows for `.minute` values to be 
passed.
This type already exists as SPI and this proposal is seeking to making it API.

## Detailed Design

The `TimeLimitTrait.Duration` struct only has one factory method:
```swift
public static func minutes(_ minutes: some BinaryInteger) -> Self
```

That ensures 2 things:
1. It's impossible to create short time limits (under a minute).
2. It's impossible to create high-precision increments of time.

Both of these features are important to ensure the API is self documenting and 
conveying the intended purpose.

For parameterized tests these time limits apply to each individual test case.

The `TimeLimitTrait.Duration` struct is declared as follows:

```swift
/// A type that defines a time limit to apply to a test.
///
/// To add this trait to a test, use one of the following functions:
///
/// - ``Trait/timeLimit(_:)``
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public struct TimeLimitTrait: TestTrait, SuiteTrait {
  /// A type representing the duration of a time limit applied to a test.
  ///
  /// This type is intended for use specifically for specifying test timeouts
  /// with ``TimeLimitTrait``. It is used instead of Swift's built-in `Duration`
  /// type because test timeouts do not support high-precision, arbitrarily
  /// short durations. The smallest allowed unit of time is minutes.
  public struct Duration: Sendable {

    /// Construct a time limit duration given a number of minutes.
    ///
    /// - Parameters:
    ///   - minutes: The number of minutes the resulting duration should
    ///     represent.
    ///
    /// - Returns: A duration representing the specified number of minutes.
    public static func minutes(_ minutes: some BinaryInteger) -> Self
  }

  /// The maximum amount of time a test may run for before timing out.
  public var timeLimit: Swift.Duration { get set }
}
```

The extension on `Trait` that allows for `.timeLimit(...)` to work is defined 
like this:

```swift
/// Construct a time limit trait that causes a test to time out if it runs for
/// too long.
///
/// - Parameters:
///   - timeLimit: The maximum amount of time the test may run for.
///
/// - Returns: An instance of ``TimeLimitTrait``.
///
/// Test timeouts do not support high-precision, arbitrarily short durations
/// due to variability in testing environments. The time limit must be at
/// least one minute, and can only be expressed in increments of one minute.
///
/// When this trait is associated with a test, that test must complete within
/// a time limit of, at most, `timeLimit`. If the test runs longer, an issue
/// of kind ``Issue/Kind/timeLimitExceeded(timeLimitComponents:)`` is
/// recorded. This timeout is treated as a test failure.
///
/// The time limit amount specified by `timeLimit` may be reduced if the
/// testing library is configured to enforce a maximum per-test limit. When
/// such a maximum is set, the effective time limit of the test this trait is
/// applied to will be the lesser of `timeLimit` and that maximum. This is a
/// policy which may be configured on a global basis by the tool responsible
/// for launching the test process. Refer to that tool's documentation for
/// more details.
///
/// If a test is parameterized, this time limit is applied to each of its
/// test cases individually. If a test has more than one time limit associated
/// with it, the shortest one is used. A test run may also be configured with
/// a maximum time limit per test case.
public static func timeLimit(_ timeLimit: Self.Duration) -> Self
```

And finally, the call site of the API looks like this:

```swift
@Test(.timeLimit(.minutes(60))
func serve100CustomersInOneHour() async {
  for _ in 0 ..< 100 {
    let customer = await Customer.next()
    await customer.order()
    ...
  }
}
```

The `TimeLimitTrait.Duration` struct has various `unavailable` overloads that
are included for diagnostic purposes only. They are all documented and
annotated like this:

```swift
/// Construct a time limit duration given a number of <unit>.
///
/// This function is unavailable and is provided for diagnostic purposes only.
@available(*, unavailable, message: "Time limit must be specified in minutes")
```

## Source Compatibility

This impacts clients that have adopted the `.timeLimit` trait and use overloads
of the trait that accept an arbitrary `Swift.Duration` except if they used the
`minutes` overload.

## Integration with Supporting Tools

N/A

## Future Directions

We could allow more finegrained time limits in the future that scale with the
performance of the test host device.
Or take a more manual approach where we detect the type of environment
(like CI vs local) and provide a way to use different timeouts depending on the
environment.

## Alternatives Considered

We have considered using `Swift.Duration` as the currency type for this API but 
decided against it to avoid common pitfalls and misuses of this feature such as
providing very small time limits that lead to flaky tests in different 
environments.

## Acknowledgments

The authors acknowledge valuable contributions and feedback from the Swift 
Testing community during the development of this proposal.
