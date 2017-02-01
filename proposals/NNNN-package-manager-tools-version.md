# Package Manager Tools Version
* Proposal: [SE-NNNN](NNNN-package-manager-tools-version.md)
* Author: [Rick Ballard](https://github.com/rballard)
* Review manager: TBD
* Status: **WIP**

## Introduction

This proposal introduces a "Swift tools version" which is declared for each Swift package.
The tools version declares the minimum version of the Swift tools required to
use the package, determines what version of the PackageDescription API should
be used in the Package.swift manifest, and determines which Swift language
compatibility version should be used to parse the Package.swift manifest.

This feature shall be added to Swift 3.1, to allow packages to manage the transition
from Swift 3 to Swift 4 compatibility.

## Motivation

This proposal addresses three problems with one mechanism.

First, when a package adopts new features of Swift or the Swift Package Manager,
it may no longer be able to be compiled by an older version of the Swift tools,
and older tools may not even be able to interpret its Package.swift manifest.
Without a mechanism to handle this, a package author who tags a version
of their package which uses new features may break the builds of all
clients of that package who are using older tools unless that pacakage adjusts its
major semantic version, which would unnecessarily stop clients who are using the
latest tools from getting that version. This is especially problematic during development of
a new version of the Swift tools, when new features have been added which are not yet
suppoted by the current release of the Swift tools.

Second, one specific planned change for the Swift Package Manager is a revision
of the Package.swift PackageDesciption API, to make it conform to
newer Swift conventions and to correct historical mistakes. In order to support backwards
compatibility, the old version of the PackageDescription API must remain available.
We need some way to determine which version of the PackageDescription API a package
wishes to use.

Finally, as the Package.swift manifest is itself written in Swift, some mechanism
is needed to control which Swift language compatibility version should be used
when interpreting the manifest. This cannot be determined by a compatibility
version property in the manifest itself, as we must know what compatibility version
to interpret the manifest with before we have access to the data in the manifest.

## Proposed solution

Each package will specify a Swift version (the "Swift tools version") which is the minimum version
of the Swift tools currently needed to build that package. This minimum version
will be specified in a file in the package, so it is managed in source
control just like any other package data and may differ for different
tagged versions of the package.

When adopting new or revised PackageDescription API, or when making changes to a Package's source
code which require a new version of Swift, users will be expected to update
the package's Swift tools version to specify that it requires that version
of the Swift tools.

When an incompatible revision is made to the PackageDescription API, the Swift Package Manager
will continue to include the older version of the PackageDescription module for backwards
compatibility. The Swift tools version shall determine which version of the PackageDescription
module will be used when interpreting the Package.swift manifest.

The Swift Tools Version will also determine which Swift language compatibility
version should be used when interpreting the Package.swift manifest.
And it will determine the default Swift language compatibility version used to compile
the package's sources if not otherwise specified.

## Detailed design

When resolving package dependencies, if the version of a dependency that would normally
be chosen specifies a Swift tools version which is greater than the version in use, that
version of the dependency will be considered ineligable and dependency
resolution will continue with evaluating the next-best version. If
no version of a dependency (which otherwise meets the version requirements
from the package dependency graph) supports the version of the Swift tools in use, a
dependency resolution error will result.

When new PackageDescription API is added which would not be understood by a
prior version of the Swift Package Manager, it will be added to the current version
of the PackageDescription module and will not require the package manager to
include a version of the module without that API. However, if that new API is used in the
Package.swift manifest, it will cause the package manager to validate that the
Swift tools version of that package specifies a version of the tools which understands that API,
or to emit an error with instructions to update the Swift tools version if not.
Note that if a [version-specific manifest](https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-manifest-selection)
is present for the older tools version, that tools version will validate as
allowable even when newer features are adopted in the main Package.swift manifest.

The Swift Package Manager may consider the Swift tools version of a package
for other compatibility-related purposes as well. For example, if a
bugfix in a new version of the Swift Package Manager might break older
packages, the fixed behavior might only be applied to packages which have
adopted the newer Swift tools version.

The Swift tools version will be specified in a file named ".swift-version",
at the root level of the package. This file will follow the conventions
already estabished by the [swiftenv](https://github.com/kylef/swiftenv/)
project. The file will contain either a Swift marketing version number
or the name of a snapshot which has been published on Swift.org.

The Swift Package Manager will have a database of known snapshot names which have
been published on Swift.org, as well as which Swift tools version each snapshot
corresponds to. A snapshot shall correspond to the first release which included
or will include that snapshot's content, and all snapshots
of a release in development shall be considered equivalent for the purposes
of the Swift tools version. This feature does not attempt to specify
compatibility between different snapshots during the development of a release, and
only allows snapshot names to be specified to preserve compatibility with swiftenv.

The Swift tools version, as output by package manager commands, will always take
the form of a Swift marketing version (with
one, two, or three version components), the string "future", or the string "trunk".
"future" indicates that the .swift-version file specifies a snapshot name which is unknown and
thus belongs to a future version of Swift. "trunk" indicates that the .swift-version file specifies
a snapshot name which is known to this version of Swift, but which has not yet
been given a designated marketing version. "trunk" shall always be considered
compatible with the current version of package manager, and "future" shall
always be considered incompatible. It is an error to specify "future" or "trunk"
directly in the `.swift-version` file; these specifiers are determined
from the package manager's interpretation of the `.swift-version` file.

A new `swift package tools-version` command will be added to manage the
Swift tools version. This command will behave as follows:

* `swift package tools-version` will report the Swift tools version of the package.

* `swift package tools-version --set <value>` will set the Swift tools version to `value`.
It will also print an informational message advising the user of any changes that this
tools version change will necessitate, depending on what the prior and new tools versions
were. For example, changing the tools version might require converting the Package.swift manifest to
a different Swift language version, and to a different version of the PackageDescription API.

* `swift package tools-version --set-current` will set the Swift tools version to the version
of the tools currently in use.

If no `.swift-version` file is present, the Swift tools version is "3.0".
It is expected that in the future all Swift packages will include a
`.swift-version` file. `swift package init` will create this file and set
it to the marketing version of the tools in use.

The Swift tools version will determine the default Swift language compatibility version
used to compile the package's Swift sources if unspecified, but the Swift language
compatibility version for the package's sources is otherwise decoupled from the
Swift tools version. A separate Swift evolution proposal will describe how
to specify a Swift language compatibility version for package sources.

## Examples

* The author of a package created with Swift 3 wishes to adopt the new Swift 4
product definitions API in their manifest. Using a Swift 4 toolchain, the author first runs
`swift package tools-version --update` to make their package require the Swift 4.0 tools. They then make
any changes to their Package.swift manifest needed to make it compatible with the Swift 4
language version and the revised Swift 4 Package Manager PackageDescription API.
Since their package sources are still written with Swift 3, they should specify
the Swift 3 language compatibility version in their manifest, if they didn't already,
so that it doesn't start defaulting to building the sources as Swift 4 code.
The author is now free to adopt new PackageDescription API in their Package.swift manifest.
They are not required to update the language version of their package sources at the same time.

* A package author wishes to support both the Swift 3 and Swift 4 tools, while
conditionally adopting Swift 4 language features. The author specifies both
Swift language compatibility versions for their package sources (using a
mechanism discussed in a separate evolution proposal). Because their package
needs to support Swift 3 tools, the package's Swift tools version must be set
to `3.1`. Their Package.swift manifest must continue to be compatible with the
Swift 3 language, and must continue to use the Swift 3.1 version of the
PackageDescription API.

* The author of a package created with the Swift 3 tools wishes to convert the package's sources to the Swift 4 language
version. They specify Swift 4 as their package's language compatibility version (using a mechanism
discussed in a separate evolution proposal). When they try to build their package, the package manager
emits an error informing them that they must update their Swift tools version to 4.0 or later, because
the Swift 4 tools are required to build a package when it no longer supports the Swift 3 language version.
The author runs `swift package tools-version --update` to make their package require the Swift 4.0 tools. They then make
any changes to their Package.swift manifest required to make it compatible with the Swift 4
language version and the revised Swift 4 Package Manager PackageDescription API.

## Impact on existing code

There is no impact on existing packages. Since existing packages either have no
.swift-version file, or have a .swift-version which specifies a Swift 3
toolchain or version, those packages will default to building their sources
with the Swift 3 language compatibility mode, and will be able to be
built by both Swift 3 and Swift 4 tools.

Use of the package manager's [version-specific tag selection](https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-tag-selection)
mechanism will no longer be necessary in many situations. Previously, authors needed to employ
that mechanism in order to tag the last version of a package compatible with an old
version of the Swift tools before adopting new Swift features, to avoid break clients
of the package still using the old version of the Swift tools. Now, when adopting new Swift features, a
package author merely needs to set their Swift tools version to that new version, and
dependency resolution performed by an older version of the Swift tools (starting with Swift 3.1) will consider
those new package versions ineligable.

The existing version-specific tag selection mechanism may still be useful for
authors who wish to publish new parallel versions of their package for multiple
versions of the Swift tools.

Use of the package manager's [version-specific manifest selection](https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-manifest-selection)
mechanism may still be useful for authors who wish to conditionally adopt new features of the Swift tool in
their Package.swift manifest without needing to update their Swift tools version to
exclude older versions of Swift.

Packages which have used conditional compilation blocks in the Package.swift
manifest to adopt new PackageDescription features while remaining compatible
with older versions of the Swift tools will no longer be able to do so for future versions
of Swift, and must instead use version-specific manifest selection. This is
because when the newer tools interpret the Package.swift manifest, those tools will see
that new PackageDescription APIs are in use, will not detect the alternate code behind
the conditional compilation blocks, and will thus emit an error requiring the
user to update the Swift tools version to a version which supports those new
APIs.

The following table shows an example of which Swift language version will be used to interpret the Package.swift manifest, and to interpret the package's sources, based on the Swift tools in use and the parameters specified by the package.

|  Swift Tools   | .swift-version | [Swift Language Compatibility Version](http://link/to/proposal) | Language Version Used |
|:---:|:---:|:---:| --- |
| 3.1  | Not Present | Not Present | Manifest: 3 Sources: 3 |
| 3.1  | 3.1  |  Not Present | Manifest: 3 Sources: 3 |
| 3.1  | 3.1  |  3 | Manifest: 3 Sources: 3 |
| 3.1  | 3.1  |  3, 4 | Manifest: 3 Sources: 3 |
| Any | 3.1  |  4 | Error |
| 3.1  | 4.0  |  Any | Error |
| 4.0  | Not Present  | Not Present | Manifest: 3 Sources: 3 |
| 4.0  | 3.1  | Not Present | Manifest: 3 Sources: 3 |
| 4.0  | 3.1  | 3 | Manifest: 3 Sources: 3 |
| 4.0  | 3.1  | 3, 4 | Manifest: 3 Sources: 4 |
| 4.0  | 4.0  | Not Present | Manifest: 4 Sources: 4 |
| 4.0  | 4.0  | 3 | Manifest: 4 Sources: 3 |
| 4.0  | 4.0  | 3, 4 | Manifest: 4 Sources: 4 |
| 4.0  | 4.0  | 4 | Manifest: 4 Sources: 4 |

## Alternatives considered

WIP.

*  Why not just try reparsing manifest in different versions until we find one that parses successfully?

* Why not just rely on conditional compilation, and/or the old version mechanisms?

* Why tie these three needs to one version?

* Why not use semver for this?

* Note that without this, packages either would fail to build with swift 4 without a change to explicitly specify 3,
or would forever default to swift 3 unless specified otherwise

* Explain why extra file isn't a burden (mostly maintain automatically)
