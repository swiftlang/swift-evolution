# Package Manager Support for Top of Tree development

* Proposal: [SE-0149](0149-package-manager-top-of-tree.md)
* Author: [Boris Bügling](https://github.com/neonichu)
* Review Manager: [Daniel Dunbar](https://github.com/ddunbar)
* Status: **Accepted**

* Bugs: [SR-3709](https://bugs.swift.org/browse/SR-3709)

## Introduction

This proposal adds enhancements to `swift package edit` to support development of packages without strict versioning ("top of tree" development).

## Motivation

The package manager currently supports package dependencies which are strictly versioned according to semantic versioning. This works well for users of packages and it is possible to edit a package in place using `swift package edit` already, but we want to allow developers to manually check out repositories on their machines as overrides. This is useful when developing multiple packages in tandem or when working on packages alongside an application.

When a developer owns multiple packages that depend on each other, it can be necessary to work on a feature across more than one of them at the same time, without having to tag versions in between. The repositories for each package would usually already be checked out and managed manually by the developer, allowing them to switch branches or perform other SCM operations at will.

A similar situation will arise when working on a feature that requires code changes to both an application and a dependent package. Developers want to iterate on the package by directly in the context of the application without having to release spurious versions of the package. Allowing developers to provide their own checkouts to the package manager as overrides will make this workflow much easier than it currently is.

## Proposed solution

As a solution to this problem, we propose to extend `swift package edit` to take an optional path argument to an existing checkout so that users can manually manage source control operations.

## Detailed Design

We will extend the `edit` subcommand with a new optional argument `--path`:

```bash
$ swift package edit bar --path ../bar
```

This allows users to manage their own checkout of the `bar` repository and will make the package manager use that instead of checking out a tagged version as it normally would. Concretely, this will make `./Packages/bar` a symbolic link to the given path in the local filesystem, store this mapping inside the workspace and will ensure that the package manager will no longer be responsible for managing checkouts for the `bar` package, instead the user is responsible for managing the source control operations on their own. This is consistent with the current behavior of `swift edit`. Using `swift package unedit` will also work unchanged, but the checkout itself will not be deleted, only the symlink. If there is no existing checkout at the given filesystem location, the package manager will do an initial clone on the user's behalf.

## Impact on existing code

There will no impact on existing code.

## Alternative considered

We could have used the symlink in the `Packages` directory as primary data, but decided against it in order to be able to provide better diagnostics and distinguish use of `swift package edit` from the user manually creating symbolic links. This makes the symlink optional, but we decided to still create it in order to keep the structure of the `Packages` directory consistent independently of the use of this feature.
