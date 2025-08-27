# Test cancellation

* Proposal: [ST-NNNN](NNNN-test-cancellation.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: [swiftlang/swift-testing#120](https://github.com/swiftlang/swift-testing/issues/120)
* Implementation: [swiftlang/swift-testing#1284](https://github.com/swiftlang/swift-testing/pull/1284)
* Review: ([pitch](https://forums.swift.org/t/pitch-test-cancellation/81847))

## Introduction

Swift Testing provides the ability to conditionally skip a test before it runs
using the [`.enabled(if:)`](https://developer.apple.com/documentation/testing/trait/enabled(if:_:sourcelocation:)),
[`.disabled(if:)`](https://developer.apple.com/documentation/testing/trait/disabled(if:_:sourcelocation:)),
etc. family of traits:

```swift
@Test(.enabled(if: Tyrannosaurus.isTheLizardKing))
func `Tyrannosaurus is scary`() {
  let dino = Tyrannosaurus()
  #expect(dino.isScary)
  // ...
}
```

This proposal extends that feature to allow cancelling a test after it has
started but before it has ended.

## Motivation

We have received feedback from a number of developers indicating that their
tests have constraints that can only be checked after a test has started, and
they would like the ability to end a test early and see that state change
reflected in their development tools.

To date, we have not provided an API for ending a test's execution early because
we want to encourage developers to use the [`.enabled(if:)`](https://developer.apple.com/documentation/testing/trait/enabled(if:_:sourcelocation:))
_et al._ trait. This trait can be evaluated early and lets Swift Testing plan a
test run more efficiently. However, we recognize that these traits aren't
sufficient. Some test constraints are dependent on data that isn't available
until the test starts, while others only apply to specific test cases in a
parameterized test function.

## Proposed solution

A static `cancel()` function is added to the [`Test`](https://developer.apple.com/documentation/testing/test)
and [`Test.Case`](https://developer.apple.com/documentation/testing/test/case)
types. When a test author calls these functions from within the body of a test
(or from within the implementation of a trait, e.g. from [`prepare(for:)`](https://developer.apple.com/documentation/testing/trait/prepare(for:))),
Swift Testing cancels the currently-running test or test case, respectively.

### Relationship between tasks and tests

Each test runs in its own task during a test run, and each test case in a test
also runs in its own task. Cancelling the current task from within the body of a
test will, therefore, cancel the current test case, but not the current test:

```swift
@Test(arguments: Species.all(in: .dinosauria))
func `Are all dinosaurs extinct?`(_ species: Species) {
  if species.in(.aves)  {
    // Birds aren't extinct (I hope)
    withUnsafeCurrentTask { $0?.cancel() }
    return
  }
  // ...
}
```

Using [`withUnsafeCurrentTask(body:)`](https://developer.apple.com/documentation/swift/withunsafecurrenttask(body:)-6gvhl)
here is not ideal. It's not clear that the intent is to cancel the test case,
and [`UnsafeCurrentTask`](https://developer.apple.com/documentation/swift/unsafecurrenttask)
is, unsurprisingly, an unsafe interface.

> [!NOTE]
> The version of Swift Testing included with Swift 6.2 does not correctly handle
> task cancellation under all conditions. See [swiftlang/swift-testing#1289](https://github.com/swiftlang/swift-testing/issues/1289).

## Detailed design

New static members are added to [`Test`](https://developer.apple.com/documentation/testing/test)
and [`Test.Case`](https://developer.apple.com/documentation/testing/test/case):

```swift
extension Test {
  /// Cancel the current test.
  ///
  /// - Parameters:
  ///   - comment: A comment describing why you are cancelling the test.
  ///   - sourceLocation: The source location to which the testing library will
  ///     attribute the cancellation.
  ///
  /// - Throws: An error indicating that the current test case has been
  ///   cancelled.
  ///
  /// The testing library runs each test in its own task. When you call this
  /// function, the testing library cancels the task associated with the current
  /// test:
  ///
  /// ```swift
  /// @Test func `Food truck is well-stocked`() throws {
  ///   guard businessHours.contains(.now) else {
  ///     try Test.cancel("We're off the clock.")
  ///   }
  ///   // ...
  /// }
  /// ```
  ///
  /// If the current test is parameterized, all of its pending and running test
  /// cases are cancelled. If the current test is a suite, all of its pending
  /// and running tests are cancelled. If you have already cancelled the current
  /// test or if it has already finished running, this function throws an error
  /// but does not attempt to cancel the test a second time.
  ///
  /// - Important: If the current task is not associated with a test (for
  ///   example, because it was created with [`Task.detached(name:priority:operation:)`](https://developer.apple.com/documentation/swift/task/detached(name:priority:operation:)-795w1))
  ///   this function records an issue and cancels the current task.
  ///
  /// To cancel the current test case but leave other test cases of the current
  /// test alone, call ``Test/Case/cancel(_:sourceLocation:)`` instead.
  public static func cancel(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> Never
}

extension Test.Case {
  /// Cancel the current test case.
  ///
  /// - Parameters:
  ///   - comment: A comment describing why you are cancelling the test case.
  ///   - sourceLocation: The source location to which the testing library will
  ///     attribute the cancellation.
  ///
  /// - Throws: An error indicating that the current test case has been
  ///   cancelled.
  ///
  /// The testing library runs each test case of a test in its own task. When
  /// you call this function, the testing library cancels the task associated
  /// with the current test case:
  ///
  /// ```swift
  /// @Test(arguments: [Food.burger, .fries, .iceCream])
  /// func `Food truck is well-stocked`(_ food: Food) throws {
  ///   if food == .iceCream && Season.current == .winter {
  ///     try Test.Case.cancel("It's too cold for ice cream.")
  ///   }
  ///   // ...
  /// }
  /// ```
  ///
  /// If the current test is parameterized, the test's other test cases continue
  /// running. If the current test case has already been cancelled, this
  /// function throws an error but does not attempt to cancel the test case a
  /// second time.
  ///
  /// - Important: If the current task is not associated with a test case (for
  ///   example, because it was created with [`Task.detached(name:priority:operation:)`](https://developer.apple.com/documentation/swift/task/detached(name:priority:operation:)-795w1))
  ///   this function records an issue and cancels the current task.
  ///
  /// To cancel all test cases in the current test, call
  /// ``Test/cancel(_:sourceLocation:)`` instead.
  public static func cancel(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> Never
}
```

These functions behave similarly, and are distinguished by the level of the test
to which they apply:

- `Test.cancel()` cancels the current test. 
  - If the current test is parameterized, it implicitly cancels all running and
    pending test cases of said test.
  - If the current test is a suite (only applicable during trait evaluation), it
    recursively cancels all test suites and test functions within said suite.
- `Test.Case.cancel()` cancels the current test case.
  - If the current test is parameterized, other test cases are unaffected.
  - If the current test is _not_ parameterized, `Test.Case.cancel()` behaves the
    same as `Test.cancel()`.

Cancelling a test or test case implicitly cancels its associated task (and any
child tasks thereof) as if [`Task.cancel()`](https://developer.apple.com/documentation/swift/task/cancel())
were called on that task.

### Throwing semantics

Unlike [`Task.cancel()`](https://developer.apple.com/documentation/swift/task/cancel()),
these functions always throw an error instead of returning. This simplifies
control flow when a test is cancelled; instead of having to write:

```swift
if condition {
  theTask.cancel()
  return
}
```

A test author need only write:

```swift
if condition {
  try Test.cancel()
}
```

The errors these functions throw are of a type internal to Swift Testing that is
semantically similar to [`CancellationError`](https://developer.apple.com/documentation/swift/cancellationerror)
but carries additional information (namely the `comment` and `sourceLocation`
arguments to `cancel(_:sourceLocation:)`) that Swift Testing can present to the
user. When Swift Testing catches an error of this type[^cancellationErrorToo],
it does not record an issue for the current test or test case.

[^cancellationErrorToo]: Swift Testing also catches errors of type
  [`CancellationError`](https://developer.apple.com/documentation/swift/cancellationerror)
  if the current task has been cancelled. If the current task has not been
  cancelled, errors of this type are still recorded as issues.

Suppressing these errors with `do`/`catch` or `try?` does not uncancel a test,
test case, or task, but can be useful if you have additional local work you need
to do before the test or test case ends.

### Support for CancellationError

Cancelling a test's or test case's associated task is equivalent to cancelling
the test or test case. Hence, if a test or test case throws an instance of
[`CancellationError`](https://developer.apple.com/documentation/swift/cancellationerror)
_and_ the current task has been cancelled, it is treated as if the test or test
case were cancelled.

### Support for XCTSkip

XCTest has an approximate equivalent to test cancellation: throwing an instance
of [`XCTSkip`](https://developer.apple.com/documentation/xctest/xctskip-swift.struct)
from the body of an XCTest test function causes that test function to be skipped
(equivalent to cancelling it).

While we encourage developers to adopt `Test.cancel()` and `Test.Case.cancel()`,
we recognize the need for interoperability with XCTest. As such, Swift Testing
will recognize when a test or test case throws an instance of
[`XCTSkip`](https://developer.apple.com/documentation/xctest/xctskip-swift.struct)
and will treat it as cancelling the test or test case.

An instance of [`XCTSkip`](https://developer.apple.com/documentation/xctest/xctskip-swift.struct)
must be caught by Swift Testing in order for it to cancel the current test. It
is not sufficient to create and discard an instance of this error type or to
catch one before Swift Testing can catch it. This behavior is consistent with
that of XCTest.

> [!NOTE]
> This compatibility does **not** extend to Objective-C. In Objective-C, XCTest
> implements [`XCTSkip()`](https://developer.apple.com/documentation/xctest/xctskip-c.macro?language=objc)
> as a macro that throws an Objective-C exception. Exceptions are not supported
> in Swift, and Swift Testing does not attempt to catch these exceptions.

### Interaction with recorded issues

If you cancel a test or test case that has previously recorded an issue, that
issue is not overridden or nullified. In particular, if the test or test case
has already recorded an issue of severity **error** when you call
`cancel(_:sourceLocation:)`, the test or test case will still fail.

### Example usage

To cancel the current test case and let other test cases run:

```swift
@Test(arguments: Species.all(in: .dinosauria))
func `Are all dinosaurs extinct?`(_ species: Species) throws {
  if species.in(.aves)  {
    try Test.Case.cancel("\(species) is birds!")
  }
  // ...
}
```

Or, to cancel all remaining test cases in the current test:

```swift
@Test(arguments: Species.all(in: .dinosauria))
func `Are all dinosaurs extinct?`(_ species: Species) throws {
  if species.is(.godzilla)  {
    try Test.cancel("Forget about unit tests! Run for your life!")
  }
  // ...
}
```

## Source compatibility

This change is additive only.

## Integration with supporting tools

The JSON event stream Swift Testing provides is updated to include two new event
kinds:

```diff
 <event-kind> ::= "runStarted" | "testStarted" | "testCaseStarted" |
   "issueRecorded" | "testCaseEnded" | "testEnded" | "testSkipped" |
-  "runEnded" | "valueAttached"
+  "runEnded" | "valueAttached" | "testCancelled" | "testCaseCancelled"
```

And new fields are added to event records to represent the comment and source
location passed to `cancel(_:sourceLocation:)`:

```diff
 <event> ::= {
   "kind": <event-kind>,
   "instant": <instant>, ; when the event occurred
   ["issue": <issue>,] ; the recorded issue (if "kind" is "issueRecorded")
   ["attachment": <attachment>,] ; the attachment (if kind is "valueAttached")
   "messages": <array:message>,
   ["testID": <test-id>,]
+  ["comments": <array:string>,]
+  ["sourceLocation": <source-location>,]
 }
```

These new fields are populated for the new event kinds as well as other event
kinds that can populate them.

These new event kinds and fields will be included in the next revision of the
JSON schema (currently expected to be schema version `"6.3"`).

## Future directions

- Adding a corresponding `Test.checkCancellation()` function and/or
  `Test.isCancelled` static property. These are beyond the scope of this
  proposal, primarily because [`Task.isCancelled`](https://developer.apple.com/documentation/swift/task/iscancelled-swift.type.property)
  and [`Task.checkCancellation()`](https://developer.apple.com/documentation/swift/task/checkcancellation())
  already work in a test.

## Alternatives considered

- Doing nothing. While we do want test authors to use [`.enabled(if:)`](https://developer.apple.com/documentation/testing/trait/enabled(if:_:sourcelocation:))
  _et al._ trait, we recognize it does not provide the full set of functionality
  that test authors need.

- Ignoring task cancellation or treating [`CancellationError`](https://developer.apple.com/documentation/swift/cancellationerror)
  as a normal error even when the current task has been cancelled. It is not
  possible for Swift Testing to outright ignore task cancellation, and a
  [`CancellationError`](https://developer.apple.com/documentation/swift/cancellationerror)
  instance thrown from [`Task.checkCancellation()`](https://developer.apple.com/documentation/swift/task/checkcancellation())
  is not really a test issue but rather a manifestation of control flow.

- Using the [`XCTSkip`](https://developer.apple.com/documentation/xctest/xctskip-swift.struct)
  type from XCTest. Interoperation with XCTest is an area of exploration for us,
  but core functionality of Swift Testing needs to be usable without also
  importing XCTest.

- Spelling the functions `static func cancel(_:sourceLocation:) -> some Error`
  and requiring it be called as `throw Test.cancel()`. This is closer to how
  the [`XCTSkip`](https://developer.apple.com/documentation/xctest/xctskip-swift.struct)
  type is used in XCTest. We have received indirect feedback about [`XCTSkip`](https://developer.apple.com/documentation/xctest/xctskip-swift.struct)
  indicating its usage is unclear, and sometimes need to help developers who
  have written:

  ```swift
  if x {
    XCTSkip()
  }
  ```

  And don't understand why it has failed to stop the test. More broadly, it is
  not common practice in Swift for a function to return an error that the caller
  is then responsible for throwing.

- Providing additional `cancel(if:)` and `cancel(unless:)` functions. In
  Objective-C, XCTest provides the [`XCTSkipIf()`](https://developer.apple.com/documentation/xctest/xctskipif)
  and [`XCTSkipUnless()`](https://developer.apple.com/documentation/xctest/xctskipunless)
  macros which capture their condition arguments as strings for display to the
  test author. This functionality is not available in Swift, but XCTest's Swift
  interface provides equivalent throwing functions as conveniences. We could
  provide these functions (without any sort of string-capturing ability) too,
  but they provide little additional clarity above an `if` or `guard` statement.

- Implementing cancellation using Swift macros so we can capture an `if` or
  `unless` argument as a string. A macro for this feature is probably the wrong
  tradeoff between compile-time magic and technical debt.

- Relying solely on [`Task.cancel()`](https://developer.apple.com/documentation/swift/task/cancel()).
  Ignoring the interplay between tests and test cases, this approach is
  difficult for test authors to use because the current [`Task`](https://developer.apple.com/documentation/swift/task)
  instance isn't visible _within_ that task. Instead, a test author would need
  to use [`withUnsafeCurrentTask(body:)`](https://developer.apple.com/documentation/swift/withunsafecurrenttask(body:)-6gvhl)
  to get a temporary reference to the task and cancel _that_ value. We would
  also not have the ability to include a comment and source location information
  in the test's console output or an IDE's test result interface.

  With that said, [`UnsafeCurrentTask.cancel()`](https://developer.apple.com/documentation/swift/unsafecurrenttask/cancel())
  _does_ cancel the test or test case associated with the current task.

## Acknowledgments

Thanks team!

Thanks Arthur! That's right, dinosaurs _do_ say "roar!"

And thanks to [@allevato](https://github.com/allevato) for nerd-sniping me into
writing this proposal.
