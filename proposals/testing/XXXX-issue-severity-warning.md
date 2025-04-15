# [DRAFT] Test Issue Warnings

* Proposal: [ST-XXXX](XXXX-issue-severity-warning.md)
* Authors: [Suzy Ratcliff](https://github.com/suzannaratcliff)
* Review Manager: TBD
* Status: **Pitched**
* Bug: [swiftlang/swift-testing#1075](https://github.com/swiftlang/swift-testing/pull/1075)
* Implementation: [swiftlang/swift-testing#1075](https://github.com/swiftlang/swift-testing/pull/1075)

## Introduction

I propose introducing a new API to Swift Testing that allows developers to record issues with a specified severity level. By default, all issues will have severity level “error”, and a new “warning” level will be added to represent less severe issues. The effects of the warning recorded on a test will not cause a failure but will be included in the test results for inspection after the run is complete.

## Motivation

Currently, when an issue arises during a test, the only possible outcome is to mark the test as failed. This presents a challenge for users who want a deeper insight into the events occurring within their tests. By introducing a dedicated mechanism to record issues that do not cause test failure, users can more effectively inspect and diagnose problems at runtime and review results afterward. This enhancement provides greater flexibility and clarity in test reporting, ultimately improving the debugging and analysis process.

## Proposed solution
We propose introducing a new property on Issues in Swift Testing called `Severity`, that represents if an issue is a warning or an error.
The default Issue severity will still be error and users can create set the severity when they record an issue.

Test authors will be able to inspect if the issue is a failing issue and will be able to check the severity.

## Detailed design

*Severity Enum*

We introduce a Severity enum to categorize issues detected during testing. This enum is crucial for distinguishing between different levels of test issues and is defined as follows:

The `Severity` enum is defined as follows:

```swift
  public enum Severity: Sendable {
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
```

*Recording Non-Failing Issues*
To enable test authors to log non-failing issues without affecting test results, we provide a method for recording such issues:

```swift
Issue.record("My comment", severity: .warning)
```

*Issue Type Enhancements*
The Issue type is enhanced with two new properties to better handle and report issues:
- `severity`: This property allows access to the specific severity level of an issue, enabling more precise handling of test results.

```swift
/// The severity of the issue.
public var severity: Severity

```
- `isFailure`: A boolean property to determine if an issue results in a test failure, thereby helping in result aggregation and reporting.
```swift

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
public var isFailure: Bool
```

For more details, refer to the [Issue Documentation](https://developer.apple.com/documentation/testing/issue).

This revision aims to clarify the functionality and usage of the `Severity` enum and `Issue` properties while maintaining consistency with the existing Swift API standards.

## Alternatives considered

- Doing Nothing: Although there have been recurring requests over the years to support non-failing issues, we did not have a comprehensive solution until now. This year, we finally had the necessary components to implement this feature effectively.

- Separate Issue Creation and Recording: We considered providing a mechanism to create issues independently before recording them, rather than passing the issue details directly to the `record` method. This approach was ultimately set aside in favor of simplicity and directness in usage.

- Naming of `isFailure` vs. `isFailing`: We evaluated whether to name the property `isFailing` instead of `isFailure`. The decision to use `isFailure` was made to adhere to naming conventions and ensure clarity and consistency within the API.

- Severity-Only Checking: We deliberated not exposing `isFailure` and relying solely on `severity` checks. However, this was rejected because it would require test authors to overhaul their code should we introduce additional severity levels in the future. By providing `isFailure`, we offer a straightforward way to determine test outcome impact, complementing the severity feature.

## Acknowledgments

Thanks to Stuart Montgomery for creating and implementing severity in Swift Testing.

Thanks to Brian Croom and Jonathan Grynspan for feedback on warnings along the way.
