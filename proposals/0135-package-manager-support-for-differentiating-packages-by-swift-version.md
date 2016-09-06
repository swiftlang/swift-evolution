# Package Manager Support for Differentiating Packages by Swift version

* Proposal: [SE-0135](0135-package-manager-support-for-differentiating-packages-by-swift-version.md)
* Author: [Anders Bertelrud](https://github.com/abertelrud)
* Review Manager: [Daniel Dunbar](https://github.com/ddunbar)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160801/025955.html)

## Introduction

As new, source-incompatible versions of Swift come into use, there is a growing
need for packages to be authored in a way that makes them usable from multiple
versions of Swift.  While package authors want to adopt new Swift versions as
soon as possible, they also need to support their existing clients.

Source incompatibilities can arise not only from changes to the language syntax,
but also from changes to the Swift Standard Library and the Package Description
API of the Swift Package Manager itself.

Support for multiple Swift versions could in theory be implemented using `#if`
directives in the package source code, but that approach can become unwieldy
when the required code differences are significant.

The Swift Package Manager should therefore provide facilities that make it as
easy as possible for package authors to support clients using different versions
of Swift.  The proposal described here intends to solve an immediate need for
Swift Package Manager 3; the need for version-specific packages will hopefully
diminish as the language and libraries stabilize.  We can revisit the need for
this support in a future version of Swift.

## Motivation

It is important to allow Swift users to migrate to new Swift versions as easily
as possible.  At the same time, packages need to stay compatible with existing
clients who are not yet ready to migrate.

A new version of Swift means a new version of the language, the Standard Library
API, and SwiftPM's own Package Description API.  In some cases it's possible to
use `#if` directives to let a single source base build using different versions
of Swift.  When the code differences are significant, however, it's impractical
to use conditional code, and some other way to differentiate is needed.  This is
particularly true for new versions of the Swift Package Manager, as the manifest
format evolves.

Making this practical requires some improvements to the Package Manager, but to
see why, it is useful to look at why current workarounds would be impractical:

###### Impractical workaround #1:

A strategy that wouldn't require any Swift Package Manager changes would be to
require package authors to tie the semantic versions([1](http://semver.org)) of
their packages to specific versions of Swift itself.  For example, a package
author could decide that version 1 of their package would work only with Swift
2.3, and package version 2 would work only with Swift 3.

Using different package versions for the different Swift versions would take
advantage of the Package Manager's existing version matching logic to make sure
that the right package is chosen, and the right package for the Swift version
would automatically be chosen.

However, this doesn't seem like a particularly acceptable restriction, since
it ties the release cycles of packages to those of Swift itself.  This coupling
between new Swift versions and new versions of all packages in use by a client
would introduce significant revlock, which may seriously impact adoption.  In
particular, a client that wanted or needed to migrate to a new version of a
package couldn't do so until they also migrated to a new version of Swift
itself.  In addition, they would at the same time have to migrate to newer
versions of any other package on which they depend (assuming that such newer
versions even exist).

This is particularly unfortunate in cases in which only the package manifest
needs to be different, since that would cause a package that could otherwise
support multiple Swift versions to have to bifurcate.

What is needed is a way to allow differentiation of packages by not just their
own semantic version, but also the version of Swift being used.

###### Impractical workaround #2:

Another possible strategy would be to choose package version numbers that also
incorporate the version of Swift they require, thereby "flattening" the two
version numbers involved (package version and Swift version) into one.

One could come up with various schemes for this, such as assigning odd-valued
package version numbers to prerelease versions of the Swift language, and
even-valued package version numbers to release versions of the Swift language.

But this would pollute the version space, and it also sends the wrong message
about semantic versioning  (which is a strategy that we want package authors to
use).  Encouraging the abuse of the major version number for other things than
the package API is not in the best interest of the maintainability of the
package ecosystem.

## Solution Goals

The solution needs to:

1. ensure that the established package ecosystem graph continues to work as-is,
   even as packages supporting new Swift versions are published
   
2. support parallel co-existence of actively maintained package graphs for:

   - the latest stable (release) version of Swift

   - the most recent pre-release version of Swift

   - any older versions of Swift that still need to be supported

(note that "Swift version" here includes not just the syntax of the language,
but also the Standard Library API and the Package Description API)

The Swift Package Manager should make it as easy as possible for a package to
support multiple Swift versions using a single package repository, when that
is possible with respect to the magnitude of the requires source differences).

An additional, more abstract goal, is to encourage the whole Swift ecosystem
to move forward as quickly as possible.  This means optimizing for a workflow
that involves latest-GM, current-prerelease, and current-development version,
but ideally not a long tail of old GM versions.

## Proposed Solution

There are two parts to the proposed solution:

1.  provide package authors with a way to differentiate package repository
    version tags by Swift version, to support multiple editions of a single
    semantic package version
    
2.  provide package authors with a way to provide multiple package manifests
    for a single package version tag, differentiated by Swift version

In both cases, version-based name suffixes are used to allow Package Manager
to resolve dependencies based on package version as well as Swift version.

### Version-differentiated package tags

When selecting the version of a package dependency to use for a particular
client, the Swift Package Manager uses a repository tag naming convention
based on the specified version restrictions of the package.

For example, a client that specifies this dependency in its `Package.swift`:

```swift
.Package(url: "https://github.com/apple/example-package-deckofplayingcards.git",
		 majorVersion: 2)
```

causes the package manager to look for tags in the form of a semantic version
(see [semver.org](http://semver.org) for more information).

In this example, only tags having a major version number of 2 are considered,
and the highest version among them is the one that is selected.

Other restrictions involving minor versions and version ranges can be specified
in the client's `Package.swift` manifest.

Regardless of how the desired version restrictions are specified, the highest
semantic version that matches the restrictions is the one that is selected when
resolving dependencies.

This proposal would allow an optional Swift version to appended to the package
version, separated from it by a `@swift-` string.

This can be used to provide two separate tags for the same package version,
differentiated only by Swift version.  For example, version 1.0 of MyPackage
could have a `1.0@swift-2.3` tag and a `1.0@swift-3` tag.

The expected use case for this is when the differences required to support two
or more versions of Swift are large enough that it would be impractical to
implement them in the same checkout of the repository.

The new logic would first look for tag names having such a Swift version suffix
that matches the version of Swift the client wants to use, and if found, omits
from consideration any tags that do not have that suffix.  The existing logic
would be applied to the remaining set of tag candidates.

The format of the swift version is not itself a semantic version, but instead
follows the Swift marketing versions used.  For matching, the number of digits
specified affects the precision of the matching; for example, `@swift-3` would
match any version Swift 3.x.x version, while `@swift-3.0` would match only
Swift 3.0.x but not Swift 3.1 etc.

The most specific version suffix matching the client's Swift version is used.
For example, if both a `@swift-3` and a `@swift-3.1` tag are found, Swift 3.1
would use the latter and Swift 3.2 would use the former.

If no tag names have the Swift version suffix, the matching would work as it
currently does, using only the package version restrictions.

### Version-differentiated package manifests

Creating Swift-versioned tags for a particular package version has maintenance
consequences. When possible, it's more maintainable for a package to support
multiple Swift versions in a single tag of a repository.  In the ideal case,
no source changes are required at all in order to support two different Swift
versions (this is the case, for example, between Swift 2.2 and Swift 2.3).

When the required changes are minimal and a single package manifest can be used,
`#if` directives in the source code can be used to support any other differences
between the Swift versions.  This already works today.

For the `Package.swift` manifest itself, though, it can be somewhat unwieldy
to express differences using only `#if` directives.  This is the case whether
the differences are due to language syntax changes (recall that `Package.swift`
manifests are actually Swift source files) or due to changes in the Package
Description API.

To support this, this proposal would allow a Swift version to be appended to
the base `Package` base name, separated from it by the string `@swift-`.  For
example, a package manifest specific to Swift 2.3 would have the file name
`Package@swift-2.3.swift`, while one that worked for any Swift 3.x version
would be `Package@swift-3.swift`.

As with versioned tags, in the absence of a version-specific `Package.swift`
file, the Package Manager would use the regular `Package.swift` file.

Often, a package author would use either version-differentiated package tags or
version-differentiated package manifests, but they could also be used together
when that makes sense.

It is hoped that as the Swift language stabilizes and packages eventually drop
support for older versions of Swift, many packages will be able to discard the
version-specific variants and keep only `Package.swift`.

## Impact on existing code

There is not expected to be any impact on existing code, since this proposal
adds on top of existing functionality.

## Alternatives

1.  Do nothing and let package authors invent their own ways.  For the reasons
    spelled out in the _Motivation_ section, this very undesirable.  However,
    given how close we are to Swift 3's completion date, there is a possibility
    that there will not be time to implement this proposal for Swift 3.
    
    The consequence would be that future changes to the Package Description API
    would cause existing packages to break, which could significantly obstruct
    package adoption of new versions of Swift.
    
2.  Add declarations to the `Package.swift` manifest to specify the required
    Swift version or version range.  This has a number of problems, including
    the fact that all of the various manifests would need to be checked out
    before deciding which to exclude from consideration.  Another problems is
    that such minimum-version requirement declarations would have to be able
    to be parsed by older versions of the Package Manager, and this is not a
    guarantee we can make (the manifest might not be parseable using an older
    version of Swift).
