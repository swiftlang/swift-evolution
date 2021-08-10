# Distributed Actors

* Proposal: [SE-NNNN](NNNN-distributed-actors.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Dario Rexin](https://github.com/drexin), [Doug Gregor](https://github.com/DougGregor), [Tomer Doron](https://github.com/tomerd), [Kavon Farvardin](https://github.com/kavon)
* Review Manager: TBD
* Status: **Implementation in progress**
* Implementation: 
  * Partially available in [recent `main` toolchain snapshots](https://swift.org/download/#snapshots) behind the `-enable-experimental-distributed` feature flag. 
  * This flag also implicitly enables `-enable-experimental-concurrency`.

## Table of Contents


<!-- @import "[TOC]" {cmd="toc" depthFrom=1 depthTo=6 orderedList=false} -->

<!-- code_chunk_output -->

- [Distributed Actors](#distributed-actors)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Motivation](#motivation)
  - [Proposed solution](#proposed-solution)
    - [Distributed actors](#distributed-actors-1)
      - [Properties](#properties)
      - [Methods](#methods)
      - [Initialization](#initialization)
    - [RPC Example](#rpc-example)
  - [Detailed design](#detailed-design)
    - [Location Transparency](#location-transparency)
    - [Typechecking Distributed Actors](#typechecking-distributed-actors)
      - [Protocol Conformances](#protocol-conformances)
        - [Default Conformances](#default-conformances)
      - [Distributed Methods](#distributed-methods)
    - [Distributed Actor initialization](#distributed-actor-initialization)
      - [Local Initialization](#local-initialization)
      - [Remote Resolution](#remote-resolution)
      - [Deinitialization](#deinitialization)
    - [Actor Transports](#actor-transports)
      - [Transporting Errors](#transporting-errors)
      - [Actor Identity](#actor-identity)
    - [Sharing and Discovery](#sharing-and-discovery)
      - [Distributed Actors are `Codable`](#distributed-actors-are-codable)
      - [Discovering Existing Instances](#discovering-existing-instances)
  - [Alternatives Considered](#alternatives-considered)
    - [Creating only a library and/or tool](#creating-only-a-library-andor-tool)
    - [Special Actor spawning APIs](#special-actor-spawning-apis)
      - [Explicit `spawn(transport)` keyword-based API](#explicit-spawntransport-keyword-based-api)
      - [Global eagerly initialized transport](#global-eagerly-initialized-transport)
      - [Directly adopt Akka-style Actors References `ActorRef<Message>`](#directly-adopt-akka-style-actors-references-actorrefmessage)
  - [Acknowledgments & Prior Art](#acknowledgments-prior-art)
  - [Source compatibility](#source-compatibility)
  - [Effect on ABI stability](#effect-on-abi-stability)
  - [Effect on API resilience](#effect-on-api-resilience)
  - [Changelog](#changelog)
- [Appendix](#appendix)
  - [Runtime implementation details](#runtime-implementation-details)
      - [Remote `distributed actor` instance allocation](#remote-distributed-actor-instance-allocation)
      - [`distributed func` internals](#distributed-func-internals)
  - [Future Directions](#future-directions)
      - [The `AnyActor` marker protocol](#the-anyactor-marker-protocol)
    - [Storing and requiring more specific Transport types](#storing-and-requiring-more-specific-transport-types)
    - [Ability to customize parameter/return type requirements](#ability-to-customize-parameterreturn-type-requirements)
    - [Resolving DistributedActor bound protocols](#resolving-distributedactor-bound-protocols)
    - [Synthesis of `_remote` and well-defined `Envelope<Message>` functions](#synthesis-of-_remote-and-well-defined-envelopemessage-functions)
    - [Support for `AsyncSequence`](#support-for-asyncsequence)
    - [Ability to hardcode actors to specific shared transport](#ability-to-hardcode-actors-to-specific-shared-transport)
    - [Actor Supervision](#actor-supervision)
  - [Related Work](#related-work)
    - [Swift Distributed Tracing integration](#swift-distributed-tracing-integration)
    - [Distributed `Deadline` propagation](#distributed-deadline-propagation)
    - [Potential Transport Candidates](#potential-transport-candidates)
  - [Background](#background)

<!-- /code_chunk_output -->



## Introduction

Swift's [actors](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md) are a relatively new building block for creating concurrent programs. The mutable state isolated by actors can only be interacted with by one task at any given time, eliminating a whole class of data races. But, the general [actor model](https://en.wikipedia.org/wiki/Actor_model) works equally well for distributed systems too.

This proposal introduces *distributed actors*, which are an extension of regular Swift actors that allows developers to take full advantage of the general actor model of computation. Distributed actors allow developers to scale their actor-based programs beyond a single process or node, without having to learn many new concepts.

Unlike regular actors, distributed actors take advantage of *[location transparency](https://en.wikipedia.org/wiki/Location_transparency)*, which relies on a robust, sharable handle (or name) for each actor instance. These handles can reference actor instances located in a different program process, which may even be running on a different machine that is accessible over a network. After resolving an actor handle to a specific instance located _somewhere_, the basic interactions with the actor instance closely mirrors that of regular actors. Distributed actors abstract over the communication mechanism that enables location transparency, so that the implementation can be extended to different domains. 

<!--
### Roadmap

 TODO: pointer to Background section?
After reading the proposal, we also recommend having a look at the [Background](#background), which may be useful to understand the big picture and how multiple Swift evolution proposals and libraries come together to support this proposal.
-->



## Motivation

Distributed systems are not just for high-performance computing. Many of the programs written today are part of a distributed system. If your program uses *any* kind of [inter-process communication](https://en.wikipedia.org/wiki/Inter-process_communication) (IPC), i.e., it communicates with entities outside of its process on the same or a different machine, then it can be viewed as a distributed system. Real-world examples include networked applications, such as games, chat or media applications.

Distributed systems are pervasive, yet they require significant effort to implement in Swift. Consider this simple example of code that establishes a connection with a server and listens for messages that trigger some action:

```swift
import Foundation

actor Counter {
  var count: Int = 0
  func increment() {
    count += 1
  }
  func get() -> Int { return count }
}

class ConnectionManager {
  var connection: URLSessionWebSocketTask
  var state: Counter

  // Initialize a connection with the other server
  // and begin listening for messages.
  init?(_ serverURL: URLRequest, sharing counter: Counter) {
    state = counter
    connection = URLSession.shared.webSocketTask(with: serverURL)
    guard connection.error != nil else {
      return nil
    }
    listenLoop()
  }

  private func listenLoop() {
    Task.detached {
      switch try? await self.connection.receive() {
        case .some(let message):
          // NOTE: skip message deserialization; assume 1 message kind!
          await self.state.increment()  // perform action on local instance
          self.listenLoop() // listen for the next connection.
        default:
          return // end listen loop
      }
    }
  }

  deinit {
    connection.cancel(with: .normalClosure, reason: nil)
  }
}

let counter = Counter() // some shared actor instance

// Start the connection!
let serverReq = URLRequest(url: URL(string: "http://example.com:1337")!)
let c = ConnectionManager(serverReq, sharing: counter)
```

This is a barebones implementation of a unidirectional remote-procedure call (RPC), where the code above corresponds to the receiver's side that implements the requests, but does not perform responses. In this example, notice the reliance on a regular actor to synchronize accesses to its state, because the state can be accessed on the reciever's side too. While the sender-side code is omitted, it is already apparent that the basic pieces of an RPC-based distributed program involves:

1. Resolving / maintaining a connection.
2. Serializing and deserializing messages.
3. Servicing requests.

 The distributed actors in this proposal are designed to model an actor whose instance may be located in another program process. This means that the sender side can interact with the `Counter`'s state without the extra boilerplate. Specifically, distributed actors abstract over the actor's identifier and the communication transport, such as TCP/UDP, WebSocket or cross-process transports like XPC. This abstraction allows distributed code to focus on the implementation of the distributed actor's operations, using the familiar syntax and semantics of Swift's regular actors, and without needing to implement the communication in an ad-hoc manner. The same definition of a distributed actor is compatible with various identity and transport implementations, instances of which can even co-exist simultaneously in the same process.

## Proposed solution

There are several new concepts introduced by this proposal, which will be described in this section.

### Distributed actors

Distributed actors are a special flavor of the actor type that enforces additional rules on the type and its values, in order to achieve location transparency. They are written by prepending `distributed` to an actor declaration, like so:

```swift
distributed actor Player {
  let name: String
  var score: Int
  var teammates: [Player]
}
```

Distributed actors adopt the same isolation rules of regular actors, but because any instance may actually refer to an actor in another process (i.e., location transparency), extra rules are applied.

#### Properties
Developers should think carefully about operations that cross into the actor's isolation domain, because the cost of each operation can be expensive (e.g., if the actor is on a machine across the internet). Properties make it very easy to accidentially make multiple round-trips:

```swift
func example1(p: Player) async throws -> (String, Int) {
  try await (p.name, p.score) // ❌ might make two slow round-trips to `p`
}
```

Instead, methods are strongly encourged so that accesses can be batched.
Thus, access to a distributed actor's properties (stored and computed) from outside of the actor's isolation are forbidden. In addition, properties cannot be `nonisolated` or participate in a key-path.

#### Methods

Regular methods isolated to the distributed actor are not accessible from outside of the actor's isolation context. A new kind of method declaration, called a *distributed method*, are the only kind of isolated members that can be accessed from outside of a distributed actor. Nonisolated methods can be defined as usual, but a distributed method cannot be marked `nonisolated`. A distributed method is defined within a distributed actor by writing `distributed` in front of the method's declaration:

```swift
extension Player {
  distributed func addTeammate(p: Player) {
    guard !haveTeammate(p) else {
      return
    }
    teammates.append(p)
  }

  func haveTeammate(p: Player) -> Bool {
    return teammates.contains(p)
  }
}

func example2(a: Player, b: Player) async throws {
  a.haveTeammate(b) // ❌ error, function not `distributed`
  
  try await a.addTeammate(b)  // ✅ OK. distributed actors are Codable!
}
```

In addition to conforming to `Sendable`, a distributed function's parameters and its return type are all required to conform to the [`Codable` protocol](https://developer.apple.com/documentation/swift/codable). A codable value supports serialization and deserialization, which is nessecary in order to maintain location transparency. For example, servicing a method call on a distributed actor instance can involve sending the arguments to another process and awaiting a response.

Like a regular actor method, an expression that calls a distributed function is  treated as `async` from outside of the actor's isoalation. But for a distributed actor, such calls are _also_ treated as `throws` when outside of the actor's isolation, because a request to call a distributed method is not guaranteed to recieve a response. The underlying process that hosts the distributed actor instance may be on another machine that crashed, or a connection may be lost, etc. To help make this clear, consider the following example, which contains only the nessecary `try` and `await` expressions:

```swift
distributed actor Greeter {
  distributed func englishGreeting() -> String { "Hello!" }
  distributed func japaneseGreeting() throws -> String { "こんにちは！" }
  distributed func germanGreeting() async -> String { "Servus!" }
  distributed func polishGreeting() async throws -> String { "Cześć!" }
  
  func inside() async throws { 
    _ = self.englishGreeting()
    _ = try self.japaneseGreeting()
    _ = await self.germanGreeting()
    _ = try await self.polishGreeting()
  }
} // end of Greeter

func outside(greeter: Greeter) async throws { 
  _ = try await greeter.englishGreeting()
  _ = try await greeter.japaneseGreeting()
  _ = try await greeter.germanGreeting()
  _ = try await greeter.polishGreeting()
}
```

Errors thrown by the underlying transport due to connection or messaging problems must conform to the `ActorTransportError` protocol. A distributed function can also be explicitly marked as `throws`, as shown above, but the underlying transport is responsible for determining how to forward any thrown errors, since errors thrown by a distributed function do _not_ have to be `Codable`.

One benefit of explicitly marking distributed functions with the `distributed` keyword that it makes clear to the programmer (and tools, such as IDEs) where networking costs are to be expected when using a distributed actor. This is an improvement over today's world, where any function might ultimately perform network calls, and we are not able to easily notice them, for example, in the middle of a tight loop.

#### Initialization
Distributed actors and functions are largely a set of a rules that enforce location transparency. In order for distributed actors to actually perform any remote communication, it is necessary to initialize them with an actual implementation of an `ActorTransport`, which is a protocol that is implementable by library writers. A *transport* handles all of the connection details that underpin distributed actors. An actor transport can take advantage of any networking, cross-process, or even in-memory approach to communicate between instances, as long as it conforms to the protocol correctly.

There are two ways to initialize a distributed actor, but in any case, a distributed actor is always associated with some `ActorTransport`. To create a new **local** instance of a distributed actor, call the actor's `init` as usual. All non-delegating initializers, which fully-initialize the distributed actor, are required to accept exactly one argument that conforms to `ActorTransport`:

```swift
distributed actor Capybara { 
  var name: String
  
  // ✅ ok. exactly one transport param for non-delegating initializer.
  init(named name: String, using: ActorTransport) {
    self.name = name
  }

  // ✅ ok. no transport param, but it's a delegating initializer.
  convenience init() {
    self.init(named: "Happybara", using: Defaults.IPoAC)
  }

  // ❌ error, too many transport params for a non-delegating init.
  init(main: ActorTransport, alt: ActorTransport) {
    self.name = "Sleepybara"
  }
  
  // ❌ error, no transports for a non-delegating init.
  init(withName name: String) {
    self.name = name
  }
}
```

Swift will automatically associate a `Capybara` instance with the transport passed to `init(named:using:)`, without the programmer explicitly using the transport argument. This is done, instead of requiring a specific `let`-bound property to be initialized, because the `ActorTransport` is specially stored in the instance, depending on whether it represents a remote or local instance of the actor.

A **remote** instance can be only be resolved if the programmer also has the instance's `ActorIdentity`. An `ActorIdentity` is a protocol that specifies the minimum capabilities of a durable, unique identifier associated with a distributed actor instance. All distributed actors have two computed properties that are accessible from anywhere, and a static `resolve` function:

```swift
public protocol DistributedActor: Sendable, Codable, Identifiable, Hashable {
  static func resolve<Identity>(id identity: Identity, using transport: ActorTransport) 
    throws -> Self
    where Identity: ActorIdentity

  /*special*/ var transport: ActorTransport { get }

  /*special*/ var id: AnyActorIdentity { get }
}
```

We refer to the creation of a remote instance as "resolving" a remote actor, because it does *not* create an instance of the distributed actor if one does not exist. The actor's identity must be valid when calling `resolve` or resolution will fail:

```swift
extension Capybara {
  distributed func meet(friend: ActorIdentity) { ... }
}

func example3(transport: ActorTransport, friend name: ActorIdentity) async throws {
  // make local instance
  let a = Capybara(using: transport)

  // resolve some other instance
  let b = try Capybara.resolve(name, using: transport)
  
  // identities are Codable
  try await a.meet(b.id)

  // resolve a local instance from an ID
  let aliasForA = try Capybara.resolve(a.id, using: transport)
}
```

**TODO:** short discussion about exchanging identities / service discovery

### RPC Example

**TODO:** the RPC example earlier, but written using distributed actors. It will assume that we already have a transport available, and got the identity from some mechanism / means. We will save discussion of the transport and identity protocols in the detailed design, since it's really meant for library writers.



## Detailed design

For clarity, a number of details about this proposal were omitted from the proposed solution. This section discusses those details. Unless otherwise specified in this proposal, the semantics of a distributed actor are the same as a regular actor, as described in [SE-306](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md).

### Location Transparency

The design of distributed actors intentionally does not provide facilities to easily determine whether an instance is local or remote. The programmer should not _need_ to think about where the instance is located, because Swift will make it work in either case. There are numerous benefits to embracing location transparency:

- The programmer can write a complex distributed systems algorithm and test it locally. Running that program on a cluster becomes merely a configuration and deployment change, without any additional source code changes.
- Distributed actors to be used with multiple transports without changing the actor's implementation.
- Actor instances can be balanced between nodes once capacity of a cluster changes, or be passivated when not in use, etc. There are many more advanced patterns for allocating instances, such as the "virtual actor" style as popularized by Orleans or Akka's cluster sharding.

One of the key restrictions that enable location transparency is the requirement that we pass arguments into the distributed actor that conform to `Codable`, so that they *can* be sent to another process if needed. But, there are some situations where the programmer _knows_ a particular instance is local to the process, so this restriction becomes bothersome.

For example, consider the [CASPaxos protocol](https://arxiv.org/abs/1802.07000), which is a popular distributed consensus protocol which performs a distributed compare-and-set operation. Its `change` API accepts a `update` closure, which cannot reliably conform to `Codable`, however local-accesses to the distributed actor would still like to make use of it:

```swift
distributed actor Registry { 
  public func change<Value: Codable>(
    key: String, 
    update: (Value?) throws -> Value
  ) async throws -> Value { /* ... */ }
}
```

Crafting a `Codable` conformance that crashes if used (i.e., on a remote instance) would allow a programmer to mark the closure-accepting method as `distributed`, but this is a poor hack. Instead, distributed actors offer a special method, called `whenLocal` that provides thread-safe access to the distributed actor's isolated members, only if the instance is locally-allocated:

```swift
extension DistributedActor { 
  /// Returns `nil` if non-local.
  @discardableResult
  /*special*/ func whenLocal<T>(
    _ body: (isolated Self) async throws -> T
  ) async rethrows -> T?
  
  /// Invokes the `else` closure if non-local.
  /*special*/ func whenLocal<T>(
    _ body: (isolated Self) async throws -> T,
    else whenRemote (Self) async throws -> T
  ) async rethrows -> T
}
```

The `whenLocal` method effectively exposes a distributed actor instance as if it were a regular actor. This means you can invoke non-distributed function when the actor instance is local, without hacks that trigger a crash if invoked on a remote instance.


### Typechecking Distributed Actors

This section discusses the semantic checking and restrictions placed on distributed actor types.

#### Protocol Conformances

A distributed actor is the only type that can conform to the `DistributedActor` protocol, and all distributed actors conform to that protocol. This protocol's list of requirements are defined earlier in this proposal, under the [Initialization section](#initialization). 

Only `distributed` or `nonisolated` methods can be specified in a distributed actor protocol `P`, which is any protocol inheriting from `DistributedActor`. This follows under the same reasoning as why `private` members cannot be stated as requirements in a protocol: the member is not be accessible from outside of the type's implementation, so it is not part of the type's interface.

> **NOTE:** One exception to this analogy with `private` is the escape-hatch method `whenLocal`, which can be used from outside of the distributed actor to strip away the location transparency. Then, an isolated method required by the protocol becomes exposed. But, this situation appears to be too niche to be worth supporting.

Importantly, a distributed actor _cannot_ conform to the Actor protocol. For example, such a conformance would fail to provide correct location transparency:

```swift
extension Actor {
  func f(x: ) -> NonCodableButSendableType { ... }
}

func g(mda: MyDistributedActor) async {
  let a: Actor = mda as Actor // ❌ error: must be disallowed because...
  let result = await a.f()    // we cannot recieve the result of `f` if remote!
}
```

Conversely, regular actors also cannot conform to the `DistributedActor` protocol because of the same principle. See the Alternatives Considered section for an `AnyActor` protocol that was under consideration, but excluded from this proposal.

##### Default Conformances

The `Equatable` and `Hashable` protocols from the Swift standard library require conformers to provide a way to distinguish between equivalent instances. When value types like structs and enums are declared to conform to these protocols, the `==` and `hash` witnesses are automatically synthesized, if the programmer does not specify them.

For distributed actors, any realistic `ActorTransport` will require conformance to `Equatable` and `Hashable`. While distributed actors are reference types, they are designed to have a stable, sharable identifier associated with each instance. Thus, Swift will automatically require that distributed actors conform to these protocols, and provide the following witnesses:

```swift
extension DistributedActor: Equatable {
  public static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }
}

extension DistributedActor: Hashable { 
  nonisolated public func hash(into hasher: inout Hasher) {
    self.id.hash(into: &hasher)
  }
}
```

It is difficult to imagine any other witnesses for these protocols, because any accesses to the actor's internal state would require an asynchronous operation.

#### Distributed Methods

A `distributed actor` type, extensions of such a type, and `DistributedActor` inherting protocols are the only places where distributed method declarations are allowed. This is because, in order to implement a distributed method, a transport and identity must be associated with the values carrying the method. Distributed methods can synchronously refer to any of the state isolated to the distributed actor instance.

As a consequence of the request-response nature of distributed methods, `inout` parameters are not supported. While subscripts are similar to methods, they are not allowed for a distributed actor. A subscript's usefulness is strongly limited by both their lack of support for being `distributed` (e.g., could only support read-only subscripts, because no coroutine-style accessors) and their lightweight syntax can lead to the same problems as properties.


### Distributed Actor initialization

The lifecycle of a distributed actor is important to consider, because it is a key part of how location transparency is achieved.

#### Local Initialization

All user-defined designated initializers of a distributed actor can be collectively referred to as "local" initializers. All local initializers of a distributed actor must accept exactly one `ActorTransport` parameter. This `ActorTransport` parameter is implicitly used to fulfil an important contract with the transport and the actor instance itself. Namely, all distributed actor instances must be assigned an `ActorIdentity`, which is provided by the transport. In addition, once fully initialized, the actor must inform the transport that it is ready to receive messages. Conceptually, these steps can be described as:

```swift
distributed actor DA {
  init(..., transport: ActorTransport) {
    // Step 1: Try to set-up the transport and identity.
    self._transport = transport
    self._id = AnyActorIdentity(transport.assignIdentity(Self.self))
    
    // Step 2: User code is executed, which may fail, access the identity, etc.
    
    // Step 3: The initializer did not fail; notify the transport.
    transport.actorReady(self)
  }
}
```

#### Remote Resolution

There is no representation of a remote initializer for a distributed actor, because a remote instance has *conceptually* already been initialized. Thanks to location transparency, remote instance is not even guaranteed to exist until it is actually needed. This is an important implementation detail that enables efficient implementations of distributed systems. To make this more concrete, consider a simplified version of the static `resolve` function that is synthesized for all distribtued actors:

```swift
distributed actor DA {  
  // Pseudocode for the implementation of actor resolution.
  static func resolve(_ identity: ActorIdentity, using transport: ActorTransport) throws -> Self {
    switch try transport.resolve(identity, as: Self.self) {
    case .instance(let instance):
      return instance
    case .proxy:
      return __runtimeMagicToAllocateProxyActor(...)
    }
  }
}
```

It is important to notice that, when the transport determines that the identity is not local, the static `resolve` only performs a memory allocation for a "proxy" representing a remote instance. Thus, resolving an actor does not neccessarily perform an inter-process action, even if the identity is for a remote instance. Inter-process actions are only guaranteed when calling a distributed method on a remote instance. Nevertheless, a resolve action may throw an error if the transport decides that it cannot resolve the passed in identity, e.g., because it is for a different transport.

In addition, it is up to the transport to determine whether an identity is local or not. This is how concepts like *virtual actors* may be implemented. While discussing the semantics of virtual actors is out of scope for this proposal, the ability to possibly support them in the future is important.

A distributed actor's static resolve function, and the related `ActorTransport.resolve` function, are not offered as an `async` function, because the `Codable` infrastructure is not currently async-ready. But, most kinds of transports should not require an asynchronous `resolve`, because actor resolution is typically implemented using local knowledge.

#### Deinitialization

**TODO**: briefly discuss what happens during deinitialization under-the-hood, and make it clear that distributed actors _do_ otherwise support deinitializers. :)

### Actor Transports

Swift users are need to provide their own implementation of an `ActorTransport`, in order to use distributed actors. It is expected that most users will use an existing library that implements the desired kind of transport infrastructure. But, users are free to implement their own `ActorTransport` according to the following protocol:

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

At a high-level, a transport has two major responsibilities:

- **Lifecycle management:** creating and resolving actor identifies, which are used by the Swift runtime to construct distributed actor instances.
- **Communication:** perform all message dispatch and handling on behalf of a distributed actor it manages.

-------
**TODO:** turn all of these bullet-points into prose, possibly including a pseudo-code summary. Then merge it with the text below it all the way through this section (and its subsection).

Specifically:
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

The specific encoder/decoder choice is left up to the specific transport that the actor was created with. It is legal for a distributed actor transport to impose certain limitations, e.g. on message size or other arbitrary runtime checks when forming and sending remote messages. Distributed actor users may need to consult the documentation of such transport to understand those limitations. It is a non-goal to abstract away such limitations in the language model. There always will be real-world limitations that transports are limited by, and they are free to express and require them however they see fit (including throwing if e.g. the serialized message would be too large etc.)

#### Transporting Errors

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

#### Actor Identity

A distributed actor's identity is defined by its `id` property which stores an instance of the `ActorIdentity` type. 

A distributed actor's identity is automatically assigned and managed during its initialization. Refer to the section on [Distributed Actor initialization](#distributed-actor-initialization) for more details.

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

### Sharing and Discovery

**TODO:** reorder and summarize the text in this section

#### Distributed Actors are `Codable`

Distributed actors are `Codable` and are represented as their _actor identity_ in their encoded form.

In order to be true to the actor model's idea of freely shareable references, regardless of their location (see [*location transparency*](#location-transparency)), we need to be able to pass distributed actor references to other--potentially remote--distributed actors.

This implies that distributed actors must be `Codable`. However, the way that encoding and decoding is to be implemented differs tremendously between _data_ and active entities such as _actors_. Specifically, it is not desirable to serialize the actor's state - it is after all what is isolated from the outside world and from external access.

The `DistributedActor` protocol also conforms to `Codable`. As it does not make sense to encode/decode "the actor", per se, the actor's encoding is specialized to what it actually intends to express: encoding an identity, that can be resolved on a remote node, such that the remote node can contact this actor. This is exactly what the `ActorIdentity` is used for, and thankfully it is an immutable property of each actor, so the synthesis of `Codable` of a distributed actor boils down to encoding its identity:

```swift
extension DistributedActor: Codable {
  nonisolated func encode(to encoder: Encoder) throws { 
    var container = encoder.singleValueContainer()
    try container.encode(self.actorAddress)
  }
}
```

Decoding is slightly more involved, because it must be triggered from _within_ an existing transport. This makes sense, since it is the transport's internal logic which will receive the network bytes, form a message and then turn to decode it into a real message representation before it can deliver it to the decoded and resolved recipient. 

In order for decoding of an Distributed Actor to work on every layer of such decoding process, a special `CodingUserInfoKey.distributedActorTransport` is used to store the actor transport in the Decoder's `userInfo` property, such that it may be accessed by any decoding step in a deep hierarchy of encoded values. If a distributed actor reference was sent as part of a message, this means that it's `init(from:)` will be invoked with the actor transport present. 

The default synthesized decoding conformance can therefore automatically, without any additional user intervention, decode itself when being decoded from the context of any actor transport. The synthesized initializer looks roughly like this:

```swift
extension DistributedActor {
  /*special*/ init(from decoder: Decoder) throws {
    guard let transport = self.userInfo[.transport] as? ActorTransport else {
      throw DistributedActorDecodingError.missingTransportUserInfo(Self.self)
    }
    let container = try decoder.singleValueContainer()

    let identity = try container.decode(AnyActorIdentity.self)
    self = try Self(resolve: identity, using: transport)
  }
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

#### Discovering Existing Instances

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

## Alternatives Considered

This section summarizes various points in the design space for this proposal that have been considered, but ultimately rejected from this proposal.


### Creating only a library and/or tool

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


# Appendix

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

#### The `AnyActor` marker protocol

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

## Background

There are a number of resources and related documents within the Swift ecosystem that aid in understanding the motivation and design of distributed actors.

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