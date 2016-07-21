# Require public overridability to be opt-in

* Proposal: [SE-0117](0117-non-public-subclassable-by-default.md)
* Authors: [Javier Soto](https://github.com/JaviSoto), [John McCall](https://github.com/rjmccall)
* Status: **Active Review July 21...25** ([Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000247.html))
* Review manager: [Chris Lattner](http://github.com/lattner)
* Previous Revision: [Revision 1](https://github.com/apple/swift-evolution/blob/2989538daa1640cfa6a56f80b5c7599967af0905/proposals/0117-non-public-subclassable-by-default.md) [Revision 2](https://github.com/apple/swift-evolution/blob/2989538daa1640cfa6a56f80b5c7599967af0905/proposals/0117-non-public-subclassable-by-default.md)

## Introduction

Since the first release of Swift, marking a class `public` has provided
two capabilities: it allows other modules to instantiate and use the
class, and it also allows other modules to define subclasses of it.
Similarly, marking a class member (a method, property, or subscript)
`public` has provided two capabilities: it allows other modules to
use the member, and it also allows those modules to override it.

This proposal suggests distinguishing these concepts.  A `public`
member will only be *usable* by other modules, but not *overridable*.
An `open` member will be *both usable and overridable*.  Similarly,
a `public` class will only be *usable* by other modules, but not
*subclassable*.  An `open` class will be *both usable and subclassable*.

This spirit of this proposal is to allow one to distinguish these cases while
keeping them at the same level of support: it does not adversely affect code
that is `open`, nor does it dissuade one from using `open` in their APIs. In
fact, with this proposal, `open` APIs are syntactically lighter-weight than
`public` ones.

Swift-evolution thread: http://thread.gmane.org/gmane.comp.lang.swift.evolution/21930/

## Motivation

Swift is very concerned with the problem of designing and maintaining
libraries.  Library authors must take care to avoid making promises
to their clients that will turn out to prevent later improvements to
the library's implementation.  A programming language can never fully
lift this burden, of course, but it can help to limit accidental
over-promises by reducing the number of implicit guarantees made
by code.  This has been a guiding idea throughout the Swift language
design.

For example, declarations in Swift default to `internal` access
control.  This prevents other modules from relying on code that was
never meant to be exposed, which would be a common error if the
default were `public`.  It also encourages library authors to think
more carefully about the interface they're providing to their
clients.  During initial development, while (say) a method's signature
is still in flux, it can be left `internal` without limiting the
programmer's ability to use and test it.  When it comes time to
prepare a public interface, the explicit act of adding `public`
to the method serves as a gentle nudge to think twice about the
method's name and type.  In contrast, if the method had to be made
`public` much earlier in development just to be able to use or test
it, it would be much more likely to slip through the cracks with
an unsatisfactory signature.

Method overriding is a very flexible programming
technique, but it poses a number of problems for library design.
A subclass that overrides methods of its superclass is intricately
intertwined with it.  The two systems are not composed, and their
behavior cannot be understood independently.  For example, a
programmer who changes how methods on a class delegate to each
other is very likely to break subclasses that override those
methods, as such subclasses can often only be written by
observing the existing pattern of behavior.  Within a single
module, this can be tolerable, but across library boundaries
it's very problematic unless the superclass has established
firm rules from the beginning.  It has frequently been observed
that designing a class well for subclassing takes far more effort
than just designing it for ordinary use, precisely because
these rules of delegation do need to be carefully laid out
if independently-designed subclasses are going to have any
chance of working.

Moreover, while subclassing is a temptingly simple manner of
allowing customization, it is also inherently limiting.
Subclasses cannot be independently tested using a mocked
implementation of the superclass or composed to apply the
customizations of two different subclasses to a single
instance.  Again, within a single module, where the superclass
and subclasses are co-designed, these problems are more
manageable: testing both systems in conjunction is more
reasonable, and the divergent customizations can be merged
into a single subclass.  But across library boundaries, they
become major hindrances.

Swift is committed to supporting subclassing and overriding.  But it
makes sense to be conservative about the promises that a class interface
makes merely by being public, and it makes sense to give library authors
strong tools for managing the overridability of their classes, and it
makes sense to encourage programmers to think more carefully about
overridability when they lift it into the external interface of a
library, where these problems become most apparent.

Furthermore, the things that make overriding such a powerful and flexible
tool for programmers also have a noticeable, negative impact on
performance.  Swift is a statically (not JIT) compiled language.  It is also a
high-level language with a number of intrinsic features that simplify
and generalize the programming model and/or improve the safety and
security of programming in Swift.  These features have costs, but the
language has typically been carefully designed to make those costs
amenable to optimization.  The Swift core team believes that it is
important for the success of Swift as a language that programmers
not be regularly required to abandon safety or (worse) drop down to a
completely different language just to meet their performance goals.
That is most at risk when there are flat-line inefficiencies in
simply executing code, and so we believe that it is crucial to remain
vigilant against pervasive abstraction penalties.  Therefore, while
dynamic features will always have a place in Swift, the language must
always retain some ability to statically optimize them in the
default case and without explicit user intervention.

And the costs of unrestricted overriding are quite real.  The
vast majority of class methods are never actually overridden,
which means they can be trivially devirtualized.  Devirtualization
is a very valuable optimization in its own right, but it is even
more important as an enabling optimization that allows the compiler
to reason about the behavior of the caller and callee together,
permitting it to further specialize and optimize both.  Making room
for subclassing and overrides also requires a great deal more
supporting code and metadata, which hurts binary sizes, launch times,
memory usage, and just general speed of execution.

Finally, it is a goal of Swift's language and performance design
that costs be "progressively disclosed".  Simple code that needs
fewer special guarantees should perform better and require less
boilerplate.  If a programmer merely wants to make a class
available for public use, that should not force excess annotations
and performance penalties just from the sudden possibility of
public subclassing.


## Proposed design

Introduce a new declaration modifier, `open` (other spellings are discussed
in the Alternatives section below).

`open` is permitted only on `class` declarations and overridable
class members (i.e. `var`, `func`, and `subscript`).

`open` is not permitted on declarations that are explicitly `final`
or `dynamic`.  (Note that it's okay if one or both of the modifiers
are implicitly inferred.)

If a declaration that is explicitly `open` does not have any other
explicit access control, it is implicitly `public`.  This promotes
a mental model where programmers may think of `open` and `public`
as two alternative ways of making a declaration externally visible.
It also significantly reduces the boilerplate of `open` declarations.

### `open` class members

A class member that overrides an `open` class member must be
explicitly declared `open` unless it is explicitly `final` or
it is a member of a `final` or non-`public` class.  In any case,
it is considered `open`.

A class member that is not `open` cannot be overridden outside
of the current module.

An `open` class member that is inherited from a superclass is
still considered `open` in the subclass unless the class is
`final`.

Note that a class member may be `open` even if its class is not
`open` or even `public`.  This is consistent with the resolution
of SE-0025, in which it was decided that `public` members should be
allowed within less-visible types and the wider visibility was
simply ignored.

### `open` classes

There are two designs under consideration here.

The first design says that classes work analogously to members.
A `public` class is not subclassable outside of the module, but
an `open` class is.  Benefits:

  - It's more consistent with explicit disclosure.

  - The library author can decline to commit to either `final` or
    `open` in their initial development/release if they aren't
    certain which way they want to go.  (`final` is an irrevocable
    decision for source- and binary-compatibility.)

  - This permits the creation of class hiearchies that are
    `public` but not publically extensible.  For example, this
    would be the natural direct translation of the compiler's
    own AST data structure.  While this use cases exists, it is not
    currently considered to be an important enough to complicate the
    language for.

  - This permits language enhancements which rely on knowing the
    full class hierarchy.  Otherwise, these become limited 
    on knowing that a class is `final` or non-`public`.

  - This permits performance enhancements which rely on knowing
    the full class hierarchy or that a class cannot be subclassed.
    For example, the compiler can avoid emitting the variants of
    designated initializers that are intended to be called from
    subclasses.  It would also be much easier to do optimizations
    like devirtualizing calls to `open` methods from superclasses
    or specializing the virtual dispatch tables for a known
    most-derived class.  However, these are relatively less
    important than the corresponding benefits from restricting
    overrides.

The second design says that there is no such thing as an `open`
class because all classes are subclassable unless made `final`.
Note that its direct methods would still not be overridable
unless individually made `open`, although its inherited `open`
methods could still be overridden.  Benefits:

  - Removes the added complexity of having the concept of non-`open`,
    non-`final` classes.

  - `open` would exist only on overridable members, potentially simplifying
    the programmer's mental model.

  - Permits the creation of "compositional" subclasses that
    add extra state and associated API as long as the superclass
    hasn't explicitly made itself `final`.

The lengths of these lists are quite imbalanced, but that should
not itself be considered an argument.  Most of the benefits of the
first design are relatively minor, and eliminating language
complexity is good.

### Temporary restrictions on `open`

The superclass of an `open` class must be `open`.  The overridden
declaration of an `open override` must be `open`.  These are conservative
restrictions that reduce the scope of this proposal; it will be possible
to revisit them in a later proposal.

### Other considerations

Objective-C classes and methods are always imported as `open`.  This means that
the synthesized header for an Objective-C class would pervasively replace
`public` with `open` in its interface.

The `@testable` design states that tests have the extra access
permissions of the modules that they import for testing.  Accordingly,
this proposal does not change the fact that tests are allowed to
subclass non-final types and override non-final methods from the modules
that they `@testable import`.

## Code examples

```swift
/// ModuleA:

// Under the open-class proposal, this class is not subclassable.
// Under the no-open-classes proposal, this class is subclassable.
public class NonSubclassableParentClass {
	// This method is not overridable in either case.
	public func foo() {}

	// This method is overridable if the class itself can be subclassed.
	// (If it cannot, this is still not an error.)
	open func bar() {}

	// The behavior of `final` methods remains unchanged.
	public final func baz() {}
}

// Under either proposal, this class would be subclassable.
// Writing `open` on a class would produce an error under the
// no-open-classes proposal.
open class SubclassableParentClass {
	// This property is not overridable.
	public var size : Int

	// This method is not overridable.
	public func foo() {}

	// This method is overridable.
	open func bar() {}

	/// The behavior of a `final` method remains unchanged.
	public final func baz() {}
}

/// The behavior of `final` classes remains unchanged.
public final class FinalClass { }
```

```swift
/// ModuleB:

import ModuleA

// Under the no-open-classes proposal, this is invalid because
// the superclass is not `open`.
class SubclassA : NonSubclassableParentClass { }

// This is allowed since the superclass is subclassable.
class SubclassB : SubclassableParentClass {
	// This is invalid because the method is not overridable outside the module.
	override func foo() { }

	// This is allowed since the superclass's method is overridable.
	//
	// If this class were `public`, this would need to be marked `open` or
	// `public`, depending on whether it the class is subclassable.
	// But because it is not `public`, the `open` marker is not required.
	override func bar() { }
}
```

## Alternatives

An earlier version of this proposal did not make `open` default to
`public`.  That is, you would have to write `public open` to get the
same effect.  This would have the benefit of not confusingly conflating
`open` with access control, but it has the very large drawback of making
`public open` significantly less syntactically privileged than `public`.
This raises questions about "defaults" and so on that aren't really our
intent to raise.  Instead, we want to promote the idea that `open` and
`public` are alternatives.  Therefore, while the current proposal is
still "opinionated" in the sense that it gently encourages the use
of `public` by making it more consistent with other language features,
it no longer makes `open` feel second-class by forcing more boilerplate.
This is consistent with how we've expressed our opinions on, say,
`let` vs. `var`: it's an extremely casual difference with only occasional
enforced use of the former.

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
Because `open` now implies `public`, the burden of asking the user to
explicit about `final` vs. `open` now seems completely reasonable.

Other proposals that have been considered:

- `public(open)`, which seems visually cluttered

- `public extensible`, which is somewhat heavyweight and invites confusion
  within `extension`

We may want to reconsider the need for `final` in the light of this change.

## Impact on existing code

This would be a backwards-breaking change for all classes and methods that are
public and non-final, which code outside of their module has overriden.
Those classes/methods would fail to compile. Their superclass would need to be
changed to `open`.

It is likely that we will want the migrator to convert existing code to
use `open` for classes and methods.

## Related work

The `fragile` modifier in the Swift 4 resilience design is very similar to this,
and will follow the precedent set by these keywords.
