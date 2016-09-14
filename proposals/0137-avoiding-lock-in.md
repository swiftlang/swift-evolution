# Avoiding Lock-In to Legacy Protocol Designs

* Proposal: [SE-0137](0137-avoiding-lock-in.md)
* Authors: [Dave Abrahams](https://github.com/dabrahams), [Dmitri Gribenko](https://github.com/gribozavr)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160815/026300.html)

## Introduction

We propose to deprecate or move protocols that shouldn't be a part of
the standard library's public API going forward.

Swift-evolution threads: [Late Pitch](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160808/026071.html), [Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160808/026103.html)

## Motivation

We've always known that when Swift reached ABI stability (now slated for
Swift 4), we would be committed to supporting many of the standard
library's design decisions for years to come.

We only realized very recently that, although Swift 3.0 is *not*
shipping with a stable ABI, the promise that Swift 3.0 code will work
with Swift 4.0 means that many of the standard library's protocols
will be locked down now.  Especially where these protocols show up in
refinement hierarchies, we won't be able to keep Swift 3 code working
in the future without carrying them forward into future standard
library binaries.

## Proposed solution

The proposed changes are as follows:

* Deprecate the `Indexable` protocols with a message indicating that they
  will be gone in Swift 4.  These protocols are implementation details
  of the standard library designed to work around language limitations
  that we expect to be gone in Swift 4.  There's no reason for anyone to
  ever touch these; users should always use a corresponding `Collection`
  protocol (e.g. instead of `MutableIndexable`, use `MutableCollection`).

  See [this pull request](https://github.com/apple/swift/pull/4091)
  for the detailed design. (This pull request was merged prematurely
  but will be reverted if the change isn't approved).
  
* Deprecate the `ExpressibleByStringInterpolation` protocol with a
  message indicating that its design is expected to change.  We know
  this protocol to be
  [mis-designed](https://bugs.swift.org/browse/SR-1260) and
  [limited](https://bugs.swift.org/browse/SR-2303), but there's no
  time to fix it for Swift 3.  If we knew how the new design should
  look, we might be able to calculate that the current API is
  supportable in a forward-compatible way (that's the case for
  `Comparable`, for example).  Unfortunately, we do not know that yet.

  See [this pull request](https://github.com/apple/swift/pull/4121)
  for the detailed design.
  

* Rename `Streamable` to `TextOutputStreamable` and add a deprecated
  `Streamable` typealias for it.  Now that `OutputStream` been renamed
  to `TextOutputStream`, we should also move `Streamable` out of the
  way, at least to reduce confusion if and when the name is reused for
  other purposes.
  
  See the following pull requests for the detailed design.  (These
  pull requests were merged prematurely but will be reverted if the
  change isn't approved).  Multiple pull requests were used to keep
  the contiguous integration system healthy.
  
  - https://github.com/apple/swift/pull/4130
  - https://github.com/apple/swift-package-manager/pull/590
  - https://github.com/apple/swift/pull/4131

## Detailed design

See the pull requests referenced above.

## Impact on existing code

No code will stop compiling or behave differently due to this change,
though the deprecations will produce warnings.  Automatic migration
will handle the renaming of `Streamable`, but other adjustments to
suppress the warnings will have to be made manually.

## Alternatives considered

We considered deprecating much more than just protocols, but on
reconsideration, we think our other legacy APIs do not result in the
same kind of lock-in for the standard library.
