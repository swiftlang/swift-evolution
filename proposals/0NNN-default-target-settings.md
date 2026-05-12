# Default Target Settings

* Proposal: [SE-0NNN](0NNN-default-target-sesttings.md)
* Authors: [Matt Massicotte](https://github.com/mattmassicotte)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swiftlang/swift-package-manager#10033](https://github.com/swiftlang/swift-package-manager/pull/10033)
* Review: ([pitch](https://forums.swift.org/t/default-package-swift-settings/71872))

## Introduction

It is very common for packages to using the same settings flags across all their targets.
A built-in mechanism to apply these base settings
offers improved readability and convenience for package manifests.

## Motivation

The default SwiftPM package template generates a manifest with two targets: primary and test.
There are many examples of packages that go far beyond this default of two,
but single-target packages are quite rare.

That same default template, as of Swift 6.4,
also includes the same setting for both of these targets.
Here's snippet of the code:

```swift
let package = Package(
  // ...
  targets: [
    .target(
      name: "MyPackage",
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency"),
      ],
    ),
    .testTarget(
      name: "MyPackageTests",
      dependencies: ["MyPackage"],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency"),
      ],
    ),
  ]
)
```

This pattern comes up over and over again across the package ecosystem.
Selectively adopting upcoming language features across all targets is very common.
For the prototypical primary-test target pair,
duplicating one or two settings might not be ideal, but it is feasible.
For packages with many targets and/or complex manifest files,
it came become quite challenging to reason about the setting being applied.

A common solution involves applying a constant array to each target.
This is sufficient as long as all targets use identical settings.
But, if a package author does happen to need slightly different settings for even
one target, additional logic needs to be introduced.

```swift
let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
  // ...
  targets: [
    .target(
      name: "MyPackage",
      swiftSettings: swiftSettings + [.enableUpcomingFeature("Lifetimes")],
    ),
    .testTarget(
      name: "MyPackageTests",
      dependencies: ["MyPackage"],
      swiftSettings: swiftSettings,
    ),
  ]
)
```

These approaches are inconvenient, verbose, and error-prone.
And because of the subtleties that can arise from compiler behavior differences,
errors here can be particularly painful.

## Proposed solution

The desired configuration for the vast majority of package authors is the same.
Begin with a core list of settings that define baseline behaviors,
along with per-target refinements to that list, if needed.

The package manifest API should provide a way to express this directly.

## Detailed design

There are two core components to this change.
The first is the ability to define and apply a base list of settings.
The second is a well-defined and reasonable merging strategy to handle per-target overrides.

### Manifest APIs

The `Package` class is extended to define a set of default settings:

```swift
public final class Package {
  // ...

  public var defaultSwiftSettings: Set<SwiftSetting>
  public var defaultCSettings: Set<CSetting>
  public var defaultCXXSettings: Set<CXXSetting>
  public var defaultLinkerSettings: Set<LinkerSetting>

  public init(
    name: String,
    defaultLocalization: LanguageTag? = nil,
    platforms: [SupportedPlatform]? = nil,
    pkgConfig: String? = nil,
    providers: [SystemPackageProvider]? = nil,
    products: [Product] = [],
    traits: Set<Trait> = [],
    dependencies: [Dependency] = [],
    targets: [Target] = [],
    swiftLanguageVersions: [SwiftVersion]? = nil,
    defaultSwiftSettings: Set<SwiftSetting> = [],
    cLanguageStandard: CLanguageStandard? = nil,
    defaultCSettings: Set<CSetting> = [],
    cxxLanguageStandard: CXXLanguageStandard? = nil,
    defaultCXXSettings: Set<CXXSetting> = [],
    defaultLinkerSettings: Set<LinkerSetting> = []
  )
}
```

### Settings Resolution

It is important that it be possible to control defaults on a per-target basis.
There is a bit of subtly here because this merge operation requires some special logic.

Handling some of these is straightforward, because the setting can have only one possible value.
Examples of this are `interoperabilityMode`, `strictMemorySafety`, `swiftLanguageMode`, and `treatAllWarnings`.
In these cases, a value defined by the target takes precedence and can simply overwrite any default.

Other settings are used to form a set of possible values.
Here, forming a union of all values can often make intuitive sense.
An example of this would be `headerSearchPath`.
The default could be used to apply a common path to all targets,
and then additional paths could be added targets as needed.
This strategy can be used for `headerSearchPath`, `linkedLibrary`,
`linkedFramework`, `enableUpcomingFeature`, and `enableExperimentalFeature`.

A very similar approach can be used to merge the four settings that apply a named value.
The warnings controls work this way, and some examples can help visualize how it would work.

|: Default                         |: Target                        |: Resolved                        |
|----------------------------------|--------------------------------|----------------------------------|
| `.treatWarning("Foo", .warning)` | -                              | ["Foo": .warning]                |
| `.treatWarning("Foo", .warning)` | `.treatWarning("Foo", .error)` | ["Foo": .error]                  |
| `.treatWarning("Foo", .warning)` | `.treatWarning("Bar", .error)` | ["Foo": .warning, "Bar": .error] |
| `.enableWarning("Foo")`          | -                              | ["Foo": .warning]                |
| `.enableWarning("Foo")`          | `.disableWarning("Foo")        | []                               |
| `.disableWarning("Foo")`         | -                              | ["Foo": .disabled]               |
| `.disableWarning("Foo")`         | `.enableWarning("Foo")`        | ["Foo": .warning]                |

The `define` property presents more of a challenge.
The argument to this setting is not really a truly free-form string,
but any merging could require at least some parsing.

To side step this problem, `define` can be treated as a unconditional override.
It is true that this could potentially require some duplication across defaults and targets.
However, given the non-trivial nature, that seems much preferable to incorrect resolution.

Here's a summary of the strategies by setting type:

|: Setting                    |: Merge Strategy  |
|-----------------------------|------------------|
| `headerSearchPath`          | Union            |
| `define`                    | Union            |
| `linkedLibrary`             | Union            |
| `linkedFramework`           | Union            |
| `interoperabilityMode`      | Override         |
| `enableUpcomingFeature`     | Union            |
| `enableExperimentalFeature` | Union            |
| `strictMemorySafety`        | Override         |
| `unsafeFlags`               | Override         |
| `swiftLanguageMode`         | Override         |
| `treatAllWarnings`          | Override         |
| `treatWarning`              | Override by name |
| `enableWarning`             | Override by name |
| `disableWarning`            | Override by name |
| `defaultIsolation`          | Override by name |

### Adding Settings

This change does impose a constraint on any new settings types added to SwiftPM.
New settings must carefully consider and implement an appropriate merge strategy.

Given the breadth of existing settings, it seems likely that new settings will be able to use one of the existing approaches.
However, if it turns out that a reasonable merge is impossible,
a fallback should be to produce an error if such a conflict is detected.

## Source compatibility

Because this is a purely additive change,
there will be no impact on existing packages.

## ABI compatibility

This change does not have any effect on ABI.

## Implications on adoption

This change impacts manifest authors, but should have no effects at all on package consumers.
Authors will be able to adopt default settings freely without concern for compatibility.

## Future directions

The most obvious avenue for future work is more advanced merging strategies,
particularly for `define`.
Altering merging behavior, however, would be a source-incompatible change.

## Alternatives considered

?

## Acknowledgments

Max Desiatov provided some much-appreciated general guidance that helped get this idea off the ground. Boris G. immediately noticed and provided great feedback on the need for merging.
