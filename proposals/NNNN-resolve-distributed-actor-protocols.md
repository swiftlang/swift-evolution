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

Although this works well for peer-to-peer systems, distributed actors are also useful for systems where a client/server split is necessary. Examples of such use-cases include isolating some failure prone logic into another process, or split between a client without the necessary libraries or knowledge how to implement an API and delegating this work to a backend service.

## Motivation

Distributed actors allow to abstract over the location (i.e. in process or not) of an actor -- often referred to as "location transparency". Currently, Swift's distributed actors have a practical limitation in how well this property can be applied to server/client split applications because the only way to obtain a *remote reference* on which a *remote call* can be made, is by invoking the resolve method on a concrete distributed actor type, like this:

```swift
import Distributed
import DistributedCluster // github.com/apple/swift-distributed-actors

protocol Greeter: DistributedActor {
  distributed func greet(name: String) -> String
}

distributed actor EnglishGreeter: Greeter {
  typealias ActorSystem = ClusterSystem
  
  func greet(name: String) -> String {
    "Hello, \(name)!"
  }
}

let system: ClusterSystem = ...

let knownID: EnglishGreeter.ID = /* obtained ID using discovery mechanisms, see ClusterSystem */
let remote: EnglishGreeter = try EnglishGreeter.resolve(id: knownID, using: system)

// remote call (implicitly async and throwing, due to e.g. network errors)
let greeting = try await remote.greet(name: "Caplin")
assert(greeting == "Hello, Caplin!")
```

This is common and acceptable in a **peer-to-peer system**, where all nodes of a cluster share the same types -- or at least a "client side" of a connection can only discover types it knows about, e.g. during version upgrade rollouts. However, this pattern is problematic in a **client/server deployment**, where the two applications do not share the concrete implementation of the `Greeter` type.

The goal of this proposal is to allow the following module approach to sharing distributed actor APIs:
- API module: allow sharing a `DistributedActor` constrained protocol, which only declares the API surface the server is going to expose
- Server module: which depends on API module, and implements the API description using a concrete distributed actor
- Client module: which depends on API module, and uses the `DistributedActor` constrained protocol to resolve and obtain a remote reference to the server's implementation; without knowledge of the concrete type.

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
│ let g: any Greeter = try #resolve(...) /*new*/ │      │ distributed actor EnglishGreeter: Greeter {  │
│ try await greeter.hello(name: ...)             │      │   distributed func greet(name: String){      │
└────────────────────────────────────────────────┘      │     "Greeting in english, for \(name)!"      │
/* Client cannot know about EnglishGreeter type */      │ }                                            │
                                                        └──────────────────────────────────────────────┘
```

In this scenario the client module (and application) has no knowledge of the concrete distributed actor type or implementation.

In order to achieve this, this proposal improves upon two aspects of distributed actors:
- introduce the ability to call `resolve(id:using:)` on a protocol type, rather than having to create an empty "stub" type manually
- extend the distributed metadata section such that a distributed method which is witness to a distributed requirement, is also recorded using the protocol method's `RemoteCallTarget.identifier` and not only the concrete method's

## Proposed solution

### The `#resolve` macro

While concrete distributed actor types have a `resolve(id:using:)` method available on them, however since the implementation of such method for a protocol would involve code generation, we'll instead leverage the new macro capabilities of the Swift compiler.

The `#resolve(id:using:)` macro is the entry point to locate and return a local or remote distributed actor reference, depending on where the distributed actor system implementation determines the ID to be pointing at.

With concrete distributed actors, this method is declared as a static requirement on the `DistributedActor` protocol, and its implementation is synthesized by the compiler for every concrete distributed actor. This is necessarily synthesized, because a remote distributed actor reference is a special kind of object that is allocated as a "small shim" rather than the complete state of the object. The declaration for the concrete distributed actor resolve is as follows:

```swift
@available(SwiftStdlib 5.7, *)
public protocol DistributedActor: AnyActor, Identifiable, Hashable 
  where ID == ActorSystem.ActorID, 
        SerializationRequirement == ActorSystem.SerializationRequirement {
          
  static func resolve(id: ID, using system: ActorSystem) throws -> Self
}
```

This method is not possible to call "on" a protocol since Swift does permit static method calls on metatypes. And it works by calling into the `DistributedActorSystem` to attempt to locate a local instance of this actor, and if none is found, forms a remote proxy instance of the specific type.

Let us consider a `Greeter` protocol that is constrained to `DistributedActor`, as follows:

```swift
import Distributed

public protocol Greeter: DistributedActor {
  distributed func greet()
}
```

Swift does not permit static functions to be invoked on a protocol metatype, so sadly we cannot spell this API as follows:

