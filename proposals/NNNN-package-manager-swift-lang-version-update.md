# Package Manager Swift Language Version API Update

* Proposal: [SE-NNNN](NNNN-package-manager-swift-lang-version-update.md)
* Author: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: [Boris Bügling](https://github.com/neonichu)
* Status: **Discussion**

## Introduction

This proposal adds support in the `Package.swift` manifest file for declaring
Swift language versions with multiple version components.

## Motivation

The Swift compiler previously supported one integer component for its language
version flag (`-swift-version`). The compiler flag has been since enhanced to
accept two components (for e.g., "4.2"). The `swiftLanguageVersions` API in
`Package.swift` currently accepts an interger array and we need to update this
API in order for packages to declare language versions with more than one
component.

## Proposed solution

We propose to change the type of `swiftLanguageVersions` property from
`[Int]` to `[SwiftVersion]` for Swift tools version 4.2. The `SwiftVersion` will
be a struct which conforms to `ExpressibleByIntegerLiteral` and
`ExpressibleByStringLiteral`:

```swift
/// Represents the version of the Swift language that should be used for
/// compiling Swift sources in the package.
public struct SwiftVersion {

    /// Create a new object using a integer.
    public init(_ value: Int)

    /// Create a new object using a string.
    public init(_ value: String)
}

extension SwiftVersion: ExpressibleByIntegerLiteral {}
extension SwiftVersion: ExpressibleByStringLiteral {}
```

The existing package manifests will continue to work when their tools version is
updated to Swift 4.2 if they are using array literal syntax for setting the
value of `swiftLanguageVersions`. Otherwise, the manifests will need to use one
of the `SwiftVersion` initializers.

## Detailed design

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
    swiftLanguageVersions: ["4", "4.2"]
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
    swiftLanguageVersions: ["4.2"]
)
```

The package manager will emit an error because this is not possible in
PackageDescription 4 runtime.

* Example 4:

```swift
// swift-tools-version:4.2

import PackageDescription

let swiftVersion = 4

let package = Package(
    name: "HTTPClient",
    ...
    swiftLanguageVersions: [SwiftVersion(swiftVersion)]
)
```

The sources will be compiled with `-swift-version 4`.

## Impact on existing code

Existing packages will not be impacted but they will not be able to use Swift
language version 4.2 unless they update their manifest to tools version 4.2.

## Alternatives considered

We considered adding a new property to existing `PackageDescription` runtime so
we don't need to ship additional runtime. However that approach is not very
scalable as it requires us to come up with another name for the APIs that are
breaking.
