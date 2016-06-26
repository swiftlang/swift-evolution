# Revising access modifiers on extensions

* Proposal: [SE-NNNN](nnnn-extensions-access-modifiers.md)
* Author: [Adrian Zubarev](https://github.com/DevAndArtist)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

One great goal for Swift 3 is to sort out any source breaking language changes. This proposal aims to fix access modifier inconsistency on extensions compared to other scope declarations types.

Swift-evolution thread: [\[Proposal\] Revising access modifiers on extensions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/022144.html)

## Motivation

When declaring members on extensions which don't have an explicit access modifier in Swift 2.2, it is possible to create an **implicitly public extension** by applying a *public* modifier to at least one extension member.

```swift
public struct A { … }

// Implicitly public 
extension A {
	public var member1: SomeType { … }
	
	// Implicitly internal 
	func member2() { … }
}

// Implicitly internal
extension A {

	// Implicitly internal
	var member3: SomeType { … }
}
```

Furthermore in Swift 2.2 it is not allowed to apply an *access modifier* on extensions when a *type inheritance clause* is present:

```swift
public protocol B { … }

// 'public' modifier cannot be used with
// extensions that declare protocol conformances
public extension A : B { … }
```

## Proposed solution

1. Allow access modifier on extensions when a type inheritance clause is present.

2. Remove the behavior of an implicit public extension.

This changes should make access modifier on extensions consistent to classes, structs and enums (and [SE-0025](https://github.com/apple/swift-evolution/blob/master/proposals/0025-scoped-access-level.md)).
	
#### The current grammar will not change:

*extension-declaration* → *access-level-modifier*<sub>opt</sub> **extension** *type-identifier* *type-inheritance-clause*<sub>opt</sub> *extension-body*

*extension-declaration* → *access-level-modifier*<sub>opt</sub> **extension** *type-identifier* *requirement-clause* *extension-body*

*extension-body* → **{** *declarations*<sub>opt</sub> **}**

Iff the *access-level-modifier* is not present, the access modifier on extensions should always be implicitly **internal**.

#### Impact on APIs:

Current version:

```swift
/// Implementation version
///========================

public protocol Y {
	func member()
}

public struct X { … }

// Implicitly public
extension X : Y {
	public func member() { ... }
	
	// Implicitly internal
	func anotherMember() { ... }
}

/// Imported modele version
///========================

public protocol Y {
	func member()
}

public struct X { ... }

// Missing `public` modifier
extension X : Y {
	public func member() { ... }
}
```

New Version:

```swift
/// Implementation version
///========================

public extension X : Y {
	public func member() { ... }
	
	// Implicitly internal 
	func anotherMember() { ... }
}

/// Imported modele version
///========================

public extension X : Y {
	public func member() { ... }
}
```

## Impact on existing code

This is a source-breaking change that can be automated by a migrator, by simply scanning the *extension-body* for at least one *public* modifier on its members. Iff a *public* modifier was found on any member, the migrator can add an explicit *public* modifier to the extension itself.

## Alternatives considered

* No other alternative were considered for this proposal.


## Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
