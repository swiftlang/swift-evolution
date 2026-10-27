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

While preparing this proposal, we explored numerous codebases and found that nearly 70% of `Task.init` uses were targeting non-throwing, Void-returning, fire-and-forget style methods, such as "complete", "finish" or similar ones to "notify" an actor some action has been triggered or completed. Those use-sites also did not retain the task object, so it could not be subject to priority escalation. We also found that very few call-sites opted for the explicit task discard to codify this intent (`_ = Task { ... }`), and the intent was left implicit.

Crucially, in inter-process calls, offered by `distributed func` enabled by the Distributed module, the lack of first class "send, don't wait" is even more problematic. Without explicit information about wether or not a call is truly uni-directional (sometimes called "oneway") runtimes can't know if they can use more optimized fire-and-forget messaging primitives, and force the callers to wait on a response even if the response is semantically meaningless. 

This makes it impossible to implement some network protocols effectively as implementations are forced into request-reply where they truly do need the ability to fire-and-forget messages across the network. The cost of a request-reply roundtrip is astronomically higher in a distributed system than it is within a process with just asynchronous methods, so this is a large performance problem for some systems. 

For example, it would be incredibly inefficient to implement a sequence like concept using methods which are forced into request/reply round trips:

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

Any actor isolated method which does not throw, and either returns `Void` or is `@discardableResult`, may be called with `send` instead of `await`. Semantically, this is similar to creating an ad-hoc task's operation will call and await the target method.

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

Unlike creating a `Task { await collector.onNext(value) }` for each call, consecutive `send` calls made from the same task to the same actor are enqueued, and therefore executed, in order. Oneway calls of synchronous methods can also be executed without allocating a asynchronous task stack.

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

We introduce a new `send` keyword which may be used in place of `await` when making calls to isolated methods. Sending a method call enqueues it on the target's isolation domain, and returns immediately without waiting for the call to return.

One of the keywords, `await` or `send` must be used when invoking a method cross-isolation, as the caller either must potentially suspend and wait for the method to execute, or additional resources must be created to invoke the target method asynchronously. Omitting the `send` keyword is not permitted because it would lead to accidental and hidden introduction of concurrency and resource utilization.

The `send` keyword's effect is similar to manually creating a task on the right isolation and ignoring its result; however it is vastly more efficient when the target method is a synchronous function, as the created task may omit creating the asynchronous context otherwise necessary for such task. 

Using `send` rather than the pattern of wrapping calls in  `Task { await actuallyAsync() }` and hiding this behind a "synchronous looking" API is vastly clearer in source as it spells out the actual intent of the code, rather than hiding it in helper functions. For example, we often see code like this, that attempts to hide the Task creation in a synchronous function, in order to make it easier to call from a synchronous context:

```swift
actor Worker { 
  func actuallyAsynchronous(_ string: String) async {
    print("got: \(string)")
  }

  nonisolated func looksEntirelySynchronousButIsnt(_ string: String) {
    Task {
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

> Note: Custom actor executors might reorder task execution, however this is not a concern for "default actors" which have the default executor implementation; and the majority of typical `SerialExecutor` implementation.

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

The optional chain is evaluated at the call site, and if any of the chain is `nil`, the rest of the chain and the arguments are not evaluated, and no call is enqueued.

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

Swift also offers the `@discardableResult` attribute which is used to indicate the return value of a function may not be interesting to callers. Functions annotated with `@discardableResult` are allowed to be called with `send` in which case the result is discarded:

```swift
actor Worker {
  @discardableResult
  func confirm() -> Bool { ... }
}

func test(worker: Worker) {
  send worker.confirm()           // OK, the returned 'Bool' is discarded
  let ok = send worker.confirm()  // error: 'send' call does not produce a value
                                  // fixit: 'send'->'await' to await the return value of 'confirm'
}
```

Even if a throwing function was annotated with `@discardableResult`  it still cannot be called using `send`, since discarding an error is not the same as discarding a result the API author has declared as not important.

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

Only isolated methods can used with `send`, and the call is immediately enqueued onto the target actor from the calling context. Neither  `nonisolated`, `nonisolated(nonsending)` or `@concurrent` functions, cannot be called using `send`.

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
- and return `-> Void`, or are annotated with `@discardableResult`,
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

Declarations that have `inout` arguments are not allowed to be used with `send`, as the target function may be still executing long after the surrounding caller context has completed:

```swift
actor Worker {
  func update(_ value: inout Int) { ... }
}

