# Package Manager Swift Language Compatibility Version

* Proposal: [SE-0151](0151-package-manager-swift-language-compatibility-version.md)
* Author: [Daniel Dunbar](https://github.com/ddunbar), [Rick Ballard](http://github.com/rballard)
* Review Manager: Anders Bertelrud
* Status: **Active review (February 7...February 13, 2017)**

## Introduction

This proposal adds support for the Swift compiler's new "language compatibility
version" feature to the package manager.

## Motivation

The Swift compiler now supports a "language compatibility version" flag which
specifies the Swift major language version that the compiler should try to
accept. We need support for an additional package manager manifest feature in
order for this feature to be used by Swift packages.

## Proposed solution

We will add support to the package manifest declaration to specify a set of
supported Swift language versions:

```swift
let package = Package(
    name: "HTTP",
    ...
    swiftLanguageVersions: [3, 4])
```

When building a package, we will always select the Swift language version that
is most close to (but not exceeding) the major version of the Swift compiler in
use.

If a package does not support any version compatible with the current compiler,
we will report an error.

If a package does not specify any Swift language versions, the
language version to be used will match the major version of the the
package's Swift tools version (as discussed in a separate evolution proposal). A
Swift tools version with a major version of '3' will imply a default Swift
language version of '3', and a Swift tools version with a major version
of '4' will imply a default Swift language version of '4'.

## Detailed design

We are operating under the assumption that for the immediate future, the Swift
language compatibility version accepted by the compiler will remain an integer
major version.

With this change, the complete package initializer will be:

```swift
    public init(
        name: String,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        targets: [Target] = [],
        products: [Product] = [],
        dependencies: [Dependency] = [],
        swiftLanguageVersions: [Int]? = nil,
        exclude: [String] = []
```

where absence of the optional language version list indicates the default
behavior should be used for this package.

### Example Behaviors

Here are concrete examples of how the package manager will compile code,
depending on its language version declarations:

* Version 3 Packager Manager & Swift 3 (only) Language Package

  The package manager will compile the code with `-swift-version 3`.

* Version 3 Packager Manager & Swift 4 (only) Language Package

  The package manager will report an error, since the package supports no language
  version compatible with the tools.

* Version 3 Packager Manager & Swift [3, 4] Language Package

  The package manager will compile the code with `-swift-version 3`, matching the
  major version of the tools in use.

* Version 4 Packager Manager & Swift 3 (only) Language Package

  The package manager will compile the code with `-swift-version 3`.

* Version 4 Packager Manager & Swift 4 (only) Language Package

  The package manager will compile the code with `-swift-version 4`.

* Version 4 Packager Manager & Swift [3, 4] Language Package

  The package manager will compile the code with `-swift-version 4`.

  Clients wishing to validate actual Swift 3 compatibility are expected to do so
  by using an actual Swift 3 implementation to build, since the Swift compiler
  does not commit to maintaining pedantic Swift 3 compatibility (that is, it is
  designed to *accept* any valid Swift 3 code in the `-swift-version 3`
  compatibility mode, but not necessarily to *reject* any code which the Swift 3
  compiler would not have accepted).

## Impact on existing code

Since this is a new API, all packages will use the default behavior once
implemented. Because the default Swift tools version of existing packages
is "3.0.0" (pending approval of the Swift tools version proposal), the Swift
4 package manager will build such packages in Swift 3 mode. When packages
wish to migrate to the Swift 4 language, they can either update their
Swift tools version or specify Swift 4 as their language version.

New packages created with `swift package init` by the Swift 4 tools will
build with the Swift 4 language by default, due to the Swift tools version
that `swift package init` chooses.

This is a new manifest API, so packages which adopt this API will no longer be
buildable with package manager versions which do not recognize that
API. We expect to add support for this API to Swift 3.1, so it will be possible
to create packages which support the Swift 4 and 3 languages and the Swift
4 and 3.1 tools.

## Alternatives considered

We could have made the Swift language version default to the version of the
Swift tools in use if not specified. However, tying this to the Swift tools
version instead allows existing Swift 3 language packages to build with the
Swift 4 tools without changes, as they won't need to explicitly specify a Swift
language version in order to continue to build with the Swift 3 language.

We chose not to support any command line features to modify the selected version
(e.g., to force a Swift 4 compiler to use Swift 3 mode where acceptable) in
order to keep this proposal simple. We will consider these in the future if they
prove necessary.

We considered supporting a way to set the Swift language version on
a per-module basis, instead of needing to set it for the entire package.
We think this would be best done using build settings, which the package
manager does not yet support. We are pending per-module support for this
feature until build settings are supported.
