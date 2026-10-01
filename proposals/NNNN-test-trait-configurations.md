# [Draft] SwiftPM: declaring trait configurations for test targets for easier testing

Proposal: [SE-NNNN](https://github.com/swiftlang/swift-evolution/blob/main/proposal-templates/NNNN-filename.md)
Authors: [Om Chachad](https://github.com/OmChachad)
Review Manager: TBD
Status: Pitch on Swift Forums
Implementation: [Implementation](https://github.com/swiftlang/swift-package-manager/pull/10480)

## Introduction 

Traits have been a great recent addition to the Swift Package Manager, but when it comes to running unit tests that rely on non-default trait configurations, you'll end up with tests that either fail or cannot compile. This pitch is largely based on proposals from [this forums thread](https://forums.swift.org/t/how-to-test-package-traits/78039). Thanks to @CharlesS and @Cyberbeni for the initial direction and to @FranzBusch and @bripeticca for their inputs on my suggestions!

P.S. This is also my first ever proposal. I'm a part of the Swift Mentorship Program for 2026, and I am very excited to contribute and hear from you! Thanks to @kukushechkin for his guidance throughout the process :)

## Motivation

Currently, if a test target tests the output of a function that is gated by a specific non-default trait combination, it will end up failing tests. Consider a package with two traits, where `SomeTrait` is a default trait and `AnotherTrait` is not:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MyPackage",
    traits: [
        .default(enabledTraits: ["SomeTrait"]),
        "SomeTrait",
        "AnotherTrait",
    ],
    targets: [
        .target(name: "MyLibrary"),
        .testTarget(name: "MyLibraryTests", dependencies: ["MyLibrary"]),
    ]
)
```

```swift
// Sources/MyLibrary/MyLibrary.swift
public struct MyLibrary {
    public init() {}

    public var isSomeTraitEnabled: Bool {
        #if SomeTrait
        true
        #else
        false
        #endif
    }

    #if AnotherTrait
    /// This API only exists when the `AnotherTrait` trait is enabled.
    public func anotherTraitOnlyAPI() -> String { "enabled" }
    #endif
}
```

A test for the trait-gated API doesn't even compile under the default configuration, and a test for trait-dependent behavior compiles but fails:

```swift
// Tests/MyLibraryTests/MyLibraryTests.swift
@Test func anotherTraitOnlyAPI() {
    // error: value of type 'MyLibrary' has no member 'anotherTraitOnlyAPI'
    // ('AnotherTrait' isn't a default trait, so this doesn't compile under `swift test`)
    #expect(MyLibrary().anotherTraitOnlyAPI() == "enabled")
}

@Test func someTraitDisabled() {
    // Compiles, but fails under `swift test` because 'SomeTrait' is a default trait.
    #expect(!MyLibrary().isSomeTraitEnabled)
}
```

You have to run `swift test` with each trait combination manually to have complete test coverage for the package:

```console
$ swift test                                          # default traits
$ swift test --traits AnotherTrait                    # AnotherTrait only
$ swift test --traits defaults,AnotherTrait           # defaults + AnotherTrait
$ swift test --disable-default-traits                 # nothing enabled
```

This enumeration usually ends up living in a CI script rather than in the package itself, where it’ll go outdated as traits evolve, and a contributor who’d run a plain `swift test` locally still sees failures for any test target that’s not dependent on a default trait.

You might also try to define multiple tests that are `#if` gated at the top level for a specific trait combination, and then run this with `swift test --enable-all-traits`:

```swift
#if SomeTrait && !AnotherTrait
@Suite struct SomeTraitOnlyTests { /* ... */ }
#endif

#if AnotherTrait && !SomeTrait
@Suite struct AnotherTraitOnlyTests { /* ... */ }
#endif
```

This, however, leads to a lot of duplicate tests and fails to evaluate the case where traits A+B and A+C both do different things when combined, because enabling all traits would have A, B, and C enabled at the same time — the `A+B`-only and `A+C`-only behaviors are never exercised, and both `#if` blocks above simply vanish from the build. The proposed `—-all-trait-combinations` flag in the original traits proposal would solve this, but will cause the other issue of building trait combinations that are never even used, especially for packages with a lot of traits since it would grow exponentially.

Without `#if` gating, even the `swift test --traits` approach will end up in a lot of errors being thrown at your face, since every test target is built under every invocation regardless of which traits it actually needs.

## Proposed solution

The best solution to this problem is to automate the process of running `swift test` for all known trait combinations that you would otherwise perform by hand. Since the package author is likely familiar with all possible valid combinations of traits in their package, defining at the manifest level all the trait configurations that a given test target is valid for, or intends on testing, will allow us to run multiple builds for each valid trait configuration and test the corresponding tests per build. This is done when the `--enable-trait-configurations` flag is passed to `swift test`.

Declaring configurations on the test targets looks like this:

```swift
targets: [
    .target(name: "MyLibrary"),
    .testTarget(
        name: "DefaultTraitsTests",
        dependencies: ["MyLibrary"],
        traitConfigurations: [.default]
    ),
    .testTarget(
        name: "AnotherTraitTests",
        dependencies: ["MyLibrary"],
        traitConfigurations: [
            .enabledTraits(["AnotherTrait"]),
            .enabledTraits(["SomeTrait", "AnotherTrait"]),
        ]
    ),
    .testTarget(
        name: "AllTraitsTests",
        dependencies: ["MyLibrary"],
        traitConfigurations: [.enableAllTraits]
    ),
]
```

A single invocation then runs every declared configuration, building and running only the test targets that declared each one:

```console
$ swift test --enable-trait-configurations
Running tests with default traits
Test Suite 'DefaultTraitsTests' passed
Running tests with traits: AnotherTrait
Test Suite 'AnotherTraitTests' passed
Running tests with traits: AnotherTrait, SomeTrait
Test Suite 'AnotherTraitTests' passed
Running tests with all traits enabled
Test Suite 'AllTraitsTests' failed

Tests failed for 1 of 4 trait configurations: all traits enabled
```

This reduces friction for testing all your traits, reduces the overhead of `#if`-gating test targets, and allows you to focus on the outcome of the tests rather than figuring out how to run them. Because each test target is only built under the configurations it declared, trait-gated tests like `testAnotherTraitOnlyAPI` above simply never get compiled under configurations where they can't compile.

## Detailed design

### Manifest API

A new `traitConfigurations` parameter is added to `.testTarget`, alongside a `Target.TraitConfiguration` type that mirrors the states a trait configuration can take:

```swift
extension Target {
    /// A configuration of the package's traits that a test target declares
    /// support for.
    ///
    /// A test target can declare the trait configurations under which its
    /// tests are expected to run, allowing the package manager to run the
    /// tests once per declared configuration.
    @available(_PackageDescription, introduced: 6.4)
    public struct TraitConfiguration: Hashable, Sendable {
        /// The package's default traits.
        public static let `default`: TraitConfiguration

        /// A configuration with all of the package's traits enabled.
        public static let enableAllTraits: TraitConfiguration

        /// A configuration with all of the package's traits disabled,
        /// including the default traits.
        public static let disableAllTraits: TraitConfiguration

        /// A configuration with the given set of traits enabled.
        ///
        /// The default traits aren't implicitly enabled; include them in the
        /// set to enable them.
        public static func enabledTraits(_ traits: Set<String>) -> TraitConfiguration
    }

    @available(_PackageDescription, introduced: 6.4)
    public static func testTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil,
        traitConfigurations: [TraitConfiguration]? = nil
    ) -> Target
}
```

The parameter is validated during manifest loading:

- `traitConfigurations` is only accepted on test targets; declaring it on any other target type is a manifest error.
- An explicitly empty array is a manifest error — a test target must declare at least one configuration when the parameter is specified.
- `.enabledTraits([])` normalizes to `.disableAllTraits`, matching the semantics of passing an empty trait set on the command line today.
- Omitting the parameter (`nil`) means the target declares nothing

Internally, the declared configurations are represented by SwiftPM's existing `TraitConfiguration` model — the same one that backs `--traits`, `--enable-all-traits`, and `--disable-default-traits` so the manifest API introduces no new trait semantics, only a way to spell the existing ones per test target.

### Execution model

Without `--enable-trait-configurations`, `swift test` behaves exactly as it does today, and any `traitConfigurations` declarations are inert.

With the flag, `swift test`:

1. Inspects all test targets of the root packages. A test target that declares no configurations is treated as if it declared `[.default]`, so it runs once under the package's default traits, the same behavior it has today.
2. Collects the unique configurations across all test targets. Two configurations are the same if they are semantically equal (`.enabledTraits(["A", "B"])` and `.enabledTraits(["B", "A"])` are one configuration).
3. Orders the configurations by their first declaration, following manifest declaration order. The run order is therefore deterministic and entirely under the package author's control.
4. For each configuration, in order: resolves and builds the package with that trait configuration, building **only the test products of the targets that declared it**, then runs only those test targets. Each test target builds as its own test product, which is what makes selective building and running possible. Test target is never compiled under a configuration it didn't declare, so trait-gated test code needs no `#if` gating.
5. A failing configuration does not stop the matrix. The remaining configurations still build and run, a summary reports which configurations failed, and the overall invocation exits non-zero if any configuration failed:

```console
Tests failed for 1 of 4 trait configurations: all traits enabled
```

### Build directories

Trait configurations affect the flags of essentially every compile command, so configurations built into a shared build directory would invalidate each other's incremental state on every run. To keep repeated matrix runs incremental, each non-default configuration builds into its own sibling build directory, named by appending a suffix to the regular one:

```
.build/
├── out                     ← default configuration (the regular build directory)
├── out+all-traits          ← .enableAllTraits
├── out+no-traits           ← .disableAllTraits
├── out+traits-AnotherTrait-SomeTrait  ← .enabledTraits(["SomeTrait", "AnotherTrait"]), names sorted
└── checkouts, artifacts, …     ← shared caches, unaffected
```

The `.default` configuration deliberately has no suffix: it shares the regular build directory, so the most common configuration stays warm with your ordinary `swift build` and `swift test` invocations. Dependency checkouts, downloaded artifacts, and registry caches are shared across all configurations as they are today. This isolation is scoped to matrix runs; regular invocations with `--traits` continue to use the regular build directory.

In practice this makes a second matrix run over an unchanged package near-instant: in my testing, a two-configuration package went from 27 seconds (first run, both configurations built from scratch) to 4 seconds on the following run.

### Build system support

The feature requires building one test product per test target. The older native build system currently cannot do this, so `--enable-trait-configurations` reports a clear error under `--build-system native`.

## Impact on existing packages

Everything added here is only accessible via the `--enable-trait-configurations` flag. Without this opt-in flag, everything will continue to work as it did before. Manifests that adopt the new `traitConfigurations` parameter require the corresponding tools version; existing manifests are unaffected, and the serialized manifest representation treats the new field as optional, so previously-compiled manifests continue to load. The build directory isolation has also currently been scoped to the flag; however, it can be expanded across SwiftPM if found appropriate.

## Future directions

The original package traits proposal, SE-0450, mentions a `swift test/build/run` flag for package authors called `--all-trait-combinations` in its future directions. @bripeticca, on the same forums thread from earlier, came up with an idea to scope this to a specific set of traits when testing a particular test target, so instead of doing all trait combinations, it would do all combinations of A, B, and C. This has been created as [#10493](https://github.com/swiftlang/swift-package-manager/issues/10493) on swift-package-manager. While this suggestion was for the CLI flag, this can be extended to our `traitConfigurations` parameter.

An `.allCombinationsOf([String])` case could be added to the existing options offered by `TraitConfiguration`. This would only be a part of the manifest-facing type and would act as a generator that expands into plain trait configurations while the manifest is being parsed. This offers a useful tool that can reduce further manual enumeration in some cases, where you would otherwise end up manually listing different combinations of a subset of your package's traits.

## Security

This proposal has no impact on security, safety, or privacy. It adds no new inputs beyond the package's own manifest and runs the same build and test pipeline that `swift test` runs today, once per declared configuration.

## Alternatives considered

Initially, the approach I considered used a `configurations` parameter on the entire `Package` that would let you define all known valid trait combinations for the package; however, I realized it would not provide significant benefits and would be confusing for someone new to traits.

Similar to what @CharlesS's first comment had, I also experimented with an `enabledTraits` parameter which took a set of traits as input. However, realizing that the same test could be worth testing for more than one set of traits, I modified it to accept an array of sets of traits. This largely worked, but I found building off of the existing `TraitConfiguration` model to be the most robust solution yet, because it easily allows expressing the `.default` or `.enableAllTraits` cases without manually enlisting the traits and provides a cleaner approach to this parameter.

Automatically testing every combination of a package's traits, without any declarations was also considered. This doesn't scale: a package with *n* traits has 2ⁿ combinations, many of which aren't valid or meaningful, and each one is a full build. Declaring the combinations that matter keeps the cost proportional to what the author actually wants covered, which is also why the scoped `.allCombinationsOf` generator above is a future direction rather than the core design.