# Tag-based Test Execution Filtering

- Proposal: [ST-NNNN](nnnn-tag-based-test-execution-filtering.md)
- Authors: [Gustavo Medori](https://github.com/gmedori)
- Review Manager: TBD
- Status: **Awaiting review**
- Implementation: [swiftlang/swift-testing#1531](https://github.com/swiftlang/swift-testing/pull/1531)
- Review: ([pitch (not yet live)](https://forums.swift.org/...))

## Introduction

Swift Testing currently provides the ability to annotate tests and suites with arbitrarily named tags. It also allows you to selectively run specific tests by matching them against a regex using the `--filter` and `--skip` command line options. I propose we join these two capabilities to allow for filtering or skipping tests based on any associated tags.

## Motivation

Tests come in all shapes and sizes, from narrowly-scoped unit tests, to integration tests that spin up live databases, to UI tests that can take a very long time to run. Depending on your needs, you might want to control which tests are run and when, rather than running your entire test suite every time with `swift test`. Swift Testing acknowledges this need by the existence of the `--filter` and `--skip` command line options, but these options fall short in certain scenarios.

Consider an iOS project where your UI code is spread across several targets (e.g. one target per "feature"). Suppose further that each of these targets has an associated test target with its own suite of tests. It could look something like this:

```
FoodTruck/
├── Package.swift
├── Sources/
│   ├── FoodDetailFeature/
│   ├── FoodListFeature/
│   ├── FoodTruck/
│   └── RootFeature/
└── Tests/
    ├── FoodDetailFeatureTests/
    ├── FoodListFeatureTests/
    ├── FoodTruckTests/
    └── RootFeatureTests/
```

During local development, you may want to skip all UI tests across all your test packages. With current tooling, this isn't possible unless you have a consistent naming scheme for your UI tests across all your packages that don't overlap with any other tests—a tall order in larger codebases. For this purpose, it is clear that we need a better, user-defined, way of grouping tests together outside of the test graph.

## Proposed Solution

I propose we introduce a special syntax to the `--filter` and `--skip` command line options. When you want to filter or skip tests by providing a tag, you will prefix the argument with `tag:`. 

## Detailed Design

### Basic Usage
 
 As they currently exist, the `--filter` and `--skip` command line options accept regular expressions as arguments. Reiterating the above, I propose enhancing these arguments to accept a special case: an exact tag name prefixed by `tag:`. For example:

```
swift test --skip tag:uiTest
```

In this example, `uiTest` must be the _exact_ name of the tag. Tags _will not_ match fuzzily or by regular expression. This treatment would be applied to both the `--filter` and `--skip` options.

As with regular usages of `--filter`/`--skip`, you can supply the option multiple times to filter/skip tests which match _any_ of the tags:

```
swift test --skip tag:uiTest --skip tag:integrationTest
```

It is not currently possible to create a filter/skip based on _all_ tags specified, as opposed to _any_ of the tags specified. In other words, supplying multiple `--filter`/`--skip` options is an **or** operation, not an **and** operation.

### Handling Raw Identifiers
 
 As of [SE-0451](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0451-escaped-identifiers.md), Swift has raw identifiers which means the following is valid Swift:

```swift
@Test func `tag:uiTest`() { /* ... */ }
```

To continue to allow matching for such function names, we will also allow the colon character to be escaped such that the entire argument will be treated as a single regular expression:

```
swift test --skip 'tag\:uiTest'
```

The example above would behave as though the string `tag:uiTest` were passed as a regular expression, omitting the escaping backslash in the final regular expression.

> **Note**: Most shells treat the backslash character `\` as a special character used for escaping. In order for the application to receive it, the argument needs to either be wrapped in quotes like `'tag\:uiTest'`, or the backslash itself needs to be escaped, `tag\\:uiTest`.

## Source Compatibility

The change is an implementation detail and makes no changes to source compatibility.

## Integration with Supporting Tools

If a codebase has test functions or suites that contain the string `tag:`, then any filtering/skipping arguments that begin with `tag:` behave differently with this proposal. They are treated as tags rather than regular expressions.

It's worth noting that string `tag:` can only appear in symbol names when using raw identifiers as described above. I feel that this scenario is relatively rare and that this improvement is worth the edge case.

## Future Directions

N/A

## Alternatives Considered

An alternate path is to create a separate command line option for filtering and skipping by tags. For example:

```
swift test --skipTag uiTest
```

While this approach may seem simpler, it has a few disadvantages:

1. We would need to make changes to the ABI between SwiftPM and Swift Testing.
2. A separate flag means a separate line in the `--help` text, making it easier to miss that filtering/skipping based on tags is possible.
3. The implementation would be more complex, requiring changes across both [swiftlang/swift-testing](https://github.com/swiftlang/swift-testing) and [swiftlang/swift-package-manager](https://github.com/swiftlang/swift-package-manager). More code = more bugs, on average.

The main advantage is that we wouldn't need to handle escaping the colon character, and that didn't seem like a big enough benefit to warrant the disadvantages.

## Acknowledgments

TBD
