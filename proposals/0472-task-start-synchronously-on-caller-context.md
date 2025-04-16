# Starting tasks synchronously from caller context

* Proposal: [SE-0472](0472-task-start-synchronously-on-caller-context.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Returned for revision**
* Implementation: https://github.com/swiftlang/swift/pull/79608
* Review: ([pitch](https://forums.swift.org/t/pitch-concurrency-starting-tasks-synchronously-from-caller-context/77960/)) ([review](https://forums.swift.org/t/se-0472-starting-tasks-synchronously-from-caller-context/78883)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0472-starting-tasks-synchronously-from-caller-context/79311))

## Introduction

Swift Concurrency's primary means of entering an asynchronous context is creating a Task (structured or unstructured), and from there onwards it is possible to call asynchronous functions, and execution of the current work may _suspend_.

Entering the asynchronous context today incurs the creating and scheduling of a task to be executed at some later point in time. This initial delay may be wasteful for tasks which perform minimal or no (!) work at all.

This initial delay may also be problematic for some situations where it is known that we are executing on the "right actor" however are *not* in an asynchronous function and therefore in order to call some different asynchronous function we must create a new task and introduce subtle timing differences as compared to just being able to call the target function–which may be isolated to the same actor we're calling from–immediately.

## Motivation

Today, the only way to enter an asynchronous execution context is to create a new task which then will be scheduled on the global concurrent executor or some specific actor the task is isolated to, and only once that task is scheduled execution of it may begin.

This initial scheduling delay can be problematic in some situations where tight control over execution is required. While for most tasks the general semantics are a good choice–not risking overhang on the calling thread–we have found through experience that some UI or performance sensitive use-cases require a new kind of semantic: starting on the calling context, until a suspension occurs, and only then hopping off to another executor once the task is resumed from the suspension.

This can be especially beneficial for tasks, which *may run to completion very quickly and without ever suspending.* 

A typical situation where this new API may be beneficial often shows up with @MainActor code, such as:

```swift
@MainActor var thingsHappened: Int

@MainActor func onThingHappened(context: Context) { 
  synchronousFunction()
}

func asyncUpdateThingsHappenedCounter() async {
  // for some reason this function MUST be async
  thingsHappened += 1
}

func synchronousFunction() {
  // we know this executes on the MainActor, and can assume so:
  MainActor.assumeIsolated { 
    // we cannot call the asynchronous function asyncUpdateThingsHappenedCounter though!
  }
  
  // Proposed API:
  Task.startSynchronously {
      // Now we CAN call the asynchronous function below:
    await asyncUpdateThingsHappenedCounter()
  }
}
```

The above example showcases a typical situation where this new API can be useful. While `assumeIsolated` gives us a specific isolation, it still would not allow us to call arbitrary async functions, as we are still in a synchronous context.

The proposed `Task.startSynchronously` API forms an async context on the calling thread/task/executor, and therefore allows us to call into async code, at the risk of overhanging on the calling executor. So while this should be used sparingly, it allows entering an asynchronous context *synchronously*.

## Proposed solution

We propose the introduction of a new family of Task creation APIs, collectively called "start synchronously", which create a Task and use the calling thread to execute the task's "first synchronous section" right until the task suspends for the first time. 

After the suspension happens, execution yields back to an appropriate executor, and does not continue to use the caller's thread anymore.

The canonical example for using this new API is using an unstructured task like this:

```swift
func synchronous() { // synchronous function
  // executor / thread: "T1"
  let task: Task<Void, Never> = Task.startSynchronously {
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

The task created by the `startSynchronously` function begins running immediately _on the calling executor (and thread)_ without any scheduling delay. This new task behaves generally the same as any other unstructured task, it gets a copy of the outer context's task locals, and uses the surrounding context's base priority as its base priority as well.

Since the task started running immediately, we're able to perform some calls immediately inside it, and potentially return early.

If a potential suspension point does not actually suspend, we still continue running on the calling context. For example, if potential suspension point `#1` did not suspend, we still continue running synchronously until we reach potential suspension point `#2` which for the sake of discussion let's say does suspend. At this point the calling thread continues executing the scope that created the unstructured task. 

> You can refer to the `(N)` numbers in the above snippet to follow the execution order of this example execution. Specifically, once the execution reaches (3) the calling thread stops executing the unstructured task, and continues executing at (4). Eventually, when the unstructured task is resumed, it gets woken up at (5) and continues running on some other executor and/or thread.

## Detailed design

We propose the introduction of a family of "start synchronously" task creation APIs.

The most frequent use of this API is likely going to be the unstructured task one. This is because we are able to enter an asynchronous context from a synchronous function using it:

```swift
extension Task {
  
    @discardableResult
    public static func startSynchronously(
        // SE-0469's proposed 'name: String? = nil' would be here if accepted
        priority: TaskPriority? = nil,
        executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
        operation: sending @escaping async throws(Failure) -> Success
    ) -> Task<Success, Failure>
  
    @discardableResult
    public static func startSynchronouslyDetached(
        // SE-0469's proposed 'name: String? = nil' would be here if accepted
        priority: TaskPriority? = nil,
        executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
        operation: sending @escaping async throws(Failure) -> Success
    ) -> Task<Success, Failure>
}
```

We also offer the same API for all kinds of task groups. These create child tasks, which participate in structured concurrency as one would expect of tasks created by task groups.

```swift
extension (Throwing)TaskGroup {
  
  // Same add semantics as 'addTask'.
  func startTaskSynchronously(
    // SE-0469's proposed 'name: String? = nil' would be here
    priority: TaskPriority? = nil,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    operation: sending @escaping () async throws -> ChildTaskResult
  )
  
  // Same add semantics as 'addTaskUnlessCancelled'.
  func startTaskSynchronouslyUnlessCancelled(
    // SE-0469's proposed 'name: String? = nil' would be here
    priority: TaskPriority? = nil,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    operation: sending @escaping () async throws -> ChildTaskResult
  )
}

extension (Throwing)DiscardingTaskGroup {
  // Same add semantics as 'addTask'.
  func startTaskSynchronously(
    // SE-0469's proposed 'name: String? = nil' would be here
    priority: TaskPriority? = nil,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    operation: sending @escaping () async throws -> ChildTaskResult
  )
  
  // Same add semantics as 'addTaskUnlessCancelled'.
  func startTaskSynchronouslyUnlessCancelled(
    // SE-0469's proposed 'name: String? = nil' would be here
    priority: TaskPriority? = nil,
    executorPreference taskExecutor: (any TaskExecutor)? = nil,
    operation: sending @escaping () async throws -> ChildTaskResult
  )
}
```

The `startTaskSynchronously` function mirrors the functionality of `addTask`, unconditionally adding the task to the group, while the `startTaskSynchronouslyUnlessCancelled` mirrors the `addTaskUnlessCancelled` which only adds the task to the group if the group (or task we're running in, and therefore the group as well) are not cancelled.

### Isolation rules

Due to the semantics of "starting on the caller context", the isolation rules of the closure passed to `startSynchronously` need to be carefully considered.

For example, the following example would not be safe, as unlike `Task.init` the task does not actually immediately become isolated to the isolation of its closure:

```swift
@MainActor var counter: Int = 0

func sayHello() {
  Task { @MainActor in // ✅ ok
    counter += 1 // we're isolated to the main actor immediately and may modify its state
  }
  
  Task.startSynchronously { @MainActor in // ❌ unsafe, must be compile time error
    counter += 1 // Not actually running on the main actor at this point (!)
  }
}
```

The isolation rules for the `startSynchronously` family of APIs need to account for this synchronous "first part" of the execution. We propose the following set of rules to make this API concurrency-safe:

- The operation closure is `sending`.
- The operation closure may only specify an isolation (e.g. `{ @MainActor in }`), if and only if already statically contained within the same isolation context.

This allows for the following pattern, where we can enter an asynchronous task context, from a synchronous function, that is _known_ to be isolated to the main actor already:

```swift
@MainActor var counter: Int = 0

func asyncUpdateCounter() async { counter += 1 }

@MainActor 
func sayHelloOnMain() {
  Task.startSynchronously { @MainActor in // ✅ ok, caller isolation is also @MainActor
    await asyncUpdateCounter()
  }
  
  Task.startSynchronously { @OtherGlobalActor in // ❌ error: MainActor != OtherGlobalActor
    await asyncUpdateCounter()
  }
}
```

Task executors do not influence the static isolation properties of code, and thus have no impact on the isolation semantics of these APIs. In general, task executors are orthogonal to actor isolation, and while they can influence which actual executor a default actor or global async function would use to execute some piece of code they have no impact on isolation properties and therefore safety properties of a piece of code.

### Interaction with `Actor/assumeIsolated`

In [SE-0392: Custom Actor Executor](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md) we introduced the ability to dynamically recover isolation information using the `assumeIsolated` API. It can be used to dynamically recover the runtime information about whether we are executing on some specific actor.

The `assumeIsolated` shares some ideas with `startSynchronously` however it is distinctly different. For example, while both APIs can effectively be used to "notice we are running on the expected actor, and therefore perform some work on its context". However, `assumeIsolated` does _not_ create a new asynchronous context, while `Task.startSynchronously` does:

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

We can compose assumeIsolated with `startSynchronously` to ensure we synchronously start a task on the MainActor if we know we are already running on it, like this:

```swift
func alwaysCalledFromMainActor() { // we know this because e.g. documentation, but the API wasn't annotated
  MainActor.assumeIsolated { // @MainActor isolated
    assert(num == 0)
    Task.startSynchronously { @MainActor in
      num +=1 // ✅ ok
      assert(num == 1) // since we are guaranteed nothing else executed since the 'num == 0' assertion
                             
      await asyncMainActorMethod() // ✅ ok
    }
  }
}
```

The synchronously started task will not suspend and context switch until any of the called async methods does. For example, we are guaranteed that there will be no interleaved code execution between the `assert(num == 0)` in our example, and the  `num += 1` inside the synchronously started task.

After the suspension point though, there may have been other tasks executed on the main actor, and we should check the value of `num` again.

### Structured concurrency semantics

Synchronously started tasks behave exactly the same as their fully asynchronous equivalents. 

In short, cancellation, and priority escalation remains automatic for structured tasks created using TaskGroup APIs, however they do not propagate automatically for unstructured tasks created using the `Task.startSynchronously[Detached](...)` APIs. Task locals and base priority also functions the same way as usual.

The only difference in behavior is where these synchronously started tasks _begin_ their execution.

## Source compatibility

This proposal is purely additive, and does not cause any source compatibility issues.

## ABI compatibility

This proposal is purely ABI additive.

## Alternatives considered

### Dynamically asserting isolation correctness

An important use case of this API is to support calling into an actor isolated context when in a synchronous function that is dynamically already running on that actor. This situation can occur both with instance actors and global actors, however the most commonly requested situation where this shows up is synchronous handler methods in existing frameworks, and which often may have had assumptions about the main thread, and did not yet annotate their API surface with @MainActor annotations.

It would be possible to create a _dynamically asserting_ version of `Task.startSynchronously`, which does handle the happy path where indeed we "know" where we're going to be called quite well, but gives a *false sense of security* as it may crash at runtime, in the same way the `Actor/preconditionIsolated()` or `Actor/assumeIsolated` APIs do. We believe we should not add more such dynamically crashing APIs, but rather lean into the existing APIs and allow them compose well with any new APIs that should aim to complement them.

The dynamically asserting version would be something like this:

```swift
// Some Legacy API: documented to be invoked on main thread but NOT @MainActor annotated and NOT 'async'
func onSomethingHappenedAlwaysOnMainThread(something: Something) {
  // we "know" we are on the MainActor, however this is a legacy API that is not an 'async' method
  // so we cannot call any other async APIs unless we create a new task.
  Task.startSynchronously { @MainActor in 
    await showThingy()
  }
}

func onSomethingHappenedSometimesOnMainThread(something: Something) {
  // 💥 Must assert at runtime if not on main thread
  Task.startSynchronously { @MainActor in 
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
    Task.startSynchronouslyDetached {
      num += 1 // could be ok; we know we're synchronously executing on caller
      
      try await Task.sleep(for: .seconds(1))
      
      num += 1 // not ok anymore; we're not on the caller context anymore
    }
    
    num += 1 // always ok
  }
}
```

### Dynamically "run synchronously if in right context, otherwise enqueue as usual"

The proposed `startSynchronously` API is a tool to be used in performance and correctness work, and any "may sometimes run synchronously, it depends" is not a good solution to the task at hand. Because of that, we aim for this API to provide the _predictable_ behavior of running synchronously on the caller, without impacting the isolation, that can compose naturally with `assumeIsolated` that can recover dynamic into static isolation information.

For example, we'll be able to build an API that composes the proposed `startSynchronously` with a not yet proposed but under investigation `Task/isIsolated(to: some Actor) -> Bool` API in order to offer an API that implements the semantics that some developers have been asking for a while:

- if already dynamically isolated on the expected actor, run synchronously,
- if not, schedule a task to execute the same operation later.

Using a combination of (a) `Task/startSynchronously`, (b) `Actor/assumeIsolated`, and some form of boolean returning the not yet proposed (c) `isIsolated` (which would be a `Bool` returning equivalent of `assumeIsolated`), we will be able to build such function by composing those more fundamental concurrency operations:

```swift
func tryRunSynchronouslyOrAsynchronouslyOtherwise<T>(
  operation: sending @escaping () async -> Success
) -> Task<Success, Failure> {
  guard let actor = operation.isolation else {
    // no specific isolation, just run async
    return Task { try await operation() }
  }
  
  if Task.__current.__isIsolated(to: actor) { // (c) !!! does not exist yet !!!
    // we definitely are executing on 'actor'
    return actor.assumeIsolated { // (b) guaranteed to not crash
      // recovered static isolation information about 'actor'
      // (a) use startSynchronously with specific actor isolation
      return Task.runSynchronously { 
          [isolated actor] in // !! does not exist yet (closure isolation control) !!
        try await operation()
      }
    }
  } else {
    // we are not isolated to 'actor' and therefore must schedule a normal unstructured task
    return Task { try await operation() }
  }
}
```

Or even better we could build the same API with structured concurrency:

```swift
func tryRunSynchronouslyOrAsynchronouslyOtherwise<T>(
  operation: sending @escaping () async throws -> Success
) async rethrows -> Success { /* same, but use TaskGroup inside */ }
```

### Expressing closure isolation tied to function parameter: `@isolated(to:)`

The currently proposed API is working within the limitations of what is expressible in today's isolation model. It would be beneficial to be able to express the startSynchronously API if we could spell something like "this closure must be isolated to the same actor as the calling function" which would allow for the following code:

```swift
@MainActor
func test() { 
  Task.startSynchronously { /* inferred to be @MainActor */ 
    num += 1
  }
}

@MainActor var num = 0
```

The way to spell this in an API could be something like this:

```swift
public static func startSynchronously(
  ...
  isolation: isolated (any Actor)? = #isolation,
  operation: @escaping @isolated(to: isolation) sending async throws(Failure) -> Success,
) -> Task<Success, Failure>
```

The introduction of a hypothetical  `@isolated(to:)` paired with an `isolated` `#isolation` defaulted actor parameter, would allow us to express "the *operation* closure statically inherits the exact same isolation as is passed to the isolation parameter of the startSynchronously method". This naturally expresses the semantics that the startSynchronously is offering, and would allow to _stay_ on that isolation context after resuming from the first suspension inside the operation closure.

Implementing this feature is a large task, and while very desirable we are not ready yet to commit to implementing it as part of this proposal. If and when this feature would become available, we would adopt it in the startSynchronously APIs.
