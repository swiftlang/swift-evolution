# Availability by Swift version

* Proposal: [SE-0141](0141-available-by-swift-version.md)
* Author: [Graydon Hoare](https://github.com/graydon)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3.1)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161003/027604.html)
* Bug: [SR-2709](https://bugs.swift.org/browse/SR-2709)

## Introduction

Swift's existing `@available(...)` attribute indicates the lifecycle of a
given declaration, either unconditionally or relative to a particular
platform or OS version range.

It does not currently support indicating declaration lifecycle relative to
Swift language versions. This proposal seeks to extend it to do so.

Swift-evolution threads:
 [Draft](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160919/027213.html),
[Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160919/027247.html)

## Motivation

As the Swift language progresses from one version to the next, some
declarations will be added, renamed, deprecated or removed from the
standard library. Existing code written for earlier versions of Swift will
be supported through a `-swift-version N` command-line flag, that runs the
compiler in a backward-compatibility mode for the specified "effective"
language version.

When running in a backward-compatibility mode, the set of available
standard library declarations should change to match expectations of older
code. Currently the only mechanism for testing a language version is the
compiler-control statement `#if swift(>= N)` which is a static construct:
it can be used to compile-out a declaration from the standard library, but
evolving the standard library through this mechanism would necessitate
compiling the standard library once for each supported older language
version.

It would be preferable to compile the standard library _once_ for all
supported language versions, but make declarations _conditionally
available_ depending on the effective language version of a _user_ of the
library. The existing `@available(...)` attribute is similar to this
use-case, and this proposal seeks to extend the attribute to support it.

## Proposed solution

The `@available(...)` attribute will be extended to support specifying
`swift` version numbers, in addition to its existing platform versions.

As an example, an API that is removed in Swift 3.1 will be written
as:

~~~~
@available(swift, obsoleted: 3.1)
class Foo {
  //...
}
~~~~

When compiling _user code_ in `-swift-version 3.0` mode, this declaration
would be available, but not when compiling in subsequent versions.

## Detailed design

The token `swift` will be added to the set of valid initial arguments
to the `@available(...)` attribute. It will be treated similarly,
but slightly differently, than the existing platform arguments. In
particular:

  - As with platform-based availability judgments, a declaration's
    `swift` version availability will default to available-everywhere
    if unspecified.

  - A declaration's `swift` version availability will be considered
    in logical conjunction with its platform-based availability.
    That is, a given declaration will be available if and only
    if it is _both_ available to the current effective `swift` version
    _and_ available to the current deployment-target platform.

  - Similar to the abbreviated form of platform availability, an
    abbreviated form `@available(swift N)` will be permitted as a synonym
    for `@available(swift, introduced: N)`. However, adding `swift` to
    a platform availability abbreviation list will not be allowed. That is,
    writing the following examples is not permitted:

    - `@available(swift 3, *)`
    - `@available(swift 3, iOS 10, *)`

    This restriction is due to the fact that platform-availability lists
    are interpreted disjunctively (as a logical-_OR_ of their arguments),
    and adding a conjunct (logical-_AND_) to such a list would make
    the abbreviation potentially ambiguous to readers.

## Impact on existing code

Existing code does not use this form of attribute, so will not be
affected at declaration-site.

As declarations are annotated as unavailable or obsoleted via
this attribute, some user code may stop working, but the same risk exists
(with a worse user experience) in today's language any time declarations
are removed or conditionally-compiled out. The purpose of this proposal
is to provide a better user experience around such changes, and facilitate
backward-compatibility modes.

## Alternatives considered

The main alternative is compiling libraries separately for each language
version and using `#if swift(>=N)` to conditionally include varying APIs.
For a library used locally within a single project, recompiling for a
specific language version may be appropriate, but for shipping the standard
library it is more economical to compile once with all declarations, and
select a subset based on language version.
