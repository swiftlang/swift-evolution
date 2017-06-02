# Package Manager Support for Top of Tree development

* Proposal: [SE-XXXX](xxxx-package-manager-top-of-tree.md)
* Author: [Boris Bügling](https://github.com/neonichu)
* Review Manager: TBD
* Status: Discussion

## Introduction

This proposal adds enhancements to `swift package edit` and the package manifest to support development of packages without strict versioning ("top of tree" development).

## Motivation

The package manager currently supports packages which are strictly versioned according to semantic versioning. This works well for users of packages and it is possible to edit a package in place using `swift package edit`, but we still see some use cases where this hinders common development workflows:

- bootstrapping a new package which does not yet have a version at all
- allowing developers to manually check out repositories on their machines as overrides -- this is useful when developing multiple packages in tandem or when working on packages alongside an application
- allowing references to packages in branches instead of tags -- this is useful for working on revlocked packages

## Proposed solution

We propose two solutions for these problems:

- extend the package manifest to allow specifying a branch instead of a version to support revlocked packages
- extend `swift package edit` to take an optional path argument to manually override the current behaviour

## Detailed Design

### Specifying branches in the manifest

We will introduce a new initializer for `Package` which takes a branch instead of a version range:

```swift
import PackageDescription

let package = Package(
    name: "foo",
    dependencies: [
        .Package(url: "http://url/to/bar", branch: "development"),
    ]
)
```

Instead of checking out a tag, the package manager will check out the specified branch for the given package. If a package exists simultaneously with a specified version range and with a specified branch in the same package graph, an error will be emitted and checking out dependencies will fail. It is also an error to depend on a package referencing a branch transitively from a tagged package. 

Running `swift package update` will update packages referencing branches to their latest remote state. Running `swift package pin` will store the commit hash for the currently checked out revision in the `Pinfile`, so that other users of the package will receive the exact same revision if pinning is enabled.

### Enhancements to `swift package edit`

We will extend the `edit` subcommand with a new optional argument `--path`:

```bash
$ swift package edit bar --path ../bar
```

This will make `./Packages/bar` a symbolic link to the given path in the local filesystem and will ensure that the package manager will no longer be responsible for managing checkouts for the `bar` package, instead the user is responsible for managing the source control operations on their own. This is consistent with the current behaviour of `swift edit`. Using `swift package unedit` will also work unchanged.

## Impact on existing code

There will no impact on existing code.

## Alternative considered

None at this point.
