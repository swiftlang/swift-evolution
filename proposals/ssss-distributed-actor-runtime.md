# Distributed Actor Runtime

* Proposal: [SE-NNNN](NNNN-distributed-actor-runtime.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Pavel Yaskevich](https://github.com/xedin) [Doug Gregor](https://github.com/DougGregor), [Kavon Farvardin](https://github.com/kavon), [Dario Rexin](https://github.com/drexin), [Tomer Doron](https://github.com/tomerd)
* Review Manager: TBD
* Status: **Partially implemented on `main`**
* Implementation: 
  * Partially available in [recent `main` toolchain snapshots](https://swift.org/download/#snapshots) behind the `-enable-experimental-distributed` feature flag. 
  * This flag also implicitly enables `-enable-experimental-concurrency`.

## Table of Contents

- [Distributed Actor Runtime](#distributed-actor-runtime)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
      - [Useful links](#useful-links)
  - [Motivation](#motivation)
      - [Example scenario](#example-scenario)
    - [Caveat: Low-level implementation details](#caveat-low-level-implementation-details)
  - [Detailed design](#detailed-design)
    - [The `DistributedActorSystem` protocol](#the-distributedactorsystem-protocol)
    - [Distributed Actors](#distributed-actors)
      - [Implicit Distributed Actor Properties](#implicit-distributed-actor-properties)
      - [Initializing Distributed Local Actors](#initializing-distributed-local-actors)
        - [Initializing `actorSystem` and `id` properties](#initializing-actorsystem-and-id-properties)
        - [Ready-ing Distributed Actors](#ready-ing-distributed-actors)
        - [Ready-ing Distributed Actors, exactly once](#ready-ing-distributed-actors-exactly-once)
      - [Resigning Distributed Actor IDs](#resigning-an-distributed-actor-ids)
      - [Resolving Distributed Actors](#resolving-distributed-actors)
    - [Distributed Methods](#distributed-methods)
      - [Invoking Distributed Methods on Remote Instances](#invoking-distributed-methods-on-remote-instances)
      - [Making Remote Calls](#making-remote-calls)
      - [Receiving Remote Calls](#receiving-remote-calls)
      - [Resolving the Recipient Distributed Actor](#resolving-the-recipient-distributed-actor)
      - [Preparing the Distributed Method invocation](#preparing-the-distributed-method-invocation)
      - [Deserializing incoming Distributed Method Parameters](#deserializing-incoming-distributed-method-parameters)
      - [Performing the target `distribtued func` call](#performing-the-target-distribtued-func-call)
      - [Collecting result/error from the Invocation](#collecting-resulterror-from-the-invocation)
  - [Future Work](#future-work)
    - [Stable names and more API evolution features](#stable-names-and-more-api-evolution-features)
    - [Passing parameters to assignID](#passing-parameters-to-assignid)
  - [Alternatives Considered](#alternatives-considered)
    - [Define remoteCall as protocol requirement, and accept `[Any]` arguments](#define-remotecall-as-protocol-requirement-and-accept-any-arguments)
    - [Constraining arguments, and return type with of `remoteCall` with `SerializationRequirement`](#constraining-arguments-and-return-type-with-of-remotecall-with-serializationrequirement)
    - [Hardcoding the distributed runtime to make use of Codable](#hardcoding-the-distributed-runtime-to-make-use-of-codable)
  - [Acknowledgments & Prior Art](#acknowledgments--prior-art)
  - [Source compatibility](#source-compatibility)
  - [Effect on ABI stability](#effect-on-abi-stability)
  - [Effect on API resilience](#effect-on-api-resilience)
  - [Changelog](#changelog)

## Introduction

With the recent introduction of [actors](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md) to the language, Swift gained powerful and foundational building blocks for expressing *thread-safe* concurrent programs. Actors guarantee thread-safety thanks to actor-isolation of mutable state they encapsulate.

In [SE-0336: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md) we took it a step further, guaranteeing complete isolation of state with distributed actor-isolation, and setting the stage for `distributed` method calls to be performed across process and node boundaries. 

This proposal focuses on the runtime aspects of making such remote calls possible, their exact semantics and how developers can provide their own `DistributedActorSystem` implementations to hook into the same language mechanisms, extending Swift's distributed actor model to various environments (such as cross-process communication, clustering, or even client/server communication).

#### Useful links

It is recommended, though not required, to familiarize yourself with the prior proposals before reading this one:

- [SE-0336: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md) - a detailed proposal 
- Distributed Actor Runtime (this proposal)

Feel free to reference the following library implementations which implement this proposal's library side of things:

- [Swift Distributed Actors Library](https://www.swift.org/blog/distributed-actors/) - a reference implementation of a *peer-to-peer cluster* for distributed actors. Its internals depend on the work in progress language features and are dynamically changing along with these proposals. It is a realistic implementation that we can use as reference for these design discussions.

## Motivation

With distributed actor-isolation checking laid out in [SE-0336: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md) we took the first step towards enabling remote calls being made by invoking `distributed func` declarations on distributed actors. The isolation model and serialization requirement checks in that proposal outline how we can guarantee the soundness of such distributed actor model at compile time.

Distributed actors enable developers to build their applications and systems using the concept of actors that may be "local" or "remote", and communicate with them regardless of their location. Our goal is to set developers free from having to re-invent ad-hoc approaches to networking, serialization and error handling every time they need to embrace distributed computing. 

Instead, we aim to embrace a co-operative approach to the problem, in which:

1. the Swift language, compiler, and runtime provide the necessary isolation checks and runtime hooks for distributed actor lifecycle management, and distributed method calls that can be turned into "messages" that can be sent to remote peers,

2. `DistributedActorSystem` library implementations, hook into the language provided cut-points, taking care of the actual message interactions, e.g. by sending messages representing remote distributed method calls over the network,
3. `distributed actor` authors, who want to focus on getting things done, express their distributed API boundaries and communicate using them. They may have opinions about serialization and specifics of message handling, and should be able to configure and use the `DistributedActorSystem` of their choice to get things done.

In general, we propose to embrace the actor style of communication for typical distributed system development, and aim to provide the necessary tools in the language, and runtime to make this a pleasant and nice default go-to experience for developers.

Distributed actors may not serve *all* possible use-cases where networking is involved, but we believe a large group of applications and systems will benefit from them, as the ecosystem gains mature `DistributedActorSystem` implementations.

#### Example scenario

In this proposal we will focus only on the runtime aspects of distributed actors and methods, i.e. what happens in order to create, send, and receive messages formed when a distributed method is called on a remote actor. For more details on distributed actor isolation and other compile-time checks, please refer to [SE-0336: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md).

We need to pass around distributed actors in order to invoke methods on them at some later point in time. We need those actors to declare `distributed` methods such that we have something we can message them with, and there must be some lifecycle and registration mechanisms related to them. 

One example use case we can keep in mind is a simple turn-based `Game` which showcases most of the capabilities we come to expect of distributed actors:

```swift
distributed actor Player { 
  // ... 
  
  distributed func makeMove() -> Move { ... } 
  
  distributed func gameFinished(result: GameResult) { 
    if result.winner == self {
      print("I WON!")
    } else {
      print("Player \(result.winner) won the game.")
    }
  }
}

distributed actor Game { 
  var state: GameState = ... 
  
  // players can be located on different nodes
  var players: Set<Player> = []
  
  distributed func playerJoined(_ player: Player) { 
    others.append(player)
    if others.count >= 2 { // we need 2 other players to start a game
      Task { try await self.start() }
    }
  }
  
  func start() async throws {
    state = .makeNewGameState(with: players)
    while !state.finished {
      for player in players { 
        let move = try await p.makeMove() // TODO: handle failures, e.g. "move timed-out" etc
        state.apply(move, by: player)
      }
    }
    
    let winner = state.winner
    try await game.finishedResult
  } 
}
```

This code snippet showcases what kind of distributed actors one might want to implement – they represent addressable identities in a system where players may be hosted on different hosts or devices. And we'd like to communicate with any of them from the `Game` actor which manages the entire game's state. Players may be on the same host as the `Game` actor, or on different ones, but we never have to change the implementation of Game to deal with this – thanks to distributed actors and the concept of location transparency, we can implement this piece of code once, and run it all locally, or distributed without changing the code specifically for either of those cases.

### Caveat: Low-level implementation details

This proposal includes low-level implementation details in order to showcase how one can use to build a real, efficient, and extensible distributed actor system using the proposed language runtime. It is primarily written for distributed actor system authors, which need to understand the underlying mechanisms which distributed actors use.

End users, which just want to use _distributed actors_, and not necessarily _implement_ a distributed actor system runtime, do not need to dive deep as deep into this proposal, and may be better served by reading [SE-0366: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md) which focuses on how distributed actors are used. Reading this, runtime, proposal however will provide additional insights as to why distributed actors are isolated the way they are.

This proposal focuses on how a distributed actor system runtime can be implemented. Because this language feature is extensible, library authors may step in and build their own distributed actor runtimes. It is expected that there will be relatively few, but solid actor system implementations eventually, yet their use would apply to many many more end-users than actor system developers.

## Detailed design

This proposal's detailed design section is going to deep dive into the runtime details and its interaction with user provided `DistributedActorSystem` implementations. Many of those aspects do are not strictly necessary to fully internallize by the end-user/developer that only wants to write some distributed actors and have them communicate using *some* distributed actor system. 

### The `DistributedActorSystem` protocol

At the core of everything distributed actors do, is the `DistributedActorSystem` protocol. This protocol is open to be implemented by anyone, and can be used to extend the functionality of distributed actors to various environments. 

Building a solid actor system implementation is not a trivial task, and we only expect a handful of mature implementations to take the stage eventually.

> At the time of writing, we–the proposal authors–have released a work in progress [peer-to-peer cluster actor system implementation](https://www.swift.org/blog/distributed-actors/) that is tracking this evolving language feature. It can be viewed as a reference implementation for the language features and `DistributedActorSystem` protocol discussed in this proposal. 
>
> Not everything mentioned in this proposal is implemented yet, the cluster library is lagging behind a little, but will be adopting the new APIs as they become available in the language.

Below we present the full listing of the `DistributedActorSystem` protocol, and we'll be explaining the specific methods one by one as we go:

```swift
// Module: _Distributed

protocol DistributedActorSystem: Sendable { 
  /// The type of 'ID' assigned to a 'distributed actor' while initializing with this actor system.
  /// The identity should be meaningfully unique, in the sense that ID equality should mean referring to the
  /// same 
  /// 
  /// A 'distributed actor' created using a specific actor system, will use the system's 'ActorID' as 
  /// the 'ID' type it stores and uses for its 'Hashable' implementation.
  ///
  /// ### Implicit 'distribute actor' Codable conformance
  /// If the 'ActorID' (and therefore also the 'DistributedActor.ID') conforms to 'Codable',
  /// the 'distributed actor' will gain an automatically synthesized conformance to 'Codable' as well.
  associatedtype ActorID: Sendable & Hashable
  
  /// The specific type of the invocation encoder that will be created and populated 
  /// with details about the invocation when a remote call is about to be made.
  ///
  /// The populated instance will be passed to the remoteCall from where it can be
  /// used to serialize into a message format in order to perform the remote invocation.
  associatedtype InvocationEncoder: DistributedTargetInvocationEncoder
  
  /// The specific type of invocation decoder used by this actor system.
  ///
  /// An instance of this type must be passed to `executeDistributedTarget` which
  /// extracts arguments and applies them to the local target of the invocation.
  associatedtype InvocationDecoder: DistributedTargetInvocationDecoder

  /// The serialization requirement that will be applied to all distributed targets used with this system. 
  ///
  /// An actor system is still allowed to throw serialization errors if a specific value passed to a distributed
  /// func violates some other restrictions that can only be checked at runtime, e.g. checking specific types
  /// against an "allow-list" or similar. The primary purpose of the serialization requirement is to provide
  /// compile time hints to developers, that they must carefully consider evolution and serialization of 
  /// values passed to and from distributed methods and computed properties.
  associatedtype SerializationRequirement
    where SerializationRequirement == InvocationEncoder.SerializationRequirement,
          SerializationRequirement == InvocationDecoder.SerializationRequirement
  
  // ==== ---------------------------------------------------------------------
  // - MARK: Actor Lifecycle

  /// Called by a distributed when it begins its initialization (in a non-delegating init).
  /// 
  /// The returned 'ID' stored by the distributed actor and is used to uniquely identify and 
  /// locate the actor within the system. Once 'actorReady' is called resolving this 'ID'
  /// with 'resolve(_:as:)' should return the same instance was just assigned this identity.
  ///
  /// The system should take special care to not assign two actors the same 'ID', and the 'ID'
  /// must remain valid until it is resigned (see 'resignID(_:)').
  func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, 
            Act.ID == ActorID

  /// Called when the distributed actor has been fully initialized (meaning that all of its,
  /// stored properties have been assigned an initial value).
  ///
  /// The distributed actor will pass its 'self' to 'actorReady(_:)' as it is fully initialized,
  /// and from that moment onwards it must be possible to resolve it using the 'resolve(_:as:)'
  /// method on the system.
  func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, 
            Act.ID == ActorID

  /// Called when the distributed actor is deinitialized (or has failed to finish initializing).
  /// 
  /// The system may release any resources associated with this actor id, and should not make
  /// further attempts to deliver messages to the actor identified by this identity.
  func resignID(_ id: ActorID)
  
  // ==== ---------------------------------------------------------------------
  // - MARK: Resolving distributed actors
  
  /// Resolve a local or remote actor address to a real actor instance, or throw if unable to.
  /// The returned value is either a local actor or proxy to a remote actor.
  ///
  /// Resolving an actor is called when a specific distributed actors `init(from:)`
  /// decoding initializer is invoked. Once the actor's identity is deserialized
  /// using the `decodeID(from:)` call, it is fed into this function, which
  /// is responsible for resolving the identity to a remote or local actor reference.
  ///
  /// If the resolve fails, meaning that it cannot locate a local actor managed for
  /// this identity, managed by this transport, nor can a remote actor reference
  /// be created for this identity on this transport, then this function must throw.
  ///
  /// If this function returns correctly, the returned actor reference is immediately
  /// usable. It may not necessarily imply the strict *existence* of a remote actor
  /// the identity was pointing towards, e.g. when a remote system allocates actors
  /// lazily as they are first time messaged to, however this should not be a concern
  /// of the sending side.
  ///
  /// Detecting liveness of such remote actors shall be offered / by transport libraries
  /// by other means, such as "watching an actor for termination" or similar.
  func resolve<Act>(_ id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, 
            Act.ID: ActorID,
            Act.SerializationRequirement == Self.SerializationRequirement
  
  // ==== ---------------------------------------------------------------------
  // - MARK: Remote Target Invocations

  /// Invoked by the Swift runtime when a distributed remote call is about to be made.
  ///
  /// The returned `InvocationEncoder` will be populated with all
  /// generic substitutions, arguments, and specific error and return types
  /// that are associated with this specific invocation.
  func makeInvocationEncoder() -> InvocationEncoder

  // We'll discuss the remoteCall method in detail in this proposal.
  // It cannot be declared as protocol requirement, and remains an ad-hoc 
  // requirement like this:
  /// Invoked by the Swift runtime when making a remote call.
  ///
  /// The `invocation` are the arguments container that was previously created
  /// by `makeInvocation` and has been populated with all arguments.
  ///
  /// This method should perform the actual remote function call, and await for its response.
  ///
  /// ## Errors
  /// This method is allowed to throw because of underlying transport or serialization errors,
  /// as well as by re-throwing the error received from the remote callee (if able to).
  //
  // Ad-hoc protocol requirement
  func remoteCall<Act, Err, Res>(
      on actor: Act,
      target: RemoteCallTarget,
      arguments: Invocation,
      throwing: Err.Type,
      returning: Res.Type
  ) async throws -> Res
      where Act: DistributedActor,
            Act.ID == ActorID,
            Err: Error,
            Res: Self.SerializationRequirement
  
  /// Invoked by the Swift runtime when making a remote call to a 'Void' returning function.
  ///
  /// ( ... Same as remoteCall ... )
  //
  // Ad-hoc protocol requirement
  func remoteCallVoid<Act, Err>(
      on actor: Act,
      target: RemoteCallTarget,
      arguments: Invocation,
      throwing: Err.Type
  ) async throws
      where Act: DistributedActor,
            Act.ID == ActorID,
            Err: Error
}

/// A distributed 'target' can be a `distributed func` or `distributed` computed property.
///
/// The actor system should encode the identifier however it sees fit, 
/// and transmit it to the remote peer in order to invoke identify the target of an invocation.
public struct RemoteCallTarget: Hashable {
  /// The mangled name of the invoked distributed method.
  /// 
  /// It contains all information necessary to lookup the method using `executeDistributedActorMethod(...)`
  var mangledName: String { ... }
  
  /// The human-readable "full name" of the invoked method, e.g. 'Greeter.hello(name:)'.
  var fullName: String { ... }
}
```

In the following sections, we will be explaining how the various methods of a distributed system are invoked by the Swift runtime.

### Implicit Distributed Actor Properties

Distributed actors have two properties that are crucial for the inner workings of actors that we'll explore during this proposal: the `id` and `actorSystem`.

These properties are synthesized by the compiler, in every `distributed actor` instance, and they witness the `nonisolated` property requirements defined on the `DistributedActor` protocol. 

The `DistributedActor` protocol (defined in SE-0336), defines those requirements:

```swift
protocol DistributedActor {
  associatedtype ActorSystem: DistributedActorSystem
  
  typealias ID = ActorSystem.ActorID
  typealias SerializationRequirement: ActorSystem.SerializationRequirement
  
  nonisolated var id: ID { get }
  nonisolated var actorSystem: ActorSystem { get }
  
  // ... 
}
```

which are witnessed by *synthesized properties* in every specific distributed actor instance.

Next, we will discuss how those properties get initialized, and used in effectively all aspects of a distributed actor's lifecycle.

### Initializing Distributed Actors

At runtime, a *local* `distributred actor` is effectively the same as a local-only `actor`. The allocated `actor` instance is a normal `actor`, however its initialization is a little special, because it must interact with its associated actor system to make itself available for remote calls.

We will focus on non-delegating initializers, as they are the ones where distributed actors cause additional things to happen. 

> Please note that **initializing** a distributed actor always returns a "**local** distributed actor". The only way to obtain a "**remote** distributed actor", i.e. "a remote reference" is by using the `resolve(id:using:)` method which is explained in [Resolving Distributed Actors](#resolving-distributed-actors).

Distributed actor initializers inject a number of calls into specific places of the initializer's body. These calls allow for the associated actor system to manage the actor's identity, and availability to remote calls. Before we dive into the details, the following diagram outlines the various calls that will be explained in this section:

```
┌────────────────────────────┐               ┌──────────────────────────┐                         
│  distributed actor MyActor │               │ MyDistributedActorSystem │                         
└────────────────────────────┘               └──────────────────────────┘                         
      │                                                    │                                      
 init(...)                                                 │                                      
      │                                                    │                                      
      │── // self.id = actorSystem.assignID(Self.self) ───▶│ Generate and reserve ID               
      │                                                    │                                      
      │   // self.actorSystem = system                     │                                      
      │                                                    │                                      
      │   <initialize other properties...>                 │                                      
      │                                                    │ 
      │── // actorSystem.actorReady(self) ────────────────▶│ Store a mapping (ID -> some DistributedActor)
      │                                                    │                                               
     ...                                                  ...
      │                                                    │                                      
      ◌ deinit ─ // actorSystem.resignID(self.id) ────────▶│ Remove (ID -> some DistributedActor) mapping 
                                                           │                                      
                                                          ...
```

### Distributed Actor initializers

A non-delegating initializer of a type must *fully initialize* it. The place in code where an actor becomes fully initialized has important and specific meaning to actor isolation which is defined in depth in [SE-0327: On Actors and Initialization](https://github.com/apple/swift-evolution/pull/1476). Not only that, but once fully initialized it is possible to escape `self` out of a (distributed) actor's initializer. This aspect is especially important for distributed actors, because it means that once fully initialized they _must_ be registered with the actor system as they may be sent to other distributed actors and even sent messages to.

All non-delegating initializers must accept a parameter that conforms to the `DistributedActorSystem` protocol. The type-checking rules of this are explained in depth in [SE-0336: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md). The following are examples of well-formed initializers:

```swift
distributed actor DA { 
  // synthesized:
  // init(system: Self.ActorSystem) {} // ✅ no user defined init, so we synthesize a default one
}

distributed actor DA2 {
  init(system: Self.ActorSystem) {} // ✅ ok, accepting the appropriate system type
  
  init(other: Int, system: Self.ActorSystem) {} // ✅ ok, other parameters are fine, in any order
  init(on system: Self.ActorSystem, with number: Int) {} // ✅ ok, other parameters are fine, in any order
  
  init(node: ClusterSystem) {} // ✅ ok, labels don't matter
  
  convenience init() {
    self.init(someGlobalSystem) {} // ✅ ok to delegate with default value, but generally a bad idea
  } 
}
```

These initializers are ill-formed since they are missing the necessary parameter:

```swift
distributed actor DA { 
  init(system: SomeActorSystem, too many: SomeActorSystem) { ... }
  // ❌ error: designated distributed actor initializer 'init(transport:too:)' must accept exactly one ActorTransport parameter, found 2
  
  init(x: String) {}
  // ❌ error: designated distributed actor initializer 'init(x:)' is missing required ActorTransport parameter
}
```

To learn more about the specific restrictions, please refer to [SE-0336: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md).

Now in the next sections, we will explore in depth why this parameter was necessary to enforce to begin with.

#### Initializing `actorSystem` and `id` properties

The first reason is that we need to initialize the `actorSystem` stored property.

This is also necessary for any distributed actor's default initializer, which is synthesized when no user-defined initializer is provided. It is similar to the no-argument default initializer that is synthesized for classes and actors:

```swift
// user defined:
distributed actor DA {}

// ~~~ synthesized ~~~
distributed actor DA: DistributedActor { 
  init(system: Self.ActorSystem) { ... }
}
// ~~~ end of synthesized ~~~
```

The `system` argument is necessary to initialize the actors synthesized `id` and `actorSystem` properties. Let us now discuss how this is done.

The `actorSystem` property is the simpler one of the two, because we just need to store the passed in `system` into the local property. The compiler synthesizes code that does this in any designated initializer of distributed actors:

```swift
distributed actor DA {
  // let id: ID
  // let actorSystem: ActorSystem
  
  init(system: Self.ActorSystem) {
    // ~~~ synthesized ~~~
    self.actorSystem = system
    // ... 
    // ~~~ end of synthesized ~~~
  }
}
```

The initialization of the `id` property is a little more involved. We need to communicate with the `system` used to initialize the distributed actor, for it is the `ActorSystem` that allocates and manages identifiers. In order to obtain a fresh `ID` for the actor being initialized, we need to call `system`'s `assignID` method. This is done before any user-defined code is allowed to run in the actors designated initializer, like this:

```swift
distributed actor DA { 
  let number: Int
  // user defined:
  init(system: ActorSystem) {
    self.number = 42
  }
  
  // ~~~ synthesized ~~~
  init(system: ActorSystem) {
    // ~~ injected property initialization ~~
    self.actorSystem = system
    self.id = system.assignID(Self.self)
    // ~~ end of injected property initialization ~~

    // user-defined code follows...
    self.number = 42
    
    // ...
  }
  // ~~~ end of synthesized ~~~
}
```

### Ready-ing Distributed Actors

So far, the initialization process was fairly straight forward. We only needed to find a way to initialize the stored properties, and that's it. There is one more step though that is necessary to make distributed actors work: "ready-ing" the actor.

As the actor becomes fully initialized, the type system allows escaping its `self` through method calls or closures. This can lead to unsafe access patterns, but those are discussed and prevented by [SE-0327: On Actor Initialization](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md). Distributed actor initializers are subject to the same rules as outlined in that proposal. In addition to that, in order for distributed actors to be able to escape through distributed calls made during their initializer, a system must carefully manage IDs that have been assigned but are not "ready" yet.

Readying is done automatically by code synthesized into the distributed actor's non-delegating initializers, and takes the shape of an `self.actorSystem.actorReady(self)` call, injected at appropriate spots in the initializer. This call is necessary in order for the distributed actor system to be able to resolve an incoming `ID` (that it knows, since it assigned it) to a specific distributed actor instance (which it does not know, until `actorReady` is called on the system). This means that there is a state between the `assignID` and `actorReady` calls, during which the actor system cannot yet properly resolve the actor. 

In this section we will discuss the exact semantics of readying actors, how systems must implement and handle these `actorReady` calls, and where exactly they are invoked during from any distributed actor initializer.

> **Note:** It is highly recommended to read [SE-0327: On Actor Initialization](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md) before reading the remainder of the initializer discussion of this proposal. As the synchronous and asynchronous rules about initialization directly fall out of SE-0327's initializer isolation rules. The two proposals have been developed in tandem, and we made sure they mesh well together.

Where the `system.actorReady(self)` call is performed depends on whether the initializer is asynchronous. Specifically, these locations fall out of the rules where any such user-defined code would be permitted, and what changes it causes to `self` isolation. 

The `actorReady` call in distributed actors is made:

- at the _end_ of **synchronous non-delegating initializers**, or
- where the actor becomes fully-initialized (and the initializer implicitly hops to the actors' execution context) in **asynchronous non-delegating initializers**.

The following snippet illustrates a **synchronous initializer**, and where the ready call is injected in it:

```swift
distributed actor DA { 
  let number: Int

  init(sync system: ActorSystem) {
    // << self.actorSystem = system
    // << self.id = system.assignID(Self.self)
    self.number = 42
    // ~~~ become fully initialized ~~~
    // cannot escape `self` without changing initializer semantics
    // since it is a synchronous one (as dictated by SE-0327)
    print("Initialized \(\(self.id))")
    // << system.actorReady(self)
  }
}
```

The next snippet illustrates an **asynchronous initializer**, for the same actor:

```swift
distributed actor DA { 
  let number: Int

  init(async system: ActorSystem) async {
    // << self.actorSystem = system
    // << self.id = system.assignID(Self.self)
    self.number = 42
    // ~~~ become fully initialized ~~~
    // << <hop to self executor>
    // << system.actorReady(self)
    print("Initialized \(\(self.id))")
  }
}
```

The location where the ready call is injected for asynchronous initializer follows the same logic as the implicit hop-to-self injection that is defined by the actor initialization proposal mentioned earlier. i.e. it is done whenever the actor becomes _fully initialized_:

```swift
distributed actor DA {
  let number: Int
  init(number: Int, system: ActorSystem) async {
    // << self.actorSystem = system
    // << self.id = system.assignID(Self.self)
    if number % 2 == 0 {
      print("even")
      self.number = number
      // ~~~ become fully initialized ~~~
      // << <hop to self executor>
      // << system.actorReady(self)
    } else {
      print("odd")
      self.number = number
      // ~~~ become fully initialized ~~~
      // << <hop to self executor>
      // << system.actorReady(self)
    }  
  }
}
```

Special care needs to be taken about the distributed actor and actor system interaction in the time between the `assignID` and `actorReady` calls, because during this time the system is unable to *deliver* an invocation to the target actor. However, it is always able to recognize that an ID is known, but just not ready yet – the system did create and assign the ID after all. 

> We suggest using the qualifier "**reserved**" for identifiers between the point in time as they have been assigned, but their respective actors have not become "ready" yet. 
>
> A reserved identifier is an important concept, because we need to make sure to never assign the same identity to two different actors -- as it would lead to ambiguity as to which actor an incoming message is designated to.

This matters even more in **synchronous** distributed actor initializers, because the ready call is performed at the end of the initializer, and before that users are allowed to e.g. escape the `self` into a `Task` and potentially invoke a remote distributed method passing `self` to it, like this:

```swift
init(greeter: Greeter, system: ActorSystem) { // synchronous (!)
 // ...
 // << id = system.assignID(Self.self)
 // ~~~ become fully initialized ~~~
 Task { 
   try await greeter.hello(from: self)
 }
 // ... 
 // ...
 // ?? what if init "never" returns"
 // ... 
 // ... 
 // << system.actorReady(self)
}
```

 In the above scenario, there exist a timespan between offering `self` to another distributed actor and the actor itself becoming ready. If the remote `Greeter` were to call a distributed method on that "escaped self" and the originating system would receive that message before the `system.actorReady(self)` call is invoked, the system would be unable to deliver the invocation. 

This thankfully is not a problem unknown to distributed actor runtimes, and can be solved by buffering messages to recipients that have been assigned an ID but are not yet ready. Since this is a synchronous initializer we are talking about, this situation cannot lead to a deadlock since the initializer will continue running and we are unable to suspend it (because it is not async). In theory, a synchronous distributed actor initializer that *never returned* is problematic here, because it will never become ready, but this simply isn't the nature of how initializers should be used, and after careful consideration we decided this is a fair tradeoff. 

Never-returning *synchronous* initializers, which escape self to other distributed actors, may not be able to receive incoming distributed calls. The problem does not necessarily have to lead to deadlocks or never-resumed tasks because remote calls are often associated with deadlines which would avoid an infinite wait. The above situation though quite an edge case though, and the other rules about actor isolation and thread-safety of initializers we feel more than make up for this one weird situation. 

This problem does not manifest with asynchronous initializers, so this is another option availablet to avoid this issue.

#### Ready-ing Distributed Actors, exactly once

Another interesting case the synthesis in asynchronous initializers needs to take care of is triggering the `actorReady` call only *once*, as the actor first becomes fully initialized. This issue does not manifest itself in simple init implementations, however the following snippet does a good job showing an example of where it can manifest:

```swift
distributed actor DA {
  var int: Int
  init(system: ActorSystem) async {
    var loops = 10
    while loops > 0 {
      self.int = loops
      // ~ AT THE FIRST ITERATION ~
      // ~ become fully initialized ~
      // ...
      loops -= 1
    }
  }
}
```

This actor performs a loop during which it assigns values to `self.int`, the actor becomes fully initialized the first time this loop runs. 

We need to emit the `actorReady(self)` call, only once, as the actor becomes initialized, and we should not repeatedly call the actor system's `actorReady` method which would force system developers into weirdly defensive implementations of this method. Tankfully, this is possible to track in the compiler, and we can emit the ready call only once, based on internal initialization marking mechanisms (that store specific bits for every initialized field). 

> This same mechanism of "do something only once, at full initialization time" is also used to emit "hop to self" in normal actors, where the actor's execution hops to its dedicated executor once it has become fully initialized, but does not need to hop any of the subsequent times in the loop.

The synthesized (pseudo)-code therefore is something like this:

```swift
distributed actor DA {
  var int: Int
  init(system: ActorSystem) {
    // initialized properties bitmap: INITMAP
    // << self.actorSystem = system
    // MARK INITMAP[actorSystem] = INITIALIZED
    // << self.id = system.assignID(Self.self)
    // MARK INITMAP[id] = INITIALIZED
    
    var loops = 10
    while loops > 0 {
      self.int = loops
      // MARK INITMAP[int] = INITIALIZED
      // INITMAP: FULLY INITIALIZED
      //
      // IF INITMAP[IMPLICIT_HOP_TO_SELF] != DONE {
      //   << <hop to self executor>
      //   MARK INITMAP[IMPLICIT_HOP_TO_SELF] = DONE
      // }
      //
      // IF INITMAP[ACTOR_READY] != INITIALIZED {
      //   << system.actorReady(self)
      //   MARK INITMAP[ACTOR_READY] = INITIALIZED
      // }
      
      loops -= 1
    }
  }
}
```

Using this technique we are able to emit the ready call only once, and put off the complexity of dealing with repeated ready calls from distributed actor system library authors. The same technique is used to avoid hopping to the self executor 10 times, but instead the implicit hop-to-self is only performed once, on the initial iteration where the actor became fully initialized.

Things get more complicated in face of failable as well as throwing initializers. Specifically, because we not only have to assign identities, we also need to ensure that they are resigned when the distributed actor is deallocated. In the simple, non-throwing initialization case this is simply done in the distributed actor's `deinit`, however some initialization semantics make this more complicated.

### Resigning Distributed Actor IDs

In addition to assigning `ID` instances to specific actors as they get created, we must also *always* ensure the `ID`s assigned are resigned as their owning actors get destroyed. 

Resigning an `ID` allows the actor system to release any resources it might have held in association with this actor. Most often this means removing it from some internal lookup table that was used to implement the `resolve(ID) -> Self` method of a distributed actor, but it could also imply tearing down connections, clearing caches, or even dropping any in-flight messages addressed to the now terminated actor.

In the simple case this is trivially solved by deinitialization: we completely initialize the actor, and once it deinitializes, we invoke resign the ID in the actor's deinitializer:

```swift
deinit {
  // << self.actorSystem.resignID(self.id)
}
```

This also works with user defined deinitializers, where the resign call is injected as the *first* operation in the deinitializer:

```swift
// user-defined deinit
deinit {
  // << self.actorSystem.resignID(self.id)
  print("deinit \(self.id)")
}
```

Things get more complicated once we take into account the existence of *failable* and *throwing* initializers. Existing Swift semantics around those types of initializers, and their effect on if and when `deinit` is invoked mean that we need to take special care of them.

Let us first discuss [failable initializers](https://docs.swift.org/swift-book/LanguageGuide/Initialization.html#ID224), i.e. initializers which are allowed to assign `nil` during their initialization. As actors allow such initializers, distributed actors should too, in order to make the friction of moving from local-only to distributed actors as small as possible.

```swift
distributed actor DA {
  var int: Int
  
  init?(int: Int, system: ActorSystem) [async] {
    // ... 
    if int < 10 {
      // ...
      // << self.actorSystem.resignID(self.id)
      return nil
    }
    self.int = int
    // ~~~ become fully initialized ~~~
    // << self.actorSystem.actorReady(self)
  }
  
  // deinit {
  //   << self.actorSystem.resignID(self.id)
  // }
}
```

Due to rules about actor and class init/deinit, when we `return nil` from a failable initializer, its deinitializer *does not run* (!). Because of this, we cannot rely on the deinit to resign the ID as we'd leave an un-used, but still registered identity hanging in the actor system, and the `resignID` is injected just before the "failing return" from such initializer. This is done transparently, and neither distributed actor developers nor actor system developers need to worry about this: the ID is always resigned properly.

> This does mean that `resignID` may be called without `actorReady` having ever been called! The system should react to this as it would to any usual resignID and free any resources associated with the identifier.

Next, we need to discuss *throwing* initializers, and their multiple paths of execution. Again, rules about class and actor deinitialization, are tightly related to whether or not a types deinit will be executed or not, so let us analyse the following example:

```swift
distributed actor DA {
  var int: Int
  
  init(int: Int, system: ActorSystem) throws {
    // << self.id = system.assignID(Self.self)
    // ...
    if int <= 1 {
      // ...
      // << self.actorSystem.resignID(self.id)
      throw Boom() // [1]
    }
    
    if int <= 2 {
      self.int = int
      // ~ become fully initialized ~
      throw Boom() // [2]
    }
    
    throw Boom() // Boom for good measure... (same as [2] though)
    // theoretically, the ready call is inserted at the end of the init:
    // << system.actorReady(self)
  }
  
  init(int: Int, system: ActorSystem) async throws {
    // << self.id = system.assignID(Self.self)
    // ...
    if int <= 1 {
      // ...
      // << self.actorSystem.resignID(self.id)
      throw Boom() // [1]
    }
    
    if int <= 2 {
      self.int = int
      // ~ become fully initialized ~
      // << system.actorReady(self)
      throw Boom() // [2]
    }
    
    throw Boom() // Boom for good measure... (same as [2] though)
  }
  
  // deinit {
  //   << self.actorSystem.resignID(self.id)
  // }
}
```

The actor shown above both has state that it needs to initialize, and it is going to throw. It will trow either before becoming fully initialized `[1]`, or after it has initialized all of its stored properties `[2]`. Swift handles those two executions differently. Only a fully initialized reference type's `deinit` is going to be executed. This means that if the init throws at `[1]` we need to inject a `resignID` call there, while if it throws after becoming fully initialized, e.g. on line `[2]` we do not need to inject the `resignID` call, because the actor's `deinit` along with the injected-there `resignID` will be executed instead.

Both the synchronous and asynchronous initializers deal with this situation well, because the resign call must be paired with the assign, and if the actor was called ready before it calls `resignID` does not really impact the resignation logic.

To summarize, the following are rules that distributed actor system implementors can rely on:

- `assignID(_:)` will be called exactly-once, at the very beginning of the initialization of a distributed actor associated with the system,
- `actorReady(_:)` will be called exactly-once, after all other properties of the distributed actor have been initialized, and it is ready to receive messages from other peers. By construction, it will also always be called after `assignID(_:)`.
- `resignID(_:)` will be called exactly-once as the actor becomes deinitialized, or fails to finish its initialization. This call will always be made after an `assignID(_:)` call. While there may be ongoing racy calls to the transport as the actor invokes this method, any such calls after `resignID(_:)` was invoked, should be handled as if actor never existed to begin with.

Note that the system usually should not hold the actor with a strong reference, as doing so inhibits its ability to deinit until the system lets go of it.

### Resolving Distributed Actors

Every distributed actor type has a static "resolve" method with the following signature:

```swift
extension DistributedActor { 
  public static func resolve(id: Self.ID, using system: Self.ActorSystem) throws -> Self { 
    ...
  }
}
```

This method will return a distributed actor reference, or throw when the actor system is unable to resolve the reference. 

The `resolve(id:using:)` method on distributed actors is an interesting case of the Swift runtime collaborating with the `DistributedActorSystem`. The Swift runtime implements this method as calling the passed-in actor system to resolve the ID, and if the system claims that this is a _remote_ reference, the Swift runtime will allocate a _remote_ distributed actor reference, sometimes called a "proxy" instance. 

Its implementation can be thought of as follows:

```swift
extension DistributedActor {
  // simplified implementation
  static func resolve(id: Self.ID, using system: ActorSystem) throws -> Self { 
    switch try system.resolve(id: id, as: Self.self) { 
      case .some(let localInstance): 
        return localInstance
      case nil: 
        return <<make proxy instance of type Self>>(id: id, system: system)
    }
  }
}
```

Specifically, this calls into the `ActorSystem`'s `resolve(id:as:)` method which has a slightly different signature than the one defined on actors, specifically it can return `nil` to signal the instance is not found in this actor system, but we're able to proxy it. 

> The **result** of `resolve(id:using:)` may be a **local instance** of a distributed actor, or a **reference to a remote** distributed actor.

The resolve implementation should be fast, and should be non-blocking. Specifically it should *not* attempt to contact the remote peer to confirm whether this actor really exists or not. Systems should blindly resolve remote identifiers assuming the remote peer will be able to handle them. Some systems may after all spin up actor instances lazily, upon the first message sent to them etc.

Allocating the remote reference is implemented by the Swift runtime, by creating a fixed-size object that serves only the purpose of proxying calls into the `system.remoteCall`. The `_isDistributedRemoteActor()` function always returns `true` for such a reference. 

If the system entirely fails to resolve the id, e.g. because it was ill-formed or the system is unable to handle proxies for the given id, it must throw with an error conforming to `DistribtuedActorSystemError`, rather than returning `nil`. An example implementation could look something like this:

```swift
final class ClusterSystem: DistributedActorSystem { 
  private let lock: Lock
  private var localActors: [ActorID: AnyWeaklyHeldDistributedActor] // stored into during actorReady
  
  // example implementation; more sophisticated ones can exist, but boil down to the same idea
  func resolve<ID, Act>(id: ID, as actorType: Act.Type)
      throws -> Act? where Act: DistributedActor, 
                           Act.ID == Self.ActorID,
                           Act.SerializationRequirement == Self.SerializationRequirement {
    if validate(id) == .illegal { 
      throw IllegalActorIDError(id)
    }
        
    return lock.synchronized {
      guard let known = self.localActors[id] else {
        return nil // not local actor, but we can allocate a remote reference for it
      }
      
      return try known.as(Act.self) // known managed local instance
    }
  }
}
```

The types work out correctly since it is the specific actor system that has _assigned_ the `ID`, and stored the specific distributed actor instance for the specific `ID`. 

> **Note:** Errors thrown by actor systems should conform to the `protocol DistributedActorSystemError: Error {}` protocol. While it is just a marker protocol, but it helps end users understand where an error originated.

Attempting to ready using one type, and resolve using another will cause a throw to happen during the resolve, e.g. like this:

```swift
distributed actor One {} 
distributed actor Two {} 

let one = One(system: cluster)
try Two.resolve(id: one.id, using: cluster) 
// throws: DistributedActorResolveError.wrongType(found: One) // system specific error
```

This is only the case for local instances though. For remote instances, by design, the local actor system does not track any information about them and as any remote call can fail anyway, the failures surface at call-site (as the remote recipient will fail to be resolved).

### Invoking Distributed Methods

Invoking a distributed method (or distributed computed property) involves a number of steps that occur on two "sides" of the call. 

The local/remote wording which works well with actors in general can get slightly confusing here, because every a call made "locally" on a "remote reference", actually results in a "local" invocation execution on the "remote system". Instead, we will be using the terms "**sender**" and "**recipient**" to better explain which side of a distributed call we are focusing on.

As was shown earlier, invoking a `distributed func` essentially can follow one of two execution paths:

- if the distributed actor instance was actually **local**:
  - the call is made directly, as if it was a plain-old local-only `actor`
- if the distributed actor was **remote**:
  - the call must be transformed into an invocation that will be offered to the `system.remoteCall(...)` method to execute

The first case is governed by normal actor execution rules; There might be a execution context switch onto the actor's executor, and the actor will receive and execute the method call as usual.

In this section, we will explain all the steps invokved in the second, remote, case of a distributed method call. The invocations will be using two very important types that represent the encoding and decoding side of such distributed method invocations. 

The full listing of those types is presented below:

```swift
protocol DistributedActorSystem: ... { 
  // ... 
  associatedtype InvocationEncoder: DistributedTargetInvocationEncoder
  associatedtype InvocationDecoder: DistributedTargetInvocationDecoder

  func makeInvocationEncoder() -> InvocationEncoder  
}
```



```swift
public protocol DistributedTargetInvocationEncoder {
  associatedtype SerializationRequirement

  /// Record a type of generic substitution which is necessary to invoke a generic distributed invocation target.
  /// 
  /// The arguments must be encoded order-preserving, and once `decodeGenericSubstitutions`
  /// is called, the substitutions must be returned in the same order in which they were recorded.
  mutating func recordGenericSubstitution<T>(_ type: T.Type) throws

  /// Record an argument of `Argument` type in this arguments storage.
  ///
  /// Ad-hoc requirement.
  mutating func recordArgument<Argument: SerializationRequirement>(_ argument: Argument) throws

  /// Record the error type thrown by the distributed invocation target.
  /// If the target does not throw, this method will not be called and the error type can be assumed `Never`.
  ///
  /// Ad-hoc requirement.
  mutating func recordErrorType<E: Error>(_ type: E.Type) throws

  /// Record the return type of the distributed method.
  /// If the target does not return any specific value, this method will not be called and the return type can be assumed `Void`.
  ///
  /// Ad-hoc requirement.
  mutating func recordReturnType<R: SerializationRequirement>(_ type: R.Type) throws

  /// All values and types have been recorded. 
  /// Optionally "finalize" the recording, if necessary.
  mutating func doneRecording() throws
}
```



```swift
public protocol DistributedTargetInvocationDecoder {
  associatedtype SerializationRequirement

  func decodeGenericSubstitutions() throws -> [Any.Type]

  /// Ad-hoc protocol requirement
  ///
  /// Attempt to decode the next argument from the underlying buffers into pre-allocated storage
  /// pointed at by 'pointer'.
  ///
  /// This method should throw if it has no more arguments available, if decoding the argument failed,
  /// or, optionally, if the argument type we're trying to decode does not match the stored type.
  ///
  /// The result of the decoding operation must be stored into the provided 'pointer' rather than
  /// returning a value. This pattern allows the runtime to use a heavily optimized, pre-allocated
  /// buffer for all the arguments and their expected types. The 'pointer' passed here is a pointer
  /// to a "slot" in that pre-allocated buffer. That buffer will then be passed to a thunk that
  /// performs the actual distributed (local) instance method invocation.
  mutating func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument

  func decodeErrorType() throws -> Any.Type?

  func decodeReturnType() throws -> Any.Type?
}
```



#### Sender: Invoking a distributed method

Calls of a distributed method on a remote distributed actor reference need to be turned into a runtime introspectable representation which will be passed to the `remoteCall` method of a specific distributed actor system implementation.

In this section, we'll see what happens for the following `greet(name:)` distributed method call:

```swift
// distributed func greet(name: String) -> String { ... }

try await greeter.greet(name: "Alice")
```

Such invocation is actually calling a "distributed thunk" for the method, rather than the method directly. The "distributed thunk" is synthesized by the compiler for every `distributed func`, and can be illustrated by the following snippet:

```swift
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ SYNTHESIZED ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
extension Greeter {
  // synthesized; not user-accessible thunk for: greet(name: String) -> String
  nonisolated func greet_$distributedThunk(name: String) async throws -> String {
    guard _isDistributedRemoteActor(self) else {
      // the local func was not throwing, but since we're nonisolated in the thunk,
      // we must hop to the target actor here, meaning the 'await' is always necessary.
      return await self.greet(name: name) 
    }

    // [1] prepare the invocation object:
    var invocation = self.actorSystem.makeInvocationEncoder()
    
    // [1.1] if method has generic parameters, record substitutions
    // e.g. for func generic<A, B>(a: A, b: B) we would get two substitutions,
    // for the generic parameters A and B:
    //
    // << invocation.recordGenericSubstitution(<runtime type of a>)
    // << invocation.recordGenericSubstitution(<runtime type of b>)
    
    // [1.2] for each argument, synthesize a specialized recordArgument call:
    try invocation.recordArgument(name)
      
    // [1.3] if the target was throwing, record Error.self, 
    // otherwise do not invoke recordErrorType at all.
    //
    // << try invocation.recordErrorType(Error.self)
      
    // [1.4] we also record the return type; it may or may not be necessary to
    // transmit over the wire but if necessary, the system may choose to do so.
    // 
    // This call is not made when the return type is Void.
    try invocation.recordReturnType(String.self)
      
    // [1.5] done recording arguments
    try invocation.doneRecording()
      
    // [2] invoke the `remoteCall` method of the actor system
    return try await self.actorSystem.remoteCall(
      on: self,
      target: RemoteCallTarget(...),
      invocation: invocation,
      throwing: Never.self, // the target func was not throwing
      returning: String.self
    )
  }
}
```

The synthesized thunk is always throwing and asynchronous, this is correct because it is only invoked in situations where we might end up calling the `actorSystem.remoteCall(...)` method, which by necessity is asynchronous and throwing.

The thunk is `nonisolated` because it is a method that can actually run on a *remote* instance, and as such is not allowed to touch any other state than other nonisolated stored properties. This is specifically designed such that the thunk (and actor system are able to access the `id` of the actor (and the `actorSystem` property itself) which is necessary to perform the actual remote message send.

The `nonisolated` aspect of the method has another important role to play: if this invocation happens to be  on a local distributed actor, we do not want to "hop" executors twice, but only once we have confirmed the actor is local and hop to it using the same semantics as we would when performing a normal actor method call. If the instance was remote, we don't need to suspend early at all, and we leave it to the `ActorSystem` to decide when exactly the task will suspend. For example, the system may only suspend the call after it has sent the bytes synchronously over some IPC channel etc. Those semantics when to suspend are highly dependent on the specific underlying transport, and thanks to this approach we allow system implementations to do the right thing, whatever that might be: they can suspend early, late, or even not at all if the call is known to be impossible to succeed.

Note that the compiler will pass the `self` of the distributed *known-to-be-remote* actor to the remoteCall method on the actor system. This allows the system to check the passed type for any potential, future, customization points that the actor may declare as static properties, and/or conformances affecting how a message shall be serialized or delivered. It is impossible for the system to access any of that actor's state, because it is remote after all. The one piece of state it will need to access though is the actor's `id` because that is signifying the *recipient* of the call.

The thunk creates the `invocation` container `[1]` into which it records all arguments. Note that  all these APIs are using only concrete types, so we never pay for any existential wrapping or other indirections. The `record...` calls are expected to serialize the values, using any mechanism they want to, and thanks to the type performing the recording being provided by the specific `ActorSystem`, it also knows that it can rely on the arguments to conform to the system's `SerializationRequirement`.

The first step in the thunk is to record any "generic substitutions" `[1.1] ` if they are necessary. This makes it possible for remote calls to support generic arguments, and even generic distributed actors. The calls are not emitted for calls where the generic context is not necessary for the invocation. For a generic method however, the runtime will invoke the `recordGenericTypeSubstitution` with _concrete_ types of the generic context that is necessary to perform the call. For example, if we declared a generic `echo` method like this:

```swift
distributed func echo<T: SerializationRequirement>(_ value: T) -> T
```

and call it like this:

```swift
try await greeter.echo("Echo!") // typechecks ok; String: SerializationRequirement
```

The swift runtime would generate the following call:

````swift
try invocation.recordGenericTypeSubstitution(String.self)
````

This method is implemented by a distributed actor system library, and can use this information to double check this type against an allow-list of types allowed to be transmitted over the wire, and then store and send it over to the recipient such that it knows what type to decode the argument as.

Next, the runtime will record all arguments of the invocation `[1.2]`. This is done in a series of `recordArgument` calls, which are made in declaration order of the parameters of the function. This method will never be invoked if the target is a distributed computed property. 

As the `recordArgument(_:)` method is generic over the argument type (`<Argument: SerializationRequirement>`), and requires the argument to conform to `SerializationRequirement` (which in turn was enforced at compile time by [SE-0336](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md)), the actor system implementation will have an easy time to serialize or validate this argument. For example, if the `SerializationRequirement` was codable -- this is where one could invoke `SomeEncoder().encode(argument)` because `Argument` is a concrete type conforming to `Codable`!

Finally, the specific error `[1.3]` and return types `[1.4]` are also recorded. If the function is not throwing, `recordErrorType` is not called. Likewise, if the return type is `Void` the `recordReturnType` is not called. 

Recording the error type is mostly future-proofing and currently will only ever be invoked with the `Error.self` or not at all. It allows informing the system if a throw from the remote side is to be expected, and technically, if Swift were to gain typed throws this method could record specific expected error types as well - although we have no plans with regards to typed throws at this point in time. 

The last encoder call is `remoteCall()` is made, to signal to the invocation encoder that no further record calls will be made. This is useful since with the optional nature of some of the calls, it would be difficult to know for a system implementation when the invocation is fully constructed. Operations which may want to be delayed until completion could include serialization. de-duplicating values or similar operations which benefit from seeing the whole constructed invocation state in the encoder.

Lastly, the populated encoder, along with additional type and function identifying information is passed to the `remoteCall`, or `remoteCallVoid` method on the actor system which should actually perform the message request/response interaction with the remote actor.

#### Sender: Serializing and Sending Invocations

The next step in making a remote call is serializing a representation of the distributed method (or computed property) invocation. This is done through a series of compiler, runtime, and distributed actor system interactions. These interactions are designed to be highly efficient and customizable. Thanks to the `DistributedTargetInvocationEncoder`, we are able to never resort to existential boxing of values, allow serializers to manage and directly write into their destination buffers (i.e. allowing for zero copies to be performed between the message serialization and the underlying networking layer), and more. 

Let us consider a `ClusterSystem` that will use `Codable` and send messages over the network. Most systems will need to form some kind of "Envelope" (easy to remember as: "the thing that contains the **message** and also has knowledge of the **recipient**"). For the purpose of this proposal, we'll define a a `WireEnvelope` and use it in the next snippets to showcase how a typical actor system would work with it. This type is not pre-defined or required by this proposal, but it is something implementations will frequently do on their own:

```swift
// !! ClusterSystem or WireEnvelope are NOT part of the proposal, but serves as illustration how actor systems might !!
// !! implement the necessary pieces of the DistributedActorSystem protocol.                                         !!

final struct ClusterSystem: DistributedActorSystem { 
  // ...
  typealias SerializationRequirement = Codable
  typealias InvocationEncoder = ClusterTargetInvocationEncoder
  typealias InvocationDecoder = ClusterTargetInvocationDecoder
  
  // Just an example, we can implement this more efficiently if we wanted to.
  private struct WireEnvelope: Codable, Sendable { 
    var recipientID: ClusterSystem.ActorID // is Codable
    
    /// Mangled method/property identifier, e.g. in a mangled format
    var identifier: String
    
    // Type substitutions matter only for distributed methods which use generics:
    var genericSubstitutions: [String]
    
    // For illustration purposes and simplicity of code snippets we use '[Data]' here, 
    // but real implementations can be much more efficient here -- packing all the data into exact 
    // byte buffer that will be passed to the networking layer etc.
    var arguments: [Data] // example is using Data, because that's what Codable coders use
    
    // Metadata can be used by swift-distributed-tracing, or other instrumentations to carry extra information:
    var metadata: [String: [Data]] // additional metadata, such as trace-ids etc.
  }
}
```

Note that `method` property is enough to identify the target of the call, we do not need to carry any extra type information explicitly in the call. The method identifier is sufficient to resolve the target method on the recipient, however in order to support generic distributed methods, we need to carry additional (mangled) type information for any of the generic parameters of this specific method invocation. Thankfully, these are readily provided to us by the Swift runtime, so we'll only need to store and send them over.

> **Note:** An implementation may choose to define any shape of "envelope" (or none at all) that suits its needs. It may choose to transport mangled names of involved types for validation purposes, or choose to not transfer them at all and impose other limitations on the system and its users for the sake of efficiency. 
>
> While advanced implementations may apply compression and other techniques to minimize the overhead of these envelopes - this is a deep topic by itself, and we won't be going in depth on it in this proposal - rest assured though, we have focused on making different kinds of implementations possible with this approach.

Next, we will discuss how the `InvocationEncoder` can be implemented in order to create such `WireEnvelope`.

> Note on ad-hoc requirements: Some of the protocol requirements on the encoder as well as actor system protocols are so-called "ad-hoc" requirements. This means that they are not directly expressed in Swift source, but instead the compiler is aware of the signatures and specifically enforces that a type conforming to such protocol implements these special methods. 
>
> Specifically, methods which fall into this category are functions which use the `SerializationRequirement` as generic type requirement. This is currently not expressible in plain Swift, due to limitations in the type system which are difficult to resolve immediately, but in time as this could become implementable these requirements could become normal protocol requirements. 
>
> This tradeoff was discussed at length and we believe it is worth taking, because it allows us to avoid numerous un-necessary type-casts, both inside the runtime as well as actor system implementations. It also allows us to avoid any existential boxing  and thus lessens the allocation footprint of making remote calls which is an important aspect of the design and use cases we are targeting.

The following listing illustrates how one _could_ implement a `DistributedTargetInvocationEncoder`:

```swift
extension ClusterSystem { 
  
  // typealias InvocationEncoder = ClusterTargetInvocationEncoder
  func makeInvocationEncoder() -> Self.InvocationEncoder {
    return ClusterTargetInvocation(system: system)
  }
}
  
struct ClusterTargetInvocationEncoder: DistributedTargetInvocationEncoder {
  typealias SerializationRequirement = ClusterSystem.SerializationRequirement
    
  let system: ClusterSystem
  var envelope: Envelope
    
    init(system: ClusterSystem) {
      self.system = system
      self.envelope = .init() // new "empty" envelope
    }

    /// The arguments must be encoded order-preserving, and once `decodeGenericSubstitutions`
    /// is called, the substitutions must be returned in the same order in which they were recorded.
    mutating func recordGenericSubstitution<T: SerializationRequirement>(type: T.Type) throws {
      // NOTE: we are showcasing a pretty simple implementation here... 
      //       advanced systems could use mangled type names or registered type IDs.
      envelope.genericSubstitutions.append(String(reflecting: T.self))
    }

    mutating func recordArgument<Argument: SerializationRequirement>(argument: Argument) throws {
      // in this implementation, we just encode the values one-by-one as we receive them:
      let argData = try system.encoder.encode(argument) // using whichever Encoder the system has configured
      envelope.arguments.append(argData)
    }
    
    mutating func recordErrorType<E: Error>(errorType: E.Type) throws {
      envelope.returnType = String(reflecting: returnType)
    }
    
    mutating func recordReturnType<R: SerializationRequirement>(returnType: R.Type) throws {
      envelope.returnType = String(reflecting: returnType)
    }

    /// Invoked when all the `record...` calls have been completed and the `DistributedTargetInvocation`
    /// will be passed off to the `remoteCall` to perform the remote call using this invocation representation.
    mutating func doneRecording() throws {
      // our impl does not need to do anything here
    }
  }
}
```

The above encoder is going to be called by the Swift runtime as was explained in the previous section.

Once that is complete, the runtime will pass the constructed `InvocationEncoder` to the `remoteCall`:

```swift
 extension ClusterSystem {
  // remoteCall is not a protocol requirement, however its signature is well known to the compiler,
  // and it will invoke the method. We also are guaranteed that the 'Res: Codable' requirement is correct,
  // since the type-system will enforce this conformance thanks to the type-level checks on distributed funcs.
  func remoteCall<Act, Err, Res>(
      on actor: Act,
      target: RemoteCallTarget,
      invocation: Self.InvocationEncoder,
      throwing: Err.Type,
      returning: Res.Type
  ) async throws -> Res
      where Act: DistributedActor,
            Act.ID == ActorID.
            Err: Error,
            Res: Self.SerializationRequirement {
    var envelope = invocation.envelope
    
    // [1] the recipient is transferred over the wire as its id
    envelope.recipient = recipient.id
      
    // [2] the method is a mangled identifier of the 'distributed func' (or var).
    //     In this system, we just use the mangled name, but we could do much better in the future.
    envelope.target = target.mangledName
      
    // [3] send the envelope over the wire and await the reply:
    let responseData = try await self.underlyingTransport.send(envelope, to: actor.id)

    // [4] decode the response from the response bytes
    // in our example system, we're using Codable as SerializationRequirement, 
    // so we can decode the response like this (and never need to cast `as? Codable` etc.):
    try self.someDecoder.decode(as: Res.self, from: data)
  }
}
```

The overall purpose of this `remoteCall` implementation is to create some form of message representation of the invocation and send it off to the remote node (or process) to receive and invoke the target method on the remote actor. 

In our example implementation, the `Invocation` already serialized the arguments and stored them in the `Envelope`, so the `remoteCall` only needs to add the information about the call recipient `[1]`, and the target (method or computed property) of the call `[2]`. In our example implementation, we just store the target's mangled name `[2]`, which is simple, but it has its challenges in regard to protocol evolution.

One notable issue that mangled names have is that any change in the method signature will result in not being able to resolve the target method anymore, we are very much aware of the issues this may cause to protocol evolution, and we lay out plans in [Future Directions](#future-directions) to improve the lookup mechanisms in ways that will even allow adding parameters (with default values), in wire (and ABI) compatible ways.

The final step is handing over the envelope containing the encoded arguments, recipient information etc. to the underlying transport mechanism `[3]`. The transport does not really have to concern itself with any of the specifics of the call, other than transmitting the bytes to the callee and the response data back. As we get the response data back, we have the concrete type of the expected response and can attempt to decode it `[4]`.

> Note on `remoteCallVoid`: One limitation in the current implementation approach is that a remote call signature cannot handle void returning methods, because of the `Res: SerializationRequirement` requirement on the method. 
>
> This will be possible to solve using the incoming [Variadic Generics](https://forums.swift.org/t/variadic-generics/54511) language feature that is being currently being worked on and pitched. With this feature, the return type could be represented as variadic generic and the `Void` return type would be modeled as "empty" tuple, whereas a value return would contain the specific type of the return, this way we would not violate the `Res: SerializationRequirement` when we needed to model `Void` calls.

#### Recipient: Receiving Invocations

On the remote side, there usually will be some receive loop or similar mechanism that is implemented in the transport layer of the actor system. In practice this often means binding a port and receiving TCP (or UDP) packets, applying some form of framing and eventually decoding the incoming message envelope.

Since the communication of the sending and receiving side is going to be implemented by the same type of transport and actor system, receiving the envelopes is straightforward: we know the wire protocol, and follow it to receive enough bytes to decode the `Envelope` which we sent a few sections above. 

This part does not have anything specific prescribed in the `DistributedActorSystem` protocol, it is up to every system to implement whichever transport mechanism works for it. While not a "real" snippet, this can be thought of a simple loop over incoming connections, like this:

```swift
// simplified pseudo code for illustration purposes
func receiveLoop(with node: Node) async throws {
  for try await envelopeData in connection(node).receiveEnvelope { 
    await self.receive(envelopeData)
  }
}
```

In a real server implementation we'd likely use a [Swift NIO](https://github.com/apple/swift-nio) ChannelPipeline to perform this networking, framing and emitting of `Envelope`s, but this is beyond the scope of what we need to explain in this proposal to get the general idea of how this is going to work.

#### Recipient: Deserializing incoming Invocations

Now that we have received all the bytes for one specific envelope, we need to perform a two-step deserialization on it. 

First, we'll need to decode the target identifier (e.g. method name, mangled method name, or some other form of target identifier), and the actor `ID` of the recipient. These are necessary to decode always, as we need to locate both the method and actor we're trying to invoke.

Next, the deserialization of the actual message representation of our invocation will take place. However, this is done lazily. Rather than just decoding the values and storing them somewhere in our system implementation, these will be requested by the Swift runtime when it is about to perform the method call. 

Before we dive deeper into this, let us visualize how this two-step process is intended to work, by looking at what might be a typical envelope format on the wire:

```c
+------------------------------- ENVELOPE --------------------------------------+
| +---------- HEADER --------++-------------------- MESSAGE ------------------+ |
| | target | recipient | ... || [ ... lazy decoded section: types, args ... ] | |
| +--------------------------++-----------------------------------------------+ | 
+-------------------------------------------------------------------------------+
```

We see that as we decode our wire envelope, we are able to get the header section, and all values contained within it eagerly and let the remaining slice of the buffer untouched. It will be consumed during performing of the invocation soon enough. The nice thing about this design is that we're still able to hold onto the actual buffer handed us from the networking library, and we never had to copy the buffer to our own local copies etc.

Next, we need to prepare for the decoding of the message section. This is done by implementing the remaining protocol requirements on the `ClusterTargetInvocation` type we defined earlier, as well as implementing a decoding iterator of type `DistributedTargetInvocationArgumentDecoder`, as shown below:

```swift
final class ClusterTargetInvocationDecoder: DistributedTargetInvocationDecoder {
  typealias SerializationRequirement = Codable
      
  let system: ClusterSystem
  var bytes: ByteBuffer

  mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
    let subCount = try self.bytes.readInt() 
    
    var subTypes: [Any.Type] = []
    for _ in 0..<subCount {
      let length = try self.bytes.readInt() // read the length of the next substitution
      let typeName = try self.bytes.readString(length: length)
      try subTypes.append(self.system.summonType(byName: typeName))
    }
    
    return subTypes
  }
  
  /// Attempt to decode the next argument from the underlying buffers into pre-allocated storage
  /// pointed at by 'pointer'.
  ///
  /// This method should throw if it has no more arguments available, if decoding the argument failed,
  /// or, optionally, if the argument type we're trying to decode does not match the stored type.
  ///
  /// The result of the decoding operation must be stored into the provided 'pointer' rather than
  /// returning a value. This pattern allows the runtime to use a heavily optimized, pre-allocated
  /// buffer for all the arguments and their expected types. The 'pointer' passed here is a pointer
  /// to a "slot" in that pre-allocated buffer. That buffer will then be passed to a thunk that
  /// performs the actual distributed (local) instance method invocation.
  mutating func decodeNext<Argument: SerializationRequirement>() throws {
    try nextDataLength = try bytes.readInt()
    let nextData = try bytes.readData(bytes: nextDataLength)
    // since we are guaranteed the values are Codable, so we can just invoke it:
    return try system.decoder.decode(as: Argument.self, from: bytes)
  }

  mutating func decodeErrorType() throws -> Any.Type? { 
    let length = try self.bytes.readInt() // read the length of the type
    guard length > 0 {
      return nil // we don't always transmit it, 0 length means "none"
    }
    let typeName = try self.bytes.readString(length: length)
    return try self.system.summonType(byName: typeName)
  }

  mutating func decodeReturnType() throws -> Any.Type? { 
    let length = try self.bytes.readInt() // read the length of the type
    guard length > 0 {
      return nil // we don't always transmit it, 0 length means "none"
    }
    let typeName = try self.bytes.readString(length: length)
    return try self.system.summonType(byName: typeName)
  }
}
```

The general idea here is that the `Invocation` is *lazy* in its decoding and just stores the remaining bytes of the envelope. All we need to do for now is to implement the Invocation in such way that it expects the decoding methods be invoked in the following order (which is the same as the order on the sending side):

- 0...1 invocation of `decodeGenericArguments`,
- 0...n invocations of `decoder.decodeNextArgument<Argument>`,
- 0...1 invocations of `decodeReturnType`,
- 0...1 invocations of `decodeErrorType`.

Decoding arguments is the most interesting here. This is another case where the compiler and Swift runtime enables us to implement things more easily. Since the `Argument` generic type of the `decodeNextArgument` is ensured to conform to the `SerializationRequirement`, actor system implementations can rely on this fact and have a simpler time implementing the decoding steps. For example, with `Codable` the decoding steps becomes a rather simple task of invoking the usual `Decoder` APIs.

This decoder must be prepared by the actor system and eventually passed to the `executeDistributedTarget` method which we'll discuss next. That, Swift runtime provided, function is the one which will be calling the `decode...` methods and will is able to ensure all the type requirements are actually met and form the correct generic method invocations.

> **Note:** This proposal does not include an implementation for the mentioned `summonType(byName:)` function, it is just one way systems may choose to implement these functions. Possible implementations include: registering all "trusted" types, using mangled names, or something else entirely. This proposal has no opinion about how these types are recovered from the transmitted values.

#### Recipient: Resolving the recipient actor instance

Now that we have prepared our `InvocationDecoder` we are ready to make the next step, and resolve the recipient actor which the invocation shall be made on. 

We already discussed how resolving actors works in [Resolving Distributed Actors](#resolving-distributed-actors), however in this section we can tie it into the real process of invoking the target function as well.

In the example we're following so far, the recipient resolution is simple because we have the recipient id available in the `Envelope.recipientID`, so we only need to resolve that using the system that is receiving the message:

```swift
guard let actor: any DistributedActor = try self.knownActors[envelope.recipientID] else {
  throw ClusterSystemError.unknownRecipient(envelope.recipientID)
}
```

This logic is the same as the internal implementation of the `resolve(id:as:)` method only that we don't have a need to validate the specific type of the actor - this will be handled by the Swift runtime in `executeDistributedTarget`'s implementation the target of the call which we'll explain in the next section.

#### Recipient: The `executeDistributedTarget` method

Invoking a distributed method is a tricky task, and involves a lot of type demangling, opening existential types, forming specific generic invocations and tightly managing all of that in order to avoid un-necessary heap allocations to pass the decoded arguments to the target function etc. After iterating over with multiple designs, we decided to expose a single `DistributedActorSystem.executeDistributedTarget` entry point which efficiently performs all the above operations. 

Thanks to abstracting the decoding logic into the `DistributedTargetInvocationDecoder` type, all deserialization can be made directly from the buffers that were received from the underlying network transport. The `executeDistributedTarget` method has no opinion about what serialization mechanism is used either, and any mechanism, be it `Codable` or other external serialization systems can be used. allowing distributed actor systems developers to implement whichever coding strategy they choose, potentially directly from the buffers obtained from the transport layer.

The `executeDistributedTarget` method is defined as:

```swift
extension DistributedActorSystem {
  /// Prepare and execute a call to the distributed function identified by the passed arguments,
  /// on the passed `actor`, and collect its results using the `ResultHandler`.
  ///
  /// This method encapsulates multiple steps that are invoked in executing a distributed function,
  /// into one very efficient implementation. The steps involved are:
  ///
  /// - looking up the distributed function based on its name
  /// - decoding, in an efficient manner, all arguments from the `Args` container into a well-typed representation
  /// - using that representation to perform the call on the target method
  ///
  /// The reason for this API using a `ResultHandler` rather than returning values directly,
  /// is that thanks to this approach it can avoid any existential boxing, and can serve the most
  /// latency sensitive-use-cases.
  func executeDistributedTarget<Act, ResultHandler>(
      on actor: Act,
      mangledName: String,
      invocation: Self.InvocationDecoder,
      handler: ResultHandler
  ) async throws where Act: DistributedActor,
                       Act.ID == ActorID,
                       ResultHandler: DistributedTargetInvocationResultHandler { 
    // implemented by the _Distributed library
  }
}
```

This method encapsulates all the difficult and hard to implement pieces of the target invocation, and it accepts the base actor the call should be performed on, along with a `DistributedTargetInvocationResultHandler`.

Rather than having the `executeDistributedTarget` method return an `Any` result, we use the result handler in order to efficiently, and type-safely provide the result value to the actor system library implementation. This technique is the same as we did with the `recordArgument` method before, and it allows us to provide the _specific_ type including its `SerializationRequirement` conformance making handling results much simpler, and without having to resort to any casts which can be unsafe if used wrongly, or have impact on runtime performance. 

The `DistributedTargetInvocationResultHandler` is defined as follows:

```swift
protocol DistributedTargetInvocationResultHandler {
  associatedtype SerializationRequirement
  
  func onReturn<Res>(value: Res) async throws
    where Res: SerializationRequirement
  func onThrow<Err>(error: Err) async throws 
    where Err: Error
}
```

In a way, the `onReturn`/`onThrow` methods can be thought of as the counterparts of the `recordArgument` calls on the sender side. We need to encode the result and send it _back_ to the sender after all. This is why providing the result value along with the appropriate SerializationRequirement conforming type is so important -- it makes sending back the reply to a call, as simple as encoding the argument of the call.

Errors must be handled by informing the sender about the failed call. This is in order to avoid senders waiting and waiting for a reply, and eventually triggering a timeout; rather, they should be informed as soon as possible that a call has failed. Treat an error the same way as you would a valid return in terms of sending the reply back. However it is not required to actually send back the actual error, as it may not be safe, or a good idea from a security and information exposure perspective, to send back entire errors. Instead, systems are encouraged to send back a reasonable amount of information about a failure, and e.g. optionally, only if the thrown error type is Codable and allow-listed to be sent over the wire, transport it directly.

#### Recipient: Executing the distributed target

Now that we have completed all the above steps, all building up to actually invoking the target of a remote call: it is finally time to do so, by calling the `executeDistributedTarget` method:

```swift
// inside recipient actor system
let envelope: IncomingEnvelope = // receive & decode ...
let recipient: DistributedActor = // resolve ...

let invocationDecoder = InvocationDecoder(system: self, bytes: envelope.bytes)

try await executeDistributedTarget(
  on: recipient, // target instance for the call
  mangledName: envelope.targetName, // target func/var for the call
  invocation: invocation // will be used to perform decoding arguments,
  handler: ClusterTargetInvocationResultHandler(system, envelope) // handles replying to the caller (omitted in proposal)
)
```

This call triggers all the decoding that we discussed earlier, and if any of the decoding, or distributed func/var resolution fails this call will throw. Otherwise, once all decoding has successfully been completed, the arguments are passed through the buffer to a distributed method accessor that actually performs the local method invocation. Once the method returns, its results are moved into the handler where the actor system takes over in order to send a reply to the remote caller - completing the remote call!

For sake of completeness, the listing below shows the **distributed method accessor thunk** that is synthesized by the compiler. The thunk is passed the memory buffer into which argument values have just been stored during the `decodeNextArgument` calls on the `Invocation`. The thunk unpacks the well-typed buffer that contains the method call arguments into local variables, and invokes the actual target, like this:

```swift
distributed actor DA {
  func myCompute(_ i: Int, _ s: String, _ d: Double) async throws -> String  { 
    "i:\(i), s:\(s), d:\(d)" 
  }
}

extension DA {
  // not user-accessible
  // compiler synthesized "distributed accessor thunk" for 'myCompute(_:_:_:) -> String'
  nonisolated func myComputeThunk(buffer: UnsafeMutableRawPointer, 
                                  result: UnsafeMutablePointer<String>) async throws {
    var offset = 0

    offset = MemoryLayout<Int8>.nextAlignedOffset(offset)
    let i = buffer.load(fromByteOffset: offset, as: Int8.self)
    offset += MemoryLayout<Int>.size
 
    offset = MemoryLayout<String>.nextAlignedOffset(offset)
    let s = buffer.load(fromByteOffset: offset, as: String.self)
    offset += MemoryLayout<String>.size

    offset = MemoryLayout<Double>.nextAlignedOffset(offset)
    let d = buffer.load(fromByteOffset: offset, as: Double.self)
    offset += MemoryLayout<Double>.size
  
    // Finally invoke the target method on the actual actor:
    let result = try await self.myCompute(i, s, d)
    result.initialize(result)
  }
}
```

As we can see, this thunk is "just" taking care of converting the heterogeneous parameters into the well typed counterparts, and finally performing a plain-old method invocation using those parameters.

The thunk again uses the indirect return, so we can avoid any kind of implicit existential boxing even on those layers. Errors are always returned indirectly, so we do not need to do it explicitly.

#### Recipient: Collecting result/error from the Invocation

Now that the distributed method has been invoked, it eventually returns or throws an error. 

Collecting the return (or error) value is also implemented using the `DistributedMethodInvocationHandler` we passed to the `executeDistributedTarget(...)` method. This is done for the same reason as parameters: we need a concrete type in order to efficiently pass the values to the actor system, so it can encode them without going through existential wrappers. As we cannot implement the `invoke()` method to be codable over the expected types -- we don't know them until we've looked up the actual method we were about to invoke (and apply generic substitutions to them).

The implementation could look as follows:

```swift
extension ExampleDistributedMethodInvocationHandler {
  func onReturn<Res: SerializationRequirement>(result: Res) throws {
    do {
      let replyData = system.encoder.encode(result)
      self.reply(replyData)
    } catch {
      self.replyError("Failed to encode reply: \(type(of: error))")
    }
  }
  
  func onError<Err: Error>(error: Err) {
    guard Err is Encodable else {
      // best effort error reporting just sends back the type string
      // we don't want to send back string repr since it could leak sensitive information
      self.replyError("\(Err.self)")
    }
    
    // ... if possible, `as?` cast to Encodable and return an actual error,
    //     but only if it is allow-listed, as we don't want to send arbitrary errors back.
  }
}
```

We omit the implementations of `replyError` and `reply` because they are more of the same patterns that we have already discussed here, and this is a proposal focused on illustrating the language feature, not a complete system implementation after all.

The general pattern here is the same as with decoding parameters, however in the opposite direction.

Once the `onError` or `onReturn` methods complete, the `executeDistributedTarget` method returns, and its caller knows the distributed request/response has completed – at least, as far as this peer is concerned. We omit the implementation of the `reply` and `replyError` methods that the actor system would implement here, because they are pretty much the same process as sending the request, except that the message must be sent as a response to a specific request, rather than target a specific actor and method. How this is achieved can differ wildly between transport implementations: some have built-in request/reply mechanisms, while others are uni-directional and rely on tagging replies with identifiers such as "this is a reply for request 123456".

## Future Work

### Variadic generics removing the need for `remoteCallVoid`

Once [variadic generics](https://forums.swift.org/t/variadic-generics/54511/2) are fully implemented, we will be able to remove the limitation that we cannot express the `remoteCall<..., Res: SerializationRequirement>(..., returning returnType: Res.Type)` function for the `Void` type, since it cannot always conform to `SerializationRequirement`.

With variadic generics it would be natural to conform an "empty tuple" to the `SerializationRequirement` and we'd this way be able to implement only a single method (`remoteCall`) rather than having to provide an additional special case implementation for `Void` return types.

### Stable names and more API evolution features

The default mangling scheme used for distributed methods is problematic for API evolution. Since distributed function identity is just its mangled name, it includes information about all of its parameters, and changing any of those pieces will make the function not resolve with the old identity anymore.

This makes it impossible to _add_ parameters in a wire-compatible way, once a signature is published. In some deployment scenarios this isn't a big problem, e.g. when distributed actors are used to communicate between an app and a daemon process that are deployed at the same time. However, when components of a cluster are deployed in a rolling deploy style, it gets harder to manage such things. One cannot just easily swap a single node, and keep calling the "new" node's code, but the rollout has to be painfully and carefully managed...

In order to solve this, we need to detach the *exact* function mangled name from the general concept of "the function I want to invoke", even if keep changing its signature in *compatible ways*. Interestingly, the same pattern emerges in ABI stable libraries, such as those shipping with the OS, developers today have to add new functions with "one more argument", like this:

```swift
public func f() {
  f(x: 0)
}

@available(macOS 13.0)
public func f(x: Int) {
  // new implementation
}
```

Instead, developers would want to be able to say this:

```swift
public func f(@available(macOS 13.0) x: Int = 0) {
  // new implementation
}

// compiler synthesizes:
// 
//   public func f() { self.f(x: 0) }
//
//   @available(macOS 13.0)
//   public func f( x: Int = 0) {
```

Where the compiler would synthesize versions of the methods for the various availabilities, and delegate, in an ABI-compatible way to the new implementation. This is very similar to what would be necessary to help wire-compatible evolution of distributed methods. We would likely need to decide on a stable name, and then allow calling into the most recent one, thanks to it having default values for "new" parameters:

```swift
// "OLD" code on Client:
distributed actor Worker {
  @_stableName("hello") // must be unique in the actor
  distributed func hello() { ... }
}

// "NEW" code on Server:
distributed actor Worker {
  @_stableName("hello") // must be unique in the actor
  distributed func hello(@available(version: 1.1) next: Int = 0) { ... }
}
```

Since the envelope carries the arguments (in this case `[]`) and the `envelope.method` is the stable name, we're able to look up the `hello(next:)` method on the "new" server code.

The same ABI-compatibility mechanism that we just described would ensure the ability to invoke the old functions here.

### Resolving DistributedActor protocols

We want to be able to publish only protocols that contain distributed methods, and allow clients to resolve remote actors based on protocols alone, without having any knowledge about the specific `distributed actor` type implementing the protocol. This allows binary, closed-source frameworks to offer distributed actors as way of communication. Of course, for this to be viable we also need to solve the above ABI and wire-compatible evolution of distributed methods, assuming we solve those though, publishing distributed actor protocols is very useful and interesting for client/server scenarios, where the peers of a communication are not exact mirrors of the same process, but exhibit some asymmetry.

Currently, we resolve distributed actors using the static method defined on the `DistributedActor` protocol, sadly this method is not possible to invoke on just a protocol:

```swift
protocol Greeter: DistributedActor { 
  func greet() -> String 
}

let greeter: (any) Greeter = try Greeter.resolve(id: ..., using: websocketActorSystem)
// ❌ error: static member 'resolve' cannot be used on protocol metatype 'Worker.Protocol'
```

A "client" peer does not have to know what distributed actor exactly implements this protocol, just that we're able to send a "greet" message to it, we should be able to obtain an existential `any Greeter` and be able to invoke `greet()` on it. 

In order to facilitate this capability we need to: 

- implement ad-hoc synthesis of a type that effectively works like a "stub" that other RPC systems generally source-generate, yet thanks to our actor model we're able to synthesise it in the compiler on demand.
- find a way to invoke `resolve` on such protocol, for example we could offer a global function `resolveDistributedActorProtocol(Greeter.self, using: websocketActorSystem)`

The `resolveDistributedActorProtocol` method has to be able to check the serialization requirement at compile-time where we invoke the resolve, because the distributed actor protocols don't have to declare a serialization requirement -- they can, but they don't have to (and this is by design).

It should be possible to resolve the following examples:

```swift
protocol Greeter: DistributedActor { 
  distribute func greet() -> String 
}
final class WebsocketActorSystem: DistributedActorSystem { 
  typealias ActorID: WebsocketID // : Codable
  typealias SerializationRequirement: Codable
}

... = try resolveDistributedActorProtocol(id: ..., as: Greeter.self, using: websocketActorSystem)
```

the resolve call would use the types defined for the `ActorID` and `SerializationRequirement` to see if this `Greeter` protocol is even implementable using these, i.e. if its distributed method parameters/return types do indeed conform to `Codable`, and if there isn't a conflict with regards to the actor ID.

This means that we should reject at compile-time any attempts to resolve a protocol that clearly cannot be implemented over the actor system in question, for example:

```swift
protocol Greeter: DistributedActor { 
  distributed func greet() -> NotCodableResponse
}
final class WebsocketActorSystem: DistributedActorSystem { 
  typealias ActorID: WebsocketID // : Codable
  typealias SerializationRequirement: Codable
}

... = try resolveDistributedActorProtocol(id: ..., as: Greeter.self, using: websocketActorSystem)
// ❌ error: 'Greeter' cannot be resolved using 'WebsocketActorSystem'
// ❌ error: result type 'NotCodableResponse' of distributed instance method does not conform to 'Codable'
```

These are the same checks that are performed on `distributed actor` declarations, but they are performed on the type. We can think of these checks running whenever distributed methods are "combined" with a specific actor system: this is the case in `distributed actor` declarations, as well as this protocol resolution time, because we're effectively creating a not-user-visible actor declaration that combines the given `DistributedActorSystem` with the synthesized "stub" distributed actor, so we need to run the checks here. Thankfully, we can run them at compile time, disallowing any ill-formed and impossible to implement combinations.

### Passing parameters to assignID

Sometimes, transports may need to get a little of configuration for a specific actor being initialized.

Since `DistributedActorSystem.assignID` accepts the actor *type* it can easily access any configuration that is static for some specific actor type, e.g. like this:

```swift
protocol ConfiguredDistributedActor: DistributedActor { 
  static var globalServiceName: String { get }
}

distributed actor Cook: DistributedActorConfiguration {
  static var globalServiceName: String { "com.apple.example.CookingService" }
}
```

This way the assignID can detect the static property and e.g. ensure this actor is possible to look up by this static name:

```swift
extension SpecificDistributedActorSystem { 
  func assignID<Act>(_ type: Act.Type) -> Act.ID where Act: DistributedActor {
    let id = <<make up some id>>
    if let C = type as ConfiguredDistributedActor.Type {
      // for example, we could make sure the actor is discoverable using the service name:
      let globalServiceName = C.globalServiceName
      self.ensureAccessibleAs(id: id, as: globalServiceName)
    }
    
    return id
  }
}
```

Or similar configuration patterns. However, it is hard to implement a per instance configuration to be passed to the system.

One way we could solve this is by introducing an `assignID` overload that accepts the `ActorConfiguration` that may be
passed to the actor initializer, and would be passed along to the actor system like this:

```swift
extension SpecificDistributedActorSystem { 
  // associatedtype ActorConfiguration
  func assignID<Act>(_ type: Act.Type, _ properties: Self.ActorConfiguration) -> Act.ID where Act: DistributedActor {
    if let name = properties.name {
      return makeID(withName: name)
    }
    
    return makeRandomID()
  }
}
```

The creation of the actor would then be able to be passed at-most one `ActorConfiguration` instance, and that would be then passed down to this method:

```swift
distributed actor Worker {...}

Worker(actorSystem: system, actorProperties: .name("worker-1234"))
```

Which can be *very* helpful since now IDs can have user provided information that are meaningful in the user's domain.

## Alternatives Considered

This section summarizes various points in the design space for this proposal that have been considered, but ultimately rejected from this proposal.

### Define remoteCall as protocol requirement, and accept `[Any]` arguments

The proposal includes the fairly special `remoteCall` method that is expected to be present on a distributed actor system, however is not part of the protocol requirements because it cannot be nicely expressed in today's Swift, and it suffers from the lack of variadic generics (which are being worked on, see: [Pitching The Start of Variadic Generics](https://forums.swift.org/t/pitching-the-start-of-variadic-generics/51467)), however until they are complete, expressing `remoteCall` in the type-system is fairly painful, and we resort to providing multiple overloads of the method:

```swift
  func remoteCall<Act, P1, Result>(
    on recipient: Act,
    method: DistributedMethodName,
    _ arg1: P1,
    throwing errorType: Err.Type, 
    returning returnType: Res.Type
  ) async throws -> Res where Act: DistributedActor, Act.ID = ActorID { ... }
  
  func remoteCall<Act, P1, P2, Result>(
    on recipient: Act,
    method: DistributedMethodName,
    _ arg1: P1, _ arg2: P2,
    throwing errorType: Err.Type, 
    returning returnType: Res.Type
  ) async throws -> Res where Act: DistributedActor, Act.ID = ActorID { ... }

  // ... 
```

This is annoying for the few distributed actor system developers, however it allows us to completely avoid any existential boxing that shuttling values through `Any` would imply. We are deeply interested in offering this system to systems that are very concerned about allocations, and runtime overheads, and believe this is the right tradeoff to make, while we await the arrival of variadic generics which will solve this system implementation annoyance.

We are also able to avoid any heap allocations during the `remoteCall` thanks to this approach, as we do not have to construct type erased `arguments: [Any]` which would have been the alternative:

```swift
  func remoteCall<Act, Result>(
    on recipient: Act,
    method: DistributedMethodIdentifier,
    _ args: [Any], // BAD
    throwing errorType: Err.Type, 
    returning returnType: Res.Type
  ) async throws -> Res where Act: DistributedActor, Act.ID = ActorID { ... }
```

Not only that, but passing arguments as `[Any]` would force developers into using internal machinery to open the existentials (the not officially supported `_openExistential` feature), in order to obtain their specific types, and e.g. use `Codable` with them.

### Constraining arguments, and return type with of `remoteCall` with `SerializationRequirement`

Looking at the signature, one might be tempted to also include a `where` clause to statically enforce that all parameters and return type, conform to the `Self.SerializationRequirement`, like so:

```swift
  func remoteCall<Act, P1, Result>(
    on recipient: Act,
    method: DistributedMethodName,
    _ arg1: P1,
    throwing errorType: Err.Type, 
    returning returnType: Res.Type
  ) async throws -> Res where Act: DistributedActor, 
                    Act.ID = ActorID,
                    P1: SerializationRequirement { ... }
// ❌ error: type 'P1' constrained to non-protocol, non-class type 'Self.R'  
```

However, this is not expressible today in Swift, because we cannot prove the `associatedtype SerializationRequirement` can be used as constraint. 

Fixing this would require introducing new very advanced type system features, and after consultation with the core team we decided to accept this as current implementation limitation. 

In practice this is not a problem, because the parameters are guaranteed to succeed being cast to `SerializationRequirement` at runtime thanks to the compile-time guarantee about parameters of distributed methods. 

### Hardcoding the distributed runtime to make use of Codable

`Codable` is a great, useful, and relatively flexible protocol allowing for serialization of Swift native types, however it may not always be the best serialization system available. For example, we currently do not have a great binary serialization format that works with `Codable`, or perhaps some developers just really want to use a 3rd party serialization format such as protocol buffers, SBE or something entirely custom.

The additional complexity of the configurable `SerializationRequirement` is pulling its weight, and we are not interested in closing down the system to just use Codable.

## Acknowledgments & Prior Art

We would like to acknowledge the prior art in the space of distributed actor systems which have inspired our design and thinking over the years. Most notably we would like to thank the Akka and Orleans projects, each showing independent innovation in their respective ecosystems and implementation approaches. As these are library-only solutions, they have to rely on wrapper types to perform the hiding of information, and/or source generation; we achieve the same goal by expanding the already present in Swift actor-isolation checking mechanisms.

We would also like to acknowledge the Erlang BEAM runtime and Elixir language for a more modern take built upon the on the same foundations, which have greatly inspired our design, however take a very different approach to actor isolation (i.e. complete isolation, including separate heaps for actors).

## Source compatibility

This change is purely additive to the source language. 

The language impact has been mostly described in the Distributed Actor Isolation proposal

## Effect on ABI stability

TODO

## Effect on API resilience

None.

## Changelog

- 2.0 Update proposal to latest `excecuteDistributedTarget` runtime
  - Explain how we deal with `: SerializationRequirement` in generics
  - Explain how we need to use `remoteCallVoid` and how we could get rid of it in the future
  - Overall reflow and fix various wording
- 1.2 Drop implicitly distributed methods
- 1.1 Implicitly distributed methods
- 1.0 Initial revision
- [Pitch: Distributed Actors](https://forums.swift.org/t/pitch-distributed-actors/51669)
  - Which focused on the general concept of distributed actors, and will from here on be cut up in smaller, reviewable pieces that will become their own independent proposals; Similar to how Swift Concurrency is a single coherent feature, however was introduced throughout many interconnected Swift Evolution proposals.