func test(worker: Worker) {
  var value = 0
  send worker.update(&value) // error: 'send' cannot be applied to a call with 'inout' arguments
}
```

Since `send` calls are executed exactly once, they may consume non-copyable arguments the same way a `@callable(once)` closure can.

A `send` call always consumes its noncopyable arguments, regardless of whether the parameter is `consuming` or `borrowing`, because the value must outlive the caller's scope.

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

### `send` is not Structured Concurrency

It is worth calling out explicitly that any use of `send` is explicitly breaking the Structured Concurrency contract: that callers wait until the code they call completes before continuing execution.

We believe having an explicit, well understood, optimized, and intentional way of breaking out of structured concurrency for the purpose of notifying an actor using specific, well-ordered calls, is an improvement over the status quo, where developers faced with a problem where they _must_ break out of structured concurrency, every time have to build ad-hoc solutions to the issue. Some developers reach to `Task.init` without realizing the loss of ordering guarantees they might be betting on. Other solutions might reach to manual management of queues with `AsyncStream` and yielding into it from synchronous contexts, which quickly becomes very verbose.

The explicit `send` keyword also makes it simple for linters to prevent its use. It would be difficult to ban use of task creation outright, but it is simpler to form policy around the use of `send` using linters or other tools, since it's purpose and behavior is very specific and well defined.

### The `@oneway` attribute

By default, every method declaration tht fulfils the requirements discussed above, can be called with `send` instead of `await`. The caller may decide to invoke the method one way or another, depending on their use-case. This is similar to today's situation where callers can any piece of code with `await target.wait()` or, create an unstructured task to make the same call: `Task { await target.wait() }`.

Previously, there was no way to for API authors communicate if calling a method without waiting for its result would be intended and supported behavior, or if it would be a very bad idea. From a source code perspective, we cannot easily tell apart an `await target.wait()` called "without waiting for it" because this depends where this call is made from, i.e. was it called from an ad-hoc created task that's purpose is to ignore the result or not?

By introducing a well defined spelling for these oneway calls, we can detect and offer guidance about the intended use of APIs. To express this, we introduce the optional `@oneway` attribute:

```swift
actor Test { 
  @oneway
  func callMe() { }
}
```

The `@oneway` attribute is optional, allows API authors to express their intent that such API is expected to be called without waiting for it complete, and does not expect to be part of a structurec concurrency call hierarchy. Typical examples for these are completion handlers. We still recommend developers make every attempt possible to keep methods within Swift's Structured Concurrency, however we do acknowledge that sometimes methods stepping out of it do exist, and it is beneficial to be able to express this in code.

It is not a requirement for methods to be annotated with `@oneway` in order to be called with `send`, because we anticipate existing methods which may want to be called this way and may not be annotated correctly. For example, imported Objective-C methods may not get annotated properly, but are a common target of such oneway calls.

For local actors, the attribute does not change how the method executes, and it does not introduce a new effect or "color": it does not propagate to callers in any way. It is part of the method's type, see [`@oneway` function types](#oneway-function-types), so that the intent is preserved when the method is referenced as a function value. It expresses the API author's intent, which the compiler checks at call sites. For distributed methods, `@oneway` is required in order to call them using `send`, and it enables the synchronous oneway call path of the actor system, as discussed next in [Sending oneway distributed actor calls](#send-oneway-distributed-method-calls).

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

@oneway @MainActor func tell() -> Reply { ... } // error: '@oneway' global function 'tell()' must return 'Void' or be '@discardableResult'
@oneway @MainActor @discardableResult func tell() -> Reply { ... } // OK

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

It is possible to promote this diagnostic to an error, by using the `AwaitedOnewayCall` warning group. A project which wants to enforce the use of `send` strictly can promote it to an error using the existing warning control mechanisms:

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

A `default @diagnose` declaration behaves as if the attribute was written on every top-level declaration in the file, including everything nested inside of them, but with a lower priority than an `@diagnose` attribute written on a declaration itself. It must be written at the top of the file, before any other declarations except `import`s. This allows a file to opt into the strict behavior, while a specific declaration in it can still opt out:

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

#### `@oneway` function types

The `@oneway` attribute is part of the function's type, similar to `@Sendable` or a global actor isolation. A reference to a `@oneway` method is a value of a `@oneway` function type, and `@oneway` can be written on function types, so that a function value, such as a closure, can express the same intent:

```swift
@MainActor
final class Notifier {
  @oneway func notify(_ value: Int) { ... }
}

