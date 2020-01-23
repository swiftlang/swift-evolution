# Package Manager Localization Resources

* Proposal: [SE-XXXX](XXXX-package-manager-localization-resources.md)
* Authors: [David Hart](https://github.com/hartbit)
* Review Manager: **TBD**
* Status: **Pitch**

## Introduction

This proposal builds on top of the [Package Manager Resources](0271-package-manager-resources.md) proposal to allow defining localized versions of resources in the SwiftPM manifest and have them automatically accessible at runtime using the same APIs.

## Motivation

The recently accepted [Package Manager Resources](0271-package-manager-resources.md) proposal allows SwiftPM users to define resources (images, data file, etc...) in their manifests and have them packaged inside a bundle to be accessible at runtime using the Foundation `Bundle` APIs. Bundles support storing different versions of resources for different locales and can retrieve the version which makes most sense depending on the runtime environment, but SwiftPM currently offers no way to define those localized variants.

While it is technically possible to benefit from localization today by setting up a resource directory structure that the `Bundle` API expects and specifying it with a `.copy` rule in the manifest (to have SwiftPM retain the structure), this comes at a cost: it bypasses any platform-custom processing that comes with `.process`, and doesn't allow SwiftPM to provide diagnostics when localized resources are mis-configured.

Without a way to defined localized resources, package authors are missing out on powerful Foundation APIs to have their applications, libraries and tools adapt to different regions and languages.

## Goals

The goals of this proposal builds on those of the [Package Manager Resources](0271-package-manager-resources.md) proposal:

* Making it easy to add localized variants of resources with minimal change to the manifest.

* Avoiding unintentionally copying files not intended to be localized variants into the product.

* Supporting platform-specific localized resource types for packages written using specific APIs (e.g. Storyboards, XIBs, strings, and stringsdict files on Apple platforms).

## Proposed Solution

The proposed solution for supporting localized resources in Swift packages is to:

* Add a new optional `developmentRegion` parameter to the `Package` initializer to define the default language and region for the resource bundle. If not set, it will default to english (`.en`).

* Detect files in a resource `.process` path located in directories named after the `Locale.identifier` they represent followed by an `.lproj` suffix, or in a special `Base.lproj` directory to open up future support for [Base Internationalization](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/InternationalizingYourUserInterface/InternationalizingYourUserInterface.html#//apple_ref/doc/uid/10000171i-CH3-SW2) on Apple platforms.

* Add an optional `localization` parameter to the `Resource.process` factory function to allow declaring files outside of `.proj` directories as localized for the development region or for base localization.

* Have SwiftPM diagnose incoherent resource configurations. For example, if a resource has both an un-localized and a localized variant, the localized variant can never be selected by `Foundation` (see the documentation on [The Bundle Search Pattern](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/AccessingaBundlesContents/AccessingaBundlesContents.html#//apple_ref/doc/uid/10000123i-CH104-SW7)).

* Have SwiftPM copy the localized resource to the resource bundle in the right locations for the `Foundation` APIs to find and use them.

## Detailed Design

### Declaring Localized Resources

The `Package` initializer in the `PackageDescription` API gains a new optional `developmentRegion` parameter with type `Locale` and a default value of english:

```swift
public init(
    name: String,
    developmentRegion: Locale = .en, // New developmentRegion parameter.
    pkgConfig: String? = nil,
    providers: [SystemPackageProvider]? = nil,
    products: [Product] = [],
    dependencies: [Dependency] = [],
    targets: [Target] = [],
    swiftLanguageVersions: [Int]? = nil,
    cLanguageStandard: CLanguageStandard? = nil,
    cxxLanguageStandard: CXXLanguageStandard? = nil
)
```

To simplify creating a `Locale` for the new initializer parameter, the `PackageDescription` module will add static factory methods to `Locale` for each currently valid identifier:

```swift
extension Locale {
    public static var en: Locale { Locale(identifier: "en") }
    public static var en_US: Locale { Locale(identifier: "en_US") }
    public static var en_GB: Locale { Locale(identifier: "en_GB") }
    public static var fr: Locale { Locale(identifier: "fr") }
    public static var fr_CH: Locale { Locale(identifier: "fr_CH") }
    // ...
}
```

To allow marking files outside of `.lproj` directories as localized, the `Resource.process` factory function gets a new optional `localization` parameter typed as an optional `LocalizationType`, an enum with two cases: `.developmentRegion` for declaring a development region localized variant, and `.base` for declaring a base-localized resource:

```swift
public struct Resource {
    public static func process(_ path: String, localization: LocalizationType? = nil) -> Resource
}

public enum LocalizationType {
    case developmentRegion
    case base
}
```

### Localized Resource Discovery

SwiftPM will only detect localized resources if they are defined with the `.process` rule. When scanning for files with that rule, SwiftPM will tag files inside directories with an `.lproj` suffix as localized variants of a resource. The name of the directory before the `.lproj` suffix will identify which locale they correspond to (based on the Foundation `Locale.identifier` property). For example, an `en.lproj` directory contains resources localized to English, while a `fr_CH.lproj` directory contains resources localized to French for Swiss speakers.

Files in those special directories represent localized variants of a "virtual" resource with the same name in the parent directory, and the manifest must use that path to reference them. For example, the localized variants in `Resources/en.lproj/Icon.png` and `Resources/fr.lproj/Icon.png` are english and french variants of the same "virtual" resource with the `Resources/Icon.png` path, and a reference to it in the manifest would look like:

```swift
let package = Package(
    name: "BestPackage",
    developmentRegion: .en,
    targets: [
        .target(name: "BestTarget", resources: [
            .process("Resources/Icon.png"),
        ])
    ]
)
```

To support SwiftPM clients for Apple platform-specific resources, SwiftPM will also recognize resources located in `Base.lproj` directories as resources using [Base Internationalization](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/InternationalizingYourUserInterface/InternationalizingYourUserInterface.html#//apple_ref/doc/uid/10000171i-CH3-SW2) and treat them as any other localized variants.

In addition to localized resources detected by scanning `.lproj` directories, SwiftPM will also take into account processed resources declared with a `localization` parameter in the manifest. This allows package authors to mark files outside of `.lproj` directories as localized, for example to keep localized and unlocalized resources together. Separate post-processing done outside of SwiftPM can provide additional localizations in this case.

### Validating Localized Resources

SwiftPM can help package authors by diagnosing mis-configurations of localized resources and other inconsistencies that may otherwise only show up at runtime. To illustrate the diagnostics described below, we define a `Package.swift` manifest with a development region of `.en`, and both a resource path with the `.process` rule an one with the `.copy` rule:

```swift
let package = Package(
    name: "BestPackage",
    developmentRegion: .en,
    targets: [
        .target(name: "BestTarget", resources: [
            .process("Resources/Processed"),
            .copy("Resources/Copied"),
        ])
    ]
```

#### Unknown Localization Directory

To avoid users unintentionally introducing typos in localized directory names, SwiftPM will emit an error for directories with a `.lproj` suffix defined with a `.process` resource rule, when their name doesn't correspond to a valid `Locale` identifier. For example, the following directory structure:

```
BestPackage
|-- Sources
|   `-- BestTarget
|       |-- Resources
|       |   |-- Processed
|       |   |   `-- invalid.lproj
|       |   |       `-- Localized.strings
|       |   `-- Copied
|       |       `-- invalid.lproj
|       |           `-- Localized.strings
|       `-- main.swift
`-- Package.swift
```

will emit the following diagnostic:

```
error: directory `Resources/Processed/invalid.lproj` in target `BestTarget` doesn't reference a valid locale identifier; all available identifiers are available on Foundation's `Locale.availableIdentifiers`
```

#### Sub-directory in Localization Directory

To avoid overly-complex and ambiguous resource directory structures, SwiftPM with emit an error when a localization directory in a `.process` resource path contains a sub-directory. For example, the following directory structure:

```
BestPackage
|-- Sources
|   `-- BestTarget
|       |-- Resources
|       |   |-- Processed
|       |   |   `-- en.lproj
|       |   |      `-- directory
|       |   |          `-- file.txt
|       |   `-- Copied
|       |       `-- en.lproj
|       |          `-- directory
|       |              `-- file.txt
|       `-- main.swift
`-- Package.swift
```

will emit the following diagnostic:

```
error: localization directory `Resources/Processed/en.lproj` in target `BestTarget` contains sub-directories, which is forbidden
```

#### Missing Development Region Localized Variant

When a localized resource is missing a variant for the development region, `Foundation` may not be able to find the resource depending on the run environment. SwiftPM will emit a warning to warn against it. For example, the following directory structure:

```
BestPackage
|-- Sources
|   `-- BestTarget
|       |-- Resources
|       |   |-- Processed
|       |   |   `-- fr.lproj
|       |   |       `-- Image.png
|       |   `-- Copied
|       |       `-- fr.lproj
|       |           `-- Image.png
|       `-- main.swift
`-- Package.swift
```

will emit the following diagnostic:


```
warning: resource `Image.png` in target `BestTarget` is missing a localization for the development region 'en'; the development region is used as a fallback when no other localization matches
```

#### Un-localized and Localized Variants

When there exists both an un-localized and localized variant of the same resource, SwiftPM will emit a warning to let users know that the localized variants will never be chosen at runtime, due to the search pattern of `Foundation` APIs (see the documentation on [The Bundle Search Pattern](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/AccessingaBundlesContents/AccessingaBundlesContents.html#//apple_ref/doc/uid/10000123i-CH104-SW7)). For example, the following directory structure:

```
BestPackage
|-- Sources
|   `-- BestTarget
|       |-- Resources
|       |   |-- Processed
|       |   |   |-- en.lproj
|       |   |   |   `-- Image.png
|       |   |   `-- Image.png
|       |   `-- Copied
|       |       |-- en.lproj
|       |       |   `-- Image.png
|       |       `-- Image.png
|       `-- main.swift
`-- Package.swift
```

will emit the following diagnostic:

```
warning: resource 'Image.png' in target 'BestTarget' has both localized and un-localized variants; the localized variant will never be chosen
```

#### Unexpected Base Localized Resource

As Apple platforms only support placing Storyboards and XIBs in `Base.lproj` directories, SwiftPM will emit an error for files with a different extension, in paths with the `.process` rule. For example, the following directory structure:

```
BestPackage
|-- Sources
|   `-- BestTarget
|       |-- Resources
|       |   |-- Processed
|       |   |   `-- Base.lproj
|       |   |       `-- Localizable.strings
|       |   `-- Copied
|       |   |   `-- Base.lproj
|       |   |       `-- Localizable.strings
|       |   `-- External.strings
|       `-- main.swift
`-- Package.swift
```

with the following manifest:

```swift
let package = Package(
    name: "BestPackage",
    developmentRegion: .en,
    targets: [
        .target(name: "BestTarget", resources: [
            .process("Resources/Processed"),
            .copy("Resources/Copied"),
            .process("Resources/External.strings", localization: .base),
        ])
    ]
```

will emit the following diagnostics:

```
warning: resource 'Localizable.strings' in target 'BestTarget' does not support base internationalization
warning: resource 'External.strings' in target 'BestTarget' does not support base internationalization
```

### Runtime Access

SwiftPM will copy localized resources into the correct locations of the Resources bundle for them to be picked up by the Foundation APIs already used to load resources as well as those sepcific to localized content:

```swift
// Get localization out of strings files.
var localizedGreeting = NSLocalizedString("greeting", bundle: .module)

// Get path to a file, which can be localized.
let path = Bundle.module.path(forResource: "TOC", ofType: "md")

// Load an image from the bundle, which can be localized.
let image = UIImage(named: "Sign", in: .module, with: nil)
```
