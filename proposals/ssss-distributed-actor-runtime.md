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
    - [Implicit Distributed Actor Properties](#implicit-distributed-actor-properties)
    - [Initializing Distributed Local Actors](#initializing-distributed-local-actors)
      - [Initializing `actorSystem` and `id` properties](#initializing-actorsystem-and-id-properties)
    - [Ready-ing Distributed Actors](#ready-ing-distributed-actors)
      - [Ready-ing Distributed Actors, exactly once](#ready-ing-distributed-actors-exactly-once)
      - [Resigning Distributed Actor IDs](#resigning-distributed-actor-ids)
    - [Resolving Distributed Actors](#resolving-distributed-actors)
    - [Distributed Methods](#distributed-methods)
      - [Invoking Distributed Methods on Remote Instances](#invoking-distributed-methods-on-remote-instances)
      - [Serializing Distributed Invocations](#serializing-distributed-invocations)
      - [Receiving Remote Calls](#receiving-remote-calls)
      - [Deserializing incoming Invocations](#deserializing-incoming-invocations)
      - [Resolving the Recipient](#resolving-the-recipient)
      - [The `executeDistributedTarget` method](#the-executedistributedtarget-method)
      - [Performing the distributed target call](#performing-the-distributed-target-call)
      - [Collecting result/error from the Invocation](#collecting-resulterror-from-the-invocation)
  - [Future Work](#future-work)
    - [Stable names and more API evolution features](#stable-names-and-more-api-evolution-features)
    - [Resolving DistributedActor protocols](#resolving-distributedactor-protocols)
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

In [SE-NNNN: Distributed Actor Isolation](https://github.com/ktoso/swift-evolution/blob/distributed-isolation/proposals/mmmm-distributed-actor-isolation.md#distributed-actor-isolation) we took it a step further, guaranteeing complete isolation of state with distributed actor-isolation, and setting the stage for `distributed` method calls to be performed across process and node boundaries. 

This proposal focuses on the runtime aspects of making such remote calls possible, their exact semantics and how developers can provide their own `DistributedActorSystem` implementations to hook into the same language mechanisms, extending Swift's distributed actor model to various environments (such as cross-process communication, clustering, or even client/server communication).

#### Useful links

It is recommended, though not required, to familiarize yourself with the prior proposals before reading this one:

- [SE-NNNN: Distributed Actor Isolation](https://github.com/apple/swift-evolution/pull/1478) - a detailed proposal 
- Distributed Actor Runtime & Serialization (this proposal)

Feel free to reference the following library implementations which implement this proposal's library side of things:

- [Swift Distributed Actors Library](https://www.swift.org/blog/distributed-actors/) - a reference implementation of a *peer-to-peer cluster* for distributed actors. Its internals depend on the work in progress language features and are dynamically changing along with these proposals. It is a realistic implementation that we can use as reference for these design discussions.
- "[Fishy Transport](https://github.com/apple/swift-sample-distributed-actors-transport)" Sample - a simplistic example transport implementation that is easier to follow the basic integration pieces than the realistic cluster implementation. Feel free to refer to it as well, while keeping in mind that it is very simplified in its implementation approach.

## Motivation

With distributed actor-isolation checking laid out in [SE-NNNN: Distributed Actor Isolation](https://github.com/ktoso/swift-evolution/blob/distributed-isolation/proposals/mmmm-distributed-actor-isolation.md#distributed-actor-isolation) we took the first step towards enabling remote calls being made by invoking `distributed func` declarations on distributed actors. The isolation model and serialization requirement checks in that proposal outline how we can guarantee the soundness of such distributed actor model at compile time.

Distributed actors enable developers to build their applications and systems using the concept of actors that may be local or remote, and communicate with them regardless of their location. Our goal is to set developers free from having to re-invent ad-hoc approaches to networking, serialization and error handling every time they need to embrace distributed computing. 

Instead, we aim to embrace a co-operative approach to the problem, in which:

1. the Swift language, compiler, and runtime provide the necessary isolation checks and runtime hooks for distributed actor lifecycle management, and distributed method calls that can be turned into "messages" that can be sent to remote peers,

2. `DistributedActorSystem` library implementations, hook into the language provided cut-points, taking care of the actual message interactions, e.g. by sending messages representing remote distributed method calls over the network,
3. `distributed actor` authors, who want to focus on getting things done, express their distributed API boundaries and communicate using them. They may have opinions about serialization and specifics of message handling, and should be able to configure and use the `DistributedActorSystem` of their choice to get things done.

In general, we propose to embrace the actor style of communication for typical distributed system development, and aim to provide the necessary tools in the language, and runtime to make this a pleasant and nice default-go-to experience for developers.

Distributed actors may not serve *all* possible use-cases where networking is involved, but we believe a large group of applications and systems will benefit from them, as the ecosystem gains more and more `DistributedActorSystem` implementations.

#### Example scenario

In this proposal we will focus only on the runtime aspects of distributed actors and methods, i.e. what happens in order to create, send, and receive messages formed when a distributed method is called on a remote actor. For more details on distributed actor isolation and other compile-time checks, please refer to [SE-0336: Distributed Actor Isolation](https://github.com/ktoso/swift-evolution/blob/distributed-isolation/proposals/0336-distributed-actor-isolation.md#distributed-actor-isolation).

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

### Caveat: Low-level implementation details

This proposal includes low-level implementation details in order to showcase how one can use to build a real, efficient, and extensible distributed actor system using the proposed language runtime. 

End users of distributed actors need not dive deep into this proposal, and may be better served by reading [SE-NNNN: Distributed Actor Isolation](https://github.com/ktoso/swift-evolution/blob/distributed-isolation/proposals/mmmm-distributed-actor-isolation.md#distributed-actor-isolation) which focuses on how distributed actors are used. This proposal focuses on how distributed actors can be implemented – because this language feature is extensible, advanced library authors may step in and build their own distributed actor runtimes.

## Detailed design

This proposal's detailed design section is going to deep dive into the runtime details and its interaction with user provided `DistributedActorSystem` implementations. Many of those aspects do not necessarily matter to the end-user/developer that only wants to write some distributed actors and have them communicate using *some* distributed actor system. This proposal however, dives deeper, explaining how distributed actors actually work internally.

### The `DistributedActorSystem` protocol

At the core of everything actors do, is the `DistributedActorSystem` protocol. This protocol is open to be implemented by anyone, and can be used to extend the functionality of distributed actors to other environments. 

Building a solid actor system implementation is not a trivial task, and we only expect a handful of mature implementations to take the stage eventually.

> At the time of writing, we–the proposal authors–have released a work in progress [peer-to-peer cluster actor system implementation](https://www.swift.org/blog/distributed-actors/) that is tracking this evolving language feature. It can be viewed as a reference implementation for the language features and `DistributedActorSystem` protocol discussed in this proposal. 
>
> As not everything mentioned in this proposal is implemented yet, the cluster library is lagging behind a little, but will be adopting the new APIs as they become available in the language.

Below we present the full listing of the `DistributedActorSystem` protocol, and we'll be explaining the specific methods one by one as we go through what and how distributed actors do in order to achieve their messaging capabilities:

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
  ///
  /// ### Implicit 'distribute actor' Codable conformance
  /// If the 'ActorID' (and therefore also the 'DistributedActor.ID') conforms to 'Codable',
  /// the 'distributed actor' will gain an automatically synthesized conformance to 'Codable' as well.
  associatedtype ActorID: Sendable & Hashable
  
  /// The specific type of the argument builder to be used for remote calls.
  associatedtype Invocation: DistributedTargetInvocation

  /// The serialization requirement to be applied to all distributed members of a distributed actor.
  ///
  /// An actor system is still allowed to throw serialization errors if a specific value passed to a distributed
  /// func violates some other restrictions that can only be checked at runtime, e.g. checking specific types
  /// against an "allow-list" or similar. The primary purpose of the serialization requirement is to provide
  /// compile time hints to developers, that they must carefully consider evolution and serialization of 
  /// values passed to and from distributed methods and computed properties.
  typealias SerializationRequirement = Invocation.SerializationRequirement
  
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
            Act.ID: ActorID
  
  // ==== ---------------------------------------------------------------------
  // - MARK: Remote Target Invocations

  /// Invoked by the Swift runtime when a distributed remote call is about to be made.
  ///
  /// The returned DistributedTargetInvocation will be populated with all
  /// arguments, generic substitutions, and specific error and return types
  /// that are associated with this specific invocation. 
  /// 
  /// Next, the prepared invocation will be passed to the remoteCall where the actual 
  /// remote message send should be performed by the system.
  @inlinable
  func makeInvocation() throws -> Invocation
  
  // We'll discuss the remoteCall method in detail in this proposal.
  // It cannot be declared as protocol requirement, and remains an ad-hoc
  // like this:
//  /// Invoked by the Swift runtime when making a remote call.
//  ///
//  /// The `arguments` are the arguments container that was previously created
//  /// by `makeInvocation` and has been populated with all arguments.
//  ///
//  /// This method should perform the actual remote function call, and await for its response.
//  ///
//  /// ## Errors
//  /// This method is allowed to throw because of underlying transport or serialization errors,
//  /// as well as by re-throwing the error received from the remote callee (if able to).
//  func remoteCall<Act, Err, Res>(
//      on actor: Act,
//      target: RemoteCallTarget,
//      arguments: Invocation,
//      throwing: Err.Type,
//      returning: Res.Type
//  ) async throws -> Res.Type
//      where Act: DistributedActor,
//            Act.ID == ActorID,
//            Res: Self.SerializationRequirement
}

/// A distributed 'target' can be a `distributed func` or `distributed` computed property.
///
/// The actor system should encode the identifier however it sees fit, 
/// and transmit it to the remote peer in order to invoke identify the target of an invocation.
@available(SwiftStdlib 5.6, *)
public struct RemoteCallTarget: Hashable {
  /// The mangled name of the invoked distributed method.
  /// 
  /// It contains all information necessary to lookup the method using `executeDistributedActorMethod(...)`
  var mangledName: String { ... }
  
  /// The human-readable "full name" of the invoked method, e.g. 'Greeter.hello(name:)'.
  var fullName: String { ... }
}
```

### Implicit Distributed Actor Properties

Distributed actors have two properties that are crucial for the inner workings of actors that we'll explore during this proposal: the `id` and `actorSystem`.

These properties are synthesized by the compiler, in every `distributed actor` instance, and they witness the `nonisolated` property requirements defined on the `DistributedActor` protocol. 

The `DistributedActor` protocol, as a reminder, defines those requirements:

```swift
protocol DistributedActor {
  associatedtype ActorSystem: DistributedActorSystem
  typealias ID = ActorSystem.ActorID
  
  nonisolated var id: ID { get }
  nonisolated var actorSystem: ActorSystem { get }
  
  // ... 
}
```

which are witnessed by the following *synthesized properties* in every specific distributed actor instance.

Next, we will discuss how those properties get initialized, and used in effectively all aspects of a distributed actor's lifecycle.

### Initializing Distributed Local Actors

At runtime, a *local* `distributred actor` is effectively the same as a local-only `actor`. The allocated `actor` instance is a normal `actor`, however its initialization is a little special, because it must interact with its associated actor system to make itself available for remote calls.

We will focus on non-delegating initializers, as they are the ones where distributed actors cause additional things to happen. 

A non-delegating initializer of a type must *fully initialize* it. The place in code where an actor becomes fully initialized has important and specific meaning to actor isolation which is defined in depth in [SE-0327: On Actors and Initialization](https://github.com/apple/swift-evolution/pull/1476). Not only that, but once fully initialized it is possible to escape `self` out of a distributed actor's initializer. This aspect is important for distributed actors, because it means that once fully initialized they _must_ be registered with the actor system as they may be sent to other distributed actors and even sent messages to.

All non-delegating initializers must accept exactly parameter that conforms to the `DistributedActorSystem` protocol. The type-checking rules of this are explained in depth in [SE-NNNN: Distributed Actor Isolation](...). E.g. these are well-formed initializers:

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
  init(transport: SomeActorSystem, too many: SomeActorSystem) { ... }
  // ❌ error: designated distributed actor initializer 'init(transport:too:)' must accept exactly one ActorTransport parameter, found 2
  
  init(x: String) {}
  // ❌ error: designated distributed actor initializer 'init(x:)' is missing required ActorTransport parameter
}
```

To learn more about the specific restrictions, please refer to [SE-0336: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md).

Now in the next sections, we will explore in depth why this parameter was necessary to enforce to begin with.

#### Initializing `actorSystem` and `id` properties

The first reason is that we need to initialize the `actorSystem` stored property.

This is also necessary for any distributed actor's default initializer, which is synthesized when no user-defined initializer is provided. It is similar to the no-argument default initializer that is synthesized for classes and actors, however since we must initialize the `id` and `actorSystem`, it also accepts a required `system` parameter:

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

The initialization of the `id` property is a little more involved. We need to communicate with the `system` used to initialize the distributed actor, for it is the `ActorSystem` that allocates and manages identifiers. In order to obtain a fresh `ID` for the actor being initialized, we need to call `system`'s `assignID` method. This is done early (before user-defined code) in the actors designated initializer, like this:

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

Readying is done automatically by code synthesized into the distributed actor's non-delegating initializers, and takes the shape of an `self.actorSystem.actorReady(self)` call, injected at appropriate spots in the actor's initializer. This call is necessary in order for the distributed actor system to be able to resolve an incoming `ID` (that it knows, since it assigned it) to a specific distributed actor instance (which it does not know, until `actorReady` is called on it). This means that there is a state between the `assignID` and `actorReady` calls, during which the actor system cannot yet properly resolve the actor. 

In this section we will discuss the exact semantics of readying actors, how systems must implement and handle these calls, and where exactly they are invoked during from any distributed actor initializer.

> **Note:** It is highly recommended to read [SE-0327: On Actor Initialization](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md) in order to understand how initializers can guarantee thread-safety, and how this proposal plays well with the there proposed initializer rules. The two proposals have been developed in tandem, and we made sure they mesh well together.

Where the `system.actorReady(self)` call is performed depends on whether the initializer is asynchronous. The reasons for this are due to thread-safety checks and how isolation is changed in actor initializers as proposed by [SE-0327: On Actor Initialization](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md). Specifically, these locations fall out of the rules where any such user-defined code would be permitted, and what changes it causes to `self` isolation. Please refer to that proposal for a detailed discussion of this topic as it is a very deep topic. 

Specifically, the ready call in distributed actors is made:

- at the _end_ of **synchronous non-delegating initializers**, or
- where the actor becomes fully-initialized (and the initializer implicitly hops to the actors' execution context) in **asynchronous non-delegating initializers**.

The following snippet illustrates a synchronous initializer, and where the ready call is injected in it:

```swift
distributed actor DA { 
  let number: Int

  init(sync system: ActorSystem) {
    // << self.actorSystem = system
    // << self.id = system.assignID(Self.self)
    self.number = 42
    // ... fully initialized ...
    // cannot escape `self` without changing initializer semantics
    // since it is a synchronous one
    print("Initialized \(\(self.id))")
    // << system.actorReady(self)
  }
}
```

Whereas the following snippet illustrates an asynchronous initializer, for the same actor:

```swift
distributed actor DA { 
  let number: Int

  init(async system: ActorSystem) async {
    // << self.actorSystem = system
    // << self.id = system.assignID(Self.self)
    self.number = 42
    // fully initialized:
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
      // ~ become fully initialized ~
      // << <hop to self executor>
      // << system.actorReady(self)
    } else {
      print("odd")
      self.number = number
      // ~ become fully initialized ~
      // << <hop to self executor>
      // << system.actorReady(self)
    }  
  }
}
```

Actor system implementations need to take special care about actor identifiers that have been assigned, but are not yet ready. 

Because of general rules about escaping `self` from not yet initialized actors and classes, it is not possible to escape a distributed actor's `self` before it is fully initialized. 

Special care needs to be taken about the distributed actor and actor system interaction between the `assignID` and `actorReady` calls, because during this time the system is unable to *deliver* an invocation to the target actor. However, it is always able to recognize that an ID is known, but just not ready yet – the system did create and assign the ID after all. This matters only in **synchronous** distributed actor initializers, because the ready call is performed at the end of the initializer, and before that users are allowed to e.g. escape the `self` into a `Task` and potentially invoke a remote distributed method passing `self` to it, like this:

```swift
init(greeter: Greeter, system: ActorSystem) { // synchronous (!)
 // ...
 // << id = system.assignID(Self.self)
 // ~ fully initialized ~
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

This thankfully is not a problem unknown to distributed actor runtimes, and can be solved by buffering messages to recipients that have been assigned an ID but are not yet ready. Since this is a synchronous initializer we are talking about here, this situation cannot lead to a deadlock since the initializer will continue running and we are unable to suspend it (because it is not async). In theory, a synchronous distributed actor initializer that *never returned* is problematic here, because it will never become ready, but this simply isn't the nature of how initializers should be used, and after careful consideration we decided this is a fair tradeoff. 

Never-returning *synchronous* initializers, which escape self to other distributed actors, may not be able to receive incoming distributed calls. The problem does not necessarily have to lead to deadlocks or never-resumed tasks because remote calls are often associated with deadlines which would break the infinite wait. The above situation though quite an edge case though, and the other rules about actor isolation and thread-safety of initializers we feel more than make up for this one weird situation. The problem does not manifest with asynchronous initializers, so this is another option available for end users which truly want to perform distributed calls that are not request/reply, but direct messages from the remote peer, this is another option available to resolve the issue.

#### Ready-ing Distributed Actors, exactly once

Another interesting case the synthesis in asynchronous initializers needs to take care of is triggering the `actorReady` call only *once*, as the actor truly becomes fully initialized. This issue does not manifest itself in simple init implementations, however the following snippet does a good job showing an example of where it can manifest:

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

This actor performs a loop during which it assigns values to `self.int`, the actor becomes fully initialized the first time this loop runs. While the implications on actor isolation are hard to observe here, the general need of performing a task once the actor is fully initialized is the same. In the case of distributed actors, we need to emit the `actorReady(self)` call, only once, as the actor becomes initialized, and we should not repeatedly call the actor system's `actorReady` method which would force system developers into weirdly defensive implementations of this method.

Thankfully, this is possible to track in the compiler, and we can emit the ready call only once, based on internal initialization marking mechanisms (that store specific bits for every initialized field). The synthesized (pseudo)-code therefore is something like this:

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

#### Resigning Distributed Actor IDs

In addition to assigning `ID` instances to specific actors as they get created, we must also *always* ensure the `ID`s assigned are resigned as their owning actors get destroyed. 

Resigning an `ID` allows the actor system to release any resources it might have held in association with this actor. Most often this means removing it from some internal lookup table that was used to implement the `resolve(ID) -> Self` method of a distributed actor, but it could also imply tearing down connections, clearing caches, or even dropping any in-flight messages addressed to the now terminated distributed actor.

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

Things get more complicated once we take into account the existence of *failable* and *throwing* initializers though. Existing Swift semantics around those types of initializers, and their effect on if and when `deinit` is invoked mean that we need to take special care about them.

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
  }
  
  // deinit {
  //   << self.actorSystem.resignID(self.id)
  // }
}
```

Due to rules about actor and class init/deinit, when we `return nil` from a failable initializer, its deinitializer *does not run* (!). Because of this, we cannot rely on the deinit to resign the ID as we'd leave an un-used, but still registered identity hanging in the actor system, and the `resignID` is injected just before the "failing return" from such initializer. This is done transparently, and neither distributed actor developers nor actor system developers need to worry about this: the ID is always resigned properly.

Next, we need to discuss *throwing* initializers, and their complicated multiple paths of execution. Again, rules about class and actor deinitialization, are tightly related to whether or not a types deinit will be executed or not, so let us analyse the following example:

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
- `actorReady(_:)` will be called exactly-once, after all other properties of the distributed actor have been initialized, and it is ready to receive messages from other peers. By construction, it will also always be called after `assignID(_:)` and before any `resignID(_:)` call.
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

This method will either return a distributed actor reference, or throw when the actor system is unable to resolve the reference.

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

The resolve implementation should be relatively fast, and should be non-blocking. Specifically it should *not* attempt to contact the remote peer to confirm whether this actor really exists or not. Systems should blindly resolve remote identifiers assuming the remote peer will be able to handle them. Some systems may after all spin up actor instances lazily, upon the first message sent to them etc.

Allocating the remote reference is implemented by the Swift runtime, by creating a fixed-size object that serves only the purpose of proxying calls into the `system.remoteCall`. The `_isDistributedRemoteActor()` function always returns `true` for such a reference. 

If the system entirely fails to resolve the id, e.g. because it was ill-formed or the system unable to handle proxies for the given id, it must throw with an error conforming to `DistribtuedActorSystemError`, rather than returning `nil`. An example implementation could look something like this:

```swift
final class ClusterSystem: DistributedActorSystem { 
  private let lock: Lock
  private var localActors: [ActorID: AnyWeaklyHeldDistributedActor] // stored into during actorReady
  
  // example implementation; more sophisticated ones can exist, but boil down to the same idea
  func resolve<ID, Act>(id: ID, as actorType: Act.Type)
      throws -> Act? where Act: DistributedActor, Act.ID == ActorID, ID: ActorID {
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

### Distributed Methods

#### Invoking Distributed Methods on Remote Instances

From the end-user's (here, defined as developer using distributed actors, not implementing an actor system runtime) perspective a remote call is a plain-old method invocation on a *potentially remote* distributed actor instance. 

Such calls actually invoke a "distributed thunk", which takes care of checking if the remote or local code-path shall be taken for this specific invocation:

```swift
// distributed func greet(name: String) -> String { ... }

try await greeter.greet(name: "Alice")
```

Such invocation is actually calling a "distributed thunk" for the method, rather than the method directly. The "distributed thunk" is synthesized by the compiler for every `distributed func`, and can be illustrated by the following snippet:

```swift
extension Greeter {
  // synthesized; not user-accessible thunk for: greet(name: String) -> String
  nonisolated func greet_$distributedThunk(name: String) async throws -> String {
    if _isDistributedRemoteActor(self) {
      // [1] prepare the invocation object:
      var invocation = self.actorSystem.makeInvocation()
      // [1.1] for each argument, synthesize a specialized recordArgument call:
      try invocation.recordArgument(name)
      
      // [1.2] if method has generic parameters, record substitutions
      // e.g. for func generic<A, B>(a: A, b: B) we would get two substitutions,
      // for the generic parameters A and B:
      //
      // << arguments.recordGenericTypeSubstitution(_getMangledTypeName(type(of: a)))
      // << arguments.recordGenericTypeSubstitution(_getMangledTypeName(type(of: b)))
      
      // [1.3] we also record the return type; it may or may not be necessary to transmit over the wire
      //       but thanks to this encoding we're able
      try invocation.recordErrorType(_getMangledTypeName(Error.self))
      
      // [1.4] if the target was throwing, record Error.self, 
      // though otherwise we do not invoke the record error type
      // try invocation.recordReturnType(_getMangledTypeName(Error.self))
      
      // [1.5] done recording arguments
      try invocation.doneRecording()
      
      return try await self.actorSystem.remoteCall(
        on: self,
        target: RemoteCallTarget(...),
        invocation: invocation,
        throwing: Never.self, // the target func was not throwing
        returning: String.self
      )
    } else {
      // the local func was not throwing, but since we're nonisolated in the thunk,
      // we must hop to the target actor here, meaning the 'await' is always necessary.
      return await self.greet(name: name) 
    }
  }
}
```

The synthesized thunk is always throwing and asynchronous, this is correct because it is only invoked in situations where we might end up calling the `actorSystem.remoteCall(...)` method, which by necessity is asynchronous and throwing as well. 

The thunk is `nonisolated` because it is a method that can actually run on a *remote* instance, and as such is not allowed to touch any other state than other nonisolated stored properties, specifically the actor's `id` and `actorSystem` which is necessary to make the remote call. 

The `nonisolated` aspect of the method has another important role to play: if this invocation happens to be  on a local distributed actor, we do not want to "hop" twice, but only once we have confirmed the actor is local and hop to it using the same semantics as we would when performing a normal actor method call. If the instance was remote, we don't need to suspend early at all, and we leave it to the `actorSystem` to decide when exactly the task will suspend. For example, the system may only suspend the call after it has sent the bytes synchronously over some IPC channel etc. Those semantics when to suspend are highly dependent on the specific underlying transport, and thanks to this approach we allow system implementations to do the right thing, whatever that might be: they can suspend early, late, or even not at all if the call is known to be impossible to succeed.

Note that the compiler will pass the `self` of the distributed *known-to-be-remote* actor to the remoteCall method on the actor system. This allows the system to check the passed type for any potential, future, customization points that the actor may declare as static properties, and/or conformances affecting how a message shall be serialized or delivered. It is of course impossible for the system to access any of that actor's state, because it is remote after all. The one piece of state it will need to access though is the actor's `id` because that is signifying the *recipient* actor of the message it is about to send.

The thunk creates the `invocation` container [1] into which it records all arguments. Note that  all these APIs are using only concrete types, so we never pay for any existential wrapping or other indirections. The `record...` calls are expected to serialize the values, using any mechanism they want to, and thanks to the type performing the recording being provided by the specific `ActorSystem`, it also knows that it can rely on the arguments to conform to the system's `SerializationRequirement`.

A non-obvious part of this thunk is the `recordGenericTypeSubstitution` [1.2] calls which are made when the `distributed func` has generic parameters, or involves any generics in its parameters whatsoever. This also happens when the distributed actor itself has generic parameters, like for example a generic greeter of various greeting types: `Greeter<G: Greeting>`. The system does not have to worry too much about the details of the generic substitutions, other than store them in the passed-in order.

Finally, we also record the specific return [1.3] and error types [1.4]. The return type should be pretty self-explanatory, however the error may be a little surprising. The `recordErrorType` method is only called when the target function is throwing, and allows the runtime to encode that a throw from the remote target method is expected. If Swift were to ever gain typed errors, we could record them using this mechanism as well. If the target method is not throwing, then the `recordErrorType` is not called.

Next, we will discuss how the actor system must implement the `remoteCall()` method(s), in order to properly serialize and send the remote call to its recipient.

#### Serializing Distributed Invocations

The next step in making a remote call is serializing a representation of the distributed method (or computed property) invocation. This is done through a series of compiler, runtime, and distributed actor system interactions. These interactions are designed to be highly efficient and customizable. For example, thanks to this `DistributedTargetInvocation` approach that we'll discuss here, we are able to *never* resort to existential boxing of values, allow serializers to manage and directly write into their destination buffers (i.e. allowing for zero copies to be performed between the message serialization and the underlying networking layer), and more. 

Sadly, it comes at the cost of having to implement a few ad-hoc protocol requirements which are not as nice to deal with but luckily only distributed system library authors will have to interact with those, meaning that the potential for mistakes with the ad-hoc declarations here is minimal and centralized.

Every distributed actor system will do something slightly different in their `makeInvocation` and `remoteCall` implementations - based on their underlying serialization and transport mechanisms. However, most systems will need to form some kind of "Envelope" (easy to remember as: "the thing that contains the Message and also has knowledge of the recipient"). 

Let us consider a `ClusterSystem` that will use `Codable` and send messages over the network. The `SerializationRequirement = Codable` is actually defined by the Invocation type, which we'll discuss next, but first let us discuss the example `Envelope` we'll use in our discussion in this section.

```swift
// !! ClusterSystem or Envelope are NOT part of the proposal, but serves as illustration how actor systems might !!
// !! implement the necessary pieces of the DistributedActorSystem protocol.                                    !!

final struct ClusterSystem: DistributedActorSystem { 
  
  /// The specific type of the argument builder to be used for remote calls.
  associatedtype Invocation: ClusterSystemTargetInvocation
  
  // Just an example, we can implement this more efficiently if we wanted to.
  private struct WireEnvelope: Codable { 
    var recipientID: ClusterSystem.ActorID // is Codable
    
    /// Mangled method/property identifier, e.g. in a mangled format
    var identifier: String 
    
    // For illustration purposes and simplicity of code snippets we use '[Data]' here, 
    // but real implementations can be much more efficient here -- packing all the data into exact 
    // byte buffer that will be passed to the networking layer etc.
    var arguments: [Data] // example is using Data, because that's what Codable coders use
    
    // Type substitutions matter only for distributed methods which use generics:
    var genericSubstitutions: [String]
    
    // Metadata can be used by swift-distributed-tracing, or other instrumentations to carry extra information:
    var metadata: [String: [Data]] // additional metadata, such as trace-ids etc.
  }
}
```

Note that `method` property is enough to identify the target of the call, we do not need to carry any extra type information explicitly in the call. The method identifier is sufficient to resolve the target method on the recipient, however in order to support generic distributed methods, we need to carry additional (mangled) type information for any of the generic parameters of this specific method invocation. Thankfully, these are readily provided to us by the Swift runtime, so we'll only need to store and send them over.

> **Note:** An implementation may choose to define any shape of "envelope" (or none at all) that suits its needs. It may choose to transport mangled names of involved types for validation purposes, or choose to not transfer them at all and impose other limitations on the system and its users for the sake of efficiency. 
>
> While advanced implementations may apply compression and other techniques to minimize the overhead of these envelopes - this is a deep topic by itself, and we won't be going in depth on it in this proposal - rest assured though, we have focused on making different kinds of implementations possible with this approach.

A remote call is implemented in two "steps", first we will return an `Invocation` object that the Swift runtime will call with information about the invocation. The invocation is a specific type defined by the `DistributedActorSystem` implementation and conforming to the `ClusterTargetIncovation` protocol:

```swift

/// Represents an invocation of a distributed target (method or computed property).
///
/// ## Forming an invocation
///
/// On the sending-side an instance of an invocation is constructed by the runtime,
/// and calls to: `recordGenericSubstitution`, `recordArgument`, `recordReturnType`,
/// `recordErrorType`, and finally `doneRecording` are made (in this order).
///
/// If the return type of the target is `Void` the `recordReturnType` is not invoked.
///
/// If the error type thrown by the target is not defined the `recordErrorType` is not invoked.
///
/// An invocation implementation may decide to perform serialization right-away in the
/// `record...` invocations, or it may choose to delay doing so until the invocation is passed
/// to the `remoteCall`. This decision largely depends on if serialization is allowed to happen
/// on the caller's task, and if any smarter encoding can be used once all parameter calls have been
/// recorded (e.g. it may be possible to run-length encode values of certain types etc.)
///
/// Once encoded, the system should use some underlying transport mechanism to send the
/// bytes serialized by the invocation to the remote peer.
///
/// ## Decoding an invocation
/// Since every actor system is going to deal with a concrete invocation type, they may
/// implement decoding them whichever way is most optimal for the given system.
///
/// Once decided, the invocation must be passed to `executeDistributedTarget`
/// which will decode the substitutions, argument values, return and error types (in that order).
///
/// Note that the decoding will be provided with the specific types that the sending side used to perform the call,
/// so decoding can rely on simply invoking e.g. `Codable` (if that is the `SerializationRequirement`) decoding
/// entry points on the provided types.
public protocol DistributedTargetInvocation {
  /// The type that all distributed target parameters and return type must conform to.
  /// 
  /// This type is equal to 'DistributedActorSystem.SerializationRequirement' 
  /// and 'DistributedActor.SerializationRequirement' of the same actor system.
  associatedtype SerializationRequirement
  
  /// The specific type of argument decoder, invoked while decoding arguments
  /// on the recipient side of a distributed remote call.
  associatedtype ArgumentDecoder: DistributedTargetInvocationArgumentDecoder


  // === Sending / recording  -------------------------------------------------

  mutating func recordGenericSubstitution<T>(mangledType: T.Type) throws

//  /// Ad-hoc requirement
//  ///
//  /// Record an argument of `Argument` type in this arguments storage.
//  /// 
//  /// Invoked with the specific type of each argument, which allows the implementation
//  /// to immediately use it for encoding the value. The argument is guaranteed via 
//  /// compile-time checks on distributed call targets to conform to the 'SerializationRequirement'.
//  mutating func recordArgument<Argument: SerializationRequirement>(argument: Argument) throws

  /// Record the error type of the distributed target.
  /// 
  /// This method is only invoked if the target is throwing.
  mutating func recordErrorType<E: Error>(mangledType: E.Type) throws

//  /// Ad-hoc requirement
//  /// 
//  /// Invoked with the specific type of the distributed target's return value.
//  /// The type is guaranteed via compile-time on distributed call targets to 
//  /// conform to the 'SerializationRequirement'.
//  /// 
//  /// This method is not invoked when the return type of the target is `Void`, 
//  /// because the `Void` type does not necessarily have to conform to the `SerializationRequirement`.
//  mutating func recordReturnType<R: SerializationRequirement>(mangledType: R.Type) throws 

  /// Invoked after all other `record...` calls have been made and the encoding phase is complete.
  /// Implementations may use this to apply any kind of compression or other "final" step to the encoding.
  mutating func doneRecording() throws

  // === Receiving / decoding -------------------------------------------------

  mutating func decodeGenericSubstitutions() throws -> [Any.Type]

  mutating func argumentDecoder() -> Self.ArgumentDecoder

  mutating func decodeReturnType() throws -> Any.Type?

  mutating func decodeErrorType() throws -> Any.Type?
}
```

We will discuss the protocol in depth in the following sections. 

Before that, it is worth explaining why some protocol requirements are "ad-hoc" requirements. We want to guarantee implementors of the `DistributedTargetInvocation` type that the passed-in arguments in fact do conform to the `SerializationRequirement` associated value. Because this is compile-time guaranteed, we can avoid numerous `as?` casts in actor system implementations, which can matter in some high-performance transport scenarios. Sadly, this generic constraint is currently not expressible in Swift and enabling it is a large complex type system feature. Because of how performance sensitive, and intertwined with the compiler and runtime the construction of the `DistributedTargetInvocation` is, we believe this is a feature we can work without for the time being, and as it becomes expressible in the language we could adopt it.

This `DistributedTargetInvocation` approach allows us to avoid any existential boxing, unsafe APIs, all while allowing system developers to directly serialize data in whatever way they see fit:

```swift
extension ClusterSystem { 
  
  // typealias Invocation = ClusterSystemTargetInvocation
  func makeInvocation(target: RemoteCallTarget) -> ClusterTargetInvocation {
    return ClusterTargetInvocation(system: system)
  }
  
  struct ClusterTargetInvocation: DistributedTargetInvocation {
    typealias ArgumentDecoder = ClusterTargetInvocationArgumentDecoder
    typealias SerializationRequirement = Codable
    
    let system: ClusterSystem
    var envelope: Envelope
    
    init(system: ClusterSystem) {
      self.system = system
      self.envelope = .init() // new "empty" envelope
    }

    // === Sending / recording  -------------------------------------------------

    /// Ad-hoc requirement
    ///
    /// The arguments must be encoded order-preserving, and once `decodeGenericSubstitutions`
    /// is called, the substitutions must be returned in the same order in which they were recorded.
    mutating func recordGenericSubstitution<T: SerializationRequirement>(type: T.Type) throws {
      // NOTE: we are showcasing a pretty simple implementation here... 
      //       advanced systems could use mangled type names or registered type IDs.
      envelope.genericSubstitutions.append(String(reflecting: T.self))
    }

    /// Ad-hoc requirement
    ///
    /// Record an argument of `Argument` type in this arguments storage.
    mutating func recordArgument<Argument: SerializationRequirement>(argument: Argument) throws {
      // in this implementation, we just encode the values one-by-one as we receive them:
      let argData = try system.encoder.encode(argument) // using whichever Encoder the system has configured
      envelope.arguments.append(argData)
    }
    
    /// Ad-hoc requirement
    ///
    /// Optionally, record the expected return type. 
    /// Encoding this information may not be necessary, depending on how the target identity is defined.
    ///
    /// This method is NOT invoked when `E` would have been `Never`, 
    /// i.e. when the target is not declared as throwing.
    mutating func recordErrorType<E: Error>(errorType: E.Type) throws {
      envelope.returnType = String(reflecting: returnType)
    }
    
    /// Ad-hoc requirement
    ///
    /// Optionally, record the expected return type. 
    /// Encoding this information may not be necessary, depending on how the target identity is defined.
    mutating func recordReturnType<R: SerializationRequirement>(returnType: R.Type) throws {
      envelope.returnType = String(reflecting: returnType)
    }

    /// Invoked when all the `record...` calls have been completed and the `DistributedTargetInvocation`
    /// will be passed off to the `remoteCall` to perform the remote call using this invocation representation.
    mutating func doneRecording() throws {
      // our impl does not need to do anything here
    }

    // === Receiving / decoding -------------------------------------------------
    // ... will be discussed in following sections ... 
  }
}
```

The above invocation is constructed by the Swift runtime whenever a remote call is about to be performed. The runtime then invokes the record methods providing the invocation the chance to either serialize, or store for future serialization all the arguments. Once that is complete, the runtime will pass the constructed `Invocation` to the `remoteCall`:

```swift
 extension ClusterSystem {
  // remoteCall is not a protocol requirement, however its signature is well known to the compiler,
  // and it will invoke the method. We also are guaranteed that the 'Res: Codable' requirement is correct,
  // since the type-system will enforce this conformance thanks to the type-level checks on distributed funcs.
  func remoteCall<Act, Err, Res>(
      on actor: Act,
      target: RemoteCallTarget,
      invocation: Self.Invocation, // ClusterSystemTargetInvocation
      throwing: Err.Type,
      returning: Res.Type // TODO: to make it `: SerializationRequirement` it'd need to be an ad hoc requirement
  ) async throws -> Res.Type
      where Act: DistributedActor,
            Act.ID == ActorID.
            Res: Codable { // since SerializationRequirement == Codable
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

While the in-line comments explain a little what is going on here, let us examine these in more detail.

The overall purpose of this `remoteCall` implementation is to create some form of message that it will send to the remote node (or process) to receive and invoke the target method on the remote actor. 

In our example implementation, the `Invocation` already serialized the arguments and stored them in the `Envelope`, so the `remoteCall` only needs to add the information about the call recipient [1], and the target (method) of the call [2]. In our example implementation, we just store the target's mangled name [2], which is simple, but it has its challenges in regard to protocol evolution.

One notable issue that mangled names have is that any change in the method signature will result in not being able to resolve the target method anymore, we are very much aware of the issues this may cause to protocol evolution, and we lay out plans in [Future Directions](#future-directions) to improve the lookup mechanisms in ways that will even allow adding parameters (with default values), in wire (and ABI) compatible ways.

The final step is handing over the envelope containing the encoded arguments, recipient information etc. to the underlying transport mechanism [3]. The transport does not really have to concern itself with any of the specifics of the call, other than transmitting the bytes to the callee and the response data back. As we get the response data back, we have the concrete type of the expected response and can attempt to decode it [4].

>  **Note:** During this proposal we frequently refer to an "`Envelope`", however this isn't any specific type that is part of the proposal. 
>
>  It is a general pattern that every actor system will end up implementing in their own way, depending on the transport and serialization layers employed. For example, with a network transport and `Codable` serialization it could simply be an `struct Envelope: Codable` that contains the target method mangled name, the encoded message.

#### Receiving Remote Calls

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

#### Deserializing incoming Invocations

Now that we have received all the bytes for one specific envelope, we need to perform a two-step deserialization on it. 

First, we'll need to decode the target identifier (e.g. method name, mangled method name, or some form of ID), and the actor `ID` of the recipient. These are necessary to decode always, as we need to locate both the method and actor we're trying to invoke.

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
extension ClusterSystem.ClusterTargetInvocation { // TODO: Split it into 2 separate "sides"
    
  // === Receiving / decoding -------------------------------------------------
  
  typealias ArgumentDecoder = ClusterTargetArgumentDecoder
  
  // FIXME: would like the visitor here too to avoid the array...
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

  mutating func argumentDecoder() -> Self.ArgumentDecoder { 
    return ClusterTargetArgumentDecoder(from: &self.bytes)
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
- 0...1 invocation of  `argumentDecoder`,
  - 0...n invocations of `decoder.decodeNext(Argument.self)`
- 0...1 invocations of `decodeReturnType`
- 0...1 invocations of `decodeErrorType`.

The argument decoder is the most interesting of all of those steps, because it has to perform actual decoding of the arguments from the stored bytes in the envelope to the expected `Argument` types. This is another case where the arguments being able to statically guarantee conforming to the `SerializationRequirement` is a great benefit, as the implementation of the type can just rely on this to perform the decoding:

```swift
extension ClusterSystem { 
  internal struct ClusterTargetArgumentDecoder: DistributedTargetInvocationArgumentDecoder {
    associatedtype SerializationRequirement = Codable
    
    let system: ClusterSystem
    var bytes: ByteBuffer

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
    mutating func decodeNext<Argument: SerializationRequirement>(
      into pointer: UnsafeMutablePointer<Argument> // pointer to our hbuffer
    ) throws {
      try nextDataLength = try bytes.readInt()
      let nextData = try bytes.readData(bytes: nextDataLength)
      // again, we are guaranteed the values are Codable, so we can just invoke it:
      let argument = system.decoder.decode(as: Argument.self, from: bytes)
      pointer.initialize(argument)
    }
  }
}
```

Since this is executed on the _recipient_ node, we may not actually have a version of the user-library where the arguments indeed conform to the required `SerializationRequirement` - if that is the case, the `executeDistributedTarget` method will throw signaling this issue, and we can handle it gracefully by returning a decoding error to the caller.

If the type conformances are correct though, the decoding implementation is fairly simple for authors of the distributed systems, and they can use all type information to do so, e.g. implementing a `Decodable` based `decodeNext` is pretty simple (as it would be with protocol buffers or similar APIs as well.)

It is worth to point out the shape of the `decodeNext(into:)` API in the sense that we never *return* the decoded value, but instead write it directly into the `UnsafeMutablePointer` provided to the call.

The reason we implement it this way is efficiency: the Swift runtime is able to stack-allocate a slab of memory for all the expected arguments that the call expects (thanks to looking-up the local `distributed func`), and vend specific pointers to the "slots" where each argument should be decoded into. It is not possible to achieve this level of efficiency with returning values, because they would end up being type-erased and wrapped using existential wrappers (in `Any`). 

While this API shape is more annoying to implement, we are comfortable putting a slightly higher burden on distributed actor system implementors, because this code is only going to be written once per system type, yet will be used many times by all kinds of distributed actor end-users, and the efficiency benefits of this design by far outweigh the slight inconvenience caused to the few implementations.

Summing up, we are convinced this "Handler-style" approach to decoding values, as well as receiving return values and errors by the distributed system implementation, gives us the best of all worlds:

- nowhere in this API will values be subject to existential boxing which would be detrimental to performance of high-performance focused systems
- network buffers never need to be copied, or converted to any specific format, systems can use whichever buffers they got the data in directly, potentially even allowing for zero-copy style deserialization
- the runtime is not opinionated about network buffer types, they could be anything (Data, NIO.ByteBuffer, or even memory mapped files)
- developers only deal with concrete types, and no special handling is needed to handle generic parameters
- the visiting of parameters in order makes implementations that read from a single continuous buffer as well as "one by one" from a set of Data objects simple

This design allows us to strive for the most high-performance messaging implementations possible, while also allowing pretty convenient usage in heavier implementations which may not have go to these extreme lengths to achieve their performance goals.

> **Note:** This proposal does not include an implementation for the mentioned `summonType(byName:)` function, it is just one way systems may choose to implement these functions. Possible implementations include: registering all "trusted" types, using mangled names, or something else entirely. This proposal has no opinion about how these types are recovered from the transmitted values.

#### Resolving the Recipient 

The first step to prepare the invocation is to resolve the target actor. We discussed how resolving actors works in [Resolving Distributed Actors](#resolving-distributed-actors), however in this section we can tie it into the real process of invoking the target function as well.

In the example we're following so far, the recipient resolution is simple because we have the recipient id available in the `Envelope.recipientID`, so we only need to resolve that using the system that is receiving the message:

```swift
let actor: DistributedActor = try self.resolveAny(id: envelope.recipientID) // where self is a DistributedActorSystem
```

The implementation here is the same as implementing the `DistributedActorSystem.resolve` just that it doesn't have to cast to a specific actor type -- it is not really necessary to perform the invocation. 

If we needed to, we could confirm though if the actor is of the right type, by using the `actorType` of the resolved `DistributedFunction`, like this:

```swift
let actor: DistribtuedActor = try self.resolve(id: envelope.recipientID, as: dfunc.actorType)
// which internally does:
//   let anyActor = self.resolveAny(id: id)
//   if anyActor as? dfunc.actorType else {
//     throw ResolvedUnexpectedActorType(...) 
//   }
```

But since the returned value will end up erased anyway, it does not really matter all that much to try to resolve a specific type here, thus the above-mentioned `resolveAny`.

#### The `executeDistributedTarget` method

Invoking a distributed method is a tricky task, and involves a lot of type demangling, opening existential types, and tightly managing all of that in order to avoid un-necessary heap allocations to pass the decoded arguments to the target function etc. After iterating over with multiple designs, we decided to expose a single `DistributedActorSystem.executeDistributedTarget` entry point. It efficiently performs all the above operations, while allowing distributed actor systems developers to implement whichever coding strategy they choose, potentially directly from the buffers obtained from the transport layer.

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
      invocation: Self.Invocation,
      handler: ResultHandler
  ) async throws where Act: DistributedActor,
                       Act.ID == ActorID,
                       ResultHandler: DistributedTargetInvocationResultHandler { 
    // implemented by the _Distributed library
  }
}
```

This method encapsulates all the difficult and hard to implement pieces of the function invocation, and it accepts the target of the call, along with a `DistributedTargetInvocationResultHandler` type, that will be used for decoding the calls arguments, as well as receiving the invocations result (or error).

This handler type allows us to offer developers a type-safe, hard-to-get-wrong and highly optimized way to perform the target method invocation. We are able to avoid heap allocations for the decoded parameter values, as well as any existential wrappers, which might have been otherwise utilized in an API with a more obvious shape (i.e. by the call just returning the arguments, we would incur both existential boxing and type-cast overheads).

The `DistributedTargetInvocationResultHandler` is defined as follows:

```swift
protocol DistributedTargetInvocationResultHandler {
  func onReturn<Res>(value: Res) async throws
  func onThrow<Err>(error: Err) async throws where Err: Error
}
```

And an implementation would usually provide a single handler type that contains logic to "send the reply" to whoever created this call.

#### Performing the distributed target call

Once we have completed all the above steps, all building up to actually invoking the target of a remote call: it is finally time to do so, by calling the `executeDistributedTarget` method:

```swift
// inside recipient actor system
let envelope: Envelope = // receive & decode ...
let recipient: DistributedActor = // resolve ...

// FIXME: make a separate type for DECODING side (!!!!!!!)
let invocation = makeInvocation(from: envelope)

try await executeDistributedTarget(
  on: recipient, // target instance for the call
  mangledName: envelope.targetName, // target func/var for the call
  invocation: invocation // will be used to perform decoding arguments,
  handler: ReplyHandler(to: envelope) // handles replying to the caller (omitted in proposal)
)
```

This call triggers all the decoding that we discussed earlier, and if any of the decoding, or distributed func/var resolution fails this call will throw. Otherwise, once all decoding has successfully been completed, the arguments are passed through the buffer to a distributed method accessor that actually performs the local method invocation. Once the method returns, its results are moved into the handler where the actor system takes over in order to send a reply to the remote caller - completing the remote call!

For sake of completeness, the listing below shows the distributed method accessor thunk that is synthesized by the compiler. The thunk is passed the memory buffer into which argument values have just been stored during the `decodeArgument` calls on the `Invocation`. The thunk unpacks the well-typed buffer that contains the method call arguments into local variables, and invokes the actual target, like this:

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

#### Collecting result/error from the Invocation

Now that the distributed method has been invoked, it eventually returns or throws an error. 

Collecting the return (or error) value is also implemented using the `DistributedMethodInvocationHandler` we passed to the `invoke(...)` method before. This is done for the same reason as parameters: we need a concrete type in order to efficiently pass the values to the actor system, so it can encode them without going through existential wrappers. As we cannot implement the `invoke()` method to be codable over the expected types -- we don't know them until we've looked up the actual method we were about to invoke (and apply generic substitutions to them).

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

- 1.2 Drop implicitly distributed methods
- 1.1 Implicitly distributed methods
- 1.0 Initial revision
- [Pitch: Distributed Actors](https://forums.swift.org/t/pitch-distributed-actors/51669)
  - Which focused on the general concept of distributed actors, and will from here on be cut up in smaller, reviewable pieces that will become their own independent proposals; Similar to how Swift Concurrency is a single coherent feature, however was introduced throughout many interconnected Swift Evolution proposals.
