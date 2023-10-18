# Task Executor Preference for Nonisolated Async Functions

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

As Swift concurrency is getting adopted in a wider variety of performance sensitive codebases, it has become clear that the lack of control over where nonisolated functions execute is a noticable problem. 
At the same time, the defensive "hop-off" semantics introduced by [SE-0338](https://github.com/apple/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md) are still valuable, but sometimes too restrictive and some use-cases might even say that the exact opposite behavior might be desirable instead.

This proposal acknowledges the different needs of various use-cases, and provides a new flexible mechanism for developers to tune their their applications and avoid potentially un-necessary context switching when possible.

## Proposed solution

We propose to introduce an additional layer of control over where a task can be executed, and have this executor setting be “sticky” to the task.

**Currently** the decision where an async function or closure is going to execute is binary:

```
// `func` execution semantics before this proposal

[ func / closure ] - /* where should it execute? */
                                 |
                           +--------------+          +=========================+
                   +- no - | is isolated? | - yes -> | on the `isolated` actor |
                   |       +--------------+          +=========================+
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
                        +--------------+          +=========================+
              +--- no - | is isolated? | - yes -> | on the `isolated` actor |
              |         +--------------+          +=========================+
              |
              v                                   +==========================+
/* task executor preference? */ ------ no ------> | on global conc. executor |
              |                                   +==========================+
             yes
              |
              v
  +=================================+
  | on specified preferred executor |
  +=================================+
```

In other words, this proposal introduces the ability to control where a **`nonisolated` function** should execute:

* if no task preference is set, it is equivalent to current semantics, and will execute on the global concurrent executor,
* if a task preference is set, nonisolated functions will execute on the selected executor.

This proposal does not change isolation semantics of nonisolated functions, and only applies to the runtime execution semantics of such functions.

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
  executor.assertIsolated()
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

let preferredExecutor: SomeConcreteExecutor = ...
Task(on: preferredExecutor) { 
  preferredExecutor.assertIsolated()
  await tryMe() // tryMe body would execute on 'preferredExecutor'
}

 await tryMe() // tryMe body would execute on 'default global concurrent executor'
```

### Task executor preference inheritance in Structured Concurrency

Task executor preference is inherited by child tasks and is *not* inherited by un-structured tasks. Specifically:

* **Do** inherit task executor preference
    * TaskGroup’s `addTask()`, unless overridden with explicit parameter
    * `async let`
* **Do not** inherit task executor preference
    * Unstructured tasks: `Task {}` and `Task.detached {}`

This also means that an entire tree can be made to execute their nonisolated work on a specific executor, just by means of setting the preference on the top-level task.

### Task executor preference and async let

Since `async let` are the simplest form of structured concurrency, they dot not offer much in the way of customization.

An async currently always executes on the global concurrent executor, and with the inclusion of this proposal, it does take into account task executor preference. In other words, if an executor preference is set, it will be used by async let to enqueue its underlying task:

```swift
func test(_ someExecutor: any Executor) -> Int {
  someExecutor.assertIsolated()
  return 42
}

await withTaskExecutor(someExecutor) { 
  async let value = test(someExecutor) // executes on 'someExecutor'
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
    on executor:  (any Executor)?,  // 'nil' means the global pool
    priority:  TaskPriority? = nil,
  operation:  @Sendable @escaping () async (throws) -> Void
  )
  
  mutating func addTask<TargetActor>(
 on actor: TargetActor,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping (isolated TargetActor) async (throws) -> Void
  ) where TargetActor: Actor
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
    on executor:  (any Executor)?,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Success
  )
  
  @discardableResult
  static func detached(
    on executor:  (any Executor)?,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Success
  )
}

extension Task where Failure == Error { 
  @discardableResult
  public init(
    on executor: any Executor,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async throws -> Success
  )
  
  @discardableResult
  static func detached(
    on executor: (any Executor)?,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async throws -> Success
  )
}
```

Tasks created this way are **immediately enqueued** on given executor.

Since serial executors are executors, they can also be used with this API. However since serial executors are predominantly used by actors, in tandem with actor isolation — there is a better way to run tasks on a specific actor, and therefore its serial executor.

### Task executor preference and Actors

The most common way to use executors in Swift is by far using an actor’s default serial executor. Every actor (and distributed actor), by default receives a synthesized default serial executor which is used to guarantee the actor’s exclusive execution semantics. It is also possible to provide a custom SerialExecutor to an actor, as introduced in [SE-0392: Custom Actor Executors](https://github.com/apple/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md), and while it is possible to pass an `SerialExecutor` used by an actor to the new APIs introduced, it is preferable to pass *the actor itself*, because this way the task’s body can statically be isolated to the actor and we can avoid having to write un-necessary awaits, like this:

```swift
actor Worker {
  func hi() {}
}

