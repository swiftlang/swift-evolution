# Package Manager Target Layout Spec

* Proposal: [SE-NNNN](NNNN-package-manager-target-layout-spec.md)
* Author: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: TBD
* Status: **Discussion**
* Bug: [SR-29](https://bugs.swift.org/browse/SR-29)

## Introduction

This is a proposal for enhancing the `Package.swift` manifest APIs to support
custom targets' layout.

## Motivation

The package manager uses a convention system to infer targets from disk layout.
This works well for many packages but sometimes more flexibility and
customization is required.  This becomes especially useful in cases like porting
an existing C libary to build with package manager, or adding package manager
support to a large project which would be very difficult to rearrange. 

We also think some of the convention rules are confusing or complicated and
should be removed.

## Proposed solution

* We propose to remove the requirement that the name of a test target should
  have suffix "Tests".

* We propose to stop inferring targets from disk and all targets should be
  explicitly declared in the manifest file. We think that the target inference
  is not that useful anymore because the targets need to be declared in
  manifest anyway to use features like: product/target dependencies, build
  settings, etc.

* A regular (Swift or C family) target can be declared using the factory
  method: `target`.

    ```swift
    .target(name: "Foo")
    ```

    The sources of a target will be searched in the directory matching the name
    of the target in following paths (in order and case-insensitive):
    package root, sources, source, src, srcs.

* We propose to add a factory method `testTarget` to `Target` class which
  declares a test target.


    ```swift
    .testTarget(name: "FooTests", dependencies: ["Foo"])
    ```

    The sources of a test target will be searched in the directory matching the
    name of the target in following paths (in order and case-insensitive):
    Tests, package root, sources, source, src, srcs.

* We propose to add 3 properties to `Target` class: `path`, `sources`, `exclude`.

    * `path`: If used, the target's sources will only be searched in this
      directory. All valid sources in this directory will become part of the
      target.

    * `sources`: If used, only these subpaths will be include in the target's
      sources.  They should be relative to the target's path.

    * `exclude`: All paths in this property will be excluded from the target's
      sources. `exclude` has more precedence than `sources` property.

      _Note: We plan to support glob in future but to keep this proposal short
      we are not adding it right now._

* It is an error if paths of two targets overlaps.

    ```swift
    // This is an error:
    .target(name: "Bar", path: "Sources/Bar"),
    .testTarget(name: "BarTests", dependencies: ["Bar"], path: "Sources/Bar/Tests"),

    // This works:
    .target(name: "Bar", path: "Sources/Bar", exclude: ["Tests"]),
    .testTarget(name: "BarTests", dependencies: ["Bar"], path: "Sources/Bar/Tests"),
    ```

* For C family library targets, we propose to add a `publicHeaders` property.

    If present, this property declares the subpath to the directory containing
    public headers of the target. The default directory is "include".

    _Note: All rules related to custom and automatic modulemap remain intact._

* The templates provided by the package init subcommand will be updated
  according to the above rules.

## Examples:

* Dummy manifest containing all Swift code.

```swift
let package = Package(
    name: "SwiftyJSON",
    targets: [
        .target(
            name: "Utility",
            path: "Sources/BasicCode"
        ),

        .target(
            name: "SwiftyJSON",
            dependencies: ["Utility"],
            path: "SJ",
            sources: ["SwiftyJSON.swift"]
        ),

        .testTarget(
            name: "AllTests",
            dependencies: ["Utility", "SwiftyJSON"],
            path: "Tests",
            exclude: ["Fixtures"]
        ),
    ]
)
```

* LibYAML

```swift
let packages = Package(
    name: "LibYAML",
    targets: [
        .target(
            name: "libyaml",
            sources: ["src"]
        )
    ]
)
```

* Node.js http-parser

```swift
let packages = Package(
    name: "http-parser",
    targets: [
        .target(
            name: "http-parser",
            publicHeaders: ".",
            sources: ["http_parser.c"]
        )
    ]
)
```

* swift-build-tool

```swift
let packages = Package(
    name: "llbuild",
    targets: [
        .target(
            name: "swift-build-tool",
            path: ".",
            sources: [
                "lib/Basic",
                "lib/llvm/Support",
                "lib/Core",
                "lib/BuildSystem",
                "products/swift-build-tool/swift-build-tool.cpp",
            ]
        )
    ]
)
```

## Impact on existing code

These enhancements will be added to version 4 API which will release with Swift
4. So, there will be no impact on packages using the version 3 manifest API.
When these packages update their minimum tools version to 4.0, they will need
to update the manifest according to the changes in this proposal.

## Alternatives considered

None.
