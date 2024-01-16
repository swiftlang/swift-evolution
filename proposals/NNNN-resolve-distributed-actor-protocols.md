# Resolve DistributedActor protocols

* Proposal: [SE-NNNN](NNNN-resolve-distributed-actor-protocols.md)
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status:  **Implementation in progress**
* Implementation: [PR #70928](https://github.com/apple/swift/pull/70928)
* Review: [Review](https://forums.swift.org/t/se-0417-task-executor-preference/68958)
* Discussion threads:
  * TBD

## Introduction

Swift's distributed actors offer developers a flexible bring-your-own-runtime approach to building distributed systems using the actor paradigm. The initial design of the feature aimed for systems where all nodes of a distributed actor system (such as nodes in a [cluster](https://github.com/apple/swift-distributed-actors)) share the same binary, and therefore all have access to the concrete `distributed actor` declarations which may be resolved and made remote calls on.

This works well for peer-to-peer systems, however distributed actors are also useful for systems where a more client/server split is necessary. Examples of such use-cases include isolating some failure prone logic into another process, or split between a client without the necessary libraries or knowlage how to implement an API and delegating this work to a backend service.

## Motivation

Distributed actors allow to abstract over the location (i.e. in process or not) of an actor -- often referred to as "location transparency". Currently, Swift's distributed actors have a practical limitation in how well this property can be applied to server/client split applications because the only way to obtain a *remote reference* on which a *remote call* can be made, is by invoking the resolve method on a concrete distributed actor type, like this:

```swift
import Distributed
import DistributedCluster // github.com/apple/swift-distributed-actors

distributed actor Greeter {
  typealias ActorSystem = ClusterSystem
  
  func greet(name: String) -> String {
    "Hello, \(name)!"
  }
}

let system: ClusterSystem = ...

let knownID: Greeter.ID = /* obtained ID using discovery mechanisms, see ClusterSystem */
let remote: Greeter = try Greeter.resolve(id: knownID, using: system)

// remote call (implicitly async and throwing, due to e.g. network errors)
let greeting = try await remote.greet(name: "Caplin")
assert(greeting == "Hello, Caplin!")
```

This is common and acceptable in a **peer-to-peer system**, where all nodes of a cluster share the same types -- or at least a "client side" of a connection can only discover types it knows about, e.g. during version upgrade rollouts. However, this pattern is problematic in a **client/server deployment**, where the two applications do not share the concrete implementation of the `Greeter` type.

The goal of this proposla is to allow the following module approach to sharing distributed actor APIs:

- API module: allow sharing a `DistributedActor` constrained protocol, which only declares the API surface the server is going to expose
- Server module: which depends on API module, and implements the API description using a concrete distributed actor
- Client module: which depends on API module, and uses the `DistributedActor` constrained protocol to resolve and obtain a remote reference to the server's implementation; without knowladge of the concrete type.

```swift
                         ┌────────────────────────────────────────┐
                         │                API Module              │
                         │========================================│
                         │ protocol Greeter: DistributedActor {   │
                 ┌───────┤   distributed func greet(name: String  ├───────┐
                 │       │ }                                      │       │
                 │       └────────────────────────────────────────┘       │
                 │                                                        │
                 ▼                                                        ▼   
┌────────────────────────────────────────────────┐      ┌──────────────────────────────────────────────┐
│             Client Module                      │      │               Server Module                  │
│================================================│      │==============================================│
│ let g: any Greeter = try .resolve(...) /*new*/ │      │ distributed actor EnglishGreeter: Greeter {  │
│ try await greeter.hello(name: ...)             │      │   distributed func greet(name: String){      │
└────────────────────────────────────────────────┘      │     "Greeting in english, for \(name)!"      │
                                                        │ }                                            │
                                                        └──────────────────────────────────────────────┘
```

In this scenario the client module (and application) has no knowladge of concrete distributed actor type or implementation.

In order to achieve this, this proposal improves upon two aspects of distributed actors:

- introduce the ability call `resolve(id:using:)` on a protocol type, rather than having to create an empty "stub" type manually
- extend the distributed metadata section such that a distributed method which is witness to a distributed requirement, is also recorded using the protocol method's `RemoteCallTarget.identifier` and not only the concrete method's

## Proposed solution

### Resolve method on protocols

The resolve method is the entry point to locate and return a local or remote distributed actor reference, depending on where the distributed actor system implementation determines the ID to be pointing at.

With concrete distributed actors, this method is declared as a static requirement on the DistributedActor protocol, and its implementation is synthesized by the compiler for every concrete distributed actor. This is necessarily synthesized, because a remote distributed actor reference is a special kind of object that is allocated as a "small shim" rather than the complete state of the object. The declaration for the concrete distributed actor resolve is as follows:

```swift
@available(SwiftStdlib 5.7, *)
public protocol DistributedActor: AnyActor, Identifiable, Hashable 
  where ID == ActorSystem.ActorID, 
        SerializationRequirement == ActorSystem.SerializationRequirement {
          
  static func resolve(id: ID, using system: ActorSystem) throws -> Self
}
```

This method, so far, was not possible to call on a protocol, i.e. with

### Extend Distributed metadata for protocol method identifier lookups

The way distributed method invocations work on the receipient node is that a message is parsed from some incoming transport, and a `RemoteCallTarget` is recovered. The remote call target in currently is a mangled encoding of the concrete distributed method the call was made for, like this:

A shared module introducing the `Capybara` protocol:

```swift
// Module "Shared"
public protocol Capybara where ActorSystem == ... {
  distributed var name: String { get }
  distributed func eat()
}
```

And a server component implementing it with a concrete type:

```swift
// Module "ServerAnimals"
distributed actor Caplin: Capybara { 
  distributed var name: String { "Caplin" }
  distributed func eat() { ... }
}

// RemoteCallIdentifier = mangled("Animals.Capybara.eat()"
```

The identifier currently includes the fully qualified identity of the method, including its module and type names, and parameters. This is a limiting afactor for protocol based remote calls, since the client side is not aware of `Caplin` distributed actor implementing the `Capybara` protocol.

The distributed actor runtime stores static metadata about distributed methods, such that the `executeDistributedTarget(on:target:invocationDecoder:handler:)` method is able to turn the mangled `RemoteCallIdentifier` into a concrete method handle that it then invokes. Since the remote caller has no idea about the concrete implementation type (or even module) or the `Caplin` type, this lookup will currently fail.

This proposal introduces additional metadata such that when calling the eat method on a resolved remote `any Capybara` reference, the created `RemoteCallIdentifier` will be the mangling of the method requirement, rather than that of any specific concrete distributed actor type.

We can illustrate the new remoteCall flow like this:

**Caller, i.e. client side:**

```swift
// Module MyClientApp

let discoveredCaplinID = ...
let capybara: any Capybara = try .resolve(id: discoveredCaplinID, using: system)

// make the remote call, without knowing the concrete 
// capybara type that we'll invoke on the remote side
let name = try await capybara.name

// invokes selected actor system's remoteCall:
//   DistributedActorSystem.remoteCall(
//     on: someCapybara, 
//     target: RemoteCallIdentifier("Shared.Capybara.name"), <<< PROTOCOL REQUIREMENT MANGLING
//     invocation: <InvocationEncoder>, 
//     throwing: Never.self, 
//     returnType: String.self) 
// -------

assert("Hello, \(name)!" ==
       "Hello, Caplin!")
```

The caller just performed a normal remote call as usual, however the Distributed runtime offered a protocol based remote call identifier (`RemoteCallIdentifier("Shared.Capybara.name")`) rather than one based on some underlying type that is hidden under the `any Capybara` existential.

Developers need not know or care about what concrete implementation (or stub implementation) is used to implement this call, as it will only ever be performing such distributed protocol based calls.

**Recipient, i.e. server side:**

```swift
// Module MyActorSystem

final class MySampleDistributedActorSystem: DistributedActorSystem, ... {
  // ... 
  
  func findById(_ id: ActorID) -> (any DistributedActor)? { ... }
  
  func receiveMessage() async throws {
    let envelope: MyTransportEnvelope = await readFromNetwork()
    guard let actor = findById(envelope.id) else {
      throw TargetActorNotFound(envelope.id)
    }

    // RemoteCallIdentifier("Shared.Capybara.name") <<< 
    let target: RemoteCallTarget = envelope.target 
    try await executeDistributedTarget(
      on: actor,
      target: target, // the protocol method identifier
      invocationDecoder: invocation.makeDecoder(),
      handler: resultHandler
    }
)
```

This logic is exactly the same as any existing `DistributedActorSystem` implementation -- however changes in the Distributed runtime will handle the protocol method invocation and be able to route it to the concrete resolved actor (returned by `findByID` in this snippet, e.g. the `Caplin` concrete type).

## Future directions

### Improve tools for non-breaking protocol evolution

While this approach allows sharing protocols as source of "truth" for APIs vended by a server, their capability to evolve over time is limited.

We find that the needs of distributed protocol evolution overlap in some parts with protocol evolution in binary stable libraries. While removing an API would always be breaking, it should be possible to automatically deprecate one method, and delegate to another by adding a new parameter and defaulting it in the deprecated version.

This could be handled with declaration macros, introducing a peer method with the expected new API:

```swift
protocol Greeter: DistributedActor { 
  @Distributed.Deprecated(newVersion: greet(name:), defaults: [name: nil])
  distributed func greet() -> String 
  
  // whoops, we forgot about a name parameter and need to add it...
  // We can delegate from greet() to greet(name: nil) automatically though!
}
```

The deprecation macro could generate the necessary delegation code, like this:

```swift 
protocol Greeter: DistributedActor { 
  @Distributed.Deprecated(newVersion: greet(name:), defaults: [name: nil])
  distributed func greet() -> String
  
/***
  distributed func greet(name: String?) -> String 
 ***/
}

/***
extension Greeter {
  /// Default implementation for deprecated ``greet()``
  /// Delegates to ``greet(name:)``
  distributed func greet() -> String {
    self.greet(name: nil)
  }
}
 ***/
```

This simplified snippet does not solve the problem about introducing the new protocol requirement in a binary compatible way, and we'd have to come up with some pattern for it -- however the general direction of allowing introducing new versions of APIs with easier deprecation of old ones is something we'd like to explore in the future.

### Consider customization points for distributed call target metadata assignment

Currently the metadata used for remote call targets is based on Swift's mangling scheme. This is sub-optimal as it includes slightly "too much" information, such as the parameters being classes or structs, un-necessarily wire causing wire-incompatible changes when one could handle them more gracefully.

Another downside of using the mangling for the keys of the distributed method accessor identifiers is that the names can be rather long as mangling is pretty verbose. It is possible to avoid sending then complete metadata by using compression schemes such that each identifier can only be sent at-most-once over the wire, and later on a numeric representation is used between the peers. Such scheme would need to be implemented dynamically at runtime and involves some tricky logic. It would be interesting to provide a hook in the actor system to allow for consistent remote call target identifier assignment, such that the identifiers could be both small, and predictable on both sides of a system. 

This would require introducing a dynamic lookup table in the runtime and it would need to interoperate with any given distributed actor system... It remains unclear if this is a net win, or un-necessary complexity since each actor system may handle this slightly differently...

### Utilize distributed method metadata for auditing

Given the information in distributed metadata, we could provide a command line application, or rather extend `swift-inspect` to be able to inspect a binary or runninb application for the distributed entry points to the application. 

This is useful as it allows auditors to quickly scan for all potential distributed entry points into an application, making auditing easier and more reliable than source scanning as it can be performed on the final artifact of a build.

## Alternatives considered

### Restrict distributed actors only to peer-to-peer systems

Since this feature expands the usefulness of distributed actors to client/server settings, we should discuss wether or not this is a good idea to begin with.

This topic has been one of heated discussions in various ecosystems every time distributed actor systems are compared to source-generation based RPC systems (such as gRPC, or OpenAPI, and others like SOAP and others in earlier days).

Distributed actors in Swift have the unique position of being placed in a language that deeply embraces the actor model. There are valid reasons to NOT use distributed actors in some situations, and e.g. prefer exposing your APIs over OpenAPI or other source generation tools, especially if one wants to treat these as the "source of truth."

At the same time though, Swift is used in many exciting domains where the use of OpenAPI, or gRPC would be deemed problematic. We are interested in supporting IPC and other low-level systems which are tightly integrated with eachother, and frequently even maintained by the same teams or organizations. Deeply integrating the language, with auditing capabilities and control over distributed process boundaries, without having to step out to secondary source generation and tools is a very valuable goal in these scenarios.


## Revisions

- 1.0
  - Initial revision