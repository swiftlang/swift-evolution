# Default classes to be non-subclassable publicly

* Proposal: [SE-0117](0117-non-public-subclassable-by-default.md)
* Authors: [Javier Soto](https://github.com/JaviSoto), [John McCall](https://github.com/rjmccall)
* Status: **Returned for Revision** ([Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000247.html))
* Review manager: [Chris Lattner](http://github.com/lattner)
* Previous Revision: [Revision 1](https://github.com/apple/swift-evolution/blob/367086f18a5deaf8f9dfbe3f5a4846ef19addf38/proposals/0117-non-public-subclassable-by-default.md)

## Introduction

Since Swift 1, marking a class `public` provides two different capabilities: it
allows other modules to instantiate and use the class, and it also allows other
modules to define subclasses of it.  This proposal suggests splitting these into
two different
concepts.  This means that marking a class `public` allows the class to be 
*used* by other modules, but does not allow other modules to define
*subclasses*.  In order to subclass from another module, the class would
also have to be marked `open`.

Relatedly, Swift also conflates two similar concepts for class members (methods,
properties, subscripts): `public`
means that the member may be used by other modules, but also that it may be
overriden by subclasses.  This proposal uses the same `open` modifier, which
is used together with `public` on members that are overridable.

Swift-evolution thread: http://thread.gmane.org/gmane.comp.lang.swift.evolution/21930/

## Motivation

Types in Swift default to `internal` access control, which makes it easy for
Swift programmers to develop code used *within* their application or library.
When one goes to publish an inheritable type for use by *other* modules, care
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


## Proposed design

Introduce a new declaration modifier, `open` (other spellings are discussed
in the Alternatives section below):

- `public open class C {}` declares that C is a class which is
  subclassable outside of the module it is declared in.

- `public open func foo() {}` declares that foo is a method which is
	overridable outside of the module it is declared in.  `open` in this
	sense is only allowed on overridable declarations, i.e. `var`, `func`,
	and `subscript` declarations within classes.

`open` is invalid on declarations that are not also `public` (see the
Alternatives discussion for rationale).

`open` is invalid on declarations that are `final`.

If an `open` class inherits an `open` method from a superclass, that
method remains `open`.  If it overrides an `open` method from a
superclass, the override is implicitly `open` if it is not `final`.

The superclass of an `open` class must be `open`.  The overridden
declaration of an `open override` must be `open`.  These are conservative
restrictions that reduce the scope of this proposal; it will be possible
to revisit them in a later proposal.

Objective-C classes and methods are always imported as `open`.

The `@testable` design states that tests have the extra access
permissions of the modules that they import for testing.  Accordingly,
this proposal does not change the fact that tests are allowed to
subclass non-final types and override non-final methods from the modules
that they `@testable import`.

## Code examples

```swift
/// ModuleA:

/// This class is not subclassable by default.
public class NonSubclassableParentClass {
	/// This method is not overridable.
	public func foo() {}

	/// This raises a compilation error: a method can't be marked `open`
	/// if the class it belongs to can't be subclassed.
	public open func bar() {}

	/// The behavior of `final` methods remains unchanged.
	public final func baz() {}
}

public open class SubclassableParentClass {
	/// This property is not overridable.
	public var size : Int

	/// This method is not overridable.
	public func foo() {}

	/// Overridable methods in an `open` class must be explicitly
	/// marked as `open`.
	public open func bar() {}

	/// The behavior of a `final` method remains unchanged.
	public final func baz() {}
}

/// The behavior of `final` classes remains unchanged.
public final class FinalClass { }
```

```swift
/// ModuleB:

import ModuleA

/// This raises a compilation error: `NonSubclassableParentClass` is
/// not `open`, so it is not subclassable outside of `ModuleA`.
class SubclassA : NonSubclassableParentClass { }

/// This is allowed since `OpenParentClass` is `open`.
class SubclassB : SubclassableParentClass {
	/// This raises a compilation error: `SubclassableParentClass.foo` is not
	/// `open`, so it is not overridable outside of `ModuleA`.
	override func foo() { }

	/// This is allowed since `SubclassableParentClass.bar` is `open`.
	override func bar() { }
}
```

## Alternatives

`open` grants additional access beyond `public` and can be thought of as
a new level of access control.  Arguably, instead of requiring it to be
written together with `public`, it could be an alternative that supersedes
`public`.  However, `open` doesn't quite imply `public`, and there's
some merit in always being able to find the external interface of a
library by just scanning for the single keyword `public`.  `open` is
also quite short.

`open` could be split into different modifiers for classes and methods.
An earlier version of this proposal used `subclassable` and `overridable`.
These keywords are self-explanatory but visually heavyweight.  They also
imply too much: it seems odd that a non-`subclassable` class can be
subclassed from inside a module, but we are not proposing to make classes
and methods `final` by default.

Classes and methods could be inferred as `final` by default.  This would
avoid using different default rules inside and outside of the defining
module.  However, it is analogous to Swift defaulting to `private` instead
of `internal`.  It penalizes code that's only being used inside an
application or library by forcing the developer to micromanage access.
The cost of getting something wrong within a module is very low, since
it is easy to fix all of the clients.

Inherited methods could be made non-`open` by default.  This would
arguably be more consistent with the principle of carefully considering
the overridable interface of a class, but it would create an enormous
annotation and maintenance burden by forcing the entire overridable
interface to be restated at every level in the class hierarchy.

Overrides could be made non-`open` by default.  However, it would be
very difficult to justify this given that inherited methods stay `open`.
It also piles up modifiers on the override: `public open override func foo()`.
The `override` keyword is already present to convey that this is possible.

Other proposals that have been considered:

- `public(open)`, which seems visually cluttered

- `public extensible`, which is somewhat heavyweight and invites confusion
  within `extension`

## Impact on existing code

This would be a backwards-breaking change for all classes and methods that are
public and non-final, which code outside of their module has overriden.
Those classes/methods would fail to compile. Their superclass would need to be
changed to `open`.

## Related work

The `fragile` modifier in the Swift 4 resilience design is very similar to this,
and will follow the precedent set by these keywords.
