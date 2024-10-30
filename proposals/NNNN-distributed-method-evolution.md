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

One place where the abstraction falls short is in how the remote calls are _identified_. While remote calls can be made using any IO and any serialization system, the accessor to the target function to be invoked is using Swift's normal mangling mechanism. This un-necessarily ties the distributed actor system to Swift's internal implementation details, and makes API evolution more difficult.

Another implication of using plain Swift protocols for API boundary declarations is that they are now the source of truth for which methods a remote peer can accept. This is both a feature, and a challenge. By design Swift distributed actors enable the use of plain Swift to express these API contracts – instead of reaching for external Interface Definition Languages – like some other RPC systems do. This means that evolution of these APIs became un-necessarily entangled with Swift's strict ABI needs which don't necessarily apply equally for a distributed system where only the wire compatibility of sent messages should actually matter.

Protocol evolution is the defining feature of any RPC system. It is crucual for Swift to provide a well-defined, and pleasant to use way to evolve APIs, in order to give developers the confidence and peace of mind when adopting distributed actors in their long-term projects.

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

**TODO: The baseline needs to be explained** 

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
    
    @Evolving(distributed func greet(greeting: Greeting) -> String)
    distributed func greet(name: String, greeting: Greeting) -> String
    
}
```

### Compatibility rules

Backwards compatibility means that a new "v2" distributed method must be possible to be invoked by clients which have its previous signature. Similar to other RPC systems, distributed method evolution achieves this by making changes only additive and non-destructive to the base signature.

#### Adding parameters

**TODO: Optional OR DEFAULTED**

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

**TODO: Do we want to drop the `distributed func` part?**

The evolving attribute must spell out a full signature of the "baseline" method it is evolving from. The attached to method must therefore "match" this baseline, and only add (or make compatible changes) to the baseline signature. This section explains what matching rules are applied, and therefore what kinds of changes can be made to the method interface.

:white_check_mark: **Adding parameters:** The parameter list of the baseline must remain untouched. Currently, only adding parameters after the baseline parameters is supported.

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

:no_entry_sign: **Parameter type changes:** In principle, baseline parameter type changes are not permitted.

```swift
@Evolving(distributed func hello(name: String, age: Int))
distributed func hello(name: ❌ Int, age: Int) -> String
// ❌ error: baseline parameter 'name' cannot change type to 'Int' (was 'String')
```

> **Note:** Technically we could support "widening" the accepted type, e.g. if we previously accepted `Int32` and now want to accept `Int64` though perhaps this isn't worth exploring until we're certain to see the need for such. The same question with regards to generic types is more difficult, and we currently also do not aim to suport such.

:no_entry_sign: **Return type changes:** It is not backwards compatible to change the return type of a method.

```swift
@Evolving(distributed func hello(name: String) -> String)
distributed func hello(name: Int) -> ❌ Greeting
// ❌ error: return type 'Greeting' does not match baseline return type 'String'
```

:no_entry_sign: **Changing `throws` and `async`:** For the purpose of remote calls–i.e. when actually crossing an distributed actor boundary–a distributed method call is always implicitly throwing and asynchronous, however a method declaration itself may be explicitly declared async or throwing. The difference is in the implementation being able to throw or suspend in the local implementation of the distributed function, regardless of the suspension and error which may be introduced by networking reasons.

It is not allowed to _add_ `async` or `throws` effects to an evolving function declaration, because it would make the backwards compatibility delegate methods 

```swift
@Evolving(distributed func hello(name: String) -> String)
distributed func hello(name: Int) ❌ async ❌ throws -> String
// ❌ error: cannot add 'async' effect which was not present in baseline signature
// ❌ error: cannot add 'throws' effect which was not present in baseline signature
```

:no_entry_sign: **Generic parameter changes:** It is not supported to change the number of generic type parameters of an evolved method.

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

**TODO: :white_check_mark: Allow move from String to String? in preparation for removal in the future**



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

### Multi-release long evolution

**TODO: Forward compatiblity in general?**

In real systems, APIs evolve not only between a "first" and "next" version, but over multiple iterations/releases and the @Evolving atribute must handle this _ongoing_ journey of an API over multiple releases.

For example, a first release of a service may have the following declaration:

```swift
protocol Greeter: DistributedActor ... { 
  distributed func greet(name: String) -> String // "v1"
}
```

Then, we added an `lastName` parameter in an subsequent release.

```swift
protocol Greeter: DistributedActor ... { 
  @Evolving(distributed greet(name: String) -> String)
  distributed func greet(name: String, lastName: String) -> String // ✅ "v2"
}
```

Next, in a subsquent release wanted to add another parameter, let's say `age: Int`. Since the `name:lastName:` API was released and has clients using it, we have to be careful to not break it from this revision as well.

**TODO: Do we need version numbers on the Evolving "versions" of the signatures?**

**TODO: Does including version number, and a client OMITTS it, makes it worse or better when we make a call to an old server?**

**TODO: @evolving overrides, do they need to be banned; JUST evolve in protocols**

```swift
protocol Greeter: DistributedActor ... { 
  @Evolving(distributed greet(name: String) -> String)
  @Evolving(distributed greet(name: String, lastName: String) -> String) // HELPFUL but nor REQUIRED
  // TODO: Unless we infer versions from this; because of the forward compat thigns?
  distributed func greet(name: String, lastName: String, age: Int?) -> String
}

