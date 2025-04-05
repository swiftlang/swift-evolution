# Suppresssed Associated Types

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Kavon Farvardin](https://github.com/kavon), [Slava Pestov](https://github.com/slavapestov)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: on `main`, using `-enable-experimental-feature SuppressedAssociatedTypes`
* Previous Proposal: [SE-427: Noncopyable Generics](0427-noncopyable-generics.md)

## Introduction

When defining an associated type within a protocol, there should be a way to 
permit noncopyable types as a witness. This would allow for the definition of
protocols that operate on a generic type that is not required to be `Copyable`:

```swift
// Queue has no reason to require Element to be Copyable.
protocol Queue<Element> {
  associatedtype Element

  mutating func push(_: consuming Element)
  mutating func pop() -> Element
}
```

This creates a problem using the `Queue` protocol as an abstraction over a queue
of noncopyable elements, because the `associatedtype Element` implicitly
requires its type witness to be Copyable.

```swift
struct WorkItem: ~Copyable { /* ... */ }

class WorkQueue: Queue {
//    `- error: type 'WorkQueue' does not conform to protocol 'Queue'
  typealias Element = WorkItem
//          `- note: possibly intended match 'WorkQueue.Element' (aka 'WorkItem') does not conform to 'Copyable'

  func push(_ elm: consuming Element) { /* ... */ }
  func pop() -> Element? { /* ... */ }
}
```

There is no workaround for this problem; protocols simply cannot be used in this
situation!

## Proposed solution

A simple design for suppressed associated types is proposed. A protocol's 
associated type that does not require a copyable type witness must be annotated
with `~Copyable`:

```swift
protocol Manager {
  associatedtype Resource: ~Copyable
}
```

A protocol extension of `Manager` does _not_ carry an implicit 
`Self.Resource: Copyable` requirement:

```swift
extension Manager {
  func f(resource: Resource) {
    // `resource' cannot be copied here!
  }
}
```

Thus, the default conformance in a protocol extension applies only to `Self`,
and not the associated types of `Self`. For this reason, while adding
`~Copyable` to the inheritance clause of a protocol is a source-compatible
change, the same with an _associated type_ is __not__ source compatible.
The designer of a new protocol must decide which associated types are
`~Copyable` up-front.

## Detailed design

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

## Source compatibility

The addition of this feature to the language does not break any existing code.

## ABI compatibility

The ABI of existing code is not affected by this proposal. Changing existing
code to make use of `~Copyable` associated types _can_ break ABI.

TODO: how, exactly (??)

## Implications on adoption

Using the feature to mark an associated type as `~Copyable` risks breaking existing source code using that protocol and ABI.

For example, suppose the following `Queue` protocol existed before, but has now
had `~Copyable` added to the `Element`:

```swift
public protocol Queue {
  associatedtype Element: ~Copyable  // <- newly added ~Copyable
  
  // Checks for a front element and returns it, without removal.
  func peek() -> Element?
  
  // Removes and returns the front element.
  mutating func pop() throws -> Element
  
  // Adds an element to the end.
  mutating func push(_: consuming Element)
}
```

Any existing code that worked with generic types that conform to `Queue` could
show an error when attempting to copy the elements of the queue:

```swift
// error: parameter of noncopyable type 'Q.Element' must specify ownership
func fill<Q: Queue>(queue: inout Q, 
                    with element: Q.Element,
                    times n: Int) {
  for _ in 0..<n {
    queue.push(element)
  }
}
```

This `fill` function fundamentally cannot work with noncopyable elements, as it
depends on the ability to make copies of `element` to push onto the queue. 

### Strategy 1: Add missing Copyable requirements
 
One way to solve this source break in the `fill` function is to update it, by 
adding a `where` clause requiring the queue's elements to be copyable:

```swift
func fill<Q: Queue>(queue: inout Q, 
                    with element: Q.Element,
                    times n: Int) 
                    where Q.Element: Copyable {
  // same as before
}
```

This strategy is only appropriate when all users can easily update their code.

> NOTE: Adding the `where` clause will also help preserve the ABI of functions
> like `fill`, because without it, the new _absence_ of a Copyable requirement
> on the  `Q.Element` will be mangled into the symbol for that generic function.
> 
> In addition, without the `where` clause, the parameter `element` would require
> some sort of ownership annotation. Adding ownership for parameters can break 
> ABI. See [SE-0377](0377-parameter-ownership-modifiers.md) for details.

### Strategy 2: Introduce a new base protocol

Rather than annotate the existing `Queue`'s associated type to be noncopyable,
introduce a new base protocol `BasicQueue` that `Queue` now inherits from:

```swift
public protocol BasicQueue {
  associatedtype Element: ~Copyable
  