func test(notifier: Notifier) async {
  let notify = notifier.notify   // '@MainActor @oneway (Int) -> Void'
  send notify(1)                 // OK

  let closure: @oneway @MainActor (Int) -> Void = { value in ... }
  send closure(2)                // OK
  await closure(3)               // warning: '@oneway' function is not intended to be awaited on, use 'send' instead
}
```

A reference to a method isolated to an actor instance, such as `self.collect` inside of an actor, does not carry that isolation in its function type: there is no way to spell "isolated to `self`" in a function type. Such a value therefore cannot be called using `send`, and the method should be called directly instead:

```swift
actor Collector {
  @oneway func collect(_ value: Int) { ... }

  func collectLater() {
    send self.collect(1)         // OK

    let collect = self.collect   // '@oneway (Int) -> Void'
    send collect(2)              // error: 'send' can only be applied to calls of actor isolated methods
  }
}
```

A function type with an `isolated` parameter can express the same intent, as the call is then enqueued on the actor passed as that argument, see below.

Calling a `@oneway` function type follows the same rules as calls of a `@oneway` method.

Just like a `@oneway` method, a `@oneway` function type must be isolated to an actor, so that a `send` of it has an actor to enqueue the call on. The function type must either be isolated to a global actor, or have an `isolated` parameter, in which case the call is enqueued on the actor passed as that argument. A `@oneway` function type without actor isolation is an error, as is a `send` of a function value whose type is not isolated to an actor:

```swift
let main: @oneway @MainActor (Int) -> Void = { _ in }          // OK
let worker: @oneway (isolated Worker, Int) -> Void = { _, _ in } // OK

func test(worker: Worker) {
  send main(1)                // OK, enqueued on the main actor
  send worker(worker, 2)      // OK, enqueued on 'worker'
}

let nonisolatedOneway: @oneway @Sendable (Int) -> Void = { _ in } // error: '@oneway' function type must be isolated to an actor
let plain: @Sendable (Int) -> Void = { _ in }
send plain(3)                 // error: 'send' can only be applied to calls of actor isolated methods
```

The same applies to `nonisolated(nonsending)`, `@concurrent` and `@isolated(any)` function types, which cannot be `@oneway` either. An `@isolated(any)` function may be dynamically nonisolated, so there is no actor a call could be guaranteed to be enqueued on.

Any function with the same isolation can be converted to a `@oneway` function type. A `@oneway` function cannot be converted to a function type which is not `@oneway`, because that would silently drop the API author's intent:

```swift
let plain: @MainActor (Int) -> Void = { _ in }
let oneway: @oneway @MainActor (Int) -> Void = plain  // OK
let back: @MainActor (Int) -> Void = oneway           // error: cannot convert '@oneway' function of type '@oneway @MainActor (Int) -> Void' to '@MainActor (Int) -> Void'
```

The same applies to `@oneway(never)`, which is also part of the function's type. A reference to a `@oneway(never)` method is a value of a `@oneway(never)` function type, and calling it with `send` from outside of its isolation produces the same `SentOnewayNeverCall` warning as a call of the method:

```swift
actor Resource {
  @oneway(never) func use(_ value: Int) { ... }
}

extension Resource {
  func useLater() {
    let use = self.use       // '@oneway(never) (Int) -> Void'
    use(1)                   // OK
    send use(2)              // OK, a send from within the actor's own isolation is not diagnosed
  }
}

