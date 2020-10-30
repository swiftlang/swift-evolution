# Structured concurrency

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [John McCall](https://github.com/rjmccall), [Joe Groff](https://github.com/jckarter), [Doug Gregor](https://github.com/DougGregor), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

[`async`/`await`](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md) is a language mechanism for writing natural, efficient asynchronous code. Asynchronous functions (introduced with `async`) can give up the thread on which they are executing at any given suspension point (marked with `await`), which is necessary for building highly-concurrent systems.

However, the `async`/`await` proposal does not introduce concurrency *per se*: ignoring the suspension points within an asynchronous function, it will execute in essentially the same manner as a synchronous function. This proposal introduces support for [structured concurrency](https://en.wikipedia.org/wiki/Structured_concurrency) in Swift, enabling concurrency execution of asynchronous code with a model that is ergonomic, predictable, and admits efficient implementation.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

For a simple example, let's make dinner, asynchronously:

```swift
func chopVegetables() async throws -> [Vegetable] { ... }
func marinateMeat() async -> Meat { ... }
func preheatOven(temperature: Double) async throws -> Oven { ... }

// ...

func makeDinner() async throws -> Meal {
  let veggies = await try chopVegetables()
  let meat = await marinateMeat()
  let oven = await try preheatOven(temperature: 350)

  let dish = Dish(ingredients: [veggies, meat])
  return await try oven.cook(dish, duration: .hours(3))
}
``` 

Each step in our dinner preparation is an asynchronous operation, so there are numerous suspension points. While waiting for the vegetables to be chopped, `makeDinner` won't block a thread: it will suspend until the vegetables are available, then resume. Presumably, many dinners could be in various stages of preparation, with most suspended until their current step is completed.

However, even though our dinner preparation is asynchronous, it is still *sequential*. It waits until the vegetables have been chopped before starting to marinate the meat, then waits again until the meat is ready before preheating the oven. Our hungry patrons will be very hungry indeed by the time dinner is finally done.

To make dinner preparation go faster, we need to perform some of the tasks in *parallel*, but at the same time, we need to do so with some form of structure. Not all tasks can be just launched in parallel, hoping for the best. In order to properly deal with parallelism, we need structure, and that structure is *concurrency*. The vegetables can be chopped at the same time as the meat is marinating and the oven is preheating. We can be combining the ingredients into the dish while the oven preheats. But we cannot prepare the dish before it's individual parts (the veggies and meat) are prepared. 

This proposal aims to provide the necessary tools to describe such task dependencies and allow for "overlapping" *parallel* execution the steps, we can cook our dinner faster.

## Proposed solution

Structured concurrency provides an ergonomic way to introduce concurrency into asynchronous functions. Every asynchronous function runs as part of an asynchronous *task*, which is the analogue of a thread. Structured concurrency allows a task to easily create child tasks, which perform some work on behalf of---and concurrently with---the task itself.

### Child tasks
This proposal introduces an easy way to create child tasks with `async let`:

```swift
func makeDinner() async throws -> Meal {
  async let veggies = try chopVegetables()
  async let meat = marinateMeat()
  async let oven = try preheatOven(temperature: 350)

  let dish = Dish(ingredients: await [veggies, meat])
  return await try oven.cook(dish, duration: .hours(3))
}
``` 

`async let` is similar to a `let`, in that it defines a local constant that is initialized by the expression on the right-hand side of the `=`. However, it differs in that the initializer expression is evaluated in a separate, concurrently-executing child task. On completion, the child task will initialize the variables in the `async let` and complete.

Because the main body of the function executes concurrently with its child tasks, it is possible that `makeDinner` will reach the point where it needs the value of an `async let` (say, `veggies`) before that value has been produced. To account for that, reading a variable defined by an `async let` is treated as a suspension point, and therefore must be marked with `await`. The task will suspend until the child task has completed initialization of the variable, and then resume.

One can think of `async let` as introducing a (hidden) future, which is created at the point of declaration of the `async let` and whose value is retrieved at the `await`. In this sense, `async let` is syntactic sugar to futures.

However, child tasks in the proposed structured-concurrency model are (intentionally) more restricted than general-purpose futures. Unlike in a typical futures implementation, a child task does not persist beyond the scope in which is was created. By the time the scope exits, the child task must either have completed, or it will be implicitly cancelled. This structure both makes it easier to reason about the concurrent tasks that are executing within a given scope, and also unlocks numerous optimization opportunities for the compiler and runtime. 

Bringing it back to our example, note that the `chopVegetables()` function might throw an error if, say, there is an incident with the kitchen knife. That thrown error completes the child task for chopping the vegetables. The error will then be propagated out of the `makeDinner()` function, as expected. On exiting the body of the `makeDinner()` function, any child tasks that have not yet completed (marinating the meat or preheating the oven, maybe both) will be automatically cancelled.

### Nurseries

The `async let` construct makes it easy to create a set number of child tasks and associate them with variables. However, the construct does not work as well with dynamic workloads, where we don't know the number child tasks we will need to create because (for example) it is dependent on the size of a data structure. For that, we need a more dynamic construct: a task *nursery*.

A nursery defines a scope in which one can create new child tasks programmatically. As with all child tasks, the child tasks within the nursery must complete when the scope exits or they will be implicitly cancelled. Nurseries also provide utilities for working with the child tasks, e.g., by waiting until the next child task completes.

To stretch our example even further, let's consider our `chopVegetables()` operation, which produces an array of `Vegetable` values. With enough cooks, we could chop our vegetables even faster if we divided up the chopping for each kind of vegetable. 

Let's start with a sequential version of `chopVegetables()`:

```swift
/// Sequentially chop the vegetables.
func chopVegetables() async throws -> [Vegetable] {
  var veggies: [Vegetable] = gatherRawVeggies()
  for i in veggies.indices {
    veggies[i] = await try veggies[i].chopped()
  }
  return veggies
}
```

Introducing `async let` into the loop would not produce any meaningful concurrency, because each `async let` would need to complete before the next iteration of the loop could start. To create child tasks programmatically, we introduce a new nursery scope via `withNursery`:

```swift
/// Concurrently chop the vegetables.
func chopVegetables() async throws -> [Vegetable] {
  // Create a task nursery where each task produces (Int, Vegetable).
  Task.withNursery(resultType: (Int, Vegetable).self) { nursery in 
    var veggies: [Vegetable] = gatherRawVeggies()
    
    // Create a new child task for each vegetable that needs to be 
    // chopped.
    for i in rawVeggies.indices {
      await try nursery.add { 
        (i, veggies[i].chopped())
      }
    }

    // Wait for all of the chopping to complete, slotting each result
    // into its place in the array as it becomes available.
    while let (index, choppedVeggie) = await try nursery.next() {
      veggies[index] = choppedVeggie
    }
    
    return veggies
  }
}
```

The `withNursery(resultType:body:)` function introduces a new scope in which child tasks can be created (using the nursery's `add(_:)` method). The `next()` method waits for the next child task to complete, providing the result value from the child task. In our example above, each child task carries the index where the result should go, along with the chopped vegetable.

As with the child tasks created by `async let`, if the closure passed to `withNursery` exits without having completed all child tasks, any remaining child tasks will automatically be cancelled.

### Detached tasks

Thus far, every task we have created is a child task, whose lifetime is limited by the scope in which is created. This does not allow for new tasks to be created that outlive the current scope.

The `runDetached` operation creates a new task. It accepts a closure, which will be executed as the body of the task. Here, we create a new, detached task to make dinner:

```swift
let dinnerHandle = Task.runDetached {
  await makeDinner()
}
```

The result of `runDetached` is a task handle, which can be used to retrieve the result of the operation when it completes (via `get()`) or cancel the task if the result is no longer desired (via `cancel()`). Unlike child tasks, detached tasks aren't cancelled even if there are no remaining uses of their task handle, so `runDetached` is suitable for operations for which the program does not need to observe completion.

## Detailed design

### Tasks

A task can be in one of three (**TODO**: four?) states:

* A **suspended** task has more work to do but is not currently running.  
    - It may be **schedulable**, meaning that it’s ready to run and is just waiting for the system to instruct a thread to begin executing it, 
    - or it may be **waiting** on some external event before it can become schedulable.
* A **running** task is currently running on a thread.  
    - It will run until it either returns from its initial function (and becomes completed) or reaches a suspension point (and becomes suspended).  At a suspension point, it may become immediately schedulable if, say, its execution just needs to change actors.
* A **completed** task has no more work to do and will never enter any other state.  
    - Code can wait for a task to become completed in various ways, most notably by [`await`](nnnn-async-await.md)-ing on it.

The way we talk about execution for tasks and asynchronous functions is more complicated than it is for synchronous functions.  An asynchronous function is running as part of a task.  If the task is running, it and its current function are also running on a thread.

Note that, when an asynchronous function calls another asynchronous function, we say that the calling function is suspended, but that doesn’t mean the entire task is suspended.  From the perspective of the function, it is suspended, waiting for the call to return.  From the perspective of the task, it may have continued running in the callee, or it may have been suspended in order to, say, change to a different execution context.

Tasks serve three high-level purposes:

* They carry scheduling information, such as the task's priority.
* They serve as a handle through which the operation can be cancelled.
* They can carry user-provided task-local data.

At a lower level, the task allows the implementation to optimize the allocation of local memory, such as for asynchronous function contexts.  It also allows dynamic tools, crash reporters, and debuggers to discover how a function is being used.

### Child tasks

An asynchronous function can create a child task.  Child tasks inherit some of the structure of their parent task, including its priority, but can run concurrently with it.  However, this concurrency is bounded: a function that creates a child task must wait for it to end before returning.  This structure means that functions can locally reason about all the work currently being done for the current task, anticipate the effects of cancelling the current task, and so on.  It also makes spawning the child task substantially more efficient.

Of course, a function’s task may itself be a child of another task, and its parent may have other children; a function cannot reason locally about these.  But the features of this design that apply to an entire task tree, such as cancellation, only apply “downwards” and don’t automatically propagate upwards in the task hierarchy, and so the child tree still can be statically reasoned about.  If child tasks did not have bounded duration and so could arbitrarily outlast their parents, the behavior of tasks under these features would not be easily comprehensible. 

### Partial tasks

The execution of a task can be seen as a succession of periods where the task was running, each of which ends at a suspension point or — finally — at the completion of the task.  These periods are called partial tasks.  Partial tasks are the basic units of schedulable work in the system.  They are also the primitive through which asynchronous functions interact with the underlying synchronous world.  For the most part, programmers should not have to work directly with partial tasks unless they are implementing a custom executor.

### Executors

An executor is a service which accepts the submission of _partial tasks_ and arranges for some thread to run them. The system assumes that executors are reliable and will never fail to run a partial task. 

An asynchronous function that is currently running always knows the executor that it's running on.  This allows the function to avoid unnecessarily suspending when making a call to the same executor, and it allows the function to resume executing on the same executor it started on.

An executor is called _exclusive_ if the partial tasks submitted to it will never be run concurrently.  (Specifically, the partial tasks must be totally ordered by the happens-before relationship: given any two tasks that were submitted and run, the end of one must happen-before the beginning of the other.) Executors are not required to run partial tasks in the order they were submitted; in fact, they should generally honor task priority over submission order.

Swift provides a default executor implementation, but both actor classes and global actors can suppress this and provide their own implementation.

Generally end-users need not interact with executors directly, but rather use them implicitly by invoking actors and functions which happen to use executors to perform the invoked asynchronous functions.

### Task priorities
Any task is associated with a specific `Task.Priority`.

Task priority may inform decisions an `Executor` makes about how and when to schedule tasks submitted to it. An executor may utilize priority information to attempt running higher priority tasks first, and then continuing to serve lower priority tasks.

The exact semantics of how priority is treated are left up to each platform and specific `Executor` implementation.

Child tasks automatically inherit their parent task's priority. Detached tasks do not inherit priority (or any other information) because they semantically do not have a parent task.

```swift
extension Task {
  public static func currentPriority() async -> Priority { ... }

  public struct Priority: Comparable {
    public static let `default`: Task.Priority
    /* ... */
  }
}
```

> **TODO**: Define the details of task priority; It is likely to be a concept similar to Darwin Dispatch's QoS; bearing in mind that priority is not as much of a thing on other platforms (i.e. server side Linux systems).

One of the ways to declare a priority level for a task is to pass it to `Task.runDetached(priority:operation:)` when starting a top-level task. All tasks started from within this task will inherit this task's priority since they would be its child tasks. 

This means that, semantically, the "UI Thread" can be represented as a top-level *UI Task* which was started as detached with the `.ui` priority, and all other tasks which need to run on as children of the UI task, will inherit its priority. In practice this will likely be reflected by a global `UIActor` (see [global actors](nnnn-actors.md) in the actors proposal) which is designated to run on an UI thread assigned `Executor` which sets tasks it uses to use the UI priority, thus handling propagation of priority from tasks started from the UI actor itself.

#### Priority Escalation
In some situations the priority of a task must be elevated (or "escalated", "raised"):

- if a `Task` running on behalf of an actor, and a new higher-priority task is enqueued to the actor, its current task must be temporarily elevated to the priority of the enqueued task, in order to allow the new task to be processed at--effectively-- the priority it was enqueued with.
    - this DOES NOT affect `Task.currentPriority()`.
- if a task is created with a `Task.Handle`, and a higher-priority task calls the `await try handle.get()` function the priority of this task must be permanently increased until the task completes.
    - this DOES affect `Task.currentPriority()`.

### Cancellation

A task can be cancelled asynchronously by any context that has a reference to a task or one of its parent tasks.  This can occur automatically, when a parent task throws yet still has pending `async let`s in flight, or some other task uses a handle to a task to `handle.cancel()` it explicitly.

The effect of cancellation on the task is cooperative and synchronous. Cancellation sets a flag in the task which marks it as having been cancelled; once this flag is set, it is never cleared. Executing a suspension point alone does not check cancellation. Operations running synchronously as part of the task can check this flag and are conventionally expected to throw a `CancellationError`. As with thrown errors, `defer` blocks are still executed when a task is cancelled, allowing code to introduce cleanup logic. 

We can illustrate cancellation with a version of the `chopVegetables()` function we saw previously:

```swift
func chopVegetables() async throws -> [Vegetable] {
  let carrot = try chop(Carrot()) // (1) throws UnfortunateAccidentWithKnifeError()!
  let onion = try chop(Onion()) // (2)
  
  return await try [carrot, onion] // (3)
}
```

We asynchronously start chopping up carrot and onion. However chopping the carrot immediately thows an error *(1)*, causing the error will be re-thrown on line *(3)*, where the `carrot` is being awaited on. At that point in time, chopping the onion might still be in progress, or it might not even have started yet. As we throw the error on line* (3)* the onion chopping task *(2)* is automatically cancelled!

We now know that the onion chopping task has been cancelled, however not how that task can react to it. As mentioned before in this section, cancellation is synchronous and co-operative, this means that the chop function has to check and act on the cancellation flag. It can do so by inspecting the task's cancelled status:

```
func chop(_ vegetable: Vegetable) async throws -> Vegetable {
  await try Task.checkCancellation() // automatically throws `CancellationError`
  // chop chop chop ...
  // ... 
  
  guard await !Task.isCancelled() else { 
    print("Canceled mid-way through chopping of \(vegetable)!")
    throw CancellationError() 
  } 
  // chop some more, chop chop chop ...
}
```

Usually cancellation aware tasks will preface their code with a call to `Task.checkCancellation()` which automatically throws if the task was already cancelled. Alternatively, an asynchronous function may at any point check the `isCancelled` flag and decide to act on it.

Note also that no information is passed to the task about why it was cancelled.  A task may be cancelled for many reasons, and additional reasons may accrue after the initial cancellation (for example, if the task fails to immediately exit, it may pass a deadline).  The goal of cancellation is to allow tasks to be cancelled in a lightweight way, not to be a secondary method of inter-task communication.

#### Cancelation with Deadlines
A very common use case for cancellation is cancelling tasks because they are taking too long to complete. This proposal introduces the concept of *deadlines* and enables them to cause a task to consider itself as cancelled if such deadline is exceeded.

We specifically use _deadlines_ ("point in time") as opposed to _timeouts_ ("number of seconds") to convey the information about when a task should be conssidered cancelled due to exceeding it's allocated time, because deadlines compose better and allow us to naturally form task trees where child tasks cannot exceed the deadline of their parent task.

To futher analyze the semantics of deadlines, let's extend our dinner preparation example with setting deadlines.

```swift
func makeDinnerWithDeadline() async throws -> Meal {
  await try Task.withDeadline(in: .hours(2)) { // (1)
    let veggies = await try chopVegetables()
    async let meat = Task.withDeadline(in: .minutes(30)) {  // (2)
      marinateMeat()
    }
    async let oven = try preheatOven(temperature: 350)
    
    let dish = Dish(ingredients: await [veggies, meat])
    return await try oven.cook(dish, duration: .hours(3))
  }
}

func cook(dish: Dish, duration: Duration) async throws -> Meal {
  await try checkCancellation() // (3)
  // ...
}
```

It is important to keep in mind that while a `Task.Deadline` is a _point in time_ we will usually express our deadline expectation using time intervals from "now." In the example above we set 2 nested deadlines. One, for four hours–for the entire dinner preparation task–and another one for thirty minutes for marinating the meat (otherwise the taste will be too intense!). We also specifically await on the chopped vegetables first before marinating the meat. This is to illustrate the following point: Imagine that chopping up the vegetables for some reason took 1 hour and 40 minutes (!). Now that we get to the meat marination step, we only have 20 minutes left in our outer deadline, yet we attempt to set a deadline in "30 minutes from now." If we had just set a timeout for 30 minutes here, we would be well past the outer deadline, instead–thanks to deadlines–the task automatically notices that the new _inner deadline_ of `now + 30 minutes` is actually greater than the _outer deadline_ and thus ignores it -- the outer deadline prevails and we will never exceed it.


Deadlines are also available to interact with programatically. For example the `cook(dish:duration:)` function knows exactly how much time it will take to complete. Just checking for cancellation at the beginning of the `cook()` function only means that the deadline has _not yet_ been exceeded. But since we know this process will take 3 hours, we need to know if we still have 3 more hours left to fit within the expected deadline! 

We can therefore update our cook function to proactively check if it has any chance to complete cooking within the deadline (or not, and we should just order a pizza 🍕):

```swift
func cook(dish: Dish, duration: Duration) async throws -> Meal {
  guard await Task.currentDeadline().remaining > duration else { 
    throw await NotEnoughTimeToPrepareMealError("Not enough time to prepare meal!")
  }
  // ...
}
```

Thanks to this, functions which have a known execution time, can proactively cancel themselfes before even starting the work which we know would miss the deadline in the end anyway.

### Child tasks with `async let`

Asynchronous calls do not by themselves introduce concurrent execution. However, `async` functions may conveniently request work to be run in a child task, permitting it to run concurrently, with an `async let`:

```swift
async let result = try fetchHTTPContent(of: url)
```

Any reference to a variable that was declared in an `async let` is a suspension point, equivalent to a call to an asynchronous function, so it must occur within an `await` expression. The initializer of the `async let` is considered to be enclosed by an implicit `await` expression.

If the initializer of the `async let` can throw an error, then each reference to a variable declared within that `async let` is considered to throw an error, and therefore must also be enclosed in one of `try`/`try!`/`try?`. 

One of the variables for a given `async let` must be awaited at least once along all execution paths (that don't throw an error) before it goes out of scope. For example:

```swift
{
  async let result = try fetchHTTPContent(of: url)
  if condition {
    let header = await try result.header
    // okay, awaited `result`
  } else {
    // error: did not await 'result' along this path. Fix this with, e.g.,
    //   _ = await try result
  }
}
```

If the scope of an `async let` exits with a thrown error, the child task corresponding to the `async let` is implicitly cancelled. If the child task has already completed, its result (or thrown error) is discarded.

> **Rationale**: The requirement to await a variable from each `async let` along all (non-throwing) paths ensures that child tasks aren't being created and implicitly cancelled during the normal course of execution. Such code is likely to be needlessly inefficient and should probably be restructured to avoid creating child tasks that are unnecessary.
 
### Child Tasks with Nurseries

In addition to `async let` this proposal also introduces an explicit `Nursery` type, which allows for fine grained scoping of tasks within such nursery. 

Tasks may be added dynamically to a nursery, meaning one may add a task for each element of a dynamically sized collection to a nursery and have them all be bound to the nursery lifecycle. This is in contrast to `async let` declarations which only allow for a statically known at compile time number of tasks to be declared.

```swift
extension Task {

  // Postcondition: if the body returns normally, the nursery is empty.
  // If it throws, all tasks in the nursery will be automatically cancelled.
  //
  // Do we have to add a different nursery type to accomodate throwing
  // tasks without forcing users to use Result?  I can't think of how that
  // could be propagated out of the callback body reasonably, unless we
  // commit to doing multi-statement closure typechecking.
  public static func withNursery<TaskResult, BodyResult>(
    resultType: TaskResult.Type,          
    body: (inout Nursery<TaskResult>) async throws -> BodyResult
  ) async rethrows -> BodyResult { ... } 
}
```

A nursery can be launched from any asychronous context, eventually returns a single value (the `BodyResult`). Tasks many be added to it dynamically, as we saw in the `chopVegetables` example in the *Proposed solution: Nurseries* section, and the nursery enforces awaiting for all tasks before it returns by asserting that is empty when returning the final result.

```swift
extension Task { 
  /* @unmoveable */ 
  public struct Nursery<TaskResult> {
    // No public initializers
    
    // Swift will statically prevent this type from being copied or moved.
    // For now, that implies that it cannot be used with generics.

    /// Add a child task.
    public mutating func add(
        overridingPriority: Priority? = nil,
        operation: () async -> TaskResult
    ) { ... } 

    /// Add a child task and return a handle that can be used to manage it.
    public mutating func addWithHandle(
        overridingPriority: Priority? = nil,
        operation: () async -> TaskResult
    ) -> Handle<TaskResult> { ... } 

    /// Wait for a child task to complete and return the result it returned,
    /// or else return.
    public mutating func next() async -> TaskResult? { ... } 
    
    /// Query whether the nursery has any remaining tasks.
    /// Nurseries are always empty upon entry to the withNursery body.
    public var isEmpty: Bool { ... } 

    /// Cancel all the remaining tasks in the nursery.
    /// Any results, including errors thrown, are discarded.
    public mutating func cancelAll() { ... } 
  }
}
```

A nursery _guarantees_ that it will `await` for all tasks that were added to it before it returns.

This waiting can be performed either: 
- by the code within the nursery itself, or
- by transparently nursery itself when returning from it.

In the `chopVegetables()` example we not only added vegetable chopping tasks to the nursery, but also collected the chopped up results. See below for simplified reminder of the general pattern:

```swift
func chopVegetables(rawVeggies: [Vegetable]) async throws -> [ChoppedVegetable] {
  Task.withNursery(resultType: ChoppedVegetable.self) { nursery in    
    var choppedVeggies: [ChoppedVegetable] = []
    choppedVeggies.reserveCapacity(veggies.count)
        
    // add all chopping tasks and process them concurrently
    for v in rawVeggies {
      await try nursery.add { // await the successful adding of the task 
        await v.chopped() // await the processing result of task
      }
    }

    while let choppedVeggie = await try nursery.next() { 
      choppedVeggies.append(choppedVeggie)
    }
    
    return choppedVeggies
  }
}
```

#### Nurseries: Throwing and cancellation

Worth pointing out here is that adding a task to a nursery could fail because the nursery could have been cancelled when we were about to add more tasks to it. To visualize this, let us consider the following example:

Tasks in a nursery by default handle thrown errors using like the musketeers would, that is: "*One for All, and All for One!*" In other words, if a single task throws an error, which escapes into the nursery, all other tasks will be cancelled and the nursery will re-throw this error.

To visualize this, let us consider chopping vegetables again. One type veggetable that can be quite tricky to chop up is onions, they can make you cry if you don't watch out. If we attempt to chop up those vegetables, the onion will throw an error into the nursery, causing all other tasks to be cancelled automatically:

```swift
func chopOnionsAndCarrots(rawVeggies: [Vegetable]) async throws -> [Vegetable] {
  await try Task.withNursery { nursery in // (3) will re-throw the onion chopping error
    // kick off asynchronous vegetable chopping:
    for v in rawVeggies {
      await try nursery.add { 
        await try v.chopped() // (1) throws
      }
    }
    
    // collect chopped up results:
    while let choppedVeggie = await try nursery.next() { // (2) will throw for the onion
      choppedVeggies.append(choppedVeggie)
    }
  }
}
```

Let us break up the `chopOnionsAndCarrots()` function into multiple steps to fully understand its semantics:

- first w add vegetable chopping tasks to the nursery
- the chopping of the various vegetables beings asynchronously,
- eventually an onion will be chopped and `throw`

#### Nurseries: Parent task cancellation

So far we did not yet discuss the cancellation of nurseries. A nursery can be cancelled if the task in which it was created is cancelled. Cancelling a nursery cancels all the tasks within it. Attempting to add more tasks into a cancelled nursery will throw a `CancellationError`. The following example illustrates these semantics:

```swift
struct WorkItem { 
  func process() async throws {
    await try Task.checkCancellation() // (4)
    // ... 
  } 
}

let handle = Task.runDetached {
  await Task.withNursery(resultType: Int.self) { nursery in
    var processed = 0
    for w in workItems where await !Task.isCancelled() { // (3)
      await nursery.add { await w.process() }
    }
    
    while let result = await nursery.next() { 
      processed += 1
    }
    
    return processed
  }
}

handle.cancel() // (1)

try await handle.get() // will throw CancellationError // (2)
```

There are various ways a task could be cancelled, however for this example let us consider a detached task being cancelled explicitly. This task is the parent task of the nursery, and as such the cancelation will be propagated to it once the parent task's handle `cancel()` is invoked.

Because cancellation remains co-operative, we need to check for it. We can do so either in the nursery itself to avoid even scheduling additional tasks when we know we have been cancelled *(3)*, or as usual in the `process()` task itself *(4)*. The benefit of checking in the nursery is that we can potentially even avoid scheduling the asynchronous child tasks if we know they won't be necessary.

In our example we were able to degrade gracefully by just returning a "best effort" processed value, alternatively one might prefer to use `checkCancellation()` and throw from the nursery when cancelled.

> NOTE: Presently nurseries do not automatically check for cancellation. They _could_ for example check for it when adding new tasks, such that `nursery.add()` would throw if the nursery is cancelled -- so we don't needlessly keep adding more work while our parent task has been cancelled already anyway. This would require add to be async and throwing which makes the API a bit unwieldly.

#### Nurseries: Implicitly awaited tasks
Sometimes it is not necessary to gather the results of asynchronous functions (e.g. because they may be `Void` returning, "uni-directional"), in this case we can rely on the nursery implicitly awaiting for all tasks started before returning. 

In the following example we need to confirm each order that we received, however that confirmation does not return any useful value to us (either it is `Void` or we simply choose to ignore the return values):

```swift
func confirmOrders(orders: [Order]) async throws {
  await try Task.withNursery { nursery in 
    for order in orders {
      await try nursery.add { await order.confirm() } 
    }
  }
}
```

The `confirmOrders()` function will only return once all confirmations have completed, because the nursery will "at the end-edge" of it's scope, await any outstanding tasks.

 
### Detached Tasks

Detached tasks are one of the two "escape hatch" APIs offered in this proposal (the other being the `UnsafeContinuation` APIs discussed in the next section), for when structured concurrency rules are too rigid for a specific asynchronous operations.


Looking at the previously mentioned example of making dinner in a detached task, but fillin in the missing types and details:


```swift
let dinnerHandle: Task.Handle<Dinner> = Task.runDetached {
  await makeDinner()
}

// optionally, someone, somewhere may cancel the task:
// dinnerHandle.cancel()

let dinner = await try dinnerHandle.get()
```

The `Task.Handle` returned from the `runDetached` function serves as a reference to an in-flight `Task`, allowing either awaiting or cancelling the task.

The `get()` function is always `throwing` (even if the task's code is not) also the `CancellationError`, so awaiting on a `handle.get()` is *always* throwing, even if the wrapped operation was not throwing itself.

```swift
extension Task {
  public final class Handle<Success> {
    public func get() async throws -> Success { ... }

    public func cancel() { ... }
  }
}
```

### Low-level code and integrating with legacy APis with `UnsafeContinuation`

The low-level execution of asynchronous code occasionally requires escaping the high-level abstraction of an async functions and nurseries. Also, it is important to enable APIs to interact with existing non-`async` code yet still be able to present to the users of such API a pleasant to use async function based interface.

For such situations, this proposal introduces the concept of a `Unsafe(Throwing)Continuation`:

```swift
extension Task {
  public static func withUnsafeContinuation<T>(
    operation: (UnsafeContinuation<T>) -> ()
  ) async -> T { ... }

  public struct UnsafeContinuation<T> {
    private init(...) { ... }
    public func resume(returning: T) { ... }
  }


  public static func withUnsafeThrowingContinuation<T, E: Error>(
    operation: (UnsafeThrowingContinuation<T, E>) -> ()
  ) async throws -> T { ... }
  
  public struct UnsafeThrowingContinuation<T, E: Error> {
    private init(...) { ... }
    public func resume(returning: T) { ... }
    public func resume(throwing: E) { ... }
  }
}
```

Unsafe continuations allow for wrapping existing complex callback-based APIs and presenting them to the caller as if it was a plan async function. 

Rules for dealing with unsafe continuations:

- the `resume` function must only be called *exactly-once* on each execution path the `operation` may take (including any error handling paths),
- the `resume` function must be called exactly at the _end_ of the `operation` function's execution, otherwise or else it will be impossible to define useful semantics for captures in the operation function, which could otherwise run concurrently with the continuation; unfortunately, this unavoidably introduces some overhead to the use of these continuations.

Using this API one may for example wrap such (purposefully convoluted for the sake of demonstrating the flexibility of the continuation API) function:

```swift
func buyVegetables(
  shoppingList: [String],
  // a) if all veggies were in store, this is invoked *exactly-once*
  onGotAllVegetables: ([Vegetable]) -> (),

  // b) if not all veggies were in store, invoked one by one *one or more times*
  onGotVegetable: (Vegetable) -> (),
  // b) if at least one onGotVegetable was called *exactly-once*
  //    this is invoked once no more veggies will be emitted
  onNoMoreVegetables: () -> (),
  
  // c) if no veggies _at all_ were available, this is invoked *exactly once*
  onNoVegetablesInStore: (Error) -> ()
)
```

```swift
// returns 1 or more vegetables or throws an error
func buyVegetables(shoppingList: [String]) async throws -> [Vegetable] {
  await try Task.withUnsafeThrowingContinuation { continuation in
    var veggies: [Vegetable] = []

    buyVegetables(
      shoppingList: shoppingList,
      onGotAllVegetables: { veggies in continuation.resume(returning: veggies) },
      onGotVegetable: { v in veggies.append(v) },
      onNoMoreVegetables: { continuation.resume(returning: veggies) },
      onNoVegetablesInStore: { error in continuation.resume(throwing: error) },
    )
  }
}

let veggies = await try buyVegetables(shoppingList: ["onion", "bell pepper"])
```

Thanks to weaving the right continuation resume calls into the complex callbacks of the `buyVegetables` function, we were able to offer a much nicer overload of this function, allowing our users to rely on the async/await to interact with this function.

> **The challange with diagnostics for Unsafe**: It is theoretically possible to provide compiler diagnostics to help developers avoid *simple* mistakes with resuming the continuation multiple times (or not at all). 
> 
> However, since the primary use case of this API is often integrating with complicated callback-style APIs (such as the `buyVegetables` shown above) it is often impossible for the compiler to have enough information about each callback's semantics to meaningfully produce diagnostic guidance about correct use of this unsafe API. 
> 
> Developers must carefully place the `resume` calls guarantee the proper resumption semantics of unsafe continuations, lack of consideration for a case where resume should have been called will result in a task hanging forever, justifying the unsafe denotation of this API.

 
## Source compatibility

This change is purely additive to the source language. The additional use of the contextual keyword `async` in `async let` accepts new code as well-formed but does not break or change the meaning of existing code.

## Effect on ABI stability

This change is purely additive to the ABI.

## Effect on API resilience

All of the changes described in this document are additive to the language and are locally scoped, e.g., within function bodies. Therefore, there is no effect on API resilience.
