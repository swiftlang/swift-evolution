# Starting tasks synchronously from caller context

* Proposal: [SE-0472](0472-task-start-synchronously-on-caller-context.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Implemented (Swift 6.2)**
* Implementation:
  * https://github.com/swiftlang/swift/pull/79608
  * https://github.com/swiftlang/swift/pull/81428
  * https://github.com/swiftlang/swift/pull/81572
* Review: ([pitch](https://forums.swift.org/t/pitch-concurrency-starting-tasks-synchronously-from-caller-context/77960/)) ([first review](https://forums.swift.org/t/se-0472-starting-tasks-synchronously-from-caller-context/78883)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0472-starting-tasks-synchronously-from-caller-context/79311)) ([second review](https://forums.swift.org/t/second-review-se-0472-starting-tasks-synchronously-from-caller-context/79683)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0472-starting-tasks-synchronously-from-caller-context/80037))

## Introduction

Swift Concurrency's primary means of entering an asynchronous context is creating a Task (structured or unstructured), and from there onwards it is possible to call asynchronous functions, and execution of the current work may _suspend_.

Entering the asynchronous context today incurs the creating and scheduling of a task to be executed at some later point in time. This initial delay may be wasteful for tasks which perform minimal or no (!) work at all.

This initial delay may also be problematic for some situations where it is known that we are executing on the "right actor" however are *not* in an asynchronous function and therefore in order to call some different asynchronous function we must create a new task and introduce subtle timing differences as compared to just being able to call the target function–which may be isolated to the same actor we're calling from–immediately.

## Motivation

Today, the only way to enter an asynchronous execution context is to create a new task which then will be scheduled on the global concurrent executor or some specific actor the task is isolated to, and only once that task is scheduled execution of it may begin.

This initial scheduling delay can be problematic in some situations where tight control over execution is required. While for most tasks the general semantics are a good choice–not risking overhang on the calling thread–we have found through experience that some UI or performance sensitive use-cases require a new kind of semantic: immediately starting a task on the calling context. After a suspension happens the task will resume on the the executor as implied by the task operation's isolation, as would be the case normally.

This new behavior can especially beneficial for tasks, which *may run to completion very quickly and without ever suspending.* 

A typical situation where this new API may be beneficial often shows up with @MainActor code, such as:

```swift
@MainActor var thingsHappened: Int = 0

@MainActor func asyncUpdateThingsHappenedCounter() async {
  // for some reason this function MUST be async
  thingsHappened += 1
}

func synchronousFunction() {
  // we know this executes on the MainActor, and can assume so:
  MainActor.assumeIsolated { 
    // The following would error:
    // await asyncUpdateThingsHappenedCounter() 
    // because it is an async call; cannot call from synchronous context
  }
  
  // Using the newly proposed Immediate Task:
  let task = Task.immediate {
    // Now we CAN call the asynchronous function below:
    await asyncUpdateThingsHappenedCounter()
  }
  
  // cannot await on the `task` since still in synchronous context
}
```

The above example showcases a typical situation where this new API can be useful. While `assumeIsolated` gives us a specific isolation, but it would not allow us to call the async functions, as we are still in a synchronous context.

The proposed `Task.immediate` API forms an async context on the calling thread/task/executor, and therefore allows us to call into async code, at the risk of overhanging on the calling executor. 

While this should be used sparingly, it allows entering an asynchronous context *synchronously*.

## Proposed solution

We propose the introduction of a new family of Task creation APIs collectively called "**immediate tasks**", which create a task and use the calling execution context to run the task's immediately, before yielding control back to the calling context upon encountering the first suspension point inside the immediate task.

Upon first suspension inside the immediate task, the calling executor is freed up and able to continue executing other work, including the code surrounding the creation of the immediate task. This happens specifically when a real suspension happens, and not for "potential suspension point" (which are marked using the `await` keyword).

The canonical example for using this new API is using an *unstructured immediate task* like this:

```swift
func synchronous() { // synchronous function
  // executor / thread: "T1"
  let task: Task<Void, Never> = Task.immediate {
    // executor / thread: "T1"
    guard keepRunning() else { return } // synchronous call (1)
    
    // executor / thread: "T1"
    await noSuspension() // potential suspension point #1 // (2)
    
    // executor / thread: "T1"
    await suspend() // potential suspension point #2 // (3), suspend, (5)
    // executor / thread: "other"
  }
  
  // (4) continue execution
  // executor / thread: "T1"
} 
```

The task created by the `immediate` function begins running immediately _on the calling executor (and thread)_ without any scheduling delay. This new task behaves generally the same as any other unstructured task, it gets a copy of the outer context's task locals, and uses the surrounding context's base priority as its base priority as well.

Since the task started running immediately, we're able to perform some calls immediately inside it, and potentially return early, without any additional scheduling delays.

If a potential suspension point does not actually suspend, we still continue running on the calling context. For example, if potential suspension point `#1` did not suspend, we still continue running synchronously until we reach potential suspension point `#2` which for the sake of discussion let's say does suspend. At this point the calling thread continues executing the code that created the unstructured task. 

> You can refer to the `(N)` numbers in the above snippet to follow the execution order of this example execution. Specifically, once the execution reaches (3) the calling thread stops executing the unstructured task, and continues executing at (4). Eventually, when the unstructured task is resumed, it gets woken up at (5) and continues running on some other executor and/or thread.

## Detailed design

We propose the introduction of a family of APIs that allow for the creation of *immediate tasks*.

The most frequent use of this API is likely going to be the unstructured task one. This is because we are able to enter an asynchronous context from a synchronous function using it:

```swift
extension Task {
  
    @discardableResult
    public static func immediate(
        name: String? = nil, // Introduced by SE-0469
        priority: TaskPriority? = nil,
        executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
        @_inheritActorContext(always) operation: sending @escaping () async throws(Failure) -> Success
    ) -> Task<Success, Failure>
  
    @discardableResult
    public static func immediateDetached(
        name: String? = nil, // Introduced by SE-0469
        priority: TaskPriority? = nil,
        executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
        @_inheritActorContext(always) operation: sending @escaping () async throws(Failure) -> Success
    ) -> Task<Success, Failure>
}
```

We also introduce the same API for all kinds of task groups. These create child tasks, which participate in structured concurrency as one would expect of tasks created by task groups.

```swift
extension (Throwing)TaskGroup {
  // Similar semantics as the usual 'addTask'.
  func addImmediateTask(
    name: String? = nil, // Introduced by SE-0469
    priority: TaskPriority? = nil,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    operation: sending @escaping () async throws -> ChildTaskResult
  )
  
  // Similar semantics as the usual 'addTaskUnlessCancelled'.
  func addImmediateTaskUnlessCancelled(
    name: String? = nil, // Introduced by SE-0469
    priority: TaskPriority? = nil,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    operation: sending @escaping () async throws -> ChildTaskResult
  )
}

extension (Throwing)DiscardingTaskGroup {
  // Similar semantics as the usual 'addTask'.
  func addImmediateTask(
    name: String? = nil, // Introduced by SE-0469
    priority: TaskPriority? = nil,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    operation: sending @escaping () async throws -> ChildTaskResult
  )
  
  // Similar semantics as the usual 'addTaskUnlessCancelled'.
  func addImmediateTaskUnlessCancelled(
    name: String? = nil, // Introduced by SE-0469
    priority: TaskPriority? = nil,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    operation: sending @escaping () async throws -> ChildTaskResult
  )
}
```

The `addImmediateTask` function mirrors the functionality of `addTask`, unconditionally adding the task to the task group, while the `addImmediateTaskUnlessCancelled` mirrors the `addTaskUnlessCancelled` which only adds the task to the group if the group (or task we're running in, and therefore the group as well) are not cancelled.

### Isolation rules

Due to the semantics of "starting on the caller context", the isolation rules of the closure passed to `Task.immediate` need to be carefully considered.

The isolation rules for the `immediate` family of APIs need to account for this synchronous "first part" of the execution. We propose the following set of rules to make this API concurrency-safe:

- The operation closure is `sending`.
- The operation closure may only specify an isolation (e.g. `{ @AnyGlobalActor in }`)

Another significant way in which `Task.immediate` differs from the `Task.init` initializer is that the inheritance of the surrounding actor context is performed more eagerly. This is because immediate tasks always attempt to execute on the "current" executor, unlike `Task.init` which only execute on the "surrounding" actor context when the task's operation closure closes over an isolated parameter, or was formed in a global actor isolated context:

```swift
@MainActor 
func alreadyDefinitelyOnMainActor() {
  Task { 
    // @MainActor isolated, enqueue
  }
  Task.immediate { 
    // @MainActor isolated, run immediately
  }
}
```

```swift
actor Caplin { 
  var anything: Int = 0
  
  func act() {
    Task {
      // nonisolated, enqueue on global concurrent executor
    }
    Task {
      // self isolated, enqueue
      self.anything // any capture of 'self'
    }
  
    Task.immediate { // regardless of captures
      // self isolated, run immediately
    }
  }
}

func go(with caplin: isolated Caplin) async {
    Task {
      // nonisolated, enqueue on global concurrent executor
    }
    Task {
      // 'caplin' isolated, enqueue
      caplin.anything // any capture of 'caplin'
    }
  
    Task.immediate { // regardless of captures
      // 'caplin' isolated, run immediately
    }
  }
}

func notSpecificallyIsolatedAnywhere() {
    Task {
      // nonisolated, enqueue on global concurrent executor
    }
  
    Task.immediate {
      // nonisolated. 
      // attempt to run on current executor, 
      // or enqueue to global as fallback
    }
  }
}
```

The `Task.immediateDetached` does not inherit isolation automatically, same as it's non-immediate `Task.detached` equivalent. 

Task group methods which create immediate child tasks do not inherit isolation automatically, although they are allowed to specify an isolation explicitly. This is the same as existing TaskGroup APIs (`addTask`).

### Scheduling immediate tasks given matching current and requested isolation

The Swift concurrency runtime maintains a notion of the "current executor" in order to be able to perform executor switching and isolation checking dynamically. This information is managed at runtime, and is closely related to compile time isolation rules, but it is also maintained throughout nonisolated and synchronous functions.

Immediate tasks make use of this executor tracking to determine on which executor we're asking the task to "immediately" execute. It is possible to start an immediate task in a synchronous context, and even require it to have some specific isolation.

The following example invokes the synchronous `sayHello()` function from a `@MainActor` isolated function. The static information about this isolation is _lost_ by the synchronous function. And the compiler will assume, that the `sayHello()` function is not isolated to any specific context -- after all, the actual isolated context would depend on where we call it from, and we're not passing an `isolated` parameter to this synchronous function.

By using an immediate task the runtime is able to notice that the requested, and current, executor are actually the same (`MainActor`) and therefore execute the task _immediately_ on the caller's executor _and_ with the expected `@MainActor` isolation, which is guaranteed to be correct:

```swift
@MainActor var counterUsual = 0
@MainActor var counterImmediate = 0

@MainActor 
func sayHelloOnMain() {
   sayHello() // call synchronous function from @MainActor
}

// synchronous function
func sayHello() {
  // We are "already on" the main actor
  MainActor.assertIsolated()
  
  // Performs an enqueue and will execute task "later"
  Task { @MainActor in 
    counterUsual += 1 
  }
  // At this point (in this specific example), `counterUsual` is still 0. 
  // We did not "give up" the main actor executor, so the new Task could not execute yet.
 
  // Execute the task immediately on the calling context (!)
  Task.immediate { @MainActor in
    counterImmediate += 1
  }
  // At this point (in this specific cexample), 
  // `counterImmediate` is guaranteed to == 1!
}
```

The difference between the use of `Task.init` and `Task.immediate` is _only_ in the specific execution ordering semantics those two tasks exhibit.

Because we are dynamically already on the expected executor, the immediate task will not need to enqueue and "run later" the new task, but instead will take over the calling executor, and run the task body immediately (up until the first suspension point).

This can have importand implications about the observed order of effects and task execution, so it is important for developers to internalize this difference in scheduling semantics.

If the same `sayHello()` function were to be invoked from some execution context _other than_ the main actor, both tasks–which specify the requested isolation to be `@MainActor`–will perform the usual enqueue and "run later":

```swift
@MainActor var counterUsual = 0
@MainActor var counterImmediate = 0

actor Caplin {
  func sayHelloFromCaplin() {
     sayHello() // call synchronous function from Caplin
  }
}

func sayHello() {
  Task { @MainActor in // enqueue, "run later"
    counterUsual += 1 
  }
  Task.immediate { @MainActor in // enqueue, "run later"
    counterImmediate += 1
  }

  // at this point, no guarantees can be made about the values of the `counter` variables
}
```

This means that a `Task.immediate` can be used to opportunistically attempt to "run immediately, if the caller matches my required isolation, otherwise, enqueue and run the task later". Which is a semantic that many developers have requested in the past, most often in relation to the `MainActor`. 

The same technique of specifying a required target isolation may be used with the new TaskGroup APIs, such as `TaskGroup/addImmediateTask`.

### Interaction with `Actor/assumeIsolated`

In [SE-0392: Custom Actor Executors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md) we introduced the ability to dynamically recover isolation information using the `Actor/assumeIsolated` API. It can be used to dynamically recover the runtime information about whether we are executing on some specific actor.

The `assumeIsolated` shares some ideas with `Task/immediate` however it is distinctly different. For example, while both APIs can effectively be used to "notice we are running on the expected actor, and therefore perform some work on its context". However, `assumeIsolated` does _not_ create a new asynchronous context, while `Task.immediate` does:

```swift
@MainActor
var state: Int = 0 

@MainActor
func asyncMainActorMethod() async { } 
  
func synchronous() {
  // assert that we are running "on" the MainActor, 
  // and therefore can access its isolated state:
  MainActor.assumeIsolated { 
    num +=1 // ✅ ok
    
    await asyncMainActorMethod() // ❌ error: 'async' call in a function that does not support concurrency
  }
  
}
```

We can compose `assumeIsolated` with `Task.immediate` to both assert that the current execution context must the the expected actor, and form a new asynchronous task that will immediately start on that actor:

```swift
func alwaysCalledFromMainActor() { // we know this because e.g. documentation, but the API wasn't annotated
  MainActor.assumeIsolated { // @MainActor isolated
    assert(num == 0)
    Task.immediate { // @MainActor isolated
      num +=1 // ✅ ok
      assert(num == 1) // since we are guaranteed nothing else executed since the 'num == 0' assertion
                             
      await asyncMainActorMethod() // ✅ ok
    }
  }
}
```

The immediately started task will not suspend and context switch until any of the called async methods does. For example, we are guaranteed that there will be no interleaved code execution between the `assert(num == 0)` in our example, and the  `num += 1` inside the synchronously started task.

After the suspension point though, there may have been other tasks executed on the main actor, and we should check the value of `num` again.

### Immediate child tasks

Immediate child tasks can be created using the various `*TaskGroup/addImmediateTask*` methods, they behave similarily to their normal structured child task API counterparts (`*TaskGroup/addTask*`).

Child tasks, including immediate child tasks, do not infer their isolation from the enclosing context, and by default are `nonisolated`.

```swift
actor Worker {
  func workIt(work: Work) async {
    await withDiscardingTaskGroup { 
      group.addImmediateTask { // nonisolated
        work.synchronousWork()
      }
    }
  }
}
```

While the immediate task in the above example is indeed `nonisolated` and does not inherit the Worker's explicit isolation, it will start out immediately on the Worker's executor. Since this example features _no suspension points_ in the task group's child tasks, this is effectively synchronously going to execute those child tasks on the caller (`self`). In other words, this is not performing any of its work in parallel.

If we were to modify the work to have potential suspension points like so:

```swift
actor Worker {
  func workIt(work: Work) async {
    await withDiscardingTaskGroup { 
      group.addImmediateTask { // nonisolated
        // [1] starts on caller immediately
        let partialResult = await work.work() // [2] actually suspends
        // [3] resumes on global executor (or task executor, if there was one set)
        work.moreWork(partialResult)
      }
    }
  }
}
```

The actual suspension happening in the `work()` call, means that this task group actually would exhibit some amount of concurrent execution with the calling actor -- the remainder between `[2]` and `[3]` would execute on the global concurrent pool -- concurrently to the enclosing actor.

Cancellation, task locals, priority escalation, and any other structured concurrency semantics remain the same for structured child tasks automatically for unstructured tasks created using the `Task/immediate[Detached]` APIs.

The only difference in behavior is where these synchronously started tasks _begin_ their execution.

## Source compatibility

This proposal is purely additive, and does not cause any source compatibility issues.

## ABI compatibility

This proposal is purely ABI additive.

## Alternatives considered

### Dynamically asserting isolation correctness

An important use case of this API is to support calling into an actor isolated context when in a synchronous function that is dynamically already running on that actor. This situation can occur both with instance actors and global actors, however the most commonly requested situation where this shows up is synchronous handler methods in existing frameworks, and which often may have had assumptions about the main thread, and did not yet annotate their API surface with @MainActor annotations.

It would be possible to create a _dynamically asserting_ version of `Task.immediate`, which does handle the happy path where indeed we "know" where we're going to be called quite well, but gives a *false sense of security* as it may crash at runtime, in the same way the `Actor/preconditionIsolated()` or `Actor/assumeIsolated` APIs do. We believe we should not add more such dynamically crashing APIs, but rather lean into the existing APIs and allow them compose well with any new APIs that should aim to complement them.

The dynamically asserting version would be something like this:

```swift
// Some Legacy API: documented to be invoked on main thread but NOT @MainActor annotated and NOT 'async'
func onSomethingHappenedAlwaysOnMainThread(something: Something) {
  // we "know" we are on the MainActor, however this is a legacy API that is not an 'async' method
  // so we cannot call any other async APIs unless we create a new task.
  Task.immediate { @MainActor in 
    await showThingy()
  }
}

func onSomethingHappenedSometimesOnMainThread(something: Something) {
  // 💥 Must assert at runtime if not on main thread
  Task.immediate { @MainActor in 
    await showThingy()
  }
}

func showThingy() async { ... } 
```

This implementation approach yields safe looking code which unfortunately may have to assert at runtime, rather than further improve the compile time safety properties of Swift Concurrency.

> See *Future Directions: Dynamically "run synchronously if in right context, otherwise enqueue as usual"* for a future direction that would allow implementing somewhat related APIs in a more elegant and correct way.

### Banning from use in async contexts (@available(*, noasync))

During earlier experiments with such API it was considered if this API should be restricted to only non-async contexts, by marking it `@available(*, noasync)` however it quickly became clear that this API also has specific benefits which can be used to ensure certain ordering of operations, which may be useful regardless if done from an asynchronous or synchronous context.

## Future Directions

### Partial not-sending closure semantics

The isolation rules laid out in this proposal are slightly more conservative than necessary. 

Technically one could make use of the information that the part of the closure up until the first potential suspension point is definitely running synchronously, and therefore even access state that would not be able to be accessed even under region isolation analysis rules.

We believe that most common situations will be handled well enough by region analysis, and sending closures, however this is a future direction that could be explored if it becomes more apparent that implementing these more complex semantics would be very beneficial.

For example, such analysis could enable the following:

```swift
actor Caplin {  
  var num: Int = 0
  
  func check() {
    Task.immediateDetached {
      num += 1 // could be ok; we know we're synchronously executing on caller
      
      try await Task.sleep(for: .seconds(1))
      
      num += 1 // not ok anymore; we're not on the caller context anymore
    }
    
    num += 1 // always ok
  }
}
```

### Implementation detail: Expressing closure isolation tied to function parameter: `@isolated(to:)`

The currently proposed API is working within the limitations of what is expressible in today's isolation model. It would be beneficial to be able to express the immediate API if we could spell something like "this closure must be isolated to the same actor as the calling function" which would allow for the following code:

```swift
@MainActor
func test() { 
  Task.immediate { /* inferred to be @MainActor */ 
    num += 1
  }
}

@MainActor var num = 0
```

The way to spell this in an API could be something like this:

```swift
public static func immediate(
  ...
  isolation: isolated (any Actor)? = #isolation,
  operation: @escaping @isolated(to: isolation) sending async throws(Failure) -> Success,
) -> Task<Success, Failure>
```

The introduction of a hypothetical  `@isolated(to:)` paired with an `isolated` `#isolation` defaulted actor parameter, would allow us to express "the *operation* closure statically inherits the exact same isolation as is passed to the isolation parameter of the `immediate` method". This naturally expresses the semantics that the `immediate` is offering, and would allow to _stay_ on that isolation context after resuming from the first suspension inside the operation closure.

Implementing this feature is a large task, and while very desirable we are not ready yet to commit to implementing it as part of this proposal. If and when this feature would become available, we would adopt it in the `immediate` APIs.

### Changelog

- Moved the alternative considered of "attempt to run immediately, or otherwise just enqueue as usual" into the proposal proper
