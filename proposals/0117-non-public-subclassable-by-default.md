# Default classes to be non-subclassable publicly

* Proposal: [SE-0117](0117-non-public-subclassable-by-default.md)
* Authors: [Javier Soto](https://github.com/JaviSoto), [John McCall](https://github.com/rjmccall)
* Status: **Active review July 5 ... 11**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

Since Swift 1, marking a class `public` provides two different capabilities: it
allows other modules to use the type, and it also allows other modules to define
classes derived from it.  This proposal suggests splitting these into two different
concepts.  This means that marking a class `public` allows the class to be 
*used* outside of the current module, but does not allow other modules to define
*subclasses*.  In order to subclass from another module, the class would be
marked `public subclassable`.

Relatedly, Swift also conflates two similar concepts for class members (methods,
properties, subscripts): `public`
means that the member may be used by other modules, but also that it may be
overriden by subclasses.  This proposal introduces a new `open` modifier, which
is used instead of `public` on members that are overridable.

Swift-evolution thread: http://thread.gmane.org/gmane.comp.lang.swift.evolution/21930/

## Motivation

Types in Swift default to `internal` access control, which makes it easy for
Swift programmers to develop code used *within* their application or library.  
When one goes to publish an interesting type for use by *other* modules, care
must be taken to think about the API being published because changing it could
break downstream dependencies.  As such, Swift requires `public` to be added
to the type and every member being published as a way to encourage the
programmer to do that thinking.

The major observation here is that not all classes make sense to subclass, and
it takes real thought and design work to make a class subclassable *well*.  As
such, being able to subclass a public class should be an additional "promise"
beyond the class just being marked `public`.  For example, one must consider the 
extension points that can be meaningfully overriden, and document the class
invariants that need to be kept by any subclasses. 

Beyond high level application and library design issues, the Swift 1 approach is
also problematic for performance.  It is commonly the case that many
properties of a class are marked `public`, but doing this means that the
compiler has to generate dynamic dispatch code for each property access.  This
is an unnecessary performance loss in the case when the property was never
intended to be overridable, because accesses within the module cannot be
devirtualized.


- Defaulting to non-`final` allows the author of a class to accidentally leave the
visible methods open for overrides, even if they didn't carefully consider this
possibility.
- Requiring that the author of a class mark a class as subclassable is akin to
requiring symbols to be explicitly `public`: it ensures that a conscious decision
is made regarding whether the ability to subclass a `class` or override a method
is part of the API.

## Proposed solution

Introduce two new declaration modifiers: `subclassable` and `open` (other
spellings are discussed in the Alternatives section below):

- `subclassable class C {}` declares that C is a class which is
  subclassable outside of the module it is declared in.  `subclassable` implies
  `public`, so `public` does not need to be explicitly written.

- `overridable func foo() {}` declares that foo is a method which is overridable
  outside of the module it is declared in.  `overridable` implies `public`, so
  `public` does not need to be explicitly written.

The `subclassable` modifier only makes sense for classes, but `overridable` may
be used on `var`, `func, and `subscript` declarations within classes.

Because these modifiers replace the `public` keyword on affected declarations,
they do not increase the annotation burden on APIs, they just increase 
expressive power and encourage thought when publishing those APIs.

Objective-C classes would always be imported as `subclassable`, and all of their 
methods are `overridable`.

## Detailed design

Code Examples:

```swift
/// ModuleA:

/// This class is not subclassable by default.
public class NonSubclassableParentClass {
	/// This method is not overridable.
	public func foo() {}

	/// This raises a compilation error: a method can't be marked `overridable`
	/// if the class it belongs to can't be subclassed.
	overridable func bar() {}

	/// The behavior of `final` methods remains unchanged.
	final func baz() {}
}

subclassable class SubclassableParentClass {
        /// This property is not overridable.
        public var size : Int

	/// This method is not overridable.
	public func foo() {}

	/// Overridable methods in a `subclassable` class must be explicitly marked as `overridable`.
	overridable func bar() {}

	/// The behavior of a `final` method remains unchanged.
	public final func baz() {}
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

## Modifier spelling alternatives

`subclassable` and `overridable` are specific, but there are other approaches
that could be used to spell these concepts.  One approach is to decouple it from
`public`, and require `public overridable func` and `public subclassable class`.

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

Defaulting to `final` instead: This would be comparable to Swift defaulting to
`private`, as opposed to `internal`.  This penalizes code that is being used
inside an application or library by forcing the developer to think about big
picture concepts that may not apply.  The cost of getting something wrong within
a module is very low, since it is easy to fix all of the clients.
