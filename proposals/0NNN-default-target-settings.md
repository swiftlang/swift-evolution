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
The first is the ability to define and apply a base list of default settings.
The second is mechanism to control how these defaults apply on a per-target basis.

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

With this in place, the default package template could look like this:

```swift
let package = Package(
  // ...
  targets: [
    .target(
      name: "MyPackage"
    ),
    .testTarget(
      name: "MyPackageTests",
      dependencies: ["MyPackage"]
    ),
  ],
  defaultSwiftSettings: [
    .enableUpcomingFeature("ApproachableConcurrency"),
  ]
)
```

### Settings Inheritance

It is important that it be possible to control defaults on a per-target basis.
This is supported with a new `inherited` placeholder setting.
When setting are evaluated, this placeholder is substituted with the corresponding default values.

Here are four possible target configurations that demonstrate the functionality.

```swift
let package = Package(
  // ...
  targets: [
    .target(
      name: "A",
    ),
    .target(
      name: "B",
      swiftSettings: [
        .inherited(),
      ]
    ),
    .target(
      name: "C",
      swiftSettings: [
      ]
    ),
    .target(
      name: "D",
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .inherited(),
      ]
    ),
  ],
  defaultSwiftSettings: [
    .defaultIsolation(MainActor.self),
  ]
)
```

- Target `A`: `swiftSettings` is omitted, so defaults apply
- Target `B`: explicitly opts into inheriting the defaults
- Target `C`: defines settings without inheriting, no defaults are applied
- Target `D`: defines settings that control the order of the inheritance

The behavior is identical for the `cSettings`, `cxxSettings`, and `linkerSettings` properties.

For compatibility with conditional compilation,
empty default settings arrays are accepted and do not have any special meaning.

### Restrictions

There are two cases that present extra complexity.

The `unsafeFlags` setting has special semantic meaning and plays an important role in dependency resolution.
Settings inheritance, even with its simplistic model,
makes the existing implementation more complex.
To avoid needing to update this logic, `unsafeFlags` are considered an invalid default.

Another area of complexity is conditional inheritance.
Default settings can have conditions, just like regular target settings.
But the **inheritance** marker itself does not accept conditions.

## Source compatibility

Because this is a purely additive change.

It is worth noting that there is now a semantic difference between a target omitting a settings array and an empty array.
However, because this difference only matters when defaults are present, so it will not have any impact on existing package manifests.

## ABI compatibility

This change does not have any effect on ABI.

## Implications on adoption

This change impacts manifest authors, but should have no effects at all on package consumers.
Authors will be able to adopt default settings freely without concern for compatibility.

## Future directions

It would be useful to allow `unsafeFlags` in default settings.
Unsafe flags themselves already impose restrictions on package use,
so this helps to limit the impact.
But if this turns out to be an area of interest,
support can be added without any API changes.

Conditional inheritance could also be something that package authors find useful.
And similarly, support for this can be added with the existing APIs.

## Alternatives considered

An earlier version of this proposal suggested an automatic,
predefined merging strategy without the `inherited` placeholder.

With some settings, such as `defaultIsolation`,
the results of a merge seem quite unambiguous.
But, this is not the case for all value, and the merging logic can be involved.
The `inherited` mechanism is both intuitive and more powerful.

## Acknowledgments

Max Desiatov provided some much-appreciated general guidance that helped get this idea off the ground. Boris Buegling, Tony Allevato, Owen Voorhees, and Allen Humphreys all provided great feedback on the concept of inheritance.
