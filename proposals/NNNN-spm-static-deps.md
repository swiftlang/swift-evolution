# Static Dependencies in SPM

* Proposal: [SE-NNNN](NNNN-spm-static-deps.md)
* Author: [Tanner Nelson](https://github.com/tanner0101)
* Status: **Awaiting Review**
* Review manager: TBD

## Introduction

This proposal introduces the ability to rely on a dependency _statically_ (meaning that it will be available for import in your `Package.swift` file).
The idea is that this will greatly increase the usability and customization of the `Package.swift` file.

## Motivation

Since SPM uses Swift for its package manifest (not JSON or YML like many other dependency managers do) it is not easy to make reliable modifications to the manifest file.
Without the ability to mechinically modify the `Package.swift` manifest, it is impossible for SPM or any convenience CLIs to help users configure their dependencies.
This includes installing new dependencies, automatically resolving errors in the manfiest, and more. This "edit problem" puts SPM at a huge disadvantage when compared 
to other dependency managers.

Xcode can make some small modification to Swift files through the use of fix-its, but it is not known how difficult it would be to add this functionality to SPM.
It is within the realm of possiblity to serialize Swift code, but the complexity behind this would be huge and possibly involve bringing in dependencies like SourceKit.
Additionally, it seems that this solution works against the idea of using a `.swift` manifest format in the first place. 

This proposal presents an alternative solution that better aligns with SPM's decision to use a `.swift` Package manifest format. Instead of fighting the format, we lend it 
strength by allowing the `Package.swift` to import third-party dependencies. This increased usability will directly solve the problems mentioned in this proposal and
hopefully many future problems as well.

## Tooling Problem

Imagine the following `Package.swift` file:

```swift
// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "VaporApp",
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "3.0.0-beta"),
    ],
    targets: [ ... ]
)
```

Let's say we want to programatically add this dependency: `.package(url: "https://github.com/vapor/fluent.git", from: "3.0.0-beta"),`. How would you do that? 

Ideally, the resulting `Package.swift` file would look something like:

```swift
// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "VaporApp",
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "3.0.0-beta"),
        .package(url: "https://github.com/vapor/fluent.git", from: "3.0.0-beta"),
    ],
    targets: [ ... ]
)
```

Developers can hack around this by using Regular Expressions or other pseudo-Swift parsing methods, but nothing that works reliably. There is simply no way to do this in the current version of SPM. To do this reliably, you would need to parse the Swift into an AST, modify that AST, and serialize the Swift. But even that incredibly involved solution still has a lot of unanswered problems.

For example, assume the original `Package.swift` file actually looked like this:

```swift
// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "VaporApp",
    dependencies: [ ],
    targets: [ ... ]
)
package.dependencies.append(.package(url: "https://github.com/vapor/vapor.git", from: "3.0.0-beta"))
```

How would you modify the Swift AST in this case? What would the edited manifest file look like?

Given Swift is a full programming langage, there are probably an infinite number of ways you could construct your `Package.swift` file. This makes building developer tools around this manifest format impossible.

## Static Dependencies

One proposed solution to the tooling problem is through "static dependencies". How this applies directly to the tooling problem is summarized in the next section. Here we look at the syntax of static dependencies.

The specific syntax of this proposal is very-much still up for discussion. Regard the syntax shown as simply examples to help you understand the core concept.

```swift
// swift-tools-version: x
import PackageDescription
import MySPMUtils // http://github.com/tanner0101/my-spm-utils.git 1.0.0..<2.0.0
```

When parsing the `Package.swift` file, SPM will first fetch the package at `http://github.com/tanner0101/my-spm-utils.git`. This will be an otherwise normal
SPM package that produces `MySPMUtils` as a product.

Any normal / static dependencies that `my-spm-utils.git` relies on must be fetched and resolved before continuing. 

```swift
let package = try MySPMUtils.generatePackage() // Package
```

The code imported from `MySPMUtils` can then be used normally. In this case, we use it to generate the `Package` required for the manifest.

Altogether, we get the following code for a complete `Package.swift` manifest file.

```swift
// swift-tools-version: x
import PackageDescription
import MySPMUtils // http://github.com/tanner0101/my-spm-utils.git 1.0.0..<2.0.0

let package = try MySPMUtils.generatePackage() // Package
```

### Solution to the Tooling Problem

With the ability to rely on arbitrary SPM dependencies in the `Package.swift` manifest itself, package authors can devise their own dependency schemes using whichever file formats they like.

For example, the `MySPMUtils` package could depend on a `my-deps.yml` file with the following layout:

```yml
- tanner0101/foo-package 1.0.0<2.0.0
- tanner0101/bar-package 2.1.5
- bob/baz-package 3.0.0-beta..<4.0.0
```

The call to `MySPMUtils.generatePackage()` in the `Package.swift` manfiest would load this file, parse it, and generate a `Package`.

YML is a well-known file format that is very easy to parse _and serialize_ making it easy for users of `MySPMUtils` to create convenience CLIs for installing packages.

### Solutions to other problems

This proposal in particular focuses on the usage of static dependencies to solve the tooling problem but there is no doubt this feature would allow much more flexility with SPM in general.

Any ideas about how you might use this feature would be appreciated!

## Impact on existing code

This is purely additive.

## Alternatives considered

### `Package.json`

A less involved fix that would address just the tooling problem would be for SPM to support a subset of the `Package.swift`'s features via a `Package.json`. This `.json` format could be used in-place of a `Package.swift` file. This would cover the majority of use cases for SPM packages (those that don't need advanced functionality) and be _much_ easier to create tooling around.

Developer tools built around the `Package.json` file could simply error (and note which edits the developer must make manually) when run against packages that use a `Package.swift`.

### Syntax 

Some alternative syntax ideas are mentioned here. Please chip in your ideas for syntax!

#### Follow `swift-tools` pattern

```swift
import MySPMUtils // swift-tools-dependency: http://github.com/tanner0101/my-spm-utils.git@1.0.0..<2.0.0
```

or 

```swift
// swift-tools-version: x
// swift-tools-dependency: http://github.com/tanner0101/my-spm-utils.git@1.0.0..<2.0.0
import PackageDescription
import MySPMUtils
```

#### Global import

This goes against SPM's desire to have sandboxed packages, but is worth a mention.

```sh
swift package install -g github.com/tanner0101/my-spm-utils.git@1.0.0..<2.0.0
```

```swift
import MySPMUtils // since we installed with `swift package install -g` this will resolve
```
