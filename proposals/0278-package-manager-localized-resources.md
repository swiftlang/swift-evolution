# Package Manager Localized Resources

* Proposal: [SE-0278](0278-package-manager-localized-resources.md)
* Author: [David Hart](https://github.com/hartbit)
* Review Manager: [Boris Buegling](https://github.com/neonichu)
* Status: **Implemented (Swift 5.3)**
* Implementation: [apple/swift-package-manager#2535](https://github.com/apple/swift-package-manager/pull/2535),
                  [apple/swift-package-manager#2606](https://github.com/apple/swift-package-manager/pull/2606)

## Introduction

This proposal builds on top of the [Package Manager Resources](0271-package-manager-resources.md) proposal to allow defining localized versions of resources in the SwiftPM manifest and have them automatically accessible at runtime using the same APIs.

## Motivation

The recently accepted [Package Manager Resources](0271-package-manager-resources.md) proposal allows SwiftPM users to define resources (images, data file, etc...) in their manifests and have them packaged inside a bundle to be accessible at runtime using the Foundation `Bundle` APIs. Bundles support storing different versions of resources for different localizations and can retrieve the version which makes most sense depending on the runtime environment, but SwiftPM currently offers no way to define those localized variants.

While it is technically possible to benefit from localization today by setting up a resource directory structure that the `Bundle` API expects and specifying it with a `.copy` rule in the manifest (to have SwiftPM retain the structure), this comes at a cost: it bypasses any platform-custom processing that comes with `.process`, and doesn't allow SwiftPM to provide diagnostics when localized resources are mis-configured.

Without a way to define localized resources, package authors are missing out on powerful Foundation APIs to have their applications, libraries and tools adapt to different regions and languages.

## Goals

The goals of this proposal builds on those of the [Package Manager Resources](0271-package-manager-resources.md) proposal:

* Making it easy to add localized variants of resources with minimal change to the manifest.

* Avoiding unintentionally copying files not intended to be localized variants into the product.

* Supporting platform-specific localized resource types for packages written using specific APIs (e.g. Storyboards, XIBs, strings, and stringsdict files on Apple platforms).

## Proposed Solution

The proposed solution for supporting localized resources in Swift packages is to:

* Add a new optional `defaultLocalization` parameter to the `Package` initializer to define the default localization for the resource bundle. The default localization will be used as a fallback when no other localization for a resource fits the runtime environment. SwiftPM will require that parameter be set if the package contains localized resources.

* Require localized resources to be placed in directories named after the [IETF Language Tag](https://en.wikipedia.org/wiki/IETF_language_tag) they represent followed by an `.lproj` suffix, or in a special `Base.lproj` directory to open up future support for [Base Internationalization](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/InternationalizingYourUserInterface/InternationalizingYourUserInterface.html#//apple_ref/doc/uid/10000171i-CH3-SW2) on Apple platforms. While Foundation supports several localization directories which are not valid IETF Language Tags, like `English` or `en_US`, it is recommended to use `en-US` style tags with a two-letter ISO 639-1 or three-letter ISO 639-2 language code, followed by optional region and/or dialect codes separated by a hyphen (see the [CFBundleDevelopmentRegion documentation](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundledevelopmentregion#)).

* Add an optional `localization` parameter to the `Resource.process` factory function to allow declaring files outside of `.lproj` directories as localized for the default or base localization.

* Have SwiftPM diagnose incoherent resource configurations. For example, if a resource has both an un-localized and a localized variant, the localized variant can never be selected by `Foundation` (see the documentation on [The Bundle Search Pattern](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/AccessingaBundlesContents/AccessingaBundlesContents.html#//apple_ref/doc/uid/10000123i-CH104-SW7)).

* Have SwiftPM copy the localized resource to the resource bundle in the right locations for the `Foundation` APIs to find and use them, and generate a `Info.plist` for the resources bundle containing the `CFBundleDevelopmentRegion` key set to the `defaultLocalization`.

## Detailed Design

### Declaring Localized Resources

The `Package` initializer in the `PackageDescription` API gains a new optional `defaultLocalization` parameter with type `LocalizationTag` and a default value of `nil`:

```swift
public init(
    name: String,
    defaultLocalization: LocalizationTag = nil, // New defaultLocalization parameter.
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
`LocalizationTag` is a wrapper around a [IETF Language Tag](https://en.wikipedia.org/wiki/IETF_language_tag), with a `String` initializer and conforming to `Hashable`, `RawRepresentable`, `CustomStringConvertible` and `ExpressibleByStringLiteral`. While a `String` would suffice for now, the type allows for future expansion.

```swift
/// A wrapper around a [IETF Language Tag](https://en.wikipedia.org/wiki/IETF_language_tag).
public struct LocalizationTag: Hashable {

    /// A IETF language tag.
    public let tag: String

    /// Creates a `LocalizationTag` from its IETF string representation.
    public init(_ tag: String) {
        self.tag = tag
    }
}

extension LocalizationTag: RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    // Implementation.
}
```

To allow marking files outside of `.lproj` directories as localized, the `Resource.process` factory function gets a new optional `localization` parameter typed as an optional `LocalizationType`, an enum with two cases: `.default` for declaring a default localized variant, and `.base` for declaring a base-localized resource:

```swift
public struct Resource {
    public enum LocalizationType {
        case `default`
        case base
    }

    public static func process(_ path: String, localization: LocalizationType? = nil) -> Resource
}
```

### Localized Resource Discovery

SwiftPM will only detect localized resources if they are defined with the `.process` rule. When scanning for files with that rule, SwiftPM will tag files inside directories with an `.lproj` suffix as localized variants of a resource. The name of the directory before the `.lproj` suffix identifies which localization they correspond to. For example, an `en.lproj` directory contains resources localized to English, while a `fr-CH.lproj` directory contains resources localized to French for Swiss speakers.

Files in those special directories represent localized variants of a "virtual" resource with the same name in the parent directory, and the manifest must use that path to reference them. For example, the localized variants in `Resources/en.lproj/Icon.png` and `Resources/fr.lproj/Icon.png` are english and french variants of the same "virtual" resource with the `Resources/Icon.png` path, and a reference to it in the manifest would look like:

```swift
let package = Package(
    name: "BestPackage",
    defaultLocalization: "en",
    targets: [
        .target(name: "BestTarget", resources: [
            .process("Resources/Icon.png"),
        ])
    ]
)
```

To support SwiftPM clients for Apple platform-specific resources, SwiftPM will also recognize resources located in `Base.lproj` directories as resources using [Base Internationalization](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/InternationalizingYourUserInterface/InternationalizingYourUserInterface.html#//apple_ref/doc/uid/10000171i-CH3-SW2) and treat them as any other localized variants.

In addition to localized resources detected by scanning `.lproj` directories, SwiftPM will also take into account processed resources declared with a `localization` parameter in the manifest. This allows package authors to mark files outside of `.lproj` directories as localized, for example to keep localized and un-localized resources together. Separate post-processing done outside of SwiftPM can provide additional localizations in this case.

### Validating Localized Resources

SwiftPM can help package authors by diagnosing mis-configurations of localized resources and other inconsistencies that may otherwise only show up at runtime. To illustrate the diagnostics described below, we define a `Package.swift` manifest with a default localization of `"en"`, and two resource paths with the `.process` rule an one with the `.copy` rule:

```swift
let package = Package(
    name: "BestPackage",
    defaultLocalization: "en",
    targets: [
        .target(name: "BestTarget", resources: [
            .process("Resources/Processed"),
            .copy("Resources/Copied"),
        ])
    ]
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

#### Missing Default Localized Variant

When a localized resource is missing a variant for the default localization, `Foundation` may not be able to find the resource depending on the run environment. SwiftPM will emit a warning to warn against it. For example, the following directory structure:

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
warning: resource 'Image.png' in target 'BestTarget' is missing a localization for the default localization 'en'; the default localization is used as a fallback when no other localization matches
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
warning: resource 'Image.png' in target 'BestTarget' has both localized and un-localized variants; the localized variants will never be chosen
```

### Missing Default Localization

The `defaultLocalization` property is optional and has a default value of `nil`, but its required to provide a valid `LocalizationTag` in the presence of localized resources. SwiftPM with emit an error if that is not the case. For example, the following directory structure:

```
BestPackage
|-- Sources
|   `-- BestTarget
|       |-- Resources
|       |   `-- en.lproj
|       |       `-- Localizable.strings
|       `-- main.swift
`-- Package.swift
```

with the following manifest:

```swift
let package = Package(
    name: "BestPackage",
    targets: [
        .target(name: "BestTarget", resources: [
            .process("Resources"),
        ])
    ]
```

will emit the following diagnostic:

```
error: missing manifest property 'defaultLocalization'; it is required in the presence of localized resources
```

#### Explicit Localization Resource in Localization Directory

Explicit resource localization declarations exist to avoid placing resources in localization directories. To avoid any ambiguity, SwiftPM will emit an error when a resource with an explicit localization declaration is inside a localization directory.

```
BestPackage
|-- Sources
|   `-- BestTarget
|       |-- Resources
|       |   `-- en.lproj
|       |       `-- Storyboard.storyboard
|       `-- main.swift
`-- Package.swift
```

with the following manifest:

```swift
let package = Package(
    name: "BestPackage",
    defaultLocalization: "en",
    targets: [
        .target(name: "BestTarget", resources: [
            .process("Resources", localization: .base),
        ])
    ]
```

will emit the following diagnostic:

```
error: resource 'Storyboard.storyboard' in target 'BestTarget' is in a localization directory and has an explicit localization declaration; choose one or the other to avoid any ambiguity
```

### Resource Bundle Generation

SwiftPM will copy localized resources into the correct locations of the resources bundle for them to be picked up by Foundation. It will also generate a `Info.plist` for that bundle with the `CFBundleDevelopmentRegion` value declared in the manifest:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>fr-CH</string>
</dict>
</plist>
```

### Runtime Access

The Foundation APIs already used to load resources will automatically pick up the correct localization:

```swift
// Get path to a file, which can be localized.
let path = Bundle.module.path(forResource: "TOC", ofType: "md")

// Load an image from the bundle, which can be localized.
let image = UIImage(named: "Sign", in: .module, with: nil)
```

And other APIs will now work as expected on all platforms Foundation is supported on:

```swift
// Get localization out of strings files.
var localizedGreeting = NSLocalizedString("greeting", bundle: .module)
```
