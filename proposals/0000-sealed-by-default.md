# Sealed classes by default

* Proposal: [SE-NNNN](0000-sealed-by-default.md)
* Author: [Javier Soto](https://github.com/JaviSoto)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Introduce a new `sealed` class modifier that makes classes and methods `final`
outside of the module they're declared in, but non-`final` within the module.

Swift-evolution thread: [Discussion thread topic for that proposal](http://thread.gmane.org/gmane.comp.lang.swift.evolution/9702/focus=9708)

## Motivation

- It is not uncommon to have a need for a reference type without needing
inheritance. Classes must be intentionally designed to be subclassable, carefully
deciding which methods are the override entry-points such that the the behavior
remains correct and subclasses respect the [Liskov substitution principle](https://en.wikipedia.org/wiki/Liskov_substitution_principle).
- Defaulting to non-`final` allows the author of a class to accidentally leave the
visible methods open for overrides, even if they didn't carefully consider this
possibility.
- Requiring that the author of a class mark a class as `open` is akin to requiring
symbols to be explicitly `public`: it ensures that a conscious decision is made
regarding whether the ability to subclass a `class` is part of the API.

## Proposed solution

- New `sealed` class modifier for classes and methods which marks them as only
overridable within the module they're declared in.
- `sealed` becomes the default for classes and methods.
- New `open` (*actual name pending bike-shedding*) class modifier to explicitly
mark a class or a method as `overridable`.

## Detailed design

Code Examples:

```swift
/// ModuleA:

/// This class is `sealed` by default.
/// This is equivalent to `sealed class SealedParentClass`
class SealedParentClass {
	/// This method is `sealed` by default`.
	func foo()

	/// This raises a compilation error: a method can't have a "subclassability"
	/// level higher than that of its class.
	open func bar()

	/// The behavior of `final` methods remains unchanged.
	final func baz()
}

open class OpenParentClass {
	/// This method is `sealed` by default`.
	func foo()

	/// Overridable methods in an `open` class must be explicitly marked as `open`.
	open func bar()

	/// The behavior of a `final` method remains unchanged.
	final func baz()
}

/// The behavior of `final` classes remains unchanged.
final class FinalClass { }
```

```swift
/// ModuleB:

import ModuleA

/// This raises a compilation error: ParentClass is effectively `final` from
/// this module's point of view.
class SubclassA : SealedParentClass { }

/// This is allowed since `OpenParentClass` has been marked explicitly `open`
class SubclassB : OpenParentClass {
	/// This raises a compilation error: `OpenParentClass.foo` is
	/// effectively `final` outside of `ModuleA`.
	override func foo() { }

	/// This is allowed since `OpenParentClass.bar` is explicitly `open`.
	override func bar() { }
}
```

## Impact on existing code

- This would be a backwards-breaking change for all classes and methods that are
public and non-final, which code outside of their module has overriden.
Those classes/methods would fail to compile. Their superclass would need to be
changed to `open`.


## Alternatives considered

- Defaulting to `final` instead:
This would be comparable to Swift defaulting to `private`, as opposed to `internal`.
Just like `internal` is a better trade-off, `sealed` by default also makes sure
that getting started with Swift, writing code within a module, doesn't require a
lot of boilerplate, and fighting against the compiler.
