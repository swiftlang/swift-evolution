# Distributed Method Evolution

* Proposal: [SE-NNNN](NNNN-resolve-distributed-actor-protocols.md)
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Pavel Yaskevich](https://github.com/xedin)
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

### No ability to evolve APIs

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

distributed actor HelloGreeter { 
  @Evolving(distributed func greet(phrase: String)) // "v1" was this signature
  distributed func greet(phrase: String, name: String? = "Stranger") { // "v2" signature
    
  }
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

### Compatibility rules

Backwards compatibility means that a new "v2" distributed method must be possible to be invoked by clients which have its previous signature. Similar to other RPC systems, distributed method evolution achieves this by making changes only additive and non-destructive to the base signature.

#### Adding defaulted parameters

The primary way to evolve APIs is to add new parameters to them, this should be possible in a non-breaking fashion, where the "new" method serves as the single implementation handling all legacy calls as well as the current API.

In the following example, the `hello(name:)` method didn't foresee a future requirement that we may need to include a `surname: String` and adds this parameter in future release ("`v2`") of the API library.

```swift
// v1 - API Library --------------------
protocol Greeter: DistributedActor where ... {
  distributed func hello(name: String) -> String
}
```

```swift
// v2 - API Library --------------------
protocol Greeter: DistributedActor where ... {
  @Evolving(distributed func hello(name: String) -> String)
  distributed func hello(name: String, surname: String?) -> String
  // 						      added parameter  ^^^^^^^^^^^^^^^^
}
```

Here we used the `@Evolving` attribute to signify the baseline version of the `hello` method, that now has gained an extra parameter. The implementation of this protocol now has to implement the latest API, so the server project which previously implemented `Greeter` at its `v1` shape will now instead implement _only_ the latest implementation:

```swift
distributed actor PoliteGreeter: Greeter {
  @Evolving(distributed func hello(name: String))
  distributed func hello(name: String, surname: String? = nil) -> String {
    "Hello"
  }
}
```

The `@Evolving` attribute enforces that all **added** parameters must have a default value. This value will be used when clients attempt to make calls on baseline versions of the API. Semantically this is equivalent to:

```swift
// Evolvable is semantically equivalent to keeping the old baseline method, 
// and forwarding to the new implementation.

distributed actor PoliteGreeter: Greeter { 
  @Evolving(distributed func hello(name: String))
  distributed func hello(name: String, surname: String? = nil) -> String {
    "Hello"
  }
  
/*
  @_disfavoredOverload
  distributed func hello(name: String) -> String {
    return hello(name: name, surname: nil)
  }
*/
}
```

Including, when a client only has a v1 declaration of `hello(name:)` and makes a remote call to a server which implemented only the `hello(name:surname:)` version of the evolving API. In other words, the change is source, abi and *wire* backwards compatible for clients.

```swift
// Client; "Old", with v1 API Library protocol declarations

// API Library @ v1
// protocol Greeter: DistributedActor where ... {
//  distributed func hello(name: String) -> String
// }

let greeter = try $Greeter.resolve(<id of greeter on v2 host>, using: system)
let greeting try await greeter.greet(name: "Caplin")
```

#### @Evolving matching rules

The evolving attribute must spell out a full signature of the "baseline" method it is evolving from. The attached to method must therefore "match" this baseline, and only add (or make compatible changes) to the baseline signature. This section explains what matching rules are applied, and therefore what kinds of changes can be made to the method interface.

**Adding parameters:** The parameter list of the baseline must remain untouched. Currently, only adding parameters after the baseline parameters is supported.

> :warning: **Draft note:** We could be more flexible here but it becomes a bit complex how we `recordArgument` so we have to think about it some more perhaps... We'd have to change how encoding works and it'be opt in somehow in new Swift runtimes... 

```swift
@Evolving(distributed func hello(name: String, age: Int))
distributed func hello(name: String, ❌ surname: String?, age: Int) -> String
// ❌ error: expected baseline parameter 'name: String' to be followed by 'age: Int', but found 'surname: String?'
```

Adding parameters after the baseline parameter list is supported:

```swift
@Evolving(distributed func hello(name: String, age: Int))
distributed func hello(name: String, age: Int, surname: String?) -> String
// ✅ ok, surname is after baseline parameters

@Evolving(distributed func hello(name: String, age: Int))
distributed func hello(name: String, age: Int, surname: String?, pet: Pet) -> String
// ✅ ok, surname and pet follow the baseline
```

**Parameter type changes:** In principle, baseline parameter type changes are not permitted.

```swift
@Evolving(distributed func hello(name: String, age: Int))
distributed func hello(name: ❌ Int, age: Int) -> String
// ❌ error: baseline parameter 'name' cannot change type to 'Int' (was 'String')
```

> **Note:** Technically we could support "widening" the accepted type, e.g. if we previously accepted `Int32` and now want to accept `Int64` though perhaps this isn't worth exploring until we're certain to see the need for such. The same question with regards to generic types is more difficult, and we currently also do not aim to suport such.

**Return type changes:** Actually "changing" the return type of a method is not supported, a client may be expecting to get an `Int` but if we suddenly started returning a `String` that is not going to be a compatible change, regardless how we go about it.

```swift
@Evolving(distributed func hello(name: String) -> String)
distributed func hello(name: Int) -> ❌ Greeting
// ❌ error: return type 'Greeting' does not match baseline return type 'String'
```

**Changing `throws` and `async`:** For the purpose of remote calls–i.e. when actually crossing an distributed actor boundary–a distributed method call is always implicitly throwing and asynchronous, however a method declaration itself may be explicitly declared async or throwing. The difference is in the implementation being able to throw or suspend in the local implementation of the distributed function, regardless of the suspension and error which may be introduced by networking reasons.

It is not allowed to _add_ `async` or `throws` effects to an evolving function declaration, because it would make the backwards compatibility delegate methods 

```swift
@Evolving(distributed func hello(name: String) -> String)
distributed func hello(name: Int) ❌ async ❌ throws -> String
// ❌ error: cannot add 'async' effect which was not present in baseline signature
// ❌ error: cannot add 'throws' effect which was not present in baseline signature
```

**Generic parameter changes:** It is not supported to change the number of generic type parameters of an evolved method.

```swift
@Evolving(distributed func hello(name: String) -> String)
distributed func hello<❌ Name: NameProtocol>(name: Name) -> String
// ❌ error: number of generic parameter types does not match baseline declaration

@Evolving(distributed func hello(name: String) -> String)
distributed func hello(name: ❌ some NameProtocol) -> String
// ❌ error: number of generic parameter types does not match baseline declaration
// ❌ error: baseline parameter 'name' cannot change type to 'some NameProtocol' (was 'String')
```

It is also not allowed to change the constraints of a given parameter



Maybe it can work since we require a default value so we know the "default" to use when no was provided...

#### Evolving distributed computed properties

Distributed computed (get-only) properties may also be subject to evolution, and may even be evolved into methods accepting parameters.

It is legal to use @Evolving to perform a variable rename:

```swift
@Evolving(distributed var tpoInName: String)
distributed var typoInName: String { "hello" }

// TODO: Do we think we care?
@Evolving(distributed var tpoInName: String)
distributed func typoInName(context: Something) -> String { "hello" }
```

TODO: Should we allow moving it to a function since this way we can deprecate the property 

#### Using @Evolving to rename methods

It is also allowed to use `@Evolving` with distributed computed properties, in which case it is effectively as-if the attribute were applied to the property's `get` accessor (as distributed computed properties cannot have other accessors):

```swift
@Evolving(distributed func tpoInName() -> String) // say, we made a typo in the signature
distributed func typoInName() -> String { ... }
```

In this example we used the baseline to keep an old "old" method name.

This allows clients to still exist with the old API declaration however new users and servers don't have to live with the typo in source code anymore, and can use the fixed method name. At runtime this behaves similar as using a silgen name attribute or (being proposed) @abi() attribute to retain ABI compatibility with some old method name, but is specific to the name of the method.

Renaming specifically could introduce a peer to the new method, and annotate the old one using deprecated renamed availability:

```swift
@Evolving(distributed func tpoInName() -> String) // say, we made a typo in the signature
distributed func typoInName() -> String { ... }
```

results in:

```swift
@available(*, deprecated, renamed: "typoInName")
distributed func tpoInName() -> String { ... }

// @Evolving(distributed func tpoInName() -> String)
distributed func tpoInName() -> String { ... }
```

### Stacking multiple @Evolvable attributes

In real systems, APIs evolve not only between a "first" and "next" version, but over multiple iterations/releases and the @Evolving atribute must handle this _ongoing_ journey of an API over multiple releases.

For example, a first release of a service may have the following declaration:

```swift
@available(...) // "v1"
protocol Greeter: DistributedActor where { 
  @Evolving(distributed greet(name: String) -> String)
  distributed func greet(name: String) -> String
}
```

Then, we added an age parameter:

```swift
@available(...) // "v2"
protocol Greeter: DistributedActor where { 

}
```



### Source forward-compatibility when Evolving requirements change

In order to make protocol evolution non-breaking for clients who implement distributed protocol types locally in their clients in order to e.g. write a "mock test", we propose that evolution should also be forward compatible in such situations.

For example, if a client library uses a V1 of an API module that contains the following protocol:

```swift
// V1 API Library
protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
  distributed func greet() -> String
}
```

And uses it in mock implementations like this:

```swift
// Client library (depends on API Library @ v1)
distributed actor MockGreeter: Greeter {
  distributed func greet() -> String { "mock!" }
}
```

When the Library introduces a new evolved method like this:

```swift
// V2 API Library; does not break MockGreater
protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
  @Evolving(distributed func greet() -> String)
  distributed func greet(name: String? = nil) -> String 
  // new parameter must be defaulted so that we can make up the 
  // greet() -> greet(name: nil) delegation code
}

// TODO: can't extension Greeter { distributed func greet() -> String { self.greet(name: nil)} } 
// UNLESS: 
  @Evolving(distributed func greet() -> String)
  distributed func greet(name: String? = nil) -> String
```

We propose to maintain source compatibility for adopters of a protocol which enables method evolution.

In this situation `MockGreeter` would still compile however it would receive a warning when the API library dependency is updated to v2:

```swift
distributed actor MockGreeter: Greeter /* at v2 now */ {
  @Evolving(distributed func greet() -> String) // TODO:
  distributed func greet() -> String { "mock!" }
  // ERROR: missing impl for greet(name:)
}
```

### Runtime integration and `RemoteCallIdentifier`

Every distributed actor is tied to an `DistributedActorSystem` implementation at runtime. The system handles the actual remote calls and does so by implementing the remoteCall method:

```swift
```



### Mangling improvements for distributed invocation target identifiers

We also propose to fix a few minor yet easy to run into weaknesses of the currently used mangling scheme. These often show up _during development_ and hinder quick iteration with distributed actors while developing an app or service while keeping the other side of the communication running. This is often the case when e.g. developing a client/server system where we continue refactoring one of the sides and restarting the process (e.g. the client app), and while we refactor it, we notice that we made some mistake in a distributed method signature. It is nice to be resilient against such changes when possible, in order not to interrupt the developer's workflow with a full client _and_ service restart whenever such situation happens.

This also acknowledges that the wire protocol evolution requirements are different from abi evolution.

#### Remove the parameter type kind information from the remote target identifier mangling

> **Note: This may have to be opt-in with a flag. Or we make it configurable using which mangling scheme we should use?**

In order to address the accidental breaking of wire protocol by changing a kind of a nominal type involved in a distributed method, we will drop the class/struct information from the mangling used by the runtime. This also matters in long term development, when some type was accidentally a reference type but should not have been, however one would hope these situations appear less frequently because, one would hope, the development team having a chance to review the code. Either way though, the ability to fix such mistakes on service boundaries is very important and we must provide support for it:

For example, if we have a greet accepting a `class` parameter:

```swift
// v1 API
final class Target: Codable {} 

protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
  distributed func greet(target: Target)
}
```

It should be possible to change this parameter type to a `struct` or perhaps an enum or even a `distributed actor` without breaking remote calls on this service boundary:

```swift
// v2 API
struct Target: Codable {} 

protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
  distributed func greet(target: Target)
}
```

Clients which issue calls using the `v1` declaration against servers hosting `v2`, as well as clients using a `v2` declaration making calls against a server hosting a `v1` declaration both are supported, because the extra information on the kind of the parameter's nominal type will be erased from the mangling.

In order to support previous Swift versions, it must be possible to accept a client using either version of API, compiled with an older version of Swift which _will include_ the type kind in the mangling, distributed method accessors are _still_ always emitted using both manglings, and we will provide a compiler flag to disable the "legacy support" when it is known that both sides of the communication are guaranteed to be on new-enough versions of Swift which can save some space in the binary.

##### Compatibility analysis

- Wire compatibility
  - Client "new" distributed runtime / Server "old" distributed runtime
    - :white_check_mark: mangling does not include class/struct information, server runtime retains 
  - Client "old" distributed runtime / Server "new" distributed runtime
    -  :warning: cannot use new mangling scheme, would result in not found methods
- Source compatibility
  - Client "new Swift" :arrow_right: Server "old Swift"
  - Client "old Swift" :arrow_right: Server "new Swift"
    - :white_check_mark: plain Swift semantics, changing class/struct usually has no impact on source
      - `inout` parameters are not allowed in `distributed` methods

## Not supported evolution changes

The following changes are not supported by the `@Evolving` attribute:

- changing the return type of a function

## Source compatibility

This proposal is purely source additive.

## ABI compatibility

This feature is intended to give libraries additional options to evolve APIs without breaking the corresponding ABIs.

Baseline methods remain present in their declaring context, and new evolved APIs are purely additive.

## Wire compatibility

This proposal retains wire compatibility with previous Swift versions.

Given the improved mangling scheme which omits e.g. class/struct information about parameter types, a naive implementation of just changing the mangling would break wire compatibility between a process built using preview Swift versions and a process

## Future directions

### Consider exposing @Evolving as a general purpose tool, rather than specialized for DistributedActors

An observant reader can notice that very few of the described mechanisms of the `@Evolving` attributed actually have anything specific to do with the distributed actor runtime. They certainly need to play by some rules such that the serialization mechanisms of the `DistributedActorSystem` can make use of it, but the general need to keep backwards compatible APIs around, documented, and easy to evolve exist equally in just ABI stable libraries.

Therefore, should we consider making this mechanism available to non-Distributed types? We could approach this by making `@Evolving` a general purpose utility for source, ABI and/or wire-compatibility library authors, and only make sure that some specific tie ins into the distributed actor remote call infrastructure happen to be aware of this attribute.

## Alternatives considered

### Don't do anything and just document the sharp edges

We could do nothing and just document how very fragile the remote call identifiers are.

This is not acceptable because versioning and API evolution is just a fundamental problem of distributed system programming, on however small or large scale, and as a core language feature aiming to simplify this problem space for developers distributed actors _must_ provide a good story for api evolution and versioning.

The necessity of this can be witnessed when comparing to any other popular RPC library where API evolution often are at the forefront of the library's design philosophy. E.g. protocol buffers handle this via an "[all fields are optional](https://protobuf.dev/programming-guides/dos-donts/)" approach which makes it possible to easily drop not-used-anymore values and keep evolving messages this way. Other actor runtimes such as Akka leave the versioning to the [underlying serialization layer](https://doc.akka.io/docs/akka/current/serialization.html) (e.g. protocol buffers), or choose to version the entire DistributedActor which is [how Grains are versioned in Orleans](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-versioning/grain-versioning).

In theory could say distributed actors don't offer any evolution mechanisms and force developers to adopt other message serialization mechanisms such as Google Protocol Buffers and force developers to only write distributed methods which have a single parameter which is "the message" that is then defined using an external IDL file and source generate the message. This goes against the goal of distributed actors' seamless integration into the developer workflow without breaking out of the Swift-first workflow.

If a developer and actor system implementation wanted to make this the way they handle messaging, this is possible to do today, and a system can require that a distributed method has only a single parameter, and have an `SerializationRequirement` that enforces e.g. the use of protocol buffers. Other than this providing a less than optimal developer experience -- reducing distributed actors to prior legacy systems like with bad usability, this is not a viable route if distributed actors are to become more widely adopted on platforms with specific code-size and serialization requirements and thus we cannot say this is the only route.

### Version negotiation and versioned feature @availability

Some form of negotiating library version along with metadata on every distributed method would be possible, but after considering the implications we find that it does not help in actual evolution of APIs.

If we were to extend availability with feature (library names) version numbers, we could "version" APIs like this:

```swift
protocol Greeter: DistributedActor where ... {
  
  // "always available if you have the Greeter protocol"
  distributed func greet() -> String

  @available(feature: "Greetings", version: 2)
  distributed func greet(name: String) -> String
}
```

While we could do this, and perhaps might even independently arrive at such availability extensions, it does not help API evolution in any meaningful way. It _prevents_ calling things rather than _enabling_ calling things that can evolve.

Clients would have to write the following code:

```swift
// mock of an idea of per-actor version availability version checking
if #available(greeter, feature: "Greetings", version: 2) {
  try await greeter.greet(name: "Caplin")
} else {
  // fallback
  try await greeter.greet()
}
```

Which is a pattern familiar to anyone who has worked with _platform availability_ (i.e. "if on macOS version higher than ...").

This solves a different problem of offering new APIs and making them optionally available, depending on some runtime version, to clients. In practice though, this isn't all that helpful: if the client has a `Greeter` declaration with the `Greetings@v2` declaration they generally may try to call it, or an actor system may just perform version negotiation at initialization time and fail if missing some capabilities. 

Even if a call were to be made from a client with a `v2` interface, towards a server which hosts only the `v1` interface -- the semantics are similar to a plain old "not found" and the method can error out as expected with normal distributed calls. This avoids doing pre-flight calls which un-necessarily slow down interactions. Since we are not interested in pre-flight checks due to the latency impact they may have, there is not much value in the version checks unless we make them asynchronously _eagerly_ before calls are made.

This becomes complicated very fast, and doesn't really help evolving APIs all that much. It is more of a different beast, like capability testing a remote peer and could perhaps be used for that instead.

One could imagine the system working as follows:

```swift
let system: SomeDistributedActorSystem = ...

let id1: SomeDistributedActorSystem.ActorID = ...
let lazyConnected = try $Greeter.resolve(id1, using: system) // connection is lazy
if try? await #available(lazyConnected, feature: "Greetings", version: 2) ?? false {
  // force an try await greeter.isAvailable(feature: "Greetings", version: 2) pre-flight call
  // - cache the feature list for this actor OR entire system
  try await lazyConnected.greet(name: "Caplin") // already connected at this point
}
```

So it would be possible to support, but in discussions we found this to be adding not enough value and being a separate discussion from the API evolution story. It may be still interesting to explore as a separate feature in the future if enough need for it appears in real world situations.

This feature would compose with the being proposed evolution of existing methods, because it could be used to guard some methods with pre-flight or on-connection feature checking, but does not really handle method evolution.

## Revisions

- 1.0
  - Initial revision