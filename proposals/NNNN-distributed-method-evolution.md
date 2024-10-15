# Distributed Method Evolution

* Proposal: [SE-NNNN](NNNN-resolve-distributed-actor-protocols.md)
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso), Pavel
* Review Manager: TBD
* Status:  **Implementation in progress**
* Implementation: TODO
* Review: TODO
* Discussion threads:
  * TBD

## Introduction

Distributed actors offer a way for Swift programs to communicate with other (primarily implemented in Swift) programs using distributed actor and protocol declarations to express the API between different processes or nodes in a network.

The use of the Swift language to express these network protocols is a powerful abstraction which removes users of distributed actor systems from the specific details of networking and serializing data as it crosses the process boundary. The serialization and IO mechanisms used by a distributed actor system are entirely pluggable, and system developers are free to use any mechanism they see fit.

One place where the abstraction falls short is in how the remote calls are _identified_. While remote calls can be mede using any IO and any serialization system, the accessor to the target function to be invoked is using Swift's normal mangling mechanism. This un-necessarily ties the distributed actor system to Swift's internal implementation details, and makes API evolution more difficult.

Another implication of using plain Swift protocols for API boundary declarations is that they are now the source of truth for which methods a remote peer can accept. This is both a feature, and a challenge. By design Swift distributed actors enable the use of plain Swift to express these API contracts – instead of reaching for external Interface Definition Languages – like some other RPC systems do. This means that evolution of these APIs became un-necessarily entangled with Swift's strict ABI needs which don't necessarily apply equally for a distributed system where only the wire compatibility of sent messages should actually matter.

This proposal offers a comprehensive set of tools to approach API evolution of distributed methods aimed at solving the above challenges.

## Motivation

Today, the distributed actor system runtime uses Swift's default mangling scheme for identifying distributed calls. This was a simple default, however we knew we'd have to revisit it at some point in order to provide more flexible API evolution semantics, which are of utmost importance to systems spanning multiple processes and versions of the application code.

The problem space can be split into two general areas:

- un-wanted effects of the mangling on remote call identifiers,
- limitations in API evolution mechanisms.

### Un-wanted effects of the default mangling 

The first problem is the "accidental" and un-wanted effect of re-using Swift's default mangling scheme for distributed call identifiers is exemplified by the following situation: A distributed method parameter of type `Greeting`, of an actor using `Codable` as its serialization requirement is at-first, declared as follows:

```swift
// API module @ v1
final class Greeting: Codable { ... }

protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
  distributed func greet(_: Greeting) -> String { ... }
}
```

The first problem stemming from the naive reuse of Swift's mangling is that it includes the kind of nominal type that the `Greeting` is in the methods mangling, and therefore if the "client code" were to use this API, but the server application were to update its `Greeting` declaration to be a `struct` (as perhaps it should have been to begin with):

```swift
// API module @ v2
struct Greeting: Codable { ... } // (!) accidental identifier break

protocol Greeter where ActorSystem: DistributedActorSystem<any Codable> {
  distributed func greet(_: Greeting) -> String { ... }
}
```

A call made from a client which has a `class Greeting` declaration, making a call to a server implementation which has a `struct Greeting` would result in different remote call identifier manglings and therefore tail to "find" the remote invocation target, forcing the actor system to throw an error that the method was "not found". This is very subtle and unexpected, because remote call arguments are serialized into some form of bytes, and then back again, the fact that the type changed from a class to struct should not matter as long as the serialized bytes can still be used to deserialize the type on the recipient process.

### Cumbersome API evolution

A common requirement for published APIs is to be able to evolve them, most commonly by adding new parameters. This is possible with distributed actors, however only in a limited fashion. Let us consider the previous `greet(_:)` method, and how now a new requirement forces the API to also accept _who_ we should greet. Implementation wise this could be moving from saying `"Hello!"` to `"Hello \(name)"`. 

The change in business logic is simple, however because we had published our API surface without this name parameter, we still need to keep supporting the "old version" of the method:

```swift
// API module @ v2

protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
  // available since v1
  distributed func greet(_: Greeting) -> String { ... }
  
    // available since v2
  distributed func greet(name: String, _: Greeting) -> String { ... }
}
```

