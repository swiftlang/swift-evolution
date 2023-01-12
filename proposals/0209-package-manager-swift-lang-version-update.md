# Package Manager Swift Language Version API Update

* Proposal: [SE-0209](0209-package-manager-swift-lang-version-update.md)
* Author: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: [Boris Bügling](https://github.com/neonichu)
* Status: **Implemented (Swift 4.2)**
* Implementation: [apple/swift-package-manager#1563](https://github.com/apple/swift-package-manager/pull/1563)
* Bug: [apple/swift-package-manager#4822](https://github.com/apple/swift-package-manager/issues/4822)

## Introduction

This proposal changes the current `Package.swift` manifest API for declaring for
Swift language versions from freeform Integer array to a new `SwiftVersion` enum
array.

## Motivation

The Swift compiler now allows `4.2` as an accepted value of Swift version flag
(`-swift-version`). The `swiftLanguageVersions` API in `Package.swift` currently
accepts an interger array and we need to update this API in order for packages
to declare this language version if required.

## Proposed solution

We propose to change the type of `swiftLanguageVersions` property from `[Int]`
to `[SwiftVersion]` in the manifest API used for Swift tools version 4.2. The
`SwiftVersion` will be an enum that contains all known Swift language version
values and will provide an option to declare custom version values:

```swift
/// Represents the version of the Swift language that should be used for
/// compiling Swift sources in the package.
public enum SwiftVersion {
    case v3
    case v4
    case v4_2

    /// User-defined value of Swift version.
    ///
    /// The value is passed as-is to Swift compiler's `-swift-version` flag.
    case version(String)
}
```

The existing package manifests that use `swiftLanguageVersions` will need to
migrate to the new enum when their tools version is updated to 4.2.

## Detailed design

The custom version string will be passed as-is to the value of `-swift-version`
flag. The custom version string allows a package to support and make use of new
language versions which are not known to the manifest API of the current tools
version. This is important for packages which want to add support for a newer
Swift language version but also want to retain compatibility with an older
language and tools version, where the new language version isn't known in the
manifest API.

The package manager will use standard version numbering rules to determine
precedence of language versions. For e.g. 5 > 4.2.1 > 4.2 > 4.

We will ship a new `PackageDescription` runtime in the Swift 4.2 toolchain. This
runtime will be selected if tools version of a package greater than or equal to
version 4.2.

When building a package, we will always select the Swift language version that
is most close to (but not exceeding) a valid language version of the Swift
compiler in use.

If a package does not specify a Swift language version, the tools version of the
manifest will be used to derive the value.

The `swift package init` command in Swift 4.2 will create packages with
`// swift-tools-version:4.2`. This is orthogonal to this proposal but is
probably worth mentioning.

### Examples

Here are some concrete examples:

* Example 1:

```swift
// swift-tools-version:4.0

import PackageDescription

let package = Package(
    name: "HTTPClient",
    ...
    swiftLanguageVersions: [4]
)
```

The sources will be compiled with `-swift-version 4`.

* Example 2:

```swift
// swift-tools-version:4.2

import PackageDescription

let package = Package(
    name: "HTTPClient",
    ...
    swiftLanguageVersions: [.v4, .v4_2]
)
```

The sources will be compiled with `-swift-version 4.2`. 

* Example 3:

```swift
// swift-tools-version:4.0

import PackageDescription

let package = Package(
    name: "HTTPClient",
    ...
    swiftLanguageVersions: [.v4_2, .version("5")]
)
```

The package manager will emit an error because this is not possible in
PackageDescription 4 runtime.

* Example 4:

```swift
// swift-tools-version:4.2

import PackageDescription

let package = Package(
    name: "HTTPClient",
    ...
    swiftLanguageVersions: [.v4, .version("5")]
)
```

The sources will be compiled with `-swift-version 4`.

## Impact on existing code

Existing packages will not be impacted but they will not be able to use Swift
language version 4.2 unless they update their manifest to tools version 4.2.

Once they do update their tools version to 4.2, they will need to migrate to the
new enum if they use `swiftLanguageVersions` property.

## Alternatives considered

We considered adding a new property to existing `PackageDescription` runtime so
we don't need to ship additional runtime. However that approach is not very
scalable as it requires us to come up with another name for the APIs that are
breaking.

We considered making `SwiftVersion` a struct which conforms to
`ExpressibleByIntegerLiteral` and `ExpressibleByStringLiteral`. However, we
think the enum approach is better for several reasons:

- It is consistent with the C/C++ language version settings.
- The package authors can easily tell which versions are available.
- The package authors don't need to concern themselves with how to spell a valid version.
