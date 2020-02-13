# Package Manager Target Based Dependency Resolution

* Proposal: [SE-0226](0226-package-manager-target-based-dep-resolution.md)
* Authors: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: [Boris Bügling](https://github.com/neonichu)
* Status: **Partially implemented (Swift 5.2):** Implemented the manifest API to disregard targets not concerned by any dependency products, which avoids building dependency test targets.
* Bug: [SR-8658](https://bugs.swift.org/browse/SR-8658)

## Introduction

This is a proposal for enhancing the package resolution process to resolve
the minimal set of dependencies that are used in a package graph.

## Motivation

The current package resolution process resolves all declared dependencies in
the package graph. Some of the declared dependencies may not be required by the
products that are being used in the package graph. For e.g., a package may be
using some additional dependencies for its test targets. The packages that
depend on this package doesn't need to resolve such additional dependencies. These
dependencies increase the overall constraint in the dependency resolution process
that can otherwise be avoided. It can cause more cases of dependency hell if two
packages want to use incompatible versions of a dependency that they only use
for their unexported products. Cloning unnecessary dependencies also impacts the
performance of the resolution process.

Another example of packages requiring additional dependencies is for sample code
targets. A library package may want to create an executable target which
demonstrates some functionality of the library. This executable may require
other dependencies such as a command-line argument parser.

## Proposed solution

We propose to enhance the dependency resolution process to resolve only the
dependencies that are actually being used in the package graph. The resolution
process can examine the target dependencies to figure out which package
dependencies require resolution. Since we will only resolve what is required, it
may reduce the odds of dependency hell situations.

To achieve this, the package manager needs to associate the product dependencies
with the packages which provide those products without cloning them. We propose
to make the package name parameter in the product dependency declaration
non-optional. This is necessary because if the package name is not specified,
the package manager is forced to resolve all package dependencies just to figure
out the packages for each of the product dependency. SwiftPM will retain support
for the `byName` declaration for products that are named after the package name.
This provides a shorthand for the common case of small packages that vend just
one product.

```swift
extension Target.Dependency {
    static func product(name: String, package: String) -> Target.Dependency
}
```

SwiftPM will also need the package names of the declared dependencies without
cloning them. The package name is declared inside the package's manifest, and
doesn't always match the package URL. We propose to enhance the URL-based
dependency declaration APIs to allow specifying the package name. In many cases,
the package name and the last path component its URL are the same.  Package name
can be omitted for such dependencies.

```swift
extension Package.Dependency {
    static func package(
        name: String? = nil,    // Proposed
        url: String,
        from version: Version
    ) -> Package.Dependency

    static func package(
        name: String? = nil,    // Proposed
        url: String,
        _ requirement: Package.Dependency.Requirement
    ) -> Package.Dependency

    static func package(
        name: String? = nil,    // Proposed
        url: String,
        _ range: Range<Version>
    ) -> Package.Dependency

    static func package(
        name: String? = nil,    // Proposed
        url: String,
        _ range: ClosedRange<Version>
    ) -> Package.Dependency
}
```

## Detailed design

The resolution process will start by examining the products used in the target
dependencies and figure out the package dependencies that vend these products.
For each dependency, the resolver will only clone what is necessary to build
the products that are used in the dependees.

The products declared in the target dependencies will need to provide their
package name unless the package and product have the same name. SwiftPM will
diagnose the invalid product declarations and emit an error.

Similarly, SwiftPM will validate the dependency declarations. It will be
required that the case used in the URL basename and the package name match in
order to allow inferring the package name from the URL. It is recommended to
keep consistent casing for the package name and the basename. Otherwise, the
package name will be required to specified in the dependency declaration.  Note
that the basename will be computed by stripping the ".git" suffix from the URL
(if present).

As an example, consider the following package manifests:

```swift
// IRC package
let package = Package(
    name: "irc",
    products: [
        .library(name: "irc", targets: ["irc"]),
        .executable(name: "irc-sample", targets: ["irc-sample"]),
    ],
    dependencies: [
       .package(name: "NIO", url: "https://github.com/apple/swift-nio.git", from: "1.0.0"),

       .package(url: "https://github.com/swift/ArgParse.git", from: "1.0.0"),
       .package(url: "https://github.com/swift/TestUtilities.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "irc",
            dependencies: ["NIO"]
        ),

        .target(
            name: "irc-sample",
            dependencies: ["irc", "ArgParse"]
        ),

        .testTarget(
            name: "ircTests",
            dependencies: [
                "irc",
                .product(name: "Nimble", package: "TestUtilities"),
            ]
        )
    ]
)

// IRC Client package
let package = Package(
    name: "irc-client",
    products: [
        .executable(name: "irc-client", targets: ["irc-client"]),
    ],
    dependencies: [
       .package(url: "https://github.com/swift/irc.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "irc-client", dependencies: ["irc"]),
    ]
)
```

When the package "irc-client" is resolved, the package manager will only create
checkouts for the packages "irc" and "swift-nio" as "ArgParse" is used by
"irc-sample" but that product is not used in the "irc-client" package and
"Nimble" is used by the test target of the "irc" package.

## Impact on existing packages

There will be no impact on the existing packages. All changes, both behavioral
and API, will be guarded against the tools version this proposal is implemented
in. It is possible to form a package graph with mix-and-match of packages
with different tools versions. Packages with the older tools version will
resolve all package dependencies, while packages using the newer tools version
will only resolve the package dependencies that are required to build the used
products.

As described in the proposal, the package manager will stop resolving the unused
dependencies. There will be no `Package.resolved` entries and checkouts for such
dependencies.

Declaring target dependency on a product from an already resolved dependency
could potentially trigger the dependency resolution process, which in turn could
lead to cloning more repositories or even dependency hell. Note that such
dependency hell situations will always happen in the current implementation.

## Alternatives considered

We considered introducing a way to mark package dependencies as "development" or
"test-only". Adding these types of dependencies would have introduced new API
and new concepts, increasing package manifest complexity. It could also require
complicated rules, or new workflow options, dictating when these dependencies
would be resolved. Instead, we rejected adding new APIs as the above proposal
can handle these cases without any new API, and in a more intuitive manner.
