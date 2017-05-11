# Package Manager Custom Target Layouts

* Proposal: [SE-0162](0162-package-manager-custom-target-layouts.md)
* Author: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: [Rick Ballard](https://github.com/rballard)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170410/035471.html)
* Bug: [SR-29](https://bugs.swift.org/browse/SR-29)

## Introduction

This proposal enhances the `Package.swift` manifest APIs to support custom
target layouts, and removes a convention which allowed omission of targets from
the manifest.

## Motivation

The Package Manager uses a convention system to infer targets structure from
disk layout. This works well for most packages, which can easily adopt the
conventions, and frees users from needing to update their `Package.swift` file
every time they add or remove sources. Adopting the conventions is more
difficult for some packages, however – especially existing C libraries or large
projects, which would be difficult to reorganize. We intend to give users a way
to make such projects into packages without needing to conform to our
conventions.

The current convention rules make it very convenient to add new targets and
source files by inferring them automatically from disk, but they also can be
confusing, overly-implicit, and difficult to debug; for example, if the user
does not follow the conventions correctly which determine their targets, they
may wind up with targets they don't expect, or not having targets they did
expect, and either way their clients can't easily see which targets are available
by looking at the `Package.swift` manifest. We want to retain convenience where it
really matters, such as easy addition of new source files, but require explicit
declarations where being explicit adds significant value. We also want to make
sure that the implicit conventions we keep are straightforward and easy to
remember.

## Proposed solution

* We propose to stop inferring targets from disk. They must be explicitly declared
  in the manifest file. The inference was not very useful, as targets eventually
  need to be declared in order to use common features such as product and target
  dependencies, or build settings (which are planned for Swift 4). Explicit
  target declarations make a package easier to understand by clients, and allow us
  to provide good diagnostics when the layout on disk does not match the
  declarations.

* We propose to remove the requirement that name of a test target must have
  suffix "Tests". Instead, test targets will be explicitly declared as such
  in the manifest file.

* We propose a list of pre-defined search paths for declared targets.

  When a target does not declare an explicit path, these directories will be used
  to search for the target. The name of the directory must match the name of
  the target. The search will be done in order and will be case-sensitive.

    Regular targets: package root, Sources, Source, src, srcs.
    Test targets: Tests, package root, Sources, Source, src, srcs.

  It is an error if a target is found in more than one of these paths. In
  such cases, the path should be explicitly declared using the path property
  proposed below.

* We propose to add a factory method `testTarget` to the `Target` class, to define
  test targets.

    ```swift
    .testTarget(name: "FooTests", dependencies: ["Foo"])
    ```

* We propose to add three properties to the `Target` class: `path`, `sources` and
  `exclude`.

    * `path`: This property defines the path to the top-level directory containing the
      target's sources, relative to the package root. It is not legal for this path
      to escape the package root, i.e., values like "../Foo", "/Foo" are invalid.  The
      default value of this property will be `nil`, which means the target will be
      searched for in the pre-defined paths. The empty string ("") or dot (".") implies
      that the target's sources are directly inside the package root.

    * `sources`: This property defines the source files to be included in the
      target. The default value of this property will be nil, which means all
      valid source files found in the target's path will be included. This can
      contain directories and individual source files.  Directories will be
      searched recursively for valid source files. Paths specified are relative
      to the target path.

      Each source file will be represented by String type. In future, we will
      consider upgrading this to its own type to allow per-file build settings.
      The new type would conform to `CustomStringConvertible`, so existing
      declarations would continue to work (except where the strings were
      constructed programatically).

    * `exclude`: This property can be used to exclude certain files and
      directories from being picked up as sources. Exclude paths are relative
      to the target path. This property has more precedence than `sources`
      property.

      _Note: We plan to support globbing in future, but to keep this proposal short
      we are not proposing it right now._

* It is an error if the paths of two targets overlap (unless resolved with `exclude`).

    ```swift
    // This is an error:
    .target(name: "Bar", path: "Sources/Bar"),
    .testTarget(name: "BarTests", dependencies: ["Bar"], path: "Sources/Bar/Tests"),

    // This works:
    .target(name: "Bar", path: "Sources/Bar", exclude: ["Tests"]),
    .testTarget(name: "BarTests", dependencies: ["Bar"], path: "Sources/Bar/Tests"),
    ```

* For C family library targets, we propose to add a `publicHeadersPath`
  property.

    This property defines the path to the directory containing public headers of
    a C target. This path is relative to the target path and default value of
    this property is `include`. This mechanism should be further improved
    in the future, but there are several behaviors, such as modulemap generation,
    which currently depend of having only one public headers directory. We will address
    those issues separately in a future proposal.

    _All existing rules related to custom and automatic modulemap remain intact._

* Remove exclude from `Package` class.

    This property is no longer required because of the above proposed
    per-target exclude property.

* The templates provided by the `swift package init` subcommand will be updated
  according to the above rules, so that users do not need to manually
  add their first target to the manifest.

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

These enhancements will be added to the version 4 manifest API, which will
release with Swift 4. There will be no impact on packages using the version 3
manifest API.  When packages update their minimum tools version to 4.0, they
will need to update the manifest according to the changes in this proposal.

There are two flat layouts supported in Swift 3:

1. Source files directly in the package root.
2. Source files directly inside a `Sources/` directory.

If packages want to continue using either of these flat layouts, they will need
to explicitly set a target path to the flat directory; otherwise, a directory
named after the target is expected. For example, if a package `Foo` has
following layout:

```
Package.swift
Sources/main.swift
Sources/foo.swift
```

The updated manifest will look like this:

```swift
// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "Foo",
    targets: [
        .target(name: "Foo", path: "Sources"),
    ]
)
```

## Alternatives considered

We considered making a more minimal change which disabled the flat layouts
by default, and provided a top-level property to allow opting back in to them.
This would allow us to discourage these layouts – which we would like
to do before the package ecosystem grows – without needing to add a fully
customizable API. However, we think the fuller API we've proposed here is fairly
straightforward and provides the ability to make a number of existing projects
into packages, so we think this is worth doing at this time.
