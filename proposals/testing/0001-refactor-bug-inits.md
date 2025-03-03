# Dedicated `.bug()` functions for URLs and IDs

* Proposal: [ST-0001](0001-refactor-bug-inits.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Status: **Implemented (Swift 6.0)**
* Implementation: [swiftlang/swift-testing#401](https://github.com/swiftlang/swift-testing/pull/401)
* Review: ([pitch](https://forums.swift.org/t/pitch-dedicated-bug-functions-for-urls-and-ids/71842)), ([acceptance](https://forums.swift.org/t/swt-0001-dedicated-bug-functions-for-urls-and-ids/71842/2))

> [!NOTE]
> This proposal was accepted before Swift Testing began using the Swift
> evolution review process. Its original identifier was
> [SWT-0001](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Proposals/0001-refactor-bug-inits.md).

## Introduction

One of the features of swift-testing is a test traits system that allows
associating metadata with a test suite or test function. One trait in
particular, `.bug()`, has the potential for integration with development tools
but needs some refinement before integration would be practical.

## Motivation

A test author can associate a bug (AKA issue, problem, ticket, etc.) with a test
using the `.bug()` trait, to which they pass an "identifier" for the bug. The
swift-testing team's intent here was that a test author would pass the unique
identifier of the bug in the test author's preferred bug-tracking system (e.g.
GitHub Issues, Bugzilla, etc.) and that any tooling built around this trait
would be able to infer where the bug was located and how to view it.

It became clear immediately that a generic system for looking up bugs by unique
identifier in an arbitrary and unspecified database wouldn't be a workable
solution. So we modified the description of `.bug()` to explain that, if the
identifier passed to it was a valid URL, then it would be "interpreted" as a URL
and that tools could be designed to open that URL as needed.

This design change then placed the burden of parsing each `.bug()` trait and
potentially mapping it to a URL on tools. swift-testing itself avoids linking to
or using Foundation API such as `URL`, so checking for a valid URL inside the
testing library was not feasible either.

## Proposed solution

To solve the underlying problem and allow test authors to specify a URL when
available, or just an opaque identifier otherwise, we propose splitting the
`.bug()` function up into two overloads:

- The first overload takes a URL string and additional optional metadata;
- The second overload takes a bug identifier as an opaque string or integer and,
  optionally, a URL string.
  
Test authors are then free to specify any combination of URL and opaque
identifier depending on the information they have available and their specific
needs. Tools authors are free to consume either or both of these properties and
present them where appropriate.

## Detailed design

The `Bug` trait type and `.bug()` trait factory function shall be refactored
thusly:

```swift
/// A type representing a bug report tracked by a test.
///
/// To add this trait to a test, use one of the following functions:
///
/// - ``Trait/bug(_:_:)``
/// - ``Trait/bug(_:id:_:)-10yf5``
/// - ``Trait/bug(_:id:_:)-3vtpl``
public struct Bug: TestTrait, SuiteTrait, Equatable, Hashable, Codable {
  /// A URL linking to more information about the bug, if available.
  ///
  /// The value of this property represents a URL conforming to
  /// [RFC 3986](https://www.ietf.org/rfc/rfc3986.txt).
  public var url: String?

  /// A unique identifier in this bug's associated bug-tracking system, if
  /// available.
  ///
  /// For more information on how the testing library interprets bug
  /// identifiers, see <doc:BugIdentifiers>.
  public var id: String?

  /// The human-readable title of the bug, if specified by the test author.
  public var title: Comment?
}

extension Trait where Self == Bug {
  /// Construct a bug to track with a test.
  ///
  /// - Parameters:
  ///   - url: A URL referring to this bug in the associated bug-tracking
  ///     system.
  ///   - title: Optionally, the human-readable title of the bug.
  ///
  /// - Returns: An instance of ``Bug`` representing the specified bug.
  public static func bug(_ url: _const String, _ title: Comment? = nil) -> Self

  /// Construct a bug to track with a test.
  ///
  /// - Parameters:
  ///   - url: A URL referring to this bug in the associated bug-tracking
  ///     system.
  ///   - id: The unique identifier of this bug in its associated bug-tracking
  ///     system.
  ///   - title: Optionally, the human-readable title of the bug.
  ///
  /// - Returns: An instance of ``Bug`` representing the specified bug.
  public static func bug(_ url: _const String? = nil, id: some Numeric, _ title: Comment? = nil) -> Self

  /// Construct a bug to track with a test.
  ///
  /// - Parameters:
  ///   - url: A URL referring to this bug in the associated bug-tracking
  ///     system.
  ///   - id: The unique identifier of this bug in its associated bug-tracking
  ///     system.
  ///   - title: Optionally, the human-readable title of the bug.
  ///
  /// - Returns: An instance of ``Bug`` representing the specified bug.
  public static func bug(_ url: _const String? = nil, id: _const String, _ title: Comment? = nil) -> Self
}
```

The `@Test` and `@Suite` macros have already been modified so that they perform
basic validation of a URL string passed as input and emit a diagnostic if the
URL string appears malformed. 

## Source compatibility

This change is expected to be source-breaking for test authors who have already
adopted the existing `.bug()` functions. This change is source-breaking for code
that directly refers to these functions by their signatures. This change is
source-breaking for code that uses the `identifier` property of the `Bug` type
or expects it to contain a URL.

## Integration with supporting tools

Tools that integrate with swift-testing and provide lists of tests or record
results after tests have run can use the `Bug` trait on tests to present
relevant identifiers and/or URLs to users.

Tools that use the experimental event stream output feature of the testing
library will need a JSON schema for bug traits on tests. This work is tracked in
a separate upcoming proposal.

## Alternatives considered

- Inferring whether or not a bug identifier was a URL by parsing it at runtime
  in tools. As discussed above, this option would require every tool that
  integrates with swift-testing to provide its own URL-parsing logic.
  
- Using different argument labels (e.g. the label `url` for the URL argument
  and/or no label for the `id` argument.) We felt that URLs, which are
  recognizable by their general structure, did not need labels. At least one
  argument must have a label to avoid ambiguous resolution of the `.bug()`
  function at compile time.

- Inferring whether or not a bug identifier was a URL by parsing it at compile-
  time or at runtime using `Foundation.URL` or libcurl. swift-testing actively
  avoids linking to Foundation if at all possible, and libcurl would be a
  platform-specific solution (Windows doesn't ship with libcurl, but does have
  `InternetCrackUrlW()` whose parsing engine differs.) We also run the risk of
  inappropriately interpreting some arbitrary bug identifier as a URL when it is
  not meant to be parsed that way.

- Removing the `.bug()` trait. We see this particular trait as having strong
  potential for integration with tools and for use by test authors; removing it
  because we can't reliably parse URLs would be unfortunate.

## Acknowledgments

Thanks to the swift-testing team and managers for their contributions! Thanks to
our community for the initial feedback around this feature.
