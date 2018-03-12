# Introducing Role Keywords to Protocol Implementations to Reduce Code Errors

* Proposal: SE-TBD
* Author(s):  [Olivier Halligon](http://github.com/AliSoftware), [Caleb Davenport](github.com/calebd), [Brian King](https://github.com/KingOfBrian), [Erica Sadun](http://github.com/erica)
* Status: tbd
* Review manager: tbd

## Introduction

This proposal eliminates several categories of user errors. It mitigates subtle, hard-to-find bugs in Swift protocol code that compile without warning. Introducing "role" keywords that document code intent will increase protocol safety and enable the compiler to test for issues by matching desired behaviors against actual code.

The proposal was designed for minimal language impact. It chooses a conservative approach that can be phased in first over time and language release over more succinct alternatives that would impact existing code bases.

*This proposal was first discussed on the Swift Evolution list in the 
[\[Pitch\] Requiring proactive overrides for default protocol implementations.](http://thread.gmane.org/gmane.comp.lang.swift.evolution/15496) thread. This version has been modified to limit scope and application, with type-implementation impact moved to a possible second proposal. This new version was discussed in the [\[Pitch\] Introducing role keywords to reduce hard-to-find bugs](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170612/037484.html) thread.*

## Motivation

The contents of protocol extensions do one of two things: 
* They can satisfy a required member that is declared in that protocol (or inherited from another protocol) with a default implementation, or 
* They can introduce functionality that is not mentioned in the protocol or its ancestors.

Consider this protocol and extension, which compiles successfully yet contains three potential errors

```swift
protocol ExampleProtocol {
   func thud(with value: Float)
}

extension ExampleProtocol {
    // 1: Near-miss type
    func thud(with value: Double) { ... }
    
    // 2: Near-miss name
    func thus(with value: Float) { ... }
    
    // 3: Accidental satisfaction, intended as extra method
    func thud(with value: Float) { ... }
}
```

Errors 1 and 2 represent near-miss implementations. The first uses the wrong parameter type (`Double`). The second misnames the method (`thus`). Neither error satisfies the protocol requirement with a default implementation as intended. Instead, they provide extended functionality that falls outside the protocol requirements. However both are bugs and will compile without warning.

Error 3 represents an accidental default implementation. Possibly implemented in a separate file, away from the protocol declaration, the coder intends to adds an extra method and accidentally satisfies a protocol requirement. Should it do so, it can introduce a subtle bug to adopting types who may not intend to overlook its implementation, and did not mean to inherit this default, which is likely tied to unrelated semantics.

Error 4 occurs when a coder updates a protocol member name, as demonstrated in the following sample.

```swift
protocol ExampleProtocol {
   func thump(with value: Float) // formerly thud
}

extension ExampleProtocol {
    // 4: Orphaned default implementation after rename
    func thud(with value: Float) { ... }
}
```

Error 4 represents an situation where the intended protocol default implementation *no longer satisfies the protocol requirement*. Renaming a method in the protocol and forgetting to rename the default implementation can lead to hard-to-spot bugs and hidden behavior changes instead of a clear error. Error 4 is most likely to surface in the absence of a conforming type, for example in frameworks and early development

All of these errors are "ghosts". The compiler does not pick up on or respond to any of these mismatches between coder intent and protocol code.

## Proposed Solution

This proposal introduces two optional keywords, nominally called `default` and `extend` (although this can be bikeshedded) to eliminate these four styles of error. Under this system, coders can annotate protocol extensions to ensure compile-time detection of these problems.

The following example demonstrates how the compiler responds to each of the errors enumerated in the previous section. Although the `default` and `extend` keywords can be omitted from the following code, including them enables the compiler to act on intent and expose these errors and fixits.

```swift
extension ExampleProtocol {
    // Error 1
    // Error: Does not satisfy any known protocol requirement
    // Fixit: replace type with Float
    public default func thud(with value: Double) { ... }
    
    // This next line includes the same error as Error 1 
    // but the compiler could not pick up on it because the 
    // auditing `default` role keyword is not included:
    
    // public func thud(with value: Double) { ... }
    
    // Error 2
    // Error: Does not satisfy any known protocol requirement
    // Fixit: replace name with `thud` 
    // (Using nearest match already implemented in compiler)
    public default func thus(with value: Float) { ... }
    
    // Error 3
    // Error: Name overlaps with existing protocol requirement
    // Fixit: replace `extend` keyword with `default`
    // Fixit: rename function signature with `thud_rename_me`
    //        and `FIXME:` annotation
    public extend func thud(with value: Float) { ... }
}

// Error 4
// Demonstrating where the protocol updated a member name
// from `thud` to `thump`. The `default` implementation is 
// no longer properly named.
extension ExampleProtocol { 
    // Error: Does not satisfy any known protocol requirement
    // Fixit: replace `default ` keyword with `extend`
    public default func thud(with value: Float) { ... }
}
```

**Note**: *Swift cannot provide a better fixit under this proposal for the final error. Swift does not provide an annotation mechanism for previous API decisions. That kind of annotation approach (presumably implemented through documentation markup) is out of scope for this proposal.*

## Protocol Inheritance

In Swift, a derived protocol can add a requirement for a member that's already been added as `extend`ed functionality in a parent protocol. This proposal clarifies but does not change Swift’s extension method dispatch rules. A value whose compile-time type conforms to `B` uses the `B.bar()` implementation. In the following example, the `bar` method extends `A` but provides a default in `B`:

```swift
protocol A {
  func foo()
}
extension A {
  extend func bar() { ... }
}
protocol B: A {
  func bar()
}
extension B {
  default func bar() { ... }
}
```

Swift follows the "closest implementation wins". A type conforming to `B` uses the `B.bar()` implementation. If a `B` extension does not supply a `bar` implementation of its own, it inherits the `extend` version from A as is currently the case in Swift 3.

## Impact on Existing Code

As optional "best practices", these changes do not affect existing Swift code. It should be easy for a migrator pass to offer to introduce the keywords to enhance code safety.

## Alternatives and Future Directions

* This proposal does not make role keywords mandatory. Swift would be safer if role annotation were required in extensions, either with `default` or `extend` or equivalent bikeshedded terms. The compiler could be adapted to introduce a Fixit for this.

* If the Swift community were willing to accept heavily warned code without breaking, one of the two keywords (preferably `extend`) could be omitted. Both keywords are needed to ensure that current Swift code will not emit warnings. Requiring `default` for any default implementation distinguishes a dynamically dispatched protocol-sourced method from statically dispatched methods that extend a protocol.

* The Swift compiler can generate warnings for methods in protocol extensions that are not annotated, with a proper Fixit. An opt-in compiler flag would be nice, but the team has enforced a consistent policy of avoiding compiler flags.

* Swift can adopt role keywords to produce better audited implementations in adopting types. An [early discussion](https://gist.github.com/erica/fc66e6f6335750d737e5512797e8284a) recommended an `override` keyword to distinguish type members that overrode default protocol members and `required` for simple protocol-satisfaction. This naming creates a parallel between protocol inheritance and class inheritance.

* In early versions of Swift 2 betas, protocol extension methods were required to specify `final` to exclude dynamic dispatch. This syntax was more confusing than useful after protocol extensions were allowed to fulfill requirements. `final` was removed before the 2.0 GM but it remained valid syntax. 

    [SE-0164](https://github.com/apple/swift-evolution/blob/master/proposals/0164-remove-final-support-in-protocol-extensions.md) removed support for `final` in protocol extensions as it had no semantic meaning. An alternative to this proposal could revert this change, allow `final` in extensions and push these warnings to a linter.

## Acknowledgements and Thanks

Thanks, Doug Gregor, Jordan Rose, and Joe Groff

## Related reading

* [Requiring Proactive Overrides for Default Protocol Implementations](https://gist.github.com/erica/fc66e6f6335750d737e5512797e8284a)
* [The Ghost of Swift Bugs Future](https://nomothetis.svbtle.com/the-ghost-of-swift-bugs-future) by Alexandros Salazar