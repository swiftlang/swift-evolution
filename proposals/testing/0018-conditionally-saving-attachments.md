# Conditionally saving attachments

* Proposal: [ST-0018](0018-conditionally-saving-attachments.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Brian Croom](https://github.com/briancroom)
* Status: **Active Review (January 9-19, 2026)**
* Bug: [rdar://138921461](rdar://138921461)
* Implementation: [swiftlang/swift-testing#1319](https://github.com/swiftlang/swift-testing/pull/1319)
* Review: ([pitch](https://forums.swift.org/t/pitch-conditionally-saving-attachments-aka-attachment-lifetimes/82541)) ([review](https://forums.swift.org/t/st-0018-conditionally-saving-attachments/84051))

## Introduction

In [ST-0009](0009-attachments.md), we introduced [attachments](https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0009-attachments.md)
to Swift Testing in Swift 6.2. This feature allows you to create a file
containing data relevant to a test. This proposal covers introducing new API to
Swift Testing to allow test authors to control whether or not a test's
attachments should be saved or discarded.

> [!NOTE]
> In this proposal, **recording** an attachment means calling
> [`Attachment.record()`](https://developer.apple.com/documentation/testing/attachment/record(_:named:sourcelocation:)).
> When you record an attachment, it is stored in an implementation-defined
> temporary location (such as memory or `/tmp/`) until the current test function
> returns. Swift Testing then determines if the attachment should be **saved**,
> i.e. written to persistent storage such as a file on disk or an Xcode test
> report.

## Motivation

In **XCTest** on Apple platforms, you can specify the *lifetime* of an
attachment by setting the [`lifetime`](https://developer.apple.com/documentation/xctest/xctattachment/lifetime-swift.property)
property of an `XCTAttachment` object. This property lets you avoid serializing
and saving an attachment if its data won't be necessary (e.g. "if the test
passes, don't bother saving this attachment.")

It is especially useful for test authors working in CI environments to be able
to control whether or not their attachments are saved, especially when those
attachments are large (on the order of hundreds of megabytes or more).
Persistent storage may come with a real-world monetary cost, or may be limited
such that their CI jobs run out of space for new attachments too quickly.

The initial implementation of the attachments feature did not include this
functionality, but we listed it as a future direction in [ST-0009](0009-attachments.md#future-directions).
We understand the utility of [`XCTAttachment.lifetime`](https://developer.apple.com/documentation/xctest/xctattachment/lifetime-swift.property)
and want to bring an analogous interface to Swift Testing.

## Proposed solution

I propose introducing a new test trait that can be applied to a suite or test
function. This trait can be configured with a condition that determines whether
or not attachments should be saved.

## Detailed design

A new trait type is added:

```swift
/// A type that defines a condition which must be satisfied for the testing
/// library to save attachments recorded by a test.
///
/// To add this trait to a test, use one of the following functions:
///
/// - ``Trait/savingAttachments(if:)``
///
/// By default, the testing library saves your attachments as soon as you call
/// ``Attachment/record(_:named:sourceLocation:)``. You can access saved
/// attachments after your tests finish running:
///
/// - When using Xcode, you can access attachments from the test report.
/// - When using Visual Studio Code, the testing library saves attachments to
///   `.build/attachments` by default. Visual Studio Code reports the paths to
///   individual attachments in its Tests Results panel.
/// - When using Swift Package Manager's `swift test` command, you can pass the
///   `--attachments-path` option. The testing library saves attachments to the
///   specified directory.
///
/// If you add an instance of this trait type to a test, any attachments that
/// test records are stored in memory until the test finishes running. The
/// testing library then evaluates the instance's condition and, if the
/// condition is met, saves the attachments.
public struct AttachmentSavingTrait: TestTrait, SuiteTrait, TestScoping {
  /// A type that describes the conditions under which the testing library
  /// will save attachments.
  ///
  /// You can pass instances of this type to ``Trait/savingAttachments(if:)``.
  public struct Condition: Sendable {
    /// The testing library saves attachments if the test passes.
    public static var testPasses: Self { get }

    /// The testing library saves attachments if the test fails.
    public static var testFails: Self { get }

    /// The testing library saves attachments if the test records a matching
    /// issue.
    ///
    /// - Parameters:
    ///   - issueMatcher: A function to invoke when an issue occurs that is used
    ///     to determine if the testing library should save attachments for the
    ///     current test.
    ///
    /// - Returns: An instance of ``AttachmentSavingTrait/Condition`` that
    ///   evaluates `issueMatcher`.
    public static func testRecordsIssue(
      matching issueMatcher: @escaping @Sendable (_ issue: Issue) async throws -> Bool
    ) -> Self
  }
}

extension Trait where Self == AttachmentSavingTrait {
  /// Constructs a trait that tells the testing library to only save attachments
  /// if a given condition is met.
  ///
  /// - Parameters:
  ///   - condition: A condition which, when met, means that the testing library
  ///     should save attachments that the current test has recorded. If the
  ///     condition is not met, the testing library discards the test's
  ///     attachments when the test ends.
  ///   - sourceLocation: The source location of the trait.
  ///
  /// - Returns: An instance of ``AttachmentSavingTrait`` that evaluates the
  ///   closure you provide.
  ///
  /// By default, the testing library saves your attachments as soon as you call
  /// ``Attachment/record(_:named:sourceLocation:)``. You can access saved
  /// attachments after your tests finish running:
  ///
  /// - When using Xcode, you can access attachments from the test report.
  /// - When using Visual Studio Code, the testing library saves attachments to
  ///   `.build/attachments` by default. Visual Studio Code reports the paths to
  ///   individual attachments in its Tests Results panel.
  /// - When using Swift Package Manager's `swift test` command, you can pass
  ///   the `--attachments-path` option. The testing library saves attachments
  ///   to the specified directory.
  ///
  /// If you add this trait to a test, any attachments that test records are
  /// stored in memory until the test finishes running. The testing library then
  /// evaluates `condition` and, if the condition is met, saves the attachments.
  public static func savingAttachments(
    if condition: Self.Condition,
    sourceLocation: SourceLocation = #_sourceLocation
  ) -> Self

  /// Constructs a trait that tells the testing library to only save attachments
  /// if a given condition is met.
  ///
  /// - Parameters:
  ///   - condition: A closure that contains the trait's custom condition logic.
  ///     If this closure returns `true`, the trait tells the testing library to
  ///     save attachments that the current test has recorded. If this closure
  ///     returns `false`, the testing library discards the test's attachments
  ///     when the test ends. If this closure throws an error, the testing
  ///     library records that error as an issue and discards the test's
  ///     attachments.
  ///   - sourceLocation: The source location of the trait.
  ///
  /// - Returns: An instance of ``AttachmentSavingTrait`` that evaluates the
  ///   closure you provide.
  ///
  /// By default, the testing library saves your attachments as soon as you call
  /// ``Attachment/record(_:named:sourceLocation:)``. You can access saved
  /// attachments after your tests finish running:
  ///
  /// - When using Xcode, you can access attachments from the test report.
  /// - When using Visual Studio Code, the testing library saves attachments
  ///   to `.build/attachments` by default. Visual Studio Code reports the paths
  ///   to individual attachments in its Tests Results panel.
  /// - When using Swift Package Manager's `swift test` command, you can pass
  ///   the `--attachments-path` option. The testing library saves attachments
  ///   to the specified directory.
  ///
  /// If you add this trait to a test, any attachments that test records are
  /// stored in memory until the test finishes running. The testing library then
  /// evaluates `condition` and, if the condition is met, saves the attachments.
  public static func savingAttachments(
    if condition: @autoclosure @escaping @Sendable () throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) -> Self

  /// Constructs a trait that tells the testing library to only save attachments
  /// if a given condition is met.
  ///
  /// - Parameters:
  ///   - condition: A closure that contains the trait's custom condition logic.
  ///     If this closure returns `true`, the trait tells the testing library to
  ///     save attachments that the current test has recorded. If this closure
  ///     returns `false`, the testing library discards the test's attachments
  ///     when the test ends. If this closure throws an error, the testing
  ///     library records that error as an issue and discards the test's
  ///     attachments.
  ///   - sourceLocation: The source location of the trait.
  ///
  /// - Returns: An instance of ``AttachmentSavingTrait`` that evaluates the
  ///   closure you provide.
  ///
  /// By default, the testing library saves your attachments as soon as you call
  /// ``Attachment/record(_:named:sourceLocation:)``. You can access saved
  /// attachments after your tests finish running:
  ///
  /// - When using Xcode, you can access attachments from the test report.
  /// - When using Visual Studio Code, the testing library saves attachments
  ///   to `.build/attachments` by default. Visual Studio Code reports the paths
  ///   to individual attachments in its Tests Results panel.
  /// - When using Swift Package Manager's `swift test` command, you can pass
  ///   the `--attachments-path` option. The testing library saves attachments
  ///   to the specified directory.
  ///
  /// If you add this trait to a test, any attachments that test records are
  /// stored in memory until the test finishes running. The testing library then
  /// evaluates `condition` and, if the condition is met, saves the attachments.
  public static func savingAttachments(
    if condition: @escaping @Sendable () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) -> Self
}
```

This trait can then be added to a test function using one of the listed factory
functions. If added to a test suite, it is recursively applied to the test
functions in that suite.

If multiple traits of this type are added to a test (directly or indirectly),
then _all_ their conditions must be met for the test's attachments to be saved.
This behavior is consistent with existing API such as [`ConditionTrait`](https://developer.apple.com/documentation/testing/conditiontrait).

### Default behavior

If a test has no instance of `AttachmentSavingTrait` applied to it, then the
test host environment determines whether or not attachments from that test are
saved:

- When using Xcode, your test plan determines if attachments are saved by
  default.
- When using Visual Studio Code, attachments are saved to a temporary directory
  inside `./.build` by default.
- When using `swift test`, you must pass `--attachments-path` to enable saving
  attachments.

For example, a test author may wish to only save attachments from a particular
test if the test fails:

```swift
@Test(.savingAttachments(if: .testFails))
func `All vowels are green`() {
  var vowels = "AEIOU"
  if Bool.random() {
    vowels += "Y"
  }
  Attachment.record(vowels)
  #expect(vowels.allSatisfy { $0.color == .green })
}
```

Or a test author may wish to save attachments if an issue is recorded in a
specific file:

```swift
extension Issue {
  var inCriticalFile: Bool {
    guard let sourceLocation else { return false }
    return sourceLocation.fileID.hasSuffix("Critical.swift")
  }
}

@Test(.savingAttachments(if: .testRecordsIssue { $0.inCriticalFile })
func `Ideas taste tremendous`() { ... }
```

If a test author wants to conditionally save attachments based on some outside
state, there are overloads of `savingAttachments(if:)` that take an autoclosure
or explicit closure:

```swift
@Test(
  .savingAttachments(if: CommandLine.arguments.contains("--save--attachments")),
  .savingAttachments { try await CI.current.storage.available >= 500.MB }
)
func `The fandango is especially grim today`() { ... }
```

## Source compatibility

This change is additive.

## Integration with supporting tools

Tools that consume the JSON event stream Swift Testing produces and which
already observe the `.valueAttached` event will generally not need to change.
When this trait is applied to a test, those events will be delivered later than
they would be without it, but still before `.testCaseEnded` for the current test
case.

Two new properties, `preferredName` and `bytes`, are added to the JSON structure
describing an attachment when the stream's schema version is `"6.3"` or higher:

- `preferredName` is a string and contains (perhaps unsurprisingly) the test
  author's preferred filename for the attachment. For more information about
  this property, see [`Attachment.preferredName`](https://developer.apple.com/documentation/testing/attachment/preferredname).
- `bytes`, if present, contains the serialized representation of the attachment
  as either a Base64-encoded string or an array of integers (one per byte). If
  the existing `path` property is set, this property is optional and may be
  excluded. (While this property may seem redundant, it is possible for a tool
  to consume the JSON event stream without also setting the attachments
  directory path, in which case the `bytes` property is necessary to recover the
  attachment's serialized representation.)

<!-- TODO: BNF for these properties -->

## Future directions

- We may wish to augment `Issue` or other types/concepts in Swift Testing to
  allow associating attachments with them rather than with the current test.
  This would likely take the form of an additional argument to
  [`Issue.record()`](https://developer.apple.com/documentation/testing/issue/record(_:sourcelocation:)).

- Test authors may still need more fine-grained control over whether individual
  attachments in a test should be saved. Our expectation (no pun intended) here
  is that per-test granularity will be sufficient for the majority of test
  authors. For those test authors who need more fine-grained control, we may
  want to add an argument of type `AttachmentSavingTrait.Condition` to
  [`Attachment.record()`](https://developer.apple.com/documentation/testing/attachment/record(_:named:sourcelocation:))
  or, alternatively, allow for applying the `AttachmentSavingTrait` trait to a
  local scope. (Locally-scoped traits are another area we're looking at for a
  future proposal.)

- There is interest in augmenting [`ConditionTrait`](https://developer.apple.com/documentation/testing/conditiontrait)
  to allow for boolean operations on them. It would make sense to add such
  functionality to `AttachmentSavingTrait` too.

## Alternatives considered

- Directly mapping XCTest's [`lifetime`](https://developer.apple.com/documentation/xctest/xctattachment/lifetime-swift.property)
  property to Swift Testing. Swift Testing presents the opportunity to improve
  upon this interface in ways that don't map cleanly to Objective-C.

- Adding a `shouldBeSaved: Bool` property to [`Attachment`](https://developer.apple.com/documentation/testing/attachment).
  While developers can create an instance of [`Attachment`](https://developer.apple.com/documentation/testing/attachment)
  before calling [`Attachment.record()`](https://developer.apple.com/documentation/testing/attachment/record(_:sourcelocation:)),
  it is typically more ergonomic to pass the attachable value directly. Thus a
  property on [`Attachment`](https://developer.apple.com/documentation/testing/attachment)
  is less accessible than other alternatives.

- Adding a `save: Bool` parameter to [`Attachment.record()`](https://developer.apple.com/documentation/testing/attachment/record(_:named:sourcelocation:)).
  In our experience, it's frequently the case that a test author wants to
  conditionally save an attachment based on whether a test fails (or some other
  external factor) and won't know if an attachment should be saved until after
  they've created it.

## Acknowledgments

Thanks to the team for their feedback on this proposal and to the Swift
community for their continued interest in Swift Testing!
