# Interoperability between Swift Testing and XCTest

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
independently, which means an `XCTAssert` failure in a Swift Testing test is
silently ignored. To address this, we formally declare a set of interoperability
principles and propose updates to specific APIs that will enable users to
migrate with confidence.

## Motivation

Unfortunately, mixing an API call from one framework with a test from the other
framework may not work as expected. As a more concrete example, if you take an
existing test helper function written for XCTest and call it in a Swift Testing
test, it won't report the assertion failure:

```swift
func assertUnique(_ elements: [Int]) {
  if Set(elements).count != elements.count {
    XCTFail("\(elements) has non unique elements")
  }
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

Generally, we get into trouble today when ALL the following conditions are met:

- You call XCTest API in a Swift Testing test, or call Swift Testing API in a
  XCTest test
- The API doesn't function as expected in some or all cases, and
- You get no notice at build or runtime about the malfunction

Example: calling `XCTAssertEqual(x, y)` in a Swift Testing test: if x does not
equal y, it should report a failure but does nothing instead.

For the remainder of this proposal, we’ll describe tests which exhibit this
problem as **lossy without interop**.

If you've switched completely to Swift Testing and don't expect to use XCTest in
the future, this proposal includes a mechanism to **prevent you from
inadvertently introducing XCTest APIs to your project, including via a testing
library.**

## Proposed solution

At a high level, we propose the following **changes for APIs which are lossy
without interop**:

- **XCTest API called in Swift Testing will work as expected.** In addition,
  runtime diagnostics will be included to highlight opportunities to adopt newer
  Swift Testing equivalent APIs.

- Conversely, **Swift Testing API called in XCTest will also work as expected.**
  You should always feel empowered to choose Swift Testing when writing new
  tests or test helpers, as it will work properly in both types of tests.

We don't propose supporting interoperability for APIs without risk of data loss,
because they naturally have high visibility. For example, using `throw XCTSkip`
in a Swift Testing test results in a test failure rather than a test skip,
providing a clear indication that migration is needed.

## Detailed design

### Highlight usage of XCTest APIs in Swift Testing tests

We propose supporting the following XCTest APIs in Swift Testing:

- Assertions: `XCTAssert*` and [unconditional failure][] `XCTFail`
- [Expected failures][], such as `XCTExpectFailure`: marking a Swift Testing
  issue in this way will generate a runtime issue.
- `XCTAttachment`
- [Issue handling traits][]: we will make our best effort to translate issues
  from XCTest to Swift Testing. Note that there are certain issue kinds that are
  new to Swift Testing and not expressible from XCTest.

Note that no changes are proposed for the `XCTSkip` API, because they already
feature prominently as a test failure to be corrected when thrown in Swift
Testing.

We also propose highlighting usage of above XCTest APIs in Swift Testing:

- **Report [runtime warning issues][]** for XCTest API usage in Swift Testing.
  This **applies to assertion successes AND failures**! We want to make sure you
  can identify opportunities to modernise even if your tests currently all pass.

- Opt-in **strict interop mode**, which will trigger a crash instead.

Here are some concrete examples:

| When running a Swift Testing test... | Current         | Proposed (default)                           | Proposed (strict) |
| ------------------------------------ | --------------- | -------------------------------------------- | ----------------- |
| `XCTAssert` failure is a ...         | ‼️ No-op        | ❌ Test Failure and ⚠️ Runtime Warning Issue | 💥 Crash          |
| `XCTAssert` success is a ...         | No-op           | ⚠️ Runtime Warning Issue                     | 💥 Crash          |
| `throw XCTSkip` is a ...             | ❌ Test Failure | ❌ Test Failure                              | ❌ Test Failure   |

### Limited support for Swift Testing APIs in XCTest

We propose supporting the following Swift Testing APIs in XCTest:

- `#expect` and `#require`
  - Includes [exit testing][]
- `withKnownIssue`: when this suppresses `XCTAssert` failures, it will still
  show a runtime warning issue.
- Attachments
- [Test cancellation][] (links to pitch)

We think developers will find utility in using Swift Testing APIs in XCTest. For
example, you can replace `XCTAssert` with `#expect` in your XCTest tests and
immediately get the benefits of the newer, more ergonomic API. In the meantime,
you can incrementally migrate the rest of your test infrastructure to use Swift
Testing at your own pace.

Present and future Swift Testing APIs will be supported in XCTest if the
XCTest API _already_ provides similar functionality.

- For example, we plan on supporting the proposed Swift Testing [test
  cancellation][] feature in XCTest since it is analogous to `XCTSkip`

