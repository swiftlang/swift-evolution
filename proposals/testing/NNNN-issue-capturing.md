# Issue Capturing & the TestingUtilities module

* Proposal: [ST-NNNN](NNNN-issue-capturing.md)
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
`withKnownIssue` is meant for tests that are not working correctly which the
test author has deprioritized fixing. There is no API for indicating that the
issues recorded inside are expected issues as part of the test or tool working
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

This proposal introduces an entirely set of new APIs to observe and capture
issues before they are reported to the rest of the testing library:
`withIssueCapturing(_:)` and `withExpectedIssue(_:matching:)`. Additionally,
this proposal introduces a new instance method on Issue which re-emits any
captured issues: `Issue.record()`.

These APIs will be made available as the first public APIs in the new
`TestingUtilities` module within the testing library package. `TestingUtilities`
exists to define tooling specifically to help test utility authors write and
verify their libraries.

## Detailed design

### New TestingUtilities module

We will introduce a new module within the testing library, to provide the new
`withIssueCapturing`, `withExpectedIssue`, and `Issue.record` APIs.

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

`withIssueCapturing` records all issues which pass through it, at the
point in the call stack where `withIssueCapturing` is added. Additionally,
`withIssueCapturing` does not pass issues along to the rest of the testing
library.

Captured issues are particularly useful for utilizing the expectation DSL
(`#expect` and `#require`) in other ways to express behavior. For example,
`withExpectedIssue` utilizes the expectation DSL to express the issue matchers.

### New functions for expected issues

We will introduce 2 functions for expected issues, to be made available in
the new TestingUtilities module:

```swift
/// Invoke a function that is expected to record at least one issue during its
/// execution. Expected issues will not be sent to the rest of the testing
/// library.
///
/// - Parameters:
///   - body: The function to invoke.
///   - issueMatcher: A function to invoke when an issue occurs that is used to
///     determine if the issue is expected, utilizing `#expect` and `#require`
///     to indicate that the issue is expected.
///   - additionalMatchers: Additional matcher functions, which are used to
///     indicate multiple issues are expected.
///
/// Library authors use this function to validate that code correctly records
/// the expected issues. For every expected issue, there must be an equivalent
/// matcher closure that captures that issue. Matcher closures may be evaluated
/// multiple times, and the Testing Library will attempt to match recorded
/// issues to the most appropriate matcher.
///
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func withExpectedIssue(
  _ body: () throws -> Void
  matching issueMatcher: @escaping @Sendable (Issue) throws -> Void,
  _ additionalMatchers: @Sendable (Issue) throws -> Void...
)

/// Invoke a function that is expected to record at least one issue during its
/// execution. Expected issues will not be sent to the rest of the testing
/// library.
///
/// - Parameters:
///   - body: The function to invoke.
///   - issueMatcher: A function to invoke when an issue occurs that is used to
///     determine if the issue is expected, utilizing `#expect` and `#require`
///     to indicate that the issue is expected.
///   - additionalMatchers: Additional matcher functions, which are used to
///     indicate multiple issues are expected.
///
/// Library authors use this function to validate that code correctly records
/// the expected issues. For every expected issue, there must be an equivalent
/// matcher closure that captures that issue. Matcher closures may be evaluated
/// multiple times, and the Testing Library will attempt to match recorded
/// issues to the most appropriate matcher.
///
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func withExpectedIssue(
  _ body: () async throws -> Void
  matching issueMatcher: @escaping @Sendable (Issue) throws -> Void,
  _ additionalMatchers: @Sendable (Issue) throws -> Void...
) async
```

`withExpectedIssue` is intended to be used to validate codepaths which
intentionally emits issues work as expected. It makes use of the Expectation DSL
for issue matchers, which makes it easier to reason about what exactly a given
matcher expects:

```swift
withExpectedIssue {
    Issue.record("my custom issue")
} matching: { #expect($0.comments == ["my custom issue"] }
```

Issues which do not match a given matcher will be sent to the rest of the
testing library. Additionally, an issue will be recorded if there are
unmatched issue matchers.

### Public API for re-emitting recording issues

We will introduce a new instance method on `Issue` specifically for re-emitting
captured issues:

```swift
extension Issue {
  /// Record this issue to the testing Library.
  ///
  /// - Returns: The issue that was recorded (`self` or a modified copy of it.)
  @discardableResult
  func record() -> Self
}
```

The `Issue.record` instance method will be a part of the TestingUtilities module
specifically because it is intended to be used only with `withIssueCapturing`.

## Source compatibility

This is an additive change to the public API and should not affect source
compatibility of existing test code.

## Integration with supporting tools

This proposal will not have any effect on existing tools which make use of the 
ABI of the Testing Library.

## Future directions

### More Test-Utility-Author specific APIs in `TestingUtilities`.

There are several other APIs in the testing library which are also candidates
to be made public in the `TestingUtilities` module. None of these APIs were
investigated as part of this proposal. Such APIs should be considered on their
own merits as part of separate proposals in order to prevent scope creep of
proposals.

### General modification and analysis of Issues before they are recorded

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
in place, there is value in separate `withIssueCapturing` APIs to wrap the
Traits which ultimately implement these, by returning the captured issues.

### Event Capturing

Issues are only one part of the Event subsystem of the Testing Library. In
addition to capturing Issues specifically, we could also add APIs to capture
Events generically. This is not included here because the Event type is not
currently a stable API. Additionally, capturing other events would be a large
expansion of scope, but even with that, capturing issues is useful enough that
it should have a dedicated API for specifically gathering issues.

### Extend `withKnownIssue` to use the Expectation DSL

A next obvious step is to extend `withKnownIssue` to make use of the Expectation
DSL similar to `withExpectedIssue`. The question to answer beforehand is whether
`withKnownIssue` should keep `withExpectedIssue`'s 1-issue-per-matcher
requirement, or whether it should keep the single matcher approach it currently
employs. Additionally, extending `withKnownIssue` felt out of place with the
rest of this proposal, which deals with APIs added to the new `TestingUtilities`
module.

### Additional functions using the expectation DSL

With the ability to capture and examine reported issues comes the ability to
improve how common assertions are written. For example, when validating if at
least one element in a sequence matches a value, it's common to write:

```swift
#expect(mySequence.contains { $0 == expectedValue })
```

or, if you only want to check parts of a value, test authors might write:

```swift
#expect(mySequence.contains { value in
  value.property1 == expectedProperty1 && value.property2 == expectedProperty2
})
```

These are fine, but hard to debug when something doesn't match. Additionally,
the more boolean logic used, the harder it is to determine which part of the
boolean logic failed.

A future proposal would specify something like `Sequence.expectContains` method,
which would use the expectation DSL itself to determine whether a sequence
contains a value:

```swift
mySequence.expectContains { value in
  #expect(value == expectedValue)
}

