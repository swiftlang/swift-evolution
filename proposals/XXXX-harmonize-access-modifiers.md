# Harmonize access modifiers for extensions

* Proposal: [SE-XXXX](XXXX-harmonize-access-modifiers.md)
* Author: [Xiaodi Wu](https://github.com/xwu)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

During discussion of [SE-0119](0119-extensions-access-modifiers.md), some voiced concern that writing `public extension` increases the default access level for members declared within that extension, whereas writing `public class` or `public struct` does not do the same.

This behavior is explained as follows: since extensions have no runtime representation and are not first-class entities, access modifiers on extensions serve as a shorthand to set the default access level for members. Certain members of the community have indicated that such behavior makes extensions a natural grouping construct.

A general principle of Swift, recently strengthened by proposals such as [SE-0117](0117-non-public-subclassable-by-default.md), has been that public API commitments should require explicit opt-in. Given the different behavior of classes and structs, the fact that extensions allow public methods to be declared without spelling out `public` at the declaration site has been called "confusing" or "odd."

The aim of this proposal is to, in as conservative a manner as possible, require explicit use of `public` for public methods declared inside any extension.

Swift-evolution threads:

* [\[Proposal\] Revising access modifiers on extensions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/022144.html)
* [\[Review\] SE-0119: Remove access modifiers from extensions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160711/024224.html)
* [\[Draft\] Harmonize access modifiers for extensions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160711/024522.html)

## Motivation

Consider the following:

```
public struct foo {
  func frobnicate() { } // internal
}
public extension foo { }

public struct bar { }
public extension bar {
  func frobnicate() { } // public
}
```

This outcome is explained by rules regarding access modifiers specifically on extensions [Swift 2](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/Swift_Programming_Language/AccessControl.html), which is slated for preservation in Swift 3 as detailed in [SE-0025](0025-scoped-access-level.md). However, it is arguably surprising that, of two declarations spelled identically, one leads to a public API commitment while the other does not.

## Proposed solution

The proposed solution is to amend access modifier rules to eliminate the possibility of defaulting the access level of members declared inside an extension to `public`.

## Detailed design

Amend access modifier rules as follows:

An extension may optionally be marked with an explicit access modifier that specifies the default scope \[see SE-0025\]. However, such an explicit modifier _must not match (or exceed) the original type's access level_.

This rule would preserve the possibility of using extensions as grouping constructs. At the same time, it would (1) remove the possibility of writing `public extension` to default the access level of members to `public`; and (2) clarify the notion that an access modifier on an extension is a shorthand and not a way to create a first-class entity by disallowing repeating of the original type's access level.

_Explicit_ access modifiers will continue to set the maximum allowed access within an extension, as clarified in SE-0025.

## Alternatives considered

One alternative is to eliminate explicit access modifiers on extensions altogether. As an advantage, this would further clarify the mental model that extensions are not their own first-class entities. As a disadvantage, extensions cease to be an access modifier grouping construct, which some users really like.

## Acknowledgments

Thanks to all discussants on the list, especially Adrian Zubarev, Jose Cheyo Jimenez, and Paul Cantrell.

## Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
