# Package editing command to add a target dependency

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: https://github.com/apple/swift-package-manager/pull/7594

## Introduction

[SE-0301](https://github.com/apple/swift-evolution/blob/main/proposals/0301-package-editing-commands.md) added several package editing commands to the Swift Package Manager to add a new package dependency, new product, or a new target to the current package from the command line. This proposal adds one more command to add a target dependency to the package (on either a target or a product from another package) from the command line.

Swift-evolution thread: [Pitch thread](https://forums.swift.org/t/package-manifest-editing-commands-beyond-se-0301/72085)

## Motivation

Adding a target dependency is a common operation on a package manifest. We'd like to be able to do this programmatically from the command line.

## Proposed solution

Add a new command line operation that can update a target dependency. For example, this:

```swift
swift package add-target-dependency --package swift-syntax SwiftSyntax MyLibrary
```

would take a package like this:

```swift
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "client",
    dependencies: [
      .package(url: "https://github.com/apple/swift-syntax.git", branch: "main")
    ],
    targets: [ .target(name: "MyLibrary") ]
)
```

and update it to:

```swift
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "client",
    dependencies: [
      .package(url: "https://github.com/apple/swift-syntax.git", branch: "main")
    ],
    targets: [ 
      .target(
        name: "MyLibrary",
        dependencies: [
          .product(name: "SwiftSyntax", package: "swift-syntax")
        ]
      ) 
    ]
)
```

## Detailed design

Here is the complete help for the command:

```
OVERVIEW: Add a new target dependency to the manifest

USAGE: swift package add-target-dependency <dependency-name> <target-name> [--package <package>]

ARGUMENTS:
  <dependency-name>       The name of the new dependency
  <target-name>           The name of the target to update

OPTIONS:
  --package <package>     The package in which the dependency resides
  --version               Show the version.
  -h, -help, --help       Show help information.
```

When `--package` is specified, the command will create a dependency on a product from the specified package. Otherwise, it will create a dependency on a target from the current package.

## Security

No

## Impact on existing packages

It does not change the manifest.

## Alternatives considered

The only alternative discussed in the pitch thread is whether to introduce another level of structure to the subcommands of `swift package`, making this `swift package target add-dependency` or similar. This alternative was discussed as part of the review of SE-0301 and is covered in the [Alternatives Considered](https://github.com/apple/swift-evolution/blob/main/proposals/0301-package-editing-commands.md#alternatives-considered) section there.
