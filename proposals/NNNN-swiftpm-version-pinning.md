# Package Manager Version Pinning

* Proposal: SE-XXXX
* Author: [Daniel Dunbar](https://github.com/ddunbar), [Ankit Aggarwal](https://github.com/aciidb0mb3r), [Graydon Hoare](https://github.com/graydon)
* Review Manager: TBD
* Status: Discussion

## Introduction

This is a proposal for adding package manager features to "pin" or "lock" package dependencies to particular versions.

## Motivation

As used in this proposal, version pinning refers to the practice of controlling
*exactly* which specific version of a dependency is selected by the dependency
resolution algorithm, *independent from* the semantic versioning
specification. Thus, it is a way of instructing the package manager to select a
particular version from among all of the versions of a package which could be
chosen while honoring the dependency constraints.

### Terminology

*We have chosen to use "pinning" to refer to this feature, over "lockfiles", since
the term "lock" is already overloaded between POSIX file locks and locks in
concurrent programming.*

### Mechanism and policy

This proposal primarily addresses the _mechanism_ used to record
and manage version-pinning information, in support of _specific
workflows_ with elevated demands for reproducable builds.

In addition to this, certain _policy_ choices around default
behavior are included; these are set initially to different
defaults than in many package managers. Specfically the default
behaviour is to _not_ generate pinning information unless
requested, for reasons outlined in the alternatives discussion.

If the policy choice turns out to be wrong, the default can be
changed without difficulty.

### Use Cases

Our proposal is designed to satisfy several different use cases for such a behavior:

1. Standardizing team workflows

When collaborating on a package, it can be valuable for team members (and
continuous integration) to all know they are using the same exact version of
dependencies, to avoid "works for me" situations.

This can be particularly important for certain kinds of open source projects
which are actively being cloned by new users, and which want to have some
measure of control around exactly which available version of a dependency is
selected.

2. Difficult to test packages or dependencies

Complex packages which have dependencies which may be hard to test, or hard to
analyze when they break, may choose to maintain careful control over what
versions of their upstream dependencies they recommend -- even if conceptually
they regularly update those recommendations following the true semantic version
specification of the dependency.

3. Dependency locking w.r.t. deployment

When stabilizing a release for deployment, or building a version of a package
for deployment, it is important to be able to lock down the exact versions of
dependencies in use, so that the resulting product can be exactly recreated
later if necessary.

## Proposed solution

We will introduce support for an **optional** new file `Package.pins` adjacent
to the `Package.swift` manifest, called the "pins file". We will also introduce
a number of new commands (see below) for maintaining the pins file.

This file will record the active version pin information for the package,
including data such as the package identifier, the pinned version, and explicit
information on the pinned version (e.g., the commit hash/SHA for the resolved
tag).

The exact file format is unspecified/implementation defined, however, in
practice it will be a JSON data file.

This file *may* be checked into SCM by the user, so that its effects apply to
all users of the package. However, it may also be maintained only locally (e.g.,
placed in the `.gitignore` file). We intend to leave it to package authors to
decide which use case is best for their project.

In the presence of a top-level `Package.pins` file, the package manager will
respect the pinned dependencies recorded in the file whenever it needs to do
dependency resolution (e.g., on the initial checkout or when updating).

The pins file will not override Manifest specified version requirements and it
will be an error (with proper diagnostics) if there is a conflict between the pins
and the manifest specification.

The pins file will also not influence dependency resolution for dependent packages;
for example if application A depends on library B which in turn depends on library C,
then package resolution for application A will use the manifest of library B to learn
of the dependency on library C, but ignore any `Package.pins` file belonging to
library B when deciding which version of library C to use.

## Detailed Design

1. We will add a new command `pin` to `swift package` tool with following semantics:

	```
	$ swift package pin ( [--all] | [<package-name>] [<version>] ) [--message <message>]
	```
    
	The `package-name` refers to the name of the package as specified in its manifest.

	This command pins one or all dependencies. The command which pins a single version can optionally take a specific version to pin to, if unspecified (or with --all) the behaviour is to pin to the current package version in use. Examples:  
	* `$ swift package pin --all` - pins all the dependencies.
	* `$ swift package pin Foo` - pins `Foo` at current resolved version.
	* `$ swift package pin Foo 1.2.3` - pins `Foo` at 1.2.3. The specified version should be valid and resolvable.

 The `--reason` option is an optional argument to document the reason for pinning a dependency. This could be helpful for user to later remember why a dependency was pinned. Example:   
 
	`$ swift package pin Foo --reason "The patch updates for Foo are really unstable and need screening."`


2. Dependencies are never automatically pinned, pinning is only ever taken as a result of an explicit user action.
 
3. We will add a new command `unpin`:

	```
	$ swift package unpin ( [--all] | [<package-name>] )
	``` 
	This is the counterpart to the pin command, and unpins one or all packages.

4. We will fetch and resolve the dependencies when running the pin commands, in case we don't have the complete dependency graph yet.

5. We will extend the workflow for update to honour version pinning, that is, it will only update packages which are unpinned, and it will only update to versions which can satisfy the existing pins. The update command will, however, also take an optional argument `--repin`:

	```
	$ swift package update [--repin]
	```

	* Update command errors if there are no unpinned packages which can be updated.

	* Otherwise, the behaviour is to update all unpinned packages to the latest possible versions which can be resolved while respecting the existing pins.

	* The `[--repin]` argument can be used to lift the version pinning restrictions. In this case, the behaviour is that all packages are updated, and packages which were previously pinned are then repinned to the latest resolved versions.

6. The update and checkout will both emit logs, notifying the user that pinning is in effect.

7. The `swift package show-dependencies` subcommand will be updated to indicate if a dependency is pinned.

8. As a future extension, we anticipate using the SHA information recorded in a pins file as a security feature, to prevent man-in-the-middle attacks on parts of the package graph.

## Impact on existing code

There will be change in the behaviours of `swift build` and `swift package update` in presence of the pins file, as noted in the proposal however the existing package will continue to build without any modifications.

## Alternative considered

### Pin by default

Much discussion has revolved around a single policy-default
question: whether SwiftPM should generate a pins file as a matter
of course any time it builds. This is how some other package
managers work, and it is viewed as a conservative stance
with respect to making repeatable builds more likely between
developers. Developers will see the pins file and will be likely
to check it in to their SCM system as a matter of convention.

While pinning does reduce the risk of packages failing to build,
it encourages package overconstraint, which is more of a risk
in Swift than in many other languages. Specifically: Swift does
not support linking multiple versions of a dependency into the same
artifact at the same time. Therefore the risk of producing a
"dependency hell" situation, in which two packages individually
build but _cannot be combined_ due to over-constrained transitive
dependencies, is significantly higher than in other languages.

For example, if package `Foo` depends on library `LibX` version 1.2,
and package `Bar` depends on `LibX` 1.3, and these are _specific_
version constraints that do not allow version-range variation,
then SwiftPM will _not_ allow building a product that depends on
both `Foo` and `Bar`: their requirements for `LibX` are incompatible.
Where other package managers will simultaneously link two versions
of `LibX` -- and hope that the differing simultaneous uses of
`LibX` do not cause other compile-time or run-time errors -- 
SwiftPM will simply fail to resolve the dependencies.

We therefore wish to encourage library authors to keep their
packages building and testing with as recent and as wide a range
of versions of their dependencies as possible, and guard more
vigorously than other systems against accidental overconstraint.
One way to encourage this behaviour is to avoid emitting pins files
by default.

If, in practice, the resulting ecosystem either contains too many
packages that fail to build, or if a majority of users emit pins files
manually regardless of default, this policy choice can be revisited.
