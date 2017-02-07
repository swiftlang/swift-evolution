# Package Manager Tools Version
* Proposal: [SE-0152](0152-package-manager-tools-version.md)
* Author: [Rick Ballard](https://github.com/rballard)
* Review Manager: Anders Bertelrud
* Status: **Active review (February 7...February 13, 2017)**

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
clients of that package who are using older tools unless that package adjusts its
major semantic version, which would unnecessarily stop clients who are using the
latest tools from getting that version. This is especially problematic during development of
a new version of the Swift tools, when new features have been added which are not yet
supported by the current release of the Swift tools.

Second, one specific planned change for the Swift Package Manager is a revision
of the Package.swift PackageDescription API for Swift 4, to make it conform to
Swift conventions and to correct historical mistakes. In order to support backwards
compatibility, the old version of the PackageDescription API must remain available.
We need some way to determine which version of the PackageDescription API a package
wishes to use.

Finally, as the Package.swift manifest is itself written in Swift, some
mechanism is needed to control which Swift language compatibility version should
be used when interpreting the manifest. This cannot be determined by a property
on the Package object in the manifest itself, as we must know what compatibility
version to interpret the manifest with before we have access to data specified
by Swift code in the manifest.

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

The Swift Package Manager will continue to include the Swift 3 version of the
PackageDescription module for backwards compatibility, in addition to including
the new version of the PackageDescription module, as designed in a forthcoming
evolution proposal. The Swift tools version shall determine which version of the
PackageDescription module will be used when interpreting the Package.swift
manifest.

The Swift Tools Version will also determine which Swift language compatibility
version should be used when interpreting the Package.swift manifest.
And it will determine the default Swift language compatibility version used to compile
the package's sources if not otherwise specified.

## Detailed design

When resolving package dependencies, if the version of a dependency that would normally
be chosen specifies a Swift tools version which is greater than the version in use, that
version of the dependency will be considered ineligible and dependency
resolution will continue with evaluating the next-best version. If
no version of a dependency (which otherwise meets the version requirements
from the package dependency graph) supports the version of the Swift tools in use, a
dependency resolution error will result.

New PackageDescription API will be added as needed for upcoming features. When
new API is used in a Package.swift manifest, it will cause the package manager
to validate that the Swift tools version of that package specifies a version of
the tools which understands that API, or to emit an error with instructions to
update the Swift tools version if not. Note that if a [version-specific manifest](https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-manifest-selection)
is present for the older tools version, that tools version will validate as
allowable even when newer features are adopted in the main Package.swift
manifest.

The Swift tools version will determine the default Swift language compatibility version
used to compile the package's Swift sources if unspecified, but the Swift language
compatibility version for the package's sources is otherwise decoupled from the
Swift tools version. A separate Swift evolution proposal will describe how
to specify a Swift language compatibility version for package sources.

The Swift Package Manager may consider the Swift tools version of a package
for other compatibility-related purposes as well. For example, if a
bugfix in a new version of the Swift Package Manager might break older
packages, the fixed behavior might only be applied to packages which have
adopted the newer Swift tools version.

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

If a package does not specify a Swift tools version, the Swift tools version is
"3.0.0". It is expected that in the future all Swift packages will specify a
Swift tools version. `swift package init` will set the Swift tools version of a
package it creates to the version of the tools in use.

### How the Swift tools version is specified

The Swift tools version will be specified by a special comment in the first line
of the Package.swift manifest. This is similar to how a DTD is defined for XML
documents. To specify a tools version, a Package.swift file must begin with the
string `// swift-tools-version:`, followed by a version number specifier.

Though the Swift tools version refers to a Swift marketing version number and is
not a proper semantic version, the version number specifier shall follow the
syntax defined by [semantic versioning 2.0.0](http://semver.org/spec/v2.0.0.html),
with an amendment that the patch version component shall be optional and shall
be considered to be `0` if not specified. As we expect that patch versions will
not affect tools compatibility, the package manager will automatically elide the
patch version component when appropriate, including when setting a version using
the `swift package tools-version --set-current` command, to avoid unnecessarily
restricting package compatibility to specific patch versions. The semver syntax
allows for an optional pre-release version component or build version component;
those components will not be used by the package manager currently, but may be
used in a future release to provide finer-grained compatibility controls during
the development of a new version of Swift.

After the version number specifier, an optional `;` character may be present;
it, and anything else after it until the end of the first line, will be ignored by
this version of the package manager, but is reserved for the use of future
versions of the package manager.

The package manager will attempt to detect approximate misspellings of the Swift
tools version comment. As such, it is an error if the first line of the file
begins with `//`, contains the string `swift-tools-version` (with any
capitalization), but is not otherwise a valid tools version comment. Any other first
line of the file will not be considered to be a Swift tools version comment, in
which case the Swift tools version will be considered to be `3.0.0`.

## Examples

* The author of a package created with Swift 3 wishes to adopt the new Swift 4
product definitions API in their manifest. Using a Swift 4 toolchain, the author
first runs `swift package tools-version --update` to make their package require
the Swift 4.0 tools. They then make any changes to their Package.swift manifest
needed to make it compatible with the Swift 4 language version and the revised
Swift 4 Package Manager PackageDescription API. Since their package sources are
still written with Swift 3, they should specify the Swift 3 language
compatibility version in their manifest, if they didn't already, so that it
doesn't start defaulting to building their sources as Swift 4 code. The author
is now free to adopt new PackageDescription API in their Package.swift manifest.
They are not required to update the language version of their package sources at
the same time.

* A package author wishes to support both the Swift 3 and Swift 4 tools, while
conditionally adopting Swift 4 language features. The author specifies both
Swift language compatibility versions for their package sources (using a
mechanism discussed in a separate evolution proposal). Because their package
needs to support Swift 3 tools, the package's Swift tools version must be set
to `3.1`. Their Package.swift manifest must continue to be compatible with the
Swift 3 language, and must continue to use the Swift 3.1 version of the
PackageDescription API.

* The author of a package created with the Swift 3 tools wishes to convert the
package's sources to the Swift 4 language version. They specify Swift 4 as their
package's language compatibility version (using a mechanism discussed in a
separate evolution proposal). When they try to build their package, the package
manager emits an error informing them that they must update their Swift tools
version to 4.0 or later, because the Swift 4 tools are required to build a
package when it no longer supports the Swift 3 language version. The author runs
`swift package tools-version --update` to make their package require the Swift
4.0 tools. They then make any changes to their Package.swift manifest required
to make it compatible with the Swift 4 language version and the revised Swift 4
Package Manager PackageDescription API.

## Impact on existing code

There is no impact on existing packages. Since existing packages do not specify
a Swift tools version, they will default to building their sources
with the Swift 3 language compatibility mode, and will be able to be built
by both Swift 3 and Swift 4 tools.

Use of the package manager's [version-specific tag selection](https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-tag-selection)
mechanism will no longer be necessary in many situations. Previously, authors needed to employ
that mechanism in order to tag the last version of a package compatible with an old
version of the Swift tools before adopting new Swift features, to avoid break clients
of the package still using the old version of the Swift tools. Now, when adopting new Swift features, a
package author merely needs to set their Swift tools version to that new version, and
dependency resolution performed by an older version of the Swift tools (starting with Swift 3.1) will consider
those new package versions ineligible.

The existing version-specific tag selection mechanism may still be useful for
authors who wish to publish new parallel versions of their package for multiple
versions of the Swift tools.

Use of the package manager's [version-specific manifest selection](https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-manifest-selection)
mechanism may still be useful for authors who wish to conditionally adopt new features of the Swift tools in
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

The following table shows an example of which Swift language version will be
used to interpret the Package.swift manifest, and to interpret the package's
sources, based on the Swift tools in use and the parameters specified by the
package.

|  Swift Tools   | Swift Tools Version | [Swift Language Compatibility Version](http://link/to/proposal) | Language Version Used |
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

We considered a number of alternative approaches that might avoid the need for
adding this new Swift tools version; however, we think that this proposal
is compelling compared to the alternatives considered.

### Don't change the PackageDescription manifest API

If we chose not to change the PackageDescription API, we would not need a way
to determine which version of the module to use when interpreting a manifest.
However, we think that it is important for this API to be made compliant with
the Swift language conventions, and to review the API with our community.
It would be best to do this now, while the Swift package ecosystem is relatively
young; in the future, when the ecosystem is more mature, it will be more
painful to make significant changes to this API.

Not changing this API would still leave the problem of figuring out which
Swift language compatibility version to interpret the manifest in. It's possible
that Package.swift manifests won't be significantly affected by Swift
language changes in Swift 4, and could mostly work in either language compatibility
mode without changes. However, we don't know whether that will be the case,
and it would be a significant risk to assume that it will be.

Finally, we will need to add new API to the PackageDescription module to
support new features, and without a Swift tools version, adoption of new features
would break existing clients of a package that aren't using the latest tools.

### Rely on conditional compilation blocks

We could choose to ask package authors to use Swift conditional compilation
blocks to make their manifests compatible with both Swift 3 and Swift 4.
Unfortunately, this might be a lot of work for package authors, and result in a
hard-to-read manifests, if the PackageDescription API changes or Swift 4
language changes are significant.

Another major downside of this approach is that until package authors do the
work of adding conditional compilation blocks, their packages would fail to
build with the Swift 4 tools. In order to build with the Swift 4 tools, you'd
both need to update your own packages with conditional compilation, and you'd
need to wait for any packages you depend upon to do the same. This could be a
major obstacle to adopting the Swift 4 tools.

Finally, we are not convinced that all authors would bother to add conditional
compilation blocks to preserve Swift 3 compatibility when they update their
packages for the Swift 4 tools. Any packages which were updated but not given
conditional compilation blocks would now break the builds of any clients still
using the Swift 3 tools.

### Rely on semantic versioning

We could expect that package authors bump their packages' major semantic version
when updating those packages for the Swift 4 tools, thereby preventing clients
who were still using the Swift 3 tools from automatically getting the updated
version of their dependency and failing to build. There are several problems with
this approach.

First, this does nothing to allow packages to be used with new Swift tools without
needing to be updated for those tools. We don't want package authors to need
to immediately adopt the Swift 4 language compatibility version and PackageDescription
API before they can build their package with the new tools. Using a Swift
tools version allows us to support multiple versions of the PackageDescription
API and the Swift language, so existing packages will continue to work
with newer tools automatically.

Second, this forces clients of a package to explicitly opt-in to updated
versions of their dependencies, even if there was otherwise no API change.
The Swift tools version mechanism that we have proposed allows packages
to automatically get updated versions of their dependencies when using Swift
tools that are new enough to be able to build them, which is preferable.

Finally, we are not confident that all package authors would reliably update
their semantic version when updating their package for newer tools. If they failed
to do so, clients still using the older Swift tools would fail to build.

### Relying on the package manager's existing versioning mechanisms

In Swift 3, the package manager introduced two versioning mechanisms:
[version-specific tag selection](https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-tag-selection),
and [version-specific manifest selection](https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-manifest-selection).
These mechanisms can be used to publish updated versions of a package without
breaking the builds of clients who are still using older Swift tools. We think
that these mechanisms are still useful and can be used in concert with the
Swift tools version, as described in the "Impact on existing code" section.
However, they are insufficient to completely solve the versioning problem.

These mechanisms allow a package to be updated for new Swift tools without
breaking clients who are still using older Swift tools, but they do not allow
a package that has not been updated to be built with new Swift tools. Again,
we don't want package authors to need to immediately adopt the Swift 4 language
compatibility version and PackageDescription API before they can build their
package with the new tools.

These mechanisms are also opt-in and may not be known to all package authors.
If a package author fails to explicitly adopt these mechanisms when updating
a package, they will break the builds of clients that are still using older
Swift tools. In contrast, the Swift tools version mechanism that we have proposed works
by default without requiring package authors to know about extra opt-in
mechanisms.

### Automatically re-interpret Package.swift manifest in different modes

We considered having the package manager automatically try to reinterpret
a Package.swift manifest in different modes until it finds a mode that
can successfully interpret it, so that we wouldn't need an explicit specifier
of which Swift language compatibility version or PackageDescription module version
the Package.swift manifest is using.

We saw three major problems with this. First, this would make it very difficult
to provide high quality diagnostics when a manifest has an error or warning.
If the manifest cannot be interpreted cleanly in any of the supported modes,
we'd have no way to know which mode it should have been interpreted in --
or whether the required mode is even known to the version of the Swift
tools in use. That means that the errors we provide might be incorrect
with respect to the actual version of the Swift language or the PackageDescription
module that the manifest targets.

Second, any subtle incompatibilities introduced by a difference in Swift language
compatibility versions could cause the manifest to interpret without errors
in the wrong mode, but result in unexpected behavior.

Finally, this could cause performance problems for the package manager. Because
the package manager needs to interpret Package.swift manifests from potentially
many packages during dependency resolution, forcing it to interpret
each manifest multiple times could add an undesirable delay to the
`swift build` or `swift package update` commands.

### Provide finer-grained versioning controls

In this proposal we've provided a single versioning mechanism which controls multiple
things: the Swift language compatibility version used to parse the manifest,
the version of the PackageDescription module to use, and the minimum version
of the tools which will consider a package version eligible during dependency
resolution. We could instead provide separate controls for each of these
things. However, we feel that doing so would add unnecessary complexity to
the Swift package manager. We do not see a compelling use-case for needing
to control these different features independently, so we are consolidating
them into one version mechanism as a valuable simplification.

### Rename the PackageDescription module

We considered giving the new version of the PackageDescription module
a different name, and having users change the import statement in their
Package.swift when they want to adopt the revised PackageDescription API.
This would mean that the package manager would not automatically switch
which version of the PackageDescription module to use based on the Swift
tools version. However, this did not seem like a better experience for our
users. It would also allow users to import both modules, which we do not
want to support. And it would allow users to continue using the old
PackageDescription API in a manifest that is otherwise updated for
Swift 4, which we also do not want to support.

### Store the Swift tools version in a separate file

Instead of storing the Swift tools version in a comment at the top of the
Package.swift manifest, we considered storing it in a separate file.
Possibilities considered were to either store it as JSON in a
`.swift-tools-version` file, or to store it in a `.swift-version` file in the
format already established by the [swiftenv](https://github.com/kylef/swiftenv/)
tool.

Reasons we prefer to store this in the Package.swift manifest include:

* Keeping the Swift tools version in the same file as the rest of the manifest
data eliminates the possibility of forgetting to include both the Package.swift
manifest and a file specifying the Swift tools version in every commit which
should affect both. Users may also find it more convenient to only need to
commit a single file when making manifest changes.

* Users may like being able to see the Swift tools version when reading a
Package.swift manifest, instead of needing to look in a separate file.

* Supporting the `.swift-version` standard would require supporting toolchain
names as a standing for a Swift tools version, which complicates this mechanism
significantly.

### Specify the Swift tools version with a more "Swifty" syntax

Several alternative suggestions were given for how to spell the comment that
specifies the Swift tools version. We could make it look like a line of Swift
code (`let toolsVersion = ToolsVersion._3_1`), a compiler directive
(`#swift-pm(tools-version: 3.1)`), or use camel case in the comment  (`//
swiftToolsVersion: 3.1`). We rejected the former two suggestions because this
version is not actually going to be interpreted by the Swift compiler, so it's
misleading to make it appears as if it is a valid line of Swift code. Embedding
metadata in a leading comment is a strategy with a clear precedent in XML &
SGML. For the latter suggestion, we are preferring kebab-case
(`swift-tools-version`) because it is distinct from normal Swift naming, and
more clearly stands out as its own special (tiny) language, which it is.