distributed actor PoliteGreeter: Greeter { 
  @Evolving(distributed greet(name: String, BLA: String) -> String) <<<<<<<<<<<<<<<
  distributed func greet(name: String, lastName: String = "<Unknown>", age: Int? = nil) -> String
}
```



We could try to just add the new parameter to the latest API:

```swift
protocol Greeter: DistributedActor where { 
  @Evolving(distributed greet(name: String) -> String)
  @Evolving(distributed greet(name: String, lastName: String) -> String)
  distributed func greet(name: String, lastName: String, age: Int?) -> String // ✅ "v3"
}

distributed actor PoliteGreeter: Greeter { 
  // forced to default `lastName` and `age`
  distributed func greet(name: String, lastName: String = "<Unknown>", age: Int? = nil) -> String // ✅
}
```

This is a tricky situation however. The runtime will mangle the distributed function accessor using the **baseline** name of the `greet(name:)` overload, for either the "v2" `name:lastName:` as well as the "v3" `name:lastName:age:` however this encoding is fragile to the order of arguments.

We could make a mistake evolving between v2 and v3, where we add the 3rd parameter _before_ the `lastName`, resulting in a mismatch that we didn't statically detect.

> **Discuss:** Open question how much this has us worried, it's a real mistake that could happen. Stacking annotations is **OPTIONAL**, things work correctly if the general rules are upheld though we don't provide checking for it if we don't do stacking. 

#### Availability and @Evolving methods

It may happen, that a specific API evolution depends on a specific platform release, for example if a parameter of a distributed call somehow depends on an API that is specific to some macOS release, or if the functionality it is now able to implement (in the "latest" version) somehow depends on a specific platform release. 

Marking the current "latest" declaration of a method with `@availability` continues to work as expected, and no special support is necessary here. However, since the goal of `@Evolving` is to remove

For example, a first release of a service may have the following declaration:

```swift
@available(macOS N, ..., *)
protocol Greeter: DistributedActor where { 
  distributed func greet(name: String) -> String
}
```

Then the library added an age parameter in a subsequent OS release:

```swift
@available(macOS N+1, ..., *) // for some reason this is only available in N+1
struct Age: Codable {} 

