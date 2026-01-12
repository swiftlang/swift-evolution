# Suppressed Default Conformances on Associated Types With Defaults

* Proposal: [SE-0503](0503-suppressed-associated-types.md)
* Authors: [Kavon Farvardin](https://github.com/kavon)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Active Review (January 11-25, 2026)**
* Implementation: on `main` using `-enable-experimental-feature SuppressedAssociatedTypesWithDefaults`
* Previous Proposals: [SE-0427: Noncopyable Generics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md), [SE-0446: Nonescapable Types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-suppressed-associated-types-with-defaults/83663)) ([review](https://forums.swift.org/t/se-0503-suppressed-default-conformances-on-associated-types-with-defaults/84070))

**Table of Contents**
- [Suppressed Default Conformances on Associated Types With Defaults](#suppressed-default-conformances-on-associated-types-with-defaults)
  - [Introduction](#introduction)
  - [Proposed Solution](#proposed-solution)
    - [Defaulting Behavior](#defaulting-behavior)
  - [Detailed Design](#detailed-design)
    - [Expansion Procedure](#expansion-procedure)
    - [Limits of Suppression](#limits-of-suppression)
    - [Protocol inheritance](#protocol-inheritance)
    - [Extensions](#extensions)
    - [Existentials](#existentials)
    - [Recursion](#recursion)
    - [Default Witnesses](#default-witnesses)
    - [Library evolution and new associated type requirements](#library-evolution-and-new-associated-type-requirements)
    - [Conditional conformance](#conditional-conformance)
  - [Source Compatibility](#source-compatibility)
  - [ABI Compatibility](#abi-compatibility)
  - [Future Directions](#future-directions)
    - [Constrained Existentials via `some`](#constrained-existentials-via-some)
  - [Alternatives Considered](#alternatives-considered)
    - [No defaulting](#no-defaulting)
    - [Definition-driven associated type defaults](#definition-driven-associated-type-defaults)
      - [Protocol-defined default requirements](#protocol-defined-default-requirements)
      - [Default constraint sets](#default-constraint-sets)
  - [Acknowledgements](#acknowledgements)


## Introduction

An associated type defines a generic type in a protocol. 
You use them to help define the protocol's requirements. 
This Queue has two associated types, Element and Allocator: 
```swift
/// Queue has no reason to require Element to be Copyable.
protocol Queue<Element>: ~Copyable {
  associatedtype Element
  associatedtype Allocator = DefaultAllocator

  init()
  init(alloc: Allocator)

  mutating func push(_: Element)
  mutating func pop() -> Element
  // ...
}
```
The first associated type Element represents the type of value by which
`push` and `pop` must be defined.

Any type conforming to Queue must define a nested type Element that satisfies
(or _witnesses_) the protocol's requirements for its Element.
This nested type could be a generic parameter named Element, a typealias named 
Element, and so on.
While the type conforming to Queue is permitted to be noncopyable, its Element
type has to be Copyable:
```swift
/// error: LinkedList does not conform to Queue
/// note: Element is required to be Copyable
struct LinkedList<Element: ~Copyable>: ~Copyable, Queue {
  ...
}
```
This is because in [SE-427: Noncopyable Generics](0427-noncopyable-generics.md),
an implicit requirement that Queue.Element is both Copyable and Escapable is inferred,
with no way to suppress it.
This is an expressivity limitation in practice, as it prevents Swift programmers 
from defining protocols in terms of noncopyable or nonescapable associated
types.

## Proposed Solution

The existing syntax for suppressing these default conformances is extended to 
associated type declarations:

```swift
/// Correct Queue protocol.
protocol Queue<Element>: ~Copyable {
  associatedtype Element: ~Copyable
  associatedtype Allocator: ~Copyable = DefaultAllocator

  init()
  init(alloc: consuming Allocator)

  mutating func push(_: consuming Self.Element)
  mutating func pop() -> Self.Element
}
```

Now, LinkedList can conform to Queue, as its Element is not required to be 
Copyable.
The associated type Allocator is also not required to be Copyable, meaning the
DefaultAllocator, which is used when the conformer doesn't define its own 
Allocator, can be either Copyable or not.
Similarly, stating `~Escapable` is allowed, to suppress the default 
conformance requirement for Escapable. 
Unless otherwise noted, any discussion of `~Copyable` types applies equivalently 
to `~Escapable` types in this proposal.

### Defaulting Behavior

Swift's philosophy behind 
[defaulting](0427-noncopyable-generics.md#default-conformances-and-suppression) 
generic parameters to be Copyable (and Escapable) is rooted in the idea that
programmers expect their types to have that ability.
Library authors choosing to generalize their design with support for `~Copyable`
generics will not impose a burden of annotation on the common user, because 
Swift will default their extensions and generic parameters to still be Copyable.
This idea serves as the foundation of the proposed defaulting behavior for associated types.

Here is a simplistic protocol for a Buffer that imposes no Copyable 
requirements:

```swift
protocol Buffer<Data>: ~Copyable {
  associatedtype Data: ~Copyable
  associatedtype Parser: ~Copyable
  ...
}
```

Recall the existing rules from
[SE-427: Noncopyable Generics](0427-noncopyable-generics.md). Under
those rules, a protocol extension of Buffer always introduces a
default `Self: Copyable` requirement, since the protocol itself doesn't require it.

By this proposal, default conformance requirements will also be introduced if any of a protocol's
_primary_ associated types (those appearing in angle brackets) are suppressed.
For Buffer, that means only a default `Data: Copyable` is introduced,
not one for the ordinary (non-primary) associated type Parser, when constraining the generic parameter `B` to conform to Buffer:

```swift
// by default,  B: Copyable, B.Data: Copyable
func read<B: Buffer>(_ bytes: [B.Data], into: B) { ... }
```

Unlike a primary associated type, an ordinary associated type is not typically 
used generically by conformers.
This rationale is in line with the original reason there is a distinction among 
associated types from [SE-346](0346-light-weight-same-type-syntax.md):

> Primary associated types are intended to be used for associated types which are usually provided by the caller. 
> These associated types are often witnessed by generic parameters of the conforming type.

The type Buffer is an example of this, as users often will build utilities
that deal with the Data generically, not Parser. Consider these example
conformers,

```swift
struct BinaryParser: ~Copyable { ... }
struct TextParser { ... }

class DecompressingReader<Data>: Buffer {
  typealias Parser = BinaryParser
}

struct Reader<Data>: Buffer {
  typealias Parser = TextParser
}

// by default,  Self.Copyable, Self.Data: Copyable
extension Buffer {
  // `valid` is provided for both DecompressingReader and Reader
  func valid(_ bytes: [UInt8]) -> Bool { ... }
}
```

If ordinary associated types like `Buffer.Parser` were to default to 
Copyable, then the extension of Buffer adding a `valid` method would exclude conformers
that witnessed the Parser with a noncopyable type, despite that being an
implementation detail.

## Detailed Design

There are three ways to impose a requirement on an associated type:
- In the inheritance clause of the associated type declaration.
- In a `where` clause attached to the associated type declaration.
- In a `where` clause attached to the protocol itself.

This proposal extends the **Detailed Design** section of
[SE-427: Noncopyable Generics](0427-noncopyable-generics.md) to allow
suppressing default conformance to Copyable in Escapable in all of
the above positions. Thus, all three below are equivalent:
```swift
protocol P { associatedtype A: ~Copyable }
protocol P { associatedtype A where Self.A: ~Copyable }
protocol P where Self.A: ~Copyable { associatedtype A }
```

### Expansion Procedure

While building the [generic signature](https://download.swift.org/docs/assets/generics.pdf) 
for a declaration, such as a generic function or type, the expansion procedure adds 
infers extra requirements based on the desugared requirements of that declaration.
The procedure itself is simple,

> Suppose there is a protocol `P` that declares primary associated types `A1, ..., An`. 
> If there exists a desugared requirement `Subject: P`, the procedure infers 
> the extra requirements `Subject.A1: IP, ..., Subject.An: IP`, for each invertible
> protocol `IP ∈ {Copyable, Escapable}`.
> If there exists a validly scoped inverse requirement `Subject.A1: ~IP`, then 
> that cancels out the inferred requirement `Subject.A1: IP`, for any invertible 
> protocol IP.

As in [SE-427: Noncopyable Generics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md), 
after building the declaration's generic signature, if there was an inverse
requirement `Thing: ~IP` and yet Thing must conform to IP anyway, then the 
inverse requirement is diagnosed as invalid.

### Limits of Suppression

Default requirements become fixed once the generic signature is built for that
declaration, after applying the expansion procedure. For example,

```swift
protocol Pushable<Element> {
  associatedtype Element: ~Copyable
}

struct Stack<Scope: Pushable> {}

func push<Val>(_ s: Stack<Val>, _ v: Val) 
  where Val.Element: ~Copyable // error
  {}
```

When the generic signature of Stack is built, the expansion procedure adds
the requirement `Scope.Element: Copyable`, because of the requirement
`Scope: Pushable` and Element being a primary associated type. The minimized
generic signature of Stack becomes,

```
<Scope where Scope : Pushable, Scope.[Pushable]Element : Copyable>
```

When building the generic signature of `push`, requirement inference consults 
the generic signature of Stack, adding the hard requirements that 
`Val == Scope` and `Scope.Element: Copyable`. There is no way to satisfy the
inverse requirement `Val.Element: ~Copyable` without mutating the generic 
signature of Stack, which is not permitted, so the inverse requirement is 
illegally scoped in `push`.

The same concept applies to the requirement signatures of a protocol becoming
fixed after expansion is applied to it locally. Consider this protocol `P`,

```swift
protocol P<A>: ~Copyable { 
  associatedtype A: ~Copyable
}
```

Its requirement signature is `<Self where Self : Escapable, Self.A : Escapable>`,
because the default Copyable requirements were suppressed on both Self and
`Self.A`. Next, consider this protocol `Q`,

```swift
protocol Q<B>: ~Copyable { 
  associatedtype B: ~Copyable, P
}
```

The expansion procedure applies locally to `Q` as follows. 
The desugared requirement `Self.B: P` implies `Self.B.A: Copyable`, yielding the now-fixed requirement signature:

```
<Self where Self : Escapable, Self.B : P, Self.B.A : Copyable>
                                          ~~~~~~~~~~~~~~~~~~~
                                          from expansion procedure
```

Constraining a generic type parameter `T` to conform to `Q` only permits suppression of a default inferred for `T.B`, not `T.B.A`:

```swift
func limits<T: Q>(_ t: T) 
  where T.B: ~Copyable, 
        T.B.A: ~Copyable // error: T.B.A is required to be Copyable
        {}
```

Inverses can apply across equality constraints _within the same declaration's generic signature_
to cancel-out default requirements from primary associated types. Consider this example,

```swift
protocol Iterable<Element>: ~Copyable {
  associatedtype Element: ~Copyable
}

struct Cursor<Value>: Iterable<Value> where Value: ~Copyable {}
```

In Cursor, the inheritance clause contains `Iterable<Value>` yielding the 
desugared requirements `Element: Copyable` and `Element == Value`.
There is also an inverse requirement `Value: ~Copyable` within Cursor 
that cancels-out the default requirement `Element: Copyable` inferred from 
the conformance to Iterable. Thus, the inverse requirement is well-scoped.

### Protocol inheritance

Defaulting interacts with protocol inheritance as follows. If a base protocol
declares an associated type with a suppressed conformance, this
associated type will also have a suppressed conformance in the derived
protocol, unless either of the following are true:

 1. it is a primary associated type in the base protocol
 2. the derived protocol re-states the associated type

Here are some examples,
```swift
protocol Base<A> {
  associatedtype A: ~Copyable
  associatedtype B: ~Copyable
}

// Case 1: 'A' requires Copyable because it's a primary associated type in Base
protocol Derived1: Base {
  // 'A' is Copyable
  // 'B' is ~Copyable
}

// Case 2, Restating the associated type B infers fresh defaults for it.
protocol Derived2: Base {
  // 'A' is Copyable
  // 'B' is Copyable
  associatedtype B
}
```

It is possible to suppress the default coming from a base protocol via Case 1 
using an inverse requirement:

```swift
// Derived3 suppresses the default from Case 1.
protocol Derived3: Base where Self.A: ~Copyable {
  // 'A' is ~Copyable
  // 'B' is ~Copyable
}
```

Elevating an ordinary associated type from a base protocol to a primary 
associated type (such as in Child) will not infer a default within that
particular protocol,

```swift
protocol Child<B>: Base {
  // 'A' is Copyable
  // 'B' is ~Copyable
}
```

But that elevation it will infer defaults in protocols downstream of it,
such as in Grandchild:

```swift
// Case 1: Child.B is a primary associated type
protocol Grandchild: Child {
  // 'A' is Copyable
  // 'B' is Copyable
}
```

It is illegal to suppress the Copyable requirements
on `A` or `B` in a protocol derived from Grandchild, as they become fixed
in the Grandchild protocol:

```swift
protocol GrandGrandchild: Grandchild {
  // 'A' is Copyable
  // 'B' is Copyable
}
```

Case 1 does not apply in GrandGrandchild to permit suppression
on 'A' or 'B' coming from Grandchild. It is the same situation as this:

```swift
protocol Bird {
  associatedtype Song
}

protocol Eagle: Bird where Self.Song: ~Copyable {}
```

where Bird declares a Song that is an associated type with a fixed Copyable
requirement; it not suppressed and not defaulted in Eagle via Case 1.

### Extensions

Consider this simple protocol for iteration,

```swift
protocol Iterable<Element>: ~Copyable {
  associatedtype Element: ~Copyable
  ...
}
```

An extension of Iterable introduces a default for Element because it is
a primary associated type, which is suppressible:

```swift
// implicitly,  where Self: Copyable, Self.Element: Copyable
extension Iterable {}

// implicitly,  where Self: Copyable
extension Iterable where Element: ~Copyable {}

// fully without defaults
extension Iterable where Self: ~Copyable, Element: ~Copyable {}
```

For ordinary associated types like Strategy in the next example, 
no default is inferred,

```swift
protocol PersistedDictionary<Key, Value>: ~Copyable {
  associatedtype Key: ~Copyable
  associatedtype Value: ~Copyable
  associatedtype Strategy: ~Copyable
}

// implicitly,  where Self: Copyable, Self.Key: Copyable, Self.Value: Copyable
extension PersistedDictionary {}
```

An inverse requirement in an extension of a protocol that conflicts with the
protocol's requirement signature is invalid,

```swift
protocol Viewable<Element>: Iterable {}

extension Viewable where Element: ~Copyable {}
// ^ error: 'Self.Element' required to be 'Copyable' but is marked with '~Copyable'
```

Viewable's requirement signature includes `Self.Element: Copyable` from
its inheritance of Iterable, which has its Element as a primary associated 
type. Once that becomes fixed in Viewable's signature, extensions of it cannot
remove the Copyable requirement. The inverse requirement must be stated on
Viewable itself to suppress the default requirement from Iterable.

### Existentials

Suppose we have the protocol,

```swift
protocol Source<Element>: ~Copyable {
  associatedtype Element: ~Copyable
  associatedtype Generator: ~Copyable
  
  func element() -> Element
  func generator() -> Generator
}
```

Existentials such as `any P` work similarly to the case of a single generic 
parameter `T`  has a conformance requirement `T: P`. The expansion of
defaults happens here as well,

```swift
func ex1(_ s: any Source) {
  let e = s.element()   // <- Copyable
  let g = s.generator() // <- NOT Copyable
}
```

It's possible to constrain the existential using a generic type parameter,
which will suppress the defaults expansion for the primary associated type of
Source,

```swift
func ex2<R: ~Copyable>(_ s: any Source<R>) {
  let e = s.element()   // <- NOT Copyable
  let g = s.generator() // <- NOT Copyable
}
```

### Recursion

There can be an infinite number of type parameters derivable from a conformance
requirement, because a protocol's associated type requirement can be part of a cycle with the protocol itself:

```swift
protocol P<A>: ~Copyable {
  associatedtype A: ~Copyable, P
}
```

For a generic signature `<R where R: P>`, all of the type parameters 
`R.A, R.A.A, R.A.A.A, ...`,
are Copyable. 
For any type parameter `X` rooted in `R`, the type `X.A` conforms to `P`, and by the expansion procedure, that implies `X.A: Copyable` because `A` is a primary
associated type of `P`.

Next, consider this pair of mutually recursive protocols where only one of 
them has a primary associated type,

```swift
protocol First<A>: ~Copyable {
  associatedtype A: ~Copyable, Second
}

protocol Second: ~Copyable {
  associatedtype B: ~Copyable, First
}
```

For a generic signature `<T where T: First>`, we observe that any type parameter
rooted in T and ending with an A, such T.A.B.A, is Copyable because 
`T.A.B: First` and First has a primary associated type A. 
Similarly, for type parameter T.A.B which ends in a B, it is *not* required to conform to Copyable, because `T.A: Second` and Second has only
the ordinary associated type B. So there is an alternating pattern for the 
defaults,

```
T.A : Copyable
T.A.B: ~Copyable
T.A.B.A: Copyable
T.A.B.A.B: ~Copyable
...
```

### Default Witnesses

An associated type can already declare a default _witness_, which is a type that
is used to witness an associated type requirement, if the conforming type does
not specify one. For example, in SegmentedArray's conformance to Queue, it 
doesn't declare a nested type named Allocator satisfying the requirements of
`Queue.Allocator`, so it automatically uses DefaultAllocator:
```swift
protocol Queue<Element>: ~Copyable {
  associatedtype Element: ~Copyable
  associatedtype Allocator: Alloc & ~Copyable = DefaultAllocator
  ...
  `init(alloc: consuming Allocator)`
}
protocol Alloc: ~Copyable { ... }
struct DefaultAllocator: Alloc { ... }
```
The DefaultAllocator conforms to Copyable, which is simple for conformers
when implementing the rest of Queue's requirements:
```swift
struct SegmentedArray<Element>: Queue { 
  // uses DefaultAllocator by default
  init(alloc: DefaultAllocator)
}
```
By the defaulting rules in this proposal, a generic type parameter `Q` 
constrained to Queue will *not* assume `Q.Allocator` is Copyable, since it is
an ordinary associated type:
```swift
// by default,  Q.Element: Copyable
func createSubQueues<Q: Queue>(_ kind: Q.Type, 
                               n: Int, 
                               with alloc: borrowing Q.Allocator) -> [Q] {
  // Q.Allocator is ~Copyable
}
```
Thus, even if the default witness for a suppressed associated type conforms to
Copyable and/or Escapable, matching generic requirement(s) *are not*
introduced. 

> **Rationale:** Part of the reason for this is understandability, as it's 
> possible for the default witness to have a conditional conformance for
> Copyable or Escapable. For example,
> 
> ```swift
> struct ForwardIterator<Item: ~Copyable>: ~Copyable { ... }
> extension ForwardIterator: Copyable where Item: Copyable { ... }
> 
> protocol Iterable<Element> {
>   associatedtype Element: ~Copyable
>   associatedtype Iter: ~Copyable = ForwardIterator<Element>
>   
>   func getIter() -> Iter
> }
> ```
> The default witness for `Iterable.Iter` is ForwardIterator, which is only
> Copyable if the Element is Copyable. Thus, the default constraints for 
> Iter would vary depending on the Element type in these functions:
> 
> ```swift
> func runForwardsInt(_ it: some Iterable<Int>) {
>   _ = copy it.getIter() // OK
> }
> 
> func runForwardsNC(_ it: some Iterable<NonCopyableType>) {
>   _ = copy it.getIter() // error: copy of noncopyable type
> }
> ```
> The same goes for extensions of the protocol.


### Library evolution and new associated type requirements

Protocols are allowed to introduce new requirements, including associated type
requirements, without breaking source or binary compatibility, as long
as a default implementation is provided for existing code.

Suppose a new primary associated type is introduced that is `~Copyable` and
the default witness does not conform to Copyable:

```swift
protocol Foo<New> {
  // Added in v2
  associatedtype New: ~Copyable
}

struct NC: ~Copyable {}

// Added in v2
extension Foo where New: ~Copyable { typealias New = NC }
```

Because of the defaulting behavior of primary associated type to Copyable, 
and the choice of providing a noncopyable default witness, this can change
the meaning of source code when it compiles against the new definition of the 
protocol:

```swift
struct ExistingConformance: Foo {}

// `T: Foo` implies `T.New: Copyable` after recompiling against Foo v2...
func existingFunction<T: Foo>(_: T) {}

func existingCaller() {
  // ...then this previously-working line of code would stop compiling, because
  // ExistingConformance.New defaults to noncopyable type NC, so doesn't
  // satisfy the default `T.New: Copyable` requirement.
  existingFunction(ExistingConformance())
}
```

Thus, the default witness must be carefully chosen to avoid a source break.

### Conditional conformance

Finally, recall that concrete types may conform to Copyable and
Escapable conditionally, depending on the copyability or
escapability of a generic parameter. Even though associated types
may now suppress conformance to these protocols, a conditional
conformance to Copyable or Escapable that depends on an
associated type is still not allowed:
```swift
protocol Goose: ~Copyable { associatedtype Quack: ~Copyable }
struct Pond<G: Goose>: ~Copyable {}
extension QueueHolder: Copyable where G.Quack: Copyable {}  // error
```
This restriction is for runtime implementation limitations.

<!-- TODO: Perhaps the limitation needs elaboration? -->


## Source Compatibility

The introduction of this feature in the language does not break
any existing code, because any usage of the suppressed conformance
syntax with associated types was diagnosed as an error.

One of the goals of this proposal is to make it safe to suppress a conformance on an 
*existing* primary associated type. A protocol's set of  primary associated types
can’t be added to or removed once declared without breaking source compatibility.

Changing an existing *ordinary* associated type declaration to suppress
conformance to Copyable or Escapable is also a **source-breaking** change.
For example, if a library publishes this protocol:
```swift
public protocol Manager: ~Copyable {
  associatedtype Resource
}
```
Client code that states a `T: Manager` requirement on a generic
parameter `T` can then assume that the type parameter
`T.Resource` is Copyable:
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
The client's extension of Manager will no longer type check, because
the body of `makeCopies()` assumes `r` is Copyable, and this
assumption is no longer true. 

## ABI Compatibility

The ABI of existing code is not affected by this proposal.

On the other hand, changing an associated type declaration in an library
to suppress conformance is can be an ABI-breaking change. For example, an
extension of a protocol providing a default implementation could have its symbol
name change, as these two implementations of `greet` must have distinct names:

```swift
protocol Greeter<T> {
  associatedtype T: ~Copyable
  func greet()
}

extension Greeter {
  func greet() { print("hello")}
}

extension Greeter where T: ~Copyable {
  func greet() { print("سلام") }
}
```

## Future Directions

It's possible to imagine additional functionality that could one day be 
supported, but is not part of this proposal.

### Constrained Existentials via `some`

There is some support for constrained existentials, such as

```swift
func f<T: Hashable>(_ e: any P<T>) {}
```

It might be a generally useful feature if there were support for a syntax such as
`any P<some Hashable>` to permit the constrained existential to carry with it the
constraint that its primary associated type conforms to Hashable. 
That syntax could then be extended to allow suppression of defaults in the
constrained existential via `any Q<some ~Copyable>`.


## Alternatives Considered

Through the development of this proposal, various alternate formulations were considered.

### No defaulting

A prior version of this proposal [was pitched](https://forums.swift.org/t/pitch-suppressed-default-conformances-on-associated-types/81880) that was absent of any defaulting behavior for associated types. The primary fault was that it
provided an inconsistent behavior when compared with generic types like S:

```swift
struct S<T: ~Copyable>: ~Copyable {}

protocol P<T>: ~Copyable {
  associatedtype T: ~Copyable
}

extension S {} // T: Copyable
extension P {} // T: ~Copyable
```

Only the extension for S provides a default for its T.

### Definition-driven associated type defaults

Rather than try to impose a blanket default on all primary associated types, we might
instead apply a limited defaulting rule only to select associated types, driven
by some aspect of the protocol definition. This could come at the expense of
increased language complexity. Readers would have to carefully consult the 
definitions of protocols to see whether they come with default Copyable 
or Escapable requirements on their associated types.

Some possibilities for how this might look include:

#### Protocol-defined default requirements

We could let a protocol definition dictate any set of Copyable or Escapable requirements to get imposed by default when used as a generic requirement. This set of requirements would have to be finite.

```swift
protocol Container: ~Copyable, ~Escapable {
    associatedtype BorrowingIterator: BorrowingIteratorProtocol,
      ~Copyable, ~Escapable
    associatedtype Element: ~Copyable, ~Escapable  

    default Element: Copyable, Element: Escapable
}

// defaults to 'where Element: Copyable & Escapable' only.
//
// Self and Self.BorrowingIterator remain ~Copyable & ~Escapable
extension Container {}
```

This might also serve as a way for a protocol to opt generic parameters *out*
of defaulting to Copyable and/or Escapable when the protocol is used as a constraint,
which may be desirable for protocols that are only used with noncopyable or
nonescapable conformers in practice.

#### Default constraint sets

There may be more than one local optimum set of default requirements for a protocol. An elaboration of the protocol-defined defaults idea might be to allow multiple, *named* sets of constraints, which can be individually suppressed as a group. For instance, this would make it possible to provide configurations of a protocol to suppress copying and escaping individually, without making developers write out the entire set of constraint suppressions:

```swift
protocol Container: ~Copyable, ~Escapable {
    associatedtype BorrowingIterator: BorrowingIteratorProtocol,
      ~Copyable, ~Escapable
    associatedtype Element: ~Copyable, ~Escapable  
    
    default constraintset Copying where Self: Copyable, Self.Element: Copyable
    default constraintset Escaping where Self: Escapable, Self.Element: Escapable
}

// implicitly has the 'Copying' & 'Escaping' sets of requirements
extension Container {}

extension Container without Copying {} // some inbetween kind
extension Container without Escaping {} 

extension Container without Copying, Escaping {} // fully unconstrained in -version

func f<T: Container>() without T: Container.Copying {}

// We could have syntax that allows you to refer to constraintsets like a member,
// to opt out a generic type parameter from multiple constrainsets:
func g<T: Container & P>() without T: Container.Copying or T: P.Copying {}
```

This functionality might also be used for future evolution. Let’s say we add a third suppressable protocol Runcible in the future, and we want to generalize Container to allow for `~Runcible` elements. We can suppress the Runcible requirement on Self and `Self.Element` along with a new default constraint set that reinstates the requirements for existing code. Existing code would continue to apply all of the default sets, and doesn’t know about the new constraint set yet, so would not suppress the newly lifted requirements:

```swift
protocol Container: ~Copyable, ~Escapable, ~Runcible {
                                         // ^ added in v2

    associatedtype BorrowingIterator: BorrowingIteratorProtocol,
      ~Copyable, ~Escapable
    associatedtype Element: ~Copyable, ~Escapable, ~Runcible
                                                // ^ added in v2:
      
      
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

## Acknowledgements

I'd like to thank the following people for their discussion, insights and/or 
contributions throughout the development of this proposal: 

- [Slava Pestov](https://github.com/slavapestov)
- [Joe Groff](https://github.com/jckarter)
