# Issue Handling Traits

* Proposal: [ST-0011](0011-issue-handling-traits.md)
* Authors: [Stuart Montgomery](https://github.com/stmontgomery)
* Review Manager: [Paul LeMarquand](https://github.com/plemarquand)
* Status: **Active Review (Jun 24 - July 8, 2025)**
* Implementation: [swiftlang/swift-testing#1080](https://github.com/swiftlang/swift-testing/pull/1080),
  [swiftlang/swift-testing#1121](https://github.com/swiftlang/swift-testing/pull/1121),
  [swiftlang/swift-testing#1136](https://github.com/swiftlang/swift-testing/pull/1136),
  [swiftlang/swift-testing#1198](https://github.com/swiftlang/swift-testing/pull/1198)
* Review: ([pitch](https://forums.swift.org/t/pitch-issue-handling-traits/80019)) ([review](https://forums.swift.org/t/st-0011-issue-handling-traits/80644))

## Introduction

This proposal introduces a built-in trait for handling issues in Swift Testing,
enabling test authors to customize how expectation failures and other issues
recorded by tests are represented. Using a custom issue handler, developers can
transform issue details, perform additional actions, or suppress certain issues.

## Motivation

Swift Testing offers ways to customize test attributes and perform custom logic
using traits, but there's currently no way to customize how issues (such as
`#expect` failures) are handled when they occur during testing.

The ability to handle issues using custom logic would enable test authors to
modify, supplement, or filter issues based on their specific requirements before
the testing library processes them. This capability could open the door to more
flexible testing approaches, improve integration with external reporting systems,
or improve the clarity of results in complex testing scenarios. The sections
below discuss several potential use cases for this functionality.

### Adding information to issues

#### Comments

Sometimes test authors want to include context-specific information to certain
types of failures. For example, they might want to automatically add links to
documentation for specific categories of test failures, or include supplemental
information about the history of a particular expectation in case it fails. An
issue handler could intercept issues after they're recorded and add these
details to the issue's comments before the testing library processes them.

#### Attachments

Test failures often benefit from additional diagnostic data beyond the basic
issue description. Swift Testing now supports attachments (as of
[ST-0009](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0009-attachments.md)),
and the ability to add an attachment to an indiviual issue was mentioned as a
future direction in that proposal. The general capability of adding attachments
to issues is outside the scope of this proposal, but if such a capability were
introduced, an issue handler could programmatically attach log files,
screenshots, or other diagnostic artifacts when specific issues occur, making it
easier to diagnose test failures.

### Suppressing warnings

Recently, a new API was [pitched][severity-proposal] which would introduce the
concept of severity to issues, along with a new _warning_ severity level, making
it possible to record warnings that do not cause a test to be marked as a
failure. If that feature is accepted, there may be cases where a test author
wants to suppress certain warnings entirely or in specific contexts.

For instance, they might choose to suppress warnings recorded by the testing
library indicating that two or more arguments to a parameterized test appear
identical, or for one of the other scenarios listed as potential use cases for
warning issues in that proposal. An issue handler would provide a mechanism to
filter issues.

### Raising or lowering an issue's severity

Beyond suppressing issues altogether, a test author might want to modify the
severity of an issue (again, assuming the recently pitched
[Issue Severity][severity-proposal] proposal is accepted). They might wish to
either _lower_ an issue with the default error-level severity to a warning (but
not suppress it), or conversely _raise_ a warning issue to an error.

The Swift compiler now allows control over warning diagnostics (as of
[SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md)).
An issue handling trait would offer analogous functionality for test issues.

### Normalizing issue details

Tests that involve randomized or non-deterministic inputs can generate different
issue descriptions on each run, making it difficult to identify duplicates or
recognize patterns in failures. For example, a test verifying random number
generation might produce an expectation failure with different random values
each time:

```
Expectation failed: (randomValue → 0.8234) > 0.5
Expectation failed: (randomValue → 0.6521) > 0.5
```

An issue handler could normalize these issues to create a more consistent
representation:

```
Expectation failed: (randomValue → 0.NNNN) > 0.5
```

The original numeric value could be preserved via a comment after being
obfuscated—see [Comments](#comments) under [Adding information to issues](#adding-information-to-issues)
above.

> [!NOTE]
> This example involves an expectation failure. The value of the `kind` property
> for such an issue would be `.expectationFailed(_:)` and it would have an
> associated value of type `Expectation`. To transform the issue in the way
> described above would require modifying details of the associated `Expectation`
> and its substructure, but these details are currently SPI so test authors
> cannot modify them directly.
>
> Exposing these details is out of scope for this proposal, but a test author
> could still transform this issue to achieve a similar result by changing the
> issue's kind from `.expectationFailed(_:)` to `.unconditional`. This
> experience could be improved in the future in subsequent proposals if desired.

This normalization can significantly improve the ability to triage failures, as
it becomes easier to recognize when multiple test failures have the same root
cause despite different specific values.

## Proposed solution

This proposal introduces a new trait type that can customize how issues are
processed during test execution.

Here's one contrived example showing how this could be used to add a comment to
each issue recorded by a test:

```swift
@Test(.compactMapIssues { issue in
  var issue = issue
  issue.comments.append("Checking whether two literals are equal")
  return issue
})
func literalComparisons() {
  #expect(1 == 1)     // ✅
  #expect(2 == 3)     // ❌ Will invoke issue handler
  #expect("a" == "b") // ❌ Will invoke issue handler again
}
```

Here's an example showing how warning issues matching a specific criteria could
be suppressed using `.filterIssues`. It also showcases a technique for reusing
an issue handler across multiple tests, by defining it as a computed property in
an extension on `Trait`:

```swift
extension Trait where Self == IssueHandlingTrait {
  static var ignoreSensitiveWarnings: Self {
    .filterIssues { issue in
      let description = String(describing: issue)

      // Note: 'Issue.severity' has been pitched but not accepted.
      return issue.severity <= .warning && SensitiveTerms.all.contains { description.contains($0) }
    }
  }
}

@Test(.ignoreSensitiveWarnings) func exampleA() {
  ...
}

@Test(.ignoreSensitiveWarnings) func exampleB() {
  ...
}
```

The sections below discuss some of the proposed new trait's behavioral details.

### Precedence order of handlers

If multiple issue handling traits are applied to or inherited by a test, they
are executed in trailing-to-leading, innermost-to-outermost order. For example,
given the following code:

```swift
@Suite(.compactMapIssues { ... /* A */ })
struct ExampleSuite {
  @Test(.filterIssues { ... /* B */ },
        .compactMapIssues { ... /* C */ })
  func example() {
    ...
  }
}
```

If an issue is recorded in `example()`, it's processed first by closure C, then
by B, and finally by A. (Unless an issue is suppressed, in which case it will
not advance to any subsequent handler's closure.) This ordering provides
predictable behavior and allows more specific handlers to process issues before
more general ones.

### Accessing task-local context from handlers

The closure of an issue handler is invoked synchronously at the point where an
issue is recorded. This means the closure can access task local state from that
context, and potentially use that to augment issues with extra information.
Here's an example:

```swift
// In module under test:
actor Session {
  @TaskLocal static var current: Session?

  let id: String
  func connect() { ... }
  var isConnected: Bool { ... }
  ...
}

// In test code:
@Test(.compactMapIssues { issue in
  var issue = issue
  if let session = Session.current {
    issue.comments.append("Current session ID: \(session.id)")
  }
  return issue
})
func example() async {
  let session = Session(id: "ABCDEF")
  await Session.$current.withValue(session) {
    await session.connect()
    #expect(await session.isConnected) // ❌ Expectation failed: await session.isConnected
                                       //    Current session ID: ABCDEF
  }
}
```

### Recording issues from handlers

Issue handling traits can record additional issues during their execution. These
newly recorded issues will be processed by any later issue handling traits in
the processing chain (see [Precedence order of handlers](#precedence-order-of-handlers)).
This capability allows handlers to augment or provide context to existing issues
by recording related information.

For example:

```swift
@Test(
  .compactMapIssues { issue in
    // This closure will be called for any issue recorded by the test function
    // or by the `.filterIssues` trait below.
    ...
  },
  .filterIssues { issue in
    guard let terms = SensitiveTerms.all else {
      Issue.record("Cannot determine the set of sensitive terms. Filtering issue by default.")
      return true
    }

    let description = String(describing: issue).lowercased()
    return terms.contains { description.contains($0) }
  }
)
func example() {
  ...
}
```

### Handling issues from other traits

Issue handling traits process all issues recorded in the context of a test,
including those generated by other traits applied to the test. For instance, if
a test uses the `.enabled(if:)` trait and the condition closure throws an error,
that error will be recorded as an issue, the test will be skipped, and the issue
will be passed to any issue handling traits for processing.

This comprehensive approach ensures that all issues related to a test,
regardless of their source, are subject to the same customized handling. It
provides a unified mechanism for issue processing that works consistently across
the testing library.

### Effects in issue handler closures

The closure of an issue handling trait must be:

- <a id="non-async"></a>**Non-`async`**: This reflects the fact that events in
  Swift Testing are posted synchronously, which is a fundamental design decision
  that, among other things, avoids the need for `await` before every `#expect`.

  While this means that issue handlers cannot directly perform asynchronous work
  when processing an individual issue, future enhancements could offer
  alternative mechanisms for asynchronous issue processing work at the end of a
  test. See the [Future directions](#future-directions) section for more
  discussion about this.

- <a id="non-throws"></a>**Non-`throws`**: Since these handlers are already
  being called in response to a failure (the recorded issue), allowing them to
  throw errors would introduce ambiguity about how such errors should be
  interpreted and reported.

  If an issue handler encounters an error, it can either:

  - Return a modified issue that includes information about the problem, or
  - Record a separate issue using the standard issue recording mechanisms (as
    [discussed](#recording-issues-from-handlers) above).

### Handling of non-user issues

Issue handling traits are applied to a test by a user, and are only intended for
handling issues recorded by tests written by the user. If an issue is recorded
by the testing library itself or the underlying system, not due to a failure
within the tests being run, such an issue will not be passed to an issue
handling trait. Similarly, an issue handling trait should not return an issue
which represents a problem they could not have caused in their test.

Concretely, this policy means that issues for which the value of the `kind`
property is `.system` will not be passed to the closure of an issue handling
trait. Also, it is not supported for a closure passed to
`compactMapIssues(_:)` to return an issue for which the value of `kind` is
either `.system` or `.apiMisused` (unless the passed-in issue had that kind,
which should only be possible for `.apiMisused`).

## Detailed design

This proposal includes the following:

* A new `IssueHandlingTrait` type that conforms to `TestTrait` and `SuiteTrait`.
  * An instance method `handleIssue(_:)` which can be called directly on a
    handler trait. This may be useful for composing multiple issue handling
    traits.
* Static functions on `Trait` for creating instances of this type with the
  following capabilities:
  * A function `compactMapIssues(_:)` which returns a trait that can transform
    recorded issues. The function takes a closure which is passed an issue and
    returns either a modified issue or `nil` to suppress it.
  * A function `filterIssues(_:)` which returns a trait that can filter recorded
    issues. The function takes a predicate closure that returns a boolean
    indicating whether to keep (`true`) or suppress (`false`) an issue.

Below are the proposed interfaces:

```swift
/// A type that allows transforming or filtering the issues recorded by a test.
///
/// Use this type to observe or customize the issue(s) recorded by the test this
/// trait is applied to. You can transform a recorded issue by copying it,
/// modifying one or more of its properties, and returning the copy. You can
/// observe recorded issues by returning them unmodified. Or you can suppress an
/// issue by either filtering it using ``Trait/filterIssues(_:)`` or returning
/// `nil` from the closure passed to ``Trait/compactMapIssues(_:)``.
///
/// When an instance of this trait is applied to a suite, it is recursively
/// inherited by all child suites and tests.
///
/// To add this trait to a test, use one of the following functions:
///
/// - ``Trait/compactMapIssues(_:)``
/// - ``Trait/filterIssues(_:)``
public struct IssueHandlingTrait: TestTrait, SuiteTrait {
  /// Handle a specified issue.
  ///
  /// - Parameters:
  ///   - issue: The issue to handle.
  ///
  /// - Returns: An issue to replace `issue`, or else `nil` if the issue should
  ///   not be recorded.
  public func handleIssue(_ issue: Issue) -> Issue?
}

extension Trait where Self == IssueHandlingTrait {
  /// Constructs an trait that transforms issues recorded by a test.
  ///
  /// - Parameters:
  ///   - transform: A closure called for each issue recorded by the test
  ///     this trait is applied to. It is passed a recorded issue, and returns
  ///     an optional issue to replace the passed-in one.
  ///
  /// - Returns: An instance of ``IssueHandlingTrait`` that transforms issues.
  ///
  /// The `transform` closure is called synchronously each time an issue is
  /// recorded by the test this trait is applied to. The closure is passed the
  /// recorded issue, and if it returns a non-`nil` value, that will be recorded
  /// instead of the original. Otherwise, if the closure returns `nil`, the
  /// issue is suppressed and will not be included in the results.
  ///
  /// The `transform` closure may be called more than once if the test records
  /// multiple issues. If more than one instance of this trait is applied to a
  /// test (including via inheritance from a containing suite), the `transform`
  /// closure for each instance will be called in right-to-left, innermost-to-
  /// outermost order, unless `nil` is returned, which will skip invoking the
  /// remaining traits' closures.
  ///
  /// Within `transform`, you may access the current test or test case (if any)
  /// using ``Test/current`` ``Test/Case/current``, respectively. You may also
  /// record new issues, although they will only be handled by issue handling
  /// traits which precede this trait or were inherited from a containing suite.
  ///
  /// - Note: `transform` will never be passed an issue for which the value of
  ///   ``Issue/kind`` is ``Issue/Kind/system``, and may not return such an
  ///   issue.
  public static func compactMapIssues(_ transform: @escaping @Sendable (Issue) -> Issue?) -> Self

  /// Constructs a trait that filters issues recorded by a test.
  ///
  /// - Parameters:
  ///   - isIncluded: The predicate with which to filter issues recorded by the
  ///     test this trait is applied to. It is passed a recorded issue, and
  ///     should return `true` if the issue should be included, or `false` if it
  ///     should be suppressed.
  ///
  /// - Returns: An instance of ``IssueHandlingTrait`` that filters issues.
  ///
  /// The `isIncluded` closure is called synchronously each time an issue is
  /// recorded by the test this trait is applied to. The closure is passed the
  /// recorded issue, and if it returns `true`, the issue will be preserved in
  /// the test results. Otherwise, if the closure returns `false`, the issue
  /// will not be included in the test results.
  ///
  /// The `isIncluded` closure may be called more than once if the test records
  /// multiple issues. If more than one instance of this trait is applied to a
  /// test (including via inheritance from a containing suite), the `isIncluded`
  /// closure for each instance will be called in right-to-left, innermost-to-
  /// outermost order, unless `false` is returned, which will skip invoking the
  /// remaining traits' closures.
  ///
  /// Within `isIncluded`, you may access the current test or test case (if any)
  /// using ``Test/current`` ``Test/Case/current``, respectively. You may also
  /// record new issues, although they will only be handled by issue handling
  /// traits which precede this trait or were inherited from a containing suite.
  ///
  /// - Note: `isIncluded` will never be passed an issue for which the value of
  ///   ``Issue/kind`` is ``Issue/Kind/system``.
  public static func filterIssues(_ isIncluded: @escaping @Sendable (Issue) -> Bool) -> Self
}
```

## Source compatibility

This new trait is additive and should not affect source compatibility of
existing test code.

If any users have an existing extension on `Trait` containing a static function
whose name conflicts with one in this proposal, the standard technique of
fully-qualifying its callsite with the relevant module name can be used to
resolve any ambiguity, but this should be rare.

## Integration with supporting tools

Most tools which integrate with the testing library interpret recorded issues in
some way, whether by writing them to a persistent data file or presenting them
in UI. These mechanisms will continue working as before, but the issues they act
on will be the result of any issue handling traits. If an issue handler
transforms an issue, the integrated tool will only receive the transformed issue,
and if a trait suppresses an issue, the tool will not be notified about the
issue at all.

## Future directions

### "Test ended" trait

The current proposal does not allow `await` in an issue handling closure--see
[Non-`async`](#non-async) above. In addition to not allowing concurrency, the
proposed behavior is that the issue handler is called once for _each_ issue
recorded.

Both of these policies could be problematic for some use cases. Some users may
want to collect additional diagnostics if a test fails, but only do so once per
per test (typically after it finishes) instead of once per _issue_, since the
latter may lead to redundant or wasteful work. Also, collecting diagnostics may
require calling `async` APIs.

In the future, a new trait could be added which offers a closure that is
unconditionally called once after a test ends. The closure could be provided the
result of the test (e.g. pass/fail/skip) and access to all the issues it
recorded. This hypothetical trait's closure could be safely made `async`, since
it wouldn't be subject to the same limitations as event delivery, and this could
complement the APIs proposed above.

### Comprehensive event observation API

As a more generalized form of the ["Test ended" trait](#test-ended-trait) idea
above, Swift Testing could offer a more comprehensive suite of APIs for
observing test events of all kinds. This would a much larger effort, but was
[mentioned](https://github.com/swiftlang/swift-evolution/blob/main/visions/swift-testing.md#flexibility)
as a goal in the
[Swift Testing vision document](https://github.com/swiftlang/swift-evolution/blob/main/visions/swift-testing.md).

### Standalone function

It could be useful to offer the functionality of an issue handling trait as a
standalone function (similar to `withKnownIssue { }`) so that it could be
applied to a narrower section of code than an entire test or suite. This idea
came up during the pitch phase, and we believe that sort of pattern may be
useful more broadly for other kinds of traits. Accordingly, it may make more
sense to address this in a separate proposal and design it in a way that
encompasses any trait.

## Alternatives considered

### Allow issue handler closures to throw errors

The current proposal does not allow throwing an error from an issue handling
closure--see [Non-`throws`](#non-throws) above. This artificial restriction
could be lifted, and errors thrown by issue handler closures could be caught
and recorded as issues, matching the behavior of test functions.

As mentioned earlier, allowing thrown errors could make test results more
confusing. We expect that most often, a test author will add an issue handler
because they want to make failures easier to interpret, and they generally won't
want an issue handler to record _more_ issues while doing so even if it can. Not
allowing errors to be thrown forces the author of the issue handler to make an
explicit decision about whether they want an additional issue to be recorded if
the handler encounters an error.

### Make the closure's issue parameter `inout`

The closure parameter of `compactMapIssues(_:)` currently has one parameter of
type `Issue` and returns an optional `Issue?` to support returning `nil` in
order to suppress an issue. If an issue handler wants to modify an issue, it
first needs to copy it to a mutable variable (`var`), mutate it, then return the
modified copy. These copy and return steps require extra lines of code within
the closure, and they could be eliminated if the parameter was declared `inout`.

The most straightforward way to achieve this would be for the closure to instead
have a `Void` return type and for its parameter to become `inout`. However, in
order to _suppress_ an issue, the parameter would also need to become optional
(`inout Issue?`) and this would mean that all usages would first need to be
unwrapped. This feels non-ergonomic, and would differ from the standard
library's typical pattern for `compactMap` functions.

Another way to achieve this ([suggested](https://forums.swift.org/t/st-0011-issue-handling-traits/80644/3)
by [@Val](https://forums.swift.org/u/Val) during proposal review) could be to
declare the return type of the closure `Void?` and the parameter type
`inout Issue` (non-optional). This alternative would not require unwrapping the
issue first and would still permit suppressing issues by returning `nil`. It
could also make one of the alternative names (such as `transformIssues`
discussed below) more fitting. However, this is a novel API pattern which isn't
widely used in Swift, and may be confusing to users. There were also concerns
raised by other reviewers that the language's implicit return for `Void` may not
be intentionally applied to `Optional<Void>` and that this mechanism could break
in the future.

### Alternate names for the static trait functions

We could choose different names for the static `compactMapIssues(_:)` or
`filterIssues(_:)` functions. Some alternate names considered were:

- `transformIssues` instead of `compactMapIssues`. "Compact map" seemed to align
  better with "filter" of `filterIssues`, however.
- `handleIssues` instead of `compactMapIssues`. The word "handle" is in the name
  of the trait type already; it's a more general word for what all of these
  usage patterns enable, so it felt too broad.
- Using singular "issue" rather than plural "issues" in both APIs. This may not
  adequately convey that the closure can be invoked more than once.

## Acknowledgments

Thanks to [Brian Croom](https://github.com/briancroom) for feedback on the
initial concept, and for making a suggestion which led to the
["Test ended" trait](#test-ended-trait) idea mentioned in Alternatives
considered.

[severity-proposal]: https://forums.swift.org/t/pitch-test-issue-warnings/79285
