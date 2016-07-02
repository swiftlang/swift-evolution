# Default classes to be non-subclassable publicly

* Proposal: [SE-NNNN](0000-non-public-subclassable-by-default.md)
* Authors: [Javier Soto](https://github.com/JaviSoto), [John McCall](https://github.com/rjmccall)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Change the default overridability of public classes and methods to be non-extensible
outside of the module they're declared in.
For this, new class and method modifiers are needed to override the default and
make them extensible / overridable.

Swift-evolution thread: http://thread.gmane.org/gmane.comp.lang.swift.evolution/21930/

## Motivation

- It is not uncommon to have a need for a reference type without needing
inheritance. Classes must be intentionally designed to be subclassable, carefully
deciding which methods are the override entry-points such that the the behavior
remains correct and subclasses respect the [Liskov substitution principle](https://en.wikipedia.org/wiki/Liskov_substitution_principle).
- Defaulting to non-`final` allows the author of a class to accidentally leave the
visible methods open for overrides, even if they didn't carefully consider this
possibility.
- Requiring that the author of a class mark a class as subclassable is akin to
requiring symbols to be explicitly `public`: it ensures that a conscious decision
is made regarding whether the ability to subclass a `class` or override a method
is part of the API.

## Proposed solution

- `public class` and `public func` allow classes and methods respectively to be
subclassed and overriden **only** within the module they're declared in.
- `public subclassable class` makes a class subclassable outside of the
module it's declared in.
- `public overridable func` makes a method of a `subclassable` class overridable
outside of the module it's declared in.

(*Actual names pending bike-shedding, see section below for spelling alternatives*)

## Detailed design

Code Examples:

```swift
/// ModuleA:

/// This class is not subclassable by default.
public class NonSubclassableParentClass {
	/// This method is not overridable.
	public func foo()

	/// This raises a compilation error: a method can't be marked `public overridable`
	/// if the class it belongs to can't be subclassed.
	public overridable func bar()

	/// The behavior of `final` methods remains unchanged.
	final func baz()
}

public subclassable class SubclassableParentClass {
	/// This method is not overridable by default.
	public func foo()

	/// Overridable methods in a `subclassable` class must be explicitly marked as `overridable`.
	public overridable func bar()

	/// The behavior of a `final` method remains unchanged.
	public final func baz()
}

/// The behavior of `final` classes remains unchanged.
public final class FinalClass { }
```

```swift
/// ModuleB:

import ModuleA

/// This raises a compilation error:
/// `NonSubclassableParentClass` is not subclassable from this module.
class SubclassA : NonSubclassableParentClass { }

/// This is allowed since `OpenParentClass` has been marked explicitly `subclassable`.
class SubclassB : SubclassableParentClass {
	/// This raises a compilation error: `SubclassableParentClass.foo` is not
	/// `overridable` outside of `ModuleA`.
	override func foo() { }

	/// This is allowed since `SubclassableParentClass.bar` is explicitly `overridable`.
	override func bar() { }
}
```

## Note on Objective-C classes

Since there's no way to mark an Obj-C class as `final`, Obj-C classes would
always be imported as `subclassable`, and their methods as `overridable`,
so this proposal only applies to non `@objc` Swift classes.

## Modifier spelling alternatives

The keywords in this proposal: `subclassable` and `overridable` are longer than
we would like, so they're just placeholders and we're open to other options.

Here are some ideas from the mailing list:

- `public open class` / `public open func`
- `public extensible class`

Or as a modifier of `public`:

- `public(subclassable) class` / `public(overridable) func`
- `public(open) class` / `public(open) func`
- `public(extensible) class`

## Impact on existing code

This would be a backwards-breaking change for all classes and methods that are
public and non-final, which code outside of their module has overriden.
Those classes/methods would fail to compile. Their superclass would need to be
changed to `open`.


## Alternatives considered

Defaulting to `final` instead:
This would be comparable to Swift defaulting to `private`, as opposed to `internal`.
Just like `internal` is a better trade-off, `sealed` by default also makes sure
that getting started with Swift, writing code within a module, doesn't require a
lot of boilerplate, and fighting against the compiler.
