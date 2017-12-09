# Restrict Cross-module Struct Initializers

* Proposal: [SE-0189](0189-restrict-cross-module-struct-initializers.md)
* Authors: [Jordan Rose](https://github.com/jrose-apple)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 4.1)**
* Implementation: [apple/swift#12834](https://github.com/apple/swift/pull/12834)
* Pre-review discussion: [Restrict Cross-module Struct Initializers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171002/040261.html)
* [Swift Evolution Review Thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171120/041478.html)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171127/041801.html)

<!--
*During the review process, add the following fields as needed:*

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

This actually *is* a distinction we want to make for code in frameworks with binary compatibility constraints, where the ability to add new members to a struct forces client code to use extra indirection. (We've been spelling this `@_fixed_layout`, though that's just a placeholder.) However, enforcing invariants may still be relevant for such a "fixed-layout" struct, and a library author can get nearly the same effect simply by defining a public memberwise initializer, something that's common to do anyway. (If performance is a concern, the initializer can also be marked inlinable.) We don't think there should ever be a reason to annotate a struct as "fixed-layout" in a source package, and we wouldn't want this to become one.


### Allow stored-property-wise initialization just for C structs

C structs are similar to the "fixed-layout" structs described above in that their layout is known at compile time, and since that's just a property of C there's no annotation cost. However, allowing this would create an unnecessary distinction between C structs and Swift structs.

Additionally, there have been requests in the past for a C-side annotation to restrict access to the implicit no-argument and memberwise initializers provided by the Swift compiler. This has been motivated by C structs that do effectively have invariants; just as C++ allows a library author to restrict how a struct may be initialized, so could Swift. This is just a possible future change (and probably unlikely to happen in Swift 5), but it works better with this proposal than without it.


### Add an exception for unit tests

An earlier version of the proposal included an exception for structs in modules imported as `@testable`, allowing unit tests to bypass the restriction that required calling an existing initializer. However, this can already be accomplished by providing an initializer marked `internal` in the original library.

```swift
public struct ExportConfiguration {
  public let speed: Int
  public let signature: String
  public init(from fileURL: URL) {…}
  internal init(manualSpeed: Int, signature: String) {…}
}
```

```swift
import XCTest
@testable import MyApp

class ExportTests: XCTestCase {
  func testSimple() {
    // Still avoids having to load from a file.
    let config = ExportConfiguration(manualSpeed: 5, signature: "abc")
    let op = ExportOperation(config)
  }
}
```

The downside is that the initializer is available to the rest of the module, which probably is not supposed to call it.

Allowing per-stored-property initializers for `@testable` imports is an additive feature; if it turns out to be a common pain point, we can add it in a later proposal. Leaving it out means `@testable` remains primarily about access control.