mySequence.expectContains { value in
  #expect(value.property1 == expectedProperty1)
  #expect(value.property2 == expectedProperty2)
}
```

This would significantly improve the readability and reliability of tests. These
will allow the test to have much finer data about what the test author expects,
and thus will allow the Testing Library to present much finer data when the
expectation fails, allowing the test author to more quickly determine why the
test failed.

These are not included here because while they definitely build upon this
proposal, they are much more separate from this proposal and should be
considered on their own merits.

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

### Use a custom availability domain instead of a new module

Instead of creating a separate module for these new APIs, the Testing Library
could define a new custom availability domain specific for Testing Utilities.
This was not chosen because custom availability are still new enough and, if
anything, make the experience of using APIs that would go into
`TestingUtilities` worse: instead of adding `import TestingUtilities`,
everywhere that uses these APIs would need to do an availability check for the
custom availability domain.

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

- `captureIssues`
- `withExpectedIssue`

`captureIssues` was initially used in the early drafts of this proposal, but
was dropped in favor of the more idiomatic `withIssueCapturing`.

### Use Bool-returning closures for matchers in `withExpectedIssue`

Instead of making use of the expectation DSL, `withExpectedIssue` could instead
determine whether an issue matches based on whether the matcher closure returns
true or false. The reason to change this standard practice is to make it easier
for users to debug why an expected issues matched or did not match. Unmatched
issues will have all of the expectations they failed in matchers included when
they are recorded. Which will provide more detail for users, and reduce the
headache of debugging unmatched issues.

### Allow a single matcher to match against multiple issues

Similar to using bool-returning closures for matchers, `withExpectedIssue` could
instead follow the traditional paradigm, and use a single matcher.
`withExpectedIssue` uses one matcher per issue in part as a mechanism to
mitigate abuse and misuse, but more importantly to aid with debugging. Instead
of forcing test authors to debug potentially complex boolean logic to capture
different issues, they can use multiple expectations within a matcher as a form
of AND, alongside multiple separate matchers as an OR. This dramatically reduces
the cognitive overhead for reasoning about why an issue did not match.

As mentioned earlier, mitigating abuse is also a strong reason why
`withExpectedIssue` requires a matcher for every expected issue. We want to
avoid the situation where
`withExpectedIssue { /* problematic code */ } matching: { _ in }` is used
to paper over problematic tests. Realistically, there is no way to entirely
prevent people who want to ignore issues from doing so, but we can make it
glaringly obvious when they are doing so.

One concern brought up with requiring 1 matcher per issue is when validating
code that is expected to emit an unknown amount of issues. I think that
`withIssueCapturing` offers an appropriate workaround, by explicitly handing
off issue handling to the caller.

### Make the `Issue.record` instance method part of the Testing Library

This proposal adds a public `Issue.record()` instance method to the
TestingUtilities module. This method could instead be a part of the Testing
Library. The reason that the `Issue.record()` instance method is part of the
TestingUtilities module is because the only way to get an `Issue` instance is
via `withIssueCapturing`. It doesn't make sense to add a method to the Testing
Library that can only be used if you use an API provided in the TestingUtilities
library.

### Include API for automatically re-emiting captured issues

An earlier revision of this proposal specified a `withIssueObservation` API
which automatically re-emited captured issues. Some members of the testing
workgroup had concerns that this observation API would not be used enough to
justify the ongoing maintenance burden of that API. Those concerns, combined
with the fact that `withIssueObservation` can be implemented by client authors
by combining the `withIssueCapturing` API with the `Issue.record()` instance
method, are why `withIssueObservation` was removed from consideration.

```swift
func withIssueObservation(_ body: () throws -> Void) -> [Issue] {
  withIssueCapturing(body).map { $0.record() }
}
```

There are instances for this `withIssueObservation` API, such as test helpers
which records additional issues providing context around why a series of issues
were recorded. As such, `withIssueObservation` may be considered in a future,
separate proposal.

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
