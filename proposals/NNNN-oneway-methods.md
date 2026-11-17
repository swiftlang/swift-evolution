# `send` and `@oneway` method calls

* Proposal: [SE-NNNN](NNNN-oneway-methods.md)
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TODO
* Status: **Awaiting review**
* Implementation: https://github.com/swiftlang/swift/pull/91316
* Review: [Pitch thread](https://forums.swift.org/t/pitch-distributed-remotecall-semantics/89357)

## Introduction

This proposal introduces oneway method calls, spelled with the `send` keyword, that make it easier to interact with isolated code from synchronous contexts. It also introduces the `@oneway` attribute which allows API authors to be intentional in their API design, by declaring that a method is meant to be called with `send`. Distributed calls made with `send` can leverage underlying fire-and-forget transport mechanisms. Oneway calls offer an intentional, safe, and more efficient way of enqueueing asynchronous work in isolated contexts in-order from any context.

## Motivation 

Methods declared on actors are implicitly asynchronous when called from another isolation context. This is inherent due to how actor isolation works. Actors ensure thread-safety by processing all tasks one-by-one on a specific serial executor, and therefore in order to enqueue a method call and obtain its result, one has to suspend until the the tasks gets to run on the actor, meaning that all such callsites are a potential suspension point. Optimizations may happen at runtime that actually execute the target method immediately on the calling task without suspension, but it is not possible to determine this at compile time as it's a dynamic, timing sensitive property.

This means that it is not possible to send common commands to an actor from synchronous contexts, such as calling a `complete()` or similar method on an actor from a synchronous callback. In order to enable such calls anyway, today, developers are often forced into writing the following pattern:

```swift
test(onComplete: { 
  if #available(...) {
    Task { await actor.complete() }
  } else {
    Task.immediate { await actor.complete() }
  }
})
```

Not only it this overly verbose, but also wasteful: such calls often actually never have interesting results (they return `Void` and don't throw), and the additional Task creation is comparatively heavy. 

Even worse, while the use of `Task.immediate` attempts to provide some kind of FIFO-ness to the calls, this isn't actually guaranteed in any way, because one might actually escalate a later task, causing the `complete()` in the following example to be (potentially) processed before the `onNext(1)`:

```swift
Task.immediate { await actor.onNext(1) } // enqueued first, at the current priority
let t = Task.immediate { await actor.complete() } // enqueued second

// Somewhere else, the retained task is escalated;
// either explicitly, or implicitly by awaiting it from a higher priority task:
Task.escalatePriority(of: t, to: .high) // Oh no!
// or: Task(priority: .high) { await t.value }
```

This results in a brittle "hope no-one changes the code" programming model which isn't very robust or intentional about the desired behavior.

### Inter-process communication

Crucially, in inter-process calls, offered by `distributed` functions, the lack of first class "send, don't wait" is even more problematic. Without explicit information about whether or not a call is truly uni-directional (sometimes called "oneway") runtimes can't know if they can use more optimized fire-and-forget messaging primitives, and force the callers to wait on a response even if the response is semantically meaningless. 

This makes it impossible to implement some network protocols effectively as implementations are forced into request-reply where they truly do need the ability to fire-and-forget messages across the network. The cost of a request-reply roundtrip is astronomically higher in a distributed system than it is within a process with just asynchronous methods, so this is a large performance problem for some systems. 

For example, it would be incredibly inefficient to implement a Sequence-like concept using distributed methods today, since they are forced into request/reply round-trips:

```swift
// we know remoteRecipient is guaranteed to be able to receive 3 elements (flow-control on protocol level)
try await remoteRecipient.send(1) // needs to await response before sending second element
try await remoteRecipient.send(2)
try await remoteRecipient.send(3)
try await remoteRecipient.complete()
```

And even if we did improve this with `Task.immediate` wrapping every remote call, we would still be using up resources for the network replies we are actually not interested in at all. It would be much more efficient to be able to make the transport use the apropriate oneway transport mechanism.

## Proposed Solution

This proposal introduces the `send` keyword which allows calling actor isolated functions without awaiting their results, in a fire-and-forget "oneway" manner.

For example, the following streaming like use-case, which previously would be forced into creating unstructured tasks explicitly, with all their implications discussed above, can now use the `send` instead of `await` when calling the actor isolated functions like this:

```swift
actor Collector { 
  func onNext<T: Sendable>(_: T) { ... }
  func complete() { ... }
}

func subscribe(stream: LegacyStream, collector: Collector) {
  stream.subscribe(
    onNext: { value in send collector.onNext(value) }, // call async-code from synchronous callback
    onComplete: { send collector.complete() } // call async-code from synchronous callback
  )
}
```

Any actor isolated method which does not throw and returns `Void` may be called with `send` instead of `await`. Semantically, this is similar to creating an ad-hoc task's operation will call and await the target method.

API authors can provide a hint about the intended use of an API by _optionally_ annotating methods with the `@oneway` attribute. We expect this attribute to be used rarely, and only when there is a significant design reason that a method should only be called without awaiting it.

For example, a method can be marked as intended to only be used with oneway `send` calls, which will cause a warning to be emitted if the method is called with `await` instead:

```swift
actor Collector {
  @oneway
  func collect(_ value: Int) { ... }
}

await collector.collect(12) // warning: '@oneway' instance method 'collect' is not intended to be awaited on, use 'send' instead
```

It is possible to turn this warning into an error using the `@diagnose(as:)` attribute, or globally by using the appropriate warning group.

Sending method calls to actors creates a special light-weight job, and enqueues it immediately on the target actor, and there is no risk of accidental priority escalation reordering the enqueued tasks, as there is with any API returning an awaitable task handle.

The explicit `send` keyword is crucial for understanding code semantics and makes oneway calls intentional. Using `send` must be acknowledged to be creating an unstructured task, consume memory and scheduling capacity, therefore omitting the keyword is not allowed. 

Unlike creating a `Task { await collector.onNext(value) }` for each call, consecutive `send` calls made from the same task to the same actor are enqueued, and therefore executed, in order. Oneway calls of synchronous methods can also be executed without allocating an asynchronous task stack.

Distributed methods declared `@oneway`, when invoked with `send`, carry this information to the underlying `DistributedActorSystem`, which then can make use of specialized fire-and-forget IPC mechanisms to perform more efficient IPC calls. For example, an [XPC](https://developer.apple.com/documentation/xpc/) actor system could use [xpc_session_send_message_async](https://developer.apple.com/documentation/xpc/xpc_session_send_message_async) for `send` messages, but still use the request-reply variant of this API ([xpc_session_send_message_with_reply_async](https://developer.apple.com/documentation/xpc/xpc_session_send_message_with_reply_async)) for calls which to expect a reply:

```swift
distributed actor IPCWorker {
  @oneway
  distributed func enable()

  distributed func refresh()
}

func test(worker: IPCWorker) async throws {
  try send worker.enable()     // directly invokes the actor system's synchronous oneway send path
  try await worker.refresh()   // regular request-reply call
}
```

## Detailed Design

### The `send` call expression

We introduce a new `send` keyword which may be used in place of `await` when making calls to isolated methods. Sending a method call enqueues it on the target's isolation domain, and returns immediately without waiting for the call to return. It also deeply integrates with `distributed` functions, which we'll discuss in its dedicated section ([Send oneway distributed method calls](#send-oneway-distributed-method-calls)).

One of the keywords, `await` or `send` must be used when invoking a method cross-isolation, as the caller either must potentially suspend and wait for the method to execute, or additional resources must be created to invoke the target method asynchronously. Omitting the `send` keyword is not permitted because it would lead to accidental and hidden introduction of concurrency and resource utilization.

The `send` keyword's effect is similar to manually creating a task on the right isolation and ignoring its result; however it is vastly more efficient when the target method is a synchronous function, as the created task may omit creating the asynchronous context otherwise necessary for such task. 

Using `send` rather than the pattern of wrapping calls in  `Task { await actuallyAsync() }` and hiding this behind a "synchronous looking" API is vastly clearer in source as it spells out the actual intent of the code, rather than hiding it in helper functions. For example, we often see code like this, that attempts to hide the Task creation in a synchronous function, in order to make it easier to call from a synchronous context:

```swift
actor Worker { 
  func actuallyAsynchronous(_ string: String) async {
    print("got: \(string)")
  }

  nonisolated func looksEntirelySynchronousButIsnt(_ string: String) {
    Task { // Don't do this.
      await actuallyAsynchronous(string)
    }  
  }
}

// Could result in any ordering being printed!
func syncTest(worker: Worker) {
  worker.looksEntirelySynchronousButIsnt("A")
  worker.looksEntirelySynchronousButIsnt("B")
}
//   got: A
//   got: B
// or
//   got: B
//   got: A
// are both possible in such implementation.
```

Instead, the `send` based variant of the above code, wouldn't need this helper function at all:

```swift
actor Worker { 
  func actuallyAsynchronous(_ string: String) async {
    print("got: \(string)")
  }
}

// Guaranteed to print (using default executor):
//   got: A
//   got: B
func syncTest(worker: Worker) {
  send worker.actuallyAsynchronous("A")
  send worker.actuallyAsynchronous("B")
}
```

This more clearly expresses the intent of the code, rather than working around limitations caused by awaiting actor methods. It also is more correct, as it guarantees the delivery of the `"A"` call before `"B"`. 

Tasks created by `send` cannot be priority escalated from the calling context, because they are effectively unstructured tasks/jobs, so automatic priority escalation does not risk reordering of the tasks. It is possible to obtain a reference of the self task and attempt to escalate it once the `"A"` call arrives at the actor, however this too would not be able to reorder it with respect to `"B"` because A is already executing.

> Custom actor executors might reorder task execution, however this is not a concern for "default actors" which have the default executor implementation; and the majority of typical `SerialExecutor` implementation.

There is also an additional benefit related to the runtime efficiency of `send` calls: if the called method is synchronous, the created job does not need to allocate a full asynchronous context to execute it, and therefore the job created in order to execute the oneway call can be significantly lower overhead than the naive `Task.init` approach.

> Sending method calls does not prevent actor reentrance issues; so if an asynchronous method suspends, you may still get interleaving execution.

Unlike `await`, `send` does not create a potential suspension point, and therefore can be used in any context, including synchronous code:

```swift
actor Collector {
  func onNext(_ value: Int) { ... }
}

func notify(collector: Collector, value: Int) {
  send collector.onNext(value) // OK, no 'async' context necessary
}
```

`send` expressions can handle optional chaining whose links are synchronous and accessible from the caller's isolation, if the unwrapped target would be actor isolated:

```swift
actor Callable {
  func call(_ value: Int)
  nonisolated var next: (any Callable)? { get }
}

func test(callable: Callable?, maybeCallable: (any Loggable)?) {
  send callable?.call(1)      // OK
  send callable?.next?.log(2) // OK, optional chaining can have multiple steps
}
```

The optional chain is evaluated at the call site, and if any of the chain is `nil`, the rest of the chain and the arguments are not evaluated, and no call is enqueued. This is an example of a syntax that would be difficult to achieve with any closure-style APIs (e.g. `Task.<some-name> {...}`), as we have to evaluate the target before we decide if we will create a task for the call or not.

Since the chain is evaluated at the call site, every link before the final call must be accessible synchronously from the caller's context. A link which is isolated to another actor, or which is `async`, would require awaiting at the call site, and is therefore not allowed:

```swift
actor Callable {
  func call(_ value: Int) {}
  
  var next: Callable? { ... }       // actor isolated
  nonisolated var nonisolatedSynchronousNext: Callable? { ... }
  nonisolated var nextAsync: Callable? { 
    get async { ... } 
  }
}

func syncTest(callable: Callable?) {
  send callable?.call(1)                             // OK
  send callable?.nonisolatedSynchronousNext?.call(2) // OK, synchronous and nonisolated
  
  send callable?.next?.call(3)                       // error: actor-isolated property 'next' can not be referenced from a nonisolated context
  send callable?.nextAsync?.call(4)                  // error: 'async' property access in a function that does not support concurrency
}

func asyncTest(callable: Callable?) async {
  send callable?.nonisolatedSynchronousNext?.call(5) // OK, synchronous and nonisolated
  send callable?.next?.call(6)                       // error: actor-isolated property 'next' cannot be accessed from outside of the actor
  send callable?.nextAsync?.call(7)                  // error: expression is 'async' but is not marked with 'await'

  if let next = await callable?.next {
    send next.call(8)                                // OK
  }
}

extension Callable {
  func inside() {
    send next?.call(9)                               // OK, 'next' is accessed on 'self', in the same isolation
  }
}
```

Evaluating the chain in the enqueued job instead would mean that the target of the call is only known once the job has hopped through the isolation of every link, so that consecutive `send` calls could no longer be enqueued on their target in program order.

Multiple async hops are not supported in such chains, so e.g. we can unwrap a local optional, but it is not supported to call through an asynchronous function or getter (like `nextAsync` in the above example) returning a `Callable` which then contains the target of a `send`. Doing so would hide a potential suspension-point, which always must be acknowledged with an explicit `await`.

#### `send` compatible declarations

It is not allowed to `send` method calls which return a value or throw, as there would be no way to obtain the result or the error. 

```swift
actor Worker {
  func ensureRunning() {}
  func process(_ item: Item) async {}
  func count() -> Int { 0 }
  func validate() throws {}
}

func test(worker: Worker, item: Item) {
  send worker.ensureRunning() // OK
  send worker.process(item)   // OK

  send worker.count()         // error: 'send' cannot discard the result of a call to 'count()'
                              // fixit: send -> await

  send worker.validate()      // error: 'send' cannot discard error thrown by call to 'validate()'
}                             // fixit: send -> await
```

A `send`-called function must explicitly return `Void`. 

This includes functions annotated with `@discardableResult`: the attribute expresses that a caller which awaits the call may ignore its result, not that the function was designed to be called without anybody waiting for it. Requiring `Void` keeps the rule simple and makes the intent of a `send`-able API visible in its signature:

```swift
actor Worker {
  @discardableResult
  func confirm() -> Bool { ... }
}

func test(worker: Worker) {
  send worker.confirm()           // error: 'send' cannot discard the result of a call to 'confirm()'
                                  // fixit: send -> await
  await worker.confirm()          // OK, the returned 'Bool' is discarded
}
```

It is not allowed to `send` property or subscript accesses. Discarding the result of a `get` would be rather unusual, and would hide an expensive or side-effecting getter behind what looks like a property access. Similarly, asynchronous `set` accessors are not supported today.

```swift
actor Worker {
  var count: Int = 0

  var message: String {
    get async { ... }
  }

  var name: String {
    get { ... }
    set { ... }
  }

  subscript(index: Int) -> String {
    get { ... }
    set { ... }
  }
}

func test(worker: Worker) async {
  send worker.count            // error: 'send' cannot be applied to property access
  send worker.message          // error: 'send' cannot be applied to computed property access
  send worker.name             // error: 'send' cannot be applied to computed property access
  send worker.name = "Caplin"  // error: 'send' cannot be applied to computed property assignment
  send worker[0]               // error: 'send' cannot be applied to subscript access
}
```

Only isolated methods can used with `send`, and the call is immediately enqueued onto the target actor from the calling context. Neither  `nonisolated`, `nonisolated(nonsending)` or `@concurrent` functions, can be called using `send`.

```swift
actor Worker {
  nonisolated func describe() {}
  nonisolated(nonsending) func log(_ s: String) async {}
  @concurrent func compute() async {}
}

func test(worker: Worker) async {
  send worker.describe()    // error: 'send' can only be applied to calls of actor isolated methods
  send worker.log("hello")  // error: 'send' can only be applied to calls of actor isolated methods
  send worker.compute()     // error: 'send' can only be applied to calls of actor isolated methods
}
```

In summary, `send` may be applied to calls of methods that:

- are actor isolated in any way: to an actor instance, to a global actor, or through an `isolated` parameter,
- and return `Void`,
  - returning `Never` is not allowed,
- and do not throw (`throws(Never)` is equivalent to not throwing, and is allowed),
- are not property or subscript accesses,
- and, if they are distributed methods, are declared `@oneway` (see [Sending oneway distributed actor calls](#send-oneway-distributed-method-calls)).

#### Arguments of a `send` call

The receiver, the callee and the arguments of a `send` call are evaluated at the call site, in order, before the next statement, just like those of a direct call. Only the call itself is executed later, on the target's actor. Any effects of evaluating them therefore happen at the call site, and need their own `try` or `await` there. In an optional chain, nothing after a link that fails is evaluated, and no call is made:

```swift
actor Logger {
  func log(_ value: Int) { ... }
}

func test(logger: Logger?, makeValue: () throws -> Int) throws {
  send logger?.log(try makeValue()) // 'makeValue()' runs here, and throws to 'test'
                                    // if 'logger' is nil, 'makeValue()' is not called
}
```

The same applies to a receiver which is produced by a throwing call. If evaluating it throws, the error propagates to the caller, and the `send` does not happen:

```swift
func test(makeLogger: () throws -> Logger) throws {
  try send makeLogger().log(1) // 'makeLogger()' runs here, and throws to 'test'
                               // if it throws, nothing is enqueued, and 'log(_:)' is never called
}
```

The arguments of a `send` call cross into the target's isolation domain, the same way as the arguments of an `await` call would.

Semantically, one can think of a `send` as if it were an implicit target isolated closure, capturing the arguments passed to it. That closure is guaranteed to be executed exactly once, as if it were an `@once` closure [SE-NNNN: Called once closures](https://github.com/swiftlang/swift-evolution/pull/3429). Therefore region based isolation ([SE-0414](0414-region-based-isolation.md)) applies to `send` expressions as you would expect: a non-`Sendable` argument must be in a disconnected region, and it is sent to the target actor, so it cannot be used by the caller afterwards:

```swift
actor Worker {
  func take(_ value: NonSendable) { ... }
}

func test(worker: Worker) {
  let nonSendable = NonSendable()
  send worker.take(nonSendable)
  nonSendable.poke() // error: sending 'nonSendable' risks causing data races
}
```

Declarations that have `inout` arguments are not allowed to be used with `send`, as the target function may be still executing after the surrounding caller context has completed:

```swift
actor Worker {
  func update(_ value: inout Int) { ... }
}

func test(worker: Worker) {
  var value = 0
  send worker.update(&value) // error: 'send' cannot be applied to a call with 'inout' arguments
}
```

Since `send` calls are executed exactly once, they may consume non-copyable arguments the same way a closure which is called at most once can.

A `send` call always consumes its noncopyable arguments, because the value must outlive the caller's scope.

```swift
struct FileHandle: ~Copyable { ... }

actor Logger {
  func retarget(to handle: consuming FileHandle) { ... }
  func inspect(_ handle: borrowing FileHandle) { ... }
}

func test(logger: Logger) {
  let a = FileHandle(...)
  send logger.retarget(to: a) // OK, 'a' is moved into the enqueued call
  a.write(...)                // error: 'a' used after consume

  let b = FileHandle(...)
  send logger.inspect(b) // OK, 'b' is consumed by 'send', and destroyed after 'inspect' returns
}
```

Non-escapable values cannot be passed to `send` calls, because the job created for the call escapes the surrounding context, just like an unstructured task would:

```swift
actor Summer {
  func add(_ values: Span<Int>) { ... }
}

func test(summer: Summer, numbers: [Int]) async {
  await summer.add(numbers.span) // OK, 'numbers' outlives the awaited call
  send summer.add(numbers.span)  // error: 'send' cannot be applied to a call with non-escapable argument of type 'Span<Int>'
}
```

### `send` and task-local values

Since `send` creates an unstructured job, similar to `Task.init`, it copies the task-local values at the call site of the function, and the called function observes those values when it eventually executes.

```swift
enum Trace {
  @TaskLocal static var requestID: String = "none"
}

actor Logger {
  func log(_ message: String) {
    print("[\(Trace.requestID)] \(message)")
  }
}

func handle(logger: Logger) {
  Trace.$requestID.withValue("req-42") {
    send logger.log("started")  // prints: [req-42] started
  }

  send logger.log("finished")   // prints: [none] finished
                                // the binding is not in effect at this call site
}
```

Today, there is no way to drop task local values from a `send` call, which would be the equivalent of `Task.detached` which does does not copy task locals into the new task at creation time. We believe this is the right choice to copy TaskLocal values in ordinary send calls, however we may explore an `@oneway(detached)` attribute if it ever were to become necessary (see [Allow detaching the implicit unstructured task with `@oneway(detached)`](#allow-detaching-the-implicit-unstructured-task-with-onewaydetached)).

### `send` is not Structured Concurrency

It is worth calling out explicitly that any use of `send` is explicitly breaking the Structured Concurrency contract: that callers wait until the code they call completes before continuing execution.

We believe having an explicit, well understood, optimized, and intentional way of breaking out of structured concurrency for the purpose of notifying an actor using specific, well-ordered calls, is an improvement over the status quo, where developers faced with a problem where they _must_ break out of structured concurrency, every time have to build ad-hoc solutions to the issue. Some developers reach to `Task.init` without realizing the loss of ordering guarantees they might be betting on. Other solutions might reach to manual management of queues with `AsyncStream` and yielding into it from synchronous contexts, which quickly becomes very verbose.

The explicit `send` keyword also makes it simple for linters to prevent its use. It would be difficult to ban use of task creation outright, but it is simpler to form policy around the use of `send` using linters or other tools, since it's purpose and behavior is very specific and well defined.

### The `@oneway` attribute

By default, every method declaration that fulfills the requirements discussed above, can be called with `send` instead of `await`. 

The caller may decide to invoke the method one way or another, depending on their use-case. This is similar to today's situation where callers can call any piece of code with `await target.wait()`, or create an unstructured task to make the same call: `Task { await target.wait() }`.

Previously, there was no way for API authors to communicate if calling a method without waiting for its result would be intended and supported behavior, or if it would be a very bad idea. From a source code perspective, we cannot easily tell apart an `await target.wait()` called "without waiting for it" because this depends on where this call is made from, i.e. was it called from an ad-hoc task created for the purpose of ignoring the result or not?

By introducing a well defined spelling for these oneway calls, we can detect and offer guidance about the intended use of APIs. To express this, we introduce the optional `@oneway` attribute:

```swift
actor Test { 
  @oneway
  func callMe() { }
}
```

The `@oneway` attribute is **optional**, allows API authors to express their intent that such API is expected to be called without waiting for it to complete, and does not expect to be part of a structured concurrency call hierarchy. 

> The `@oneway` attribute does NOT introduce a new "function color". 
> It is purely an informational mechanism, issuing warnings when such method is used without `send`.

Typical examples for these are completion handlers. We still recommend developers make every attempt possible to keep methods within Swift's Structured Concurrency, however we do acknowledge that sometimes methods stepping out of it do exist, and it is beneficial to be able to express this in code.

It is not a requirement for methods to be annotated with `@oneway` in order to be called with `send`, because we anticipate existing methods which may want to be called this way and may not be annotated correctly. For example, imported Objective-C methods may not get annotated properly, but are a common target of such oneway calls:

```swift
// Imported from Objective-C, not annotated with `@oneway`:
//   NS_SWIFT_UI_ACTOR @interface ProgressView : NSObject
//   - (void)updateProgress:(double)fraction completionHandler:(void (^)(void))completionHandler;
//   @end
//
// The completion handler makes the method import as an `async` method:
//   @MainActor func updateProgress(_ fraction: Double) async

// Or an existing method in a library which cannot be changed:
actor Metrics {
  func record(_ name: String, value: Int) { } // not `@oneway`
}

func report(view: ProgressView, metrics: Metrics) {
  send view.updateProgress(0.5)           // OK, the method is not annotated, but is eligible for `send`
  send metrics.record("requests", value: 1) // OK, also not annotated
}
```

Calling a method which is not annotated with `@oneway` with `send` is always allowed, as long as the method fulfills the `send` requirements: it must not throw, and must return `Void`. 

For local actors, the attribute does not change how the method executes, and it does not introduce a new effect or "color": it does not propagate to callers in any way. It is a declaration attribute, not part of the method's type, see [`@oneway` is a declaration attribute](#oneway-is-a-declaration-attribute). It expresses the API author's intent, which the compiler checks at call sites. For distributed methods, `@oneway` is required in order to call them using `send`, and it enables the synchronous oneway call path of the actor system, as discussed next in [Sending oneway distributed actor calls](#send-oneway-distributed-method-calls).

The `@oneway` attribute performs declaration site-checking for the method being compatible with the `send` call rules that we discussed above, and you can make sure that the declaration is able to be called using send if you annotate it with `@oneway`:

```swift
class Bad {
  @oneway func test() {} // error: '@oneway' can only be applied to an actor isolated method
}

actor GreatActor {
  @oneway func test() {} // OK
  @oneway static func test() {} // error: '@oneway' can only be applied to an actor isolated method
}

protocol GreatProtocol: Actor {
  @oneway func test() // OK
}

distributed actor DistributedKnownActor {
  @oneway distributed func test() {} // OK
}

protocol GreatDistributedProtocol: DistributedActor {
  @oneway distributed func test() // OK
}

@MainActor
@oneway func test() {} // OK

class Example {
  @oneway func testIsolated(_: isolated GreatActor) {} // OK
}

@oneway @MainActor func tell() -> Reply { ... } // error: '@oneway' global function 'tell()' must return 'Void'
@oneway @MainActor @discardableResult func tell() -> Reply { ... } // error: '@oneway' global function 'tell()' must return 'Void'

@oneway @MainActor func tell() throws {} // error: '@oneway' global function 'tell()' must not be 'throws'
@oneway @MainActor func tell(test: () throws -> Void) rethrows {} // error: '@oneway' global function 'tell(test:)' must not be 'throws'
@oneway @MainActor func tell<E: Error>() throws(E) {} // error: '@oneway' global function 'tell()' must not be 'throws'
```

Calling a `@oneway` method with `await` results in a warning:

```swift
actor Collector {
  @oneway func collect(_ value: Int) { ... }
}

func test(collector: Collector) async {
  send collector.collect(1)  // OK
  await collector.collect(2) // warning: '@oneway' instance method 'collect' is not intended to be awaited on, use 'send' instead
}
```

A `@oneway` method can also be called with `send` from within its own isolation domain, such as `send self.collect(1)` from inside the actor. Such a call is not made in place: it is enqueued on the actor itself, and runs after the current job has completed, in order with other `send` calls to the same actor. This can be used to defer work, or to break up long running processing without suspending.

It is possible to promote this diagnostic to an error, by using the `AwaitedOnewayCall` warning group. A project which wants to enforce the use of `send` strictly can promote warnings about `send` misuse to errors using the existing warning control mechanisms:

- for the whole module:
  - with the `-Werror AwaitedOnewayCall` compiler flag ([SE-0443](0443-warning-control-flags.md)), 
  - or the `.treatWarning("AwaitedOnewayCall", as: .error)` SwiftPM setting ([SE-0480](0480-swiftpm-warning-control.md)),
- for all declarations in a file:
  - with a `default @diagnose(AwaitedOnewayCall, as: error)` declaration at the top of the file ([SE-0478](0478-default-isolation-typealias.md)),
- for a specific declaration:
  - with the `@diagnose(AwaitedOnewayCall, as: error)` attribute ([SE-0522](0522-source-warning-control.md)):

```swift
@diagnose(AwaitedOnewayCall, as: error)
func test(collector: Collector) async {
  await collector.collect(2) // error: '@oneway' instance method 'collect' is not intended to be awaited on, use 'send' instead
}
```

A common way to enforce these might be by using the `default @diagnose` syntax, as follows:

```swift
default @diagnose(AwaitedOnewayCall, as: error)

func test(collector: Collector) async {
  await collector.collect(1) // error: '@oneway' instance method 'collect' is not intended to be awaited on, use 'send' instead
}

@diagnose(AwaitedOnewayCall, as: ignored, reason: "waits for the collection on purpose")
func drain(collector: Collector) async {
  await collector.collect(2) // OK, the attribute on the declaration takes precedence
}
```

The warning can also be suppressed with `@diagnose(AwaitedOnewayCall, as: ignored)`, when code intentionally awaits a `@oneway` method. We believe this is the right tradeoff, as it supports documenting the decision taken to await such call explicitly.

The warning is not an error by default, so that adding `@oneway` to an existing method is not a source breaking change.

It is also possible to express that a method _should not_ be called using `send` by annotating it with `@oneway(never)`, which is a useful way to dissuade developers from unintentionally breaking structured concurrency for methods which truly rely on it (e.g. for cancellation, or task-local values):

```swift
actor Resource {
  /// Never try using this resource from outside the structured task hierarchy you created it in.
  @oneway(never)
  func use() {
    ...
  }
}

func test() async {
  await makeResource { resource in
    await resource.use() // OK

    send resource.use() // warning: '@oneway(never)' instance method 'use()' is not intended to be called with 'send', use 'await' instead
                        // fix-it: replace 'send' with 'await'
  }
}

func notify(resource: Resource) {
  send resource.use() // warning: '@oneway(never)' instance method 'use()' is not intended to be called with 'send', use 'await' instead
}
```

This warning belongs to its own diagnostic group, `SentOnewayNeverCall`, which can be promoted to an error or suppressed the same way as the `AwaitedOnewayCall` group.

`@oneway` is not accepted on properties, computed properties, subscripts, or static functions, because they cannot be used with `send`.

#### `@oneway` is a declaration attribute

`@oneway` and `@oneway(never)` are declaration attributes. They are not part of a function's type and do not affect its mangled name, the same way as `@discardableResult` does not. A reference to a `@oneway` method is an ordinary function value, and neither attribute can be written on a function type:

```swift
@MainActor
final class Notifier {
  @oneway func notify(_ value: Int) { ... }
}

@MainActor
func test(notifier: Notifier) {
  let notify = notifier.notify            // '(Int) -> Void'
  notify(1)                               // OK, an ordinary call

  let callback: @oneway @MainActor (Int) -> Void = { _ in } // error: attribute can only be applied to declarations, not types
}
```

The diagnostics about `await` of a `@oneway` method and about `send` of a `@oneway(never)` method only apply to calls which name the method directly. A function value can be called with `send` if its function type is isolated to an actor, like any other call, see [`send` compatible declarations](#send-compatible-declarations). Expressing the intent of `@oneway` in function types is left as a [future direction](#oneway-function-types).

#### Overloading oneway methods

Since `@oneway` is not part of the function type, two methods which only differ in `@oneway` redeclare each other:

```swift
actor WorkQueue {
  func flush() { ... }
  @oneway func flush() { ... } // error: invalid redeclaration of 'flush()'
}
```

A `@oneway` method can be overloaded with methods which differ in other ways, such as `async`, their result type or their parameters. When more than one overload can be called, a `send` call prefers the `@oneway` overload, and any other call prefers an overload which is not `@oneway`. A `send` call only considers candidates which can be `send`-called, that is, methods which do not throw and return `Void`:

```swift
actor WorkQueue {
  func stop() async -> Summary {
    // "graceful" stop which returns when the stopping has completed
    // ...
  }

  @oneway 
  func stop() {
    // initiates stopping, but the caller will not wait for the stopping to finish
  }
}

func testAwait(queue: WorkQueue) async {
  let summary = await queue.stop() // calls the Summary-returning overload, waits for the result
}

func testNoWait(queue: WorkQueue) async {
  send queue.stop()                // calls the '@oneway' overload
}
```

This is also used to prefer calling the `@oneway` overload from a `send` context, even if for other reasons (such as defaulted parameters), normally one would have called a different non-oneway overload, like this:

```swift
actor Logger {
  @oneway func flush(timeout: Duration = .seconds(1)) { ... }
  func flush() { ... }

  func test() {
    send self.flush() // calls 'flush(timeout:)'
    self.flush()      // calls 'flush()'
  }
}
```

This allows a library to add a `@oneway` variant next to an existing method which keeps its behavior for `await` calls.

### Send oneway distributed method calls

Oneway fire-and-forget methods are commonplace in distributed systems, as the cost of a request/response roundtrip is drastically higher than in a local call between two concurrency domains. Remote calls involve serializing the request, making a networking call of some sort, deserializing the request on the remote side, executing the target distributed method, and finally encoding and delivering the response to the caller.

Many distributed protocols are built on low level fire-and-forget primitives that skip the response part of this entirely, and build reliable request/response or streaming protocols on top of these lower-level primitives, or make use of the fire-and-forget semantics to embrace the nature of message loss in networked distributed systems explicitly.

Without `@oneway` methods, distributed systems developers in Swift were not given an option, and had to work with request/response mechanisms, or invent sneaky ways to pretend a fire-and-forget message by inspecting target method identifiers.

Oneway methods solve this problem elegantly, by expressing the intent of the API to both developers, the distributed runtime, and most importantly, the `DistributedActorSystem` implementation handling the transport layer of such calls.

Distributed methods can be called with `send` only if they are declared `@oneway`. The usual `send` rules apply to them as well, i.e. such methods must not throw, and must return `Void`:

```swift
distributed actor Greeter {
  typealias ActorSystem = ExampleActorSystem // conforms to DistributedOnewayActorSystem

  @oneway
  distributed func greet(name: String) {
    print("Hello, \(name)!")
  }

  distributed func wave() { 
    print("*Greeter waves*")
  }
}

func test(greeter: Greeter) async throws {
  try send greeter.greet(name: "Caplin") // OK

  try send greeter.wave()
  // error: 'send' of distributed instance method 'wave()' requires it to be '@oneway'
  // fixit: send -> try await
  // fixit: add '@oneway' to 'wave()'

  try await greeter.wave()           // OK, regular request-reply call
}
```

Unlike for local actors, where `@oneway` only expresses the API author's intent, for distributed methods `@oneway` is required in order to use `send`. 

This is because a `send` of a distributed method must forward a remote invocation to the underlying actor system's new synchronous `remoteCallOneway` method, which is what can be used to guarantee that the order of consecutive `send` calls is preserved for remote actors as well. 

Since the actor system does not enforce a specific actor isolation, executing multiple `send` jobs on it would result in executing them potentially concurrently, and could lead to unexpected enqueue order violations which we intend to preserve when using `@oneway` calls.

When the compiler encounters an `@oneway distributed` method, it emits an additional, synchronous (!), distributed thunk that handles `send` calls directly, without creating a light-weight task at the call site. This allows distributed functions to exhibit the exact same behavior when the target instance is local, and efficiently call into the distributed actor system if the target is remote. The emitted distributed thunk handles calls as follows:

- When the target is a **local** distributed actor:
  - the thunk performs a `send` call on the underlying local actor method.
- When the target is a **remote** distributed actor:
  - the thunk encodes the arguments, and synchronously calls the new `remoteCallOneway` method of the actor system, which hands off the message without waiting for any reply.

```swift
// Pseudo code of the oneway thunk logic generated for a `@oneway distributed func greet(name:)`
extension Greeter {
  nonisolated func <oneway thunk for greet>(
    name: sending String
  ) throws /* [distributed_thunk] */ {
    guard __isRemoteActor(self) else {
      send self.greet(name: name) // same semantics as normal local-actor 'send' call
      return
    }

    var invocation = actorSystem.makeInvocationEncoder()
    try invocation.recordArgument(RemoteCallArgument(label: "name", name: "name", value: name))
    try invocation.doneRecording()
    var target = RemoteCallTarget(<identifier of '@oneway' greet(name:)>)
    target.isOnewayRemoteCall = true // this call was made with 'send', and expects no reply
    target.isOnewayTarget = true     // the target method is declared '@oneway'

    try actorSystem.remoteCallOneway(
      on: self, target: target, invocation: &invocation)
  }
}

// Pseudo code of the normal thunk generated for a `distributed func greet(name:)`
extension Greeter {
  nonisolated(nonsending) func <thunk for greet>(
    name: sending String
  ) async throws /* [distributed_thunk] */ { /*...*/ }
}
```

A `@oneway` distributed method can still be called using `await`, which results in the usual warning about awaiting a `@oneway` method, and makes a regular request-reply call through `remoteCallVoid`. In such a call, `target.isOnewayRemoteCall` is `false`, because the caller expects a reply, while `target.isOnewayTarget` is `true`, because the target method is declared `@oneway`. 

The actor system can use this to decide whether it supports request-reply calls of `@oneway` methods. A system which does not support them can throw an error from `remoteCallVoid`, which the caller receives at its `try await`. Other systems can simply perform a request-reply call to the target, and return once the reply arrives.

If a system does allow handling `@oneway` methods with/response calls, it should also transfer to the recipient that a response is expected (even though it is `Void`) as the return may be used as a simple form of acknowledgment.

Since the whole send path of a remote oneway call is synchronous, an actor system may provide stronger ordering guarantees across the wire for consecutive `send` calls made by the same task on the same target actor. It is up to a specific transport to define how strong ordering guarantees to expect from such calls, so please refer to your system's documentation. Most systems should attempt to offer "as enqueued" order to be carried throughout to the call enqueue on the recipient though.

#### Implicit throws on oneway distributed method calls

While it may seem surprising at first, oneway calls on distributed methods retain the implicitly throwing behavior of their non-oneway counterparts.

The semantic meaning is quite clear: a distributed thunk may throw also on the local-side of the call, while serializing the arguments, or attempting to establish or use a connection. While remote oneway calls express the intent to not wait for the _remote_ side's reply, the local side of the call is still interesting, and it is beneficial to be able to expose e.g. a potential encoding problem to the caller.

> `DistributedOnewayActorSystem` implementations can decide for themselves if and how they make use of this throwing capability. Some systems may not be able to leverage this "throw early" capability, but in general it is a useful semantic capability we can offer to potentially remote oneway calls.

So, even though the target method of a remote oneway call itself cannot throw, the caller's side of a remote may still fail and therefore oneway remote calls must be marked with `try send` as follows:

```swift
distributed actor Greeter { 
  @oneway 
  distributed func greet(name: String) { ... } // does not throw
}

func test(greeter: Greeter) throws {
  try send greeter.greet(name: "Caplin") // OK, encoding and transport hand-off errors are thrown

  send greeter.greet(name: "Caplin") // error: call can throw but is not marked with 'try'
}

func testIsolated(greeter: isolated Greeter) throws {
  // greeter is known-to-be-local
  send greeter.greet(name: "Caplin") // OK, not a remote call, cannot throw
}
```

This does not contradict the rule that `send` cannot be applied to calls of methods that throw: the target method does not throw, and the errors thrown by a `try send` are only ever about the caller's side of the call. In other words, we are "trying to send" this call, which may still fail. Whether the call was actually delivered, and whether the method executed successfully on the recipient, is not reported and there is no way to ferry back this information back to the caller -- it is truly an fire-and-forget, though the "fire" may still fail.

#### Handle oneway remote calls in `DistributedOnewayActorSystem`

This proposal introduces a third way of making remote calls, the `remoteCallOneway` method, which complements the existing `remoteCall` and `remoteCallVoid` asynchronous methods. This is necessary to support `send` callsites from synchronous code; because otherwise calling the distributed method thunk might need to call the asyncornous `remoteCallVoid(...)` method with a `send`, however those functions are not actor isolated, and we would not necessarily be able to enforce strict invocation ordering, which is something we want to support for remote oneway calls.

The new `remoteCallOneway` requirement is similar to `remoteCallVoid`, with the only difference that it is a synchronous methods requirement. It is declared by a new protocol, `DistributedOnewayActorSystem`, which refines `DistributedActorSystem`, so an actor system opts into supporting oneway calls by conforming to it:

```swift
@available(SwiftStdlib 6.5, *)
public protocol DistributedOnewayActorSystem<SerializationRequirement>: DistributedActorSystem {
  /// Invoked when a `@oneway` distributed method is called using `send` on
  /// a remote distributed actor reference.
  ///
  /// The call is synchronous and must return as soon possible when the
  /// message was handed off to the underlying transport.
  /// Implementations must not wait for the remote side's reply in any way.
  /// If reasonable, the `remoteCallOneway` method is allowed to wait for
  /// the message to be enqueued on the underlying transport, however it should
  /// not take excessive time doing so, as the method will be executing on the calling
  /// task/thread, and therefore should avoid any IO work. 
  ///
  /// The `isOnewayRemoteCall` property of the `target` is guaranteed to be `true`
  /// when the `remoteCallOneway` method is invoked by the synthesized distributed
  /// thunk of a `send` call. The `isOnewayTarget` property is `true` if the
  /// target method is declared `@oneway`.
  ///
  /// If necessary, the implementation may itself use `send ...` to ship off any 
  /// asynchronous work to an unstructured task, without awaiting for its result.
  ///
  /// If the `remoteCallOneway` method itself needs to invoke any asynchronous code
  /// in order to perform the message send, it should itself `send` the
  /// remaining work off to an actor, or find another way to offload the
  /// heavier work off the calling thread.
  ///
  /// - Parameters:
  ///   - actor: the remote actor reference on which the call is made
  ///   - target: identifies the distributed method, `target.isOnewayRemoteCall` is `true`
  ///   - invocation: the encoded arguments of the call
  /// - Throws: if the message could not be handed off to the transport;
  ///   the error is thrown to the caller of the `try send` call
  func remoteCallOneway<Act>(
      on actor: Act,
      target: RemoteCallTarget,
      invocation: inout InvocationEncoder
  ) throws
      where Act: DistributedActor,
            Act.ID == ActorID
}
```

Unlike `remoteCall` and `remoteCallVoid` the method has no `throwing:` parameter, because only methods which do not throw can be `@oneway` methods. It still is `throws` because it may throw an encoding error, as discussed earlier.

> `DistributedActorSystem` currently does not support typed errors for the transport errors or distributed methods. Once this is supported, the thrown error here would be a "transport error" or "distributed actor system error", and not the error of the target function (since it cannot throw).

Since a `@oneway` distributed method must be able to use the synchronous call path, it is an error to declare one in an actor whose `ActorSystem` is not known to conform to `DistributedOnewayActorSystem`:

```swift
distributed actor BadWorker {
  typealias ActorSystem = NotOnewaySystem // does not conform to DistributedOnewayActorSystem

  @oneway distributed func stop()
  // error: '@oneway' distributed instance method 'stop()' requires
  // 'NotOnewaySystem' to conform to 'DistributedOnewayActorSystem'

  distributed func pause() // OK, but cannot be called with 'send'
}

distributed actor GoodWorker {
  typealias ActorSystem = OnewaySystem // conforms to DistributedOnewayActorSystem

  @oneway distributed func stop() // OK
}
```

The conformance may also be known through a generic constraint, a constrained extension, or a protocol constraint:

```swift
distributed actor GenericWorker<ActorSystem: DistributedOnewayActorSystem<any Codable>> {
  @oneway distributed func stop() // OK
}

distributed actor FlexibleWorker<ActorSystem: DistributedActorSystem<any Codable>> {
  distributed func pause() // OK, but cannot be called with 'send'
}

extension FlexibleWorker where ActorSystem: DistributedOnewayActorSystem<any Codable> {
  @oneway distributed func stop() // OK, only available with oneway capable actor systems
}

@Resolvable
public protocol MyService: DistributedActor
  where ActorSystem: DistributedOnewayActorSystem<any Codable> {
  @oneway distributed func stop() // OK
}
```

In addition to the new `remoteCallOneway` method, the existing `RemoteCallTarget` type gains two boolean markers:

- `isOnewayRemoteCall` which determines if the call was made using `send`,
- and `isOnewayTarget` if the target was declared `@oneway`. 

Since a `@oneway` distributed method may still be called using `await`, `isOnewayRemoteCall` is a property of each individual call rather than of the target method. `isOnewayTarget` determines if the target method is declared `@oneway`, regardless of how it was called. This allows a system to determine if "downgrading" a oneway call to a request/response is supported or not. Either way, the caller will be met with a warning about calling an `@oneway` method using `await`, so there is compile time indication of this potentially not being supported already.

```swift
public struct RemoteCallTarget {
  // ... existing members ...

  /// Whether the call was made using 'send', and therefore no reply is expected.
  public var isOnewayRemoteCall: Bool { get set }

  /// Whether the target method is declared '@oneway', regardless of whether
  /// the call was made using 'send' or 'await'.
  public var isOnewayTarget: Bool { get set }
}
```

The new properties are settable in order to make unit testing simpler, in case a system implementation would simply like to test their `remoteCall` implementations directly, without going through the synthesized distributed call thunks.

Both flags describe how a particular call was made, and are not part of the identity of the target. They are ignored by the `Equatable` and `Hashable` conformances of `RemoteCallTarget`, which keep comparing only the identifier of the target: the targets of a `send` and an `await` of the same method are equal, and hash the same.

The `isOnewayRemoteCall` property is used to determine if for _a specific call_ a response is expected or not. And the `isOnewayTarget` property is used to inform the runtime if the target function was explicitly declared `@oneway`. The actor system may use this information to e.g. reject `send` calls to methods which were not explicitly opted into `@oneway` semantics if the underlying transport does not allow for handling such. It also can be used to determine if a `@oneway` method was called using `try await` in which case the `remoteCallVoid` method would be invoked with a remote call target which would have the `isOnewayTarget` flag set to `true`. This would already issue a warning at compile-time, however the actor system runtime may also decide to outright fail such call and have the caller be failed with an error immediately. We believe this flexibility is useful for highly specialized actor systems.

A simplified implementation of `remoteCallOneway` may look like this:

```swift
extension ExampleActorSystem {
  func remoteCallOneway<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) throws where Act: DistributedActor, Act.ID == ActorID {
    let envelope = try makeEnvelope(recipient: actor.id, target: target, invocation: invocation)

    send transport.send(envelope) // only a single send-job is created
                                  // as the remoteCallOneway was called into synchronously
  }
}
```

### `@oneway` protocol requirements

Protocol requirements can be declared `@oneway` in the same way as methods:

```swift
protocol Worker: Actor {
  @oneway
  func stop()
}
```

A `@oneway` requirement may be witnessed by a method which is not `@oneway`, since such a method can be called with `send` as well:

```swift
actor PlainWorker: Worker {
  func stop() { ... } // OK, can be called with 'send'
}

actor OnewayWorker: Worker {
  @oneway func stop() { ... } // OK
}
```

A requirement which is not `@oneway` cannot be witnessed by a `@oneway` method, since callers using the protocol may call the requirement using `await`, which the witness does not intend to support:

```swift
protocol Flusher: Actor {
  func flush()
}

actor BadFlusher: Flusher {
  @oneway func flush() { ... }
  // error: '@oneway' instance method 'flush()' cannot witness requirement 'flush()' which is not '@oneway'
}
```

Since `@oneway` can only be applied to isolated methods, only requirements of protocols which guarantee that their conforming types are isolated can be declared `@oneway`. Those are protocols refining `Actor` or `DistributedActor`, and global actor isolated protocols:

```swift
protocol LocalWorker: Actor {
  @oneway func stop() // OK
}

@MainActor
protocol MainWorker {
  @oneway func stop() // OK, conforming types are isolated to the main actor
}

protocol DistributedWorker: DistributedActor where ActorSystem: DistributedOnewayActorSystem<any Codable> {
  @oneway func stop() // OK
}

protocol AnyWorker {
  @oneway func stop() // error: '@oneway' can only be applied to an actor isolated method
  
  @oneway func stop() where Self: Actor // OK
}
```

A requirement of a protocol which is neither constrained to `Actor` or `DistributedActor`, nor isolated to a global actor, is not actor isolated, and therefore cannot be `@oneway`, just like a nonisolated method. 

Calls through generic parameters and existentials of such protocols may use `send` the same way as calls on a concrete actor:

```swift
func stopAll(_ workers: [any Worker]) {
  for worker in workers {
    send worker.stop()
  }
}

func stop(_ worker: some Worker) {
  send worker.stop()
}
```

### `@oneway` protocol requirements and distributed actors

Distributed actors generally use `@Resolvable` protocols ([SE-0428: Resolve DistributedActor protocols](0428-resolve-distributed-actor-protocols.md)) to express their public API surface, and later implement these APIs in a server component using distributed methods. It is also possible for distributed methods to witness non-distributed protocol requirements, as long as those are asynchronous and throwing.

#### Witnessing `distributed func` protocol requirements

Requirements of a protocol which refines `DistributedActor` are declared as `distributed` methods, and calls to them go through a distributed thunk of the protocol, which handles the local/remote branching of the call the same way as the thunk of a concrete distributed actor. A distributed requirement does not need to be declared `throws` in order to be called remotely, as remote calls are implicitly throwing at the call site. The same as for concrete distributed actors, a distributed requirement can be called using `send` only if it is declared `@oneway`, in which case the protocol must guarantee that the actor system conforms to `DistributedOnewayActorSystem`. A `send` call of such a requirement uses the synchronous call path and invokes `remoteCallOneway` directly:

```swift
@Resolvable 
protocol Mailman: DistributedActor where ActorSystem: DistributedOnewayActorSystem<any Codable> {
  @oneway
  distributed func deliver(_ mail: Mail)

  distributed func inspect(_ mail: Mail)
}

distributed actor MailmanImpl: Mailman {
  distributed func deliver(_ mail: Mail) { ... }
  distributed func inspect(_ mail: Mail) { ... }
}

func test(mailman: any Mailman, other: some Mailman) async throws {
  try send mailman.deliver(Mail())  // OK, synchronous oneway call path
  try send other.deliver(Mail())    // OK
  try await mailman.deliver(Mail()) // warning: '@oneway' distributed instance method 'deliver' is not intended to be awaited on, use 'send' instead

  try send mailman.inspect(Mail())
  // error: 'send' of distributed instance method 'inspect' requires it to be '@oneway'
}
```

Since the call goes through the protocol's synchronous distributed thunk, it uses the oneway call path regardless of whether the call is made on a concrete type, a generic parameter, or an existential.

Declaring an `@oneway` requirement in a protocol which does not guarantee that its actor system conforms to `DistributedOnewayActorSystem` is an error:

```swift
protocol BadMailman: DistributedActor {
  @oneway
  distributed func deliver(_ mail: Mail)
  // error: '@oneway' distributed instance method 'deliver' requires the actor system
  // to conform to 'DistributedOnewayActorSystem'
}
```

Allowing this would result in compile time issues later on when this protocol would attempt to be witnessed by an actor whose actor system does not support the required `remoteCallOneway` function. However it is allowed to declare `@oneway` requirements in protocols which guarantee the actor system's type does conform to `DistributedOnewayActorSystem`, by e.g. expressing it using a where clause like:

```swift
protocol BadMailman: DistributedActor where ActorSystem: DistributedOnewayActorSystem<any Codable> {
  @oneway
  distributed func deliver(_ mail: Mail) // OK
}
```

The common way this is used in practice, is with a known actor system, that does implement the oneway actor system protocol, like so:

```swift
import Distributed

@Resolvable
protocol DistributedWorker: DistributedActor where ActorSystem == ExampleActorSystem {
  @oneway
  distributed func stop()
}

func test(system: ExampleActorSystem, id: ExampleActorSystem.ActorID) throws {
  let worker: some DistributedWorker = try $DistributedWorker.resolve(id: id, using: system)
  try send worker.stop() // OK, internally calls 'actorSystem.remoteCallOneway'
}
```

#### Witnessing non-`distributed` protocol requirements

A distributed actor may also conform to a protocol which does not refine `DistributedActor`. To witness any requirement methods, these requirements must be declared as `async throws`, due to the implicitly throwing nature of remote calls:

```swift
protocol Mailman {
  func deliver(_ mail: Mail) async throws
}

distributed actor MailmanImpl: Mailman {
  distributed func deliver(_ mail: Mail) { ... } // witnesses the requirement
}
```

However, due to the rule about `send` calls not being allowed on throwing declarations in general, calling such method on `any Mailman` would fail:

```swift
func test(mailman: any Mailman) {
  send mailman.deliver(Mail()) // error: 'send' cannot discard error thrown by call to 'deliver'
}
```

This is not specific to distributed actors, but follows from the rules discussed in [`send` compatible declarations](#send-compatible-declarations):

- The requirement is declared `throws`. Any type may conform to the protocol, so the requirement may be witnessed by a method which actually throws errors, which a `send` call would have silently discarded.
- The protocol does not guarantee that its conforming types are isolated to an actor, so there may be no actor on which the call could be enqueued.

To enable `send` calls through a protocol, the protocol should refine `DistributedActor` and declare its requirements as `@oneway distributed` methods, as shown above. We view this limitation as reasonable, as the combination of needing `@oneway` along with witnessing not-oneway requirements by a distributed actor seem quite rare. And the more common case, where the requirement is itself declared `@oneway`, is handled correctly:

```swift
protocol DistributedMailman: DistributedActor where ActorSystem: DistributedOnewayActorSystem<any Codable> {
  @oneway
  distributed func deliver(_ mail: Mail)
}

distributed actor MailmanImpl: DistributedMailman {
  typealias ActorSystem = OnewaySystem // conforms to DistributedOnewayActorSystem

  distributed func deliver(_ mail: Mail) { ... }
}

func test(mailman: any Mailman) throws {
  try send mailman.deliver(Mail()) // OK, uses the actor system's oneway call path
}
```

The `@oneway` requirement enforcement rule is sound for distributed actors, because any attempt to witness a oneway method with a distributed actor, without expressing the `@oneway` intent on the witness itself, is rejected:

- a `@oneway distributed func` requirement can only be witnessed by a `@oneway distributed` method, because a call through the requirement uses the witness's synchronous thunk, and the witness's remote call target identifier, which must refer to a `@oneway` method on the recipient,
- a `@oneway func` requirement cannot be witnessed by a `distributed func`,
- a requirement of a protocol which does not refine `DistributedActor` cannot be used to `send` a call to a distributed method at all: the requirement must be `async throws` to be witnessed by a distributed method, and is not isolated to an actor, so a `send` of it is rejected, see above.

A oneway remote call is therefore only ever made to a target which its recipient declares `@oneway`.

### Lack of Local Backpressure

It is worth acknowledging that similar to just creating many tasks using `Task.init`, task is never backpressured in Swift. Even TaskGroups which could account for some "at most" active task number, do not currently exert any backpressure on creating tasks, and this is left to a higher level API or end-user to orchestrate. While we do very much value flow-control and back-pressure in our systems, we also acknowledge that sometimes a plain old fire-and-forget is the right tool for the job. 

This is especially true for remote send calls: it could be a totally valid strategy to either drop, or `throw` on send attempts when the underlying transport is overwhelmed. With the currently proposed design, a distributed actor system could implement either strategy, and e.g. throw an error if a caller is trying to `send` a call to a target which is exerting backpressure on the wire somehow.

We do not anticipate a form of such back-pressure for local `send` calls though; as they are effectively equivalent to task creation, albeit a bit more efficient, which also do not offer any way of backing off if an executor is "overloaded" - as determining what "overloaded" means can be a very difficult question in itself.

## Source compatibility

This proposal is entirely additive.

## ABI compatibility

This proposal is ABI additive, it adds:

- the `DistributedOnewayActorSystem` protocol, 
- the `isOnewayRemoteCall` and `isOnewayTarget` properties to the existing `RemoteCallTarget` type.

The `@oneway` and `@oneway(never)` attributes do not affect a method's type or mangled name. Adding either attribute to an existing method of a plain or global actor, removing it, or changing one into the other is therefore ABI neutral: clients compiled against either version of a resilient library keep working with the other one. It is source compatible as well, though clients may see new warnings, e.g. when they `await` a method which became `@oneway`.

For distributed methods, `@oneway` additionally causes a synchronous distributed thunk to be emitted, which `try send` calls use. Adding `@oneway` to a distributed method is ABI additive, but removing it removes that thunk, which breaks clients compiled to `send` the method. The effect of `@oneway` on the remote call target identifier, and so on wire compatibility between peers which disagree about `@oneway`, is specified together with distributed `@oneway` methods, see [Distributed: Wire compatibility](#distributed-wire-compatibility).

Because the emitted distributed thunks call into the new `remoteCallOneway` method, `try send` can only be present in code as available as that method.

## Distributed: Wire compatibility

This proposal does not affect the wire protocol of remote calls by itself, however supporting `@oneway` may have different implications to various transports, so please refer to your actor system documentation for wire compatibility specifics.

`@oneway` does not change the mangled name of a method. Whether the remote call target identifier of a `@oneway` distributed method stays the same as the one it would have without `@oneway`, with `RemoteCallTarget.isOnewayRemoteCall` marking calls made with `send`, so that peers which disagree about `@oneway` can still call each other, is still to be settled together with the implementation of distributed `@oneway` methods.

## Future directions

### Oneway function types

This proposal makes `@oneway` a declaration attribute only. A future proposal could allow `@oneway` on function types, so that function values and closures, such as a callback isolated to a global actor, can carry the same intent. That would make `@oneway` part of the function type and of the mangled names of the declarations which use it, so adding or removing it would no longer be ABI neutral, and it would require rules for converting between `@oneway` and other function types. Forming such closures isolated to a specific actor instance would additionally require extending closure isolation control to actor instances.

### More semantic attributes for remote distributed calls (e.g. `@idempotent`)

Another potential semantic that would be useful to express in the future might be the concept of idempotent calls. The same as as `GET` operations are generally considered idempotent in well-designed RESTful APIs, or other RPC systems identify idempotent calls in other ways, allowing them to retry operations of e.g. the connection breaks while obtaining the response etc.

In general an actor system cannot safely automatically retry operations because it is not clear if a call was delivered and may have caused a side-effect, which must not by accidentally caused twice. Idempotent methods would indicate to the actor system that a call may be invoked multiple times and will not cause unexpected or duplicated side-effects. 

### Allow detaching the implicit unstructured task with `@oneway(detached)`

In the majority of situations, carrying the base priority of the task an unstructured task is created from, copying the related task-locals as well as carrying vouchers which may be important for the correct operation of the `send` called function, is the right thing to do.

However, in some rare situations it might be the case that carrying forward these properties of the creating task are unwelcome, and could cause complications. For the same reason as Swift offers `Task.init` and `Task.detached` it might become necessary to offer a way of using `send` and `@oneway` functions with a "like detached" task mechanism. We are unsure of the necessity of this mechanism so it is not yet proposed in this initial revision, however it would be simple to introduce by modifying the `@oneway` attribute and detaching the context when necessary.

## Alternatives considered

### Do nothing

One could argue to "do nothing" and keep the status quo where developers must reach for manually invoking `Task.init`, `Task.immediate` or building ad-hoc queing mechanisms using `AsyncStream`... We strongly believe a dedicated, well-understood operation for a fundamental actor operation such as this is warranted. 

Oneway calls can be more efficient, are explicit and intentional in code, and can be employed by developers intentionally. Rather than hiding the same semantics in partial or half-correct attempts to emulate this behavior using nonisolated methods starting unstructured tasks. So we strongly believe this is a net positive addition to the understandability and clarity of the language.

It also prevents the anti-pattern of APIs pretending to be synchronous, but aren't:

```swift
actor Logger {
  private var lines: [String] = []

  private func appendLine(_ line: String) {
    lines.append(line)
  }

  // Looks synchronous to callers, but actually spawns an unstructured task;
  // BUG: the order of logged lines is not guaranteed
  // ISSUE: the use of unstructured concurrency is entirely invisible
  nonisolated func log(_ line: String) {
    Task { await self.appendLine(line) }
  }
}

func handle(request: Request, logger: Logger) {
  logger.log("Received \(request.id)") // no indication anything asynchronous is happening
  logger.log("Handled \(request.id)") // may be appended before the line above
}
```

Instead, with `send`, the boilerplate method and task are not necessary, and the call-site makes it clear that the call is enqueued on the actor:

```swift
actor Logger {
  private var lines: [String] = []

  @oneway
  func log(_ line: String) {
    lines.append(line)
  }
}

func handle(request: Request, logger: Logger) {
  send logger.log("Received \(request.id)")
  send logger.log("Handled \(request.id)") // guaranteed to be appended after the line above
}
```

### Alternative spellings for `@oneway`

We explored various ways to express the "should (not) be called as oneway", including spellings that leaned into how the call site may use the `send` or `await` keywords, expressed as `@callable(send)` and `@callable(await)`. While these spellings are very precise in their meaning, and don't introduce a new "oneway" word, they are somewhat clunky and could be hard to understand:

```swift
actor Worker {
  @callable(send) func sendMe() { ... }
  @callable(await) func awaitMe() { ... }
}

func test(worker: Worker) async {
  send worker.sendMe() // ok
  await worker.sendMe() // warning: call to '@callable(send)' instance method 'sendMe()' should use 'send' instead of 'await'

  send worker.awaitMe() // warning: call to '@callable(await)' instance method 'awaitMe()' should use 'await' instead of 'send'
  await worker.awaitMe() // ok
}
```

We also considered an `oneway` effect modifier similar to `async` however it may suggest to readers that this introduces a "function color" similar to `async` which isn't the case:

```swift
actor Worker {
  func tell() oneway { ... } // hypothetical 'oneway' effect spelling
  func work() { ... }
}

// An 'async' function forces its callers to be 'async' as well,
// a 'oneway' effect spelled in the same position suggests a similar restriction:
func caller(worker: Worker) oneway { // ?
  send worker.tell()
}

// It also suggests the effect is part of the function type, like 'async' is:
let fn: () oneway -> Void = worker.tell // ?
```

Neither is the case: `send` can be used from synchronous and asynchronous contexts alike, any eligible actor method can be called with `send` regardless of being annotated or not, and a `@oneway` method can still be awaited. `@oneway` is not part of the function type either, see [`@oneway` is a declaration attribute](#oneway-is-a-declaration-attribute). An attribute expresses the "this is how the method is intended to be called" nature of the annotation better than an effect would.


We decided against this spelling. `@callable(await)` is expected to be needed very rarely, and can be added in the future if it turns out to be necessary (see [Await-only methods](#await-only-methods)). Without it, the symmetry argument for the `@callable(...)` spelling disappears. Furthermore, for distributed methods the attribute does not only express intent, but also enables the synchronous `remoteCallOneway` call path, and `@oneway` more clearly describes this property of the method, matching the established "oneway" terminology used by many RPC systems (see [Prior art](#prior-art)).

### Allow any method to be `send`-called

We could allow any method, including value returning or throwing ones, to be called with `send` and therefore "not awaited" on. 

We feel this would encourage over-use of the oneway capability, and we still believe encouraging awaiting and structured concurrency is an overall goal of Swift Concurrency and therefore we want to allow this new way of calling asynchronous methods only in specific scenarios.

### Allow `send` calls to `@discardableResult` functions

We considered allowing `send` to call functions which return a value, as long as they are annotated with `@discardableResult`, however ultimately discarded this idea as it may lead to complex interactions, for little payoff. 

```swift
actor Worker {
  @discardableResult
  func confirm() -> Bool { ... }
}

func test(worker: Worker) {
  send worker.confirm() // alternative: OK, the result is discarded
}
```

`@discardableResult` only states that a caller which awaits the call may ignore the result; it does not say the function was designed to be called without anybody waiting for it. A value returning function is rarely a good fit for fire-and-forget calls, and allowing it would encourage over-use of `send`.

Requiring an explicit `-> Void` keeps the rule simple and makes the intent of a `send`-able API visible in its signature. An author who wants to offer both flavors can declare two methods, or an awaiting caller can keep using `await` and discard the result.

If we find that this combination would be very useful in practice in the future, it would be possible to add this without source breakage, which is why we decided to take the convservative route for now, and only allow explicit `Void` returning methods.

### Allow `send` of any distributed method

We considered allowing `send` of any distributed method which does not throw and returns `Void`, regardless of whether it is declared `@oneway`. For such methods, a `send` would make a regular `remoteCall` or `remoteCallVoid` call from within an enqueued call, and mark the remote call target as oneway using `isOnewayRemoteCall`, leaving it up to the actor system to not wait for a reply and return eagerly.

We decided against this, because such calls could not provide the guarantees which `send` provides for local actors, and for `@oneway` distributed methods:

- The order of consecutive `send` calls would not be preserved for remote actors: there is no local executor on which the enqueued calls could be ordered, so each of them would be scheduled independently, and the actor system's `remoteCall` methods could be invoked in any order.
- Whether the call actually results in a oneway message would depend on the actor system honoring the `isOnewayRemoteCall` marker; otherwise a full request-reply roundtrip would happen within the enqueued call, without the caller being aware of it.
- Errors on the caller's side of the call, such as failing to encode the arguments, could never be observed by the caller, since they would happen within the enqueued call, while the synchronous oneway call path throws them directly to the caller of `try send`.

Requiring `@oneway` makes every `send` of a distributed method use the actor system's oneway call path, with the same ordering guarantees as for local actors.

### Make oneway calls without a call-site keyword

In theory, we could allow calling methods with plain call syntax, e.g. `actor.complete()`, without any marker at the call-site. This would make calls which enqueue work on another actor indistinguishable from synchronous calls which would be very problematic for reading and analyzing performance and semantics of such code..

Requiring `send` at every call-site keeps the "something is happening asynchronously here" information visible in source code, the same way `await` marks potential suspension points.

### Make `@oneway` call-site violations errors by default

Calling a `@oneway` method with `await` results in a warning rather than an error. Such a call is well defined: the method does not throw and returns `Void`, so nothing is lost by awaiting it, and the attribute only expresses the API author's intent. Making this an error would mean that adding `@oneway` to an existing method is a source breaking change. Projects which want to enforce this strictly can promote the `AwaitedOnewayCall` diagnostic group to an error, see [The `@oneway` attribute](#the-oneway-attribute).

### Allow `send` calls of throwing methods

Throwing is a form of returning a value to the caller, which the caller may want to inspect. Since a `send` call is never awaited, there is nobody to receive the thrown error. Allowing throwing methods to be called with `send` would mean that errors are silently dropped, which is a significant footgun.

If a method intended to be called with `send` needs to signal a failure, it should do so explicitly, e.g. by sending another message back to the caller.

`send` calls of distributed methods are implicitly throwing, the same as `await` calls of distributed methods, and must be written as `try send`. The sending side of the operation may fail to encode the message, or fail to hand it off to the transport, and such errors are thrown to the caller. It is not possible to carry back an error from the recipient to the caller, which is consistent with the rationale for banning throws to begin with.

### Alternative spellings of `send`, e.g. `nowait`, `tell`, `cast` ...

We explored various words we could use for the callsite, including words like `nowait` which sounds funny and is very explicit about what it does, however we found that leaning into existing terminology around `send` feels quite natural, and expresses the right `sending` semantics as arguments are sent to the target context.

While `send` may be confused with the `sending` parameter modifier and the `Sendable` protocol, these are actually closely related concepts: the arguments of a `send` call are themselves sent to the target actor's isolation domain, and are checked accordingly. Similar as like the sending inference works for the operation closure of a Task.

Some examples of explored alternative spellings:

- `nowait actor.tell()` - is quite explicit, and similar to await, but perhaps too cute. If we are okay inventing a "nowait" word, this might be the best option, as it explicitly conveys what this kind of call is doing. And we know that "not waiting" is what we cause here, including breaking out of structured concurrency guarantees. It's somewhat unpleasant spelling perhaps could be thought of as a benefit here, we indeed don't want these `nowait` calls to be used as much as await ones...
- `tell actor.hello()` - is quite cute, and leans into the actor terminology that "actor tells another actor something" as well as some Akka heritage where this word was used, however doesn't really explain to non-experts what is going on, and could be too cute and doesn't discourage using this mechanism.
- `cast actor.hello()` - would be leaning into the Erlang terminology, where gen servers use the term "cast" for oneway messages, as compared to "call" which do wait for the call response. It doesn't really make much sense in plain english though, so we feel it's a bad choice for Swift which favors code readability and understanding.
- `fire actor.hello()` - would be a short form of "fire-and-forget" which would be too long of a keyword... Doesn't really convey what we're doing here.
- `post`, `enqueue` and `notify` are words which may come to mind, but don't really convey the right meaning. Enqueue potentially being the closest to intended semantics however it would be weird to speak in terms of job enqueueing in this high level operation keyword, as it seems to be mixing concerns of implementation details into the high level semantic keyword.

### Respect Objective-C `oneway` when importing

Objective-C has a `oneway` method qualifier, e.g. `- (oneway void)ping:(NSInteger)value;`, and the Clang importer could import such methods as `@oneway`. Today the obj-c `oneway` modifier is dropped during importing. Objective-C's oneway semantics are different than the ones introduced in this proposal, so we should not import objc-oneway as Swift `@oneway`.

Objective-C's `oneway` related specifically to Distributed Objects and allows the distributed objects, such as `NSDistantObject`, to forward the message without waiting for the remote side to reply. This is very similar to the `distributed actor` implementation of this proposal. However, a message sent to a "local" object is still a synchronous `objc_msgSend`: the method runs to completion on the caller's thread before the call returns. These semantics do not match what we are aiming to express for actors in `Swift`, i.e. "enqueue but don't wait" rather than Objective-C's run synchronously to completion anyway. We could not implement the Objective-C semantics in Swift without blocking calling threads, which is not an option for performance and thread starvation risk reasons.

An Objective-C API which wants Swift callers to treat a method as `@oneway` should state that explicitly, for example with an attribute that the importer understands, rather than through a qualifier that means something else.

### Task executor preference and `send`

Since the task/job created by `send` is effectively an unstrucutred task similar to those created by `Task.init`, it does not respect task executor preference (defined in [SE-0417: Task Executor Preference](0417-task-executor-preference.md)) of the calling task. This makes `send` introduced unstructured concurrency, and should not be used when we have contextual requirements for the downstream calls.

Making the `send` respect task executor preference, but not be structured concurrency would confuse developers and blur the lines between what is structured concurrency and what isn't. And at the end of the day, we still very much want to encourage using structured concurrency wherever possible.

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

**Erlang/Elixir/OTP (1986):** Erlang's raw actor primitive, `!` (read as "send"), is unidirectional and does not wait for any response from the recipient. The popular way to build RPC actors, `gen_server` however does expose a request/response pattern which is known as "`call`": `gen_server:call/2`, as opposed to "`cast`" which is oneway/unidirectional. 

Using the terms the term "send" expresses the right meaning, but using "cast" in order to differentiate from `sending` and `Sendable` would not really fit Swift very well as it is a rather uncommon word.

**Distributed Objects (1992):** Objective-C Distributed Objects, `NSDistantObject`, dating back to NeXTSTEP, implemented synchronous blocking remote calls, and were sometimes criticized for being too implicit in their remote call handling. Calls would look like normal local methods yet perform remote blocking calls by default. Distributed Actors differ here significantly because both effects (`throws` and `async`) are modeled by the language, and it is simple to notice where remote calls might be happening.

Objective-C offers a literal `oneway` method-declaration keyword: `- (oneway void)update:(id)data;`. A message to a `oneway` method which goes through a Distributed Objects proxy returns without waiting for the remote side, which matches the proposed semantics of `oneway`. A message to an ordinary object is still delivered synchronously, see [Respecting Objective-C `oneway` when importing](#respect-objective-c-oneway-when-importing).

**Windows COM / DCOM (1993):** Microsoft COM/DCOM are described in an IDL called MIDL (Microsoft Interface Definition Language). MIDL defines an [`[maybe]` attribute](https://learn.microsoft.com/en-us/windows/win32/midl/maybe), which marks fire-and-forget operations: the client does not wait for the call to complete, so such operations must return `void` and cannot have `[out]` parameters. MIDL also defines an [[idempotent]` attribute](https://learn.microsoft.com/en-us/windows/win32/midl/idempotent), which is a future direction for remote call semantics mentioned above.

**CORBA (1991):** CORBA's IDL has a literal `oneway` keyword predating this proposal by decades. An operation declared as `oneway void notify(in Data d);` must return `void`, may not declare any raised exceptions, and may not have `out` or `inout` parameters. The ORB is explicitly permitted, though not required, to deliver oneway calls best-effort rather than guaranteed, and to return control to the caller without waiting for the call to reach the server at all. These restrictions map almost exactly onto the void-only restriction this proposal places on `oneway`, and the term "oneway" used here likely traces back to this CORBA IDL usage, or to Distributed Objects, which is where it appears on Apple platforms.

Interestingly, **gRPC (2015)** does not offer any unidirectional calls, as in practice every call may end with a trailing response. However oneway messages are implemented as passing a stream of messages in an initial RPC which is later on consumed by the recipient. This pattern is also already possible in Swift.

Summing up, we see that the majority of RPC frameworks and systems use the term `oneway` and it explains the semantics we're exposing quite well.

## Revisions

- 1.0: Initial revision, `@remoteCall(oneway)` and `blocking` distributed methods
- 2.0:
  - Remove `blocking` from this proposal, it may be revisited separately
  - Generalize oneway calls from distributed actors to all actors
  - Introduce the `send` call keyword: any isolated method which does not throw and returns `Void` can be called with `send`, and its arguments are evaluated at the call site. `@discardableResult` functions which return a value are not supported, the callee must explicitly return `Void`
  - Replace `@remoteCall(oneway)` with the `@oneway` declaration attribute, and add `@oneway(never)`. Neither is part of the function type or the mangling, so adding or removing them is ABI neutral for actors, and methods which only differ in `@oneway` are redeclarations
  - Awaiting a `@oneway` method across isolation, or sending a `@oneway(never)` method, is a warning in the `AwaitedOnewayCall` or `SentOnewayNeverCall` diagnostic group
  - `send` of a distributed method requires it to be `@oneway`, and is written `try send`
  - `@oneway` distributed methods get a synchronous thunk which calls the new `remoteCallOneway` requirement of `DistributedOnewayActorSystem`, which the actor system must conform to
  - Add `RemoteCallTarget.isOnewayRemoteCall` and `RemoteCallTarget.isOnewayTarget``
