# Issue Capturing & the TestingTools module

* Proposal: [ST-NNNN](NNNN-issue-capturing.md)
* Authors: [Rachel Brindle](https://github.com/younata)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TBD
* Review: ()

## Introduction

Test tool authors have additional needs for the tooling they write compared to
test authors. One such need is the ability to verify that a testing tool has
reported an issue.

This proposal introduces a new TestingTools module with the testing library,
containing APIs specifically intended for test tool authors. The first APIs in
this new module  API to enable test authors to not only verify that issues were
reported, but to also be able to inspect them after the fact.

## Motivation

Test tool authors can currently make use of the
[`withKnownIssue`](https://swiftpackageindex.com/swiftlang/swift-testing/main/documentation/testing/known-issues)
family of functions in order to verify that an issue was reported.
Unfortunately, the semantics of `withKnownIssue` imply that any issue recorded
inside of `withKnownIssue` is something to be fixed, instead of the expected
result that most test tool authors use it for.

For example, in [Nimble's](https://github.com/quick/Nimble) integration with
Swift Testing, the
[tests for the integration](https://github.com/Quick/Nimble/blob/main/Tests/NimbleTests/SwiftTestingSupportTest.swift)
utilize `withKnownIssue` in a semantically-incorrect way to validate that a
failing Nimble expectation is correctly reported to Swift Testing's issue
reporting system. Practically this results in extraneous and unnecessary console
output and UI when Nimble's
`SwiftTestingSupportSuite.reportsAssertionFailuresToSwiftTesting` test runs,
which can be confusing to someone who doesn't already expect this.

Ideally, the maintainers of Nimble and other testing tools who would wish to
write tests against their testing tools would have an API that doesn't imply
that their correctly-behaving tool doesn't have an issue with it.

Furthermore, adding the ability to record reported issues and act on them opens
up an additional avenue for making use of the Testing DSL. For example, the
[Polling Confirmations](https://github.com/younata/swift-evolution/blob/younata/testing-polling-expectations/proposals/testing/NNNN-polling-confirmations.md)
pitch makes use of recording issues in order to indicate whether a polling
attempt has succeeded or failed.

The testing workgroup feels that there needs to be some space for APIs intended
for test tool authors which is separate from APIs intended for test authors.
As noted earlier, test tool authors often have need for additional need for
APIs that the vast majority of test authors do not need. Rather than clutter the
API surface of the main Testing module and potentially confuse test authors, we
instead will create a separate module within the Testing package to contain
these APIs intended solely for test tool authors.

## Proposed solution

This proposal introduces a new module within the testing library package:
`TestingTools`. `TestingTools` defines tooling specifically to help test tool
authors write and verify their libraries.

The first APIs in `TestingTools` will be the
`captureIssues(_:silently:sourceLocation:_:matching:)` and
`captureIssues(_:silently:isolation:sourceLocation:_:matching:)` functions.
These functions take in a closure to be run, and, by default, record without
reporting any issues emitted within the closure.

For both of these functions, whethere or not captured issues are also reported
as failing is controlled by the `silently` argument: When `true`,
captured issues will not be reported as failing. When `false` (the default),
they will be. `false` is the default in order to minimize that chance of
silently dropping valid issues in the event of incorrect usage of
`captureIssues`.

## Detailed design

### New TestingTools module

We will introduce a new module within the testing library.

### New functions for capturing issues

We will introduce 2 functions as the first public APIs to this new library:

```swift
/// Invoke a function, and return any issues recorded during its execution.
///
/// - Parameters:
///   - comment: An optional comment describing the context around this issue.
///   - silently: If true, captured issues will not be immediately reported to
///     the testing library. This means that callers must manually report issues
///     after the fact in order for them to be recorded. The default value is
///     false: All captured issues will also be reported to the testing library.
///   - sourceLocation: The source location to which any recorded issues should
///     be attributed.
///   - body: The function to invoke.
///   - issueMatcher: A function to invoke when an issue occurs that is used to
///     determine if the issue should be captured. By default, all issues match.
///
/// - Throws: Whatever is thrown by `body`, unless it is matched by
///   `issueMatcher`.
///
/// Test tool authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
///
/// - Note: `issueMatcher` may be invoked more than once for the same issue.
public func captureIssues(
  _ comment: Comment? = nil,
  silently: Bool = false,
  sourceLocation: SourceLocation = #Testing::sourceLocation,
  _ body: () throws -> Void,
  matching issueMatcher: @escaping KnownIssueMatcher = { _ in true }
) rethrows -> [Issue]

/// Invoke a function, and return any issues recorded during its execution.
///
/// - Parameters:
///   - comment: An optional comment describing the context around this issue.
///   - silently: If true, captured issues will not be immediately reported to
///     the testing library. This means that callers must manually report issues
///     after the fact in order for them to be recorded. The default value is
///     false: All captured issues will also be reported to the testing library.
///   - sourceLocation: The source location to which any recorded issues should
///     be attributed.
///   - body: The function to invoke.
///   - issueMatcher: A function to invoke when an issue occurs that is used to
///     determine if the issue should be captured. By default, all issues match.
///
/// - Throws: Whatever is thrown by `body`, unless it is matched by
///   `issueMatcher`.
///
/// Test tool authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
///
/// - Note: `issueMatcher` may be invoked more than once for the same issue.
public func captureIssues(
  _ comment: Comment? = nil,
  silently: Bool = false,
  isolation: isolated (any Actor)? = #isolation,
  sourceLocation: SourceLocation = #Testing::sourceLocation,
  _ body: () async throws -> Void,
  matching issueMatcher: @escaping KnownIssueMatcher = { _ in true }
) async rethrows -> [Issue]
```

## Source compatibility

These are new APIs and a brand new Module that is unlikely to collide with any
existing client-provided interfaces. The typical Swift disambiguation tools can
be used if needed.

## Integration with supporting tools

Testing tools can and should make use of `captureIssues` to both verify that
test tools record issues, as well as to enable new tools to make use of and
expand on the DSL provided by the testing library. Otherwise, this proposal will
not have any effect on existing tools.

## Future directions

### Move `ForToolsIntegrationOnly` SPI-gated APIs to `TestingTools`.

Potentially, any API in the testing library currently gated by the 
`ForToolsIntegrationOnly` SPI is a candidate to be moved into the `TestingTools`
module. None of those APIs are investigated as part of this proposal. Such 
APIs should be considered on their own merits as part of separate proposals in
order to prevent scope creep of proposals.

## Alternatives considered

### Not creating a separate module for testing tools

The current methodology for gating APIs specifically for testing tool authors is
to use the `ForToolsIntegrationOnly` SPI. Instead of creating a separate module,
Issue Capturing could have been added as a `ForToolsIntegrationOnly` API. Or,
it could have been made public without a gating SPI. Either approach would
obviate the need for a separate module.

On the whole, using SPIs is suboptimal as it means that the toolchain-provided
testing library cannot be used in tools that use SPI-gated APIs. This
discourages the use of such APIs as tool authors don't want to require users
to rebuild the testing library, nor do they wish to proliferate a dependency on
the non-toolchain testing library. Thus, to encourage that test tool authors
actually use Issue Capturing, it will not require an SPI.

However, while I do wish to encourage test tool authors to make use of Issue
Capturing, we also want to discourage test authors from making use of it. Issue
Capturing is one of the few APIs that can wholely prevent an issue from being
reported without any outside notice. In order to prevent accidental misuse of
Issue Capturing from resulting in valid and desired issues from being hidden,
it should require some amount of extra ceremony to be able to access. Which
in this case, is a separate module.

### `captureIssues`'s `silently` parameter should default to `true`

I expect most users of `captureIssues` to use it to validate that their testing
tool correctly reports issues. In which case, they will call it with `silently`
set to `true`.

The reason to keep the default value of `silently` as true is the same as
providing Issue Capturing under a separate module: To prevent accidental misuse
of Issue Capturing from hiding potential bugs in test author's source code.

### `captureIssues` shouldn't have the `silently` parameter

The majority of users of `captureIssues` will be calling `silently` with
`true`, the few who don't can easily call `issues.forEach { $0.report() }`
on the array of issues returned by `captureIssues`.

The `silently` parameter exists for two reasons:

1. To cater to and enable those who wish to make use of the testing library's
   issue DSL while also reporting those same issues.
2. To make it more difficult to accidentally misuse `captureIssues`.

While most usage of `captureIssues` will likely be for verifying that a testing
tool captures issues, we want to acknowledge and cater to the audience creating
tools that expand on the testing library's DSL.

## Acknowledgments

This proposal came out of a suggestion that
[Brandon Williams](https://github.com/mbrandonw) had for the
[polling confirmations](https://github.com/younata/swift-evolution/blob/younata/testing-polling-expectations/proposals/testing/NNNN-polling-confirmations.md)
feature to make use of the issue reporting DSL to determine whether or not a
polling attempt had failed. Thanks to him for that suggestion which led to my
second proposal for Swift Testing.

This API is inspired by Nimble's
[`gatherExpectations`](https://github.com/Quick/Nimble/blob/main/Sources/Nimble/Adapters/AssertionRecorder.swift#L96-L125)
API, including the desire
for the `silently` parameter to default to `false`. Thanks to
[Jeff Hui](https://github.com/jeffh) for writing the original implementation of
Nimble's `gatherExpectations` API.
