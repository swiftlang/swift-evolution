# Issue Responder Chain, Issue Observation & the TestingTools module

* Proposal: [ST-NNNN](NNNN-issue-responder-chain.md)
* Authors: [Rachel Brindle](https://github.com/younata)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation:
  [swiftlang/swift-testing#1939](https://github.com/swiftlang/swift-testing/pull/1939)
* Review: ()

## Introduction

Test tool authors have additional needs for the tooling they write compared to
test authors. One such need is the ability to verify that a testing tool has
reported an issue. Adding this has driven out a new approach for handling issues
that will be significantly more flexible and friendly to test tool authors.

This proposal introduces a new TestingTools module with the testing library,
containing APIs specifically intended for test tool authors. The first APIs in
this new module API enable test authors to observe and verify that issues were
reported, as well as to otherwise control how issues are handled.

## Motivation

Test tool authors can currently make use of the
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

This proposal overhauls the issue reporting system to utilize a chain, where
each link in the chain is given the issue and they can act on it and optionally
pass it to the next link in the issue responder chain. The final link in the
issue responder chain is the eventing link, which creates an event for the issue
which will ultimately report the issue to the rest of the testing library and
observers of the event system.

Once an issue is sent through the eventing system, other systems take over.
Systems which act on issues after they have been sent through the eventing
system, such as 
[Issue Handling Traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0011-issue-handling-traits.md)
will be unaffected by this proposal.

This proposal converts the existing `withKnownIssue` behavior to be one of the
link types in the issue responder chain. `withKnownIssue` acts to transform
issues passed to it, marking them as known if they match the matcher given to
`withKnownIssue`, or any of the parent `withKnownIssue` contexts in the issue
reporting chain.

This proposal also introduces two entirely new links in the issue responder
chain: `observeIssues(_:sourceLocation:_:)` and
`captureIssues(_:sourceLocation:_:)`. These are test-author-only APIs which
record issues. They differ in that `observeIssues` will also pass the issue
along to the next link in the issue reporting chain, while `captureIssues` will
not pass the issue to the next link in the issue reporting chain.

Both `observeIssues` and `captureIssues` will be made available as the first
public APIs in the new `TestingTools` module within the testing library package.
`TestingTools` exists to define tooling specifically to help test tool authors
write and verify their libraries.

## Detailed design

### New TestingTools module

We will introduce a new module within the testing library, to provide the new
`captureIssues`, `observeIssues`, and `IssueResponder` APIs.

### New Issue Responder Chain & `IssueResponder` type

We will introduce a new protocol, `IssueResponder` to define a link in the new
Issue Responder Chain. We will convert the existing Issue Recording system to
make use of the Issue Responder Chain for any issues reported within a test.

```swift
/// A protocol for types in the Issue Responder Chain.
///
/// The types in the Issue Responder Chain receive and handle issues in the time
/// between where they are initially reported and before they are sent off to
/// the testing library's event system. Implementing an IssueResponder allows
/// you to observe, transform, or even block an issue from being sent up the
/// chain.
///
/// Use ``withIssueResponder(_:body:)`` (available in the TestingTools module)
/// to add your IssueResponder to the Issue Responder Chain.
public protocol IssueResponder: Sendable {
  /// Handle and respond to the given issue.
  ///
  /// - Parameters:
  ///   - issue: The issue to handle or respond to.
  /// - Returns: The issue to send to the next responder in the chain. This can
  ///   be the same issue that was sent, a transformed issue, or even nil, to
  ///   indicate that the Issue Responder Chain should stop processing the
  ///   issue.
  func respond(to issue: Issue) -> Issue?
}
```

`IssueResponder` will be made public in the `TestingTools` module. Test tool
authors may define their own `IssueResponder`s and add them to the Issue
Responder Chain utilizing the new `withIssueResponder` functions, also available in
the `TestingTools` module:

```swift
/// Add a new ``IssueResponder`` instance onto the current Issue Responder
/// Chain.
///
/// - Parameters:
///   - issueResponder: The ``IssueResponder`` to add onto the Issue Responder
///     Chain.
///   - body: The function to invoke with the issue responder added to the
///     chain.
///
/// - returns: Whatever is returned by `body`.
/// - throws: Whatever is thrown by `body`.
public func withIssueResponder<T>(
  _ issueResponder: any IssueResponder,
  body: () throws -> T
) rethrows -> T

/// Add a new ``IssueResponder`` instance onto the current Issue Responder
/// Chain.
///
/// - Parameters:
///   - issueResponder: The ``IssueResponder`` to add onto the Issue Responder
///     Chain.
///   - body: The function to invoke with the issue responder added to the
///     chain.
///
/// - returns: Whatever is returned by `body`.
/// - throws: Whatever is thrown by `body`.
public func withIssueResponder<T>(
  _ issueResponder: any IssueResponder,
  body: sending @isolated(any) () async throws -> sending T
) async rethrows -> sending T
```

### New `KnownIssueResponder` internal type

`withKnownIssue` will be converted to use a `KnownIssueResponder` type.
Following it's previous behavior, `KnownIssueResponder` will transform an issue
by marking it as known if it or any earlier `KnownIssueResponder` in the Issue
Responder Chain matches with it. If an issue does not match, then it will be
forwarded up the chain as-is. As with the current behavior, if no issues are
found to match and the `isIntermittent` parameter was set to false, then the
`KnownIssueResponder` will emit a separate issue to indicate the lack of any
issues. This will mark the semantics of `withKnownIssue` to fundamentally be
about transform an issue, specifically to mark that a failing test is correctly
failing, but the maintainers have deprioritized fixing the implementation to
comply with the test.

### New functions for observing issues

We will introduce 2 functions for observing issues, to be made available in
the new TestingTools module:

```swift
/// Invoke a function, and return any issues recorded during its execution.
/// Issues recorded will be sent to the next responder in the Issue Responder
/// Chain.
///
/// - Parameters:
///   - body: The function to invoke.
///
/// Library authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func observeIssues(
  _ body: () throws -> Void
) -> [Issue]

/// Invoke a function, and return any issues recorded during its execution.
/// Issues recorded will be sent to the next responder in the Issue Responder
/// Chain.
///
/// - Parameters:
///   - body: The function to invoke.
///
/// Library authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func observeIssues(
  _ body: sending @isolated(any) () async throws -> Void
) async -> [Issue]
```

`observeIssues` works to observe and record any issues which pass through it, at
the point in the chain where `observeIssues` is added, passing the issue along
to the next Issue Responder without making any changes to it. Semantically,
`observeIssues` is purely about observation.

### New functions for capturing issues

We will introduce 2 functions for capturing issues, to be made available in
the new TestingTools module:

```swift
/// Invoke a function, capture and return any issues recorded during its
/// execution. Issues captured will not be sent to the next responder in the
/// Issue Responder Chain.
///
/// - Parameters:
///   - body: The function to invoke.
///
/// Library authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func captureIssues(
  _ body: () throws -> Void
) -> [Issue]

/// Invoke a function, capture and return any issues recorded during its
/// execution. Issues captured will not be sent to the next responder in the
/// Issue Responder Chain.
///
/// - Parameters:
///   - body: The function to invoke.
///
/// Library authors use this function to capture and analyze any issues for
/// later analysis. This is particularly useful for verifying that test helpers
/// correctly record issues.
/// Test authors should consider using
/// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
func captureIssues(
  _ body: sending @isolated(any) () async throws -> Void
) async -> [Issue]
```

Like `observeIssues`, `captureIssues` observes and records any issues which pass
through it, at the point in the chain where `captureIssues` is added. However,
`captureIssues` differs in that it does not pass issues along to the next link
in the Issue Responder Chain. Semantically, this marks `captureIssues` as much
more of an issue handler 

These functions will both create new `CapturingIssueResponder` instances and add
them to the Issue Responder Chain. All issues recorded within the `body` closure
will be locally recorded and then not passed along to the next link in the Issue
Responder Chain.

## Source compatibility

This will change an existing, if very rarely encountered, behavior with the current
`withKnownIssue` API. Test authors would only have encountered this behavior if
they had multiple `withKnownIssue` scopes nested within each other and one of the
inner `withKnownIssue` scopes matches a reported issue. In which case
they will now no longer see a confusing "known issue not encountered" test error
emitted by the outer `withKnownIssue` scopes.

Otherwise, this is only making additive changes to the public API and should
not affect source compatibility of existing test code.

## Integration with supporting tools

Testing tools can and should make use of `captureIssues` and `observeIssues` to
both verify that test tools record issues, as well as to enable new tools to
make use of and expand on the DSL provided by the testing library. Otherwise,
this proposal will not have any effect on existing tools.

## Future directions

### More Test-Tool-Author specific tooling in `TestingTools`.

There are several other APIs in the testing library which are also candidates
to be made public in the `TestingTools` module. None of these APIs were
investigated as part of this proposal. Such APIs should be considered on their
own merits as part of separate proposals in order to prevent scope creep of
proposals.

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

However, while we do wish to encourage test tool authors to make use of Issue
Capturing, we also want to discourage test authors from making use of it. Issue
Capturing is the only API that can wholely prevent an issue from being reported
without any outside notice. In order to prevent accidental misuse of Issue
Capturing from resulting in valid and desired issues from being hidden, it
should require some amount of extra ceremony to be able to access. Which in this
case, is a separate module.

### Combine `captureIssues` and `observeIssues` into a single function

Semantically, `captureIssues` and `observeIssues` both observe recorded issues.
As such, and especially with Nimble's prior art, it makes sense for these to be
the same function, with a parameter for whether observed issues are also
reported to the rest of the issue recording system.

However, the behavior of preventing issues from being reported to the rest of
the issue recording system is different enough to warrant separate functions.

Semantically, `observeIssues` only observes recorded issues and then passes them
along the issue recording chain. After being observed, issues recorded are
passed along the chain for other inspectors in to handle.  

On the other hand, `captureIssues` not only observes recorded issues, but it
does not pass them along the issue recording chain. Once an issue is captured by
a `captureIssues` scope, it essentially ceases to exist.

These semantics are different enough that not only do they warrant separate
functions, but these also warranted entirely rethinking how the issue recording
system worked.

### Add a `matching` parameter to `captureIssues` and `observeIssues`

Instead of returning all issues which pass through them, `captureIssues` and
`observeIssues` should include a parameter to filter issues as they come in.
This matches the existing behavior of `withKnownIssue`, and particularly for
`captureIssues`, allows captured issues to go to the next value in the Issue
Responder Chain.

No `matching` parameter is included with `captureIssues` and `observeIssues`
specifically because they return the observed issues in an array. Test tool
authors can filter on issues after the fact if they so wish. For `captureIssues`
specifically, test authors can choose to re-emit issues by calling the
`record()` method on them after that `captureIssues` call is no longer in the
Issue Responder Chain. I view this as a rare-enough need that this approach is
acceptable.

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
