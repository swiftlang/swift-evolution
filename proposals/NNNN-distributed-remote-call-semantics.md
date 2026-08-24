# Distributed RemoteCall Semantics

* Proposal: [SE-NNNN](NNNN-distributed-synchronous-blocking-calls.md)
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TODO
* Status: **Awaiting review**
* Implementation: https://github.com/swiftlang/swift/pull/91316
* Review: TODO

## Introduction

Distributed functions are functions declared on distributed actors which may be located on remote hosts. Calls to such functions are implemented by switching over the "local or remote?" identity of the actual actor object the call is made on, and if the distributed actor is only a reference to a _remote distributed actor_, the call is forwarded to the `DistributedActorSystem.remoteCall` function which handles serialization and any necessary networking.

Today, there is no flexibility in terms of how remote calls are to be handled by remote call implementations, and therefore an assumption of request/response including "await for the response" is the expected semantic of all remote calls.

Some transports, be it IPC or network, have special semantics which they may want to employ to implement certain remote calls. 

This proposal introduces a way to express expected semantics for specific distributed methods, which an actor system implementation may then consider in making the remote calls.

## Proposed Solution

This proposal introduces a general mechanism to express semantic requirements for remote calls which are then handled by the underlying actor system. 

### Remote Call Semantics Attribute

We introduce a `@remoteCall(...)` attribute which we use to express two initial semantic attributes of remote calls. The design expects future extension of the set of supported semantics.

### Oneway / Unidirectional remote calls

In network protocols, as well as in classical actor model systems, it is common to send messages without awaiting their response. While this removes the implicit backpressure caused by a series of request/response calls, it enables building more efficient protocols and avoiding head-of-line blocking. Some protocols need to use a light-weight form of unidirectional "fire-and-forget" messages. Typical examples for those include streaming flow-controlled updates, keep-alive messages, or simple acknowledgments where the potential for message-loss is not an issue.

Today, distributed actors cater very well to the RPC request/response style of remote calls, however it has not been possible to cleanly express a oneway message send. We propose to introduce a remote call semantic marker expressing this semantic to the user, type-system, and actor runtime:

```swift
@remoteCall(oneway)
distributed func allGood() { ... }
```

### Synchronous Blocking Remote Calls

In the vast majority of situations blocking the calling thread is strongly discouraged, and especially blocking any thread that is part of the cooperative global thread pool which Swift Concurrency uses to run all asynchronous code on (unless a more specific executor is requested). However, some very specific performance sensitive IPC situations do call for ways to perform synchronous blocking calls over process boundaries. These calls may get preferential treatment and understanding from the system, and benefit from deep integration throughout the IPC stack.

Blocking calls need to be carefully managed and not occur in a context where the blocking is unexpected, or might cause thread-starvation etc. The ability to detect that an intentionally blocking call is being made also helps the runtime to determine and potentially throw (or crash) if such call is made from a context (e.g. thread) which must not be blocked, for example the main thread or threads belonging to the shared global concurrent executor. The policy of what and how to enforce and act on this semantic hint is left to actor system implementations.

```swift
@remoteCall(blocking)
distributed func superQuickRender() -> Frame
```

## Detailed Design

### Controlling semantics with @remoteCall(...)

First, we introduce the `@remoteCall(...)` attribute which may be used to adjust the semantic expectations of a remote call. 

#### Attribute grammar

The `@remoteCall` attribute is a declaration attribute, and this proposal adds the following production rules to the grammar of attributes:

```
attribute → remote-call-attribute

remote-call-attribute → '@remoteCall' '(' remote-call-option ')'

remote-call-option → 'oneway'
remote-call-option → 'blocking'
```

The argument clause is not optional, and exactly one semantic mode must be passed. There is no way to explicitly spell "remote call with default semantics", because that is precisely what an un-annotated `distributed` declaration already means.

The `remoteCall` attribute can only be applied to a `distributed func` or a `distributed var`. It is not allowed on a `distributed actor` or an extension of such actor because we want to have a tight visual indication of how a call will be executed, and not make it too difficult for developers to guess which semantic a call might have.

```swift
@remoteCall(blocking) // error: '@remoteCall' can only be applied to 'distributed' functions or computed properties 
distributed actor Greeter {
  @remoteCall(blocking) // error: '@remoteCall' can only be applied to 'distributed' functions or computed properties
  func localOnly() -> String { "..." }
}
```