func test(resource: Resource) async {
  let use: @oneway(never) @MainActor (Int) -> Void = { value in ... }
  await use(1)               // OK
  send use(2)                // warning: '@oneway(never)' function is not intended to be called with 'send', use 'await' instead
}
```

Converting a `@oneway(never)` function to a function type which is not `@oneway(never)` would silently drop the API author's intent just like dropping `@oneway`, and is an error. This includes converting it to a `@oneway` function type, which would turn the intent into its opposite. Any function which is neither `@oneway` nor `@oneway(never)` can be converted to a `@oneway(never)` function type:

```swift
let plain: @MainActor (Int) -> Void = { _ in }
let never: @oneway(never) @MainActor (Int) -> Void = plain   // OK
let back: @MainActor (Int) -> Void = never                   // error: cannot convert '@oneway(never)' function of type '@oneway(never) @MainActor (Int) -> Void' to '@MainActor (Int) -> Void'
let oneway: @oneway @MainActor (Int) -> Void = never         // error: cannot convert '@oneway(never)' function of type '@oneway(never) @MainActor (Int) -> Void' to '@oneway @MainActor (Int) -> Void'

let sendable: @oneway @MainActor (Int) -> Void = { _ in }
let awaited: @oneway(never) @MainActor (Int) -> Void = sendable // error: cannot convert '@oneway' function of type '@oneway @MainActor (Int) -> Void' to '@oneway(never) @MainActor (Int) -> Void'
```

A function type cannot be both `@oneway` and `@oneway(never)`, as they are mutually exclusive behaviors.

#### Overloading oneway methods

It is allowed to overload methods only on the presence of the `@oneway` attribute. The oneway attribute does impact the function type, and is mangled in its mangled type. When a method is overloaded only on the overload attribute, a `send` call prefers the `@oneway` overload, and an `await` call prefers the other one:

```swift
actor WorkQueue {
  func stop() async { ... }
  @oneway func stop() { ... }
}

func test(queue: WorkQueue) async {
  send queue.stop()  // calls the '@oneway' overload
  await queue.stop() // calls the other overload, no warning
}
```

This is done intentionally, in order to allow rolling out `send` support for existing functions which would have preferred to exhibit this semantic, without having to change behavior of already shipping awaitable versions. This primarily matters in distributed calls.

A `send` call only considers candidates which can `send`-called, that is, methods which do not throw and either return `Void` or are `@discardableResult`. If more than one candidate remains, overload resolution prefers the `@oneway` one over one just returning `Void`:

```swift
actor WorkQueue {
  func stop() async -> Summary {
    // "graceful" stop which returns when the stopping has completed
    // ...
  }

  @oneway func stop() {
    // initiates stopping, but the caller will not wait for the stopping to finish
  }
}

func testAwait(queue: WorkQueue) async {
  let summary = await queue.stop() // calls the Summary-returning overload, waits for the result
}

