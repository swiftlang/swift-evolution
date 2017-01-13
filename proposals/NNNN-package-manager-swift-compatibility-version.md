# Package Manager Swift Compatibility Version

* Proposal: [SE-NNNN](NNNN-package-manager-swift-compatibility-version.md)
* Author: [Daniel Dunbar](https://github.com/ddunbar)
* Review manager: N/A
* Status: **WIP**

## Introduction

This proposal adds support for the Swift compiler's new "compatibility version"
feature to the package manager.

## Motivation

The Swift compiler now supports a "compatibility version" flag which specifies
the Swift major language version that the compiler should try to accept. We need
support for an additional package manager manifest feature in order for this
feature to be used effectively by Swift packages.

## Proposed solution

We will add support to the package manifest declaration to specify a set of
supported versions:

```swift
let package = Package(
    name: "HTTP",
    ...
    compatibleSwiftVersions: [3, 4])
```

When building a package, we will always select the compatible Swift version that
is most close to (but not exceeding) the major version of the Swift compiler in
use.

If a package does not support any version compatible with the current compiler,
we will report an error.

If a package does not specify any compatible Swift versions, we will assume that
it is compatible with all Swift versions and behave accordingly (i.e., build
using the major version of the Swift compiler in use).

## Detailed design

We are operating under the assumption that for the immediate future, the Swift
version accepted by the compiler will remain an integer major version.

With this change, the complete package initializer will be:

```swift
    public init(
        name: String,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        targets: [Target] = [],
        products: [Product] = [],
        dependencies: [Dependency] = [],
        compatibleSwiftVersions: [Int]? = nil,
        exclude: [String] = []
```

where absence of the optional compatible version list indicates the default
behavior should be used for this package.

### Example Behaviors

Here are concrete examples of how the package manager will compile code,
depending on its compatibility declarations:

* Version 3 Packager Manager & Swift 3 (only) Compatibile Package

  The package manager will compile the code with `-swift-version 3`.

* Version 3 Packager Manager & Swift 4 (only) Compatibile Package

  The package manager will report an error, since the package supports no version
  compatible with the tools.

* Version 3 Packager Manager & Swift [3, 4] Compatibile Package

  The package manager will compile the code with `-swift-version 3`, matching the
  major version of the tools in use.

* Version 4 Packager Manager & Swift 3 (only) Compatibile Package

  The package manager will compile the code with `-swift-version 3`.

* Version 4 Packager Manager & Swift 4 (only) Compatibile Package

  The package manager will compile the code with `-swift-version 4`.

* Version 4 Packager Manager & Swift [3, 4] Compatibile Package

  The package manager will compile the code with `-swift-version 4`.

  Clients wishing to validate actual Swift 3 compatibility are expected to do so
  by using an actual Swift 3 implementation to build, since the Swift compiler
  does not commit to maintaining pedantic Swift 3 compatibility (that is, it is
  designed to *accept* any valid Swift 3 code in the `-swift-version 3`
  compatibility mode, but not necessarily to *reject* any code which the Swift 3
  compiler would not have accepted).

## Impact on existing code

Since this is a new API, all packages will use the default behavior once
implemented. This means that the Swift 4 package manager will immediately begin
compiling packages in Swift 4 mode. This is as intended, although it may expose
Swift 4 source incompatibilities in packages and require them to adopt an
explicit declaration for Swift 3 compatibility.

This is a new manifest API, so packages which adopt this API will no longer be
buildable with package manager versions which do not recognize that
API. Packages which require support for that can use the features added in
[SE-0135](https://github.com/apple/swift-evolution/blob/master/proposals/0135-package-manager-support-for-differentiating-packages-by-swift-version.md).

## Alternatives considered

We could have made several different choices for the behavior when a package
does not declare compatible versions, for example we could conservatively assume
it requires Swift 3. However, we expect that there will be minimal source
breaking changes for the forseeable future of Swift development, and would
prefer to optimize for most packages being built in the latest Swift mode.

We chose not to support any command line features to modify the selected version
(e.g., to force a Swift 4 compiler to use Swift 3 mode where acceptable) in
order to keep this proposal simple. We will consider these in the future if they
prove necessary.