Multiple `@remoteCall` attributes may be applied to the same declaration. We expect the set of supported semantics to grow in the future, so this leaves room for combining new attributes easily as we add them in the future.

The two semantics introduced by this proposal however are mutually exclusive: a `blocking` call is defined by waiting for the reply, and a `oneway` call has no reply to wait for, so combining them is rejected.

```swift
@remoteCall(oneway)
@remoteCall(blocking) // error: remote call semantics 'oneway' and 'blocking' cannot be combined
distributed func hello()
```

In the future we may introduce remote call options which are compatible with existing semantics.

This attribute is encoded into the `RemoteCallTarget` passed to the actor system's `remoteCall` implementation, effectively facilitating the following pattern:

```swift
extension MyActorSystem: DistributedActorSystem {
  func remoteCallVoid<Act, Err, Res>(
      on actor: Act,
      target: RemoteCallTarget,
      invocation: inout InvocationEncoder,
      throwing: Err.Type
  ) async throws -> Res
      where Act: DistributedActor,
            Act.ID == ActorID,
            Err: Error {
    // ...
    if <check target semantics> {
      // special handling
      return
    }
    // ... 
  }
}
```

Next, let us discuss the concrete semantics offered by this proposal.

### Oneway "unidirectional" calls with `@remoteCall(oneway)`

```
Caller task          DistributedActorSystem                 |    Remote server
───────────────      ──────────────────────────             |   ─────────────────
try await foo()  ──> [thunk]                                |
                      try await remoteCallVoid(...)         |
                      ─────── send message ─────────────────|─> executeTarget
                                                            |         │
<── return Void  <──  return/throw immediately after write  |         v
                                                            |     runs foo()
                                                            |         │
                                                            |        ...
```

By default, distributed method calls model the typical request/response nature of method calls and Remote Procedure Calls (RPC). Sometimes however, it is crucial to express unidirectional "fire-and-forget" message sends. In networking, such messages are very common and often used to implement batched writes, keep-alive or acknowledgments. 

This semantic attribute is spelled as: 

```swift
distributed actor Greeter {
  @remoteCall(oneway)
  func thanks()
}
```

Without this attribute even a void-returning distributed method call would still _await an (empty) reply_, causing a full request/response cycle. This may be beneficial if we want to confirm the recipient received or executed our call, but in this situation, we don't.

Oneway calls cannot return any values; attempting to declare a oneway method which returns a value results in a compile-time error:

```swift
extension Greeter {
  @remoteCall(oneway) distributed func thanks() -> String // error: oneway distributed function must return Void

  @remoteCall(oneway) func thanks() // OK
  @remoteCall(oneway) func thanks() -> Void // OK
  @remoteCall(oneway) func thanks() async throws -> Void // OK
}
```

Oneway calls are still asynchronous and may still throw, because the underlying `remoteCallVoid` method is asynchronous and throwing. 

A oneway remote call may throw when:

- serialization of the method arguments would fail.
- potentially, if the send of the message failed.
- any other reason which an actor system implementation may decide to communicate back to the caller on the sending side, without waiting for the reply.

Distributed computed properties are not allowed to be oneway, the inherent purpose of computed properties is to _read_ the value they return. We do not want to encourage treating computed properties like funny methods without parameters, instead, prefer methods without parameters if you intend to send an oneway message without inputs:

```swift
extension Greeter {
  @remoteCall(oneway) 
  distributed var question: String { ... } // error: distributed computed property cannot have 'oneway' remote call semantics
  
  @remoteCall(oneway) 
  distributed var weird: Void { ... } // error: distributed computed property cannot have 'oneway' remote call semantics
}
```

Finally, a oneway remote call may suspend when:

- the `remoteCall` implementation suspends; this may happen e.g. if the semantics of the transport are "await until the message was _sent_".

The exact timing semantics of such potential suspension are up to the specific actor system to define. Some may never suspend and simply fire off the message, while others may choose to suspend and resume the caller when the message was enqueued on the transport for example. This is a tradeoff that depends on the transport details, and it is hard for the language to decide up front on a hard rule that would fit all possible transports.

#### Implementing oneway remote calls

The oneway attribute is carried by the `RemoteCallTarget` descriptor that is passed to a `remoteCall` implementation, in the form of the `isOnewayRemoteCall` boolean property:

