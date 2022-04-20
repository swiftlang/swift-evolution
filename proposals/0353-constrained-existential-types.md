# Constrained Existential Types

* Proposal: [SE-0353](0353-constrained-existential-types.md)
* Authors: [Robert Widmann](https://github.com/codafi)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Active review (April 20...May 3, 2022)**
* Implementation: implemented in `main` branch, under flag `-enable-parameterized-existential-types`

## Introduction

Existential types complement the Swift type system’s facilities for abstraction. Like generics, they enable a function to take and return multiple possible types. Unlike generic parameter types, existential types need not be known up front when passed as inputs to a function. Further, concrete types can be *erased* (hidden behind the interface of a protocol) when returned from a function. There has been a flurry of activity in this space with[SE-0309](https://github.com/apple/swift-evolution/blob/main/proposals/0309-unlock-existential-types-for-all-protocols.md#covariant-erasure-for-associated-types) unblocking the remaining restrictions on using protocols with associated types as existential types, and [SE-0346](https://github.com/apple/swift-evolution/blob/main/proposals/0346-light-weight-same-type-syntax.md) paving the way for a lightweight constraint syntax for the associated types of protocols. Building directly upon those ideas, this proposal seeks to re-use the syntax of lightweight associated type constraints in the context of existential types.

```
any Collection<String>
```

In essence, this proposal seeks to provide the same expressive power that [SE-0346](https://github.com/apple/swift-evolution/blob/main/proposals/0346-light-weight-same-type-syntax.md) gives to `some` types to `any` types.

Swift-evolution pitch thread: https://forums.swift.org/t/pitch-constrained-existential-types/56361

## Motivation

Though [SE-0309](https://github.com/apple/swift-evolution/blob/main/proposals/0309-unlock-existential-types-for-all-protocols.md#covariant-erasure-for-associated-types) provides the ability to use protocols with associated types freely, it does not leave any room for authors to further constrain the associated types of those protocols, creating a gap in expressiveness between generics and existentials. Consider the implementation of a type-erased stack of event producers and consumers:

```
protocol Producer {
  associatedtype Event
  
  func poll() -> Self.Event?
}

protocol Consumer {
  associatedtype Event
  
  func respond(to event: Self.Event)
}
```

If a hypothetical event system type wishes to accept an arbitrary mix of `Producer`s and an arbitrary mix of `Consumer`s, it is free to do so with existential types:

```
struct EventSystem {
  var producers: [any Producer]
  var consumers: [any Consumer]
  
  mutating func add(_ producer: any Producer) { self.producers.append(producer) }
}
```

However, we run into trouble when trying to compose producers and consumers with one another. As any given `Producer` yields data of an unspecified and unrelated `Event` type when `poll`’ed, Swift will (rightly) tell us that none of our consumers can safely accept any events. One solution would be to make `EventSystem` generic over the type of events and require `Producer` and `Consumer` instances to only return those events. As it stands, this also means restricting the producers and consumers to be concrete, with the added downside of requiring us to homogenize their types - ad-hoc type erasure strikes again:

```
struct EventSystem<Event> {
  var producers: [AnyProducer<Event>]
  var consumers: [AnyConsumer<Event>]
  
  mutating func add<P: Producer>(_ producer: P)
    where P.Event == Event
  { 
    self.producers.append(AnyProducer<Event>(erasing: producer)) 
  }
}
```

In this example, we have sacrificed quite a lot for type safety - and also have to maintain two extra type erasing wrappers for producers and consumers. Really, what is missing is the ability to express the fact that the producer and consumer types don’t matter (existential types) but the data they operate on *does* (generic constraints). This is where constrained existential types shine. When combined with the power of primary associated types from [SE-0346](https://github.com/apple/swift-evolution/blob/main/proposals/0346-light-weight-same-type-syntax.md), it allows us to write the code we wanted to in the first place:

```
struct EventSystem<Event> {
  var producers: [any Producer<Event>]
  var consumers: [any Consumer<Event>]
  
  mutating func add(_ producer: any Producer<Event>) { 
    self.producers.append(producer) 
  }
}
```

## Proposed solution

Existential types will be augmented with the ability to specify constraints on their primary associated types. When an existential type appears with such constraints, they will be converted into same-type requirements.

```
protocol P<T, U, V> { }

var xs: [any P<B, N, J>] // "Equivalent" to [any P] where P.T == B, P.U == N, P.V == J
```

## Detailed design

The syntax of existential types will be updated to accept constraint clauses. Type inference procedures will be updated to apply inference rules to generic parameters appearing as part of parameterized existential types.

The Swift type system and runtime will accept casts from parameterized existential types to non-parameterized existential types and vice versa, as well as casts that refine any constrained primary associated types. Upcasts and downcasts to, from, and between existential types will be updated to take these additional constraints into account:

```
var x: any Sequence<T>
_ = x as any Sequence // trivially true
_ = x as! any Sequence<String> // requires examining Sequence.Element at runtime
```

### Equality of constrained protocol types

The language must define when two types that are derived differently in code are in fact the same type. In principle, it would make sense to say that two constrained protocol types are the same if and only if they have exactly the same set of possible conforming types. Unfortunately, this rule is impractical in Swift’s type system for complex technical reasons. This means that some constrained protocol types which are logically equivalent to each other will be considered different types in Swift.

The exact rule is still being determined, but for example, it is possible that the type `any P & Q<Int>` might be considered different from the type `any P<Int> & Q` even if the associated types of these protocols are known to be equal. Because these types have equivalent logical content, however, there will be an implicit conversion between them in both directions. As a result, this is not expected to pose a large practical difficulty.

Substitutions of constrained protocol types written with the same basic “shape”, such as `any P<Int>`and `any P<T>` in a generic context where `T == Int`, will always be the same type.

### Variance

One primary use-case for constrained existential types is their the Swift Standard Library’s Collection types. The Standard Library’s *concrete* collection types have built-in support for covariant coercions. For example, 

```
func up(from values: [NSView]) -> [Any] { return values }
```

At first blush, it would seem like constrained existential types should support variance as well:

```
func up(from values: any Collection<NSView>) -> any Collection<Any> { return values }
```

But this turns out to be quite a technical feat. There is a naive implementation of this coercion that recasts the input collection as an `Array` of the appropriate type, but this would be deeply surprising and would bake the fact that `Array` is always returned into the ABI of the standard library forever.

Constrained existential types will behave as normal generic types with respect to variance - that is, they are *invariant -* and the code above will be rejected.

## Effect on ABI stability

As constrained existential types are an entirely additive concept, there is no impact upon ABI stability.

It is worth noting that this feature requires revisions to the Swift runtime and ABI that are not backwards-compatible nor backwards-deployable to existing OS releases.

## Alternatives considered

Aside from the obvious of not accepting this proposal, we could imagine many different kinds of spellings to introduce same-type requirements on associated types. For example, a where-clause based approach as in:

```
any (Collection where Self.Element == Int)
```

Syntax like this is hard to read and use in context and the problem becomes worse as it is made to compose with other existential types and constraints. Further it would conflict with the overall direction that generic constraints in Swift are taking as of [SE-0346](https://github.com/apple/swift-evolution/blob/main/proposals/0346-light-weight-same-type-syntax.md). Generalized constraint syntaxes are out of scope for this proposal and are mentioned later as future directions. 

## Future directions

#### Generalized Constraints

This proposal intentionally does not take a position on the generalized constraint syntax considered during the review of [SE-0341](https://github.com/apple/swift-evolution/blob/main/proposals/0341-opaque-parameters.md#constraining-the-associated-types-of-a-protocol). To take one spelling:

```
any Collection<.Index == String.Index>
```

Though when and if such a syntax is available we expect it to apply to constrained existential types. Possible designs for generalized constraints on existential types are discussed in https://forums.swift.org/t/generalized-opaque-and-existential-type-constraints/55494.

#### Opaque Constraints

One particularly interesting construction is the composition of opaque types and constrained existential types. This combo allows for a particularly powerful form of type abstraction:

```
any Collection<some View>
```

This type describes any value that implements the `Collection` protocol but whose element type is an opaque instance of the `View` protocol. Today, Swift’s generics system lacks the ability to express same-type constraints with opaque types as an operand.

#### Even More Generalized Existentials

Constraints on existing primary associated types are hardly the only thing existential types can express. Swift’s type system can be given the ability to open arbitrary (constrained) type parameters into scope via an existential. This enables not just top-level usages as in

```
any<T: View> Collection<T>
```

But also nested usages as in

```
any Collection<any<T: Hashable> Collection<T>>
```

Essentially enabling ad-hoc abstraction over generic types of *any shape* at any point in the program.