  // Removes and returns the front element.
  mutating func pop() throws -> Element
  
  // Adds an element to the end.
  mutating func push(_: consuming Element)
}

public protocol Queue: BasicQueue {
  associatedtype Element
  
  // Checks for a front element and returns it, without removal.
  func peek() -> Element?
}
```

There are two major advantages of this approach. First, users of `Queue` do not
need to update their source code. Second, any method or property requirements
that cannot be satisfied by conformers can remain in the derived protocol.

In this example, the `peek` method requirement cannot be realistically
satisfied by an implementation of `BasicQueue` that holds noncopyable elements.
It requires the ability to return a copy of the same first element each time 
it is called. Thus, it remains in `Queue`, which is now derived from the
`BasicQueue` that holds the rest of the API that _is_ compatible with
noncopyable elements. 

This strategy is only appropriate if the new base protocol can stand on its own
as a useful type to implement and use. 

> NOTE: introducing a new inherited protocol to an existing one will break ABI
> compatibility. It is equivalent to adding a new requirement on Self in the 
> protocol, which can impact the mangling of generic signatures into symbols.

<!-- ### Strategy 3: Introduce a new protocol beside another

To avoid breaking ABI or source compatibility, it's possible to introduce new
protocols that do not require a Copyable associated type, while providing a
default conformance to this new protocol for types that only conform to the old
one:

```swift
// A new Queue-like protocol that is very mindful to not include requirements
// like 'peek' cannot be implemented for noncopyable Elements.
public protocol DemureQueue {
  associatedtype Element: ~Copyable
  mutating func pop() throws -> Element
  mutating func push(_: consuming Element)
}

// The original Queue that requires Element to be Copyable.
public protocol Queue {
  associatedtype Element
  func peek() -> Element?
  mutating func pop() throws -> Element
  mutating func push(_: consuming Element)
}
```

FIXME: Delete this. It isn't workable like I thought! See Future Directions. 

 -->


## Future directions

The future directions for this proposal are machinery to aid in the 
adoption of noncopyable associated types. This is particularly relevant for 
Standard Library types like Collection.

#### Conditional Requirements

Suppose we could say that a protocol's requirement only needs to be witnessed
if the associated type were Copyable. Then, we'd have a way to hide specific requirements of an existing protocol if they aren't possible to implement:

```swift
public protocol Queue {
  associatedtype Element: ~Copyable
  
  // Only require 'peek' if the Element is Copyable.
  func peek() -> Element? where Element: Copyable

  mutating func pop() throws -> Element
  mutating func push(_: consuming Element)
}
```

This idea is similar optional requirements, which are only available to
Objective-C protocols. The difference is that you statically know whether a 
generic type that conforms to the protocol will offer the method. Today, this 
is not possible at all:

```swift
protocol Q {}

protocol P {
  associatedtype A
  func f() -> A where A: Q
  // error: instance method requirement 'f()' cannot add constraint 'Self.A: P' on 'Self'
}
```

#### Bonus Protocol Conformances

Even if the cost of introducing a new protocol is justified, it is still an 
ABI break to introduce a new inherited protocol to an existing one.
That's for good reason: a library author may add new requirements that are 
unfulfilled by existing users, and that should result in a linking error.

However, it might be possible to allow "bonus" protocol conformances, which
adds an extra conformance to any type that conforms to some other protocol:

```swift
protocol NewQueue { 
  associatedtype Element: ~Copyable
  // ... push, pop ...
}

protocol Queue { 
  associatedtype Element
  // ... push, pop, peek ...
}

// A type conforming to Queue also conforms to NewQueue where Element: Copyable.
// This is a "bonus" conformance.
extension Queue: NewQueue {
  typealias Element = Queue.Element
  mutating func push(_ e: consuming Element) { Queue.push(e) }
  mutating func pop() -> Element throws { try Queue.pop() }
}
```

To make this work, this bonus protocol conformance:
  1. Needs to provide implementations of all requirements in the bonus protocol.
  2. Take lower precedence than a conformance to `NewQueue` declared directly on the type that conforms to `Queue`.
  3. Perhaps needs to be limited to being declared in the same module that defines the extended protocol.
   
The biggest benefit of this capability is that it provides a way for all 
existing types that conform to `Queue` to also work with new APIs that are based
on `NewQueue`. It is a general mechanism that works for scenarios beyond the 
adoption of noncopyable associated types.

## Acknowledgments

TODO: thank people
