# Noncopyable Generics

* Proposal: [SE-0427](0427-noncopyable-generics.md)
* Authors: [Kavon Farvardin](https://github.com/kavon), [Tim Kientzle](https://github.com/tbkka), [Slava Pestov](https://github.com/slavapestov)
* Review Manager: [Holly Borla](https://github.com/hborla), [Ben Cohen](https://github.com/airspeedswift)
* Status: **Accepted**
* Implementation: On `main` gated behind `-enable-experimental-feature NoncopyableGenerics`
* Previous Proposal: [SE-0390: Noncopyable structs and enums](0390-noncopyable-structs-and-enums.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-noncopyable-generics/68180)) ([first review](https://forums.swift.org/t/se-0427-noncopyable-generics/70525)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0427-noncopyable-generics/72039)) ([second review](https://forums.swift.org/t/second-review-se-0427-noncopyable-generics/72881)) ([acceptance](https://forums.swift.org/t/accepted-se-0427-noncopyable-generics/73560))

<!-- markdown-toc start - Don't edit this section. Run M-x markdown-toc-refresh-toc -->
**Table of Contents**

- [Noncopyable Generics](#noncopyable-generics)
  - [Introduction](#introduction)
  - [Motivation](#motivation)
  - [Proposed Solution](#proposed-solution)
    - [The `Copyable` protocol](#the-copyable-protocol)
    - [Default conformance to `Copyable`](#default-conformance-to-copyable)
    - [Suppression of `Copyable`](#suppression-of-copyable)
  - [Detailed Design](#detailed-design)
    - [The `Copyable` protocol](#the-copyable-protocol-1)
    - [Default conformances and suppression](#default-conformances-and-suppression)
    - [Struct, enum and class extensions](#struct-enum-and-class-extensions)
    - [Protocol extensions](#protocol-extensions)
    - [Protocol inheritance](#protocol-inheritance)
    - [Conformance to `Copyable`](#conformance-to-copyable)
    - [Classes](#classes)
    - [Existential types](#existential-types)
  - [Source Compatibility](#source-compatibility)
  - [ABI Compatibility](#abi-compatibility)
  - [Alternatives Considered](#alternatives-considered)
    - [Alternative spellings](#alternative-spellings)
    - [Associated types without defaulting behavior](#associated-types-without-defaulting-behavior)
    - [Inferred conditional copyability](#inferred-conditional-copyability)
    - [Extension defaults](#extension-defaults)
    - [Recursive `Copyable`](#recursive-copyable)
    - [`~Copyable` as logical negation](#copyable-as-logical-negation)
  - [Future Directions](#future-directions)
    - [Suppressed associated types](#suppressed-associated-types)
    - [Standard library adoption](#standard-library-adoption)
    - [Tuples and parameter packs](#tuples-and-parameter-packs)
    - [`~Escapable`](#escapable)
  - [Acknowledgments](#acknowledgments)

<!-- markdown-toc end -->

## Introduction

The noncopyable types introduced in
[SE-0390: Noncopyable structs and enums](0390-noncopyable-structs-and-enums.md)
cannot be used with generics, protocols, or existentials,
leaving an expressivity gap in the language. This proposal extends Swift's
type system to fill this gap.

## Motivation

Noncopyable structs and enums are intended to express value types for which
it is not meaningful to have multiple copies of the same value.

Support for noncopyable generic types was omitted from SE-0390. For example,
`Optional` could not be instantiated with a noncopyable type,
which prevented declaration of a failable initializer:
```swift
struct FileDescriptor: ~Copyable {
  init?(filename: String) { // error: cannot form a Optional<FileDescriptor>
    ...
  }
}
```

Practical use of generics also requires conformance to protocols, however
noncopyable types could not conform to protocols.

In order to broaden the utility of noncopyable types in the language, we need
a consistent and sound way to relax the fundamental assumption of copyability
that permeates Swift's generics system.

## Proposed Solution

We begin by recalling the restrictions from SE-0390:

1. A noncopyable type could not appear in the generic argument of some other generic type.
2. A noncopyable type could not conform to protocols.
3. A noncopyable type could not be boxed as an existential.

This proposal builds on the `~Copyable`  notation introduced in SE-0390, and
introduces three fundamental concepts that together eliminate these
restrictions:

1. A new `Copyable` protocol abstracts over types whose values can be copied.
2. Every struct, enum, class, generic parameter, protocol and associated type
now conforms to `Copyable` _by default_.
3. The `~Copyable` notation is used to _suppress_ this default conformance
requirement anywhere it would otherwise be inferred.

**Note**: The adoption of noncopyable generics in the standard library will be
covered in a subsequent proposal.

### The `Copyable` protocol

The notion of copyability of a value is now expressed as a special kind of
protocol. The existing `~Copyable` notation is re-interpreted as _suppressing_
a conformance to this protocol, as we detail below. This protocol has no
explicit requirements, and it has some special behaviors. For example,
metatypes and tuples cannot normally conform to other protocols,
but they do conform to `Copyable`.

A key goal of the design is _progressive disclosure_. The idea of _default_ conformance to
`Copyable` means that a user never interacts with noncopyable generics unless
they choose to do so, using the `~Copyable` notation to _suppress_
the default conformance.

The meaning of existing code remains the same; all generic parameters and
protocols now require conformance to `Copyable`, but all existing concrete
types do in fact conform.

### Default conformance to `Copyable`

Every struct and enum now has a default conformance to `Copyable`, unless the
conformance is suppressed by writing `~Copyable` in the inheritance clause. In
this proposal, we will show these inferred requirements in comments. For example,
a definition of a copyable struct is understood as if the user wrote the
conformance to `Copyable`:
```swift
struct Polygon /* : Copyable */ {...}
```

Furthermore, generic parameters now conform to `Copyable` by
default, so the following generic function can only be called with `Copyable` types:
```swift
func identity<T>(x: T) /* where T: Copyable */ { return x }
```

Finally, protocols also have a default conformance to `Copyable`, thus
only `Copyable` types can conform to `Shape` below:
```swift
protocol Shape /*: Copyable */ {}
```

### Suppression of `Copyable`

So far, we haven't described anything new, just formalized existing behavior with
a protocol. Now, we allow writing `~Copyable` in some new positions.

For example, to generalize our identity function to also allow noncopyable types, we
suppress the default `Copyable` conformance on `T` as follows:
```swift
func identity<T: ~Copyable>(x: consuming T) { return x }
```
This function imposes _no_ requirements on the generic parameter `T`. All possible
types, both `Copyable` and noncopyable, can be substituted for `T`.
This is the reason why we refer to `~Copyable` as _suppressing_ the conformance
rather than _inverting_ or _negating_ it.

As with a concrete noncopyable type, a noncopyable generic parameter type must
be prefixed with one of the ownership modifiers `borrowing`,
`consuming`, or `inout`, when it appears as the type of a function's parameter.
For details on these parameter ownership modifiers,
see [SE-377](0377-parameter-ownership-modifiers.md).

A protocol can allow noncopyable conforming types by suppressing its inherited
conformance to `Copyable`:
```swift
protocol Resource: ~Copyable {
  consuming func dispose()
}

extension FileDescriptor: Resource {...}
```
A `Copyable` type can still conform to a `~Copyable` protocol.

What it means to write `~Copyable` in each position will be fully explained in
the **Detailed Design** section.

## Detailed Design

This proposal does not fundamentally change the abstract theory of Swift
generics, with its four fundamental kinds of requirements that can appear in a
`where` clause; namely conformance, superclass, `AnyObject`, and same-type
requirements.

The proposed mechanism of default conformance to `Copyable`, and its suppression by
writing `~Copyable`, is essentially a new form of syntax sugar; the transformation
is purely syntactic and local.

### The `Copyable` protocol

While `Copyable` is a protocol in the current implementation, it is unlike a
protocol in some ways. In particular, protocol extensions of `Copyable` are not
allowed:
```swift
extension Copyable {  // error
  func f() {}
}
```
Such a protocol extension would effectively add new members to _every_
copyable type, which would complicate overload resolution and possibly lead to
user confusion.

### Default conformances and suppression

Default conformance to `Copyable` is inferred in each position below,
unless explicitly suppressed:

1. A struct, enum or class declaration.
2. A generic parameter declaration.
3. A protocol declaration.
4. An associated type declaration; does not support suppression (see Future Directions).
5. The `Self` type of a protocol extension.
6. The generic parameters of a concrete extension.

The `~Copyable` notation is also permitted to appear as the _member_ of
a protocol composition type. This ensures that the following three declarations
have the same meaning, as one might expect:
```swift
func f<T: Resource & ~Copyable>(_: T) {}
func f<T>(_: T) where T: Resource & ~Copyable {}
func f<T>(_: T) where T: Resource, T: ~Copyable {}
```

A conformance to `Copyable` cannot be suppressed if it must hold for
some _other_ reason. In the above declaration of `f()`, we can suppress
`Copyable` on `T` because `Resource` suppresses its own `Copyable` requirement
on `Self`:
```swift
protocol Resource: ~Copyable {...}
```
Thus, nothing else forces `f()`'s generic parameter `T` to be `Copyable`. On the
other hand, let's look at a copyable protocol like `Shape` below:
```swift
protocol Shape /*: Copyable */ {...}
```
If we try to suppress the `Copyable` conformance on a generic parameter that also
conforms to `Shape`, we get an error:
```swift
func f<T: Shape & ~Copyable>(_: T) {...}  // error
```
The reason being that the conformance `T: Copyable` is _implied_ by `T: Shape`, and
cannot be suppressed.

Furthermore, a `Copyable` conformance can only be suppressed if the subject type
is a generic parameter declared in the innermost scope. That is, the following
is an error:
```swift
struct S<T /* : Copyable */> {
  func f<U /* : Copyable */>(_: T, _: U) where T: ~Copyable  // error!
}
```
The rationale here is that since `S` must be instantiated with a copyable type,
it does not make sense for a method of `S` to operate on an `S<T>` where `T`
might be noncopyable. For a similar reason the same rule applies to nested
generic types.

### Struct, enum and class extensions

We wish to allow existing types to adopt noncopyability without changing the
meaning of existing code. Thus, an extension of a concrete type must introduce
a default `T: Copyable` requirement on every generic parameter of the
extended type:
```swift
struct Pair<T: ~Copyable>: ~Copyable {...}

extension Pair /* where T: Copyable */ {...}
```
The conformance can be suppressed to get an unconstrained extension of `Pair`:
```swift
extension Pair where T: ~Copyable {...}
```

An extension presents a copyable view of the world by default, behaving as if
`Pair` were declared like so:
```swift
struct Pair<T /* : Copyable */> /* : Copyable */ {...}
```

An extension of a nested type introduces default conformance requirements for
all outer generic parameters of the extended type, and each conformance
can be individually suppressed:
```swift
struct Outer<T: ~Copyable> {
  struct Inner<U: ~Copyable> {}
}

extension Outer.Inner /* where T: Copyable, U: Copyable */ {}
extension Outer.Inner where T: ~Copyable /* , U: Copyable */ {}
extension Outer.Inner where /* T: Copyable, */ U: ~Copyable {}
```

An extension of a type whose generic parameters must be copyable cannot
suppress conformances:
```swift
struct Horse<Hay> {...}
extension Horse where Hay: ~Copyable {...}  // error
```

### Protocol extensions

Where possible, we wish to allow the user to change an existing protocol to
accommodate noncopyable conforming types, without changing the meaning of existing
code.

For this reason, an extension of a `~Copyable` protocol also introduces a default
`Self: Copyable` requirement, because this is the behavior expected from
existing clients:
```swift
protocol EventLog: ~Copyable {
  ...
}

extension EventLog /* where Self: Copyable */ {
  func duplicate() -> Self {
    return copy self // OK
  }
}
```

To write an unconstrained protocol extension, suppress the conformance on `Self`:
```swift
extension EventLog where Self: ~Copyable {
  ...
}
```
Associated types cannot have their `Copyable` requirement suppressed 
(see Future Directions).

### Protocol inheritance

Another consequence that immediately follows from the rules as explained so far
is that protocol inheritance must re-state `~Copyable` if needed:
```swift
protocol Token: ~Copyable {}
protocol ArcadeToken: Token /* , Copyable */ {}
protocol CasinoToken: Token, ~Copyable {}
```
Again, because `~Copyable` suppresses a default conformance instead of introducing
a new kind of requirement, it is not propagated through protocol inheritance.

### Conformance to `Copyable`

Structs and enums conform to `Copyable` unconditionally by default, but a
conditional conformance can also be defined. For example, take this
noncopyable generic type:
```swift
enum List<T: ~Copyable>: ~Copyable {
  case empty
  indirect case element(T, List<T>)
}
```
We would like `List<Int>` to be `Copyable` since `Int` is, while still being
able to use a noncopyable element type, like `List<FileDescriptor>`. We do
this by declaring a _conditional conformance_:
```swift
extension List: Copyable where T: Copyable {}
```
Note that the `where` clause needs to be written, because a conformance to
`Copyable` declared in an extension does _not_ automatically add any other
requirements, unlike other extensions.

A conditional `Copyable` conformance is not permitted if the
struct or enum declares a `deinit`. Deterministic destruction requires the
type to be unconditionally noncopyable.

A conformance to `Copyable` is checked by verifying that every stored property
(of a struct) or associated value (or an enum) itself conforms to `Copyable`.
For a conditional `Copyable` conformance, the conditional requirements must be
sufficient to ensure this is the case. For example, the following is rejected,
because the struct cannot unconditionally conform to `Copyable`, having a
stored property of the noncopyable type `T`:
```swift
struct Holder<T: ~Copyable> /* : Copyable */ {
  var value: T  // error
}
```

There are two situations when it is permissible for a copyable type to
have a noncopyable generic parameter. The first is when the generic parameter
is not stored inside the type itself:
```swift
struct Factory<T: ~Copyable> /* : Copyable */ {
  let fn: () -> T  // ok
}
```
The above is permitted, because a _function_ of type `() -> T` is still copyable,
even if a _value_ of type `T` is not copyable.

The second case is when the type is a class. The contents of a class is never
copied, so noncopyable types can appear in the stored properties of a class:
```swift
class Box<T: ~Copyable> {
  let value: T  // ok

  init(value: consuming T) { self.value = value }
}
```

For a conditional `Copyable` conformance, the conditional requirements must be
of the form `T: Copyable` where `T` is a generic parameter of the type. It is
not permitted to make `Copyable` conditional on any other kind of requirement:
```swift
extension Pair: Copyable where T == Array<Int> {}  // error
```

Conditional `Copyable` conformance must be declared in the same source
file as the struct or enum itself. Unlike conformance to other protocols,
copyability is a deep, inherent property of the type itself.

### Classes

This proposal supports classes with noncopyable generic parameters,
but it does not permit classes to themselves be `~Copyable`.
Similarly, an `AnyObject` or superclass requirement cannot be combined with
`~Copyable`:
```swift
func f<T>(_ t: T) where T: AnyObject, T: ~Copyable { ... }  // error
```

### Existential types

The type `Any` is no longer the supertype of all types in the type system's
implicit conversion rules.

The constraint type of an existential type is now understood as being a
protocol composition, with a default `Copyable` _member_. So
the empty protocol composition type `Any` is really `any Copyable`, and the
supertype of all types is now `any ~Copyable`:

```
              any ~Copyable
               /         \
              /           \
   Any == any Copyable   <all purely noncopyable types>
        |
<all copyable types>
```

This default conformance is suppressed by writing `~Copyable` as a member of a
protocol composition:

```swift
protocol Pizza: ~Copyable {}
struct UniquePizza: Pizza, ~Copyable {}

let t: any Pizza /* & Copyable */ = UniquePizza()  // error
let _: any Pizza & ~Copyable = UniquePizza()  // ok
```

## Source Compatibility

The default conformance to `Copyable` is inferred anywhere it is not explicitly
suppressed with `~Copyable`, so this proposal does not change the interpretation
of existing code.

Similarly, the re-interpretation of the SE-0390 restrictions in terms of
conformance to `Copyable` preserves the meaning of existing code that makes use of
noncopyable structs and enums.

## ABI Compatibility

This proposal does not change the ABI of existing code.

Adding `~Copyable` to
an existing generic parameter is generally an ABI-breaking change, even when
source-compatible.

Targeted mechanisms are being developed to preserve ABI compatibility when
adopting `~Copyable` on previously-shipped generic code. This will enable adoption
of this feature by standard library types such as `Optional`. Such mechanisms will
require extreme care to use correctly.

## Alternatives Considered

### Alternative spellings

The spelling of `~Copyable` generalizes the existing syntax introduced in
SE-0390, and changing it is out of scope for this proposal.

### Associated types without defaulting behavior

A simple design for suppressed associated types was considered, where the 
default conformance in a protocol extension applies only to `Self`, and not
the associated types of `Self`. For example, we first declare a protocol with a
`~Copyable` associated type:
```swift
protocol Manager {
  associatedtype Resource: ~Copyable
}
```
Now, a protocol extension of `Manager` does _not_ carry an implicit
`Self.Resource: Copyable` requirement:
```swift
extension Manager {
  func f(resource: Resource) {
    // `resource' cannot be copied here!
  }
}
```
For this reason, while adding `~Copyable` to the inheritance clause of a protocol
is a source-compatible change, the same with an _associated type_ is not
source compatible. The designer of a new protocol must decide which associated
types are `~Copyable` up-front.

Requirements on associated types can be written in the associated type's
inheritance clause, or in a `where` clause, or on the protocol itself. As
with ordinary requirements, all three of the following forms define the same
protocol:
```swift
protocol P { associatedtype A: ~Copyable }
protocol P { associatedtype A where A: ~Copyable }
protocol P where A: ~Copyable { associatedtype A }
```

If a base protocol declares an associated type with a suppressed conformance
to `Copyable`, and a derived protocol re-states the associated type, a
default conformance is introduced in the derived protocol, unless it is again
suppressed:
```swift
protocol Base {
  associatedtype A: ~Copyable
  func f() -> A
}

protocol Derived: Base {
  associatedtype A /* : Copyable */
  func g() -> A
}
```

Finally, conformance to `Copyable` cannot be conditional on the copyability of
an associated type:
```swift
struct ManagerManager<T: Manager>: ~Copyable {}
extension ManagerManager: Copyable where T.Resource: Copyable {}  // error
```

This design for associated types was initially implemented but ultimately 
removed from this proposal, because of the source compatibility issues. A more
comprehensive design that allows for some way of preserving source compatibility
requires a separate proposal due to the open design issues.

### Inferred conditional copyability

A struct or enum can opt out of copyability with `~Copyable`, and then possibly
declare a conditional conformance. It would be possible to automatically infer
this conditional conformance. For example, in the below,
```swift
struct MaybeCopyable<T: ~Copyable> {
  var t: T
}
```
The only way this _could_ be valid is if we had inferred the conditional
conformance:
```
extension MaybeCopyable: Copyable /* where T: Copyable */ {}
```
Feedback from early attempts at implementing this form of inference suggested
it was more confusing than helpful, so it was removed.

### Extension defaults

One possible downside is that extensions of types with noncopyable generic
parameters must suppress the conformance on each generic parameter.

It would be possible to allow library authors to explicitly control this
behavior, with a new syntax allowing the default `where` clause of an
extension to be written inside of a type declaration. For example,
```swift
public enum Either<T: ~Copyable, U: ~Copyable> {
  case a(T)
  case b(U)

  // Hypothetical syntax:
  default extension where T: Copyable, U: ~Copyable
}

// `T` is copyable, but `U` is not, because of the defaults above:
extension Either /* where T: Copyable */ { ... }

```

This becomes much more complex for protocols that impose conformance
requirements on their own associated types:
```swift
protocol P: ~Copyable {
  associatedtype A: P, ~Copyable

  // Hypothetical syntax:
  default extension where A: Copyable
}

extension P {
  // A is Copyable. What about A.A? A.A.A? ...
}
```

Besides the unclear semantics with associated types, it was also felt this
approach could lead to user confusion about the meaning of a particular
extension. As a result, we feel that explicitly suppressing `Copyable` on
every extension is the best approach.

### Recursive `Copyable`

The behavior of default `Copyable` conformance on associated types prevents
existing protocols from adopting `~Copyable` on their associated types in a
source compatible way.

For example, suppose we attempt to change `IteratorProtocol` to accommodate
noncopyable element types:
```swift
protocol IteratorProtocol: ~Copyable {
  associatedtype Element: ~Copyable
  mutating func next() -> Element?
}
```
An existing program might declare a generic function that assumes `T.Element` is
`Copyable`:
```swift
func f<T: IteratorProtocol /* & Copyable */>(iter: inout T) {
  let value = iter.next()!
  let copy = value  // error
}
```
Since `IteratorProtocol` suppresses its `Copyable` conformance, the generic
parameter `T` defaults to `Copyable`. However, `T.Element` is no longer
`Copyable`, thus the above code would not compile.

One can imagine a design where instead of a single default conformance
requirement `T: Copyable` being introduced above, we also add a requirement
`T.Element: Copyable`. This would preserve source compatibility and our
function `f()` would continue to work as before.

However, this approach introduces major complications, if we again consider
protocols that impose conformance requirements on their associated types.

Consider this simple protocol and function that uses it:
```swift
protocol P: ~Copyable {
  associatedtype A: P, ~Copyable
}

func f<T: P>(_: T) {}
```
Our hypothetical design would actually introduce an infinite sequence of
requirements here unless suppressed:
```swift
func f<T: P>(_: T) /* where T: Copyable, T.A: Copyable, T.A.A: Copyable, ... */ {}
```
Of course, it seems natural to represent this infinite sequence of requirements
as a new kind of "recursive conformance" requirement instead.

Swift generics are based on the mathematical theory of
_string rewriting_, and requirements and associated types define certain _rewrite
rules_ which operate on a set of terms. In this formalism, a
hypothetical "recursive conformance" requirement corresponds to a rewrite
rule that can match an infinite set of terms given by a _regular expression_.
We would then need to generalize the algorithms for deciding term equivalence to
handle regular expressions. While there has been research in this area,
the design for such a system is far beyond the scope of this proposal.

### `~Copyable` as logical negation

Instead of the syntactic desugaring presented in this proposal, one can attempt to
formalize `T: ~Copyable` as the _logical negation_
of a conformance, extending the theory of Swift generics with a fifth requirement kind to
represent this negation. It is not apparent how this leads to a sound and
usable model and we have not explored this further.

## Future Directions

### Suppressed associated types

Supporting the full generality of associated types with suppressed Copyable 
requirements, while providing a mechanism to preserve source compatibility is
a highly desirable goal. At the same time, it is a large, open design problem. 
A few ideas were considered (see Alternatives Considered) but it was ultimately
determined to be too complex to tackle in this proposal.

### Standard library adoption

The `Optional` and `UnsafePointer` family of types can support noncopyable types
in a straightforward way. In the future, we will also explore noncopyable
collections, and so on. All of this requires significant design work and is out
of scope for this proposal.

### Tuples and parameter packs

Noncopyable tuples and parameter packs are a straightforward generalization
which will be discussed in a separate proposal.

### `~Escapable`

The ability to "escape" the current context is another implicit capability
of all current Swift types.
Suppressing this requirement provides an alternative way to control object lifetimes.
A companion proposal will provide details.

## Acknowledgments

Thank you to Joe Groff and Ben Cohen for their feedback throughout the
development of this proposal.