```swift
@available(SwiftStdlib 5.7, *)
public struct RemoteCallTarget {
  // ... existing members ...

  /// Whether the target was declared '@remoteCall(oneway)'.
  @available(SwiftStdlib 6.5, *)
  public var isOnewayRemoteCall: Bool { get set }
}
```

There, an actor system may choose to act on it. It is important to note that these remote call semantics are effectively "hints" for the implementation to act on a specific call in some specified way. If a system does not understand a semantic it may choose to ignore it entirely, or actively throw/crash reporting to the developer this style of call is not supported by the system.

Assuming the system does support oneway calls, this is how one would implement handling it:

```swift
extension MyActorSystem: DistributedActorSystem {
  func remoteCallVoid<Act, Err, Res>(
      on actor: Act,
      target: RemoteCallTarget,
      invocation: inout InvocationEncoder,
      throwing: Err.Type
  ) async throws -> Res
      where Act: DistributedActor,
            Act.ID == ActorID,
            Err: Error {
    // ...
    if target.isOnewayRemoteCall {
      try sendMessage(to: actor.id, target, invocation) // example impl; didn't suspend at all
      return
    }
    // ... 
  }
}
```

The system should not make attempts to carry back failures of oneway remote calls from the remote side, because this also implies waiting for the call to complete.

### Synchronous blocking calls with `@remoteCall(blocking)`

As discussed earlier, the explicit "blocking" mode of remote calls is designed for very few, yet important, situations, so it is quite likely many developers will not interact with this mode.

The semantic attribute offers an expressive way of signalling that blocking is both intentional, expected, and must be handled carefully when making a *specific call*. Today a system implementation may already just implement remote calls by blocking them, however that would be rather unexpected and the usual mode of operation is suspending the local task while awaiting for the remote server to reply (or timeout) to the call.

The blocking semantic changes this flow to the following:

```
Caller thread        DistributedActorSystem                 |   Remote server
───────────────      ──────────────────────────             |   ─────────────────
try await foo()  ──> [thunk]                                |
                      try await remoteCall(...)             |
                      ═══════ send message ═════════════════|═> executeTarget
                      thread BLOCKED; does not suspend      |         │
                              ║                             |     runs foo()
                              ║                             |         │
                              ║                             |         v
                              ║                             |    returns Frame
                      <═══════ reply ═══════════════════════|══
<── return Frame <──  unblocked, decode and return          |
```

There are no additional type-checking rules applied to blocking calls. Notably such calls still are implicitly async because the case when calling a local actor still does the usual actor hop. The remoteCall path however is possible to execute without ever suspending on the local side of the call.

#### Implementing blocking remote calls

As with oneway calls, the `blocking` semantic is recorded onto the `RemoteCallTarget` descriptor:

```swift
@available(SwiftStdlib 5.7, *)
public struct RemoteCallTarget {
  // ... existing members ...

  /// Whether the target was declared '@remoteCall(blocking)'.
  @available(SwiftStdlib 6.5, *)
  public var isSynchronousBlockingRemoteCall: Bool { get set }
}
```

A system implementation can then act on this hint and implement a blocking call when necessary:

```swift
func remoteCall<Act, Err, Res>(
  on actor: Act, target: RemoteCallTarget,
  invocation: inout InvocationEncoder, throwing: Err.Type, returning: Res.Type
) async throws -> Res
  where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: SerializationRequirement {
  if target.isSynchronousBlockingRemoteCall {
    try ... // perform a blocking synchronous request/response
  } else {
    try await ... // perform the usual asynchronous request/response
  }
}
```

#### Preventing blocking calls from certain contexts

More importantly though, the explicit nature of these attributes means that the system can perform a dynamic check if the context where the blocking is about to happen is allowed to block (or not):

```swift
if target.isSynchronousBlockingRemoteCall {
  guard allowedToBlock(<check current executor>)
        || currentThreadIsAllowedToBlock(...) else {
    fatalError("Blocking call detected on unsupported executor or thread!")
  }
  
  // make the blocking call
}
```

Currently checking the current executor's compatibility with blocking is somewhat tricky, however we expect the introduction of APIs to query the current task executor (e.g. through the [Custom Main and Global Executors](https://forums.swift.org/t/pitch-4-custom-main-and-global-executors/89107) proposal or similar). Regardless of these upcoming APIs to query the current executor though, systems may use their own custom mechanisms to determine if it is safe to block on the calling context or not. E.g. they may require doing so only on a specific dispatch queue, or actor executor by checking `Actor.assumeIsolated` or similar.

