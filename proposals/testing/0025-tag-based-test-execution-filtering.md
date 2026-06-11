# Tag-based Test Execution Filtering

- Proposal: [ST-0025](0025-tag-based-test-execution-filtering.md)
- Authors: [Gustavo Medori](https://github.com/gmedori)
* Review Manager: [Paul LeMarquand](https://github.com/plemarquand)
* Status: **Active Review (Jun 11 - June 26, 2026)**
- Bugs: [swiftlang/swift-testing#591](https://github.com/swiftlang/swift-testing/issues/591), rdar://132989780
- Implementation: [swiftlang/swift-testing#1531](https://github.com/swiftlang/swift-testing/pull/1531)
- Review: [pitch](https://forums.swift.org/t/pitch-tag-based-test-execution-filtering/86001)

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

During local development, you may want to skip all UI tests across all your test packages. With current tooling, this isn't possible unless you have a consistent naming scheme for your UI tests across all your packages that doesn't overlap with any other tests — a tall order in larger codebases. For this purpose, it is clear that we need a better, user-defined, way of grouping tests together outside of the test graph.

Additionally, it's worth noting that existing tools that support filtering by tags (like the Visual Studio Code plugin) do so by using the SourceKit index to search for tags and then collecting the test IDs that match those tags into a [giant regular expression](https://github.com/swiftlang/vscode-swift/blob/f56817494c1ea989dbeec894896be98dd8e25c8a/src/TestExplorer/TestRunArguments.ts#L99-L118). Adding a native ability to filter by tag would simplify this implementation (and that of any other tools hoping to implement the same).

## Proposed Solution

I propose we introduce a special syntax to the `--filter` and `--skip` command line options. When you want to filter or skip tests by providing a tag, you will prefix the argument with `tag:`. 

## Detailed Design

### Basic Usage
 
As they currently exist, the `--filter` and `--skip` command line options accept regular expressions as arguments. Reiterating the above, I propose enhancing these arguments to accept a special case: an exact tag name prefixed by `tag:`. For example:

```
swift test --skip tag:uiTest
```

In this example, `uiTest` is a regular expression that matches the tags that you want to filter/skip on. As with regular usages of `--filter`/`--skip`, you can supply the option multiple times to filter/skip tests which match _any_ of the tags:

```
swift test --skip tag:uiTest --skip tag:integrationTest
```

It is not currently possible to create a filter/skip based on _all_ tags specified, as opposed to _any_ of the tags specified. In other words, supplying multiple `--filter`/`--skip` options is an **or** operation, not an **and** operation.

### Handling Raw Identifiers
 
As of [SE-0451](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0451-escaped-identifiers.md), Swift has raw identifiers which means the following is valid Swift:

```swift
@Test func `tag:uiTest`() { /* ... */ }
```

To continue to allow matching for such function names, I propose introducing a _separate_ prefix called `id:` which behaves much like the `tag:` prefix in that everything that follows it is a regular expression. Its job, however, is to disambiguate and allow the user a mechanism to explicitly say "match on test symbol names please." 

```sh
swift test --skip 'id:tag:uiTest'
```

The `id:` prefix doesn't introduce any new behavior. In fact, its behavior is the entirety of what Swift Testing supports today. However, we wanted a flexible way to disambiguate raw identifiers that also left the door open for other filtering/skipping mechanisms in the future.

It will still be possible to omit the prefix entirely. So long as none of the known prefixes are present, we will assume matching by `id:`.

With respect to raw identifiers, the converse here also applies. It is possible to apply a tag that uses a raw identifier as its name. For example:

```swift
extension Tag {
    @Tag static var `some tag with spaces`: Self
}

@Test(.tags(.`some tag with spaces`))
func myTest() { /* ... */ }
```

In this scenario, you would wrap the argument in single quotes and the entirety of the text supplied after the `tag:` prefix would be interpreted the name of a single tag. So for a tag named `some tag with spaces`, you could filter for it as follows:

```sh
swift test --filter 'tag:some tag with spaces'
```

It's reasonable to expect some developers to attempt that filter by including the backticks used to delimit the symbol name for a raw identifier like so:

```sh
swift test --filter 'tag:`some tag with spaces`' # INVALID: This wouldn't match the symbol.
```

Backticks are not part of the symbol name of a raw identifier, so this filter wouldn't match anything. I believe it's reasonable to suggest that if some filter the user provides is surrounded by backticks (i.e. more precisely, it matches the regex ```/^`[^`]*`$/```), then we can be reasonably sure the user means a raw identifier, and we should supply an error message and strip them for the user:

```
Backticks aren't a valid part of a Swift symbol. Replacing '`some tag with spaces`' with 'some tag with spaces'.
```

## Source Compatibility

If a codebase has test functions or suites that contain the string `tag:`, then any filtering/skipping arguments that begin with `tag:` behave differently with this proposal. They are treated as tags rather than regular expressions.

It's worth noting that string `tag:` can only appear in symbol names when using raw identifiers as described above. I feel that this scenario is relatively rare and that this improvement is worth the edge case.

## Integration with Supporting Tools

This introduces a new mechanism that can be used by any existing tools to filter/skip based on tags, and has the same backwards compatibility concerns associated with the source compatibility section above. That is, if a tool that calls `swift test` is filtering/skipping for a test with a name containing `tag:`, this will cause unexpected behavior. Otherwise, this change is additive.

## Future Directions

Filtering based on tags is quite broad and general purpose. Because you can define any tag to stick on any test or suite, and because tags exist orthogonally to the test graph, you can arbitrarily include/skip any test based solely on the semantics of your tags. However, this change does raise the question of what _else_ we could filter/skip on and how we can be more expressive about it.

For example, you may wish to filter/skip tests based on protocol conformance and/or inheritance. A suite's ancestor types can be a useful, and perhaps more natural, signal indicating whether it should run in a given context or not because the ancestor types carry with them behaviors and contracts that have powerful semantic meaning. In the future, we may seek to expand the prefix operators we allow beyond just `tag:`.

Additionally, internally, the test suite already supports arbitrary boolean groupings of test filters. It may not be unreasonable to attempt to expose that on the CLI.

## Alternatives Considered

An alternate path is to create a separate command line option for filtering and skipping by tags. For example:

```
swift test --skipTag uiTest
```

This approach may seem simpler, and indeed one important advantage is that we would forgo the need to have a well-defined syntax for filtering/skipping if we decide to enhance it further. However, it has a few disadvantages:

1. We would need to make changes to the ABI between SwiftPM and Swift Testing.
2. A separate flag means a separate line in the `--help` text, making it easier to miss that filtering/skipping based on tags is possible.
3. The implementation would be more complex, requiring changes across both [swiftlang/swift-testing](https://github.com/swiftlang/swift-testing) and [swiftlang/swift-package-manager](https://github.com/swiftlang/swift-package-manager). More code = more bugs, on average.

The main advantage is that we wouldn't need to handle escaping the colon character, and that didn't seem like a big enough benefit to warrant the disadvantages.

## Acknowledgments

TBD