A naive and supported today way of handling this is to just keep adding new methods overloading the existing greet method and adding the new functionality, like this:

```swift
// Server module @ v2
distributed actor HelloGreeter: Greeter {
  distributed func greet(_: Greeting) -> String { "Hello!" }
  distributed func greet(name: String, _: Greeting) -> String { "Hello \(name)!"}
}
```

In simple examples this is still manageable, but as the number of overloads and versions grow, this can become hard to maintain.

We'd prefer to be able to have one "latest" version of a distributed method, and have "legacy APIs" that can forward to the new implementation. 

## Proposed solution

### `@Evolving` distributed methods

In order to facilitate easier API evolution, we introduce a new **`@Evolving(...)`** attribute in the Distributed module, which can be used with a `distributed` function or property declaration:

```swift
import Distributed

// v2
distributed actor HelloGreeter { 
  @Evolving(distributed func greet(_: Greeting)) // "v1" was this signature
  distributed func greet(name: String? = nil, _: Greeting)
  
  // other spelling ideas:
  // OR ???
  // @Evolving(signature: greet(_: Greeting))
  // OR ???
  // @Evolving(baseline: greet(_: Greeting))
  // OR ???
  // @Evolving(greet(_: Greeting))
  // OR ???
  // @Evolving(_: Greeting)
}
```

The `@Evolving` attribute foregoes specific version numbers, but instead expresses that this method is the "latest" version of a series of evolution compatible methods which are now all implemented by the `greet(name:_:)` method.

> Note that this mechanism is very similar to the proposed `@abi(...)` mechanism pitched in [Controlling the ABI of a declaration ](https://forums.swift.org/t/pitch-controlling-the-abi-of-a-declaration/75123), which is designed to give library authors control over ABI mangling of methods -- for a similar purpose, evolving ABI stable Swift APIs safely, however `@abi` is focused on the in-process and specific to ABI mangling rather than evolution aspect of what is being proposed here.

The signature contained in the `@Evolving()` and the method (or computed distributed variable) must be compatible.

Every call on a `distributed` method which was made on a _remote_ actor reference is turned into a call to the `remoteCall` method on its underlying `DistributedActorSystem` implementation. That method accepts an is then given a `RemoteCallTarget` which is used to identify the target of the call, and gives the actor system implementation the identifier it can serialize. If the target has a baseline attribute declared on it, the `RemoteCallTarget/identifier` will be the identifier of the baseline:

```swift
protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
    
    @Evolving(baseline: distributed func greet(greeting: Greeting) -> String)
    distributed func greet(name: String, greeting: Greeting) -> String
    
}
```



#### @Evolving distributed computed properties

It is also allowed to use `@Evolving` with distributed computed properties, in which case it is effectively as-if the attribute were applied to the property's `get` accessor (as distributed computed properties cannot have other accessors):

```swift
@Evolving(distributed var tpoInName: String) // say, we made a typo in the signature and need to keep wire-compat
distributed var typoInName: String { ... }
```

In this example we used the base

#### Backward compatibility

### Backward compatibility: ignoring input parameters



#### Forward compatibility



### Improved wire-protocol aware mangling



## Future directions

### Improve tools for non-breaking protocol evolution



## Alternatives considered

### Don't do anything and just document the sharp edges

We could do nothing and just document how very fragile the remote call identifiers are.

This is not acceptable because versioning and API evolution is just a fundamental problem of distributed system programming, on however small or large scale, and as a core language feature aiming to simplify this problem space for developers distributed actors _must_ provide a good story for api evolution and versioning.

The necessity of this can be witnessed when comparing to any other popular RPC library where API evolution often are at the forefront of the library's design philosophy. E.g. protocol buffers handle this via an "[all fields are optional](https://protobuf.dev/programming-guides/dos-donts/)" approach which makes it possible to easily drop not-used-anymore values and keep evolving messages this way. Other actor runtimes such as Akka leave the versioning to the [underlying serialization layer](https://doc.akka.io/docs/akka/current/serialization.html) (e.g. protocol buffers), or choose to version the entire DistributedActor which is [how Grains are versioned in Orleans](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-versioning/grain-versioning).


## Revisions

- 1.0
  - Initial revision