# Task Executor Preference

* Proposal: SE-NNNN
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso), [John McCall](https://github.com/rjmccall), [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: Partially implemented [PR #68793](https://github.com/apple/swift/pull/68793)
* Implementation: TBD
* Review: TBD

## Introduction

Swift Concurrency uses tasks and actors to model concurrency and primarily relies on actor isolation to determine where a specific piece of code shall execute.

The recent introduction of custom actor executors in [SE-0392](https://github.com/apple/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md) allows customizing on what specific `SerialExecutor` implementation code should be running on while isolated to a specific actor. This allows developers to gain some control over exact threading semantics of actors, by e.g. making sure all work made by a specific actor is made on a dedicated queue or thread.

Today, the same flexibility is not available to tasks in general, and nonisolated asynchronous functions are always forced to execute on the default global concurrent thread pool managed by Swift concurrency.

## Motivation

Custom actor executors allow developers to customize where execution of a task “on” an actor must happen (e.g. on a specific queue or thread, represented by a `SerialExecutor`), the same capability is currently missing for code that is not isolated to an actor.

Notably, since Swift 5.7’s [SE-0338: Clarify the Execution of Non-Actor-Isolated Async Functions](https://github.com/apple/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md), functions which are not isolated to an actor will always hop to the default global concurrent executor, which is great for correctness and understanding the code and avoids “hanging onto” actors  longer than necessary. This is also a desirable semantic for code running on the `MainActor` calling into `nonisolated` functions, since it allows the main actor to be quickly freed up to proceed with other work, however it has a decremental effect on applications which want to *avoid* hops in order to maximize request processing throughput. This is especially common with event-loop based systems, such as network servers or other kinds of tight request handling loops.

As Swift concurrency is getting adopted in a wider variety of performance sensitive codebases, it has become clear that the lack of control over where nonisolated functions execute is a noticeable problem. 
At the same time, the defensive "hop-off" semantics introduced by [SE-0338](https://github.com/apple/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md) are still valuable, but sometimes too restrictive and some use-cases might even say that the exact opposite behavior might be desirable instead.

This proposal acknowledges the different needs of various use-cases, and provides a new flexible mechanism for developers to tune their their applications and avoid potentially un-necessary context switching when possible.

## Proposed solution

We propose to introduce an additional layer of control over where a task can be executed, and have this executor setting be “sticky” to the task.

**Currently** the decision where an async function or closure is going to execute is binary:

```
// `func` execution semantics before this proposal

[ func / closure ] - /* where should it execute? */
                                 |
                           +--------------+          +==========================+
                   +- no - | is isolated? | - yes -> | default (actor) executor |
                   |       +--------------+          +==========================+
                   |
                   |                                 +==========================+
                   +-------------------------------> | on global conc. executor |
                                                     +==========================+
```

This proposal introduces a way to control hopping off to the global concurrent pool for `nonisolated` functions and closures. This is expressed as **task executor preference** and is sticky to the task and entire *structured task hierarchy* created from a task with a specified preference. This changes the current decision diagram to the following:

```
// `func` execution semantics with this proposal

[ func / closure ] - /* where should it execute? */
                               |
                     +--------------+          +===========================+
           +-------- | is isolated? | - yes -> | actor has unownedExecutor |
           |         +--------------+          +===========================+
           |                                       |                |      
           |                                      yes               no
           |                                       |                |
           |                                       v                v
           |                  +=======================+    /* task executor preference? */
           |                  | on specified executor |        |                   |
           |                  +=======================+       yes                  no
           |                                                   |                   |
           |                                                   |                   v
           |                                                   |    +==========================+
           |                                                   |    | default (actor) executor |
           |                                                   v    +==========================+
           v                                   +==============================+
/* task executor preference? */ ---- yes ----> | on Task's preferred executor |
           |                                   +==============================+
           no
           |
           v
  +===============================+
  | on global concurrent executor |
  +===============================+
```

In other words, this proposal introduces the ability to where code may execute from a Task, and not just by using a custom actor executor,
and even influence the thread use of default actors.

With this proposal a **`nonisolated` function** will execute, as follows:

* if task preference **is not** set:
  * it is equivalent to current semantics, and will execute on the global concurrent executor,

* if a task preference **is** set,
  * **(new)** nonisolated functions will execute on the selected executor.


The preferred executor also may influence where **actor-isolated code** may execute, specifically:

- if task preference **is** set:
  - **(new)** default actors will use the task's preferred executor
  - actors with a custom executor execute on that specified executor (i.e. "preference" has no effect), and are not influenced by the task's preference

The task executor preference can be specified either, at task creation time:

```swift
Task(on: executor) {
  // starts and runs on the 'executor'
  await nonisolatedAsyncFunc()
}

Task.detached(on: executor) {
  // starts and runs on the 'executor'
  await nonisolatedAsyncFunc()
}

await withDiscardingTaskGroup { group in 
  group.addTask(on: executor) { 
    // starts and runs on the 'executor'
    await nonisolatedAsyncFunc()
  }
}

func nonisolatedAsyncFunc() async -> Int {
  // if the Task has a specific executor preference,
  // runs on that 'executor' rather than on the default global concurrent executor
  return 42
} 
```

or, for a specific scope using the `withTaskExecutor` method:

```swift
await withTaskExecutor(executor) { 
  // if not already running on specified 'executor'
  // the withTaskExecutor would hop to it, and run this closure on it.

  // task groups
  await withDiscardingTaskGroup { group in 
    group.addTask {
      // starts and runs on the 'executor'
      await nonisolatedAsyncFunc()
    }
  }
  
  // async let 
  async let number = nonisolatedAsyncFunc() // starts and runs on 'executor'
  await number
}
```

Notably, the task executor preference is in effect for the entire structured task hierarchy while running in a task or scope where a task executor preference is set. For example, the following snippet illustrates child tasks created inside of a `withTaskExecutor`.

If a task with such executor preference encounters code which is `isolated` to some specific actor, it would adhere to that requirement and hop to it as expected:

```swift
let capy: Capybara = Capybara()
actor Capybara { func eat() {} } 

Task(on: executor) {
  // starts on 'executor', however...
  try await capy.eat() // still executes actor isolated code on the actor's executor, as expected
}
```

## Detailed design

### Setting task executor preference

A new concept of task executor preference is added to Swift Concurrency tasks. This preference is stored in a task and propagated throughout child tasks (such as ones created by TaskGroups and async let).

The preference can be set using various APIs that will be discussed in detail in their respective sections. The first of those APIs is `withTaskExecutor` which is can be called inside an asynchronous context to both ensure we’re executing on the expected executor, as well as set the task executor preference for the duration of the operation closure:

```swift
await withTaskExecutor(someExecutor) { 
 // guaranteed to be executing on someExecutor
}
```

Once set, the effect of an executor preference is such that a nonisolated func instead of immediately hopping to the global pool, it may hop to the preferred executor, e.g.:

```swift
nonisolated func tryMe() async { 
 // ...
}

let preferredExecutor: SomeConcreteTaskExecutor = ...
Task(on: preferredExecutor) {
  // executes on 'preferredExecutor'
  await tryMe() // tryMe body would execute on 'preferredExecutor'
}

 await tryMe() // tryMe body would execute on 'default global concurrent executor'
```

### The `TaskExecutor` protocol

In order to fulfil the requirement that we'd like default actors to run on a task executor, if it was set, we need to introduce a new kind of executor.

This stems from the fact that `SerialExecutor` and how a default actor effectively acts as an executor "for itself" function in Swift.
A default actor (so an actor which does not use a custom executor), has a "default" executor that is created by the Swift runtime and uses the actor is the executor's identity.
This means that the runtime executor tracking necessarily needs to track that some code is executing on a specific serial executor in order for things like `assumeIsolated` or the built-in runtime thread-safety checks can utilize them.

The new protocol mirrors `Executor` and `SerialExecutor` in API, however it provides different semantics, and is tracked using a different mechanism at runtime -- by obtaining it from a task's executor preference record.

The `TaskExecutor` is defined as:

```swift
public protocol TaskExecutor: Executor {
  func enqueue(_ job: consuming ExecutorJob)

  func asUnownedTaskExecutor() -> UnownedTaskExecutor
}
```

As an intuitive way to think about `TaskExecutor` and `SerialExecutor`, one can think of the prior as being a "source of threads" to execute work on,
and the latter being something that "provides serial isolation" and is a crucial part of Swift actors. The two share similarities, however the task executor has a more varied application space.

### Task executor preference inheritance in Structured Concurrency

Task executor preference is inherited by child tasks and actors which do not declare an explicit executor (so-called "default actors"), and is *not* inherited by un-structured tasks. 

Specifically:

* **Do** inherit task executor preference
    * TaskGroup’s `addTask()`, unless overridden with explicit parameter
    * `async let`
    * methods on default actors (actors which do not use a custom executor)
* **Do not** inherit task executor preference
    * Unstructured tasks: `Task {}` and `Task.detached {}`
    * methods on actors which **do** use a custom executor (including e.g. the `MainActor`)

This also means that an entire tree can be made to execute their nonisolated work on a specific executor, just by means of setting the preference on the top-level task.

### Task executor preference and async let

Since `async let` are the simplest form of structured concurrency, they dot not offer much in the way of customization.

An async currently always executes on the global concurrent executor, and with the inclusion of this proposal, it does take into account task executor preference. In other words, if an executor preference is set, it will be used by async let to enqueue its underlying task:

```swift
func test() async -> Int {
  return 42
}

await withTaskExecutor(someExecutor) { 
  async let value = test(someExecutor) // async let's "body" and target function execute on 'someExecutor'
  // ... 
  await value
}
```

### Task executor preference and TaskGroups

A `TaskGroup` and its various friends (`ThrowingTaskGroup`, `DiscardingTaskGroup`, ...) are the most powerful, but also most explicit and verbose API for structured concurrency. A group allows creating multiple child tasks using the `addTask` method, and always awaits all child tasks to complete before returning.

This proposal adds overloads to the `addTask` method, which changes the executor the child tasks will be enqueued on:

```swift
extension (Discarding)(Throwing)TaskGroup { 
  mutating func addTask(
    on executor:  (any TaskExecutor)?,  // 'nil' means the global pool
    priority:  TaskPriority? = nil,
    operation:  @Sendable @escaping () async (throws) -> Void
  )
}
```

Which allows users to require child tasks be enqueued and run on specific executors:

```swift
Task(on: specialExecutor) {
  _ = await withTaskGroup(of: Int.self) { group in 
    group.addTask() {
      specialExecutor.assertIsolated()
      12 
    }
    group.addTask(on: differentExecutor) {
      differentExecutor.assertIsolated()
      42 
    }
    group.addTask(on: nil) { 
      // guaranteed to run on the default global concurrent executor;
      // this is equivalent to the only behavior a group exhibits today.
      84
    } 
    return await group.next()!
  }
```

This gives developers explicit control over where a task group child task shall be executed. Notably, this gives callers of libraries more control over where work should be performed. Do note that code executing on an actor will always hop to that actor; and task executor preference has no impact on code which *requires* to be running in some specific isolation.

If a library really wants to ensure that hops to the global concurrent executor *are* made by e.g. such task group, they should use `group.addTask(on: nil)` to override the inherited task executor preference.

### Task executor preference and Unstructured Tasks

We propose adding new APIs and necessary runtime changes to allow a Task to be enqueued directly on a specific `Executor`, by using a new `Task(on:)` initializer:

```swift
extension Task where Failure == Never {
  @discardableResult
  public init(
    on executor:  (any TaskExecutor)?,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Success
  )
  
  @discardableResult
  static func detached(
    on executor:  (any TaskExecutor)?,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Success
  )
}

extension Task where Failure == Error { 
  @discardableResult
  public init(
    on executor: any TaskExecutor,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async throws -> Success
  )
  
  @discardableResult
  static func detached(
    on executor: (any TaskExecutor)?,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async throws -> Success
  )
}
```

Tasks created this way are **immediately enqueued** on given executor.

Since serial executors are executors, they can also be used with this API. However since serial executors are predominantly used by actors, in tandem with actor isolation — there is a better way to run tasks on a specific actor, and therefore its serial executor.

#### Task executor preference and default actor isolated methods

It is also worth explaining the interaction with actors which do not use a custom executor -- which is the majority of actors usually defined in a typical codebase.
Such actors are referred to as "default actors" and are the default way of how actors are declared:

```swift
actor RunsAnywhere { // a "default" actor == without an executor requirement
  func hello() {
    return "Hello"
  }
}
```

Such actor has no requirement as to where it wants to execute. This means that if we were to call the `hello()` isolated 
actor method from a task that has defined an executor preference -- the hello() method would still execute on a thread owned by that executor (!),
however isolation is still guaranteed by the actor's semantics:

```swift
let anywhere = RunsAnywhere()
Task { await anywhere.hello() } // runs on "default executor", using a thread from the global pool

Task(on: myExecutor) { await anywhere.hello() } // runs on preferred executor, using a thread owned by that executor
```

Methods which assert isolation, such as `Actor/assumeIsolated` and similar still function as expected.

The task executor can be seen as a "source of threads" for the execution, while the actor's serial executor is used to ensure the serial and isolated execution of the code.

## Execution semantics discussion

### Not a Golden Hammer

As with many new capabilities in libraries and languages, one may be tempted to use task executors to solve various problems.

We advice to take care when doing so with task executors, because while they do minimize the "hopping off" from executors and the associated context switching,
this is also a behavior that may be entirely _undesirable_ in some situations. For example, over-hanging on the MainActor's executor is one of the main reasons
earlier Swift versions moved to make `nonisolated` asynchronous functions always hop off their calling execution context; and this proposal brings back this behavior 
for specific executors. 

Applying task executors to solve a performance problem should be done after thoroughly understanding the problem an application is facing,
and only then determining the right "sticky"-ness behavior and specific pieces of code which might benefit from it.

Examples of good candidates for task executor usage would be systems which utilize some form of "specific thread" to minimize synchronization overhead, 
like for example event-loop based systems (often, network applications), or IO systems which willingly perform blocking operations and need to perform them off the global concurrency pool. 

### Analysis of use-cases and the "sticky" preference semantics

The semantics explained in this proposal may at first seem tricky, however in reality the rule is quite strightfoward:

- when there is a strict requirement for code to run on some specific executor, *it will* (and therefore disegard the "preference"),
- when there is no requirement where asynchronous code should execute, this proposal allows to specify a preference and therefore avoid hopping and context switches, leading to more efficient programs.

It is worth discussing how user-control is retained with this proposal. Most notably, we believe this proposal follows Swift's core principle of progressive disclosure. 

When developing an application at first one does not have to optimize for less context switches, however as applications grow performance analysis diagnoses context switching being a problem -- this proposal gives developers the tools to, selectively, in specific parts of a code-base introduce sticky task executor behavior.

### Separating blocking code off the global shared pools

This proposal gives control to developers who know that they'd like to isolate their code off from callers. For example, imagine an IO library which wraps blocking IO primitives like read/write system calls. You may not want to perform those on the width-limited default pool of Swift Concurrency, but instead wrap APIs which will be calling such APIs with the executor preference of some "`DedicatedIOExecutor`" (not part of this proposal):

```swift
// MyCoolIOLibrary.swift

func blockingRead() -> Bytes { ... } 

public func callRead() async -> Bytes { 
  await withTaskExecutor(DedicatedIOExecutor.shared) { // sample executor
    blockingRead() // OK, we're on our dedicated thread
  }
}

public func callBulk() async -> Bytes {
  // The same executor is used for both public functions
  await withTaskExecutor(DedicatedIOExecutor.shared) { // sample executor
    await callRead() 
    await callRead()
  }
}
```

This way we won't be blocking threads inside the shared pool, and not risking thread starving of the entire application.

We can call `callRead` from inside `callBulk` and avoid un-necessary context switching as the same thread servicing the IO operation may be used for those asynchronous functions -- and no actual context switch may need to be performed when `callBulk` calls into `callRead` either.

For end-users of this library the API they don't need to worry about any of this, but the author of such library is in full control over where execution will happen -- be it using task executor preference, or custom actor executors.

This works also the other way around: when we're using a library and notice that it is doing blocking things and we'd rather separate it out onto a different executor. It may even have declared asynchronous methods -- but still is taking too long to yield the thread for some reason, causing issues to the shared pool.

```swift
// SomeLibrary
nonisolated func slowSlow() async { ... } // causes us issues by blocking
```

 In such situation, we, as users of given library can notice and work around this issue by wrapping it with an executor preference:

```swift
// our code
func caller() async {
  // on shared global pool...
  // let's make sure to run slowSlow on a dedicated IO thread:
  await withTaskExecutor(DedicatedIOExecutor.shared) { // sample executor
    await slowSlow() // will not hop to global pool, but stay on our IOExecutor
  }
}
```

In other words, task executor preference gives control to developers at when and where care needs to be taken.

The default of hop-avoiding when a preference is set is also a good default because it optimizes for less context switching and can lead to better performance. 

It is possible to disable a preference by setting the preference to `nil`. So if we want to make sure that some code would not be influenced by a caller's preference, we can defensively insert the following:

```swift
func function() async {
  // make sure to ignore caller's task executor preference
  await withTaskExecutor(nil) { ... }
}
```

#### What about the Main Actor?

While the `MainActor` is not really special under this model, and behaves just as any other actor _with_ an specific executor requirement. 

It is worth reminding that using the main actor's executor as a preferred excecutor would have the same effect as with any other executor. While usually using the main actor as preferred executor is not recommended. After all, this is why the original proposal was made to make nonisolated async functions hop *off* from their calling context, in order to free the main actor to interleave other work while other asynchronous work is happening.

In some situations, where the called asynchronous function may be expected to actually never suspend directly but only sometimes call another actor, and otherwise just return immediately without ever suspending. This may be used as fine optimization to tune around specific well known calls.

### Task executor preference and `AsyncSequence`s

One use-case worth calling out is AsyncSequences, especially when used from actors. 

The following snippet illustrates a common performance pitfall today:

```swift
actor Looper { 
  func consumeSequence() async {
    for await value in getAsyncSequence() {
      // 1. hop-to global pool: await next()
      // 2. hop-to actor: execute for-loop body
      print("got: \(value)")
    }
  }
}
```

Because an async sequence's iterator has a nonisolated `next()` method (declared like this `func next() async -> Element?`),
under the current execution semantics, the execution will _always_ hop to the global concurrent executor to execute the `next()` method,
and only then let it run, potentially produce a value without even suspending (!), and hop back to the actor to process the body of the for-loop.

This is unfortunate and can cause a lot of back-and forth hopping that may not necessarily be desirable. Especially with async sequences which employ
some form of buffering, such that e.g. the sequence has a number of elements "ready" and will return them immediately without having to suspend or synchronize with other `isolated` code.

With the use of task executor preference, we are able to circumvent the hops to the global concurrent executor, by preferring the actor's own executor, like this:

```swift
actor Looper { 
  func consumeSequence() async {
    withTaskExecutor(self) {
      for await value in getAsyncSequence() {
        // 1.a. 'next()' can execute on Looper's executor
        // 1.b. if next() needs to call some other isolated code, we would hop there
        //      but only when necessary.
        // 2.a. Following the fast path where next() executed directly on Looper.executor,
        //      the "hop back to actor" is efficient because it is a hop to the same executor which is a no-op.
        // 2.b. Following the slow path where next() had to call some `isolated` code,
        //      the hop back to the Looper is the same as it would be normally.
        print("got: \(value)")
      }
    }
  }
}
```

Async sequences are expected to undergo further evolution in order to express isolation more efficiently in the actor case.
Task executors are expected to fit well into this model, and offer an additional layer of "fine tuning" of developers encounter the need to do so.

## Prior-Art

It is worth comparing with other concurrency runtimes with similar concepts to make sure if there are some common ideas or something different other projects have researched.

For example, in Kotlin, a `launch` which equivalent to Swift’s creation of a new task, takes a coroutine context which can contain an executor preference. The official documentation showcases the following example:

```kotlin
launch { // context of the parent, main runBlocking coroutine
    println("main runBlocking      : I'm working in thread ${Thread.currentThread().name}")
}
launch(Dispatchers.Unconfined) { // not confined -- will work with main thread
    println("Unconfined            : I'm working in thread ${Thread.currentThread().name}")
}
launch(Dispatchers.Default) { // will get dispatched to DefaultDispatcher 
    println("Default               : I'm working in thread ${Thread.currentThread().name}")
}
launch(newSingleThreadContext("MyOwnThread")) { // will get its own new thread
    println("newSingleThreadContext: I'm working in thread ${Thread.currentThread().name}")
}
```

Which is similar to the here proposed semantics of passing a specific executor preference. Notably though, because Swift has the concept of actor `isolation` the executor semantics introduced in this proposal are only a preference and will never override the executor requirements of actually strongly `isolated` code.

Kotlin jobs also inherit the coroutine context from their parent, which is similar to the here proposed executor inheritance works.

## Future directions

### Task executor preference and global actors

Thanks to the improvements to treating @SomeGlobalActor isolation proposed in [SE-NNNN: Improved control over closure actor isolation](https://github.com/apple/swift-evolution/pull/2174) we would be able to that a Task may prefer to run on a specific global actor’s executor, and shall be isolated to that actor.

Thanks to the equivalence between `SomeGlobalActor.shared` instance and `@SomeGlobalActor` annotation isolations (introduced in the linked proposal), this does not require a new API, but uses the previously described API that accepts an actor as parameter, to which we can pass a global actor’s `shared` instance.

```swift
@MainActor 
var example: Int = 0

Task(on: MainActor.shared) { 
   example = 12 // not crossing actor-boundary
}
```

It is more efficient to write `Task(on: MainActor.shared) {}` than it is to `Task { @MainActor in }` because the latter will first launch the task on the inferred context (either enclosing actor, or global concurrent executor), and then hop to the main actor. The `on MainActor` spelling allows Swift to immediately enqueue on the actor itself.

### Static closure isolation 

It would be interesting to allow starting a task on a specific actor's executor, and have this infer the specific isolation.
The upcoming [SE-NNNN: Improved control over closure actor isolation](https://github.com/apple/swift-evolution/pull/2174) proposal includes a future direction which would allow isolating a closure to a known other value.

This could be utilized to spell the `Task` initializer like this:

```swift
extension Task where ... {
  init<TargetActor>(
    on target: TargetActor,
    // ..., 
    operation: @isolated(target) () async -> ()
  ) where TargetActor: Actor
}
```

This would allow us to cut down on the noise of passing the isolated-on parameter explicitly, and we could rely on capturing the worker and propagating isolation semantics -- similar to how a `Task {}` initializer captures the "self" implicitly, but generalized to parameters of functions, and not just lexical scope:

```swift
actor Worker { func work() {} }
let worker: Worker = Worker()

Task(on: worker) { worker in // noisy parameter; though required for isolation purposes
  worker.work()
}
```

### Starting tasks on distributed actor executors

Expressing the “run isolated to this distributed actor” APIs is tricky until distributed actors gain the ability to express the `local`-ness of a specific instance. For that reason we currently do not introduce the above APIs for distributed actors.

For reference, the semantics we are after would be something like the following:

```swift
extension Task where Failure == Never {
  @discardableResult
  public init<TargetActor>(
    on executor: local TargetActor,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping (isolated TargetActor) async -> Success
  ) where TargetActor: DistributedActor
}
```

Which would be used like this:

```swift
let definitelyLocal = Worker(actorSystem: system) 
// : local Worker
Task(on: definitelyLocal) { definitelyLocal in 
  definitelyLocal.hello()
}
```

Which can work only with a `local` distributed actor because a local can always be safely upgraded to an `isolated` reference by performing an actor hop to its executor. The same is not possible for an “unknown if local or remote” reference.

## Alternatives considered

### Do not provide any control over task executors

We considered if not introducing this feature could be beneficial and forcing developers to always pass explicit `isolated` parameters instead. We worry that this becomes a) very tedious and b) impossibly ties threading semantics with public API and ABI of methods. We are concerned that the lack of executor “preference” which only affects the nonisolated functions in a task hierarchy would cause developers to defensively and proactively create multiple versions of APIs. It would also only allow passing actors as the executors, because isolation is an actor concept, and therefore we’d only be able to isolate using serial executors, while we may want to isolate using general purpose `Executor` types.


## Revisions
- 1.3
  - introduce TaskExecutor in order to be able to implement actor isolation properly and still use a different thread for running default actors
  - wording cleanups
  - removal of the `Task(on: Actor)` APIs; we could perhaps revisit this if we made default actors' executors somehow aware of being a thread source as well etc. 
- 1.2
  - preference also has effect on default actors
- 1.1
  - added future direction about simplifying the isolation of closures without explicit parameter passing
  - removed ability to observe current executor preference of a task