Task(on: actor) { actor in
  actor.hi()
}
```

The APIs added to Task are similar to the ones discussed above using executors as parameters, but specialized for Actor types:

```swift
extension Task where Failure == Never {
  @discardableResult
  init<TargetActor>(
    on actor: TargetActor,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping (isolated TargetActor) async -> Success
  ) where TargetActor: Actor

  @discardableResult
  static func detached<TargetActor>(
    on actor: TargetActor,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping (isolated TargetActor) async -> Success
  ) where TargetActor: Actor
}

extension Task where Failure == Error { 
  @discardableResult
  public init<TargetActor>(
    on actor: TargetActor,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping (isolated TargetActor) async throws -> Success
  ) where TargetActor: Actor
  
  @discardableResult 
  static func detached<TargetActor>(
    on actor: TargetActor,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping (isolated TargetActor) async throws -> Success
  ) where TargetActor: Actor
}
```

This API also enables stronger guarantees about task enqueue order on actors. Previously, a snippet of two unstructured tasks, following one another without awaiting on the `first` before starting the `second` would have un-specified enqueue order of the `wantsToBeFirst()` and `wantsToBeSecond()` calls on the actor:

```swift
actor Worker { 
  func wantsToBeFirst() {} 
  func wantsToBeSecond() {} 
}
let worker = Worker()

// No enqueue order guarantee:
let first = Task { 
  // 1. starts on global concurrent executor
  // 2. hops-to 'worker' executor
  await worker.wantsToBeFirst() 
} 
let second = Task { 
  // 1. starts on global concurrent executor
  // 2. hops-to 'worker' executor
  await worker.wantsToBeSecond()   
} 
```

Because of the `Task` always “starting on” the global concurrent executor, the code above exhibits a race between the two tasks and it is not defined which task would be first enqueued on the actor; Instead, if one were to use the following pattern using the  Task(on: actor) initializer:

```swift
_ = Task(on: worker) { worker in
  // 0. Task enqueued directly onto 'worker' executor
  worker.wantsToBeFirst()
}
_ = Task(on: worker) { worker in
  // 0. Task enqueued directly onto 'worker' executor
  worker.wantsToBeSecond()
}
```

This can be useful in limited situations to provide stronger ordering guarantees than possible before; however it **does not** provide strict FIFO in-order processing guaranteesbecause if `second` would be awaited on from a high-priority task, its priority would be escalated and it may still execute before the wantsToBeFirst call happens. Swift’s default actors handle priority escalation by default and allow for such reordering.

If one were to guarantee that neither `first` and `second` will not be awaited on, the order of the calls would be as expected. This is a rather brittle mechanism though and we do not recommend it as a way to enforce strict FIFO ordering for actors.

The same kind of APIs are offered for creating structured tasks using TaskGroups:

```swift
extension (Discarding)(Throwing)TaskGroup { 
  func addTask<TargetActor: Actor>(
    on: TargetActor, 
    operation: (isolated TargetActor) async (throws) -> Success)
}
```

### Task executor preference and global actors

Thanks to the improvements to treating @SomeGlobalActor isolation proposed in [SE-NNNN: Improved control over closure actor isolation](https://github.com/apple/swift-evolution/pull/2174) we are able to express that a Task may prefer to run on a specific global actor’s executor, and shall be isolated to that actor.

Thanks to the equivalence between `SomeGlobalActor.shared` instance and `@SomeGlobalActor` annotation isolations (introduced in the linked proposal), this does not require a new API, but uses the previously described API that accepts an actor as parameter, to which we can pass a global actor’s `shared` instance.

```swift
@MainActor 
var example: Int = 0

Task(on: MainActor.shared) { 
   example = 12 // not crossing actor-boundary
}
```

It is more efficient to write `Task(on: MainActor.shared) {}` than it is to `Task { @MainActor in }` because the latter will first launch the task on the inferred context (either enclosing actor, or global concurrent executor), and then hop to the main actor. The `on MainActor` spelling allows Swift to immediately enqueue on the actor itself.

## Execution semantics discussion

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



## Prior Art

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

### Static closure isolation 

When starting tasks on an actor's serial executor this proposal has to utilize the pattern of passing an isolated parameter to a task's operation closure in order to carry the isolation information to the closure, like this:


```swift
actor Worker { func work() {} }
let worker: Worker = Worker()

Task(on: worker) { worker in // noisy parameter; though required for isolation purposes
  worker.work() 
}
```

This is because, currently, there is no other way to inform the type system about the isolation of this closure. 

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

This would allow us allow us to cut down on the noise of passing the isolated-on parameter explicitly, and we could rely on capturing the worker and propagating isolation semantics -- similar to how a `Task {}` initializer captures the "self" implicitly, but generalized to parameters of functions, and not just lexical scope:

```swift
actor Worker { func work() {} }
let worker: Worker = Worker()

Task(on: worker) { worker in // noisy parameter; though required for isolation purposes
  worker.work()
}
```

### Task executor preference and distributed actors

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

- added future direction about simplifying the isolation of closures without explicit parameter passing
- removed ability to observe current executor preference of a task
