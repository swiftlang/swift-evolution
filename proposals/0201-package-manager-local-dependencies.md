# Package Manager Local Dependencies

* Proposal: [SE-0201](0201-package-manager-local-dependencies.md)
* Author: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: [Boris Bügling](https://github.com/neonichu)
* Status: **Implemented (Swift 4.2)**
* Implementation: [apple/swift-package-manager#1583](https://github.com/apple/swift-package-manager/pull/1583)
* Bug: [apple/swift-package-manager#4824](https://github.com/apple/swift-package-manager/issues/4824)

## Introduction

This proposal adds a new API in `PackageDescription` to support declaring
dependency on a package using its path on disk instead of the git URL.

## Motivation

There are two primary motivations for this proposal:

1. Reduce friction in bringing up a set of packages.

	Currently, there is a lot of friction in setting up a new set of interconnected
packages. The packages must be in a git repository and the package author needs
to run the `swift package edit` command for each dependency to develop them in tandem.

2. Some package authors prefer to keep their packages in a single repository.
   This could be because of several reasons, for e.g.:

    * The packages are in very early design phase and are not ready to be published
    in their own repository yet.
    * The author has a set of loosely related packages which they may or may not
    want to publish as a separate repository in future.

## Proposed solution

We propose to add the following API in the `PackageDescription` module:

```swift
extension Package.Dependency {
    public static func package(path: String) -> Package.Dependency
}
```

* This API will only be available if the tools version of the manifest is
  greater than or equal to the Swift version this proposal is implemented in.

* The value of `path` must be a valid absolute or relative path string.

* The package at `path` must be a valid Swift package. 

* The local package will be used as-is and the package manager will not try to
  perform any git operation on the package.

* The local package must be declared in the root package or in other local
  dependencies. This means, it is not possible to depend on a regular versioned
  dependency that declares a local package dependency.

* A local package dependency will override any regular dependency in the package
  graph that has the same package name.

* A local dependency will not be recorded in the `Package.resolved` file and
  if it overrides a dependency in the package graph, any existing entry will be
  removed. This is similar to the edit mode behaviour.

* The package manager will not allow using the edit feature on local dependencies.

## Impact on existing packages

None.

## Alternatives considered

We considered piggybacking this on the multi-package repository feature, which
would also allow authors to publish subpackages from a repository. However, we
think local dependencies is a much simpler feature that stands on its own.
