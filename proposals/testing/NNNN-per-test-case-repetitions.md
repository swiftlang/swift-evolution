# Per-test-case repetition

* Proposal: [ST-NNNN](NNNN-filename.md)
* Authors: [Harlan Haskins](https://github.com/harlanhaskins)
* Review Manager: TBD
* Status: **Awaiting review**
* Bugs: [swiftlang/swift-testing#1392](https://github.com/swiftlang/swift-testing/issues/1392), rdar://130508488
* Implementation: [swiftlang/swift-testing#1528](https://github.com/swiftlang/swift-testing/pull/1528)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Since its initial release, Swift Testing has supported [repeating tests](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results#Run-testing-repeatedly-to-determine-reliability)
for a number of iterations, or until a specific failure/success condition is reached.

Currently, when a repetition condition is met by any of the test cases in the test target, all of the tests in the
test target are repeated.

This proposal seeks to change this iteration behavior to apply the repetition behavior to only those test cases that
met the repetition condition.

## Motivation

The current behavior causes unnecessary additional test execution; if only one test case of a large parameterized
test suite fails, it will cause all of the tests in the test target to run again. This also does not match the 
behavior of XCTest, which repeats failing test methods instead of all tests within an XCTestCase or the entire
test target.

It also does not match developer expectations; the phrase "repeat tests while issue recorded" implies that only
tests which have issues recorded will be repeated, but that is not the current behavior.

## Proposed solution

Swift Testing should instead only re-run test cases that meet the repetition condition. Further, iterations
should be reported directly along with `testStarted`/`testEnded` events, not via global `iteration` events,
and on `Test.Case` instances.

## Detailed design

### JSON schema changes

Add a per-test-case `iteration` value to event records in the 6.4 schema version.
This value is one-indexed and will be provided even if the configuration has set the repetition
policy to `.none`.

```diff
diff --git a/Documentation/ABI/JSON.md b/Documentation/ABI/JSON.md
index f4ae1b84..f315244b 100644
--- a/Documentation/ABI/JSON.md
+++ b/Documentation/ABI/JSON.md
@@ -205,6 +205,7 @@ sufficient information to display the event in a human-readable format.
   ["attachment": <attachment>,] ; the attachment (if kind is "valueAttached")
   "messages": <array:message>,
   ["testID": <test-id>,]
+  ["iteration": <number>] ; the one-indexed test iteration (if event is posted during test execution).
 }
```

The Tools SPI types will be updated to provide this information as well.

### Behavior changes

Individual test cases will have repetition conditions evaluated after every execution
and console output will be updated to match. The global iteration behavior will be
fully removed.

This does change observable behavior; if a serialized test suite expected a certain set of 
tests to be run _in order_, running some of them multiple times without running others may
break existing behavior. Such reliance, however, is an anti-pattern, and hidden dependencies
like these between test functions should be avoided.

## Source compatibility

This is purely additive with regards to the JSON schema. Clients of existing Tools SPI will need to
be updated to use the updated SPI values.

## Integration with supporting tools

If tools intend to support test repetition, they can provide the repetition behavior by providing
the existing `--repetitions` and `--repeat-until` command-line arguments in the Swift Testing
entrypoint. If not provided, all `iteration` values provided to `EncodedEvent`s will be `1`.

## Future directions

### Repetition trait

Developers may want to define repetition behaviors for specific tests that override the
global value passed in via configuration parameters. Such a trait could be useful for
repeating known-flaky tests in CI, for example.

```swift
@Test(.repeating(.whileIssueRecorded, maximumIterations: 5, comment: "This might get transiently disconnected")))
func somethingNetworkBound() {
    let value = await downloadSomethingFromTheInternet()
}
```

More consideration needs to be done with how this interacts with the existing top-level configuration property,
but this has been requested in the past.

This also doesn't reach the full level of granularity that the behavior would support; we would need some other
syntax for repeating just a subset of parameterized test cases.

```swift
@Test(
    .repeating(.whileIssueRecorded, maximumIterations: 5, "This might get transiently disconnected")),
    arguments: [
        TestEnvironment.production,
        .staging, // How can I specify that we should only repeat the test on `.staging`?
        .development
    ]
)
func somethingNetworkBound(env: TestEnvironment) {
    let value = await downloadSomethingFromTheInternet(environment: env)
    #expect(...)
}
```

### Exposing current iteration at runtime

We could add an accessor for clients to read the current iteration at runtime, which would enable
developers to do things like adding additional more expensive logging when a test retries to aid
in debugging the failure, without incurring that cost for most of their test runs.

```swift
@Test
func ableToConnectToSocket() {
    let value = await socket.connect(enableVerboseLogging: Test.currentIteration > 1)
    #expect(...)
}
```

## Alternatives considered

### Configuration for global vs case-level iteration

We could provide a toggle in `Configuration` for choosing the existingglobal iteration behavior.
However, in our experience and discussion with Swift Testing clients, the current behavior is almost always
seen as surprising and unexpected. As such, we see little value in leaving the old behavior in beyond
the amount required for staging a transition.

## Acknowledgments

Thanks to [@grynspan](https://github.com/grynspan) and [@stmontgomery](https://github.com/stmontgomery) for
helping me iterate this proposal and get the implementation solid, and to the Testing Workgroup for
the discussion that led to this proposal.
