# Default Target Settings

* Proposal: [SE-0540](0540-default-target-settings.md)
* Authors: [Matt Massicotte](https://github.com/mattmassicotte)
* Review Manager: [Mikaela Caron](https://github.com/mikaelacaron)
* Status: **Active review (August 3 - August 17, 2026)**
* Implementation: [swiftlang/swift-package-manager#10033](https://github.com/swiftlang/swift-package-manager/pull/10033)
* Review: ([pitch](https://forums.swift.org/t/default-package-swift-settings/71872)) ([review](https://forums.swift.org/t/se-0540-default-package-settings/88748))

## Introduction

It is very common for Swift packages to use the same settings flags across all their targets.
A built-in mechanism to apply these base settings
offers improved readability and convenience for package manifests.

## Motivation

The default SwiftPM package template generates a manifest with two targets: primary and test.
There are many examples of packages that go far beyond this default of two,
but single-target packages are quite rare.

That same default template, as of Swift 6.4,
also includes the same setting for both of these targets.
Here's a snippet from the Package.swift file:

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
Selectively adopting upcoming language features for all targets is very common.
For the prototypical primary-test target pair,
duplicating one or two settings might not be ideal, but it is feasible.
For packages with many targets and/or complex manifest files,
it can become quite challenging to reason about the setting being applied.

A possible solution involves applying a constant array to each target.
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

And, all of this is just discussing how a uniform list of settings could be applied.
There are packages that have much more complex requirements.
Typically, this requires at least some logic within the manifest file.

A more real-world example comes from the [swift-configuration](https://github.com/apple/swift-configuration/blob/ef2069fd7a0ee254c3b65a1ca7f53751afc326d0/Package.swift) package manifest. It uses the post-definition settings modification mechanism, and does so in a non-trivial way. Here's the current implementation:

```swift
for target in package.targets {
  var settings = target.swiftSettings ?? []
  
  // https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md
  // Require `any` for existential types.
  settings.append(.enableUpcomingFeature("ExistentialAny"))
  
  // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
  settings.append(.enableUpcomingFeature("MemberImportVisibility"))
  
  // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
  settings.append(.enableUpcomingFeature("InternalImportsByDefault"))
  
  // https://docs.swift.org/compiler/documentation/diagnostics/nonisolated-nonsending-by-default/
  settings.append(.enableUpcomingFeature("NonisolatedNonsendingByDefault"))
  
  settings.append(
    .enableExperimentalFeature(
      "AvailabilityMacro=Configuration 1.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
    )
  )
  
  if enableAllCIFlags {
    // Ensure all public types are explicitly annotated as Sendable or not Sendable.
    settings.append(.unsafeFlags(["-Xfrontend", "-require-explicit-sendable"]))
  }
  
  target.swiftSettings = settings
}
```

This technique requires mutating the package targets and managing
settings array construction within the loop.
It also needs to do so after the package has been defined,
which further separates the settings from the entities they affect.

These existing solutions are inconvenient, verbose, and error-prone.
And because of the subtleties that can arise from compiler behavior differences,
errors here can be particularly painful.

## Proposed solution

The desired configuration for the vast majority of package authors is the same.
Begin with a core list of settings that define baseline behaviors,
along with per-target refinements to that list as needed.

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

  public var defaultSwiftSettings: [SwiftSetting]?
  public var defaultCSettings: [CSetting]?
  public var defaultCXXSettings: [CXXSetting]?
  public var defaultLinkerSettings: [LinkerSetting]?

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
    defaultSwiftSettings: [SwiftSetting] = [],
    cLanguageStandard: CLanguageStandard? = nil,
    defaultCSettings: [CSetting] = [],
    cxxLanguageStandard: CXXLanguageStandard? = nil,
    defaultCXXSettings: [CXXSetting] = [],
    defaultLinkerSettings: [LinkerSetting] = []
  )
}
```

```swift
struct SwiftSetting {
  // ...
  
  public static func inherited() -> SwiftSetting {
    // ...
  }
}

struct CSetting {
  // ...
  
  public static func inherited() -> CSetting {
    // ...
  }
}

struct CXXSetting {
  // ...
  
  public static func inherited() -> CXXSettings {
    // ...
  }
}

struct LinkerSetting {
  // ...
  
  public static func inherited() -> LinkerSetting {
    // ...
  }
}
```

With these changes in place, the default package template could look like this:

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

The swift-configuration definition would see a much more dramatic simplification (with a little help from a ternary expression).

```swift
defaultSwiftSettings: [
  // https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md
  // Require `any` for existential types.
  .enableUpcomingFeature("ExistentialAny"),
  
  // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
  .enableUpcomingFeature("MemberImportVisibility"),
  
  // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
  .enableUpcomingFeature("InternalImportsByDefault"),
  
  // https://docs.swift.org/compiler/documentation/diagnostics/nonisolated-nonsending-by-default/
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  
  .enableExperimentalFeature(
    "AvailabilityMacro=Configuration 1.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
  ),
  
  .unsafeFlags(
    enableAllCIFlags ? ["-Xfrontend", "-require-explicit-sendable"] : []
  ),
]
```

It completely eliminates the array and target mutations.
Plus, it helps to establish a more obvious connection between the definition and the settings.
This makes the file feel much more declarative.

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
        .inherited(),
        .enableExperimentalFeature("Lifetimes"),
      ]
    ),
  ],
  defaultSwiftSettings: [
    .enableUpcomingFeature("ApproachableConcurrency"),
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

This inheritance mechanism matches the existing behavior of the settings definition APIs.
This means that duplicates and invalid combinations are permitted.
These situations are handled either by later stages of package validation or by the build tools themselves.
In many cases, this results in "last entry wins" semantics.

### Restrictions

Default settings can have conditions, just like regular target settings.
Supporting and resolving this correctly represents considerable additional complexity.
For now, the `inherited` placeholder setting itself does not accept conditions.

## Source compatibility

This is a purely additive change and is fully compatible with existing manifest files.

It is worth noting that there is now a semantic difference between
a target omitting a settings array and an explicit empty array.
However, because this difference only matters when defaults are present,
it will not have any impact on existing package manifests.

## ABI compatibility

This change does not have any effect on ABI.

## Implications on adoption

This change impacts manifest authors, but should have no effects at all on package consumers.
Authors will be able to adopt default settings freely without concern for compatibility.

## Future directions

Conditional inheritance could also be something that package authors find useful.
It would be possible to add support for this in an API-compatible way.

## Alternatives considered

An earlier version of this proposal suggested an automatic,
predefined merging strategy without the `inherited` placeholder.

With some settings, such as `defaultIsolation`,
the results of a merge seem quite unambiguous.
But, this is not the case for all values, and the merging logic can be involved.
The `inherited` mechanism is both intuitive and more powerful.

## Acknowledgments

Max Desiatov provided some much-appreciated general guidance that helped get this idea off the ground. Boris Buegling, Tony Allevato, Owen Voorhees, and Allen Humphreys all provided great feedback on the concept of inheritance.
