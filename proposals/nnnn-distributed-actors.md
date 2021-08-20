# Distributed Actors

* Proposal: [SE-NNNN](NNNN-distributed-actors.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Dario Rexin](https://github.com/drexin), [Doug Gregor](https://github.com/DougGregor), [Tomer Doron](https://github.com/tomerd), [Kavon Farvardin](https://github.com/kavon)
* Review Manager: TBD
* Status: **Implementation in progress**
* Implementation: 
  * Partially available in [recent `main` toolchain snapshots](https://swift.org/download/#snapshots) behind the `-enable-experimental-distributed` feature flag. 
  * This flag also implicitly enables `-enable-experimental-concurrency`.

## Table of Contents

<!--ts-->
* [Distributed Actors](#distributed-actors)
   * [Table of Contents](#table-of-contents)
   * [Introduction](#introduction)
   * [Motivation](#motivation)
   * [Proposed solution](#proposed-solution)
      * [Distributed actors](#distributed-actors-1)
      * [Distributed functions](#distributed-functions)
      * [Distributed actor transports](#distributed-actor-transports)
      * [Fundamental principle: Location Transparency](#fundamental-principle-location-transparency)
   * [Detailed design](#detailed-design)
      * [Distributed Actors](#distributed-actors-2)
         * [The DistributedActor protocol](#the-distributedactor-protocol)
            * [DistributedActor is not an Actor](#distributedactor-is-not-an-actor)
            * [Optional: The AnyActor marker protocol](#optional-the-anyactor-marker-protocol)
         * [Progressive Disclosure towards Distributed Actors](#progressive-disclosure-towards-distributed-actors)
      * [Distributed Actor initialization](#distributed-actor-initialization)
         * [Local initializers](#local-initializers)
         * [Resolve function](#resolve-function)
      * [Distributed Functions](#distributed-functions-1)
         * [distributed func declarations](#distributed-func-declarations)
         * [Distributed function parameters and return values](#distributed-function-parameters-and-return-values)
         * [Distributed functions are implicitly async throws when called cross-actor](#distributed-functions-are-implicitly-async-throws-when-called-cross-actor)
      * [Distributed Actor Isolation](#distributed-actor-isolation)
         * [Only distributed or nonisolated members may be accessed on distributed actors](#only-distributed-or-nonisolated-members-may-be-accessed-on-distributed-actors)
         * [No permissive special case for accessing constant let properties](#no-permissive-special-case-for-accessing-constant-let-properties)
         * [Distributed functions and protocol conformances](#distributed-functions-and-protocol-conformances)
         * [nonisolated members](#nonisolated-members)
      * [Actor Transports](#actor-transports)
         * [Transporting Errors](#transporting-errors)
      * [Actor Identity](#actor-identity)
         * [Distributed Actors are Identifiable](#distributed-actors-are-identifiable)
         * [Distributed Actors are Equatable and Hashable](#distributed-actors-are-equatable-and-hashable)
         * [Distributed Actors are Codable](#distributed-actors-are-codable)
      * ["Known to be local" distributed actors](#known-to-be-local-distributed-actors)
   * [Runtime implementation details](#runtime-implementation-details)
         * [Remote distributed actor instance allocation](#remote-distributed-actor-instance-allocation)
         * [distributed func internals](#distributed-func-internals)
   * [Future Directions](#future-directions)
      * [Resolving DistributedActor bound protocols](#resolving-distributedactor-bound-protocols)
      * [Synthesis of _remote and well-defined Envelope&lt;Message&gt; functions](#synthesis-of-_remote-and-well-defined-envelopemessage-functions)
      * [Support for AsyncSequence](#support-for-asyncsequence)
      * [Ability to hardcode actors to specific shared transport](#ability-to-hardcode-actors-to-specific-shared-transport)
      * [Actor Supervision](#actor-supervision)
   * [Related Work](#related-work)
      * [Swift Distributed Tracing integration](#swift-distributed-tracing-integration)
      * [Distributed Deadline propagation](#distributed-deadline-propagation)
      * [Potential Transport Candidates](#potential-transport-candidates)
   * [Related Proposals](#related-proposals)
   * [Alternatives Considered](#alternatives-considered)
      * [TODO: all the internal representations of remote/local](#todo-all-the-internal-representations-of-remotelocal)
      * [Discussion: Why Distributed Actors are better than "just" some RPC library?](#discussion-why-distributed-actors-are-better-than-just-some-rpc-library)
      * [Special Actor spawning APIs](#special-actor-spawning-apis)
         * [Explicit spawn(transport) keyword-based API](#explicit-spawntransport-keyword-based-api)
         * [Global eagerly initialized transport](#global-eagerly-initialized-transport)
         * [Directly adopt Akka-style Actors References ActorRef&lt;Message&gt;](#directly-adopt-akka-style-actors-references-actorrefmessage)
   * [Acknowledgments &amp; Prior Art](#acknowledgments--prior-art)
   * [Source compatibility](#source-compatibility)
   * [Effect on ABI stability](#effect-on-abi-stability)
   * [Effect on API resilience](#effect-on-api-resilience)

<!-- Added by: ktoso, at: Wed Jul 21 00:16:35 JST 2021 -->

<!--te-->


## Introduction

Thanks to the recent introduction of [actors](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md) in Swift 5.5, developers gained the ability to express their concurrent programs in a new and natural way. 

Actors are a fantastic, foundational, building block for highly concurrent and scalable systems. Actors enable developers to focus on their problem domain, rather than having to micro-manage every single function call with regard to its thread-safety. State isolated by actors can only be interacted with "through" the enclosing actor, which ensures proper synchronization. This also means that such isolated state, may not actually be locally available, and as far as the caller of such function is concerned, there is not much difference "where" the computation takes place.

This is one of the core strengths of the [actor model](https://en.wikipedia.org/wiki/Actor_model): it applies equally well to concurrent and distributed systems. 

This proposal introduces *distributed actors*, which allow developers to take full advantage of the general actor model of computation. Distributed actors allow developers to scale their actor systems beyond single node/device systems, without having to learn many new concepts, but rather, naturally extending what they already know about actors to the distributed setting.

Distributed actors introduce the necessary type system guardrails, as well as runtime hooks along with an extensible transport mechanism. This proposal focuses on the language integration pieces, and explains where a transport library author would interact with such a system to build a fully capable distributed actor runtime. The proposal does not go in depth about transport internals and design considerations, other than those required by the model.

**TODO: Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)**

After reading the proposal, we also recommend having a look at the [Related Proposals](#related-proposals), which may be useful to understand the big picture and how multiple Swift evolution proposals and libraries come together to support this proposal.


## Motivation

Most of the systems we write nowadays, whether we want it or not, are distributed.


For example:
- They might have multiple processes with the parent process using some IPC (inter-process communication) mechanism. 
- They might be part of a single (clustered) service, or a multi-service backend system that uses various networking technologies for communication between the nodes. 
- They might be composed of a client and server side applications, where the client needs to constantly interact with the server component to keep the application up to date. The same may apply to interactive, networked applications, such as games, chat or media applications.

These use cases all vary significantly and have very different underlying transports and mechanisms that enable them. Their implementations are also tremendously different. However, the general concept of wanting to communicate with non-local _identifiable_ entities is common in all of them. 

Distributed actors provide a general abstraction that extends the notion of an identifiable actor beyond the scope of a single process. By abstracting away the communication transport from the conceptual patterns associated with distributed actors, they enable application code to focus on their business, while providing a common and elegant pattern to solving the networking issues such applications would have solved in an ad-hoc manner otherwise.

This proposal _does not_ define any specific runtime. It is designed in such a way that various, first and third-party, transport implementations may be offered and co-exist even in the same process if necessary (e.g. utilizing some distributed actors for cross-process communication, while utilizing others to communicate with a server backend).

## Proposed solution

### Distributed actors

This proposal introduces the `distributed` contextual keyword, which may be used in conjunction with actor definitions (`distributed actor`), as well as `distributed func` declarations within such actors.

Distributed actors are very similar to their local counterparts. They provide the same state isolation guarantees as local actors with some additional restrictions. E.g. synchronous access to a remote property would not make sense. This means that everything that is true about an `actor` in general is also true for distributed actors.

When adding the `distributed` modifier to an existing `actor` the first thing we notice is that a distributed actor has stronger isolation requirements than plain local actors. Specifically, it is not possible to invoke plain (async or not) functions on the distributed actor anymore, and we'll need to mark functions that are accessible on the distributed actor as `distributed func`.

For example, we could implement a `Player` actor (similar to player objects as seen in the [SwiftShot](https://developer.apple.com/documentation/arkit/swiftshot_creating_a_game_for_augmented_reality) WWDC18 sample app), like this:

```swift
distributed actor Player {
  let name: String
  var score: Int
}
```

So far this behaves the same as a local-only actor, we cannot access `score` directly because the properties are "actor isolated". This is the same as with local-only actors where mutable state is isolated by the actor. Distributed actors however must also isolate immutable state, because the state itself may not even exist locally. Therefore, accessing `name` is also illegal on a distributed actor type, and would fail at compile time as shown below:

```swift
let player: Player
player.score // error: distributed actor-isolated property 'score' can only be referenced inside the distributed actor
player.name // error: distributed actor-isolated property 'name' can only be referenced inside the distributed actor
```

It is illegal to declare `nonisolated` _stored_ properties on distributed actors. The exact semantics of `nonisolated` will be discussed later on.

It is allowed to declare `static` properties and functions on distributed actors and–as they are completely outside of the distributed actor instance–they are legal to access from any context. They always refer to the local processes value of the static property or function. Usually these can be used for constants useful for the distributed actor itself, or users of it, e.g. like names or other identifiers.

```swift
distributed actor Player { 
  static let namePrefix = "PLAYER"
  static func makeName(name: String) -> String { 
    return "\(Player.namePrefix):\(name)"
  }
}

Player.namePrefix // ok
Player.makeName("Alice") // ok
```



### Distributed functions

A distributed function is declared by prefixing the `func` keyword with the `distributed` contextual keyword, like this:

```swift
distributed actor Worker { 
  
  distributed func work() {
     // ... 
  }

}
```

Distributed functions are the only type of function or property that is "cross-actor" (see [cross-actor references and Sendable types](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md#cross-actor-references-and-sendable-types) in the actors proposal) callable on a distributed actor type.

A distributed function can only be declared in the context of a distributed actor. Attempts to define a distributed function outside of a distributed actor will result in a compile time error:

```swift
struct SomeNotActorStruct {
  distributed func nope() async throws -> Int { 42 } 
  // error: 'distributed' function can only be declared within 'distributed actor'
  // fixit: replace 'struct' with 'distributed actor'
  // fixit: remove 'distributed' from 'distributed func'
}
```

Distributed functions can be declared synchronous, asynchronous, and/or throwing. When called cross-actor (i.e. "from the outside of the actor they are declared in"), they are *implicitly* asynchronous *and* throwing. This follows precendent from the actor proposal, in which synchronous functions inside actors, when called cross-actor, are implicitly asynchronous. The distributed nature of distributed functions however, also implies that any such call may fail, and therefore must be assumed to be throwing when called cross-actor:

```swift
distributed actor Worker { 
  distributed func work() -> Results { ... }
  
  func inside() {
    self.work() // calls inside the actor are always fine, and no implicit effects are added
  }
}

func outside(worker: Worker) {
  worker.inside() // error: cannot invoke non-distribured function 'inside()' on distributed actor 'Worker'
  worker.work() // error: function is throwing and async
  // fixit: insert `try await` before worker.work()
  
  let results = try await worker.work() // ok
}
```

Errors thrown _by_ the underlying transport should conform to the `ActorTransportError`. A transport may also attempt to transport an error from the remote side, to the local caller of a distributed function if it is able to do so - transporting such errors "back" callers of remote actors will be discussed in depth in [Transporting Errors](#transporting-errors).

It is not allowed to declare `static` `distributed` functions, because static functions are not isolated to any actor actor and therefore such can never be remote:

```swift
distributed actor Worker { 
  static distributed func illegal() {} 
  // error: 'distributed' functions cannot be 'static'
}
```

### Distributed actor transports

Distributed actors and functions are largely a type system and compiler feature, providing the necessary isolation and guardrails for such distributed actor to be correct and safe to use. In order for such an actor to actually perform any remote communication, it is necessary to provide an actual runtime piece that will handle the networking such actor is intended to perform. This is done by providing any distributed actor with a specific instance of an `ActorTransport`.

While distributed actors, on purpose, abstract away the "how" of their underlying messaging runtime, the actor transport is where the implementation must be defined. A transport must be provided to every distributed actor instantiation. 

Unlike local-only actors, a distributed actor does not have an parameterless initializer, and must be initialized using the `init(transport:)` synthesized initializer instead. 

```swift
distributed actor Worker {}

Worker() 
// error: missing argument for parameter 'transport' in call
// note: 'init(transport:)' declared here
//     internal init(transport: ActorTransport)
//              ^

let transport = SomeActorTransport()
let worker = Worker(transport: transport)
```

Alternatively, any user-defined initializer may be invoked, however any such initializer must delegate to the local initializer, and provide it some transport that the actor should be used with.

```swift
distributed actor Worker { 
  let name: String
  init(name: String, transport: ActorTransport) {
    self.init(transport: transport)
    self.name = name
  }
}
```

An actor transport can take advantage of any networking, cross process, or even in-memory approach it wants to, as long as it implements the protocol correctly. Transports may offer varying amounts of message send reliability, or other guarantees, and it is important that while we focus on the ability for actors to use any transport, it is not wrong for an application to be aware of what transports it will be used with, and e.g. attempt to limit message sizes to small messages in case the underlying transport has some inherent limitations around those.

End users of transports interact with them frequently, but not very deeply, as a transport must be passed to any instantiation of a distributed actor. Following that however, all other messaging interactions are done transparently by various hooks in the runtime. 

A typical distributed actor creation therefore can look like this:

```swift
let transport: ActorTransport = // WebSocketActorTransport(...)
                                // ClusterActorTransport(...)
                                // InterProcessActorTransport(...)

// create local instance, on given transport:
let local: Greeter = Greeter(transport: transport)
let greeting: String = try await local.greet(name: "Alice")
```

The second way of creating distributed actors is by resolving a potentially remote identity, this is done using the `resolve(id:using:)` function:

```swift
// resolve remote instance, using provided transport:
let maybeRemoteID: AnyActorIdentity = ...
let greeter: Greeter = try Greeter.resolve(id: maybeRemoteID, using: transport)
let greeting: String = try await greeter.greet(name: "Alice")
```

The returned greeter may be a remote or local instance, depending on what the passed in identity was pointing at. Resolving a local instance is how incoming messages are delivered to specific actors, the transport preforms a lookup using a freshly deserialized identity, and if an actor is located, delivers messages (function invocations) to it.

All distributed actors have the implicit nonisolated `transport` and `id` property, which is initialized by the local initializer or resolve function automatically:

```swift
worker.transport // ok; synthesized, nonisolated property
worker.id // ok; synthesized, nonisolated property
```

### Fundamental principle: Location Transparency

To fully understand and embrace the design of distributed actors it is useful to first discuss the concept of [location transparency](https://en.wikipedia.org/wiki/Location_transparency#:~:text=In%20computer%20networks%2C%20location%20transparency,their%20actual%20location.), as it is the foundational principle this design is built upon. This technique is usually explained as follows:

> In computer networks, location transparency is the use of *names* to identify network resources, rather than their *actual location*.

In our context, this means that distributed actors are uniquely identifiable in the network/system/cluster by their `ActorIdentity` which is assigned and managed by a specific `ActorTransport`. This identifier is sufficient to uniquely identify and locate the specific actor in the system, regardless of its location.

This, in combination with the principle that it is generally not possible to statically determine if a distributed actor is local or remote, allows us to fully embrace location transparency in the programming model. Developers should focus on getting their actor interactions correct, without focusing too much on _where exactly_ the actor is running. Static isolation checking rules in the model enforce this, and help developers not to violate this principle. 

> We offer _dynamic_ ways to check and peek into a local actor if it is _known to be local_, and we'll discuss this entry point in detail in ["Known to be local" distributed actors](#known-to-be-local-distributed-actors), however their use should be rare and limited to special use-cases such as testing.

When an actor is declared using the `distributed` keyword (`distributed actor Greeter {}`), it is referred to as a "distributed actor". At runtime, references to distributed actors can be either "local" or "remote":

- **local** `distributed actor` references
  - which are semantically the same as non-distributed `actor`s at runtime.
- **remote** `distributed actor` references
  - which can be thought of as "proxy" objects, which merely point at a remote actor, identified by their `.id`. Such objects do not have any storage allocated for the actor declarations stored properties. Distributed functions on such instances are implemented by serializing and sending asynchronous messages over the underlying transport.

In other words, given the following snippet of code, we never know if the `greeter` passed to the `greet(who:)` function is local or remote. We merely operate on the information that it is a _distributed actor_, and therefore _may_ be remote:

```swift
distributed actor Greeter {
  distributed func hello() async throws
}

func greet(who greeter: Greeter) { // maybe remote, maybe local -- we don't care
  try await greeter.hello()
}
```

It is not _statically_ possible to determine if the actor is local or remote. This is hugely beneficial, as it allows us to write code independent of the location of the actors. We can write a complex distributed systems algorithm and test it locally. Deploying it to a cluster is merely a configuration and deployment change, without any additional code changes.

*Location Transparency* enables distributed actors to be used across various transports without changing code using them, be balanced between nodes once capacity of a cluster changes, be passivated when not in use and many more advanced patterns such as "virtual actor" style systems as popularized by Orleans and Akka's cluster sharding.

## Detailed design

### Distributed Actors

Distributed actors are declared using the `distributed actor` keywords, similar to local-only actors which are declared using only the `actor` keyword.

Similar to local-only actors which automatically conform to the `Actor` protocol, a type declared as `distributed actor` implicitly conforms to the `DistributedActor` protocol. The distributed modifier cannot be applied to any other type declaration other than `actor`, doing so results in a compile-time error:

```swift
distributed class ClassNope {} // error: 'distributed' can only be applied to 'actor' definitions
distributed struct StructNope {} // error: 'distributed' modifier cannot be applied to this declaration
distributed enum EnumNope {} // error: 'distributed' modifier cannot be applied to this declaration
```

A `distributed actor` type, extensions of it, and `DistributedActor` bound protocols are the only places where `distributed func` declarations are allowed. This is because in order to implement a distributed function, a transport and identity are necessary.

It is possible for a distributed actor to have non-distributed functions as well. They are callable only from two contexts: the actor itself (by `self.nonDistributedFunction()`), and from within an `maybeRemoteActor.whenLocalActor { await $0.nonDistributedFunction() }` which will be discussed in ["Known to be local" distributed actors](#known-to-be-local-distributed-actors), although the need for this should be relatively rare.

It is not allowed to define global actors which are distributed actors. If enough use-cases for this exist, we may loosen up this restriction, however generally this is not seen as a strong use-case, and it is possible to add this capability in a source and binary compatible way in the future if necessary.

#### The `DistributedActor` protocol

Similar to how any `actor` type automatically conforms to the `Actor` protocol, and any other kinds of types are banned from manually conforming to the `Actor` protocol, any `distributed actor` automatically conforms to the `DistributedActor` protocol.

The `DistributedActor` bears similarity to the `Actor` protocol and is defined as: 

```swift
public protocol DistributedActor: AnyActor, Sendable, Codable, Identifiable {

  // << Discussed in detail in "Resolve function" >>
  static func resolve<Identity>(id identity: Identity, using transport: ActorTransport) 
    throws -> Self
    where Identity: ActorIdentity

  // << Discussed in detail in "Actor Transports" >>
  var transport: ActorTransport { get }

  // << Discussed in detail in "Actor Identity" >> 
  var id: AnyActorIdentity { get }
}
```

It is not possible to declare any other type (struct, actor, class, ...) and make it conform to the `DistributedActor` protocol manually, for the same reasons as doing so is illegal for the `Actor` protocol: such a type would be missing additional type-checking restrictions and synthesized pieces which are necessary for distributed actors to function properly.

```swift
actor ActorNope: DistributedActor {
  // error: non-distributed actor type 'ActorNope' cannot conform to the 'DistributedActor' protocol
  // fixit: insert 'distributed' before 'actor'
}

class ClassNope: DistributedActor {
  // error: non-actor type 'ClassNope' cannot conform to the 'Actor' protocol
  // fixit: replace 'class' with 'distributed actor'
}
// (similarly for enums and structs)
```

The `DistributedActor` protocol includes a few more conformances which will be covered in depth in their own dedicated sections, as we discuss the importance of the [actor identity](#actor-identity) property.

The two property requirements (`transport` and `id`) are automatically implemented by the compiler. They are derived from specific calls to the underlying transport during the actor's initialization. They are immutable and will never change during the lifetime of the specific actor instance. Equality as well as messaging internals rely on this guarantee.


##### `DistributedActor` is not an `Actor`

It is crucial for correctness that neither `Actor` implies `DistributedActor`, nor the other way around. Such relationship would cause soundness issues in the model, e.g. like this:

```swift
// NOT PROPOSED; Illustrates a soundness issue if `DistributedActor: Actor` was proposed
//
// Assume that:
protocol DistributedActor: Actor { ... } // NOT proposed

extension Actor {
  func f() -> SomethingSendable { ... }
}
// and then...
func g<A: Actor>(a: A) async {
  print(await a.f())
}
// and then...
distributed actor MA {
}
func h(ma: MA) async {
  await g(ma) // BUG! allowed because a distributed actor is an Actor, but can't actually work at runtime
}
```

The core of the issue illustrated above stems from the incompatibility of the types semantics of "definitely local" vs. "maybe local, maybe remote". The semantics of a distributed actor to carry this "*maybe*" are crucial for building systems using distributed actors, and are not something we want to sacrifice (it is the foundation of location transparency), as such the two types are incompatible and converting between them seemingly with a sub-typing relationship would cause bugs and crashes at runtime.

This is not an issue though, rarely would one want to transparently convert "any (existential) Actor" to some other "any (existential DistributedActor". In reality, programs are developed in terms of specific protocols of concrete types.

The proposal addresses this simply by acknowledging that `DistributedActor` does _not_ inherit from `Actor`, and we believe this is in practice a very much workable model.

##### Optional: The `AnyActor` marker protocol

We could introduce a lightweight `@_marker protocol AnyActor` which is inherited by both `Actor` and `DistributedActor`. 

```swift
@_marker protocol AnyActor {} 
protocol Actor: AnyActor {} 
protocol DistributedActor: AnyActor {}
```

Marker protocols cannot be inspected at runtime, and cannot be extended. As such, this protocol does not have much to offer in terms of practical reasons, i.e. we would not be able to write extensions of it. But even if we could, such extensions could not really be very useful, as such protocol does not really have any meaningful state or functions it could offer. However, it might be useful to express type requirements where we'd like to express the requirement that a type be implemented using any actor type, such as:

```swift
protocol Scientist { 
  func research() async throws -> Publication
}

func <S: AnyActor & Scientist>researchAny(scientist: S) async throws -> Publication {
  try await scientist.research()
}
```

> **Note:** Indeed, the utility of this marker protocol is rather limited... however we feel it would be nice, and relatively cost-free to introduce this type as a _marker_ protocol because of the zero runtime overhead of it, and the added logical binding of actors in a common type hierarchy. 
>
> The authors of the proposal could be convinced either way about this type though, and we welcome feedback from the community about it.

#### Progressive Disclosure towards Distributed Actors

The introduction of `distributed actor` is purely incremental, and does not imply any changes to the local programming model as defined by `actor`. However, once developers understand "share nothing" and "all communications are done through asynchronous functions (messages)", it is relatively simple to map the same understanding onto the distributed setting. Naturally, a distributed system carries many inherent complexities with it (e.g. message delivery reliability), but the general way of thinking about it in terms of actors remains the same, which we believe is a crucial and valuable aspect of the design and has been proven by other distributed actor implementations in other languages.

None of the distributed systems aspects of distributed actors leak through to local-only actors. Developers who do not wish to use distributed actors may simply ignore them.

Developers who first encounter `distributed actor` in some API beyond their control can more easily learn about it if they have already seen actors in other parts of their programs, since the same mental model applies to distributed as well as local-only actors. The big difference is the inclusion of serialization and networking. A good first intuition is that such calls will be "slow" as they are going to be performed over the network -- this is no different from having _some_ asynchronous functions performing "very heavy" work (like sending HTTP requests by calling `httpClient.post(<file upload>)`) while some other asynchronous functions are relatively fast--developers always need to reason about _what_ a function does in any case to understand performance characteristics.

Swift's distributed actors help because we can explicitly mark such network interaction heavy objects as `distributed actor`s, and therefore we know that distributed functions are going to use e.g. networking, so invoking them repeatedly in loops may not be the best idea. This is also the reason we are not interested in exposing distributed properties, because it would encourage distributed anti-patterns where the operations end up way too fine-grained and multi-call, rather than collapsing them into larger functions which perform a given request atomically. 

Thanks to distributed actors and functions being expressed in the type system, it is also relatively simple for IDEs to e.g. highlight distributed actor functions, helping developers understand where exactly networking costs are to be expected. This is an improvement over today's world, where any function could technically perform network calls, and we are not able to easily notice it and may cause silly `N+1` operation mistakes by putting heavy network calls in the middle of a tight loop.

### Distributed Actor initialization

#### Local initializers

All user-defined designated initializers are collectively referred to as "local" initializers. This is just a simple way to remember that any user-defined initializer will create a _local_ instance of an actor. 

All designated initializers of a distributed actor must accept exactly one `ActorTransport` parameter. 

This `ActorTransport` parameter is implicitly used to fulfil an important contract with the transport and the actor itself: it first must be assigned an `ActorIdentity` and once fully initialized it must inform the transport that it is ready to receive messages by calling `transport.actorReady(self)`.

This also means that, unlike other actors, the default no-argument `init()` initializer is _not_ synthesized for distributed actors. Instead, a default `init(transport:)` is initialized in its place:

```swift
distributed actor Blank { 
  // This Distributed Actor Is Intentionally Left Blank
}

Dog() // error: missing argument for parameter 'transport' in call
Dog(transport: Cluster(...))
```

It is legal to declare any other designated initializers, or even the `init(transport:)` initializer, as long as they accept exactly one transport parameter:

```swift
distributed actor Capybara { 
  init(transport: ActorTransport) { ... } // ok 
}

distributed actor Fish {
  let name: String
  init(name: String, transport: ActorTransport) { ... } // ok
  convenience init() { self.init(transport: GlobalTransport()) } // ok 
  
  // --- bad declarations ---
  init(transport: Int) {...} // error: 'transport: Int' must conform to ActorTransport
  init(name: String) {...} // error: missing 'ActorTransport' parameter
  init(which one: ActorTransport, 
       is   real: ActorTransport) {} // error: distributed actor designated initializer must accept exactly one 'ActorTransport' parameter
  convenience init() {} // error: must delegate to designated initializer
  
}
```

When declaring the `init(transport:)` explicitly, the type of `transport` must conform to `ActorTransport`.

The synthesized code injected into local initializers can be thought of like this:

```swift
init(..., transport: ActorTransport) {
  // ~~~ syntiesized ~~~
  self._transport = transport
  self._id = AnyActorIdentity(transport.assignIdentity(Self.self))
  // === end of synthesized ===
  
  // ... user-code
  self.name = name // etc.
  
  // ~~~ end of synthesized ~~~
  transport.actorReady(self)
  // === end of synthesized ===
}
```

The transport and identity properties are initialized by the implicitly synthesized code, and once the actor is state is fully initialized, the self reference is offered to the transport, allowing it to store the reference for future resolve lookups.

Thanks to the guarantee that the `init(transport:)` will _always_ be called when creating a distributed actor instance and the only other method of distributed actor initialization also ensures those properties are initialized properly, we are able to offer the `transport` and `id` properties as `nonisolated` members of any distributed actor. This is important, because those properties enable us to implement certain crucial protocol requirements using nonisolated functions, as we'll discuss in [Distributed functions and protocol conformances](#distributed-functions-and-protocol-conformances).

#### Resolve function

So far, we have not seen a way to create a _remote_ distributed actor reference. This is handled by a special `resolve(id:using:)` function is synthesized for distributed actors. It is not manually implementable, and invokes internal runtime functionality for allocating "proxy" actors which is not possible to achieve in any other way.

The resolve function is declared as `func resolve<Act>(_ identity: Act.ID, as actorType: Act.Type) throws -> ActorResolved<Act>`, and in simplified terms can be imagined as being implemented as follows:

```swift
distributed actor Greeter {  
  /* ~~~ synthesized ~~~ */
  static func resolve(_ identity: ActorIdentity, using transport: ActorTransport) throws -> Self {
    switch try await transport.resolve(identity, as: Self.self) {
    case .instance(let instance):
      return instance
    case .proxy:
      return __runtimeMagicToAllocateProxyActor(...)
    }
  }
  /* === synthesized === */
}
```

The result of a resolve call can be an existing actor reference, e.g. if the resolved identity points to a local actor known to the transport the resolve was performed with. Or it may return a fresh remote actor instance, which effectively is just an empty shell of an actor storing the `identifier` and `transport` directing all calls as messages to the underlying transport for further processing and e.g. sending over the wire.

A resolve may also throw if the transport decides that it cannot resolve the passed in identity. A common example of a transport throwing in a `resolve` call would be if the `identity` is for some protocol `unknown://...` while the transport only can resolve `known://...` actor identities.

The resolve initializer and related resolve function on the `ActorTransport` are _not_ `async` because they must be able to be invoked from decoding values, and the `Codable` infrastructure is not async-ready just yet. Also, for most use-cases they need not be asynchronous as the resolve is usually implemented well enough using local knowledge. In the future we might want to introduce an asynchronous variant of resolving actors which would simplify implementing transports as actors themselves, as well as enable more complicated resolve processes.

A transport may decide to return a "dead letters" reference, which is a pattern in where instead of throwing, we return a reference that will log all incoming calls as so-called dead letters, meaning that we know that those messages will never arrive at their designated recipient. This concept is can be useful in debugging actor lifecycles, where we accidentally didn't keep the actor alive as long as we hoped etc. It is up to each specific transport to document and implement either behavior.

A resolve initializer may transparently create an instance if it decides it is the right thing to do. This is how concepts like "virtual actors" may be implemented: we never actively create an actor instance, but its creation and lifecycle is managed for us by some server-side component with which the transport communicates. Virtual actors and their specific semantics are outside of the scope of this proposal, but remain an important potential future direction of these APIs.

### Distributed Functions

#### `distributed func` declarations

Distributed functions are a type of function which can be only defined inside a distributed actor, and any attempt of defining one outside of a `distributed actor` (or an extension of such) is a compile-time error:

```swift
distributed actor DA {
  distributed func greet() -> String { ... } // ok
}

extension DA {
  distributed func hola() -> String { ... } // ok
}

struct/class/enum/actor NotDistActor {
  distributed func nope() -> Int { ... } 
  // error: 'distributed' function can only be declared within 'distributed actor'
}

protocol Greeter: DistributedActor { 
  distributed func henlo() -> String // ok!
}
```

Distributed functions must be marked explicitly for a number of reasons, thought primarily thopse resolve around the fact that type-checking rules (see  [Distributed Actor Isolation](#distributed-actor-isolation)) and code synthesis (see [`distributed func` internals](#distributed-func-internals). IDEs also benefit from the ability to understand that a specific function is distributed, and may want to color them differently or otherwise indicate that such function may have higher latency and should be used with care.

Similar to normal functions defined on actors, a distributed function has an implicitly `isolated` self parameter, meaning that they are able to refer to all internal state of an actor. Calling a distributed function on a local actor works effectively the same as calling any actor function on a local-only actor, meaning that if necessary an actor-hop will be emitted.

#### Distributed function parameters and return values

In addition to the usual `Sendable` parameter and return type requirements of actor functions, distributed actor functions also require their parameters and return values to conform to `Codable`. This is because any call of a distributed function may potentially need to be serialized, and `Codable` is our mechanism of doing so. 

Our greeter example naturally fulfills these requirements, because it only used primitive types which already conform to `Codable`, such as `String` and `Int`:

```swift
distributed actor Greeter { 
  distributed func greet(
    name: String, // ok: String is Codable
    age: Int      // ok: Int is Codable
  ) -> String {   // ok: String is Codable
    "Hello, \(name)! Seems you're \(age) years old."
  }
}
```

If we were to try to return a non-`Codable` type, such as a `Greeting` struct we just created, we would get a compiler error informing us that the `Greeting` type must be made to conform to `Codable` as well:

```swift
struct Greeting { ... }

distributed actor Greeter {
  distributed func greet(name: String) -> Greeting { ... }
  // error: distributed function result type 'NotCodableValue' does not conform to 'Codable'
  // fixit: add 'Codable' conformance to 'Greeting'
  
  distributed func receive(_ greeting: Greeting) { ... }
  // error: distributed function parameter 'notCodable' of type 'NotCodableValue' does not conform to 'Codable'
  // fixit: add 'Codable' conformance to 'Greeting'
}
```

Once we make `Greeting` codable both those functions would compile and work fine.

The specific encoder/decoder choice is left up to the specific transport that the actor was created with. It is legal for a distributed actor transport to impose certain limitations, e.g. on message size or other arbitrary runtime checks when forming and sending remote messages. Distributed actor users may need to consult the documentation of such transport to understand those limitations. It is a non-goal to abstract away such limitations in the language model. There always will be real-world limitations that transports are limited by, and they are free to express and require them however they see fit (including throwing if e.g. the serialized message would be too large etc.)

#### Distributed functions are implicitly `async throws` when called cross-actor

Similarly to how any `actor` function is *implicitly* asynchronous if called from outside the actor (sometimes called a "cross-actor call"), distributed functions are implicitly asynchronous _and throwing_. This is because a distributed function represents a potentially remote call, and any remote call may fail due to various reasons not present in single-process programming. Connections can fail, transport layer timeouts and heartbeats may signal that the call should be considered failed etc. 

This implicit throwing behavior is in addition to whether or not the function itself is declared as throwing. The below snippet shows the implicit effects applied to distributed functions when called from the outside:

```swift
distributed actor Greeter {
  func englishGreeting() -> String { "Hello!" }
  func japaneseGreeting() throws -> String { "こんにちは！" }
  func germanGreeting() async -> String { "Servus!" }
  func polishGreeting() async throws -> String { "Cześć!" }
  
  func inside() async throws { 
    _ = self.englishGreeting() // ok
    _ = try self.japaneseGreeting() // ok
    _ = await self.germanGreeting() // ok
    _ = try await self.polishGreeting() // ok
  }
}

func outside(greeter: Greeter) async throws { 
  _ = try await greeter.englishGreeting()  // ok, implicit `async` and implicit `throws`
  _ = try await greeter.japaneseGreeting() // ok, implicit `async` and explicit `throws`
  _ = try await greeter.germanGreeting()   // ok, explicit `async` and implicit `throws`
  _ = try await greeter.polishGreeting()   // ok, explicit `async` and explicit `throws`
}
```

The type of errors thrown if the remote communication fail are up to the transport, however it is recommended that all errors thrown by the _transport_ rather than the actual remote function conform to the `ActorTransportError` protocol, which helps determine the reason of a call failing. We will discuss errors in more detail in their dedicated [Transporting Errors](#transporting-errors) section of this proposal.

> **Potential future direction:** If Swift were to embrace a more let-it-crash approach, which thanks to actors and the full isolation story of them seems achievable, we could consider building into the language a notion of crashing actors and "failures" which are separate from "errors". This is not being considered or pitched in this proposal, but it's worth keeping in mind. Further discussion on this can be found here: [Cleanup callback for fatal Swift errors](https://forums.swift.org/t/stdlib-cleanup-callback-for-fatal-swift-errors/26977).

### Distributed Actor Isolation

Distributed actor isolation inherits all the isolation properties of local-only actors, removes a few one local-only special-case and adds two additional restrictions to the model. In the following sections we will discuss them one-by one to fully grasp why they are necessary.

#### Only `distributed` or `nonisolated` members may be accessed on distributed actors

As discussed in earlier sections, it is crucial that only `distributed func` declared members be accessible on any distributed actor instance.

Thanks to this guarantee the compiler can check the necessary requirements on such declarations (see [`distributed func` declarations](#distributed-func-declarations)), and transports and runtime systems can tightly control the exact "exposed" surface of a distributed actor.

#### No permissive special case for accessing constant `let` properties

Distributed actors remove the special case that exists for local-only actors, where access is permitted to such actor's properties as long as they are immutable `let` properties.

Local-only actors in Swift make a special case to permit _synchronous_ access to _constant properties_, e.g. `let name: String`, since they are known to be safe to access and cannot be modified either so for the sake of concurrency safety, such access is permissible. Such loosening of the actor model is _not_ permissible for distributed actors, because these properties must are potentially remote, and any such access would have to be asynchronous and involve networking.

Specifically, the following is permitted under Swift's local-only actors model:

```swift
actor LocalGreeter { 
  let details: String // "constant"
}
LocalGreeter().name // ok
```

yet is illegal when the actor is distributed:

```swift
distributed actor Greeter { 
  let details: String // "constant", yet distributed actor isolated
}
Greeter(transport: ...).details // error: property 'details' is distributed actor-isolated
```

This restriction is restored in the distributed actor model, because accessing such property would mean a network call.

We also argue that it is a non-goal, and would cause problematic anti-patterns in the real world, if such access to stored properties over network were somehow to be allowed. It is very much in the interest of clean distributed systems to expose as little and as coarse grained operations as possible, without the "easy way out" of exposing a remote actor's state remotely.

#### Distributed functions and protocol conformances

It is legal to declare a `DistributedActor` bound protocol, and to declare `distributed` functions inside it. In fact, this is a common use-case and will eventually allow developers to vend their APIs as plain protocols, without having to share the underlying `distributed actor` implementation. Such protocols may be defined as:

```swift
protocol DistributedFunctionality: DistributedActor {
  distributed func dist() -> String
  distributed func distAsync() async -> String
  distributed func distThrows() throws -> String
  distributed func distAsyncThrows() async throws -> String
}

distributed actor DF: DistributedFunctionality { 
  // ... implements all of the above functions ...
  
  func local() async throws {
    _ = self.dist() // ok
    _ = await self.distAsync() // ok
    _ = try self.distThrows() // ok
    _ = try await self.distAsyncThrows() // ok
  }
}

func outsideAny<AnyDF: DistributedFunctionality>(df: AnyDF) async throws {
  _ = try await self.dist() // ok
  _ = try await self.distAsync() // ok
  _ = try await self.distThrows() // ok
  _ = try await self.distAsyncThrows() // ok
}
```

As showcased in `outsideAny()` it is possible to invoke distributed functions on a generic or even existential type bound to a distributed actor protocol. The behavior of such invocations is as one might expect: if the actual passed actor is local, the actual function implementation is invoked, if it is remote a message is formed and sent to the remote distributed actor.

It is also legal to declare non-distributed functions and other protocol requirements in such protocol, however as usual with any distributed actor such will _not_ be possible to be invoked cross-actor, however they may serve as an implementation detail for other distributed functions. They would be possible to call cross-actor when using the "known to be local" escape hatch which will be discussed later on.

```  swift
protocol DistributedAndNonisolatedLocalFunctionality: DistributedActor {
  func makeName() -> String // must be implemented as `nonisolated`
  distributed func generate() -> String
}

// e.g. the generate function may offer a default implementation in terms of the local funcs
extension DistributedAndNonisolatedLocalFunctionality {
  distributed func generate() -> String { 
    "Default\(self.makeName())"
  }
}
```

A conforming distributed actor would be able to implement such protocol as follows:

```swift
distributed actor DAL: DistributedAndNonisolatedLocalFunctionality {
  nonisolated makeName() -> String { "SomeName" }
  
  // uses default generate() impl, 
  // or may provide one here by implementing `distributed func generate() -> String` here.
}
```

Given such a definition of the `DAL` actor and above protocols, the following would be legal/illegal invocations of the appropriate functions:

```swift
let dal: DAL
dal.makeName() // error: only 'distributed' functions can be called from outside the distributed actor
try await dal.generate() // ok!
```

The semantics of the `makeName()` witness are the same as discussed in [SE-0313: Improved control over actor isolation: Protocol conformances](https://github.com/apple/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md#protocol-conformances) - it must be nonisolated in order to be able to conform to the protocol requirement. As they are not distributed functions, the same rules apply as if it were a plain old normal actor. The only difference being, when one is allowed to invoke them cross-actor (only when using the `whenLocal(...)` escape hatch).

#### `nonisolated` members

In order to be able to implement a few yet very useful protocols for distributed actor usage within the context of e.g. collections, we need to be able to implement functions which are "independent" of their enclosing distributed actor's nature.

As we will discuss in detail in the following sections, distributed actors are for example `Equatable` by default, because there is exactly _one_ correct way of implementing this and a few other protocols on a distributed actor type.

The `nonisolated` serves the same purpose and mechanically works the same way as on normal actors - it effectively means that the implicit `self` parameter of any such function or computed property, is `nonisolated` which can be understood as the function being "outside" of the actor, and therefore no actor hop needs to be emitted to invoke such functions. This allows us to implement synchronous protocol requirements, such as `Codable`, `Hashable` and others. Refer to [SE-0313: Improved control over actor isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md#protocol-conformances) for more details on actors and protocol conformances.

Specifically, the `Equatable` and `Hashable` implementations have only _one_ meaningfully correct implementation given any distributed actor, which is utilizing the actors identity to check for equality or compute the hash code:

```swift
protocol DistributedActor {
  nonisolated var id: AnyActorIdentity { get }
  // ... 
}

distributed actor Worker {} 

extension Worker: Equatable {
  public static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }
}

extension Worker: Hashable { 
  nonisolated public func hash(into hasher: inout Hasher) {
    self.id.hash(into: &hasher)
  }
}
```

While it is not possible to declare stored properties as `nonisolated`, the `id` and `transport` are implemented using special _computed_ properties, which know where in memory those fields are stored for every distributed actor, even if it is a remote instance which does not otherwise allocate memory for any of its declared stored properties.

Unlike local-only actors, distributed actors *cannot* declare stored properties as `nonisolated`, however nonisolated functions, computed properties and subscripts are all supported. As any nonisolated function though, they may not refer to any isolated state of the actor.

This would invite a model in the isolation checking, where we would allow–when dealing with a remote actor reference–access to properties which do not exist in memory. This is because a remote reference has allocated _exactly_ as much memory for the object as is necessary to store the address and transport fields, and no storage is allocated for any of the other stored properties of a remote reference, because the actor's state _does not exist_ locally, and we would not be able to invent any valid values for it. Therefore, it must not be possible to declare stored properties as nonisolated.

This also means that it is possible to access the address and transport cross-actor, even though they are not distributed, and these accessess will not have any implicit effects applied to them:

```swift
distributed actor Worker {}
let worker: Worker = ... 
worker.id   // ok
worker.transport // ok
```

### Actor Transports

Distributed actors are always associated with a specific transport that handles a specific instance.

A transport a protocol that distributed runtime frameworks implement in order to take intercept and implement the messaging performed by a distributed actor. The protocol is defined as:


```swift

public protocol ActorTransport: Sendable {

  // ==== ---------------------------------------------------------------------
  // - MARK: Resolving actors by identity

  func decodeIdentity(from decoder: Decoder) throws -> AnyActorIdentity

  func resolve<Act>(_ identity: Act.ID, as actorType: Act.Type) throws -> ActorResolved<Act>
      where Act: DistributedActor

  // ==== ---------------------------------------------------------------------
  // - MARK: Actor Lifecycle

  func assignIdentity<Act>(_ actorType: Act.Type) -> Act.ID
      where Act: DistributedActor

  func actorReady<Act>(_ actor: Act) 
      where Act: DistributedActor

  func resignIdentity(_ id: AnyActorIdentity)

}
```

A transport has two main responsibilities:

- **Lifecycle management:** creating and resolving actor addresses which are used by the language runtime to construct distributed actor instances,
- **Messaging:** perform all message dispatch and handling on behalf of a distributed actor it manages, specifically:
  - for a remote distributed actor reference: 
    - be invoked by the framework's source generated `_remote_impl_function` implementations with a "message" representation of the locally invoked function, serialize and dispatch it onto the network or other underlying transport mechanism. 
    - This turns local actor function invocations into messages put on the network.
  - for a local distributed actor instance: 
    - handle all incoming messages on the transport, decode and dispatch them to the apropriate local recipient instance. 
    - This turns incoming network messages into local actor invocations.

The swift runtime synthesizes calls to the actor functions in specific locations of actor initializers, deinitializers and distributed functions, for example:

- When a distributed actor is created using the local initializer (`init(transport:)`) the `transport.assignIdentity(...)` function is invoked.
- When the actor is deinitialized, the transport is invoked with `transport.resignIdentity(...)` with the terminated actor's identity. 
- When creating a distributed actor using the resolve function (`resolve(id:using:)`) the Swift runtime invokes `transport.resolve(_:as:)` asking the transport to decide if this address resolves as a local reference, or if a proxy actor should be allocated. 
  - Creating a proxy object is a Swift internal feature, and not possible to invoke in any way other than using a resolve call.

The second category is "actually sending/receiving the messages" which is highly dependent on the details of the underlying transport. We do not have to impose any API requirements on this piece of a transport actually. Since a distributed actor is intended to be started with a transport, and `_remote_<function>` functions are source generated by the same framework as the used transport, it may have to downcast the property to `MyTransport` and implement the message sending whichever way it wants.

> **NOTE:** We are discussing the possibility of removing this down-cast requirement and the source generation of `_remote` functions in the future. However, today we are lacking the language features to do so.

This way of dealing with message sending allows frameworks to use their specific data-types, without having to copy back and forth between Swift standard types and whichever types they are using. It would be helpful if we had a shared "bytes" type in the language here, however in general a transport may not even directly operate on bytes, but rather accept a `Codable` representation of the invoked function (e.g. an enum that is `Codable`) and then internally, depending on configuration, pick the appropriate encoder/decoder to use for the specific message (e.g. encoding it using a binary coder rather than JSON etc). By keeping this representation fully opaque to Swift's actor runtime, we also allow plugging in completely different transports, and we could actually invoke gRPC or other endpoints which use completely different serialization formats (e.g. protobuf or JSON over websocket) rather than the `Codable` mechanism. We don't want to prevent such use-cases from existing, thus opt to keep the "send" functions out of the `ActorTransport` protocol requirements. This is also good, because it won't allow users to "randomly" write `self.transpot.send(randomMessage, to: id)` which would circumvent the type-safety experience of using distributed actors.

#### Transporting `Error`s

A transport _may_ attempt to transport errors back to the caller if it is able to encode/decode them.

Because the errors thrown by a `distributed func` are not typed, it is impossible to enforce at compile time that an error is always `Codable`. Transports may perform a best effort attempt to encode/decode errors, e.g. perhaps by encoding just the error type name rather than the entire error object and send it back to the caller where it would be thrown as an ActorTransportError subtype. Some transports may attempt encoding the entire Error object _if it was `Codable`_, however to do so securely, such types would also need to be registered in safe-lists for serialization etc. This isn't a topic we're exploring in depth in this proposal (because it is a transport implementation concern), but have explored and thought about already.

As usual with today's Swift, it is possible to express strongly typed errors by using `Result<User, InvalidPassword>` as it allows for typed handling of such errors as well as automatically enforcing that the returned error type is also `Codable` and thus possible to encode and transport back to the caller. This is a good idea also because it forces developers to consider if an error really should be encoded or not (perhaps it contains large amounts of data, and a different representation of the error would be better suited for the distributed function).

The exact errors thrown by a distributed function depends on the underlying transport. Generally one should expect some form of `struct BestTransportError: ActorTransportError { ... }` to be thrown by a distributed function if transport errors occur--the exact semantics of those throws are intentionally left up to specific transports to document when and how to expect errors to be thrown.

To provide more tangible examples, why a transport may want to throw even if the called function does not, consider the following:

```swift
// Node A
distributed actor Failer { 
  distributed func letItCrash() { fatalError() } 
}
```

```swift
// Node B
let failer: Failer = ... 

// could throw transport-specific error, 
// e.g. "ClusterTransportError.terminated(actor:node:existenceConfirmed:)"
try await failer.letItCrash() 
```

This allows transports to implement failure detection mechanisms, which are tailored to the specific underlying transport, e.g. for clustered applications one could make use of Swift Cluster Membership's [SWIM Failure Detector](https://www.github.com/apple/swift-cluster-membership), while for IPC mechanisms such as XPC more process-aware implementations can be provided. The exact guarantees and semantics of detecting failure will of course differ between those transports, which is why the transport must define how it handles those situations, while the language feature of distributed actors _must not_ define it any more specifically than discussed in this section.

### Actor Identity

A distributed actor's identity is defined by its `id` property which stores an instance of the `ActorIdentity` type. 

A distributed actor's identity is automatically assigned and managed during its initialization. Refer to the section on [Distributed Actor initialization](#distributed-actor-initialization) for an in depth discussion of the initialization process.

The specific implementation of the identity is left up to the transport that assigns it, and therefore may be as small as an `Int` or as complex as a full `URI` representing the actor's location in a cluster. As the identity is used to implement a number of protocol requirements, it must conform to a number of them as well, most notably it should be `Sendable`, `Codable`, and `Hashable`:

```swift
public protocol ActorIdentity: Sendable, Codable, Hashable {}
```

The actual `id` property of the distributed actor is a `nonisolated` computed property which is synthesized by the compiler and points at the identity assigned to the actor during the initialization (or resolve process). 

The property uses a type-erased struct to store the identity, because otherwise `Hashable`'s `Self` type requirements would prevent using `DistributedActor` bound protocols as existentials, which is a crucial use-case that we are going to implement in the near future.

```swift
protocol DistributedActor {

  /// Logical identity of this distributed actor.
  ///
  /// Many distributed actor references may be pointing at, logically, the same actor.
  /// For example, calling `resolve(id:using:)` multiple times, is not guaranteed
  /// to return the same exact resolved actor instance, however all the references would
  /// represent logically references to the same distributed actor, e.g. on a different node.
  ///
  /// Conformance to this requirement is synthesized automatically for any
  /// `distributed actor` declaration.
  nonisolated var id: AnyActorIdentity { get }
}
```

Specific transports, depending on their use-cases and needs, may implement the identity protocol slightly differently. For example, they might implement the identity using a simple numeric identifier, or URI-like scheme. Implementing an identifier is simple, because a `struct` type gets all the necessary implementation pieces synthesized automatically, so it can be as simple as defining:

```swift
// e.g. some "Net Actors" library may define the identity as:
struct NetActorAddress: ActorIdentity { 
  let uri: String
}
```

Comparing actor identities is sufficient to know if the pointed-at actors are the logically "the same" actor or different ones. An actor is inherently bound to a transport that it was created with, and as such, to the address assigned to it. This means that the same actor should be pointed at using the same address type, so cross type comparisons are not a big concern.

We also offer the type-eraser `AnyActorIdentity` which is used to _store_ arbitrary actor identities, and is useful for e.g. using it as keys in a dictionary:

```swift
public struct AnyActorIdentity: ActorIdentity, @unchecked Sendable, CustomStringConvertible {
  public init<ID>(_ identity: ID) where ID: ActorIdentity { ... }
    // ... 
  }
}
```

Next, we will discuss a number of protocols that are implemented for any distributed actor by delegating to its identity.

#### Distributed Actors are `Identifiable`

An important protocol that any distributed actor conforms to automatically is the [`Identifiable` protocol](https://developer.apple.com/documentation/swift/identifiable) which is used to provide a _stable (logical) identity_, as this is exactly what a distributed actor's identity provides, we propose to conform to this protocol by default.

The `Identifiable` protocol is useful for any type which has a *stable identity*, and in the case of a distributed actor there is a single correct way to conform to this protocol: by implementing the `id` requirement using the actor's identity:

```swift
// @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
// public protocol Identifiable {
//
//   /// A type representing the stable identity of the entity associated with
//   /// an instance.
//   associatedtype ID: Hashable
// 
//   /// The stable identity of the entity associated with this instance.
//   var id: ID { get }
// }

extension DistributedActor: Identifiable { 
  nonisolated var id: AnyActorIdentity { /*... synthesized ...*/ }
}
```

Note that the implementation of `id` is `nonisolated`. This means that it can be accessed _synchronously_, and even though it is not a distributed function, it can always be accessed on any distributed actor. 

The identity can be largely viewed as an opaque object from the perspective of the runtime, and users of distributed actors. However, for users it may provide useful debug information since, depending on the transport, it may include a full network address of the referred to actor, or some other logical name that can help identify the specific instance this reference is pointing at in the case of a remote actor reference. As such, it can be useful to print the actor identity in the actor's default `description` implementation as well.

#### Distributed Actors are `Equatable` and `Hashable`

Concrete distributed actors types (i.e. not protocols) automatically get synthesized `Equatable` and `Hashable` conformances.

Equality of actors _by actor identity_ is tremendously important, because it enables us to "remember" actors in collections, look them up, and compare if an incoming actor reference is one which we have not seen yet, or is a previously known one. It is an important piece of the location transparency focused design that we are proposing. 

For example, let us imagine a local, non-thread safe, class `ChatRoom` which aims to implement greetings to new members. If we implement each member of the chat room as a struct with some `id` (their nickname), property, we can eaisly implement a functionality to greet first time chatters slightly differently than returning ones:

```swift
struct Chatter: Hashable { 
  var id: String = "@ktoso" 
}

final class ChatRoom {
  var members: Set<Chatter> = []
  
  distributed func join(chatter: Chatter) async {
    if members.insert(chatter).inserted {
      return print("Welcome, \(chatter)!")
    }
  
    return "Welcome back, \(chatter)!"
  }
}
```

Now, what if we wanted to implement a _distributed_ chat room? We would want our chatters to be active entities to which we can send chat messages - this is a natural fit for a distributed actor. The chatroom itself also may be located on some server, but we don't really care about _where exactly_ it is (remember _location transparency_?), so it also is a nice candidate for a distributed actor.

Now, since the actor identities are unique, and assigned to each actor, we can simply use them to recognize new or returning chatters, like this:

```swift
distributed actor Chatter {} 

distributed actor DistributedChatRoom { 
  var members: Set<Chatter> = []
  
  distributed func join(chatter: Chatter) async { 
    if members.insert(chatter).inserted { 
      return "Welcome!"
    } else {
      return "Welcome back!"
    }
  }
}
```

While this example is pretty simple, it showcases an incredibly common pattern to store and remember actors by their stable identity. This, and similar shapes of this pattern (which are lifecycle aware), are tremendously common in distributed actor system programming, and therefore we aim to make this simple, and work as expected by default.

Unlike local-only actors, reference equality (`===`) of distributed actors is usually very misleading or actively harmful! This is because we need to be able to implement transports which simply return a new proxy instance whenever they are asked to resolve a remote instance, rather than forevermore return the same exact instance for them which would lead to infinite (!) memory growth including forever keeping around instances of remote actors which we never know for sure if they are alive or not, or if they ever will be resolved again. Therefore `ActorIdentity` equality is the only reasonable way to implement equality _and_ is a crucial element to keep transport implementations memory efficient.

For reference, this is how the `==` and `hash` functions are synthesized by the compiler:

```swift
extension Chatter: Hashable {  
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }

  nonisolated public func hash(into hasher: inout Hasher) {
    self.id.hash(into: &hasher)
  }
}
```

We, purposefully, do not implement these protocols directly on the `DistributedActor` protocol, because we want to allow such protocols be used as existentials in the near future. If we conformed the protocol itself to `Hashable` we would not be able to store other distributed actor protocols as existentials in variables, which is an essential use-case we want to support in order to allow for resolving such protocols, without knowing their implementation type at runtime. This use-case is discussed in depth in [Future Directions: Resolving `DistributedActor` bound protocols](#resolving-distributedactor-bound-protocols)).

#### Distributed Actors are `Codable`

Distributed actors are `Codable` and are represented as their _actor identity_ in their encoded form.

In order to be true to the actor model's idea of freely shareable references, regardless of their location (see [*location transparency*](#location-transparency)), we need to be able to pass distributed actor references to other--potentially remote--distributed actors.

This implies that distributed actors must be `Codable`. However, the way that encoding and decoding is to be implemented differs tremendously between _data_ and active entities such as _actors_. Specifically, it is not desirable to serialize the actor's state - it is after all what is isolated from the outside world and from external access.

The `DistributedActor` protocol also conforms to `Codable`. As it does not make sense to encode/decode "the actor", per se, the actor's encoding is specialized to what it actually intends to express: encoding an identity, that can be resolved on a remote node, such that the remote node can contact this actor. This is exactly what the `ActorIdentity` is used for, and thankfully it is an immutable property of each actor, so the synthesis of `Codable` of a distributed actor boils down to encoding its identity:

```swift
extension DistributedActor: Codable {
  /* ~~~ synthesized ~~~ */ 
  nonisoalted func encode(to encoder: Encoder) throws { 
    var container = encoder.singleValueContainer()
    try container.encode(self.actorAddress)
  }
  /* === synthesized === */
}
```

Decoding is slightly more involved, because it must be triggered from _within_ an existing transport. This makes sense, since it is the transport's internal logic which will receive the network bytes, form a message and then turn to decode it into a real message representation before it can deliver it to the decoded and resolved recipient. 

In order for decoding of an Distributed Actor to work on every layer of such decoding process, a special `CodingUserInfoKey.distributedActorTransport` is used to store the actor transport in the Decoder's `userInfo` property, such that it may be accessed by any decoding step in a deep hierarchy of encoded values. If a distributed actor reference was sent as part of a message, this means that it's `init(from:)` will be invoked with the actor transport present. 

The default synthesized decoding conformance can therefore automatically, without any additional user intervention, decode itself when being decoded from the context of any actor transport. The synthesized initializer looks roughly like this:

```swift
extension DistributedActor {
  /* ~~~ synthesized ~~~ */ 
  @derived init(from decoder: Decoder) throws {
    guard let transport = self.userInfo[.transport] as? ActorTransport else {
      throw DistributedActorDecodingError.missingTransportUserInfo(Self.self)
    }
    let container = try decoder.singleValueContainer()

    let identity = try container.decode(AnyActorIdentity.self)
    self = try Self(resolve: identity, using: transport)
  }
  /* === synthesized === */
}
```

During decoding of such reference, the transport gets called again and shall attempt to `resolve` the actor's identity. If it is a local actor known to the transport, it will return its reference. If it is a remote actor, it will return a proxy instance pointing at this identity. If the identity is illegal or unrecognized by the transport, this operation will throw and fail decoding the message.

To show an example of what this looks like in practice, we might implement an actor cluster transport, where the actor identities are a form of URIs, uniquely identifying the actor instance, and as such encoding an actor turns it into `"[transport-name]://system@10.0.0.1:7337/Greeter#349785`, or using some other encoding scheme.

It is tremendously important to allow passing actor references around, across distributed boundaries, because unlike local-only actors, distributed actors can not rely on passing a closure to another actor to implement "call me later" style patterns. This is also what enables the familiar "delegate" style patterns to be adopted and made use of using distributed actors!

Such "call me later"-patterns must be expressed by passing the `self` of a distributed actor (potentially as a `DistributedActor` bound protocol) to another distributed actor, such that it may invoke it whenever necessary. E.g. publish/subscribe patterns implemented using distributed patterns need this capability:

```swift
distributed actor PubSubPublisher {
  var subs: Set<AnySubscriber<String>> = []
  
  /// Subscribe a new distributed actor/subscriber to this publisher
  distributed func subscribe<S>(subscriber: subscriber)
    where S: SimpleSubscriber, S.Value == String {
    subs.insert(AnySubscriber(subscriber))
  }
  
  /// Emit a value to all subscribed distributed actors
  distributed func emit(_ value: String) async throws { 
    for s in subs {
      try await s.onNext(value)
    }
  }
}
```

```swift
protocol SimpleSubscriber: DistributedActor {
  associatedtype Value: Codable
  distributed func onNext(_ value: Value)
}

distributed actor PubSubSubscriber: Subscriber { 
	typealias Value = String
  
  let publisher: PubSubPublisher = ...
  
  func start() async throws { 
    try await publisher.subscribe(self) // `self` is safely encoded and sent remotely to the publisher
  }
  
  /// Invoked every time the publisher has some value to emit()
  func onNext(_ value: Value) { 
    print("Received \(value) from \(publisher)!")
  }
}
```

The above snippet showcases that with distributed actors it is pretty simple to implement a small _distributed_ pub-sub style publisher, and of course this ease of development extends to other distributed systems issues. The fundamental building blocks being a natural fit for distribution that "just click" are of tremendous value to the entire programming style with distributed actors. Of course a real implementation would be more sophisticated in its implementation, but it is a joy to look at how distributed actors make mundane and otherwise difficult distributed programming tasks simple and understandable.

This allows us to pass actors as references across distributed boundaries:

```swift
distributed actor Person {
  distributed func greet(_ greeting: String) async throws {
    log.info("I was greeted: '\(greeting)' yay!")
  }
}

distributed actor Greeter { 
  var greeting: String = "Hello, there!"
  
  distributed func greet(person: Person) async throws {
    try await person.greet("\(greeting)!")
  }
}
```

#### Sharing identities and discovering Distributed Actors

As discussed, identities are crucial to locate and resolve an opaque identity into a real and "live" actor reference that we can send messages through.

However, how do we communicate an identity of one actor from one node to another if to identify _any distributed actor_ actor we need to know their identity to begin with? This immediately ends up in a "catch-22" situation, where in order to share an identity with another actor, we need to know _that_ actor's identity, but we can't know it, since we were not able to communicate with it yet!

Luckily, this situation is not uncommon and has established solutions that generally speaking are forms of _service discovery_. Swift already offers a general purpose service discovery library with [swift-service-discovery](https://github.com/apple/swift-service-discovery), however it's focus is very generic and all about services, which means that for a given well-known service name e.g. "HelloCluster", we're able to lookup which _nodes_ are part of it, and therefore we should attempt connecting to them. Implementations of service discovery could be using DNS, specific key-value stores, or kubernetes APIs to locate pods within a cluster. 

This is great, and solves the issue of locating _nodes_ of a cluster, however we also need to be able to locate specific _distributed actors_, that e.g. implement some specific protocol. For example, we would like to, regardless of their location locate all `Greeter` actors in our distributed actor system. We can use the well-known type name Greeter as key in the lookup, or we could additionally qualify it with some identifier for example only to find those `Greeter` actors which use the language `pl` (for Polish).

In practice, _how_ such lookups are performed is highly tied to the underlying transport, and thus the transport library should provide a specific pattern to perform those lookups. We call this pattern the `Receptionist`, and it may take the following protocol shape:

```swift
protocol Receptionist: DistributedActor { 
    @discardableResult
    public func register<Guest>(
        _ guest: Guest,
        with key: Reception.Key<Guest>,
        replyTo: ActorRef<>? = nil
    ) async -> Reception.Registered<Guest> 
      where Guest: ReceptionistGuest

    distributed func lookup<Guest>(
        _ key: Reception.Key<Guest>
    ) async -> Reception.Listing<Guest> 
      where Guest: DistributedActor

  // more convenience functions may exist ...
}
```

Such receptionist is a normal distributed actor, which may be resolved on the used transport and performs the actor "discovery" on our behalf.

In practice, this means that locating all greeters in a system boils down to:

```swift
guard let anyGreeter =
  try await Receptionist.resolve(transport)
    .lookup(Greeter.self).first else {
  print("No Greeter discovered!")
}

try await anyGreeter.greet("Caplin, the Capybara")
```

Notice that this pattern, by design, requires actors to opt-into being discoverable. This is important for a number of reasons, most importantly for security we would not want to allow any node in the system to resolve _arbitrary_ actor references by guessing their types and names. Instead, only distributed actors which opt into this discovery mechanism participate in it.

It is still possible to _explicitly_ share an actor reference or identity throught messaging though. If security demands it, we can provide ways to ban specific actors from being shared in this way as well though.

### "Known to be local" distributed actors

Usually programming with distributed actors means assuming that an actor may be remote, and thus only `Codable` parameters/return types may be used with it. This is a sound and resilient model, however it sometimes becomes a frustrating limitation when an actor is "_known to be local_".

This situation sometimes occurs when developing a form of manager actor which always has a single local instance per cluster node, but also is reachable by other nodes as a distributed actor. Since the actor is defined as distributed, we can only send messages which can be encoded to it, however sometimes such APIs have a few specialized local functions which make sense locally, but are never actually sent remotely. We do want to have these local-only messages to be handled by exactly the same actor as the remote messages, to avoid race conditions and accidental complexity from splitting it up into multiple actors.

Another situation where piercing through the distributed isolation model is useful is testing. While unit testing distributed actors, it is sometimes useful to peek into their internal state and write assertions against such otherwise inaccessible state.

Another specific example of such pattern is the [CASPaxos protocol](https://arxiv.org/abs/1802.07000), which is a popular distributed consensus protocol which performs a distributed compare-and-set operation over a distributed register. It's API accepts a `change` closure, which naturally we cannot (and do not want to) serialize and send around the cluster, however the local proposer wants to accept such function:

```swift
distributed actor Proposer<Value: Codable> { 
  public func change(
    key: String, 
    update: (Value?) throws -> Value
  ) async throws -> Value { /* ... */ }
}
```

Given such API, naturally cannot be used in distributed fashion, but still we'd like to send this closure to the local proposer actor. Without an escape hatch that would allow doing so, developers would be forced into hacking their way around the limitation by wrapping closures in e.g. some `NotActuallyCodable { value in ... }` what would be marked `Codable` even though its implementation would be to crash if anyone attempted to encode it. 

This is sub-optimal because technically, we can make mistakes and accidentally invoke such functions on an actor that actually was remote, causing the process to crash. Rather we would like to express the assumption directly: "*assuming this actor is local, I want to be able to invoke it using the local actor rules, without the restrictions imposed by the additional distributed actor checking*".

We could offer a function to inspect and perform actions when the actor reference indeed is local like this:

```swift
extension DistributedActor { 
  @discardableResult
  nonisolated func whenLocal(
    _ body: (isolated Self) async throws -> T
  ) async rethrows -> T?
  
  nonisolated func whenLocal(
    _ body: (isolated Self) async throws -> T,
    else whenRemote (Self) async throws -> T
  ) async rethrows -> T
}
```

Which can be used like this:

```swift
distributed actor Greeter { func tell(_ message: String) { print(message) } }
let greeter: Greeter = Greeter(transport: someTransport)
let greeter2: Greeter = try Greeter(resolve: address, transport: someTransport)

await greeter.whenLocal { greeterWasLocal in 
  greeterWasLocal.tell("It is local, after all!")
}

let location = await greeter.whenLocal { _ in
  "was local"
} else { 
  "was remote, after all!"
}
```

This allows us to keep using the actor as isolation and "linearization" island, keep the distributed protocol implementations simple and not suffer from accidental complexity of splitting "local" "and local but also remote" pieces into separate actors.

> For comparison, when this situation happens with other runtimes such as Akka the way around it is to throw exceptions when "not intended for remoting" messages are sent. It is possible to determine if an actor is local or remote in such runtimes, and it is used in some low-level orchestration and internal load balancing implementations, e.g. selecting 1/2 of local actors, and moving balancing them off to another node in the cluster etc.

The implementation of the `isLocalActor` function is a trivial check if the `isDistributedActor` flag is set on the actor instance, and therefore does not add any additional storage to the existing actor infrastructure since actors already have such flags property used for other purposes.

## Runtime implementation details

This section of the proposal discusses some of the runtime internal details of how distributed functions and remote references are implemented. While not part of the semantic model of the proposal, it is crucial for the implementation approach to fit well into Swift's runtime.

#### Remote `distributed actor` instance allocation

Creating a proxy for an actor type is done using a special `resolve(id:using:)` factory function of any distributed actor. Internally, it invokes the transport's `resolve` function, which determines if the identity resolves to a known local actor managed by this transport, a remote actor which this transport is able to communicate with, or the identity cannot be resolved and the resolve will throw:

```swift
protocol DistributedActor { 
    static func resolve<ID>(identity: ActorIdentity, using transport: ActorTransport) 
      throws -> Self 
      where ID: ActorIdentity { 
    	// ... synthesized ...
    }
}

protocol ActorTransport { 
  /// Resolve a local or remote actor address to a real actor instance, or throw if unable to.
  /// The returned value is either a local actor or proxy to a remote actor.
  func resolve<Act>(id identity: ActorIdentity, as actorType: Act.Type) 
      throws -> ResolvedDistributedActor<Act>
	  where Act: DistributedActor
}

enum ResolvedDistributedActor<Act: DistributedActor> { 
  case resolved(instance: Act)
  case makeProxy
}
```

This function can only be invoked on specific actor types–as usual with static functions on protocols–and serves as a factory function for actor proxies of given specific type.

Implementing the resolve function by returning `.resolved(instance)` allows the transport to return known local actors it is aware of. Otherwise, if it intends to proxy messages to this actor through itself it should return `.proxy`, instructing the constructor to only construct a partial "proxy" instance using the address and transport. The transport may also chose to throw, in which case the constructor will rethrow the error, e.g. explaining that the passed in address is illegal or malformed.

The `resolve` function is intentionally not asynchronous, in order to invoke it from inside `decode` implementations, as they may need to decode actor addresses into actor references.

To see this in action, consider:

```swift
distributed actor Greeter { ... }
```

Given an `ActorAddress`, `Greeter.resolve` can be used to create a proxy to the remote actor:

```swift
let greeter = try Greeter.resolve(id: someIdentity, using: someTransport)
```

The specifics of how a `resolve` works are left up to the transport, as their semantics depend on the capabilities of the underlying protocols the transport uses.

Implementations of resolve should generally not perform heavy operations and should be viewed similar to initializers -- quickly return the object, without causing side effects or other unexpected behavior.

#### `distributed func` internals

> **Note:** It is a future direction to stop relying on end-users or source-generators having to fill in the `_remote_` function implementations.
> However we will only do so once we've gained practical experience with a few more transport implementations. 
> This would happen before the feature is released from its experimental mode however.

Developers implement distributed functions the same way as they would any other functions. This is a core gain from this model, as compared to external source generation schemes which force users to implement and provide so-called "stubs". Using the distributed actor model, the types we program with are the same types that can be used as proxies--there is no need for additional intermediate types.

A local `distributed actor` instance is a plain-old `actor` instance. If we simplify the general idea what an actor call actually is, it boils down to enqueueing a representation of the call to the actor's executor. The executor then eventually schedules the task/actor and the call is invoked. We could think about it as if it did the following for each cross-actors call:

```swift
// local-actor PSEUDO-CODE (does not directly represent actual runtime implementation!)
func greet(name: String) async -> String { 
  let job = __makeTaskRepresentingThisInvocation()
  self.serialExecutor.enqueue(job)
  return await job.get() // get the job's result
}
```

Remote actors are very similar to this, but instead of enqueueing a `job` into their `serialExecutor`, they convert the call into a `message` (rather than `job`) and pass it to their `transport` (rather than `Executor`) for processing. In that sense, local and remote actors are very similar, each needs to turn an invocation into something the underlying runtime can handle, and then pass it to the appropriate runtime.

The distributed actors design is purposefully detaching the implementation of such transport from the language, as we cannot and will not ship all kinds of different transport implementations as part of the language. Instead, the language feature is implemented by delegating to `_remote_<function-name>` functions whenever a `<function-name>` function is invoked on a distributed actor. This is done by a synthesized thunk, which performs a simple check like this:

```swift
distributed func hi(name: String, surname: String) -> String { ... }

/* ~~~~~~~ synthesized ~~~~~~ */
// Synthesized thunk for hi(name:surname:).
// 
// Thunk identifiers are the same as the function they are for, however their mangling 
// has an appended additional thunk type identifier, which in case of distributed function thunks is 'Td'.
func hi(name: String, surname: String) async throws -> String {
  if _isRemoteDistributedActor(self) { 
    return try await self._remote_hi(name: name, surname: surname)
  } else {
    return self.hi(name: name, surname: surname) // calls actual function the thunk is for
  }
}
/* === end of synthesized === */
```

> **WORK IN PROGRESS NOTE:** Depending on how Kavon's idea on separate Decls for remote/local goes, we could instead just emit the remote call in the remote actor decl. We would avoid this if/else on calls then entirely at the cost of more emitted decls.

So, invocations on a distributed actor implicitly perform this check and dispatch either to the local, or `_remote` function. The `_remote_<function-name>` is also synthesized by default, and is a **dynamic function**, which means that it may be _dynamically replaced_ at build time. 

The `_remote_<function-name>` is also synthesized at compile-time, however its implementation is going to exit with a fatal-error, unless it is replaced with a specific implementation. Its signature is the same as the target function it is representing. So in the case of the func `hi(name:surname:)` shown above, it would be effectively of the following shape:

```swift
/* ~~~ synthesized ~~~ */
dynamic nonisolated func _remote_hi(name: String, surname: String) async throws -> String { 
  fatalError("""
             helpful message that one must provide a replacement for ths function, 
             e.g. by installing a SwiftPM plugin of some transport (e.g. ...).
             """)
} 
/* === end of synthesized === */
```

> This replacement also works even if we only have a binary dependency of the distributed actor providing library, but provide the _remote implementation on our project (compiling from source). This allows for re-use actors which are declared in libraries for which we do not have sources.

An interesting benefit from this approach is that if developing a generally useful library of a few distributed actors and operations on them, they need not provide any `_remote` implementations or specific transports. This means, that in test modules they may use some `TestTransport()` and keep the main module free of any transport dependencies or transport related code. The code would even compile, and run completely fine until used in a distributed setting at which point the user of the library has to take the required steps to set up and use the transport of course.

In practice, this means that a project would install a SwiftPM plugin (see, [SE-0303](https://github.com/apple/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md)) which source generates the tiny bit of glue code necessary for each of the distributed functions and their respective message representation. Because such source generation plugins run transparently to developers during the build process, it is not really noticeable during development time that source generation is used.

The glue code that such plugin must generate might look somewhat as follows: 

First, for outgoing messages, we need to create a "message" representing the distributed function. Transports may choose to do so as some form of large `enum`, containing all functions of a type as its cases, or by independent message structs representing each of the functions:

```swift
// EXAMPLE; One of the ways a source generator may synthesize a distributed func as a message
extension Greeter { 
  struct _HiMessage: _MyFrameworkMessage, Codable {
    typealias Reply = String
    let name: String
    let surname: String
  }
  
  // OR, a transport may represent messages as a large enum, like so:
  
  enum Messages { 
    case hi(name: String, surname: String, reply: Reply<String>)
    case unknown
  }
}
```

Second, for outgoing messages still, we need to replace the remote function. This is currently done using the direct dynamic replacement API, however as we mature this piece of the proposal this may either get its own attribute, or become unnecessary. 

The dynamic replacement function must be `nonisoalted` because the actor is operating on is always _remote_ and therefore has no state, and access to its properties (other than the transport and id) must be prevented, because they don't exist. Thankfully the `nonisolated` attribute achieves exactly that, bu making the function effectively be semantically "outside" the actor.

```swift
extension Greeter { 
  @_dynamicReplacement(for: hi(name:surname:))
  nonisolated func _remote_impl_hi(name: String, surname: String) async throws -> String {
    let message = _HiMessage(name: name, surname: surname)
    try await self._transport.send(message)
  }
}
```

Lastly, for incoming messages, a transport must somehow handle them by invoking the appropriate function. It is up to the transport to perform the decoding from the wire and obtain the discriminator by which to invoke the right function, but effectively it can boil down to switching over an enum or type, and invoking the function, e.g.:

```swift
// EXAMPLE; assuming enum implementation of messages
extension Greeter {
  func _receive(message: _MyFrameworkMessageEnum) {
    switch message {
    case .hi(let name, let surname, let replyTo):
      try await reply.send(self.hi(name: name, surname: surname))
    }     
  }
} 
```

> **NOTE:** It is a goal to eventually get rid of this source generation step, however for the time being, and learning from experience and requirements of a number of specific transports we want to explore, the source generation approach is reasonable. 
> 
> Once we are confident in the semantics and language features required to get rid of the source generation step, we will be able to synthesize the appropriate `Envelope<Message>` and represent every `distributed func` as a well-defined codable `Message` type, which transports then would simply use their configured coders on.

## Future Directions

### Storing and requiring more specific Transport types

For some specific use-cases it may be necessary to ensure an actor is only used over some speific transport. Currently this is not illegal, but the type-system does not reflect the specific type of a transport if it were to be initialized like this:

```swift
protocol OnlyIPCTransport: ActorTransport { ... }

distributed actor Worker { 
  init(transport: OnlyIPCTransport) {}
}
```

Which means that this `Worker` actor can only ever be used with inter process communication transports, rather than arbitrary networking. 

If a more specific transport is used, all initializers must use the same type for the transport parameter in their declarations.

The distributed actor transport (or identity) property may not be declared explicitly. Though we could lift this restriction if it was deemed necessary.

### Ability to customize parameter/return type requirements

Currently distributed actors require all their parameters and return types to be `Codable` (and `Sendable`). However some transports may wish to restrict the set of allowed types even further, for example, only allowing the sending of integers and other "known to be safe" types.

We suggest that a future version of distributed actors allows customizing this behavior by providing a typealias:

```swift
enum SuperSafe { 
  case int(Int)
  case safe(SomeSafeType)
}

distributed actor TrustNoOne { 
  typealias MessageRequirement = SuperSafe
  
  distributed func hello(string: String) {}
  // error: type 'String' of parameter 'string' is not allowed, 
  //        only 'SuperSafe' types are allowed, because 
  // 		    'TrustNoOne.MessageRequirement' restriction
}
```



### Resolving DistributedActor bound protocols

In some situations it may be undesirable or impossible to share the implementation of a distributed actor (the `distributed actor` definition) between "server" and "client". 

We can imagine a situation where we want to offer users of our system easy access to it using distributed actors, however we do not want to share our internal implementation thereof. This works similarly to how one might want to publish API definitions, but not the actual API implementations. Other RPC runtimes solve this by externalizing the protocol definition into external interface description languages (IDLs), such as `.proto` files in the case of gRPC.

With Swift, we already have a great way to define protocols... protocols!

Distributed actor protocols, i.e. protocols which also conform to `DistributedActor`, are allowed to define distributed functions and can only be implemented by declaring a `distributed actor` conforming to such protocol.

For example, it is legal to define the following distributed actor protocol:

```swift
protocol Greeter: DistributedActor {
  distributed func greet(name: String) throws -> String
}
```

And a "client" side application, even without knowledge of how the distributed actor is implemented on the "backend" may resolve it as follows:

```swift
let id: ActorIdentity = ... // known to point at a remote `Greeter`
let greeter: Greeter = try Greeter.resolve(id: id, using: someTransport)

let greeting = try await greeter.greet("Alice")
assert(greeting == "Hello, Alice!")
```

Such a resolved reference (i.e., `greeter`) should be a remote actor, since there is no local implementation the transport can invent to implement this protocol. We could imagine some transports using source generation and other tricks to fulfil this requirement, so this isn't stated as a MUST, however in any normal usage scenario the returned reference would be remote or the resolve should throw.

In other words, thanks to Swift's expressive protocols and isolation-checking rules applied to distributed functions and actors, we are able to use protocols as the interface description necessary to share functionality with other parties, even without sharing out implementations. There is no need to step out of the Swift language to define and share distributed system APIs with eachother.

> TODO: This is not implemented yet, and a bit more tricky however unlocks amazing use cases for when client/server are not the same team or organization.

### Synthesis of `_remote` and well-defined `Envelope<Message>` functions

Currently the proposal relies on "someone", be it a SwiftPM plugin performing source code generation, or a developer implementing specific `_remote_` function counterparts for each distributed function for a transport to receive apropriate message representations of each function invocation. 

While this is sub-optimal, it is not a road-block for the first iteration of this proposal. It allows us to explore and iterate on specific requirements from various transport implementations without having to bake their assumptions into the compiler right away.

Once we have collected enough experience from real transport implementations we will be able to remove the requirement to "fill in" remote function implementations by end users and instead synthesize them. This change will likely take the shape of introducing a common "envelope" type, and adding a `send(envelope: Envelope)` requirement to the `ActorTransport` protocol, as such, we expect this piece of work would be best done before stabilizing the distributed feature.

A rough sketch of what would need to be synthesized by the compiler is shown below:

```swift
distributed actor Greeter { 
  distributed func greet(name: String) -> String
}

// *mockup - not complete design yet*
protocol ActorTransport {
  func send<Message: Codable>(envelope: Envelope) async throws 
}

// ------- synthesized --------
extension Greeter { 
  func _remote_greet(name: String) async throws -> String { 
    var envelope: Envelope<$GreetMessage> = Envelope($GreetMessage(name: name))
    envelope.recipient = self.id
    // ... 
    return try await self.transport.send(envelope)
  }
}
// ---- end of synthesized ----
```

The difficulty in this is mostly in the fact that we would be committing forever to the envelope format and how the messages are synthesized and encoded. 

This must be thought though with consideration for numerous transports, and only once we're confident the strategy serves all transports we're interested will we be able to commit to a synthesis strategy here. Until then, we want to explore and learn about the various transport specific complications as we implement them using source generators and/or hand implemented `_remote_` functions.

### Support for `AsyncSequence`

This isn't really something that the language will need much more support for, as it is mostly handled in the `ActorTransport` and serialization layers, however it is worth pointing out here.

It is possible to implement (and we have done so in [other runtimes](https://doc.akka.io/docs/akka/current/stream/stream-refs.html) in the past), distributed references to streams, which may be consumed across the network, including the support for flow-control/back-pressure and cancellation.

This would manifest in returning / accepting values conforming to the AsyncSequence or some more specific marker protocol. Distributed actors can then be used as coordinators and "sources" e.g. of metrics or log-lines across multiple nodes -- a pattern we have seen successfully applied in other runtimes in the past.

### Ability to hardcode actors to specific shared transport

In this potential extension we would allow either requiring a specific type of transport be used by adopting distributed actors, or outright provide a shared transport instance for certain distributed actors.

Specifically, it may be useful for some transports which offer special features that only they can implement (and perhaps a test "in memory" transport), to require that all distributed actors conforming to `FancyDistributedActor` should require `FancyActorTransport`:

```swift
protocol FancyDistributedActor: DistributedActor { 
  typealias ActorTransportRequirement = FancyActorTransport
}
```

This would affect the generated initializer and related functions, by changing the type used for the transport transport parameter and storage:

```swift
distributed actor FancyGreeter: FancyDistributedActor { 
  // var transport: FancyActorTransport { ... }
  // init(transport: FancyActorTransport) { ... }
}
```

We can also imagine specific transports, or projects, which know that they only use a specific shared transport in the entire application, and may avoid this initialization boilerplate. This would be possible if we tweak synthesis to allow and respect properties initialized in their field declarations, like this:

```swift
protocol SpecificDistributedActor: DistributedActor { 
  var transport: ActorTransport { SpecificTransport.shared }
}

distributed actor SpecificDaemon: SpecificActor { 
  // var transport: SpecificTransport { ... }
  
  // NOT synthesized: init(transport:)
 
  /* ~~~ synthesized instead ~~~ */
  init()
  static func resolve(id:) throws
  /* === synthesized instead === */
}
```

### Actor Supervision

Actor supervision is a powerful and crucial technique for distributed actor systems. It is a pattern well-known from other runtimes such as Erlang and Akka, where it is referred to "linking" or "watching" respectively.

Our goal with the `distributed actor` language feature is to allow enough flexibility such that such features may be implemented in transport libraries. Specific semantics on failure notification may differ depending on transports, and while a generalization over them can be definitely very useful (and we may end up providing one), allowing specific transports to offer specific failure handling mechanisms is called for as well.

A rough sketch of this is shown below. An actor can "watch" other actors if the transport supports it, and if such remote actor–or the node on which it was hosted–crashes, we would be notified in the `actorTerminated` function and may react to it, e.g. by removing any such crashed workers from our internal collection of workers:

```swift
@available(SwiftStdlib 5.5, *)
distributed actor Observer {
  let watch: DeathWatch!
  var workers: [Worker] = []

  init(…) { 
    // … 
    watch = DeathWatch(self)
  }

  func add(worker: Worker) {
    workers[worker.id] = watch(worker)
  }

  func actorTerminated(identity: AnyActorIdentity) {
    print(“oh no, \(identity) has terminated!”)
    workers.remove(identity)
  } 
}
```

## Related Work

### Swift Distributed Tracing integration

> This future direction does *not* impact the compiler pieces of the proposal, and is implementable completely in `ActorTransport` implementations, however we want to call it out nevertheless, because the shape of the proposal and task-local values have been designed to support this long-term use case in mind.

With the recent release of [Swift Distributed Tracing](https://github.com/apple/swift-distributed-tracing) we made first steps towards distributed tracing becoming native to server-side swift programs. This is not the end-goal however, we want to enable distributed tracing throughout the Swift ecosystem, and by ensuring tracers can natively, and easily inter-op with distributed actors we lay down further ground work for this vision to become reality.

Note that distributed traces also mean the ability to connect traces from devices, http clients, database drivers and last but not least distributed actors into a single visualizable trace, similar to how Instruments is able to show execution time and profiles of local applications. With distributed tracing we have the ability to eventually offer such "profiler like" experiences over multiple actors, processes, and even front-end/back-end systems.

Thanks to [SE-NNNN: **Task Local Values**](https://github.com/apple/swift-evolution/pull/1245) `ActorTransport` authors can utilize all the tracing and instrument infrastructure already provided by the server side work group and instrument their transports to carry necessary trace information.

Specifically, since the distributed actor design ensures that the transport is called in the right place to pick up the apropriate values, and thus can propagate the trace information using whichever networking protocol it is using internally:

```swift
// simplified remote implementation generated by a transport framework
func _remote_exampleFunc() async throws {
  var message: MessageRepr = .init(name: "exampleFunc") // whatever representation the framework uses
  
  if let traceID = Task.local(\.traceID) { // pick up tracing `Baggage` or any specific values and carry them
    message.metadata.append("traceID", traceID) // simplified, would utilize `Injector` types from tracing
  }
  
  try await self.transport.send(message, to: self.id)
}
```

Using this, trace information and other information (see below where we discuss distributed deadlines), is automatically propagated across node boundaries, and allows sophisticated tracing and visualization tools to be built.

If you recall the `makeDinner` example from the 

Such distributed dinner cooking can then be visualized as:

```
>-o-o-o----- makeDinner ----------------o---------------x      [15s]
  | | |                     | |         |                  
~~~~~~~~~ ChoppingService ~~|~|~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  \-|-|- chopVegetables-----x |                            [2s]     \
    | |  \- chop -x |         |                        [1s]         | Executed on different host (!)
    | |             \- chop --x                        [1s]         /
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    \-|- marinateMeat -----------x      |                  [3s]
      \- preheatOven -----------------x |                 [10s]
                                        \--cook---------x  [5s]
```

Specific tracing systems may offer actual fancy nice UIs to visualize this rather than ASCII art.

### Distributed `Deadline` propagation

The concurrency proposals initially also included the concept of deadlines, which co-operate with task cancellation in the task runtime.

Distributed actors as well as Swift Distributed Tracing

> This pattern is well-known and has proven most useful as proven by its wide application in effectively _all_ distributed Go systems, where the `Context` type automatically carries a deadline value, and automatically causes cancellation of a context if the deadline is exceeded.

Example use-case:

```swift
enum AppleStore { 
  distributed actor StorePerson { 
    let storage: Storage
  
    distributed func handle(order: Order, customer: Customer) async throws -> Device {
      let device = await try Task.withDeadline(in: .minutes(1)) { 
        await try storage.fetchDevice(order.deviceID)
      }
      
      guard await customer.processPayment(device.price) else {
        throw PaymentError.tryAgain
      }
      
      return device
    }
  }
}

// imagine this actor running on a completely different machine/host
extension AppleStore {
  distributed actor Storage { 
    distributed func fetchDevice(_ deviceID: DeviceID) async throws -> Device { 
      // ...
    }
  }
}
```

### Potential Transport Candidates

While this proposal intentionally does not introduce any specific transport, the obvious reason for introducing this feature is implementing specific actor transports. This proposal would feel incomplete if we would not share our general thoughts about which transports would make sense to be implemented over this mechanism, even if we cannot at this point commit to specifics about their implementations.

It would be very natural, and has been considered and ensured that it will be possible by using these mechanism, to build any of the following transports:

- clustering and messaging protocols for distributed actor systems, e.g. like [Erlang/OTP](https://www.google.com/search?q=erlang) or [Akka Cluster](https://doc.akka.io/docs/akka/current/typed/cluster-concepts.html).
- [inter-process communication](https://en.wikipedia.org/wiki/Inter-process_communication) protocols, e.g. XPC on Apple platforms or shared-memory.
- various other RPC-style protocols, e.g. the standard [XML RPC](http://xmlrpc.com), [JSON RPC](https://www.jsonrpc.org/specification) or custom protocols with similar semantics.
- it should also be possible to communicate with WASM and "Swift in the Browser" using distributed actors and an apropriate websocket transport.

## Related Proposals

- **[Swift Concurrency Manifesto](https://gist.github.com/lattner/31ed37682ef1576b16bca1432ea9f782#design-sketch-for-interprocess-and-distributed-compute)** - distributed actors as part of the language were first roughly outlined as a general future direction in the Concurrency Manifesto. The approach specified in this proposal takes inspiration from the manifesto, however may be seen as a reboot of the effort. We have invested a significant amount of time, research, prototypinig and implementing the approach since, and are confident in the details of the proposed model.

**Pre-requisites**

- [SE-0296: **async/await**](https://github.com/apple/swift-evolution/blob/main/proposals/0296-async-await.md) - asynchronous functions are used to express distributed functions,
- [SE-0306: **Actors**](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md) - are the basis of this proposal, as it refines them in terms of a distributed actor model by adding a few additional restrictions to the existing isolation rules already defined by this proposal,

**Related**

- [SE-0311: **Task Local Values**](https://github.com/apple/swift-evolution/blob/main/proposals/0311-task-locals.md) - are accessible to transports, which use task local values to transparently handle request deadlines and implement distributed tracing systems (this may also apply to multi-process Instruments instrumentations),
- [SE-0295: **Codable synthesis for enums with associated values**](https://github.com/apple/swift-evolution/blob/main/proposals/0295-codable-synthesis-for-enums-with-associated-values.md) - because distributed functions relying heavily on `Codable` types, and runtimes may want to express entire messages as enums, this proposal would be tremendously helpful to avoid developers having from ever dropping down to manual Codable implementations.
- [SE-0303: **SwiftPM Extensible build-tools**](https://github.com/apple/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) – which will enable source-code generators, necessary to fill-in distributed function implementations by specific distributed actor transport frameworks.

**Related work**

- [Swift Cluster Membership](https://www.github.com/apple/swift-cluster-membership) ([blog](https://swift.org/blog/swift-cluster-membership/)) – cluster membership protocols are both natural to express using distributed actors, as well as very useful to implement membership for distributed actor systems.
- [Swift Distributed Tracing](https://github.com/apple/swift-distributed-tracing) – distributed actors are able to automatically and transparently participate in distributed tracing systems and instrumentation, this allows for a "profiler-like" performance debugging experience across entire fleets of servers,

## Alternatives Considered

### TODO: all the internal representations of remote/local

TODO: there was tens of iterations of this, we should explain a few so they don't come up again as they at first seem viable but break down later on.

### Discussion: Why Distributed Actors are better than "just" some RPC library?

While this may be a highly subjective and sensitive topic, we want to tackle the question up-front, so why are distributed actors better than "just" some RPC library?

The answer lies in the language integration and the mental model developers can work with when working with distributed actors. Swift already embraces actors for its local concurrency programming, and they will be omni-present and become a familiar and useful tool for developers. It is also important to notice that any aync function may be technically performing work over network, and it is up to developers to manage such calls in order to not overwhelm the network etc. With distributed actors, such calls are more _visible_ because IDEs have the necessary information to e.g. underline or otherwise hightlight that a function is likely to hit the network and one may need to consider it's latency more, than if it was just a local call. IDEs and linters can even use this statically available information to write hints such as "hey, you're doing this distributed actor call in a tight loop - are you sure you want to do that?"

Distributed actors, unlike "raw" RPC frameworks, help developers to think about their distributed applications in terms of a network of collaborating actors, rather than having to think and carefully manage every single serialization call and network connection management between many connected peers - which we envision to be more and more important in the future of device and server programming et al. You may also refer to the [Swift Concurrency Manifesto; Part 4: Improving system architecture](https://gist.github.com/lattner/31ed37682ef1576b16bca1432ea9f782#part-4-improving-system-architecture) section on some other ideas on the topic.

This does _not_ mean that we shun RPC style libraries or plain-old HTTP clients and libraries similar to them, which may rather be expressed as non-actor types with asynchronous functions. They still absolutely have their place, and we do not envision distributed actors fully replacing them in all use-cases. We do mean however that extending the actor model to it's natural habitat (networking) will enable developers to build some kinds of interactive multi-peer/multi-node systems far more naturally than each time having to re-invent a similar abstraction layer, never quite reaching the integration smoothness as language provided integration points such as distributed actors can offer.

### Special Actor spawning APIs

One of the verbose bits of this API is that a distributed actor must be created or resolved from a specific transport. This makes sense and is _not_ accidental, but rather inherent complexity – because Swift applications often interact over various transports: within the host (e.g. a phone or mac) communicating via XPC with other processes, while at the same time communicating with server side components etc. It is important that it is clear and understandable what transport is used for what actor at construction.

#### Explicit `spawn(transport)` keyword-based API

The `spawn` word is often used in various actor runtimes

Rather than provide the specialized `init(transport)` that every distributed actor must invoke, we could solve this using "compiler magic" (which we are usually trying to avoid), and introduce a form of `spawn` keyword. 

This goes against the current Actor proposal. Actors do not currently need to be prefixed with any special keywords when creating them. I.e. a local actor is simply created by constructing it: `Greeter()` rather than `spawn Greeter()` or similar.

In theory, we could require that a distributed actor must be spawned by `spawn(transport) Greeter()` and we would be able to hook up all internals of the distributed actor this way. Local actors could be spawned using `spawn Greeter()`. 

This would be fairly consistent and leaves a natural extension point for additional actor configuration in the spawn function (e.g. configuring an actor's executor at _spawn time_ could be done this way as well). However it is not clear if the core team would want to introduce yet another keyword for actor spawning, and specialize it this way. The burden of adding yet another keyword for this feature may be too high and not exactly worth it, as it only moves around where the transport/configuration passed: from their natural location in actor constructors, to special magical syntax.

#### Global eagerly initialized transport

One way to avoid having to pass a transport to every distributed actor on creation, would be to use some global state to register the transport to be used by all distributed actors in the process. This _seems_ like a good idea at first, but actually is a terrible idea - based on experience from moving an actor system implementation from global to non-global state over many years (during the Akka 1 to 2 series transition, as well as years of migrating off global state and problems caused by it by the Play framework).

The idea is similar in spirit to what SSWG projects do with bootstraping logging, metrics, and tracing systems: 

```swift
GlobalActorTransport.bootstrap(SpecificTransport())
// ... 
let greeter = DistributedGreeter()
```

While _at first glance_ this seems nice, the negative implications of such global state are numerous:

- It is hard to know by browsing the code what transprot the greeter will use,
  - if a transport were passed in via constructor (as implemented by this proposal) it is simpler to understand where the messages will be sent, e.g. via XPC, or some networking mechanism.
- The system would have to crash the actor creation if no transport is bootstrapped before the greeter is initialized.
- Since global state is involved, all actor spawns would need to take a lock when obtaining the actor reference. We would prefer to avoid such locking in the core mechanisms of the proposal.
- It encourages global state and makes testing harder; such bootstrap can only be called __once__ per process, making testing annoying. For example, one may implement an in-process transport for testing distributed systems locally; or simply configure different actors using different "nodes" even though they run in the same process. 

This global pattern discourages good patterns, about managing where and how actors are spawned and kept, thus we are not inclined to accepting any form of global transport.

#### Directly adopt Akka-style Actors References `ActorRef<Message>`

Theoretically, distributed actors could be implemented as just a library, same as Akka does on the JVM. However, this would be undermining both the distributed actors value proposition as well as the actual local-only actors provided by the language.

First, a quick refresher how Akka models (distributed) actors: There are two API varieties, the untyped "classic" APIs, and the current (stable since a few years) "typed" APIs. 

Adopting a style similar to Akka's ["classic" untyped API](https://doc.akka.io/docs/akka/current/actors.html#here-is-another-example-that-you-can-edit-and-run-in-the-browser-) is not ideal because of the lack of type-safety in those classic APIs.

Akka's typed actor API's represent actors as `Behavior<Message>` which is spawned, and then an `ActorRef<Message>` is returned from the spawn operation. The `Message` is a type representing, via sub-classing and immutable case classes, all possible messages this actor can reply to. Semantically this is equivalent to an `enum` in Swift. And we might indeed represent messages like this in Swift (even internally in an `ActorTransport` in the current proposal!) However, this model requires users to manually switch, destructure and handle much boilerplate related to wielding the types in the right ways so the model compiles and works properly. The typed API also heavily relies on Scala sugar for pattern matching within total and partial functions, allowing the expressions such as:

```scala
// scala
Behaviors.receiveMessage { 
  case "hello" => Behaviors.same
}
```

Having introduced the general ideas, let us imagine how this API would look like in Swift:

```swift
enum GreetMessage: Codable {
  case greet(who: ActorRef<String>, language: String)
}

// the actor behavior
let behavior: Behavior<Greet> = Behavior.setup { context in
  // state is represented by capturing it in behaviors
  var greeted = 0

  // actual receive function
  return .receiveMesage { message in 
    switch message {
    case .greet(let who, let language):
      greet(who: who, in: language)
    }
  }
                                                
  func greet(who: ActorRef<String>, language: String) { 
    greeted += 1
    localize("Hi \(who.address.name)!", in: "language")
  }
}

// spawning the actor and obtaining the reference
let ref: ActorRef<GreetMessage> = try system.spawn("greeter", behavior)
ref.tell(.greet(who: "Alice", in: "en")) // messages are used explicitly, so we create the enum values
```



```swift
distributed actor Greeter { 
  var greeted = 0
  distributed func greet(who: String, in language: String) async throws -> Greeting { 
    greeted += 1
    localize("Hi \(who)!", in: language)
  }
}

let greeter = Greeter(transport: ...)
let greeting = await greeter.greet(who: "Alice", in: "en")
```



There are **many** fantastic lessons, patterns and ideas developed by the Akka community–many of which inspire this proposal–however, it is limited in its expression power, because it is _just a library_. In contrast, this effort here is colaborative with the compiler infrastructure, including type checking, and thread-safety, concurrency model hooks and code generation built-into the language on various layers of the project. 

Needless to say, what we are able to achieve API wise and also because who the target audience of this project is, we are taking different tradeoffs in the API design - favoring a more language integrated model, for the benefit of feeling natural for the developers first discovering actor model programming. By doing so, we aim to provide a model that, as Akka has in the past, will mature well over the next 10 years, as systems become more and more distributed and programming such systems becomes more commonplace than ever before.

## Acknowledgments & Prior Art

We would like to acknowlage the prior art in the space of distributed actor systems which have inspired our design and thinking over the years. Most notably we would like to thank the Akka and Orleans projects, each showing independent innovation in their respective ecosystems and implementation approaches. 

We would also like to acknowlage the Erlang BEAM runtime and Elixir language for a more modern take built upon the on the same foundations. In some ways, Swift's distributed actors are not much unlike the gen_server style processes available on those platforms. While we operate in very different runtime environments and need to take different tradeoffs at times, both have been an inspiration and very useful resource when comparing to the more Akka or Orleans style actor designs.

## Source compatibility

This change is purely additive to the source language. 

The additional use of the keyword `distributed` in `distributed actor` and `distributed func` applies more restrictive requirements to the use of such an actor, however this only applies to new code, as such no existing code is impacted.

Marking an actor as distributed when it previously was not is potentially source-breaking, as it adds additional type checking requirements to the type.

## Effect on ABI stability

This proposal is ABI additive.

**TODO:** ???

## Effect on API resilience

**TODO:** ???

## Changelog

- Remove `init(transport:)` and base the design around synthesis of the lifecycle calls into existing designated initializers
- Remove `init(resolve:using:)` and replace it with a static resolve factory function which works much better with the DI challanges that such remote instance might be facing
- Change `struct ActorAddress` to `protocol ActorIdentity` which allows for transports to customize and pick efficient representations of identities as apropriate for their underlying transport mechanisms
  - These may remain URI-like structures, or highly optimized numeric representations (e.g. unique actor ID number)
  - Makes implementation dependent on [SE-0309: Unlock existentials for all protocols](https://github.com/apple/swift-evolution/blob/main/proposals/0309-unlock-existential-types-for-all-protocols.md)
