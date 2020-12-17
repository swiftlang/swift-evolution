# Declaring executable targets in Package Manifests

* Proposal: [SE-0294](0294-package-executable-targets.md)
* Authors: [Anders Bertelrud](https://github.com/abertelrud)
* Review Manager: [Tom Doron](https://github.com/tomerd)
* Status: **Active review (December 1...December 13)**
* Implementation: [apple/swift-package-manager#3045](https://github.com/apple/swift-package-manager/pull/3045)
* Bugs: [SR-13924](https://bugs.swift.org/browse/SR-13924)
* Pitch: [Forum Discussion](https://forums.swift.org/t/pitch-ability-to-declare-executable-targets-in-swiftpm-manifests-to-support-main/41968)

## Introduction

This proposal lets Swift Package authors declare targets as executable in the
package manifest. This replaces the current approach of inferring executabilty
based on the presence of a source file with the base name `main` at the top
level of the target source directory.

Letting package authors declare targets as executable allows the use of `@main`
in Swift package targets. It also allows for better diagnostics, since the
purpose of the target is unambiguous even if source files are moved or renamed.

## Motivation

The Swift Package Manager doesn’t currently provide a way for a package manifest
to declare that a target provides the main module for an executable. Instead,
SwiftPM infers this by looking for a compilable source file with a base name of
`main` at the top level of the target directory.

It is important to know unambiguously whether or not a target is intended to be
executable, because it affects the flags that are passed to the compiler at
build time. It also affects the quality of diagnostics, such as detecting
product declarations that mistakenly include more or less than a single
executable target in an executable product.

Relying on specially named source files also doesn’t work when using `@main` to
specify the entry point of an executable. In addition, there are ergonomic
problems with using specially named source files (e.g.
[SR-1379](https://bugs.swift.org/browse/SR-1379)) that would be addressed by
being able to explicitly declare a target as being executable in the manifest.

## Proposed solution

The most straightforward approach is to allow a target to be marked as
executable in the manifest. This could take the form of either a parameter to
the existing `target` type, or a new target type.

There is already an established pattern of using the type itself to denote the
kind of target being declared (e.g. `testTarget` as a specialization of
`target`), so this proposal suggests adding a new `executableTarget` type for
this purpose.

Using a separate target type in the manifest would also support any future
differences in parameters between an executable target and a library target.
It would also be easier to read in a package manifest that includes a long
list of target declarations.

## Detailed design

The `PackageDescription` API is updated to add an `executableTarget` function,
currently having the same parameters as the `target` function:

```swift
/// Creates an executable target.
///
/// An executable target can contain either Swift or C-family source files, but not both. It contains code that
/// is built as an executable module that can be used as the main target of an executable product.  The target
/// is expected to either have a source file named `main.swift`, `main.m`, `main.c`, or `main.cpp`, or a source
///  file that contains the `@main` keyword.
///
/// - Parameters:
///   - name: The name of the target.
///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
///       for example, `[PackageRoot]/Sources/[TargetName]`.
///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
///       A path is relative to the target's directory.
///       This parameter has precedence over the `sources` parameter.
///   - sources: An explicit list of source files. If you provide a path to a directory,
///       the Swift Package Manager searches for valid source files recursively.
///   - resources: An explicit list of resources files.
///   - publicHeadersPath: The directory containing public headers of a C-family library target.
///   - cSettings: The C settings for this target.
///   - cxxSettings: The C++ settings for this target.
///   - swiftSettings: The Swift settings for this target.
///   - linkerSettings: The linker settings for this target.
@available(_PackageDescription, introduced: 999.0)
public static func executableTarget(
   name: String,
   dependencies: [Dependency] = [],
   path: String? = nil,
   exclude: [String] = [],
   sources: [String]? = nil,
   resources: [Resource]? = nil,
   publicHeadersPath: String? = nil,
   cSettings: [CSetting]? = nil,
   cxxSettings: [CXXSetting]? = nil,
   swiftSettings: [SwiftSetting]? = nil,
   linkerSettings: [LinkerSetting]? = nil
) -> Target {
   return Target(
       name: name,
       dependencies: dependencies,
       path: path,
       exclude: exclude,
       sources: sources,
       resources: resources,
       publicHeadersPath: publicHeadersPath,
       type: .executable,
       cSettings: cSettings,
       cxxSettings: cxxSettings,
       swiftSettings: swiftSettings,
       linkerSettings: linkerSettings
   )
}
```

A new `.executable` case is also added to the `TargetType` enum in the
`PackageDescription` API.

These are the only API changes that are visible to package manifest authors.

On the implementation side, this proposal also updates the logic in SwiftPM
so that:

- if the package tools-version is less than 5.4, a target is considered to be
  executable in exactly the same way as in versions of SwiftPM prior to 5.4
- if the package tools-version is greater than or equal to 5.4, then:
   - if the target is declared using `.executableTarget`, then it is considered
     to be an executable target
   - if the target is declared using `.target`, then source files are examined
     using the same rules as prior to 5.4, and a warning suggesting that the
     target be declared using `.executableTarget` is emitted if the target is
     considered executable under those rules

The effect of this logic is that, starting with SwiftPM tools-version 5.4,
declaring an executable target by using `.target` and having it inferred to be
an executable by the presence of a source file with a base name of `main` is
considered deprecated but still works.

This approach eases the transition for any package that adopts tools-version
5.4, and provides better diagnostics to change the declarations of executable
targets to use `.executableTarget`. If technically feasible, the warning
should have a fix-it to change the associated `.target` declaration to
`.executableTarget`.

A future tools-version will remove the warning and treat any target that is
declared using `.target` as library target.

SwiftPM already passes different flags when compiling executable targets and
library targets, and that remains unchanged. In particular, SwiftPM passes
`-parse-as-library` when compiling a non-executable target, and will continue
to do so with these changes. It will continue to not pass this flag when
compiling executable targets, so that the compiler will continue to interpret
`main.swift` as the main source file of an executable.

## Impact on exisiting packages

There is no impact on existing packages. Packages that specify a tools-version
of 5.4 or greater will get the new behavior. Any package graph can contain a
mixture of old and new packages, and each target's executability will be
determined according to the tools-version of the package that declares it.

As with any Swift module, the Swift compiler will not let an executable have
multiple `@main` entry points, including one that is specified by having a
`main.swift` source file in the target.

## Alternatives considered

There are various other ways that could have been considered for designating
a target as executable:

#### As a new parameter on `target`

Target declaration functions already have many parameters, and this would
exacerbate that problem. It would also make it difficult to syntactically
distinguish between executable targets and library targets in the package
manifest. It would also make it difficult to add future parameters that
applied to only library targets or executable targets.

#### Through some other designation outside the manifest

Since the intended executability of a target is a fundamental statement of
purpose, it seems logical that this should be denoted in the package manifest.
The Swift package manifest provides all the information other than what can be
inferred from the file system.

## Future directions

It is somewhat redundant that a package having only a single executable target
that builds a single executable product will now have both a product and target
with the word "executable" in its type. This is mitigated by the existing Swift
Package Manager behavior of implicitly creating an executable product for any
executable target if there isn't already a product with the same name (this
behavior remains unchanged by this proposal).

Since a future goal is to find a way to unify product and target declarations
in the package manifest, the redundant appearance of the word "executable" in
both product and target type names is expected to be only a short-term issue.
