# Test Issue Severity

- Proposal: [ST-0013](0013-issue-severity-warning.md)
- Authors: [Suzy Ratcliff](https://github.com/suzannaratcliff)
- Review Manager: [Maarten Engels](https://github.com/maartene)
- Status: **Active Review (July 9...July 23, 2025)**
- Implementation: [swiftlang/swift-testing#1075](https://github.com/swiftlang/swift-testing/pull/1075)
- Review: ([pitch](https://forums.swift.org/t/pitch-test-issue-warnings/79285)) ([review](https://forums.swift.org/t/st-0013-test-issue-warnings/80991))

## Introduction

I propose introducing a new API to Swift Testing that allows developers to record issues with a specified severity level. By default, all issues will have severity level “error”, and a new “warning” level will be added to represent less severe issues. The effects of the warning recorded on a test will not cause a failure but will be included in the test results for inspection after the run is complete.

## Motivation

Currently, when an issue arises during a test, the only possible outcome is to mark the test as failed. This presents a challenge for users who want a deeper insight into the events occurring within their tests. By introducing a dedicated mechanism to record issues that do not cause test failure, users can more effectively inspect and diagnose problems at runtime and review results afterward. This enhancement provides greater flexibility and clarity in test reporting, ultimately improving the debugging and analysis process.

### Use Cases

- Warning about a Percentage Discrepancy in Image Comparison:
  - Scenario: When comparing two images to assess their similarity, a warning can be triggered if there's a 95% pixel match, while a test failure is set at a 90% similarity threshold.
  - Reason: In practices like snapshot testing, minor changes (such as a timestamp) might cause a discrepancy. Setting a 90% match as a pass ensures test integrity. However, a warning at 95% alerts testers that, although the images aren't identical, the test has passed, which may warrant further investigation.
- Warning for Duplicate Argument Inputs in Tests:
  - Scenario: In a test library, issue a warning if a user inputs the same argument twice, rather than flagging an error.
  - Reason: Although passing the same argument twice might not be typical, some users may have valid reasons for doing so. Thus, a warning suffices, allowing flexibility without compromising the test's execution.
- Warning for Recoverable Unexpected Events:
  - Scenario: During an integration test where data is retrieved from a server, a warning can be issued if the primary server is down, prompting a switch to an alternative server. Usually mocking is the solution for this but may not test everything needed for an integration test.
  - Reason: Since server downtime might happen and can be beyond the tester's control, issuing a warning rather than a failure helps in debugging and understanding potential issues without impacting the test's overall success.
- Warning for a retry during setup for a test:
  - Scenario: During test setup part of your code may be configured to retry, it would be nice to notify in the results that a retry happened
  - Reason: This makes sense to be a warning and not a failure because if the retry succeeds the test may still verify the code correctly

## Proposed solution

We propose introducing a new property on `Issue` in Swift Testing called `severity`, that represents if an issue is a `warning` or an `error`.
The default Issue severity will still be `error` and users can set the severity when they record an issue.

Test authors will be able to inspect if the issue is a failing issue and will be able to check the severity.

## Detailed design

### Severity Enum

We introduce a Severity enum to categorize issues detected during testing. This enum is crucial for distinguishing between different levels of test issues and is defined as follows:

The `Severity` enum:

```swift
extension Issue {
  // ...
  public enum Severity: Codable, Comparable, CustomStringConvertible, Sendable {
    /// The severity level for an issue which should be noted but is not
    /// necessarily an error.
    ///
    /// An issue with warning severity does not cause the test it's associated
    /// with to be marked as a failure, but is noted in the results.
    case warning

    /// The severity level for an issue which represents an error in a test.
    ///
    /// An issue with error severity causes the test it's associated with to be
    /// marked as a failure.
    case error
  }
  // ...
}
```

### Recording Non-Failing Issues

To enable test authors to log non-failing issues without affecting test results, we provide a method for recording such issues:

```swift
Issue.record("My comment", severity: .warning)
```

Here is the `Issue.record` method definition with severity as a parameter.

```swift
  /// Record an issue when a running test fails unexpectedly.
  ///
  /// - Parameters:
  ///   - comment: A comment describing the expectation.
  ///   - severity: The severity of the issue.
  ///   - sourceLocation: The source location to which the issue should be
  ///     attributed.
  ///
  /// - Returns: The issue that was recorded.
  ///
  /// Use this function if, while running a test, an issue occurs that cannot be
  /// represented as an expectation (using the ``expect(_:_:sourceLocation:)``
  /// or ``require(_:_:sourceLocation:)-5l63q`` macros.)
  @discardableResult public static func record(
    _ comment: Comment? = nil,
    severity: Severity = .error,
    sourceLocation: SourceLocation = #_sourceLocation
  ) -> Self

  // ...
```

### Issue Type Enhancements

The Issue type is enhanced with two new properties to better handle and report issues:

- `severity`: This property allows access to the specific severity level of an issue, enabling more precise handling of test results.

```swift
// ...

extension Issue {

/// The severity of the issue.
public var severity: Severity { get set }

}

```

- `isFailure`: A boolean property to determine if an issue results in a test failure, thereby helping in result aggregation and reporting.

```swift
extension Issue {
  // ...

  /// Whether or not this issue should cause the test it's associated with to be
  /// considered a failure.
  ///
  /// The value of this property is `true` for issues which have a severity level of
  /// ``Issue/Severity/error`` or greater and are not known issues via
  /// ``withKnownIssue(_:isIntermittent:sourceLocation:_:when:matching:)``.
  /// Otherwise, the value of this property is `false.`
  ///
  /// Use this property to determine if an issue should be considered a failure, instead of
  /// directly comparing the value of the ``severity`` property.
  public var isFailure: Bool { get }
}
```

Example usage of `severity` and `isFailure`:

```swift
// ...
withKnownIssue {
  // ...
} matching: { issue in
    return issue.isFailure || issue.severity > .warning
}
```

For more details on `Issue`, refer to the [Issue Documentation](https://developer.apple.com/documentation/testing/issue).

This revision aims to clarify the functionality and usage of the `Severity` enum and `Issue` properties while maintaining consistency with the existing Swift API standards.

### Integration with supporting tools

Issue severity will be in the event stream output when a `issueRecorded` event occurs. This will be a breaking change because some tools may assume that all `issueRecorded` events are failing. Due to this we will be bumping the event stream version and v1 will maintain it's behavior and not output any events for non failing issues. We will also be adding `isFailure` to the issue so that clients will know if the issue should be treated as a failure.

The JSON event stream ABI will be amended correspondingly:

```
<issue> ::= {
  "isKnown": <bool>, ; is this a known issue or not?
+ "severity": <string>, ; the severity of the issue
+ "isFailure": <bool>, ; if the issue is a failing issue
  ["sourceLocation": <source-location>,] ; where the issue occurred, if known
}
```

Example of an `issueRecorded` event in the json output:

```
{"kind":"event","payload":{"instant":{"absolute":302928.100968,"since1970":1751305230.364087},"issue":{"_backtrace":[{"address":4437724864},{"address":4427566652},{"address":4437724280},{"address":4438635916},{"address":4438635660},{"address":4440823880},{"address":4437933556},{"address":4438865080},{"address":4438884348},{"address":11151272236},{"address":4438862360},{"address":4438940324},{"address":4437817340},{"address":4438134208},{"address":4438132164},{"address":4438635048},{"address":4440836660},{"address":4440835536},{"address":4440834989},{"address":4438937653},{"address":4438963225},{"address":4438895773},{"address":4438896161},{"address":4438891517},{"address":4438937117},{"address":4438962637},{"address":4439236617},{"address":4438936181},{"address":4438962165},{"address":4438639149},{"address":4438935045},{"address":4438935513},{"address":11151270653},{"address":11151269797},{"address":4438738225},{"address":4438872065},{"address":4438933417},{"address":4438930265},{"address":4438930849},{"address":4438909741},{"address":4438965489},{"address":11151508333}],"_severity":"error","isFailure":true, "isKnown":false,"sourceLocation":{"_filePath":"\/Users\/swift-testing\/Tests\/TestingTests\/EntryPointTests.swift","column":23,"fileID":"TestingTests\/EntryPointTests.swift","line":46}},"kind":"issueRecorded","messages":[{"symbol":"fail","text":"Issue recorded"},{"symbol":"details","text":"Unexpected issue Issue recorded (warning) was recorded."}],"testID":"TestingTests.EntryPointTests\/warningIssues()\/EntryPointTests.swift:33:4"},"version":0}
```

### Console output

When there is an issue recorded with severity warning the output looks like this:

```swift
    Issue.record("My comment", severity: .warning)
```

```
􀟈  Test "All elements of two ranges are equal" started.
􀄣  Test "All elements of two ranges are equal" recorded a warning at ZipTests.swift:32:17: Issue recorded
􀄵  My comment
􁁛  Test "All elements of two ranges are equal" passed after 0.001 seconds with 1 warning.
```

### Trying this out

To use severity today, checkout the branch here: https://github.com/swiftlang/swift-testing/pull/1189

```
.package(url: "https://github.com/suzannaratcliff/swift-testing.git", branch: "suzannaratcliff:suzannaratcliff/enable-severity"),
```

For more details on how to checkout a branch for a package refer to this: https://developer.apple.com/documentation/packagedescription/package/dependency/package(url:branch:)

## Alternatives considered

- Separate Issue Creation and Recording: We considered providing a mechanism to create issues independently before recording them, rather than passing the issue details directly to the `record` method. This approach was ultimately set aside in favor of simplicity and directness in usage.

- Naming of `isFailure` vs. `isFailing`: We evaluated whether to name the property `isFailing` instead of `isFailure`. The decision to use `isFailure` was made to adhere to naming conventions and ensure clarity and consistency within the API.

- Severity-Only Checking: We deliberated not exposing `isFailure` and relying solely on `severity` checks. However, this was rejected because it would require test authors to overhaul their code should we introduce additional severity levels in the future. By providing `isFailure`, we offer a straightforward way to determine test outcome impact, complementing the severity feature.
- Naming `Severity.error` `Severity.failure` instead because this will always be a failing issue and test authors often think of test failures. Error and warning match build naming conventions and XCTest severity naming convention.

## Future directions

- In the future I could see the warnings being able to be promoted to errors in order to run with a more strict testing configuration

- In the future I could see adding other levels of severity such as Info and Debug for users to create issues with other information.

## Acknowledgments

Thanks to Stuart Montgomery for creating and implementing severity in Swift Testing.

Thanks to Joel Middendorf, Dorothy Fu, Brian Croom, and Jonathan Grynspan for feedback on severity along the way.
