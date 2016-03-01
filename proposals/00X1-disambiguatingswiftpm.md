# Disambiguating SwiftPM Naming Conflicts

* Proposal: TBD
* Author(s): [Erica Sadun](http://github.com/erica)
* Status: TBD
* Review manager: TBD

## Introduction

I propose to modify SwiftPM's `PackageDescription` to allow developers to assign local module names to avoid module conflicts. This namespacing proposal supports a decentralized packaging ecosystem to handle the rare case of name overlaps without requiring a central package registry.

This proposal was discussed on the Swift-Dev and Swift-Build-Dev lists in the "[Right List?](http://article.gmane.org/gmane.comp.lang.swift.devel/1149)" thread.

## Motivation

Swift offers a built in mechanism for distinguishing symbol conflicts. When working with `NSView`, I take care to differentiate `Swift.print`, which outputs text to the console or stream from `NSView`'s  `print`, which creates a print job. Swift does not yet offer a solution for conflicting module names.

Like many other Swift developers, I have spent considerable time building utility packages. Mine use obvious names like `SwiftString` and `SwiftCollections`. Simple clear naming is a hallmark of Swift design. At the same time, this style introduces the possibility of package name conflicts. 

```swift
import SwiftString // mine
import SwiftString // someone else's. oops.
```

Two `SwiftString` packages cannot be used simultaneously without some form of namespace resolution. Moving back to Cocoa-style `ESSwiftString` namespacing feels ugly and antithetical to Swift design. Swift should encourage recognizable, easy-to-understand module names. This proposal addresses this rare but possible conflict.

## Detail Design

Under this proposal, renaming occurs when declaring dependencies. Package descriptions looks like this under the current system:

```swift
import PackageDescription
let package = Package (
    name: "MyUtility",
    dependencies: [
	.Package(url: "https://github.com/erica/SwiftString.git",
                 majorVersion: 1),
	.Package(url: "https://github.com/bob/SwiftString.git",
                 majorVersion: 1),
    ]
)
```

Under this proposal, the Package dependency gains an optional `importAs` parameter. When `importAs` is omitted, a module uses the name of the repo's package.

```swift
import PackageDescription
let package = Package (
    name: "MyUtility",
    dependencies: [
	.Package(url: "https://github.com/erica/SwiftString.git",
                 majorVersion: 1, importAs: "SadunString"), // import SadunString
	.Package(url: "https://github.com/bob/SwiftString.git",
                 majorVersion: 1, importAs: "BobString"), // import BobString
	.Package(url: "https://github.com/erica/SwiftCollections.git",
                 majorVersion: 1), // import SwiftCollections
    ]
)
```

Remaining module name clashes should produce compiler errors.

## Alternatives Considered

#### Original Design

I first considered namespacing using reverse domain naming in Package declarations. This offers a traditional approach to identify a module's source:

```swift
import PackageDescription

let package = Package(
    name:   "SwiftString"
    origin: "org.sadun"
)
```

Reverse domain names

* are relatively short
* are already well established for Apple app distribution
* do not rely on a web address that may change should the repo move
* are less likely to conflict with user names across repo hosts 

However concise, using reverse domain names bring unnecessary verbiage to name conflicts. Consider the following example.

```swift
import org.sadun.SwiftString
import com.other.SwiftString

...

// Use my implementation of countSyllables
let count = org.sadun.SwiftString.countSyllables(myString)
```

In this example, `org.sadun.SwiftString.countSyllables` places a burden both on writing and reading code. Surely there has to be a better solution.

Adapting `import` statements resolves symbols but has negative side effects:

```swift
import org.sadun.SwiftString as SadunString
import com.other.SwiftString as OtherString

...

// Use my implementation of countSyllables
let count = SadunString.countSyllables(myString)
```

1. This approach requires Swift language modification
2. Import redeclarations may be required across multiple files

[Joe Groff](https://github.com/jckarter) suggested a simpler approach: allow package manifests to take responsibility for mapping dependencies to source-level module names.

#### Other alternatives

Swift names should be as simple and elegant as possible without overlapping with built-in keywords. Other suggestions brought up in-discussion included:

* Using GitHub or Bitbucket usernames as namespacing prefixes, e.g. `erica.SwiftString`. This would not be resilient across cross-repo username conflicts.
* Using repo URLs to resolve namespacing conflicts. This would be fragile if repos moved and does not address local module name resolution.
* Introducing a registration index for packages. I believe this is not necessary or desirable.

## Acknowledgements
Thanks to [Joe Groff](https://github.com/jckarter), [Ankit Aggarwal](https://github.com/aciidb0mb3r), Max Howell, Daniel Dunbar, Kostiantyn Koval