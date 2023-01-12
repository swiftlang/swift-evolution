# Package Manager System Library Targets

* Proposal: [SE-0208](0208-package-manager-system-library-targets.md)
* Author: [Ankit Aggarwal](https://github.com/aciidb0mb3r), [Daniel Dunbar](https://github.com/ddunbar)
* Review Manager: [Boris Bügling](https://github.com/neonichu)
* Status: **Implemented (Swift 4.2)**
* Implementation: [apple/swift-package-manager#1586](https://github.com/apple/swift-package-manager/pull/1586)
* Bug: [apple/swift-package-manager#4823](https://github.com/apple/swift-package-manager/issues/4823)

## Introduction

This proposal introduces a new type of target "system library target", which
moves the current system-module packages feature from package to target level.

## Motivation

The package manager currently supports "system-module packages" which are
intended to adapt a system installed dependency to work with the package
manager. However, this feature is only supported on *package* declarations,
which mean libraries that need it often need to create a separate repository
containing the system package and refer to it as a dependency.

Our original motivation in forcing system packages to be declared as standalone
packages was to encourage the ecosystem to standardize on them, their names,
their repository locations, and their owners. In practice, this effort did not
work out and it only made the package manager harder to use.

## Terminology

**Swift N**: The tools version this proposal is implemented in.

## Proposed solution

We propose adding a new "system library target", which would supply the same
metadata needed to adapt system libraries to work with the package manager, but
as a target. This would allow packages to embed these targets with the libraries
that need them.

We propose to deprecate the legacy system-module package declaration for
packages that are only compatible with Swift N or later.

## Detailed design

We will add a new factory method for system library target:

```swift
extension Target {
    public static func systemLibrary(
        name: String,
        path: String? = nil,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil
    ) -> Target
}
```

* This target factory function will only be available if the tools version of
  the manifest is greater than or equal to Swift N.

* During dependency resolution, the package manager will emit a deprecation
  warning if there is a legacy system-module package in the package graph and
  the tools version of the root package is greater than or equal to Swift N.

* Currently, the package manage implicitly assumes a dependency on system-module
  packages when they are included as a dependency. In the new model, for
  consistency with the existing target/product model, clients of a system
  package must also specify explicit dependencies from the targets which use the
  system library.

* System library targets _may_ be exported from a package as products. To do so,
  they *must* be exported via a library product with exactly one member target
  i.e. the system library target.

## Examples

For example, an existing package which defines only a system library adaptor
would be described:

```swift
// swift-tools-version:N
import PackageDescription

let package = Package(
    name: "CZLib",
    products: [
        .library(name: "CZLib", targets: ["CZLib"]),
    ],
    targets: [
        .systemLibrary(
            name: "CZLib",
            pkgConfig: "zlib",
            providers: [
                .brew(["zlib"]),
                .apt(["zlib"]),
            ]
        )
    ]
)
```

A similar package which exported a Swift interface for zlib might look like the
following example, which is not expressible today without using a separate
repository.

```swift
// swift-tools-version:N
import PackageDescription

let package = Package(
    name: "ZLib",
    products: [
        .library(name: "ZLib", targets: ["ZLib"]),
    ],
    targets: [
        .target(
            name: "ZLib",
            dependencies: ["CZLib"]),
        .systemLibrary(
            name: "CZLib")
    ]
)
```

In this case, the system library is not an exported product, and would not be
available to other packages.

## Impact on existing packages

None.

## Alternatives considered

None.
