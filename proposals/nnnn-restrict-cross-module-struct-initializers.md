# Restrict Cross-module Struct Initializers

* Proposal: [SE-NNNN](NNNN-non-exhaustive-enums.md)
* Authors: [Jordan Rose](https://github.com/jrose-apple)
* Review Manager: TBD
* Status: **Awaiting review**

<!--
*During the review process, add the following fields as needed:*

* Pull Request: [apple/swift#FIXME]()
* Pre-review discussion: FIXME
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

Adding a property to a public struct in Swift ought to not be a source-breaking change. However, a client in another target can currently extend a struct with a new initializer that directly initializes the struct's fields. This proposal forbids that, requiring any cross-target initializers to use `self.init(…)` or assign to `self` instead. This matches an existing restriction for classes, where cross-module initializers must be convenience initializers.


## Motivation

Swift structs are designed to be flexible, allowing library authors to change their implementation between releases. This goes all the way to changing the set of stored properties that make up the struct. Since initializers have to initialize every stored property, they have two options:

- Assign each property before returning or using `self`.
- Assign all properties at once by using `self.init(…)` or `self = …`.

The former requires knowing every stored property in the struct. If all of those properties happen to be public, however, a client in another target can implement their own initializer, and suddenly adding a new stored property (public or not) becomes a source-breaking change.

Additionally, initializers are often used with `let` properties to enforce a struct's invariants. Consider this (contrived) example:

```swift
public struct BalancedPair {
  public let positive: Int
  public let negative: Int
  public init(absoluteValue: Int) {
    assert(absoluteValue >= 0)
    self.positive = absoluteValue
    self.negative = -absoluteValue
  }
}
```

At this point a user of BalancedPair ought to be able to assume that `positive` and `negative` always hold opposite values. However, an unsuspecting (or malicious) client could add their own initializer that breaks this invariant:

```swift
import ContrivedExampleKit
extension BalancedPair {
  init(positiveOnly value: Int) {
    self.positive = value
    self.negative = 0
  }
}
```

Anything that prevents the library author from enforcing the invariants of their type is a danger and contrary to the spirit of Swift.


## Proposed solution

If an initializer is declared in a different module from a struct, it must use `self.init(…)` or `self = …` before returning or accessing `self`. Failure to do so will produce a warning in Swift 4 and an error in Swift 5.

The recommendation for library authors who wish to continue allowing this is to explicitly declare a public memberwise initializer for clients in other modules to use.


### C structs

C structs are not exempt from this rule, but all C structs are imported with a memberwise initializer anyway. This *still* does not guarantee source compatibility because C code owners occasionally decide to split up or rename members of existing structs, but this proposal does not make that situation worse. Most C structs also have a no-argument initializer that fills the struct with zeros unless one of the members is marked `_Nonnull`.


## Source compatibility

This makes existing code invalid in Swift 5, which is a source compatibility break.

This makes adding a stored property to a struct a source-compatible change (except for Swift 4 clients that choose to ignore the warning).


## Effect on ABI stability

This is required for structs to avoid exposing the layout of their properties in a library's binary interface.


## Effect on Library Evolution

It is now a binary-compatible change to add a public or non-public stored property to a struct.

It is still not a binary-compatible change to remove a public stored property from a struct.


## Alternatives considered

### Do nothing

We've survived so far, so we can live without this for libraries that don't have binary compatibility concerns, but not being able to enforce invariants is still a motivating reason to do this proposal.


### Distinguish between "structs with a fixed set of stored properties" and "structs that may get new stored properties later"

This actually *is* a distinction we want to make for code in frameworks with binary compatibility constraints, where the ability to add new members to a struct forces client code to use extra indirection. However, this should be an advanced feature in the language, and limiting its use to binary frameworks is a good way to keep it out of the way for most developers. A library author can get nearly the same effect simply by defining a public memberwise initializer, something that's common to do anyway.