# Piecemeal adoption of future language improvements

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#59055](https://github.com/apple/swift/pull/59055)

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

Swift 6 is accumulating a number of improvements to the language that have enough source-compatibility impact that they could not be enabled by default in prior language modes (Swift 4.x and Swift 5.x). These improvements are already implemented in the Swift compiler behind the Swift 6 language mode, but they are inaccessible to users, and will remain so until Swift 6 becomes available as a language mode. There are several reasons why we should consider making these improvements available sooner:

* Developers would like to get the benefits from these improvements soon, rather than wait until Swift 6 is available.
* Making these changes available to developers prior to Swift 6 provides more experience, allowing us to tune them further for Swift 6 if necessary.
* The sum of all changes made in Swift 6 might make migration onerous for some modules, and adopting these language changes one-by-one while in Swift 4.x/5.x can smooth that transition path.

A few proposals have already introduced bespoke solutions to provide a migration path: [SE-0337](https://github.com/apple/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md) adds `-warn-concurrency` to enable warnings for `Sendable`-related checks in Swift 4.x/5.x. [SE-0354](https://github.com/apple/swift-evolution/blob/main/proposals/0354-regex-literals.md) adds the flag `-enable-bare-slash-regex` to enable the bare `/.../` regular expression syntax. And although it wasn't part of the proposal, the discussion of [SE-0335](https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md) included requests for a compiler flag to require `any` on all existentials. These all have the same flavor, of opting existing Swift 4.x/5.x code into improvements that will come in Swift 6.

This proposal explicitly embraces the piecemeal, intentional adoption of features that were held until Swift 6 for source-compatibility reasons. It establishes a direct path to incrementally adopt Swift 6 features, one-by-one, to gain their benefits in a Swift 4.x/5.x code base and smooth the migration path to a Swift 6 language mode. Developers can use a new compiler flag, `-enable-future-feature X` to enable the specific feature named `X` for that module, and multiple features can be specified in this manner. When the developer moves to the next major language version, `X` will be implied by that language version and the compiler flag will be rejected. This way, future feature flags only accumulate up to the next major Swift language version and are then cleared away, so we don't fork the language into incompatible dialects.

Swift-evolution thread: [Pitch #1](https://forums.swift.org/t/piecemeal-adoption-of-swift-6-improvements-in-swift-5-x/57184)

## Proposed solution

Introduce a compiler flag `-enable-future-feature X`, where `X` is a name for the feature to enable. Each proposal will document what `X` is, so it's clear how to enable that feature. For example, SE-0274 could use `ConciseMagicFile`, so that `-enable-future-feature ConciseMagicFile` will enable that change in semantics. One can of course pass multiple `-enable-feature` flags to the compiler to enable multiple features. 

Unrecognized future features will be ignored by the compiler. This allows older tools to use the same command lines as newer tools for Swift code that has started adopting new features, but has appropriate workarounds to still work with older tools. Sometimes this is possible because older compilers will still have a reasonable interpretation of the code, other times one will need a way to [detect features in source code][#feature-detection-in-source-code], the subject of a later section.

All "future" features are enabled by default in some language version. The compiler will produce an error if `-enable-future-feature X` is provided and the language version enables the feature `X` by default. This will make it clear to developers when their expectations about when a feature is available, and clean up projects and manifests that have evolved from from earlier language versions, adopted features piecemeal, and then moved to later language versions.

### Proposals define their own feature identifier

Amend the [Swift proposal template](https://github.com/apple/swift-evolution/blob/main/proposal-templates/0000-swift-template.md) with a new, optional field that defines the feature identifier:

* **Feature identifier**: UpperCamelCaseFeatureName

Amend the following proposals, which are partially or wholly delayed until Swift 6, with the following feature identifiers:

* [SE-0274 "Concise magic file names"](https://github.com/apple/swift-evolution/blob/main/proposals/0274-magic-file.md) (`ConciseMagicFile`) delayed the semantic change to `#file` until Swift 6. Enabling this feature changes `#file` to mean `#fileID` rather than `#filePath`.
* [SE-0286 "Forward-scan matching for trailing closures"](https://github.com/apple/swift-evolution/blob/main/proposals/0286-forward-scan-trailing-closures.md) (`ForwardTrailingClosures`) delays the removal of the "backward-scan matching" rule of trailing closures until Swift 6. Enabling this feature remove the backward-scan matching rule.
* [SE-0335 "Introduce existential `any`"](https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md) (`ExistentialAny`) delays the requirement to use `any` for all existentials until Swift 6. Enabling this feature requires `any` for existential types.
* [SE-0337 "Incremental migration to concurrency checking"](https://github.com/apple/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md) (`StrictConcurrency`) delays some checking of the concurrency model to Swift 6 (with a flag to opt in to warnings about it in Swift 5.x). Enabling this feature is equivalent to `-warn-concurrency`, performing complete concurrency checking.
* [SE-0352 "Implicitly Opened Existentials"](https://github.com/apple/swift-evolution/blob/main/proposals/0352-implicit-open-existentials.md) (`ImplicitOpenExistentials`) expands implicit opening to more cases in Swift 6, because we didn't want to change the semantics of well-formed code in Swift 5.x. Enabling this feature performs implicit opening in these additional cases.
* [SE-0354 "Regex Literals"](https://github.com/apple/swift-evolution/blob/main/proposals/0354-regex-literals.md) (`BareSlashRegexLiterals`) delays the introduction of the `/.../` regex literal syntax until Swift 6. Enabling this feature is equivalent to `-enable-bare-regex-syntax`, making the `/.../` regex literal syntax available. If this proposal and SE-0354 are accepted in the same release, `-enable-bare-regex-syntax` can be completely removed in favor of this approach.

### Swift Package Manager support for future features

SwiftPM targets should be able to specify the future language features they require. Extend the `target` part of the manifest to take a set of future features as strings, e.g.:

```swift
.target(name: "myPackage",
        futureFeatures: ["ConciseMagicFile", "ExistentialAny"])
```

SwiftPM would then pass each of the future features listed there to the compiler via the  `-enable-future-feature` flag when building the module for this target. Other targets that depend on this one do not need to pass the features when they build, because the effect of future features does not cross module boundaries.

The features are provided as strings here so that SwiftPM's manifest format doesn't need to change each time a new feature is added to the compiler. Package authors can add to the `futureFeatures` list while still supporting older tools without creating a new, versioned manifest.

### Feature detection in source code

When adopting a new feature, it's common to want code to still compile with older tools where that feature is not available. Doing so requires a way to check whether the feature is enabled, either by `-enable-future-feature` or by enabling a suitable language version.

We should extend Swift's `#if` with explicit support for a `hasFeature(X)` check, which evaluates true whenever the feature with identifier `X` is available. Code that needs to check for a specific feature can use `#if hasFeature` like this:

```swift
#if hasFeature(ImplicitOpenExistentials)
  f(aCollectionOfInts)
#else
  f(AnyCollection<Int>(aCollectionOfInts))
#endif
```

The `hasFeature(X)` check indicates the presence of features, but by itself an older compiler will still attempt to parse the `#if` branch even if the feature isn't known. That's fine for this feature (implicitly opened existentials) because it doesn't add any syntax, but other features that add syntax might require something more. `hasFeature` can be composed with the `compiler` directive introduced by [SE-0212](https://github.com/apple/swift-evolution/blob/main/proposals/0212-compiler-version-directive.md), e.g.,

```swift
#if compiler(>=5.7) && hasFeature(BareSlashRegexLiterals)
let regex = /.../
#else
let regex = try NSRegularExpression(pattern: "...")
#endif
```

There is in issue with the above, because `hasFeature` *itself* is not understood by tools that predate this proposal, so the code above will fail to compile on with any Swift compiler that predates the introduction of `hasFeature`. It is possible to avoid this problem by nested the `hasFeature` check like this (assuming that Swift 5.7 introduced `hasFeature`):

```swift
#if compiler(>=5.7)
  #if hasFeature(BareSlashRegexLiterals)
  let regex = /.../
  #else
  let regex = #/.../#
  #endif
#else
let regex = try NSRegularExpression(pattern: "...")
#endif
```

In the worst case, this does involve some code duplication for libraries that need to work on Swift versions that predate the introduction of `hasFeature`, but it is possible to handle those compilers, and over time that limitation will go away.

To prevent this issue for any future extensions to the `#if` syntax, the compiler should interpret the "call" syntax to an unknown function as if it always evaluated false. That way, if we invent something like `#if hasAttribute(Y)` in the future, one can use

```swift
#if hasAttribute(Sendable)
...
#endif
```

and the `#if` condition will evaluate to `false` on any compiler that doesn't understand the `hasAttribute` check. This is similar in spirit to how C compilers introduce checks like [`__has_feature`](https://clang.llvm.org/docs/LanguageExtensions.html#has-feature-and-has-extension), where one can use the C preprocessor to define a function-like macro for compilers that don't support the feature-checking mechanism.

### Embracing experimental features

It is common for language features in the compiler to be staged in behind an "experimental" flag as they are developed. This is usually done in an ad hoc manner, and the flag is removed before the feature finally ships. However, we should embrace the experimental feature model further: when a feature is under development, provide it with a feature identifier that allows it to be enabled with a new flag, `-enable-experimental-feature X`, or its SwiftPM counterpart `experimentalFeatures`.

Experimental features are still to be considered unstable, and should not be available in released compilers. However, by unifying the manner in which experimental and future features are introduced, we can rely on the same staging mechanisms: a way to enable the feature and to check for its presence in source code, making it easier to experiment with these features. If a feature then "graduates" to a complete, supported language feature, `hasFeature` can return true for it and, if part of it was delayed until the next major language version, `-enable-future-feature` will work with it, too. 

## Source compatibility

For the language itself, `hasFeature` is the only addition, and it occurs in a constrained syntactic space (`#if`) where there are no user-definable functions. Therefore, there is no source-compatibility issue in the traditional sense, where a newer compiler rejects existing, well-formed code. 

For SwiftPM, the addition of the `futureFeatures` parameter represents a one-time break in the manifest file format. Packages that wish to adopt this parameter and support tools versions that predate the introduction of `futureFeatures` can use versioned manifest, e.g., `Package@swift-5.6.swift`, to adopt the feature for newer tools versions. Once `futureFeatures` has been added, adopting additional features this way won't require another copy of the manifest format.

## Alternatives considered

### `$X` instead of `hasFeature(X)`

The original pitch for this proposal used special identifiers `$X` for feature detection instead of `hasFeature(X)`. `$X` has been used in the compiler implementation to help stage in Swift's concurrency features, especially when producing Swift interface files that might need to be understood by olde tools versions. The compiler still defines `$AsyncAwait`, for example, which can be used with  `#if` to check for async/await support:

```swift
#if compiler(>=5.3) && $AsyncAwait
func f() async -> String
#endif
```

The primary advantage to the `$` syntax is that all Swift compilers already treat `$` as an acceptable leading character for an identifier. The compiler can define names with a leading `$`, but developers aren't technically supposed to, so it's effectively a reserved space for "magic" names. This means that, unlike the `hasFeature` formulation of the above, older compilers can process the code above without producing an error.

However, this proposal introduces `hasFeature` because it's a clearer in the code, and makes the forward-looking changes to the way `#if` conditions are processed to make it easier for additional `hasFeature`-like features to be introduced in the future without having this problem with older compilers.

### Enabling optional features

This proposal narrowly introduces `-enable-future-feature` to only describe accepted features that will be enabled with a newer language version, but that were held back (partially or in full) due to source compatibility concerns. It is not meant to be used to enable "optional" features, which would create permanent dialects, and is designed to be somewhat self-healing: as folks move to newer language modes (e.g., Swift 6), the future feature flags are eliminated with the new baseline.

## Acknowledgments

Becca Royal-Gordon designed the original `#if compiler(>=5.5) && $AsyncAwait` approach to adopting features without breaking compatibility with older tools, and helped shape this design.