@available(macOS N, ..., *)
protocol Greeter: DistributedActor where { 
  @Evolving(
    @available(macOS N, ..., *)
    distributed greet(name: String) -> String
  )
  @available(macOS N+1, ..., *)
  distributed func greet(name: String, age: Swift.Age) -> String
}
```

Which allows for a natural way of expressing the usual OS based availability of specific revisions of an API.

### Forward-compatibility

**TODO: This is scary to clients, maybe we need to allow this via opt in on the server to forward compat some specific methods**

**TODO: We need param indicies probably anyway.**

Forward compatibility in distributed calls means that a distributed actor must be able to receive calls from "future" client versions.

We can analyze this using our familiar Greeter example:

```swift
protocol Greeter: DistributedActor where ... { 
  @Evolving(distributed greet(name: String) -> String)
  distributed func greet(name: String, surname: String? = nil) -> String
}
```

Forward compatibility in evolving methods boils down to the ability to ignore unknown values, this can be observed in a situation where we have a "v2" Greeter protocol, and a server which is still running the previous "v1" which only has `greet(name:)`, being invoked by a client using the new "v2" declaration:

```swift
// Client @ v2
try await greeter.greet(name: "Caplin", surname: "Capybara") -> String
// (!) remote 'greeter' is "v1: greet(name:)"
```

```swift
// Server @ v1
distributed func greet(name: String) -> String
```

When making the distributed call the distributed runtime encoded the `greet(name:)` baseline identifier since it is

#### Registering dismissed arguments

It is possible for a runtime to offer a task local context that would be the "call context" that may include information about "unexpected" arguments that the system has encountered.

While this is actor system implementation specific, we can provide a short example how one may want to choose to implement this using the following pseudo code of an `DistributedActorSystem` handling an incoming remote call:

```swift
// Client
// Distributed runtime performs the following:
try invocation.recordArgument(RemoteCallArgument("name", "Caplin"))
try invocation.recordArgument(RemoteCallArgument("surname", "Capybara"))
try invocation.doneRecording()

// Server; remote call is received and we attempt to decode it
var invocation: MyDistributedTargetInvocationDecoder<any Codable> = // wrap incoming message bytes
let target: RemoteCallTarget = // decoded from incoming message envelope
try await executeDistributedTarget(on: actor, target, invocation, ...)

```

TODO DEEP DIVE INTO THE CODING HOW TO 

```
RemoteCallContext.with(invocation) { 
  try await executeDistributedTarget(on: actor, target, invocation, ...)
}