- On the other hand, [Traits][] are a powerful Swift Testing feature, and
  include the ability to [add tags][tags] to organise tests. Even though XCTest
  does not interact with tags, this is beyond the scope of interoperability
  because XCTest doesn't have existing “tag-like” behaviour to map onto.

Here are some concrete examples:

| When running a XCTest test...                | Current         | Proposed (default)       | Proposed (strict) |
| -------------------------------------------- | --------------- | ------------------------ | ----------------- |
| `#expect` failure is a ...                   | ‼️ No-op        | ❌ Test Failure          | ❌ Test Failure   |
| `#expect` success is a ...                   | No-op           | No-op                    | No-op             |
| `withKnownIssue` wrapping `XCTFail` is a ... | ❌ Test Failure | ⚠️ Runtime Warning Issue | 💥 Crash          |

### Interoperability Modes

The default interoperability surfaces test failures that were previously
ignored. We include two more permissible interoperability modes to avoid
breaking projects that are dependent on this pre-interop behaviour.

- **Warning-only**: This is for projects which do not want to see new test
  failures surfaced due to interoperability.

- **None**: Some projects may additionally have issue handling trait that
  promote warnings to errors, which means that warning-only mode could still
  cause test failures.

For projects that want to bolster their Swift Testing adoption, there is also an
opt-in strict interop mode.

- **Strict**: Warning issues included in the default mode can be easily
  overlooked, especially in CI. The strict mode guarantees that no XCTest API
  usage occurs when running Swift Testing tests by turning those warnings into a
  runtime crash.

Configure the interoperability mode when running tests using the
`SWT_XCTEST_INTEROP_MODE` environment variable:

| Interop Mode | Issue behaviour across framework boundary    | `SWT_XCTEST_INTEROP_MODE`                   |
| ------------ | -------------------------------------------- | ------------------------------------------- |
| Off          | ‼️ No-op (status quo)                        | `off`                                       |
| Warning-only | ⚠️ Runtime Warning Issue                     | `warning`                                   |
| Default      | ❌ Test Failure and ⚠️ Runtime Warning Issue | `default`, or empty value, or invalid value |
| Strict       | 💥 Crash                                     | `strict`                                    |

### Phased Rollout

When interoperability is first available, "default" will be the interop mode
enabled for new projects. In a future release, "strict" will become the default
interop mode.

## Source compatibility

As the main goal of interoperability is to change behaviour, this proposal will
lead to situations where previously "passing" test code now starts showing
failures. We believe this should be a net positive if it can highlight actual
bugs you would have missed previously.

You can use `SWT_XCTEST_INTEROP_MODE=off` in the short-term to revert back to
the current behaviour. Refer to the "Interoperability Modes" section for a full list
of options.

## Integration with supporting tools

Interoperability will be first available in future toolchain version,
hypothetically named `6.X`, where default interop mode will be enabled for
projects. After that, a `6.Y` release would make strict interop mode the
default.

- Swift Package Manager projects: `swift-tools-version` declared in
  Package.swift will be used to determine interop mode, regardless of the
  toolchain used to run tests.

- Xcode projects: Installed toolchain version will be used to determine interop
  mode.

- Any project can use `SWT_XCTEST_INTEROP_MODE` to override interop mode at
  runtime, provided they are on toolchain version `6.X` or newer

## Future directions

There's still more we can do to make it easier to migrate from XCTest to Swift
Testing:

- Provide fixups at compile-time to replace usage of XCTest API with the
  corresponding Swift Testing API, e.g. replace `XCTAssert` with `#expect`.
  However, this would require introspection of the test body to look for XCTest
  API usage, which would be challenging to do completely and find usages of this
  API within helper methods.

- After new API added to SWT in future, will need to evaluate for
  interoperability with XCTest until strict mode is the default. "strict" is
  kind of saying "from this point forward, no new interop will be added" for new
  SWT features.

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
lossy without interop APIs, and decided to prioritise the current default as a
good balance between notifying users yet not breaking existing test suites.

## Acknowledgments

Thanks to Stuart Montgomery, Jonathan Grynspan, and Brian Croom for feedback on
the proposal.

[unconditional failure]: https://developer.apple.com/documentation/xctest/unconditional-test-failures
[runtime warning issues]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0013-issue-severity-warning.md
[expected failures]: https://developer.apple.com/documentation/xctest/expected-failures
[issue handling traits]: https://developer.apple.com/documentation/testing/issuehandlingtrait
[test cancellation]: https://forums.swift.org/t/pitch-test-cancellation/81847
[traits]: https://swiftpackageindex.com/swiftlang/swift-testing/main/documentation/testing/traits
[tags]: https://swiftpackageindex.com/swiftlang/swift-testing/main/documentation/testing/addingtags
[exit testing]: https://developer.apple.com/documentation/testing/exit-testing
