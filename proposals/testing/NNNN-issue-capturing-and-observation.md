# Issue Capturing, Issue Observation & the TestingUtilities module

* Proposal: [ST-NNNN](NNNN-issue-capturing-and-observation.md)
* Authors: [Rachel Brindle](https://github.com/younata)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation:
  [swiftlang/swift-testing#1939](https://github.com/swiftlang/swift-testing/pull/1939)
* Review: ()

## Introduction

test utility authors have additional needs for the tooling they write compared
to test authors. One such need is the ability to verify that a testing utility
has reported an issue. Adding this has driven out a new approach for handling
issues that will be significantly more flexible and friendly to test utility
authors.

This proposal introduces a new TestingUtilities module with the testing library,
containing APIs specifically intended for test utility authors. The first APIs
in this new module API enable test authors to observe and verify that issues
were reported, as well as to otherwise control how issues are handled.

## Motivation

test utility authors can currently make use of the
[`withKnownIssue`](https://swiftpackageindex.com/swiftlang/swift-testing/main/documentation/testing/known-issues)
family of functions in order to verify that an issue was reported.
Unfortunately, the semantics of `withKnownIssue` are that any issue recorded
inside of `withKnownIssue` is something that needs to to be fixed. That is,
`withKnownIssue` is for tests that are not working correctly which the test
author has deprioritized fixing. There is no API for indicating that the issues
recorded inside are expected issues as part of the test or tool working
correctly.

For example, in [Nimble's](https://github.com/quick/Nimble) integration with
Swift Testing, the
[tests for the integration](https://github.com/Quick/Nimble/blob/main/Tests/NimbleTests/SwiftTestingSupportTest.swift)
utilize `withKnownIssue` in a semantically-incorrect way to validate that a
failing Nimble expectation is correctly reported to Swift Testing's issue
reporting system. In practice, this results in extraneous and unnecessary
console output and UI when Nimble's
`SwiftTestingSupportSuite.reportsAssertionFailuresToSwiftTesting` test runs,
which can be confusing to someone who doesn't already expect this.

Ideally, the maintainers of Nimble and other testing utilities who would wish to
write tests against their testing utilities would have an API that doesn't imply
that their correctly-behaving tool doesn't have an issue with it.

Furthermore, adding the ability to record reported issues and act on them opens
up an additional avenue for making use of the Testing DSL. For example, the
[Polling Confirmations](https://github.com/younata/swift-evolution/blob/younata/testing-polling-expectations/proposals/testing/NNNN-polling-confirmations.md)
pitch makes use of recording issues in order to indicate whether a polling
attempt has succeeded or failed.

The testing workgroup feels that there needs to be some space for APIs intended
for test utility authors which is separate from APIs intended for test authors.
As noted earlier, test utility authors often have need for additional need for
APIs that the vast majority of test authors do not need. Rather than clutter the
API surface of the main Testing module and potentially confuse test authors, we
instead will create a separate module within the Testing package to contain
these APIs intended solely for test utility authors.

## Proposed solution

This proposal introduces two entirely new APIs to observe and capture issues
before they are reported to the rest of the testing library:
`withIssueObservation(_:)` and `withIssueCapturing(_:)`. These are
tool-author-only APIs which return any issues recorded during the execution of
the `body` closures parameters. They differ in that `withIssueObservation(_:)`
will also pass the issue along to be reported to the rest of the testing
library, while `withIssueCapturing(_:)` will prevent the issue from being
reported to the rest of the testing library.

Both `withIssueObservation(_:)` and `withIssueCapturing(_:)` will be made
available as the first public APIs in the new `TestingUtilities` module within
the testing library package. `TestingUtilities` exists to define tooling
specifically to help test utility authors write and verify their libraries.

## Detailed design

### New TestingUtilities module

We will introduce a new module within the testing library, to provide the new
`withIssueCapturing`, and `withIssueObservation` APIs.

### New functions for observing issues

We will introduce 2 functions for observing issues, to be made available in
the new TestingUtilities module:

```swift
/// Invoke a function, and return any issues recorded during its execution.
/// Issues recorded will still be sent to the rest of the testing library.
///
/// - Parameters:
///   - body: The function to invoke.
///
/// Library authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
public func withIssueObservation(
  _ body: () throws -> Void
) -> [Issue]

/// Invoke a function, and return any issues recorded during its execution.
/// Issues recorded will still be sent to the rest of the testing library.
///
/// - Parameters:
///   - body: The function to invoke.
///
/// Library authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func withIssueObservation(
  _ body: sending @isolated(any) () async throws -> Void
) async -> [Issue]
```

`withIssueObservation(_:)` works to observe and record any issues which pass 
through it, at the point in the call stack where `withIssueObservation` is
added, passing the issue along to the rest of the testing library without making
any changes to it.

### New functions for capturing issues

We will introduce 2 functions for capturing issues, to be made available in
the new TestingUtilities module:

```swift
/// Invoke a function, capture and return any issues recorded during its
/// execution. Issues captured will not be sent to the rest of the testing
/// library.
///
/// - Parameters:
///   - body: The function to invoke.
///
/// Library authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func withIssueCapturing(
  _ body: () throws -> Void
) -> [Issue]

/// Invoke a function, capture and return any issues recorded during its
/// execution. Issues captured will not be sent to the rest of the testing
/// library.
///
/// - Parameters:
///   - body: The function to invoke.
///
/// Library authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func withIssueCapturing(
  _ body: sending @isolated(any) () async throws -> Void
) async -> [Issue]
```

Like `withIssueObservation`, `withIssueCapturing` observes and records any
issues which pass through it, at the point in the call stack where
`withIssueCapturing` is added. However, `withIssueCapturing` differs in that it
does not pass issues along to the rest of the testing library.

## Source compatibility

This changes how the existing `withKnownIssue` API is implemented. There is no
change in behavior of `withKnownIssue`. The additive changes to the public API
should not affect source compatibility of existing test code.

## Integration with supporting tools

Testing utilities can and should make use of `withIssueCapturing` and
`withIssueObservation` to both verify that test utilities record issues, as well
as to enable new tools to make use of and expand on the DSL provided by the
testing library. Otherwise, this proposal will not have any effect on existing
tools.

## Future directions

### More Test-Utility-Author specific APIs in `TestingUtilities`.

There are several other APIs in the testing library which are also candidates
to be made public in the `TestingUtilities` module. None of these APIs were
investigated as part of this proposal. Such APIs should be considered on their
own merits as part of separate proposals in order to prevent scope creep of
proposals.

### Allow general modification and analysis of Issues before they are recorded

In addition to capturing and observing issues, we could also allow for more
general modification and analysis of issues prior to recording. This would allow
test library authors to, for example, add, remove, or modify comments to all
issues recorded before they are sent to the rest of the testing library. There
are several ways we could handle this. This is excluded from this proposal in
the interest of avoiding scope creep and keeping the public API small.

### Local Traits

A potential other way to implement this behavior is to extend the trait system
to allow for temporary, or local, traits. Then, we could use a mechanism like
Issue Handling Traits to record and modify issues as they're recorded.

While local traits are a worthwhile area to investigate in the future, they were
considered to be beyond the scope of this proposal. The existing trait system
was not designed to work on units smaller than a `Test.Case`, and changing that
would invalidate several assumptions made about traits in the testing library.

In the future, Issue Capturing & Issue Observation could be implemented using
local traits. For the time being, they aren't. Even with a local trait system
in place, there is value in separate `withIssueCapturing(_:)` and
`withIssueObservation(_:)` APIs to wrap the Traits which ultimately implement
these: Providing the "returning recorded issues" behavior.

## Alternatives considered

### Not creating a separate module for testing utilities

The current methodology for gating APIs specifically for test utility authors is
to use the `ForToolsIntegrationOnly` SPI. Instead of creating a separate module,
Issue Capturing could have been added as a `ForToolsIntegrationOnly` API. Or,
it could have been made public without a gating SPI. Either approach would
obviate the need for a separate module.

On the whole, using SPIs is suboptimal as it means that the toolchain-provided
testing library cannot be used in tools that use SPI-gated APIs. This
discourages the use of such APIs as utility authors don't want to require users
to rebuild the testing library, nor do they wish to proliferate a dependency on
the non-toolchain testing library. Thus, to encourage that test utility authors
actually use Issue Capturing, it will not require an SPI.

However, while we do wish to encourage test utility authors to make use of Issue
Capturing, we also want to discourage test authors from making use of it. Issue
Capturing is the only API that can wholely prevent an issue from being reported
without any outside notice. In order to prevent accidental misuse of Issue
Capturing from resulting in valid and desired issues from being hidden, it
should require some amount of extra ceremony to be able to access. Which in this
case, is a separate module.

### Module Naming

Originally, this proposal called new `TestingUtilities` module `TestingTools`.
This name was dropped after a discussion to decide on what a "testing tool" is.
A testing tool is a separate program that interacts with and consumes the
Testing Library's JSON ABI or console output. XCode, the `swift test` CLI
command, and VSCode (with appropriate plug-ins) are testing tools. A testing
tool is not a library which builds upon APIs provided by the Testing Library.
For example, Nimble is not considered a testing tool. It is more accurate to
call Nimble a testing library, or a testing utility. Considering that Swift
Testing itself is also referred to as the Testing Library, we want to avoid
confusion and establish that libraries, frameworks, or packages that consume the
APIs provided by the Testing Library as part of APIs the
library/framework/package provides should be called testing utilities, and thus
the new module has been named `TestingUtilities`, as it provides APIs for these
utilities.

### Function Naming

Other names considered while developing this proposal include

- `captureIssues`/`observeIssues`
- `withExpectedIssue`

`captureIssues` and `observeIssues` were initially used in the early drafts of
this proposal, but were dropped in favor of the more idiomatic
`withIssueCapturing` and `withIssueObservation`.

`withExpectedIssue` was a suggestion from one of the testing workgroup members,
and was not used because of potential confusion with XCTest's
[`XCTExpectFailure(_:enabled:strict:issuematcher:)`](https://developer.apple.com/documentation/xctest/xctexpectfailure(_:enabled:strict:issuematcher:))
API. Additionally, `withExpectedIssue` implies that a separate issue should be
recorded if no issue was received, which is not a desired behavior of
`withIssueCapturing` and `withIssueObservation`. Neither `withIssueCapturing`
nor `withIssueObservation` should record an issue if no issue was received
during the execution of their respective `body` closures: they will instead
return an empty array.

### Remove `withIssueObservation`, make `Issue.record` instance method public

The testing workgroup discussed the idea of excluding `withIssueObservation`,
and instead making the `Issue.record()` instance method public. Some members
had concerns that `withIssueObservation` would not be used enough to justify
the ongoing maintenance burden of that function. Instead, for the rare case
where the `withIssueObservation` behavior was desired, test utility authors
could instead re-record any issues returned by `withIssueCapturing`. That is,
test utility authors could write:

```swift
let issues = withIssueCapturing {
    // ...
}
// process the issues
issues.forEach { $0.record() }
```

I do not think this is the correct approach, because while I do think that
`withIssueCapturing` will be used more often than `withIssueObservation`,
`withIssueObservation` has its place in test helpers that provide additional
context with the failed issues. For example, a test helper that records an
additional issue to provide context around why a series of issues were recorded.

Furthermore, making a public `Issue.record()` instance method requires further
consideration: Should there also be a public initializer for `Issue`? If not,
then a public `Issue.record()` would only exist for the purpose of re-recording
captured issues. Which should be answered as part of making a public
`Issue.record()` instance method.

### Combine `withIssueCapturing` and `withIssueObservation` into a single API

Semantically, `withIssueCapturing` and `withIssueObservation` both observe
recorded issues. As such, and especially with Nimble's prior art, it makes sense
for these to be the same function, with a parameter for whether observed issues
are also reported to the rest of the issue recording system.

However, the behavior of preventing issues from being reported to the rest of
the issue recording system is different enough to warrant separate functions.

Semantically, `withIssueObservation` only observes recorded issues and then
passes them along the issue recording chain. After being observed, issues
recorded are passed along the chain for other inspectors in to handle.

On the other hand, `withIssueCapturing` not only observes recorded issues, but
it does not pass them along the issue recording chain. Once an issue is captured
by a `withIssueCapturing` scope, it essentially ceases to exist.

These semantics are different enough that not only do they warrant separate
functions, but these also warranted entirely rethinking how the issue recording
system worked.

### Add a `matching` parameter to `withIssueCapturing` & `withIssueObservation`

Instead of returning all issues which pass through them, `withIssueCapturing`
and `withIssueObservation` should include a parameter to filter issues as they
come in. This matches the existing behavior of `withKnownIssue`, and
particularly for `withIssueCapturing`, allows unmatched issues to be sent to the
rest of the Testing Library.

No `matching` parameter is included with `withIssueCapturing` and
`withIssueObservation` specifically because they are intended to be used with in
test utilities and to validate test utilities. Two areas where authors want to
specifically operate on and, in the case of `withIssueCapturing`, block issues
from being recorded.

## Acknowledgments

This proposal came out of a suggestion that
[Brandon Williams](https://github.com/mbrandonw) had for the
[polling confirmations](https://github.com/younata/swift-evolution/blob/younata/testing-polling-expectations/proposals/testing/NNNN-polling-confirmations.md)
feature to make use of the issue reporting DSL to determine whether or not a
polling attempt had failed. Thanks to him for that suggestion which led to my
second proposal for Swift Testing.

This API is inspired by Nimble's
[`gatherExpectations`](https://github.com/Quick/Nimble/blob/main/Sources/Nimble/Adapters/AssertionRecorder.swift#L96-L125)
API. Thanks to [Jeff Hui](https://github.com/jeffh) for writing the original
implementation of Nimble's `gatherExpectations` API.
