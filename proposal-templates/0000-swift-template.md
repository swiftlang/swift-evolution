# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Author 1](https://github.com/swiftdev), [Author 2](https://github.com/swiftdev)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

A short description of what the feature is. Try to keep it to a
single-paragraph "elevator pitch" so the reader understands what
problem this proposal is addressing.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Describe the problems that this proposal seeks to address. If the
problem is that some common pattern is currently hard to express, show
how one can currently get a similar effect and describe its
drawbacks. If it's completely new functionality that cannot be
emulated, motivate why this new functionality would help Swift
developers create better Swift code.

## Proposed solution

Describe your solution to the problem. Provide examples and describe
how they work. Show how your solution is better than current
workarounds: is it cleaner, safer, or more efficient?

## Detailed design

Describe the design of the solution in detail. If it involves new
syntax in the language, show the additions and changes to the Swift
grammar. If it's a new API, show the full API and its documentation
comments detailing what it does. The detail in this section should be
sufficient for someone who is *not* one of the authors to be able to
reasonably implement the feature.

## Source compatibility

Relative to the Swift 3 evolution process, the source compatibility
requirements for Swift 4 are *much* more stringent: we should only
break source compatibility if the Swift 3 constructs were actively
harmful in some way, the volume of affected Swift 3 code is relatively
small, and we can provide source compatibility (in Swift 3
compatibility mode) and migration.

Will existing correct Swift 3 or Swift 4 applications stop compiling
due to this change? Will applications still compile but produce
different behavior than they used to? If "yes" to either of these, is
it possible for the Swift 4 compiler to accept the old syntax in its
Swift 3 compatibility mode? Is it possible to automatically migrate
from the old syntax to the new syntax? Can Swift applications be
written in a common subset that works both with Swift 3 and Swift 4 to
aid in migration?

## Effect on ABI stability

The ABI comprises all aspects of how code is generated for the
language and how that code interacts with the Swift runtime library.
It includes such things as calling conventions, function signatures,
the layout of data types, and the behavior of dynamic features in
the language ssuch as reflection, dynamic dispatch, and dynamic
casting.  It also includes things such as the addition of functions
and types to the public symbols of a library.

Many language proposals have no direct impact on the ABI.  For
example, a proposal to add the `typealias` declaration would have
no effect on the ABI because type aliases are not represented
dynamically and uses of them in code can be straightforwardly
translated into uses of the aliased type.  Such proposals can
simply state in this section that they have no impact on the ABI.
However, if *using* the feature in code that must maintain a stable
ABI can have a surprising ABI impact, that should be discussed
in this section.

Because Swift has a stable ABI on some platforms, proposals are
generally not acceptable if they would require changes to the ABI
of existing language features or declarations.  For example,
Swift could not accept a feature which, in order to work, would
require parameters with certain types to always be passed as owned
values, because parameters are not always passed as owned values
in the ABI.  Proposals must be designed to avoid the need for this.
For example, the feature above might only be enabled for parameters
marked a special way, and then adding that marking to an existing
function parameter would change the ABI of that function.

Proposals are acceptable if they can be thought of as merely
*adding* to the ABI, such as by adding new kinds of declarations,
adding new modifiers or attributes that can be used on existing
kinds of declarations, or adding new types or methods to the Swift
standard library.  On platforms with stable ABIs, such features
will by default require a new release of the platform in order
to work, and so their use in code that may deploy to older
releases will have to be availability-guarded.  If this limitation
applies to any part of this proposal, that should be discussed
in this section.

Adding a function to the standard library does not always require
an addition to the ABI if it can be implemented using other
library functions.  Library maintainers may be able to help you
with this during the code review of your implementation.  Adding
a type or protocol always requires an addition to the ABI.

If a feature does require additions to the ABI, platforms with
stable ABIs may sometimes be able to back-deploy those additions
to existing releases of the platform.  This is not always possible,
and in any case, it is outside the scope of the evolution process.
Proposals should usually discuss ABI stability concerns as if
it was not possible to back-deploy the necessary ABI additions.

## Effect on API resilience

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.

## Acknowledgments

If significant changes or improvements suggested by members of the 
community were incorporated into the proposal as it developed, take a
moment here to thank them for their contributions. Swift evolution is a 
collaborative process, and everyone's input should receive recognition!
