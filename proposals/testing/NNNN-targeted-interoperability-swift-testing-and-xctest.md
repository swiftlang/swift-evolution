# Targeted Interoperability between Swift Testing and XCTest

- Proposal: [ST-NNNN](NNNN-xctest-interoperability.md)
- Authors: [Jerry Chen](https://github.com/jerryjrchen)
- Review Manager: TBD
- Status: **Awaiting implementation**
- Implementation: [swiftlang/swift-testing#NNNNN](https://github.com/swiftlang/swift-testing/pull/NNNNN)
- Review: ([pitch](https://forums.swift.org/...))

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
- [Expected failures][], such as `XCTExpectFailure`: marking a Swift Testing
  issue in this way will generate a runtime warning issue.
- [Issue handling traits][]: we will make our best effort to translate issues
  from XCTest to Swift Testing. For issue details unique to XCTest, we will
  include them as a comment when constructing the Swift Testing issue.

Note that no changes are proposed for the `XCTSkip` API, because they already
feature prominently as a test failure when thrown in Swift Testing.

We also don't propose changes for [`XCTestExpectation`][XCTestExpectation] and
[`XCTWaiter`][XCTWaiter]. They cannot be used safely in a Swift concurrency
context when running Swift Testing tests. Instead, we recommend that users
migrate to Swift concurrency where possible. For code that does not easily map
to `async`/`await` semantics, use [continuations][] and [confirmations][]
instead.

Refer to [Migrating a test from XCTest][XCTest migration validate async] for a
detailed discussion.

We also propose highlighting usage of above XCTest APIs in Swift Testing:

- **Report [runtime warning issues][]** for XCTest API usage in Swift Testing.
  This **applies to both assertion failures _and successes_**! This notifies you
  about opportunities to modernize even if your tests currently pass.

- Opt-in **strict interop mode**, where XCTest API usage will result in
  `fatalError("Usage of XCTest API in a Swift Testing context is unsupported")`.

Here are some concrete examples:

| When running a Swift Testing test... | Current         | Proposed                                     | Proposed (strict) |
| ------------------------------------ | --------------- | -------------------------------------------- | ----------------- |
| `XCTAssert` failure is a ...         | ‼️ No-op        | ❌ Test Failure and ⚠️ Runtime Warning Issue | 💥 `fatalError`   |
| `XCTAssert` success is a ...         | No-op           | ⚠️ Runtime Warning Issue                     | 💥 `fatalError`   |
| `throw XCTSkip` is a ...             | ❌ Test Failure | ❌ Test Failure                              | ❌ Test Failure   |

### Targeted support for Swift Testing APIs with XCTest API equivalents

We propose supporting the following Swift Testing APIs in XCTest:

- [`#expect` and `#require`][Swift Testing expectations]
  - Includes [`#expect(throws:)`][testing for errors]
  - Includes [exit testing][]
- `withKnownIssue`: marking an XCTest issue in this way will generate a runtime
  warning issue. In strict interop mode, this becomes a `fatalError`.
- [Test cancellation][] (currently pitched)

We think developers will find utility in using Swift Testing APIs in XCTest. For
example, you can replace `XCTAssert` with `#expect` in your XCTest tests and
immediately get the benefits of the newer, more ergonomic API. In the meantime,
you can incrementally migrate the rest of your test infrastructure to use Swift
Testing at your own pace.

Present and future Swift Testing APIs will be supported in XCTest if the
XCTest API _already_ provides similar functionality.

For example, the recently-pitched [test cancellation][] feature in Swift Testing
is analogous to `XCTSkip`. If that pitch were accepted, this proposal would
support interop of the new API with XCTest.

On the other hand, [traits][] are a powerful Swift Testing feature which is not
related to any functionality in XCTest. Therefore, there would not be
interoperability for traits under this proposal.

Here are some concrete examples:

| When running a XCTest test...                | Current         | Proposed                 | Proposed (strict) |
| -------------------------------------------- | --------------- | ------------------------ | ----------------- |
| `#expect` failure is a ...                   | ‼️ No-op        | ❌ Test Failure          | ❌ Test Failure   |
| `#expect` success is a ...                   | No-op           | No-op                    | No-op             |
| `withKnownIssue` wrapping `XCTFail` is a ... | ❌ Test Failure | ⚠️ Runtime Warning Issue | 💥 `fatalError`   |

### Interoperability Modes

- **Advisory**: Test failures that were previously ignored are reported as
  runtime warning issues. It also includes runtime warning issues for XCTest API
  usage in a Swift Testing context. This is for projects which do not want to
  see new test failures surfaced due to interoperability.

- **Permissive**: This is the default interoperability mode, which surfaces test
  failures that were previously ignored. It also includes runtime warning issues
  for XCTest API usage in a Swift Testing context.

- **Strict**: Warning issues included in the permissive mode can be easily
  overlooked, especially in CI. The strict mode guarantees that no XCTest API
  usage occurs when running Swift Testing tests by turning those warnings into a
  `fatalError`.

Configure the interoperability mode when running tests using the
`SWIFT_TESTING_XCTEST_INTEROP_MODE` environment variable:

| Interop Mode | Issue behavior across framework boundary                                   | `SWIFT_TESTING_XCTEST_INTEROP_MODE`            |
| ------------ | -------------------------------------------------------------------------- | ---------------------------------------------- |
| Advisory     | XCTest API: ⚠️ Runtime Warning Issue. All Issues: ⚠️ Runtime Warning Issue | `advisory`                                     |
| Permissive   | XCTest API: ⚠️ Runtime Warning Issue. All Issues: ❌ Test Failure          | `permissive`, or empty value, or invalid value |
| Strict       | XCTest API: 💥 `fatalError`. Swift Testing API: ❌ Test Failure            | `strict`                                       |

## Source compatibility

When interoperability is first available, "permissive" will be the default
interop mode enabled for new projects.

As the main goal of interoperability is to change behavior, this proposal will
lead to situations where previously "passing" test code now starts showing
failures. We believe this should be a net positive if it can highlight actual
bugs you would have missed previously.

You can use `SWIFT_TESTING_XCTEST_INTEROP_MODE=advisory` in the short-term
to revert any changes to test pass/fail outcomes as a result of
interoperability.

## Integration with supporting tools

- Swift packages: `swift-tools-version` declared in Package.swift will be used
  to determine interop mode, regardless of the toolchain used to run tests.
  Specifically, it will use the default interop mode associated with that
  toolchain version ("permissive" for the initial release version).

  We will work with the Swift Package Manager maintainers and the Ecosystem
  Steering Group to make appropriate changes in other parts of the toolchain.

- Otherwise, the default interop mode associated with the installed toolchain
  version will be used to determine interop mode.

- Any project can use `SWIFT_TESTING_XCTEST_INTEROP_MODE` to override interop
  mode at runtime.

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

### Opt-out of interoperability

In a similar vein, we considered `SWIFT_TESTING_XCTEST_INTEROP_MODE=off` as a
way to completely turn off interoperability. Some projects may additionally have
an issue handling trait that promotes warnings to errors, which means that
advisory mode could still cause test failures.

However, in the scenario above, we think users who set up tests to elevate
warnings as errors would be interested in increased visibility of testing issues
surfaced by interop. We're open to feedback about other scenarios where a
"interop off" mode would be preferred.

### Strict interop mode as the default

We believe that for projects using only Swift Testing, strict interop mode is
the best choice. Making this the default would also send the clearest signal
that we want users to migrate to Swift Testing.

However, we are especially sensitive to use cases that depend upon the currently
lossy without interop APIs. With strict interop mode, the test process will
crash on the first instance of XCTest API usage in Swift Testing, completely
halting testing. In this same scenario, the proposed default permissive interop
mode would record a runtime warning issue and continue the remaining test, which
we believe strikes a better balance between notifying users yet not being
totally disruptive to the testing flow.

### Alternative methods to control interop mode

- **Build setting:** e.g. a new `SwiftSetting` that can be included in
  Package.swift. A project could then configure their test targets to have a
  non-default interop mode.

  However, interop is a runtime concept, and would be difficult or at least
  non-idiomatic to modify with a build setting.

- **CLI option through SwiftPM:**

  ```
  swift test --interop-mode=advisory
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
[issue handling traits]: https://developer.apple.com/documentation/testing/issuehandlingtrait
[traits]: https://developer.apple.com/documentation/testing/traits
[confirmations]: https://developer.apple.com/documentation/testing/confirmation
[XCTest migration validate async]: https://developer.apple.com/documentation/testing/migratingfromxctest#Validate-asynchronous-behaviors

<!-- Misc -->

[runtime warning issues]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0013-issue-severity-warning.md
[continuations]: https://developer.apple.com/documentation/swift/checkedcontinuation
[test cancellation]: https://forums.swift.org/t/pitch-test-cancellation/81847