func testNoWait(queue: WorkQueue) async {
  send queue.stop()                // calls the Void-returning overload
}
```

### Send oneway distributed method calls

Oneway fire-and-forget methods are commonplace in distributed systems, as the cost of a request/response roundtrip is inherently much higher than in a local call between two concurrency domains. Remote calls involve serializing the request, making a networking call of some sort, deserializing the request on the remote side, executing the target distributed method, and finally encoding and delivering the response to the caller.

Many distributed protocols are built on low level fire-and-forget primitives that skip the response part of this entirely, and build reliable request/response or streaming protocols on top of these lower-level primitives, or make use of the fire-and-forget semantics to embrace the nature of message loss in networked distributed systems explicitly.

Without `@oneway` methods, distributed systems developers in Swift were not given an option, and had to work with request/response mechanisms, or invent sneaky ways to pretend a fire-and-forget message by inspecting target method identifiers.

Oneway methods solve this problem elegantly, by expressing the intent of the API to both developers, the distributed runtime, and most importantly, the `DistributedActorSystem` implementation handling the transport layer of such calls.

Distributed methods can be called with `send` only if they are declared `@oneway`. The usual `send` rules apply to them as well, i.e. such methods must not throw, and must either return `Void` or be `@discardableResult`:

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

This is because a `send` of a distributed method must forward a remote invocation to the underlying actor system's new synchronous `remoteCallOneway`, which is what can be used to guarantee that the order of consecutive `send` calls is preserved for remote actors as well. Since the actor system does not enforce a specific actor isolation, executing multiple `send` jobs on it would result in executing them potentially concurrently, and could lead to unexpected enqueue order violations which we intend to preserve when using `@oneway` calls.

When the compiler encounters an `@oneway distributed` method, it emits an additional, synchronous (!), distributed thunk that handles which a `send` calls directly, without creating a light-weight task at the call site. This allows distributed functions to exhibit the exact same behavior when the target instance is local, and efficiently call into the distributed actor system if the target is remote. The emitted distributed thunk handles calls as follows:

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

A `@oneway` distributed method can still be called using `await`, which results in the usual warning about awaiting a `@oneway` method, and makes a regular request-reply call through `remoteCallVoid`. In such a call, `target.isOnewayRemoteCall` is `false`, because the caller expects a reply, while `target.isOnewayTarget` is `true`, because the target method is declared `@oneway`. The actor system can use this to decide whether it supports request-reply calls of `@oneway` methods. A system which does not support them can throw an error from `remoteCallVoid`, which the caller receives at its `try await`. Other systems can simply perform a request-reply call to the target, and return once the reply arrives.

If a system does allow handling `@oneway` methods with/response calls, it should also transfer to the recipient that a response is expected (even though it is `Void`) as the return may be used as a simple form of acknowledgment.

Since the whole send path of a remote oneway call is synchronous, an actor system may provide stronger ordering guarantees across the wire for consecutive `send` calls made by the same task on the same target actor. It is up to a specific transport to define how strong ordering guarantees to expect from such calls, so please refer to your system's documentation. Most systems should attempt to offer "as enqueued" order to be carried throughout to the call enqueue on the recipient though.

#### Implicit throws on oneway distributed method calls

While it may seem surprising at first, oneway calls on distributed methods retain the implicitly throwing behavior of their non-oneway counterparts.

The semantic meaning is quite clear: a distributed thunk may throw also on the local-side of the call, while serializing the arguments, or attempting to establish or use a connection. While remote oneway calls express the intent to not wait for the _remote_ side's reply, the local side of the call is still interesting, and it is beneficial to be able to expose e.g. a potential encoding problem to the caller.

> `DistributedOnewayActorSystem` implementations can decide for themselves if and how they make use of this throwing capability. Some systems may not be able to leverage this "throw early" capabilitt, byt in general it is an useful semantic capability we can offer to potentially remote oneway calls.

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

This does not contradict the rule that `send` cannot be applied to calls of methods that throw: the target method does not throw, and the errors thrown by a `try send` are only ever about the caller's side of the call. In other words, we are "trying to send" this call, which may still fail. Whether the call was actually delivered, and whether the method executed successfully on the recipient, is not reported and there is no way to ferry back this information back to the caller.

#### Handle oneway remote calls in `DistributedOnewayActorSystem`

This proposal introduces a third way of making remote calls, the `remoteCallOneway` method, which complements the existing `remoteCall` and `remoteCallVoid` asynchronous methods. This is necessary to support `send` callsites from synchronous code; because otherwise calling the distributed method thunk might need to call the `actorSystem.remoteCall(...)` method with a `send`, however those functions are not actor isolated, and we would not necessarily be able to enforce strict invocation ordering, which is something we want to support for remote oneway calls.

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

Since a `@oneway` distributed method may still be called using `await`, `isOnewayRemoteCall` is a property of each individual call rather than of the target method. `isOnewayTarget` determines if the target method is declared `@oneway`, regardless of how it was called. This allows a system to determine if "downgrading" an oneway call to a request/response is supported or not. Either way, the caller will be met with a warning about calling an `@oneway` method using `await`, so there is compile time indication of this potentially not being supported already.

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

The `isOnewayRemoteCall` property is used to determine if for _a specific call_ a response is expected or not. And the `isOnewayTarget` property is used to inform the runtime if the target function was explicitly declared `@oneway`. The actor system may use this information to e.g. reject `send` calls to methods which were not explicitly opted into `@oneway` semantics if the underlying transport does not allow for handling such. It also can be used to determine if a `@oneway` method was called using `try await` in which case the `remoteCallVoid` method would be invoked with a remote call target which would have the `isOnewayTarget` flag set to `true`. This would already issue a warning at compile-time, however the actor system runtime may also decide to outright fail such call and have the caller be failed with an error immediately. We believe this flexibility is useful for specialized actor systems.

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
  send mailman.deliver(Mail())
  // error: 'send' cannot discard error thrown by call to 'deliver'
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

The `@oneway` requirement enforcement rule is sound for distributed actors, because any attempt to witness an oneway method with a distributed actor, without expressing the `@oneway` intent on the witness itself, is rejected:

- a `@oneway distributed func` requirement can only be witnessed by a `@oneway distributed` method, because a call through the requirement uses the witness's synchronous thunk, and the witness's remote call target identifier, which must refer to a `@oneway` method on the recipient,
- a `@oneway func` requirement cannot be witnessed by a `distributed func`,
- a requirement of a protocol which does not refine `DistributedActor` cannot be used to `send` a call to a distributed method at all: the requirement must be `async throws` to be witnessed by a distributed method, and is not isolated to an actor, so a `send` of it is rejected, see above.

A oneway remote call is therefore only ever made to a target which its recipient declares `@oneway`.

## Source compatibility

This proposal is entirely additive.

## ABI compatibility

This proposal is ABI additive, it adds:

- the `DistributedOnewayActorSystem` protocol, 
- the `isOnewayRemoteCall` and `isOnewayTarget` properties to the existing `RemoteCallTarget` type.

The `@oneway` and `@oneway(never)` attributes are part of a method's type, and therefore of its mangled name: a `@oneway` or `@oneway(never)` method is a distinct method from one which is not, even if their names and signatures are otherwise the same. Declaring a new `@oneway` or `@oneway(never)` method is ABI additive. However, adding either `@oneway` or `@oneway(never)` to an existing method, removing it, or changing one into the other, replaces the method's symbol with a different one, which is an ABI breaking change for resilient libraries, like other changes of a method's type. Clients compiled against the previous version of the library fail to find the method's symbol at runtime. The same applies to function types: changing a function type in a public API, such as the type of a parameter or of a property, by adding or removing `@oneway` or `@oneway(never)` changes the mangled names of the declarations which use it.

A library which wants to offer a `@oneway` variant of an existing method without breaking its clients can keep the existing method next to the new `@oneway` overload, see [Overloading oneway methods](#overloading-oneway-methods). A library which wants to discourage `send` calls of an existing method cannot add `@oneway(never)` to it in a binary compatible way, and can only document the intent until it is able to make an ABI breaking change.

For distributed methods, `@oneway` additionally causes a synchronous distributed thunk to be emitted, and the attribute is part of the method's remote call target identifier. A `@oneway` distributed method is therefore a distinct remote call target: a recipient which declares a method `@oneway` does not accept calls made by callers which were compiled against a version of the method which was not `@oneway`, and vice versa. The same applies to `@oneway(never)`, so adding or removing either attribute on a distributed method also breaks wire compatibility with peers compiled against the other version. To evolve a distributed protocol, a recipient can keep the existing method next to the new `@oneway` overload.

Because the emitted distributed thunks call into the new `remoteCallOneway` method, `try send` can only be present in code as available as that method.

## Distributed: Wire compatibility

This proposal does not affect the wire protocol of remote calls by itself, however supporting `@oneway` may have different implications to various transports, so please refer to your actor system documentation for wire compatibility specifics.

`@oneway` methods do gain a different specific mangling, so they are not callable from "old" clients, which will need to upgrade their Swift runtime version to call such methods. Changing a method from not-oneway to `@oneway` is wire identifier breaking.

## Future directions

### Oneway closures isolated to an actor instance

This proposal allows `@oneway` function types, including closures isolated to a global actor, e.g. `@oneway @MainActor (Int) -> Void`, see [`@oneway` function types](#oneway-function-types).

It may be useful to also allow forming oneway closures which are isolated to a specific actor instance, e.g. to pass a fire-and-forget callback which is enqueued on that actor. This would require extending closure isolation control to be applicable to instance actors.

### More semantic attributes for remote distributed calls (e.g. `idempotent`)

Another potential semantic that would be useful to express in the future might be the concept of idempotent calls. The same as as `GET` operations are generally considered idempotent in well-designed RESTful APIs, or other RPC systems identify idempotent calls in other ways, allowing them to retry operations of e.g. the connection breaks while obtaining the response etc.

In general an actor system cannot safely automatically retry operations because it is not clear if a call was delivered and may have caused a side-effect, which must not by accidentally caused twice. Idempotent methods would indicate to the actor system that a call may be invoked multiple times and will not cause unexpected or duplicated side-effects. 

### Allow detaching the implicit unstructured task with @oneway(detached)

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

Neither is the case: `send` can be used from synchronous and asynchronous contexts alike, any eligible actor method can be called with `send` regardless of being annotated or not, and a `@oneway` method can still be awaited. The `@oneway` function type does not compose like an effect either: any function can be converted to it, see [`@oneway` function types](#oneway-function-types). An attribute expresses the "this is how the method is intended to be called" nature of the annotation better than an effect would.


We decided against this spelling. `@callable(await)` is expected to be needed very rarely, and can be added in the future if it turns out to be necessary (see [Await-only methods](#await-only-methods)). Without it, the symmetry argument for the `@callable(...)` spelling disappears. Furthermore, for distributed methods the attribute does not only express intent, but also enables the synchronous `remoteCallOneway` call path, and `@oneway` more clearly describes this property of the method, matching the established "oneway" terminology used by many RPC systems (see [Prior art](#prior-art)).

### Allow any method to be `send`-called

We could allow any method, including value returning or throwing ones, to be called with `send` and therefore "not awaited" on. 

We feel this would encourage over-use of the oneway capability, and we still believe encouraging awaiting and structured concurrency is an overall goal of Swift Concurrency and therefore we want to allow this new way of calling asynchronous methods only in specific scenarios.

This proposal already extended support to allowing calling methods that are annotated with `@discardableResult` which we consider a good tradeoff.

### Allow `send` of any distributed method

We considered allowing `send` of any distributed method which does not throw and returns `Void` (or is `@discardableResult`), regardless of whether it is declared `@oneway`. For such methods, a `send` would make a regular `remoteCall` or `remoteCallVoid` call from within an enqueued call, and mark the remote call target as oneway using `isOnewayRemoteCall`, leaving it up to the actor system to not wait for a reply and return eagerly.

We decided against this, because such calls could not provide the guarantees which `send` provides for local actors, and for `@oneway` distributed methods:

- The order of consecutive `send` calls would not be preserved for remote actors: there is no local executor on which the enqueued calls could be ordered, so each of them would be scheduled independently, and the actor system's `remoteCall` methods could be invoked in any order.
- Whether the call actually results in a oneway message would depend on the actor system honoring the `isOnewayRemoteCall` marker; otherwise a full request-reply roundtrip would happen within the enqueued call, without the caller being aware of it.
- Errors on the caller's side of the call, such as failing to encode the arguments, could never be observed by the caller, since they would happen within the enqueued call, while the synchronous oneway call path throws them directly to the caller of `try send`.

Requiring `@oneway` makes every `send` of a distributed method use the actor system's oneway call path, with the same ordering guarantees as for local actors.

### Make oneway calls without a call-site keyword

In theory, we could allow calling methods with plain call syntax, e.g. `actor.complete()`, without any marker at the call-site. This would make calls which enqueue work on another actor indistinguishable from synchronous calls which would be very problematic for reading and analyzing performance and semantics of such code..

Requiring `send` at every call-site keeps the "something is happening asynchronously here" information visible in source code, the same way `await` marks potential suspension points.

### Make `@oneway` call-site violations errors by default

Calling a `@oneway` method with `await` results in a warning rather than an error. Such a call is well defined: the method does not throw, and its result is either `Void` or declared discardable, so nothing is lost by awaiting it, and the attribute only expresses the API author's intent. Making this an error would mean that adding `@oneway` to an existing method is a source breaking change. Projects which want to enforce this strictly can promote the `AwaitedOnewayCall` diagnostic group to an error, see [The `@oneway` attribute](#the-oneway-attribute).

### Allow `send` calls of throwing methods

Throwing is a form of returning a value to the caller, which the caller may want to inspect. Since a `send` call is never awaited, there is nobody to receive the thrown error. Allowing throwing methods to be called with `send` would mean that errors are silently dropped, which is a significant footgun.

If a method intended to be called with `send` needs to signal a failure, it should do so explicitly, e.g. by sending another message back to the caller.

`send` calls of distributed methods are implicitly throwing, the same as `await` calls of distributed methods, and must be written as `try send`. The sending side of the operation may fail to encode the message, or fail to hand it off to the transport, and such errors are thrown to the caller. It is not possible to carry back an error from the recipient to the caller, which is consistent with the rationale for banning throws to begin with.

### Alternative spellings of `send`, e.g. `nowait`, `tell`, `cast` ...

We explored various words we could use for the callsite, including words like `nowait` which sounds funny and is very explicit about what it does, however we found that leaning into existing terminology around `send` feels quite natural, and expresses the right `sending` semantics as arguments are sent to the target context.

While `send` may be confused with the `sending` parameter modifier and the `Sendable` protocol, these are actually closely related concepts: the arguments of a `send` call are themselves sent to the target actor's isolation domain, and are checked accordingly. Similar as like the sending inference works for the operation closure of a Task.

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

**Distributed Objects (1988):** Objective-C Distributed Objects, `NSDistantObject`, dating back to NeXTSTEP, implemented synchronous blocking remote calls, and were sometimes criticized for being too implicit in their remote call handling. Calls would look like normal local methods yet perform remote blocking calls by default. Distributed Actors differ here significantly because both effects (`throws` and `async`) are modeled by the language, and it is simple to notice where remote calls might be happening.

Objective-C offers a literal `oneway` method-declaration keyword: `- (oneway void)update:(id)data;`. A message to a `oneway` method which goes through a Distributed Objects proxy returns without waiting for the remote side, which matches the proposed semantics of `oneway`. A message to an ordinary object is still delivered synchronously, see [Respecting Objective-C `oneway` when importing](#respect-objective-c-oneway-when-importing).

**Windows COM / DCOM (1993):** Microsoft COM/DCOM are described in an IDL called MIDL (Microsoft Interface Definition Language). MIDL defines an [`[maybe]` attribute](https://learn.microsoft.com/en-us/windows/win32/midl/maybe), which marks fire-and-forget operations: the client does not wait for the call to complete, so such operations must return `void` and cannot have `[out]` parameters. MIDL also defines an [[idempotent]` attribute](https://learn.microsoft.com/en-us/windows/win32/midl/idempotent), which is a future direction for remote call semantics mentioned above.

**CORBA (1991):** CORBA's IDL has a literal `oneway` keyword predating this proposal by decades. An operation declared as `oneway void notify(in Data d);` must return `void`, may not declare any raised exceptions, and may not have `out` or `inout` parameters. The ORB is explicitly permitted, though not required, to deliver oneway calls best-effort rather than guaranteed, and to return control to the caller without waiting for the call to reach the server at all. These restrictions map almost exactly onto the void-only restriction this proposal places on `oneway`, and the term "oneway" used here likely traces back to this CORBA IDL usage, or to Distributed Objects, which predates it on Apple platforms.

Interestingly, **gRPC (2015)** does not offer any unidirectional calls, as in practice every call may end with a trailing response. However oneway messages are implemented as passing a stream of messages in an initial RPC which is later on consumed by the recipient. This pattern is also already possible in Swift.

Summing up, we see that the majority of RPC frameworks and systems use the term `oneway` and it explains the semantics we're exposing quite well.

## Revisions

- 1.0: Initial revision, `@remoteCall(oneway)` and `blocking` distributed methods
- 2.0:
  - Remove `blocking` from this proposal, it may be revisited separately
  - Generalize oneway calls from distributed actors to all actors
  - Introduce the `send` call keyword: any isolated method which does not throw, and returns `Void` or is `@discardableResult`, can be called with `send`, and its arguments are evaluated at the call site
  - Replace `@remoteCall(oneway)` with the `@oneway` attribute, which is part of the function type and allows overloading on it, and add `@oneway(never)`
  - Awaiting a `@oneway` method across isolation, or sending a `@oneway(never)` method, is a warning in the `AwaitedOnewayCall` or `SentOnewayNeverCall` diagnostic group
  - `send` of a distributed method requires it to be `@oneway`, and is written `try send`
  - `@oneway` distributed methods get a synchronous thunk which calls the new `remoteCallOneway` requirement of `DistributedOnewayActorSystem`, which the actor system must conform to
  - Add `RemoteCallTarget.isOnewayRemoteCall` and `RemoteCallTarget.isOnewayTarget`
