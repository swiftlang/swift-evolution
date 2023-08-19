# Package Editor Commands

* Proposal: [SE-0301](0301-package-editing-commands.md) 
* Authors: [Owen Voorhees](https://github.com/owenv)
* Review Manager: [Tom Doron](https://github.com/tomerd)
* Status: **Accepted (2021-02-24)**
* Implementation: [apple/swift-package-manager#3034](https://github.com/apple/swift-package-manager/pull/3034)
* Decision Notes: [Rationale](https://forums.swift.org/t/accepted-with-modification-se-0301-package-editor-commands/45069)

## Introduction

Because Swift package manifests are written in Swift using the PackageDescription API, it is difficult to automate common tasks like adding a new product, target, or dependency. This proposal introduces new `swift package` subcommands to perform some common editing tasks which can streamline users' workflows and enable new higher-level tools.

Forums Discussion: https://forums.swift.org/t/pitch-package-editor-commands/42224/

## Motivation

There are a number of reasons someone might want to make changes to a package using a CLI or library interface instead of editing a manifest by hand:

- In some situations, it's less error-prone than editing the manifest manually. Package authors could provide a one line command in their README to easily integrate the latest version as a dependency.
- Because more of the process is automated, users would no longer need to remember details of the package layout convention, like which files and folders they need to create when adding a new library target.
- Using libSwiftPM, IDEs could offer to update the manifest automatically when the user tries to import a missing dependency or create a new target.
- Users could add packages from their package collections as dependencies by name instead of URL

Additionally, many other package managers offer similar features:
- npm's [`npm install`](https://docs.npmjs.com/specifying-dependencies-and-devdependencies-in-a-package-json-file#adding-dependencies-to-a-packagejson-file-from-the-command-line) command for adding dependencies to its `package.json`
- Tools like [cargo-edit](https://github.com/killercup/cargo-edit) for editing the `cargo.toml` format used by Rust
- Elm's [`elm install`](https://elmprogramming.com/elm-install.html) command for adding dependencies to `elm.json`

## Proposed solution

This proposal introduces three new `swift package` subcommands: `add-product`, `add-target`, and `add-dependency`, which edit the manifest of the current package. Together, these encompass many of the most common editing operations performed by users when working on a package.

## Detailed design

### New Commands

The following subcommands will be added to `swift package`:

`swift package add-product <name> [--type <type>] [--targets <targets>]`

- **name**: The name of the new product.
- **type**: _executable_, _library_, _static-library_, or _dynamic-library_. If unspecified, this will default to _library_.
- **targets**: A space separated list of target names to to add to the new product.
***
`swift package add-target <name> [--type <type>] [--no-test-target] [--dependencies <dependencies>] [--url <url>] [--path <path>] [--checksum <checksum>]`
- **name**: The name of the new target.
- **type**: _library_, _executable_, _test_, or _binary_. If unspecified, this will default to _library_. Adding system library targets will not be supported by the initial version of the CLI due to their often complex configuration requirements.
- **--no-test-target**: By default, a test target is added for each library target unless this flag is present.
- **dependencies**: A space separated list of target dependency names.
- **url/path**: The URL for a remote binary target or path for a local one.
- **checksum**: The checksum for a remote binary target.

In addition to editing the manifest, the add-target command will create the appropriate `Sources` or `Tests` subdirectories for new targets.
***
`swift package add-dependency <dependency> [--exact <version>] [--revision <revision>] [--branch <branch>] [--from <version>] [--up-to-next-minor-from <version>]`
- **dependency**: This may be the URL of a remote package, the path to a local package, or the name of a package in one of the user's package collections.

The following options can be used to specify a package dependency requirement:
- **--exact <version>**: Specifies a `.exact(<version>)` requirement in the manifest.
- **--revision <revision>**: Specifies a `.revision(<revision>)` requirement in the manifest.
- **--branch <branch>**: Specifies a `.branch(<branch>)` requirement in the manifest.
- **--up-to-next-minor-from <version>**: Specifies a `.upToNextMinor(<version>)` requirement in the manifest.
- **--from <version>**: Specifies a `.upToNextMajor(<version>)` requirement in the manifest when it appears alone. Optionally, **--to <version>** may be added to specify a custom range requirement, or **--through** may be added to specify a custom closed range requirement.

If no requirement is specified, the command will default to a `.upToNextMajor` requirement on the latest version of the package.

### Compatibility

These new commands will be restricted to only operate on package manifests having a `swift-tools-version` of 5.2 or later. This decision was made to reduce the complexity of the feature, as there were a number of major changes to the `PackageDescription` module in Swift 5.2. It is expected that as the API continues to evolve in the future, support for editing manifests with older tools versions will be maintained whenever possible.

### Editing Non-Declarative Manifests

The subcommands described above support editing all fully declarative parts of a package manifest. For the purposes of this proposal, an entry in a manifest is considered fully declarative if it consists only of literals and calls to factory methods and initializers in the `PackageDescription` module. The vast majority of products, targets, and dependencies sections in existing package manifests are fully declarative.

However, because manifests may contain arbitrary Swift code, not all of them meet this criteria. The proposed subcommands will be capable of making edits to many of these manifests, but they will do so on a best-effort basis. If the requested editing operation cannot be performed successfully, they will report an error and leave the manifest unchanged.

### Example

Given a simple initial package:
```swift
// swift-tools-version:5.3
import PackageDescription

// Description of my package
let package = Package(
  name: "MyPackage",
  targets: [
    .target(
      name: "MyLibrary", // Utilities
      dependencies: []
    ),
  ]
)
```

The following commands can be used to add dependencies, targets, and products:
```
swift package add-dependency https://github.com/apple/swift-argument-parser
swift package add-target MyLibraryTests --type test --dependencies MyLibrary
swift package add-target MyExecutable --type executable --dependencies MyLibrary ArgumentParser
swift package add-product MyLibrary --targets MyLibrary
```
Resulting in this manifest:
```swift
// swift-tools-version:5.3
import PackageDescription

// Description of my package
let package = Package(
  name: "MyPackage",
  products: [
    .library(
      name: "MyLibrary",
      targets: [
          "MyLibrary",
      ]
    ),
  ],
  dependencies: [
    .package(name: "swift-argument-parser", url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "0.3.1")),
  ],
  targets: [
    .target(
      name: "MyLibrary", // Utilities
      dependencies: []
    ),
    .testTarget(
      name: "MyLibraryTests",
      dependencies: [
        "MyLibrary",
      ]
    ),
    .target(
      name: "MyExecutable",
      dependencies: [
        "MyLibrary",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
  ]
)
```

Additionally, `Sources/MyExecutable/main.swift` and `Tests/MyLibraryTests/MyLibraryTests.swift` will be created for the new targets.

## Security

This proposal has minimal impact on the security of the package manager. Packages added using the `add-dependency` subcommand will be fetched and their manifests will be loaded, but this is no different than if the user manually edited the manifest to include them.

## Impact on Existing Packages

Because this proposal only includes new editing commands, it has no impact on package semantics.

## Alternatives considered

One alternative considered was not including this functionality at all. It's worth noting that maintaining package editor functionality over time and adapting it to changes in the `PackageDescription` API will require a nontrivial effort. However, the benefits of including the functionality are substantial enough that it seems like a worthwhile tradeoff. Beyond that, much of the required infrastructure can be reused to enable other new features like source locations in manifest diagnostics and commands like `swift package upgrade` discussed in the "Future Directions" section.

Another suggested alternative was to provide an interface to run scripts which mutate the `Package` object after the manifest is run. A full discussion of such a feature is outside the scope of this proposal, but it would likely allow more flexible edits. However, this approach has several downsides. To persist edits after running such a script, the entire `Package.swift` would need to be rewritten, which would drop comments, the content of inactive conditional compilation blocks, and any other skipped branches in the manifest code. The proposed subcommands, which rely on a syntax-level transformation, are able to make more specific edits to the manifest and avoid these issues.

---

During the review, an alternative spelling for the commands was proposed:
```
swift package product add ...
swift package target add ...
swift package dependency add ...
```
These spellings could scale better to introduce new 'verbs' in addition to `add` (for example, `rename`, `delete`, etc.), and there's some prior art (`git remote add`, for example). However, they'd also introduce a fourth level of subcommand nesting which could impact help output and ease-of-use, and might imply the existence of additional functionality which isn't likely to be added in the near future. Overall, both approaches to the subcommand spellings have legitimate tradeoffs, so it was decided to keep the original spellings.

## Future Directions

### Support for Deleting Products/Targets/Dependencies and Renaming Products/Targets

This functionality was considered, but ultimately removed from the scope of the initial proposal. Most of these editing operations appear to be fairly uncommon, so it seems better to wait and see how the new commands are used in practice before rolling out more.

### Add a `swift package upgrade` Command

A hypothetical `swift package upgrade` command could automatically update the version specifiers of package dependencies to newer versions, similar to `npm upgrade`. This is another manifest editing operation very commonly provided by other package managers.
