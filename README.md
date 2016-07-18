# Swift Programming Language Evolution

**Before you initiate a pull request**, please read the process document. Ideas should be thoroughly discussed on the [swift-evolution mailing list](https://swift.org/community/#swift-evolution) first.

This repository tracks the ongoing evolution of Swift. It contains:

* Goals for upcoming Swift releases (this document).
* The [Swift evolution review status][proposal-status] tracking proposals to change Swift.
* The [Swift evolution process](process.md) that governs the evolution of Swift.
* [Commonly Rejected Changes](commonly_proposed.md), proposals which have been denied in the past.

This document describes goals for the Swift language on a per-release
basis, usually listing minor releases adding to the currently shipping
version and one major release out.  Each release will have many
smaller features or changes independent of these larger goals, and not
all goals are reached for each release.

Goals for past versions are included at the bottom of the document for
historical purposes, but are not necessarily indicative of the
features shipped. The release notes for each shipped version are the
definitive list of notable changes in each release.

## Development major version:  Swift 3.0

Expected release date: Late 2016

The primary goal of this release is to solidify and mature the Swift language and
development experience.  While source breaking changes to the language have been
the norm for Swift 1 through 3, we would like the Swift 3.x (and Swift 4+)
languages to be as *source compatible* with Swift 3.0 as reasonably possible.
However, this will still be best-effort: if there is a really good reason to
make a breaking change beyond Swift 3, we will consider it and find the least
invasive way to roll out that change (e.g. by having a long deprecation cycle).

To achieve this end, Swift 3 focuses on getting the basics right for the
long term: 

* **API design guidelines**: The way in which Swift is used in popular
  libraries has almost as much of an effect on the character of Swift
  code as the Swift language itself. The [API naming and design
  guidelines](https://swift.org/documentation/api-design-guidelines/) are a
  carefully crafted set of guidelines for building great Swift APIs.

* **Automatic application of naming guidelines to imported Objective-C APIs**:
  When importing Objective-C APIs, the Swift 3 compiler 
  [automatically maps](proposals/0005-objective-c-name-translation.md) methods
  into the new Swift 3 naming guidelines, and provides a number of Objective-C
  features to control and adapt this importing.

* **Adoption of naming guidelines in key APIs**: The Swift Standard Library has
  been significantly overhauled to embrace these guidelines, and key libraries
  like [Foundation](proposals/0069-swift-mutability-for-foundation.md) and
  [libdispatch](proposals/0088-libdispatch-for-swift3.md) have seen major
  updates, which provide the consistent development experience we seek.

* **Swiftification of imported Objective-C APIs**: Beyond the naming guidelines,
  Swift 3 provides an improved experience for working with Objective-C APIs.
  This includes importing
  [Objective-C generic classes](proposals/0057-importing-objc-generics.md),
  providing the ability to [import C APIs](proposals/0044-import-as-member.md)
  into an "Object Oriented" style, much nicer
  [imported string enums](proposals/0033-import-objc-constants.md), safer
  syntax to work with [selectors](proposals/0022-objc-selectors.md) and
  [keypaths](proposals/0062-objc-keypaths.md), etc.

* **Focus and refine the language**: Since Swift 3 is the last release to make
  major source breaking changes, it is also the right release to reevaluate the
  syntax and semantics of the core language.  This means that some obscure or
  problematic features will be removed, we focus on improving consistency of
  syntax in many small ways (e.g. by 
  [revising handling of parameter labels](proposals/0046-first-label.md), and
  focus on forward looking improvements to the type system.  This serves the
  overall goal of making Swift a simpler, more predictable, and more consistent
  language over the long term.

* **Improvements to tooling quality**: The overall quality of the compiler is
  really important to us: it directly affects the joy of developing in Swift.
  Swift 3 focuses on fixing bugs in the compiler and IDE features, improving the
  speed of compile times and incremental builds, improving the performance of
  the generated code, improving the precision of error and warning messages, etc.

One of the reasons that stability is important is that **portability** to non-Apple
systems is also a strong goal of Swift 3.  This release enables
broad scale adoption across multiple platforms, including significant
functionality in the [Swift core libraries](https://swift.org/core-libraries/)
(Foundation, libdispatch, XCTest, etc).  A useful Linux/x86 port is
already available (enabling many interesting server-side scenarios), and work is
underway across the community to bring Swift to FreeBSD, Raspberry Pi, Android,
Windows, and others.  While we don't know which platforms will reach a useful
state by the launch of Swift 3, significant effort continues to go into making
the compiler and runtime as portable as practically possible.

Finally, Swift 3 also includes a mix of relatively small but important additions
to the language and standard library that make solving common problems easier and
make everything feel nicer.  A detailed list of accepted proposals is included
on the [proposal status page][proposal-status].


## Swift 2.2 - Released on March 21, 2016

[This release](https://swift.org/blog/swift-2-2-released/) focused on fixing
bugs, improving quality-of-implementation (QoI)
with better warnings and diagnostics, improving compile times, and improving
performance.  It put some finishing touches on features introduced in Swift 2.0, 
and included some small additive features that don't break Swift code or
fundamentally change the way Swift is used. As a step toward Swift 3, it
introduced warnings about upcoming source-incompatible changes in Swift 3
so that users can begin migrating their code sooner.

Aside from warnings, a major goal of this release was to be as source compatible
as practical with Swift 2.0.

[review-status]: https://apple.github.io/swift-evolution/
