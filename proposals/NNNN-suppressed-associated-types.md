# Suppressed Default Conformances on Associated Types

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Kavon Farvardin](https://github.com/kavon), [Slava Pestov](https://github.com/slavapestov)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: on `main`, using `-enable-experimental-feature SuppressedAssociatedTypes`
* Previous Proposals: [SE-427: Noncopyable Generics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md), [SE-446: Nonescapable Types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md)

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

However, with the current proposal,this  defaulting behavior does
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
  func makeCopies(_ e: Self.Element) -> (Self.Element, Self.Element) {
    return (e, e)
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
the body of `makeCopies()` assumes `e` is `Copyable`, and this
assumption is no longer true. 

## ABI Compatibility

The ABI of existing code is not affected by this proposal.

On the other hand, changing an associated type declaration in an library
to suppress conformance is an ABI-breaking change, for similar reasons
to those described above.

## Alternatives Considered

A more advanced form of this idea would attempt to introduce "recursive
`Copyable` requirements" (and similarly for `Escapable`). This was already
discussed in the **Alternatives Considered** section of
[SE-427: Noncopyable Generics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md), and the difficulties outlined there still
apply today.