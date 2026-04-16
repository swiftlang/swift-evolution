# Targeted Interoperability between Swift Testing and XCTest

- Proposal: [ST-0021](0021-targeted-interoperability-swift-testing-and-xctest.md)
- Authors: [Jerry Chen](https://github.com/jerryjrchen)
- Review Manager: [Rachel Brindle](https://github.com/younata)
- Status: **Accepted**
- Implementation: [swiftlang/swift-testing#1523](https://github.com/swiftlang/swift-testing/pull/1523),
  [swiftlang/swift-testing#1573](https://github.com/swiftlang/swift-testing/pull/1573),
  [swiftlang/swift-testing#1542](https://github.com/swiftlang/swift-testing/pull/1542),
  [swiftlang/swift-testing#1516](https://github.com/swiftlang/swift-testing/pull/1516),
  [swiftlang/swift-testing#1512](https://github.com/swiftlang/swift-testing/pull/1512),
  [swiftlang/swift-testing#1478](https://github.com/swiftlang/swift-testing/pull/1478),
  [swiftlang/swift-testing#1439](https://github.com/swiftlang/swift-testing/pull/1439),
  [swiftlang/swift-testing#1369](https://github.com/swiftlang/swift-testing/pull/1369),
  [swiftlang/swift-corelibs-xctest#525](https://github.com/swiftlang/swift-corelibs-xctest/pull/525)
- Review: ([pitch](https://forums.swift.org/t/pitch-targeted-interoperability-between-swift-testing-and-xctest/82505),
  [review](https://forums.swift.org/t/st-0021-targeted-interoperability-between-swift-testing-and-xctest/84965),
  [acceptance](https://forums.swift.org/t/accepted-st-0021-targeted-interoperability-between-swift-testing-and-xctest/85331))

> Apr 2026: Amended to change the definition of limited interop mode.

## Introduction

Many projects want to migrate from XCTest to Swift Testing, and may be in an
intermediate state where test helpers written using XCTest API are called from
Swift Testing. Today, the Swift Testing and XCTest libraries stand mostly
independently, which means an [`XCTAssert`][XCTest assertions] failure in a
Swift Testing test or an [`#expect`][Swift Testing expectations] failure in an
XCTest test is silently ignored. To address this, we formally declare a set of
interoperability principles and propose changes to the handling of specific APIs
that will enable users to migrate with confidence.

## Motivation

Calling XCTest or Swift Testing API within a test from the opposite framework
may not always work as expected. As a more concrete example, if you take an
existing test helper function written for XCTest and call it in a Swift Testing
test, it won't report the assertion failure:

```swift
func assertUnique(_ elements: [Int]) {
  XCTAssertEqual(Set(elements).count, elements.count, "\(elements) has non unique elements")
}

// XCTest

class FooTests: XCTestCase {
    func testDups() {
        assertUnique([1, 2, 1]) // Fails as expected
    }
}

// Swift Testing

@Test func `Duplicate elements`() {
  assertUnique([1, 2, 1]) // Passes? Oh no!
}
```

### Lossy without interop

Generally, you encounter the above limitation with testing APIs when _all_ the
following conditions are met:

- You call XCTest API in a Swift Testing test, or call Swift Testing API in a
  XCTest test,
- The API doesn't function as expected in some or all cases, and
- You get no notice at build time or runtime about the malfunction

For the remainder of this proposal, we’ll describe test APIs which exhibit this
limitation as **lossy without interop**.

You could regress test coverage if you migrate to Swift Testing without
replacing usage of lossy without interop test APIs. Furthermore, you may want to
ensure you don't inadvertently introduce new XCTest API after completing your
Swift Testing migration.

## Proposed solution

- **XCTest APIs which are lossy without interop will work as expected when
  called in Swift Testing.** In addition, runtime diagnostics will be included
  to highlight opportunities to adopt newer Swift Testing equivalent APIs.

- Conversely, **Swift Testing API called in XCTest will work as expected if
  XCTest already provides similar functionality.** You should always feel
  empowered to choose Swift Testing when writing new tests or test helpers, as
  it will work properly in both types of tests.

We don't propose supporting interoperability for APIs which are not lossy
without interop, because they naturally have high visibility. For example, using
`throw XCTSkip` in a Swift Testing test results in a test failure rather than a
test skip, providing a clear indication that migration is needed.

## Detailed design

> [!NOTE]
> This proposal refers to XCTest in the abstract. There are two different
> implementations of XCTest: the open source [swift-corelibs-xctest][] and a
> [proprietary XCTest][Xcode XCTest] that is shipped as part of Xcode. The Swift
> evolution process governs changes to the former only. Therefore,
> this proposal is targeted for Corelibs XCTest.

[swift-corelibs-xctest]: https://github.com/swiftlang/swift-corelibs-xctest
[Xcode XCTest]: https://developer.apple.com/documentation/xctest

### Highlight and support XCTest APIs which are lossy without interop

We propose supporting the following XCTest APIs in Swift Testing:

- [Assertions][XCTest Assertions]: `XCTAssert*` and [unconditional failure][]
  `XCTFail`
- [Expected failures][], such as `XCTExpectFailure` (where available): marking a
  Swift Testing issue in this way will generate a runtime warning issue.
- [Issue handling traits][]: we will make our best effort to translate issues
  from XCTest to Swift Testing. For issue details unique to XCTest, we will
  include them as a comment when constructing the Swift Testing issue.

Note that no changes are proposed for the `XCTSkip` API, because it already
features prominently as a test failure when thrown in Swift Testing.

We also don't propose changes for [`XCTestExpectation`][XCTestExpectation] and
[`XCTWaiter`][XCTWaiter]. They cannot be used safely in a Swift concurrency
context when running Swift Testing tests. Instead, we recommend that users
migrate to Swift concurrency where possible. For code that does not easily map
to `async`/`await` semantics, use [continuations][] and [confirmations][]
instead.

Refer to [Migrating a test from XCTest][XCTest migration validate async] for a
detailed discussion.

We also propose highlighting usage of the above XCTest APIs in Swift Testing:

- **Report [runtime warning issues][]** for XCTest API usage in Swift Testing
  alongside assertion failures. This notifies you about opportunities to
  modernize.

- Opt-in **strict interop mode**, where XCTest API usage will result in
  `fatalError("Usage of XCTest API in a Swift Testing context is unsupported")`.

Here are some concrete examples:

| When running a Swift Testing test... | Current                   | Proposed                                     | Proposed (strict) |
| ------------------------------------ | ------------------------- | -------------------------------------------- | ----------------- |
| `XCTAssert` failure is a ...         | ‼️ False Negative (No-op) | ❌ Test Failure and ⚠️ Runtime Warning Issue | 💥 `fatalError`   |
| `XCTAssert` success is a ...         | No-op                     | ⚠️ Runtime Warning Issue                     | 💥 `fatalError`   |
| `throw XCTSkip` is a ...             | ❌ Test Failure           | ❌ Test Failure                              | ❌ Test Failure   |

### Targeted support for Swift Testing APIs with XCTest API equivalents

We propose supporting the following Swift Testing APIs in XCTest:

- [`#expect` and `#require`][Swift Testing expectations]
  - Includes [`#expect(throws:)`][testing for errors]
  - Includes [exit testing][]
  - Includes directly recording an issue with [`Issue.record()`][issues]
- `withKnownIssue`: marking an XCTest issue in this way will generate a runtime
  warning issue. In strict interop mode, this becomes a `fatalError`.
- [Test cancellation][]

We think developers will find utility in using Swift Testing APIs in XCTest. For
example, you can replace `XCTAssert` with `#expect` in your XCTest tests and
immediately get the benefits of the newer, more ergonomic API. In the meantime,
you can incrementally migrate the rest of your test infrastructure to use Swift
Testing at your own pace.

Present and future Swift Testing APIs will be supported in XCTest if the
XCTest API _already_ provides similar functionality.

For example, the [test cancellation][] feature in Swift Testing is analogous to
`XCTSkip`. This proposal would support interop of that API with XCTest.

On the other hand, [traits][] are a powerful Swift Testing feature which is not
related to any functionality in XCTest. Therefore, there would not be
interoperability for traits under this proposal.

Here are some concrete examples:

| When running an XCTest test...               | Current                   | Proposed                 | Proposed (strict) |
| -------------------------------------------- | ------------------------- | ------------------------ | ----------------- |
| `#expect` failure is a ...                   | ‼️ False Negative (No-op) | ❌ Test Failure          | ❌ Test Failure   |
| `#expect` success is a ...                   | No-op                     | No-op                    | No-op             |
| `withKnownIssue` wrapping `XCTFail` is a ... | ❌ Test Failure           | ⚠️ Runtime Warning Issue | 💥 `fatalError`   |

### Interoperability Modes

- **None**: No interop, which is the status quo prior to this proposal.

For the remaining modes, **Swift Testing API will behave as expected when used
in XCTest**. This includes reporting any assertion failures as errors within an
XCTest test case. As a result, any interop mode will enable you to incrementally
migrate your assertions to Swift Testing if desired.

**XCTest API used in Swift Testing tests** behaves differently based on interop
mode:

- **Limited**: Test failures that were previously ignored are reported as
  runtime warning issues. It also includes runtime warning issues for XCTest API
  usage in a Swift Testing context.

- **Complete**: This is the [default interoperability
  mode](#source-compatibility), which surfaces all test failures that were
  previously ignored. It also includes runtime warning issues for XCTest API
  usage in a Swift Testing context.

- **Strict**: Warning issues included in the complete mode can be easily
  overlooked, especially in CI. The strict mode guarantees that no XCTest API
  usage occurs when running Swift Testing tests by turning those warnings into a
  `fatalError`.

Here is a concrete example of how interop assertion failures behave under the
different modes:

```swift
class FooTests: XCTestCase {
    func testInterop() {
      // None:     No-op
      // Limited:  ❌ "Interop failure"
      // Complete: ❌ "Interop failure"
      // Strict:   ❌ "Interop failure"
      Issue.record("Interop failure")
    }
}

@Test func `Test Interop`() {
    // None:     No-op
    // Limited:  ⚠️ "Interop failure", ⚠️ Adopt Swift Testing primitives
    // Complete: ❌ "Interop failure", ⚠️ Adopt Swift Testing primitives
    // Strict:   💥 fatalError: Adopt Swift Testing primitives
    XCTFail("Interop failure")
}
```

Configure the interoperability mode when running tests using the
`SWIFT_TESTING_XCTEST_INTEROP_MODE` environment variable:

| Interop Mode | `SWIFT_TESTING_XCTEST_INTEROP_MODE`          |
| ------------ | -------------------------------------------- |
| None         | `none`                                       |
| Limited      | `limited`                                    |
| Complete     | `complete`, or empty value, or invalid value |
| Strict       | `strict`                                     |

## Source compatibility

The "complete" interoperability mode will be the default for new projects.
Existing projects will have "limited" interoperability mode by default, with the
option to easily opt-in to "complete".

Concretely, when interoperability is available in toolchain version `6.X`,
the interop mode will be determined for Swift Package projects as follows:

- `swift-tools-version` >= `6.X` will have "complete" interop mode
- `swift-tools-version` < `6.X` will have "limited" interop mode

As the main goal of interoperability is to change behavior, this proposal will
lead to situations where previously "passing" test code now starts showing
failures. We believe this should be a net positive if it can highlight actual
bugs you would have missed previously.

You can revert any changes in the short-term to test pass/fail outcomes as a
result of interoperability:

- `SWIFT_TESTING_XCTEST_INTEROP_MODE=limited` reduces issue severity from error
  to warning for XCTest issues used in Swift Testing tests.
- `SWIFT_TESTING_XCTEST_INTEROP_MODE=none` completely turns off interop.

## Integration with supporting tools

- Swift packages: `swift-tools-version` declared in Package.swift will be used
  to determine interop mode, regardless of the toolchain used to run tests.
  Specifically, it will use the default interop mode associated with that
  toolchain version ("complete" for the initial release version).

  We will work with the Swift Package Manager maintainers and the Ecosystem
  Steering Group to make appropriate changes in other parts of the toolchain.

- Otherwise, the default interop mode associated with the installed toolchain
  version will be used to determine interop mode.

- Any project can use the environment variable
  `SWIFT_TESTING_XCTEST_INTEROP_MODE` to override interop mode at runtime.

## Future directions

There's still more we can do to make it easier to migrate from XCTest to Swift
Testing:

- In a future release, we would consider making strict interop mode the default.

- Provide fixups at compile-time to replace usage of XCTest API with the
  corresponding Swift Testing API, e.g. replace `XCTAssert` with `#expect`.
  However, this would require introspection of the test body to look for XCTest
  API usage, which would be challenging to do completely and find usages of this
  API within helper methods.

- When new API is added to Swift Testing, we will need to evaluate it for
  interoperability with XCTest.

- Ideally, we'd report a runtime warning for XCTest API usage in Swift Testing for
  both assertion failures _and successes_. This notifies you about opportunities
  to modernize even if your tests currently pass.

  However, assertion successes are more common than failures in most projects
  (hopefully), and the extra volume of warnings can become very noisy.
  Furthermore, validating every instance of XCTest API usage introduces a
  performance penalty.

## Alternatives considered

### Arguments against interoperability

Frameworks that operate independently generally have no expectation of
interoperability, and XCTest and Swift Testing are currently set up this way.
Indeed, the end goal is not necessarily to support using XCTest APIs
indefinitely within Swift Testing. Adding interoperability can be interpreted as
going against that goal, and can enable users to delay migrating completely to
Swift Testing.

However, we believe the benefits of fixing lossy without interop APIs and
helping users catch more bugs are too important to pass up. We've also included
a plan to increase the strictness of the interoperability mode over time, which
should make it clear that this is not intended to be a permanent measure.

### Strict interop mode as the default

We believe that for projects using only Swift Testing, strict interop mode is
the best choice. Making this the default would also send the clearest signal
that we want users to migrate to Swift Testing.

However, we are especially sensitive to use cases that depend upon the currently
lossy without interop APIs. With strict interop mode, the test process will
crash on the first instance of XCTest API usage in Swift Testing, completely
halting testing. In this same scenario, the proposed default complete interop
mode would record a runtime warning issue and continue the remaining tests,
which we believe strikes a better balance between notifying users yet not being
totally disruptive to the testing flow.

### Warning severity for Swift Testing in Limited interop mode

In the original version of this proposal, limited interop mode converted test
failures that were previously ignored into runtime warning issues for **both**
XCTest and Swift Testing API. The goal was to minimize disruptions to existing
projects that may inadvertently be calling Swift Testing API within XCTest
tests.

This had the unfortunate side effect that if you did as suggested in the
proposal and switched from `XCTFail()` -> `Issue.record()`, interop consequently
degraded your assertion errors to warnings, which would effectively reduce your
test coverage if you weren't careful!

```swift
func someHelperOld() {
    XCTFail("Native failure")
}

func someHelperNew() {
    Issue.record("Interop failure")
}

class FooTests: XCTestCase {
    func testInterop() {
      // Limited interop mode: switch from old -> new, demotes to warning
      someHelperOld() // ❌ "Native failure"
      someHelperNew() // ⚠️ "Interop failure"
    }
}
```

The current proposal does not have this issue. However, limited interop
mode can cause new test failures if an existing project inadvertently calls
Swift Testing API within an XCTest test. We think this trade-off is worth it:

- This likely surfaces actual bugs in such projects, so error severity is
  warranted.

- Since Swift Testing is newer than XCTest, existing projects are more likely to
  have test code and helpers that use XCTest API. Calling XCTest API in Swift
  Testing tests is therefore more common than the other direction.

- Users can use the none interop mode to opt-out of interop.

### Alternative methods to control interop mode

- **Build setting:** e.g. a new `SwiftSetting` that can be included in
  Package.swift. A project could then configure their test targets to have a
  non-default interop mode.

  However, interop is a runtime concept, and would be difficult or at least
  non-idiomatic to modify with a build setting.

- **CLI option through SwiftPM:**

  ```
  swift test --interop-mode=limited
  ```

  This could be offered in addition to the proposed environment variable option,
  although it would be unclear which one should take precedence.

## Acknowledgments

Thanks to Stuart Montgomery, Jonathan Grynspan, and Brian Croom for feedback on
the proposal.

<!-- XCTest -->

[XCTest assertions]: https://developer.apple.com/documentation/xctest/equality-and-inequality-assertions
[unconditional failure]: https://developer.apple.com/documentation/xctest/unconditional-test-failures
[expected failures]: https://developer.apple.com/documentation/xctest/expected-failures
[XCTWaiter]: https://developer.apple.com/documentation/xctest/xctwaiter
[XCTestExpectation]: https://developer.apple.com/documentation/xctest/xctestexpectation

<!-- Swift Testing -->

[Swift Testing expectations]: https://developer.apple.com/documentation/testing/expectations
[Testing for errors]: https://developer.apple.com/documentation/testing/testing-for-errors-in-swift-code
[exit testing]: https://developer.apple.com/documentation/testing/exit-testing
[issues]: https://developer.apple.com/documentation/testing/issue
[issue handling traits]: https://developer.apple.com/documentation/testing/issuehandlingtrait
[traits]: https://developer.apple.com/documentation/testing/traits
[confirmations]: https://developer.apple.com/documentation/testing/confirmation
[XCTest migration validate async]: https://developer.apple.com/documentation/testing/migratingfromxctest#Validate-asynchronous-behaviors

<!-- Misc -->

[runtime warning issues]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0013-issue-severity-warning.md
[continuations]: https://developer.apple.com/documentation/swift/checkedcontinuation
[test cancellation]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0016-test-cancellation.md
