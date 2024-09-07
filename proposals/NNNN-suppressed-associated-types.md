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
TODO: how (??)

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

### Strategy 2: Introduce a new base protocol instead

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
> compatability.

## Future directions

TODO: Describe the typealias idea.

## Alternatives considered

TODO: explain the various ideas we've had

## Acknowledgments

TODO: thank people