Existing systems which do not support the semantic hint, would just execute the calls without blocking, which we believe is a good way to roll out this feature.

### Remote call semantics in @Resolvable protocols

The API boundary, or "contract", of a service in is declared using `@Resolvable` protocols, as defined in [SE-0428 Resolve DistributedActor protocols](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0428-resolve-distributed-actor-protocols.md). 

These protocols serve as the single-source-of-truth of api descriptions, similar like an IDL (Interface Description Language) works in similar systems that rely on an external language to define the API surfaces. Because APIs are offered to consumers by exposing such protocol, it is important to annotate the semantics of a call on the protocol itself:

```swift
@Resolvable
protocol Greeter: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
  @remoteCall(oneway)
  distributed func thanks(name: String)
}
```

Because a consumer of such API protocol is only interacting with the protocol, without ever knowing the underlying implementation type it is crucial for calls on resolved distributed protocols to respect the declared semantics, e.g.:

```swift
let greeter: any Greeter = try $Greeter.resolve(...)
try await greeter.thanks(name: "Caplin") // thank, don't wait for response network-roundtrip
```

Such call will arrive at the `remoteCall` function of the actor system with the appropriate call semantic set.

A witness to a distributed function with specific semantics cannot "drop" those semantics; The source of truth is the protocol declaration.

## Source compatibility

This proposal is entirely additive, existing systems will simply ignore the new semantic hints.

## ABI compatibility

This proposal is entirely ABI additive, new computed properties are added onto the existing `RemoteCallTarget`.

## Wire compatibility

This proposal does not affect the wire protocol of remote calls by itself, however if an implementation wants to start using it to allow new ways of making remote calls, this is opt in and should not break existing implementations.

It is technically possible to make a blocking or oneway call to a remote side which did not implement those semantics; however the technical possibility of implementing this strictly depends on the implementation's transport mechanism.

## Future directions

### `nonisolated(nonsending)` remote calls to avoid the executor hop

The goal of allowing blocking calls is to eventually be able to have a "zero (thread or actor) hops" hot path for critical IPC calls. Today the runtime will still insert a hop "off" a calling context onto the global concurrent pool when invoking the `nonisolated func remoteCall` which is implicitly `@concurrent`. We will allow opting into executing these remoteCall functions on the calling context, which will eliminate this unnecessary thread hop and further improve performance of remote calls, also benefitting normal asynchronous calls.

### Idempotent remote calls and automatic retrying

Another potential semantic that would be useful to express in the future might be the concept of idempotent calls. The same as as `GET` operations are generally considered idempotent in well-designed RESTful APIs, or other RPC systems identify idempotent calls in other ways, allowing them to retry operations of e.g. the connection breaks while obtaining the response etc.

In general an actor system cannot safely automatically retry operations because it is not clear if a call was delivered and may have caused a side-effect, which must not by accidentally caused twice. Idempotent methods would indicate to the actor system that a call may be invoked multiple times and will not cause unexpected or duplicated side-effects. 

## Alternatives considered

### Always treat void-returning methods as unidirectional

This was discussed when distributed methods were first introduced. It is semantically not correct to just treat any void-returning method as oneway because functions may still return an error by throwing, or returning without failing may still function as an acknowledgment that the request was at least received or processed (depending on API contract).

Therefore, an opt-in mechanism to determine which methods may be treated as unidirectional remains necessary.

### Make both oneway and blocking calls not async

In theory, since a remote oneway call does not need to wait for a reply we could make those calls not async and allow `try ref.onewayMethod()` however due to distributed references always being in either: "known to be local" or "potentially remote" states, the type system cannot express the fact that a reference will definitely be on the remote path. 

The local call path still is a normal actor call and we need to make an async/await call to the actor.

It would be possible to make these functions "not await" by ad-hoc creating a new task like so `Task.immediate { try await ref.onewayMethod() }` however w e should not be creating unstructured tasks without the knowledge of users, as it leads to unexpected resource usage growth. 

Therefore, if users need to call oneway (or blocking) methods from a not-async context they should create an unstructured immediate task themselves. In the remote call path the immediate task would also be able to not suspend at all, since the immediate task starts executing immediately on the caller.

