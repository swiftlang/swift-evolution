# Package Manager Support for branches

* Proposal: [SE-0150](0150-package-manager-branch-support.md)
* Author: [Boris Bügling](https://github.com/neonichu)
* Review Manager: [Daniel Dunbar](https://github.com/ddunbar)
* Status: **Accepted**

* Bugs: [SR-666](https://bugs.swift.org/browse/SR-666)

## Introduction

This proposal adds enhancements to the package manifest to support development of packages without strict versioning. This is one of two features, along with "Package Manager Support for Top of Tree development", being proposed to enable use of SwiftPM to develop on "top of tree" of related packages.

## Motivation

The package manager currently supports packages dependencies which are strictly versioned according to semantic versioning. This is how a package's dependencies should be specified when that package is released, but this requirement hinders some development workflows:

- bootstrapping a new package which does not yet have a version at all
- developing related packages in tandem in between releases, when one package may depend on the latest revision of another, which has not yet been tagged for release

## Proposed solution

As a solution to this problem, we propose to extend the package manifest to allow specifying a branch or revision instead of a version to support revlocked packages and initial bootstrapping. In addition, we will also allow specifying a branch or revision as an option to the `pin` subcommand.

## Detailed Design

### Specifying branches or revisions in the manifest

We will introduce a second initializer for `.Package` which takes a branch instead of a version range:

```swift
import PackageDescription

let package = Package(
    name: "foo",
    dependencies: [
        .Package(url: "http://url/to/bar", branch: "development"),
    ]
)
```

In addition, there is also the option to use a concrete revision instead:

```swift
import PackageDescription

let package = Package(
    name: "foo",
    dependencies: [
        .Package(url: "http://url/to/bar", revision: "0123456789012345678901234567890123456789"),
    ]
)
```

Note that the revision parameter is a string, but it will still be sanity checked by the package manager. It will only accept the full 40 character commit hash here for Git and not a commit-ish or tree-ish. 

Whenever dependencies are checked out or updated, if a dependency on a package specifies a branch instead of a version, the latest commit on that branch will be checked out for that package. If a dependency on a package specifies a branch instead of a version range, it will override any versioned dependencies present in the current package graph that other packages might specify.

For example, consider this graph with the packages A, B, C and D:

A -> (B:master, C:master)
     B -> D:branch1
     C -> D:branch2

The package manager will emit an error in this case, because there are dependencies on package D for both `branch1` and `branch2`.

While this feature is useful during development, a package's dependencies should be updated to point at versions instead of branches before that package is tagged for release. This is because a released package should provide a stable specification of its dependencies, and not break when a branch changes over time. To enforce this, it is an error if a package referenced by a version-based dependency specifies a branch in any of its dependencies.

Running `swift package update` will update packages referencing branches to their latest remote state. Running `swift package pin` will store the commit hash for the currently checked out revision in the pins file, as well as the branch name, so that other users of the package will receive the exact same revision if pinning is enabled. If a revision was specified, users will always receive that specific revision and `swift package update` becomes a no op.

### Pinning to a branch or revision

In addition to specifying a branch or revision in the manifest, we will also allow specifying it when pinning:

```bash
$ swift pin <package-name> --branch <branch-name>
$ swift pin <package-name> --revision <revision>
```

This is meant to be used for situations where users want to temporarily change the source of a package, but it is just an alternative way to get the same semantics and error handling described in the previous section.

## Impact on existing code

There will no impact on existing code.

## Alternative considered

We decided to make using a version-based package dependency with unversioned dependencies an error, because a released package should provide a stable specification of its dependencies. A dependency on a branch could break at any time when the branch is being changed over time.
