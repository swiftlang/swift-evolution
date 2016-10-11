# Package Manager Version Pinning

* Proposal: SE-XXXX
* Author: [Daniel Dunbar](https://github.com/ddunbar), [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: TBD
* Status: Discussion

## Introduction

This is a proposal for adding package manager features to "pin" or "lock" package dependencies to particular versions. 

## Motivation

* Complex packages might want to maintain tight control over their upstream dependencies.
* There is sometimes need to pin a certain problematic third party dependency.
* It will also serve as a mechanism for dependency locking i.e. locking down the entire graph of dependencies.

## Proposed solution

Persist the contents of a dependency resolution result in a file named `Package.pins` (pins file). This file is analogous to "lock" files in dependency managers however the term "lock" is deliberately avoided so it is not confused with UNIX style lock files.  
It will record information related to the dependency resolution result like: Package, the pinned version, and explicit information on the pinned version (e.g., the commit hash/SHA for the resolved tag).  
The file format is unspecified/implementation detail at this point, however it will most likely be JSON.

The file will live along side the Manifest (i.e. package root) and can be checked into SCM by the user. It will be generated and modified automatically by the Package Manager and users are not expected to modify it by hand.

In presence of `Package.pins` file, Package Manager will respect the pinned dependencies recorded in the file while performing dependency resolution or initial checkout.

The pins file will not override Manifest specified version requirements and it will be an error (with proper diagnostics) if there is a conflict between pins and Manifest specification.

## Detailed Design

1. We will add a new command `pin` to `swift package` tool with following format:

	```
	$ swift package pin ( [--all] | [<package-name>] [<version>] ) [--message <message>]
	```
	The `package-name` refers to the name of the package as specified in Manifest.

	This command pins one or all dependencies. The command which pins a single version can optionally take a specific version to pin to, if unspecified (or with --all) the behaviour is to pin to the current package version in use. Examples:  
	* `$ swift package pin --all` - pins all the dependencies.
	* `$ swift package pin Foo` - pins `Foo` at current resolved version.
	* `$ swift package pin Foo 1.2.3` - pins `Foo` at 1.2.3. The specified version should be a valid and resolvable.

 The `--message` option is an optional argument to record the reason/message for pinning a dependency. This could be helpful for user to later remember why a dependency was pinned. Example:   
 
	`$ swift package pin Foo --message "The patch updates for Foo are really unstable and needs screening."`


2. Adding a new dependency in manifest file will not automatically pin it, and can be pinned using the pin command.
 
3. We will add a new command `unpin`:

	```
	$ swift package unpin ( [--all] | [<package-name>] )
	``` 
	This is the counterpart to the pin command, and unpins one or all packages.

4. We will fetch and resolve the dependencies when running the pin commands, in case we don't have the complete dependency graph yet.

5. We will extend the workflow for update to honour version pinning. The update command will take an optional argument `--repin`:

	```
	$ swift package update [--repin]
	```

	* Update command errors if there are no unpinned packages which can be updated.

	* Otherwise, the behaviour is to update all unpinned packages to the latest possible versions which can be resolved while respecting the existing pins.

	* The `[--repin]` argument can be used to lift the version pinning restrictions. In this case, the behaviour is that all packages are updated, and packages which were previously pinned are then repinned to the latest resolved versions.

6. The update and checkout will both emit logs, notifying the user that pinning is in effect.

7. The `swift package show-dependencies` subcommand will be updated to indicate if a dependency is pinned.

## Impact on existing code

There will be change in the behaviours of `swift build` and `swift package update` in presence of the pins file, as noted in the proposal however the existing package will continue to build without any modifications.

## Alternative considered

We considered making the pinning behavior default on running `swift build`, however we think that pinning by default makes the package graph more constrained than it should be. It drives the user away from taking full advantage of semantic versioning. We think it will be good for the package ecosystem if such a restriction is not a default behavior and it might also lead to faster discovery of bugs and fixes in the upstream. 