### A dedicated `SynchronousDistributedActorSystem` marker protocol

It is not required to be absolutely certain if and how some semantic will be implemented by an actor system. There is no way around reading the documentation of an actor system runtime to understand its transport semantics. A marker protocol may provide a hint, but still would be insufficient to truly understand how a call is implemented. Any semantic of a remote call (oneway, synchronous or just plain asynchronous) has its own small details that users may need to read up about if they intend to fully understand the transport semantics. For most users assuming the system "does the right thing" is sufficient.

### Distinct `remoteCallSync` / `remoteCallVoidSync` requirements

It is not necessary to introduce new requirements because we're able to support `nonisolated(nonsending)` in existing `remoteCall` which will enable the same amount of hop elimination without having to duplicate requirements.

### Changing the `distributed` keyword (`distributed(sync)`)

The semantic changes we're expressing with this attribute are not about the distributed-ness of the declarations, which is an isolation property rather than a property of the calls.

The semantics we need to express here specifically are tied only to the remote calls performed, and do not affect local calls which remain exactly as if it were a plain actor instance.

## Prior art

### Other ecosystem's "oneway" equivalents

Oneway calls are common in various actor systems across many RPC systems.

**Orleans (2010):** The system most similar to DistributedActorSystem because of its leaning into "looks like a method call" usability is Microsoft Orleans. Orleans offers oneway method calls using the `[OneWay]` attribute:

```c#
public interface IOneWayGrain : IGrainWithGuidKey
{
    [OneWay]
    Task Notify(MyData data);
}
```

We feel this is a useful precedent and it expresses the same semantic we are aiming to offer.

**Akka (2009):** Akka actor messaging defaults to oneway messages where they're expressed using the `!` operator (spelled as "`tell`" in the Java API). Request response messaging is expressed using the `?` operator (spelled as "`ask`" in Java API). 

The terminology of `actor tell message` reads well with messages, but not as much in the method-oriented syntax of Swift, so using "tell" as our way of signalling oneway wouldn't really read naturally.

**Apache Thrift (2007):** Thrift's IDL also offers a `oneway` modifier, e.g. `oneway void log(1: string message)`, with the same restriction that oneway methods must return void and cannot propagate declared exceptions back to the caller. 

**Erlang/Elixir/OTP (1986):** Erlang's raw actor primitive, `!` (read as "send"), is unidirectional and does not wait for any response from the recipient. The popular way to build RPC actors, `gen_server` however does expose a request/response pattern which is known as "call": `gen_server:call/2`, as opposed to "cast" which is oneway/unidirectional. 

Using the terms "send" or "cast" doesn't really express the semantics very well, and would be confusing to read as `@remoteCall(cast)` in Swift.

**Distributed Objects (1988):** Objective-C Distributed Objects, `NSDistantObject`, dating back to NeXTSTEP, implemented synchronous blocking remote calls, and were sometimes criticized for being too implicit in their remote call handling. Calls would look like normal local methods yet perform remote blocking calls by default. Distributed Actors differ here significantly because both effects (`throws` and `async`) are modeled by the language, and it is simple to notice where remote calls might be happening.

Objective-C offers a literal `oneway` method-declaration keyword: `- (oneway void)update:(id)data;`. A method declared `oneway` returns as soon as the message is enqueued, which matches the proposed semantics of `@remoteCall(oneway)`.

**CORBA (1991):** CORBA's IDL has a literal `oneway` keyword predating this proposal by decades. An operation declared as `oneway void notify(in Data d);` must return `void`, may not declare any raised exceptions, and may not have `out` or `inout` parameters. The ORB is explicitly permitted, though not required, to deliver oneway calls best-effort rather than guaranteed, and to return control to the caller without waiting for the call to reach the server at all. These restrictions map almost exactly onto the void-only restriction this proposal places on `@remoteCall(oneway)`, and the term "oneway" used here likely traces back to this CORBA IDL usage, or to Distributed Objects, which predates it on Apple platforms.

Interestingly, **gRPC (2015)** does not offer any unidirectional calls, as in practice every call may end with a trailing response. However oneway messages are implemented as passing a stream of messages in an initial RPC which is later on consumed by the recipient. This pattern is also already possible in Swift.

Summing up, we see that the majority of RPC frameworks and systems use the term `oneway` and it explains the semantics we're exposing quite well.

## Revisions

- v1: Initial revision
