# Feature name

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author: Austin Zheng
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

The current `protocol<>` construct, which defines an existential type consisting of zero or more protocols, should be renamed `Any<>`.

## Motivation

A stated goal for Swift 3.0 is making breaking changes to prepare the way for features to be introduced in future features, especially those involving the enhancements to the generics system detailed in [*Completing Generics*](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md).

One such change described in *Completing Generics* is renaming `protocol<>` to `Any<>` in order to allow it to serve as a syntactic foundation for more generalized existential types. This is a straightforward change which will allow a later version of Swift to introduce better handling for existential types without making breaking changes, or changes whose functionality overlaps with that of existing features.

Discussion thread: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/018109.html

## Proposed solution

The `protocol<>` construct should be replaced with the `Any<>` construct, where zero or more protocol names can be inserted between the angle brackets to denote protocol composition. There will be no changes to the behavior of `Any<>` relative to `protocol<>`.

`Any` will retain the same function and behavior as it did prior to Swift 3.0. The language should define `Any` and `Any<>` to be equivalent.

Trivial example:

```swift
protocol A { }
protocol B { }

struct Foo : A, B { }

let a : Any<A, B> = Foo()
```

## Impact on existing code

Programmers will need to update any code using `protocol<>` (this can be done with a simple find and replace operation). Code that uses `Any`, but no protocol composition, will be unaffected.

## Alternatives considered

A couple alternatives follow.

* Leave `protocol<>` as-is, and decide whether to change it after Swift 3.0 ships. This has the disadvantage of introducing a breaking source change.

* Decide before Swift 3.0 ships that generalized existentials should be defined using a syntax besides the `protocol<>` or `Any<>` syntaxes, and adopt that syntax instead. Disadvantages: core team has no bandwidth to consider changes of this scope at the current time.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