```swift
import SampleDistributed // provides SampleSystem

let system: SampleActorSystem
let greeter = try Greeter.resolve(id: id, using: system)
// ❌ error: static member 'resolve' cannot be used on protocol metatype '(any Greeter).Type'
```

Even if we could invoke such method on a metatype, we still would not have a concrete type that a proxy instance could be formed of. In other words, such a resolve must trigger code generation -- we need to obtain a "stub" type, that implements all requirements of the `Greeter` protocol with stub implementations, and then return a remote reference for it.

Instead of relying on ad-hoc compiler built-in synthesis, we can rely on Swift's macros to provide the type and implementation for `resolve`:

```swift
let system: SampleActorSystem = ... 
let id: SampleActorSystem.ActorID = ...
let greeter = try #resolve<any Greeter, SampleActorSystem>(id: id, using: system) // ✅ correct 
```

Where the #resolve macro is declared in the `Distributed` module shipping with Swift:

```swift
public macro resolve<DA: DistributedActor, DAS: DistributedActorSystem>(
  id: DAS.ActorID, using system: DAS) -> DA = ... 
```

The `#resolve` macro functions similarily to the resolve method, however it is able to work with protocol types constrained to `DistributedActor`. It creates an anonymous distributed actor type that is used as the "stub" for the remote calls to be performed at runtime.

The synthesized "stub type" is generally not visible to end users as the macto returns an `any MyActor` rather than exposing the underlying synthesized type. The name of the synthesized type is unique and cannot be relied on by observers, e.g. by inspecting names using the `type(of:)` function -- there is no guarantee the name of the synthesized type will always be the same.

This macro necessarily must be passed the explicit types of the resolved actor, and cannot be used in a generic function to create "any distributed actor", as the macro based code synthesis would not be able ot know what such generic `T` actor actually is:

```swift
func ohNo<T: DistributedActor>(...) {
  #resolve<any T, SampleActorSystem>(...) // ❌ types passed to resolve must be statically known
}
```

And in our `Greeter` example, expands to the following:

```swift
{
    distributed actor UniqueStubName(Greeter, SampleActorSystem): Greeter {
        typealias ActorSystem = SampleActorSystem // must be known statically
           
        distributed func hello(param: NotCodable) -> String { Distributed._methodStub() }
    }
    return try UniqueStubName(Greeter, SampleActorSystem)
      .resolve(id: id, using: system)
}()
```

The important part is that the macro is able to synthesize an stub implementation type, that the existing resolution mechanisms can be invoked on. 

The necessity to synthesize such type stems from the fact that the `ActorSystem` type must be a concrete type for synthesis of a distributed method's thunk to work correctly. Sadly, at present, the `ActorSystem` cannot be made generic due to difficult type-system implications this would cause, neccessitating some form of code synthesis at a point where both the actor system, and protocol are known statically, which is usually in the "Client" module of a project.

> Aside: The "Server" module does not need to synthesize any code, as it would host a concrete implementation of the `Greeter` protocol, like the `EnglishGreater` in our example used so far in the proposal.

## Detailed design

### Details of the `#resolve` macro's workings

The entry point to resolve a distributed actor protocol is the new `#resolve` macro, which is declared as follows:

```swift
@freestanding(expression)
public macro resolve<DA: DistributedActor, DAS: DistributedActorSystem>(
  id: DAS.ActorID, using system: DAS
) throws -> DA

```

This macro depends on the existence of other macros, that the protocol type type provided to its invocation is expected to generate. E.g. an invocation on `Greeter` like this:

```swift
// Module: API
public protocol Greeter: DistributedActor { 
  distributed func hello()
  distributed func greet(name: String) -> String
}

// !! macro names are subject to change and are not guaranteed !!

// @freestanding(expression)
// public macro _distributed_resolve_Greeter<DAS: DistributedActorSystem>(
//  stubName: String,
//  id: DAS.ActorID,
//  using system: DAS) -> Any

// @freestanding(declaration, names: named(hello(), greet(name:)))
// public macro _distributed_stubs_Greeter() =
//   /* encodes all method requirements of Greeter in a form that stubs can be generated from */
```

All these macros are implemented in the `Distributed`  module, even though the macro *declarations* are specific for every distributed actor protocol and present in their respective modules. In our example, if the `Greeter` protocol is present in the `API` module, the macros generated from it reside in it as well.

To make the example more interesting, let us consider a `Greeter` protocol that also inherits from other protocols, like this:

```swift
public protocol Watchable: DistributedActor {
  distributed func watch()
}

public protocol Greeter: Watchable, DistributedActor { 
  distributed func hello()
  distributed func greet(name: String) -> String
}
```

Both these protocols have their respective distributed macros synthesized.

Now, when it comes to invoke the resolve macro invoked as:

```swift
let g = try #resolve<any Greeter, MyActorSystem>(id: id, using: system)
```

