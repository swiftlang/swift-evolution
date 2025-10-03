# Suppressed Default Conformances on Associated Types

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Kavon Farvardin](https://github.com/kavon), [Slava Pestov](https://github.com/slavapestov)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: on `main` and available since at least Swift 6.1.2, using `-enable-experimental-feature SuppressedAssociatedTypes`
* Previous Proposals: [SE-427: Noncopyable Generics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md), [SE-446: Nonescapable Types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md)
* Review: [Pitch](https://forums.swift.org/t/pitch-suppressed-default-conformances-on-associated-types/81880)

## Introduction

Today, it is not possible to declare an associated type that does not require its
_type witnesses_ to be `Copyable` or `Escapable`. For example, consider the `Element`
associated type of `Queue` below:
```swift
/// Queue has no reason to require Element to be Copyable.
protocol Queue<Element>: ~Copyable {
  associatedtype Element

  mutating func push(_: consuming Self.Element)
  mutating func pop() -> Self.Element
}
```
While the conforming type is itself permitted to be noncopyable, its `Element`
type witness has to be `Copyable`:
```swift
/// error: LinkedListQueue does not conform to Queue
struct LinkedListQueue<Element: ~Copyable>: ~Copyable, Queue {
  ...
}
```
This is an expressivity limitation in practice, and there is no workaround
possible today.

## Proposed Solution

We propose that the existing syntax for suppressing these conformances be
extended to associated type declarations:

```swift
/// Correct Queue protocol.
protocol Queue<Element>: ~Copyable {
  associatedtype Element: ~Copyable

  mutating func push(_: consuming Self.Element)
  mutating func pop() -> Self.Element
}
```

Similarly, stating `~Escapable` should be allowed, to suppress the default conformance
to `Escapable`.

## Detailed Design

There are three ways to impose a requirement on an associated type:
- In the inheritance clause of the associated type declaration.
- In a `where` clause attached to the associated type declaration.
- In a `where` clause attached to the protocol itself.

We extend the **Detailed Design** section of
[SE-427: Noncopyable Generics](0427-noncopyable-generics.md) to allow
suppressing default conformance to `Copyable` in `Escapable` in all of
the above positions. Thus, all three below are equivalent:
```swift
protocol P { associatedtype A: ~Copyable }
protocol P { associatedtype A where Self.A: ~Copyable }
protocol P where Self.A: ~Copyable { associatedtype A }
```

### Protocol inheritance

This interacts with protocol inheritance as follows. If a base protocol
declares an associated type with a suppressed conformance, this
associated type will also have a suppressed conformance in the derived
protocol, unless the derived protocol re-states the associated type. That is:
```swift
protocol Base {
  associatedtype A: ~Copyable
}

protocol Derived1: Base {
  // A is still ~Copyable here
}

protocol Derived2: Base {
  // A now defaults to Copyable
  associatedtype A
}
```

### No recursion

Suppressed conformances on associated types differ from those on generic
parameters and protocols in one crucial respect. Here is the protocol
`Queue` from earlier:
```swift
/// Correct Queue protocol.
protocol Queue<Element>: ~Copyable {
  associatedtype Element: ~Copyable

  mutating func push(_: consuming Self.Element)
  mutating func pop() -> Self.Element
}
```

Recall the existing rules from
[SE-427: Noncopyable Generics](0427-noncopyable-generics.md). Under
those rules, a protocol extension of `Queue` always introduces a
default `Self: Copyable` requirement; that is:
```swift
extension Queue /* where Self: Copyable */ {
  ...
}
```
An unconstrained extension of `Queue` is declared by suppressing
`Copyable` on `Self`:
```swift
extension Queue where Self: ~Copyable {
  ...
}
```

However, with the current proposal, this defaulting behavior does
not extend to associated types
with supressed conformances. In particular, no implicit
`Self.Element: Copyable` requirement is introduced above, by
either extension. Instead, a protocol extension
for queue types where **both** the queue itself and the element
type are `Copyable` takes the following form:
```swift
extension Queue where Self.Element: Copyable {
  ...
}
```

This is discussed further in **Source Compatibility** below.

### Library evolution and new associated type requirements

Another complication in extending the defaulting behavior of generic
parameters to associated types comes from library evolution. Protocols
are allowed to introduce new requirements, including associated type
requirements, without breaking source or binary compatibility, as long
as a default implementation is provided for existing code.
After this proposal, a new associated type can be `~Copyable` and/or
`~Escapable`, and the default type could be non-`Copyable` or
non-`Escapable`.

```swift
protocol Foo {
  // Added in v2
  associatedtype New: ~Copyable
}

struct NC: ~Copyable {}

// Added in v2
extension Foo { typealias New = NC }
```

If the defaulting rule for generic parameters extended to all associated types,
then a protocol introducing an associated type would change the meaning of source
code when it compiles against the new definition of the protocol, since the new
associated type would impose new default requirements. This could cause existing
code to stop compiling when the default implementation of the new associated type,
used by existing conformances to the modified protocol, is non-`Copyable` or
non-`Escapable` so does not satisfy those default requirements.

```swift
struct ExistingConformance: Foo {}

// If `T: Foo` implied `T.New: Copyable` after recompiling against Foo v2...
func existingFunction<T: Foo>(_: T) {}

func existingCaller() {
  // ...then this previously-working line of code would stop compiling, because
  // ExistingConformance.New defaults to noncopyable type `NC`, so doesn't
  // satisfy the default `T.New: Copyable` requirement.
  existingFunction(ExistingConformance())
}
```

### Conditional conformance

Finally, recall that concrete types may conform to `Copyable` and
`Escapable` conditionally, depending on the copyability or
escapability of a generic parameter. Even though associated types
may now suppress conformance to these protocols, a conditional
conformance to `Copyable` or `Escapable` that depends on an
associated type is still not allowed:
```swift
struct QueueHolder<Q: Queue>: ~Copyable {}
extension QueueHolder: Copyable where Q.Element: Copyable {}  // error
```
This restriction is for runtime implementation reasons.

## Source Compatibility

The introduction of this feature in the language does not break
any existing code, because any usage of the suppressed conformance
syntax with associated types was diagnosed as an error.

However, changing an existing associated type declaration to suppress
conformance to `Copyable` or `Escapable` is a
**source-breaking** change, as a consequence of the design
discussed in **No recursion** above.

For example, if a library publishes this protocol:
```swift
public protocol Manager: ~Copyable {
  associatedtype Resource
}
```
Client code that states a `T: Manager` requirement on a generic
parameter `T` can then assume that the type parameter
`T.Resource` is `Copyable`:
```swift
extension Manager where Self: ~Copyable {
  func makeCopies(_ r: Self.Resource) -> (Self.Resource, Self.Resource) {
    return (r, r)
  }
}
```
Now suppose the library author then changes the protocol to
suppress conformance:
```swift
public protocol Manager: ~Copyable {
  associatedtype Resource: ~Copyable
}
```
The client's extension of `Manager` will no longer type check, because
the body of `makeCopies()` assumes `r` is `Copyable`, and this
assumption is no longer true. 

## ABI Compatibility

The ABI of existing code is not affected by this proposal.

On the other hand, changing an associated type declaration in an library
to suppress conformance is an ABI-breaking change, for similar reasons
to those described above.

## Alternatives Considered

### Recursive requirements

A more advanced form of this idea would attempt to introduce "recursive
`Copyable` requirements" (and similarly for `Escapable`). This was already
discussed in the **Alternatives Considered** section of
[SE-427: Noncopyable Generics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md), and the difficulties outlined there still
apply today. 

If we were able to design and implement such a feature, it still would not
address the library evolution problem with default requirements on
associated types.

### Definition-driven associated type defaults

Rather than try to impose a blanket default on all associated types, we might
instead apply a limited defaulting rule only to select associated types, driven
by some aspect of the protocol definition. This could avoid the infinite recursion
and library evolution problems, if designed properly, at the expense of increased
language complexity. Readers would have to consult the definitions of protocols
to see whether they come with default `Copyable` or `Escapable` requirements.

Some possibilities for how this might look include:

#### Defaulting only for primary associated types

Primary associated types have a strong correlation to what one might consider the core interface of a protocol. They also can’t be added to or removed once declared without breaking source compatibility. So we could only default primary associated types:

```
protocol Container<Element> {
  associatedtype Element: ~Copyable & ~Escapable
  associatedtype Iterator: ~Copyable & ~Escapable
}

func foo<T: Container>() {...}
// defaults T: Copyable, T: Escapable, T.Element: Copyable, T.Element: Escapable
//   but defaults to leaving Iterator unconstrained
```

In order to avoid creating an infinite set of defaults, this would not be
recursive, but only apply to

One drawback of this approach is that it would make adding a `~Copyable` and/or
`~Escapable` associated type as a primary associated type to a protocol that
had not already declared primary associated types would become a source-breaking
change. Currently, a protocol without primary associated types can add
some without affecting compatibility with existing source code.

#### Protocol-defined default requirements

We could let a protocol definition dictate any set of `Copyable` or `Escapable` requirements to get imposed by default when used as a generic requirement. This set of requirements would have to be finite.

```
protocol Container: ~Copyable, ~Escapable {
    associatedtype BorrowingIterator: BorrowingIteratorProtocol,
      ~Copyable, ~Escapable
    associatedtype Element: ~Copyable, ~Escapable  

    default Element: Copyable, Element: Escapable
}
```

This might also serve as a way for a protocol to opt generic parameters out
of defaulting to `Copyable` and/or `Escapable` when the protocol is used as a constraint,
which may be desirable for protocols that are only used with non-`Copyable` or
non-`Escapable` conformers in practice.

#### Default constraint sets

There may be more than one local optimum set of default requirements for a protocol. An elaboration of the protocol-defined defaults idea might be to allow multiple default constraint sets, which can be individually suppressed as a group. For instance, this would make it possible to provide constraint sets to suppress copying and escaping individually, without making developers write out the entire set of constraint suppressions:

```
protocol Container: ~Copyable, ~Escapable {
    associatedtype BorrowingIterator: BorrowingIteratorProtocol,
      ~Copyable, ~Escapable
    associatedtype Element: ~Copyable, ~Escapable  
    
    default constraintset Copying where Self: Copyable, Self.Element: Copyable
    default constraintset Escaping where Self: Escapable, Self.Element: Escapable
}

// implicitly has Copying & Escaping sets of requirements
extension Container {}

extension Container without Copying {} // some inbetween kind
extension Container without Escaping {} 

extension Container without Copying, Escaping {} // fully unconstrained in -version

// For generic signatures in other positions, we could have syntax 
// that allows you to refer to constraintsets like a member:
func f<T: Container, V: Container>() without T: Container.Copying {}

```

This functionality might also be used for future evolution. Let’s say we add a third suppressable protocol `Runcible` in the future, and we want to generalize `Container` to allow for `~Runcible` elements. We can suppress the `Runcible` requirement on `Self` and `Self.Element` along with a new default constraint set that reinstates the requirements for existing code. Existing code would continue to apply all of the default sets, and doesn’t know about the new constraint set yet so would not suppress the newly lifted requirements:

```
protocol Container: ~Copyable, ~Escapable,
  // added in v2:
  ~Runcible {
    associatedtype BorrowingIterator: BorrowingIteratorProtocol,
      ~Copyable, ~Escapable
    associatedtype Element: ~Copyable, ~Escapable,
      // added in v2:
      ~Runcible
      
    associatedtype SubContainer: Container /*implies where SubContainer: C,E,R*/
    
    default constraintset Copying where Self: Copyable, Self.Element: Copyable
    default constraintset Escaping where Self: Escapable, Self.Element: Escapable
    // added in v2 to maintain compatibility:
    default constraintset Runcing where Self: Runcible, Self.Element: Runcible
}

// These all retain their meaning from v1:
extension Container {}
extension Container without Copying {}
extension Container without Escaping {} 
extension Container without Copying, Escaping {}

// In v2, code can now do the following for maximum permissivity:
extension Container without Copying, Escaping, Runcing {}
```
