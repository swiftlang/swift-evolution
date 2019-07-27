# Identifiable Protocol

* Proposal: [SE-0261](0261-identifiable.md)
* Authors: [Matthew Johnson](https://github.com/anandabits), [Kyle Macomber](https://github.com/kylemacomber)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 5.1)**
* Implementation: [apple/swift#26022](https://github.com/apple/swift/pull/26022)
* Decision Notes: [Rationale](https://forums.swift.org/t/accepted-se-0261-identifiable-protocol/27358)

## Introduction

This proposal introduces an `Identifiable` protocol, a general concept that is broadly useful—
for diff algorithms, user interface libraries, and other generic code—to
correlate snapshots of the state of an entity in order to identify changes. It
is a fundamental notion that deserves representation in the standard library.

Swift-evolution thread: [Move SwiftUI's `Identifiable` and related types into
the standard library](https://forums.swift.org/t/move-swiftuis-identifiable-protocol-and-related-types-into-the-standard-library/25713)

## Motivation

There are many use cases for identifying distinct values as belonging to a
single logical entity. Consider a `Contact` record:

```swift
struct Contact {
    var id: Int
    var name: String
}

let john = Contact(id: 1000, name: "John Appleseed")
var johnny = john
johnny.name = "Johnny Appleseed"
```

Snapshots of a `Contact`, like `john` and `johnny`, refer to the same logical
person, even though that person may change their name over time and at any
moment, may share any number of other details with distinct persons. Being able
to determine that two such snapshots belong to the same logical entity is a
broadly useful capability.

Representing such identity as simply the `ObjectIdentifier` of a class instance
(or using `===` directly) sometimes works, but there are cases, such as when the
instances are persistent or distributed across processes, where it simply
doesn't, and even when it does work, allocating class instances to represent
identity of value types is needlessly costly.

### Diffing

User interfaces often involve collections of elements, each of which represents 
an entity. Consider a list of favorite contacts:

```swift
struct FavoriteContactList: View {
    var favorites: [Contact]

    var body: some View {
        List(favorites) { contact in
            FavoriteCell(contact)
        }
    }
}
```

In order to provide a high quality user experience when updating such a user
interface with new content it is necessary to distinguish between the identity
of the represented entity and the representation of the state of the entity that
is presented to the user. Content in an interface representing an entity whose 
state has changed but identity has not should be updated in place (rather than
resorting to removing the old content and inserting the new content).

A user interface component is capable of making such a distinction if its
represented entities are `Identifiable`:

```swift
struct List {
    init<Data: Collection, RowContent: View>(
        _ data: Data,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Data.Element: Identifiable
}
```

`Identifiable` supports diff algorithms that are able to report entity insertions,
moves and removals. These algorithms are also able to detect _changes_ to the
state of an entity that is represented in both collections. This can include
changes to the state of an entity that _also_ moves in the collection.

While diffs are often applied to the user interface layer of a program the diff 
algorithm does not necessarily need to run in the user interface layer. It can 
be desirable to compute a diff in the model layer. For example, the model layer 
updates may be processed in the background and the diff can be computed before 
moving back to the main thread to apply the changes to the UI. There may also 
be more than one simultaneous presentation of the same data in the UI, in which 
case computing the diff in the UI layer is redundant.

Model layer code that performs these computations often has no dependencies
outside the standard library itself. It is unlikely to accept a dependency on
a UI framework that defines its own `Identifiable` protocol. If `Identifiable`
doesn't move to the standard library Swift programmers 
will need to continue using their own variation of this protocol and will need
to ensure it is able co-exist with other similar definitions found in other frameworks higher 
up the dependency stack. Unfortunately none these variations 
are likey to be compatible with one another.

## Proposed solution

The proposed solution is to define a new `Identifiable` protocol:

```swift
/// A class of types whose instances hold the value of an entity with stable identity.
protocol Identifiable {

    /// A type representing the stable identity of the entity associated with `self`.
    associatedtype ID: Hashable

    /// The stable identity of the entity associated with `self`.
    var id: ID { get }
}
```

This protocol will be used by diff algorithms, user interface libraries and other
generic code to correlate snapshots of the state of an entity in order to identify
changes to that state from one snapshot to another.

An example conformance follows:

```swift
struct Contact: Identifiable {
    var id: Int
    var name: String
}
```

There are a variety of considerations (value or reference semantics, persisted,
distributed, performance, convenience, etc.) to weigh when choosing the
appropriate representation of identity for an entity. `ID` is an associatedtype
because no single concrete type of identifier is appropriate in all cases.

`id` was chosen as the name of the requirement over the unabbreviated form
because it is a [frequently used](https://www.swiftbysundell.com/posts/type-safe-identifiers-in-swift)
term of art that will allow easy conformance.

## Detailed design

### Object identifiability

In order to make it as convenient as possible to conform to `Identifiable`, a
default `id` is provided for all class instances:

```swift
extension Identifiable where Self: AnyObject {
    var id: ObjectIdentifier {
        return ObjectIdentifier(self)
    }
}
```

Then, a class whose instances are identified by their object identities need not
explicitly provide an `id`:

```swift
final class Contact: Identifiable {
    var name: String

    init(name: String) {
        self.name = name
    }
}
```

Note, a class may provide a custom implementation of `id`:

```swift
final class Contact: Identifiable {
    let id: Int
    let name: String

    init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}
```

## Source compatibility

This is a purely additive change.

## Effect on ABI stability

This is a purely additive change.

## Effect on API resilience

This has no impact on API resilience which is not already captured by other
language features.

## Alternatives considered

### Per-use identification

Instead of constraining a collection's elements to an `Identifiable` protocol,
generic code could take an additional parameter that projects the identity of an
entity from its representation:

```swift
struct FavoriteContactList: View {
    var favorites: [Contact]

    var body: some View {
        List(favorites, id: \.id) { contact in
            FavoriteCell(contact)
        }
    }
}

struct List {
    public init<Data: Collection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data, ID>,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    )
}
```

This is undesirable because a type generally has a single, canonical identity,
but this approach unnecessarily re-defines an entity's identity at every use
site, which is error-prone.

Furthermore, this isn't a practical alternative because there is evidence that
if Swift doesn't define an `Identifiable` concept, libraries will opt to define
their own rather than take an identifier at the use-site.

### Concrete conformances

The purpose of `Identifiable` is to distinguish the identity of an entity from
the state of an entity. Concrete types like `UUID`, `Int`, and `String` are
commonly _used as identifiers_, however they do not _have an identifier_, so
they should not conform to `Identifiable`.

## Future directions

### Collection diffing

Today there is a collection diffing convenience for `Equatable` elements:

```swift
extension BidirectionalCollection where Element: Equatable {
  func difference<C: BidirectionalCollection>(
    from other: C
  ) -> CollectionDifference<Element> where C.Element == Self.Element
}
```

It may be desirable to add a similar convenience for `Identifiable` elements
(and prefer use of `Identifiable` to `Equatable` when a type conforms to both).
This is omitted from the immediate proposal in order to keep it focused.

### Conditional conformances

It may be desirable to provide the conditional conformance 
`Optional: Identifiable where Wrapped: Identifiable`. This is omitted from the
immediate proposal in order to keep it focused.