It effectively forms a series of expansions:

- `#resolve<any Greeter, MyActorSystem>` expands into an invocation of the specific target macro `#_distributed_resolve_Greeter<MyActorSystem>`

- `#_distributed_resolve_Greeter<MyActorSystem>` synthesizes the body of the resolve body, and an anonymous distributed actor declaration

  - The body of the anonymous actor declaration declares `typealias ActorSystem = MyActorSystem`, which was obtained though the macros forwarding the type argument through to eachother

  - A number of `#_distributed_stubs_TYPE` expansions, for every protocol that the `Greeter` protocol refines, as they all contribute requirements that need to be stubbed out.

    In our example this means the anonymous actor body expands the following two macros:

    - `#_distributed_stubs_Watchable`
    - `#_distributed_stubs_Greeter`
    - If `Watchable` were to also refine some other protocol (which may contribute protocol requirements), this macro would also expand to provide stubs for those.

- The specific `#_distributed_stubs_TYPE` expansions simply form a list of declarations (function or computed property) which are implemented using a fatalError explaining that this type is a stub and should never have been able to invoked "directly."

  - Methods invoked on a stub shall always be turned into `remoteCall` invocations, therefore the function bodies of the stubs can directly just assume that calling them directly is "impossible" (or the result of some bug).

None of the names generated by these intermediate macros surfaced to end users and are not generally observable–except opening the existential and inspecting the `type(of:)` of the returned stub).

> :warning: The names and functions of macro declarations explained in this section are not stable and may change between Swift versions. Specifically, if the need for source synthesis were to be subsumed by sufficiently powerful language features, the macros may instead directly delegate to those instead.

#### Limitations

Because the `#resolve` necessarily needs to obtain concrete type information it is not possible to call it from generic methods.

The macro must be provided a **concrete** name of a distributed actor system and type that a proxy should be synthesized for.

```swift
try #resolve<any DA, LocalTestingDistributedActorSystem>(id: id, using: system)
```

It is not possible to use this macro from a context where for example the distributed actor system is provided via a generic type parameter:

```swift
func cannot<DAS: DistributedActorSystem>(_: DAS.Type = DAS.self) {
  try #resolve<any DA, DAS>(id: id, using: system) // ❌ expansion will fail
}
```

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

## Source compatibility

The changes proposed are purely additive.

The introduced macros do not introduce any new capabilities to the `DistributedActorSystem` protocol itself, but rather introduce new source generation techniques 

## ABI compatibility

This proposal is purely ABI additive.

We introduce new static, accessible at runtime, metadata necessary for the identification and location of distributed protocol methods.

## Wire compatibility

> Since distributed actors are used across processes, an additional kind of compatibility is necessary to discuss in proposals which may impact how messages are sent or methods identified and invoked.

This proposal is additive and provides additional metadata such that "distributed protocol" methods may be invoked across process. 

Remote calls are identified using the `RemoteCallTarget` struct, which contains an `identifier` of the target method. In today's distributed actors these identifiers are the mangled name of the target method. 

In this proposal `identifier` of a call made on a distributed protocol method is changed to use the protocol method declaration's mangled name. This means that e.g. in this situation:

```swift
protocol Greeter {
  func greet()
}

distributed actor Impl: Greeter {
  func greeter() {}
}

try await remoteImpl.greeter()
```

The mangling used to be `mangledName(Impl, greet)` but now will be `mangledName(Greeter, greet)`. 

### :white_check_mark: "Old" process, sending protocol based method to "new" process

When an "old" process or node invokes a distributed protocol method on a distributed actor, its return `RemoteCallTarget.identifier` is going to be the same as always - identifying the specific concrete type's method.

The recipient "new" process may indeed be aware that this method is a "distributed protocol method", however metadata to invoke it using the concrete target identifier is still available. This works without any effort on the distributed actor system implementation side.

### :warning: "New" process, sending protocol based method to "old" process

When a process using Swift with support for distributed protocol methods sends an invocation using the new target identifier, an "old" Swift version recipient will not be able to invoke such method -- and will throw an error from its `executeDistributedTarget` call.

```swift
if isAtLeast(targetNode, version: "5.11") { // external knowladge
  await sendInvocation(target.identifier, ...) // identifier is the protocol method identifier
} else if target.protocolTargetIdentifier != nil {
  // target node is old and cannot support protocol call; attempt a call with forced concrete target
  await sendInvocation(target.concreteTargetIdentifier, ...) // identifier is the protocol method identifier
} else {
  // it is not a protocol call, all target versions understand such calls, no need to special handle
  await sendInvocation(target.identifier, ...)
}
```

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

### Handle stub synthesis in the compiler




## Revisions

- 2.0
  - Change implementation approach to macros, introduce `#resolve` macro
- 1.0
  - Initial revision