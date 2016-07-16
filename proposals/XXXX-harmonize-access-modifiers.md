# Harmonize access modifiers for extensions

* Proposal: [SE-XXXX](XXXX-harmonize-access-modifiers.md)
* Author: [Xiaodi Wu](https://github.com/xwu)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

During discussion of [SE-0119](0119-extensions-access-modifiers), the community articulated the view that access modifiers for extensions were and should continue to be subject to the same rules as access modifiers for types. Unfortunately, it is not factually true today; this proposal aims to make it so.

Swift-evolution threads:

* [\[Proposal\] Revising access modifiers on extensions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/022144.html)
* \[More to be added here\]

## Motivation

Consider the following:

```
public struct foo {
  func frobnicate() { } // implicitly internal
}
public extension foo { }

public struct bar { }
public extension bar {
  func frobnicate() { } // implicitly public
}
```

In [Swift 2](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/Swift_Programming_Language/AccessControl.html), a method moved from the body of a public struct into a public extension becomes public without modification. This is surprising behavior contrary to Swift's general rule of not exposing public API by default, but it is preserved for Swift 3 as detailed in [SE-0025](0025-extensions-access-modifiers).

Furthermore, SE-0025 now permits the owner of a type to design access for members as though the type will have a higher access level than it currently does. For example, users will be able to design `public` methods inside an `internal` type before "flipping the switch" and making that type `public`. The same approach is prohibited by SE-0025 for extensions, although conceptually it need not be.


## Proposed solution

The proposed solution is to change access modifier rules for extensions with the following effect: if any method (or computed property) declared within the body of a type at file scope is moved without modification into the body of an extension in the same file, the move will not change its accessibility.

In code:

```
struct foo {
  // Any method declared here...
}
extension foo {
  // ...should have the same visibility when moved here.
}
```

This implies that public API commitments will need to be annotated as `public` at declaration sites inside an extension just as it must be at declaration sites inside types.

## Detailed design

1. Declarations inside the extension will, like declarations inside types, have a default access level of `internal`.
2. The compiler should not warn when a broader level of access control is used for a method (or computed property, etc.) declared within an extension with more restrictive access. This allows the owner of the extension to design the access level they would use for a method if the type or extension were to be made more widely accessible.
3. An extension declared without an explicit access modifier will have the same access level as the type being extended.
4. An extension declared without protocol conformance may optionally use an explicit access modifier to provide an upper bound for the visibility of its members.

## Alternatives considered

*  One alternative, still open for consideration, is to eliminate #4 and disallow explicit access modifiers on extensions. As an advantage, this would clarify the mental model that extensions are not their own entities, as they cannot be referred to by name and have no runtime representation. As a disadvantage, extensions cease to be an access modifier grouping construct, which some users really like.

## Acknowledgments

Thanks to all discussants on the list, especially Adrian Zubarev and Jose Cheyo Jimenez.

## Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