distributed func hello() { 
  assert(RemoteCallContext.droppedValues.count == 0)
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

### Runtime integration and `RemoteCallTarget`

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

### Consider support for removing optional parameters

While being able to incrementally add new fields is great and solves a majority of evolution use-cases, sometimes one field becomes superseeded by another, and this situation isn't too well supported today, other than documenting "`name` is not used anymore" there is no good way to _stop sending the `name` payload_ given a signature like this:

```swift
distributed func call(name: String)
```

If in the next version we split up name into `firstName` and `secondName` we may want to stop passing any value for `name` if we're using the "new" API. In theory, if we had the foresight to make parameters optional in the baseline version of the API, we could allow omitting such optional parameters entirely:

```swift
@Evolving(distributed func call(name: String?, age: Int))
distributed func call(age: Int, firstName: String, secondName: String?)
```

Callers of the "new" version

## Alternatives considered

### Use @abi rather than introduce a new attribute

We can we allow only `Optional` and **defaulted** parameters for API evolution and instead of `@Evolving`, and we just use @abi with with initial declaration. 

The decl checker we could detect the situation when `@abi` is used on a `distributed` member and use the solver to check whether initial version is callable through the current spelling. This would mean that we always guarantee backward compatibility and clients don't need to deal with #available checks in their code (can gradually add new parameters as their are re-compiled against newer libraries). 

#### Forward compatibility

The only rough edge of this is using "new" client to call "old" server (i.e. that rolling update scenario I was talking about). I think we can approach this problem by "versioning" the actor system instead individual actors, so that it won't be possible to either establish connections to "old" servers in the scenario I described above or calling anything on it would produce a compatibility error.

### Force "Request/Response" message style as only way of evolving remote calls

We could do nothing and just document how very fragile the remote call identifiers are. Once published, a distributed can never change in any way.

We could encourage developers to adopt an RequestObject / ResponseObject style, similar to other messaging systems which fully embrace their *message* based nature (e.g. Akka, gRPC) rather than a more *procedure* based nature (e.g. Thrift, Orleans), which would force developers to alway adopt the following shape for distributed calls:

```swift
distributed func hello(request: HelloRequest) -> HelloResponse { ... }

struct HelloRequest: Codable { ... } 
struct HelloResponse: Codable { ... } 
```

Such shape reverts the expressive nature of 

This is not acceptable because versioning and API evolution is just a fundamental problem of distributed system programming, on however small or large scale, and as a core language feature aiming to simplify this problem space for developers distributed actors _must_ provide a good story for api evolution and versioning.

The necessity of this can be witnessed when comparing to any other popular RPC library where API evolution often are at the forefront of the library's design philosophy. E.g. protocol buffers handle this via an "[all fields are optional](https://protobuf.dev/programming-guides/dos-donts/)" approach which makes it possible to easily drop not-used-anymore values and keep evolving messages this way. Other actor runtimes such as Akka leave the versioning to the [underlying serialization layer](https://doc.akka.io/docs/akka/current/serialization.html) (e.g. protocol buffers), or choose to version the entire DistributedActor which is [how Grains are versioned in Orleans](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-versioning/grain-versioning).

In theory could say distributed actors don't offer any evolution mechanisms and force developers to adopt other message serialization mechanisms such as Google Protocol Buffers and force developers to only write distributed methods which have a single parameter which is "the message" that is then defined using an external IDL file and source generate the message. This goes against the goal of distributed actors' seamless integration into the developer workflow without breaking out of the Swift-first workflow.

If a developer and actor system implementation wanted to make this the way they handle messaging, this is possible to do today, and a system can require that a distributed method has only a single parameter, and have an `SerializationRequirement` that enforces e.g. the use of protocol buffers. Other than this providing a less than optimal developer experience -- reducing distributed actors to prior legacy systems like with bad usability, this is not a viable route if distributed actors are to become more widely adopted on platforms with specific code-size and serialization requirements and thus we cannot say this is the only route.

### Disable overloads of distributed methods entirely & use basic name mangling

This would be a source breaking and quite disruptive change, however it would mean that we could for example use just the base name of a distributed method as its identifier, and then for example special-treat any optional parameter as being allowed to be "missing" from incoming calls.

This is somewhat similar to Thrift's method of evolution, where one may add `optional` parameters and if they are missing they are simply defaulted to nil on the recipient server.

This change would be wire protocol breaking, or we would have to maintain both identifiers for the foreseeable future, as we would only identify methods using their base name. It would make distributed methods limited and unable to provide overloads which may or may not be acceptable.

As for API evolution, the same mechanisms as discussed above would have to be employed. Only adding optional fields would be supported and we could special handle `Value?` optionals specifically, however any other new parameter must have a defaulted value or we would have to fail at runtime when receiving an invocation that is missing a value:

```swift
// caller
dist.hello(name: "Caplin")

// recipient "v2" declaration
distributed func hello(name: String, surname: String)
// ❌ fail at runtime, attempt to 'decodeNextArgument' for surname and fail

distributed func hello(name: String, surname: String = "")
// ✅ don't provide value for surname, use the default

distributed func hello(name: String, surname: String, age: Int = 23)
// ❌ problematic, on one hand, this can fail with "not enough arguments"
// but 
```

This is similar to Thrift's versioning style, without the ability to remove fields and being order sensitive.

### Tagged fields

Some RPC systems choose to "tag" fields which are then used to transfer the numbered identifiers rather than names of fields. A number may not be repeated and fields may be removed if they were optional. For forward compatibility, it is possible to ignore incoming parameters if their ID are not known, such are simply discarded.

In idea would result in the following syntax:

```swift
@Evolving
distributed func hello(
  name: @FieldID(1) String, 
  surname: @FieldID(2) String
) -> String
```

Functions without tags cannot be backwards compatible, so you'd have to opt-in immediately expecting future evolution of an API which is a problematic downside of this approach.

### Server-side distributed method resolution

In this way we send over all labels and types, and based that we perform RUNTIME overload resolution...

Seems too hardcore and overhead on the wire protocol.

### Version and per-instance-#availability

Some form of negotiating library version along with metadata on every distributed method would be possible, but after considering the implications we find that it does not help in actual evolution of APIs.

If we were to extend availability with feature to allow arbitrary version numbers, we could "version" APIs like this:

```swift
protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
  // "always available if you have the Greeter protocol"
  // Implicitly "version 1" / "baseline"
  distributed func greet() -> String

  @available(version: 2)
  distributed func greet(name: String) -> String
}
```

This approach attempts to prevent calling "not found" methods, and comes at a large cost of pre-exchanging information about available versions.

Client code utilize an extended version of availability checking that is instance specific:

```swift
if #available(greeter, version: 2) { // problematic (!)
  try await greeter.greet(name: "Caplin") // was available from "v2"
} else {
  // fallback
  try await greeter.greet() // baseline / "v1" is always available
}
```

Which is a pattern familiar to anyone who has worked with _platform availability_ (i.e. "if on macOS version higher than ..."). Implementing such check, however, is most difficult in a distributed system: it assumes prior knowledge **before** we attempt to send the message (!). This requires us to pre-exchange information between the server and the client. 

This is problematic in practice, because how and *when* would we obtain this "available versions" information?

#### Option 1) During actor system start and connection establishment exchange _all_ available version information

We could, in theory, force an actor system which intends to use versioning in this scheme, to eagerly send all information about available actors and versions upon first connection. A naive implementation could be entirely eager during actor system creation:

```swift
let system = try await MyActorSystem("localhost:7337") // forced to eagerly connect
//  [client] ----------------------> [server]
//           HELLO
//           <---------------------- ACK HELLO
//           Greeter @ v2
//           Another @ v3
//           SomethingElse @ v1
//           AnotherSomethingElse @ v4
//           ...

let resolved = try $Greeter.resolve(id, using: system) // create proxy
```

This approach would effectively force implementations into a "heavy handshake" before any communication can take place. And this would be forced to transfer _all_ distributed actor versions it knows about in the server (!). Aside from the tricky implementation: we'd have to offer an API to the system that effectively inspects runtime information and offers this information back to the system, for it to include it in the handshake (this is possible to implement).

A heavy handshake is something many systems are actively working to avoid – it adds an extra roundtrip and therefore delays time-to-interactive of the network communication. For some systems, which aim to minimize the time-to-interactive initial delay of communication such additional handshake might be unacceptable.

For some systems this might not be possible to implement. because connections are established *lazily* dependin on identifiers. A typical identifier can include the host or process identifier of the target we want to communicate with:

```swift
let resolved = try $Greeter.resolve(id: "<host|pid>/Greeter", using: system) // create proxy
try await resolved.test() // connection established HERE, lazily (!)
```

Connections are frequently established lazily, on first message exchange, and such systems do not even know the number of connections they will maintain until the IDs are resolved, in other words: not during ActorSystem creation time. This is on purpose, to keep system setup "light" and only activate resource usage once they are required.

This means that the following check this alternative would rely on, cannot be reliably implemented unless we force it to be asynchronous:

```swift
// ❌ cannot reliably work, we may not have enough information to answer this question *synchronously*
if #available(greeter, version: 2) { 
  try await greeter.greet(name: "Caplin") // connection establishment COULD happen here
}
```

#### Option 2) Asynchronous per-instance #available

We could make this model work if we made the `#available` asynchronous, and it would work as follows:

```swift
// works, but forces pre-flight message
if try await #available(greeter, version: 2) { // forces connection, and pre-flight message on "first time" per actor type
  try await greeter.greet(name: "Caplin")
}
```

For completeness, the `#available` effectively would be a macro that takes the shape of something like:

```swift
protocol PerInstanceAvailabilityChecking { 
  associatedtype Base: DistributedActor
  // FIXME: 🫣 Our friend the problematic "protocol requirement with associatedtype"
  func checkAvailability<Instance: Base>(instance: Base, version: Int) async throws -> Bool
}

extension MyActorSystem { 
  func checkAvailability<Instance: Base>(instance: Instance, version: Int) async throws -> Bool {
    if let connection = self.connections(instance) {
      if let remoteVersion = self.versionsCache[(connection, Base.self)] {
        return version <= remoteVersion
      } else {
        // need to make a remote roundtrip to get the information
        let v = try await connection.getVersion(Base.self) // ⚠️ distributed call
        self.versionsCache[(connection, Base.self)] = v
        return version <= remoteVersion
      }
    } else {
      let connection = try await self.connect(instance.id) // force connection establishment
      // need to make a remote roundtrip to get the information (could be in handshake)
      let v = try await connection.getVersion(Base.self) // ⚠️ distributed call
      self.versionsCache[(connection, Base.self)] = v
      return version <= remoteVersion
    }
  }
}
```

So it is implementable, however again, we'd be forcing first-message per connection/type to make an roundtrip to just check if we're able to communicate at all – in order to complete the `#available()` check.

#### Semantics Discussion

We should discuss if this provides enough value, and how it relates to versioning and protocol evolution to decide if it's worth implementing or not.

This feature would **not** provide any support in evolving APIs. It only extends availability guards to remote calls, and effectively can prevent calls to not-implemented on remote side methods. In distributed systems, RPC or just plain HTTP in general, making a call and getting a "404 Not Found" equivalent respose is not uncommon, nor is it catastrophic. Unlike guarding @availability within the same address space, attempting to call a non existent method is not a dramatic problem that _must_ be avoided at any cost. 

Implementation aproaches to enable this compiler assisted "is this method available?" semantics would necessarily force before-remote-call message exchanges, which forces additional roundtrip messages (which may, depending on transport and network conditions account for hundreds od milliseconds of delays). Such additional delays are often not acceptable for many systems, where most effort is spent on minimizing the number of round trips (RTT, Round Trip Time) in order to minimize time-to-interative delays. 

We conclude that *forcing* systems into additional round trips is not a viable direction.

#### Necessary features for this approach are enabling Server Reflection, but not Evolution

This feature however does seem more similar to a different useful but optional capability of RPC systems which is "server reflection" (e.g. [gRPC Reflection](https://grpc.io/docs/guides/reflection/)), which gives a client the ability to inspect the capabilities of a server. The Option 1) approach effectively requires a server to be able to list all distributed actors and their versions; this is a building block for server reflection.

Reflection is useful in debugging services, but cannot be used in public facing APIs, quoting gRPC:

> Reflection is *not* automatically enabled on a gRPC server. The server author must call a few additional functions to add a reflection service. 
>
> If your gRPC API is accessible to public users, you may *not* want to expose the reflection service, as you may consider this a security issue. 

#### Compatibility Analysis Table

| Client    | API                                                          | Server                                                       | Compatibility |
| --------- | ------------------------------------------------------------ | ------------------------------------------------------------ | ------------- |
| Client@v1 | v1: <br />greeter(name: String)                              | API@v1: greeter(name: String)                                | ✅ Baseline    |
|           | v2: <br />greeter(name: String)<br />greeter(name: String, surname: String) | greeter(name: String)<br />@available(2) greeter(name: String) |               |
|           |                                                              |                                                              |               |



## Revisions

- 1.0
  - Initial revision