# Structured concurrency

* Proposal: [SE-NNNN](nnnn-structured-concurrency.md)
* Authors: [John McCall](https://github.com/rjmccall), [Joe Groff](https://github.com/jckarter), [Doug Gregor](https://github.com/DougGregor), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

[`async`/`await`](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md) is a language mechanism for writing natural, efficient asynchronous code. Asynchronous functions (introduced with `async`) can give up the thread on which they are executing at any given suspension point (marked with `await`), which is necessary for building highly-concurrent systems.

However, the `async`/`await` proposal does not introduce concurrency *per se*: ignoring the suspension points within an asynchronous function, it will execute in essentially the same manner as a synchronous function. This proposal introduces support for [structured concurrency](https://en.wikipedia.org/wiki/Structured_concurrency) in Swift, enabling concurrent execution of asynchronous code with a model that is ergonomic, predictable, and admits efficient implementation.

Swift-evolution thread: [\[Concurrency\] Structured concurrency](https://forums.swift.org/t/concurrency-structured-concurrency/41622)

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

To make dinner preparation go faster, we need to perform some of these steps *concurrently*. To do so, we can break down our recipe into different tasks that can happen in parallel. The vegetables can be chopped at the same time that the meat is marinating and the oven is preheating. Sometimes there are dependencies between tasks: as soon as the vegetables and meat are ready, we can combine them in a dish, but we can't put that dish into the oven until the oven is hot. All of these tasks are part of the larger task of making dinner. When all of these tasks are complete, dinner is served.

This proposal aims to provide the necessary tools to carve work up into smaller tasks that can run concurrently, to allow tasks to wait for each other to complete, and to effectively manage the overall progress of a task.

## Proposed solution

Our approach follows the principles of *structured concurrency*. All asynchronous functions run as part of an asynchronous *task*. Tasks can easily make child tasks that will perform work concurrently. This creates a hierarchy of tasks, and information can naturally flow up and down the hierarchy, making it convenient to manage the whole thing holistically.

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

### Child tasks with Task Groups

The `async let` construct makes it easy to create a set number of child tasks and associate them with variables. However, the construct does not work as well with dynamic workloads, where we don't know the number of child tasks we will need to create because (for example) it is dependent on the size of a data structure. For that, we need a more dynamic construct: a *task group*.

A task group defines a scope in which one can create new child tasks programmatically. As with all child tasks, the child tasks within the task group scope must complete when the scope exits or they will be implicitly awaited on. This is equivalent to a normal function scope enforcing that one awaits on all `async let` variables before exiting the scope, however with dynamically added child tasks the await becomes implicit at the exit of the task group scope. It is likely that various behavior variations for handling outstanding not-awaited-on added tasks will be available for call-site configuration. Task groups also provide utilities for working with the child tasks' results, e.g., by waiting until the next child task completes.

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

Introducing `async let` into the loop would not produce any meaningful concurrency, because each `async let` would need to complete before the next iteration of the loop could start. To create child tasks programmatically, we introduce a new task group scope via `Task.withGroup`:

```swift
/// Concurrently chop the vegetables.
func chopVegetables() async throws -> [Vegetable] {
  // Create a task group where each task produces (Int, Vegetable).
  await try Task.withGroup(resultType: (Int, Vegetable).self) { group in 
    var veggies: [Vegetable] = gatherRawVeggies()
    
    // Create a new child task for each vegetable that needs to be 
    // chopped.
    for i in veggies.indices {
      await try group.add { 
        (i, veggies[i].chopped())
      }
    }

    // Wait for all of the chopping to complete, slotting each result
    // into its place in the array as it becomes available.
    while let (index, choppedVeggie) = await try group.next() {
      veggies[index] = choppedVeggie
    }
    
    return veggies
  }
}
```

The `Task.withGroup(resultType:body:)` function introduces a new scope in which child tasks can be created (using the task group's `add(_:)` method). The `next()` method waits for the next child task to complete, providing the result value from the child task. In our example above, each child task carries the index where the result should go, along with the chopped vegetable.

As with the child tasks created by `async let`, if the closure passed to `Task.withGroup` exits without having completed all child tasks, any remaining child tasks will automatically be cancelled.

### Detached tasks

Thus far, every task we have created is a child task, whose lifetime is limited by the scope in which it is created. This does not allow for new tasks to be created that outlive the current scope.

The `runDetached` operation creates a new task. It accepts a closure, which will be executed as the body of the task. Here, we create a new, detached task to make dinner:

```swift
let dinnerHandle = Task.runDetached {
  await makeDinner()
}
```

The result of `runDetached` is a task handle, which can be used to retrieve the result of the operation when it completes (via `get()`) or cancel the task if the result is no longer desired (via `cancel()`). Unlike child tasks, detached tasks aren't cancelled even if there are no remaining uses of their task handle, so `runDetached` is suitable for operations for which the program does not need to observe completion.

## Detailed design

### Structured concurrency

Any concurrency system must offer certain basic tools. There must be some way to create a new thread that will run concurrently with existing threads. There must also be some way to make a thread wait until another thread signals it to continue. These are powerful tools, and you can write very sophisticated systems with them. But they're also very primitive tools: they make very few assumptions, but in return they give you very little support.

Imagine there's a function which does a large amount of work on the CPU. We want to optimize it by splitting the work across two cores; so now the function creates a new thread, does half the work in each thread, and then has its original thread wait for the new thread to finish. (In a more modern system, the function might add a task to a global thread pool, but the basic concept is the same.) There is a relationship between the work done by these two threads, but the system doesn't know about it. That makes it much harder to solve systemic problems.

For example, suppose a high-priority operation needs the function to hurry up and finish. The operation might know to escalate the priority of the first thread, but really it ought to escalate both. At best, it won't escalate the second thread until the first thread starts waiting for it. It's relatively easy to solve this problem narrowly, maybe by letting the function register a second thread that should be escalated. But it'll be an ad hoc solution that might need to be repeated in every function that wants to use concurrency.

Structured concurrency solves this by asking programmers to organize their use of concurrency into high-level tasks and their child component tasks. These tasks become the primary units of concurrency, rather than lower-level concepts like threads. Structuring concurrency this way allows information to naturally flow up and down the hierarchy of tasks which would otherwise require carefully-written support at every level of abstraction and on every thread transition. This in turn permits many different high-level problems to be addressed with relative ease.

For example:

- It's common to want to limit the total time spent on a task. Some APIs support this by allowing a timeout to be passed in, but it takes a lot of work to propagate timeouts down correctly through every level of abstraction. This is especially true because end-programmers typically want to write timeouts as relative durations (e.g. 20ms), but the correctly-composing representation for libraries to pass around internally is an absolute deadline (e.g. now + 20ms). Under structured concurrency, a deadline can be installed on a task and naturally propagate through arbitrary levels of API, including to child tasks.

- Similarly, it's common to want to be able to cancel an active task. Asynchronous interfaces that support this often do so by synchronously returning a token object that provides some sort of `cancel()` method. This significantly complicates the design of an API and so often isn't provided. Moreover, propagating tokens, or composing them to cancel all of the active work, can create significant engineering challenges for a program. Under structured concurrency, cancellation naturally propagates through APIs and down to child tasks, and APIs can simply install handlers to respond instantaneously to cancellation.

- Graphical user interfaces often rely on task prioritization to ensure timely refreshes and responses to events.  Under structured concurrency, child tasks naturally inherit the priority of their parent tasks.  Furthermore, when higher-priority tasks wait for lower-priority tasks to complete, the lower-priority task and all of its child tasks can be escalated in priority, and this will reliably persist even if the task is briefly suspended.

- Many systems want to maintain their own contextual information for an operation without having to pass it through every level of abstraction, such as a server that records information for the connection currently being serviced.  Structured concurrency allows this to naturally propagate down through async operations as a sort of "task-local storage" which can be picked up by child tasks.

- Systems that rely on queues are often susceptible to queue-flooding, where the queue accepts more work than it can actually handle. This is typically solved by introducing "back-pressure": a queue stops accepting new work, and the systems that are trying to enqueue work there respond by themselves stopping accepting new work. Actor systems often subvert this because it is difficult at the scheduler level to refuse to add work to an actor's queue, since doing so can permanently destabilize the system by leaking resources or otherwise preventing operations from completing. Structured concurrency offers a limited, cooperative solution by allowing systems to communicate up the task hierarchy that they are coming under distress, potentially allowing parent tasks to stop or slow the creation of presumably-similar new work.

This proposal doesn't propose solutions for all of these, but early investigations show promise.

### Tasks

A task is the basic unit of concurrency in the system. Every asynchronous function is executing in a task. In other words, a _task_ is to _asynchronous functions_, what a _thread_ is to _synchronous functions_. That is:

- All asynchronous functions run as part of some task.
- A task runs one function at a time; a single task has no concurrency.
- When a function makes an `async` call, the called function is still running as part of the same task (and the caller waits for it to return).
- Similarly, when a function returns from an `async` call, the caller resumes running on the same task.

Synchronous functions do not necessarily run as part of a task.

Swift assumes the existence of an underlying thread system. Tasks are scheduled by the system to run on these system threads. Tasks do not require special scheduling support from the underlying thread system, although a good scheduler could take advantage of some of the interesting properties of Swift's task scheduling.

A task can be in one of three states:

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
* They serve as a handle through which the operation can be cancelled, queried, or manipulated.
* They can carry user-provided task-local data.

At a lower level, the task allows the implementation to optimize the allocation of local memory, such as for asynchronous function contexts.  It also allows dynamic tools, crash reporters, and debuggers to discover how a function is being used.

### Child tasks

An asynchronous function can create a child task.  Child tasks inherit some of the structure of their parent task, including its priority, but can run concurrently with it.  However, this concurrency is bounded: a function that creates a child task must wait for it to end before returning.  This structure means that functions can locally reason about all the work currently being done for the current task, anticipate the effects of cancelling the current task, and so on.  It also makes spawning the child task substantially more efficient.

Of course, a function’s task may itself be a child of another task, and its parent may have other children; a function cannot reason locally about these.  But the features of this design that apply to an entire task tree, such as cancellation, only apply “downwards” and don’t automatically propagate upwards in the task hierarchy, and so the child tree still can be statically reasoned about.  If child tasks did not have bounded duration and so could arbitrarily outlast their parents, the behavior of tasks under these features would not be easily comprehensible. 

### Partial tasks

The execution of a task can be seen as a succession of periods where the task was running, each of which ends at a suspension point or — finally — at the completion of the task.  These periods are called partial tasks.  Partial tasks are the basic units of schedulable work in the system.  They are also the primitive through which asynchronous functions interact with the underlying synchronous world.  For the most part, programmers should not have to work directly with partial tasks unless they are implementing a custom executor.

### Executors

An executor is a service which accepts the submission of partial tasks and arranges for some thread to run them. The system assumes that executors are reliable and will never fail to run a partial task. 

An asynchronous function that is currently running always knows the executor that it's running on.  This allows the function to avoid unnecessarily suspending when making a call to the same executor, and it allows the function to resume executing on the same executor it started on.

An executor is called *exclusive* if the partial tasks submitted to it will never be run concurrently.  (Specifically, the partial tasks must be totally ordered by the happens-before relationship: given any two tasks that were submitted and run, the end of one must happen-before the beginning of the other.) Executors are not required to run partial tasks in the order they were submitted; in fact, they should generally honor task priority over submission order.

Swift provides a default executor implementation, but both actor classes and global actors can suppress this and provide their own implementation.

Generally end-users need not interact with executors directly, but rather use them implicitly by invoking actors and functions which happen to use executors to perform the invoked asynchronous functions.

### Task priorities

A task is associated with a specific `Task.Priority`.

Task priority may inform decisions an `Executor` makes about how and when to schedule tasks submitted to it. An executor may utilize priority information to attempt to run higher priority tasks first, and then continuing to serve lower priority tasks. It may also use priority information to affect the platform thread priority.

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

The priority level for a task is set by passing it to `Task.runDetached(priority:operation:)` when starting a top-level task. The child tasks of the task will inherit this priority.

The priority of a task does not necessarily match the priority of its executor. For example, the UI thread on Apple platforms is a high-priority executor; any task submitted to it will be run with high priority for the duration of its time on the thread. This helps to ensure that the UI thread will be available to run higher-priority work if it is submitted later. This does not affect the formal priority of the task.

#### Priority Escalation

In some situations the priority of a task must be escalated in order to avoid a priority inversion:

- If a task is running on behalf of an actor, and a higher-priority task is enqueued on the actor, the task may temporarily run at the priority of the higher-priority task. This does not affect child tasks or `Task.currentPriority()`; it is a property of the thread running the task, not the task itself.

- If a task is created with a `Task.Handle`, and a higher-priority task calls `await try handle.get()`, the priority of the task will be permanently increased to match the higher-priority task.  This does affect child tasks and `Task.currentPriority()`.

### Cancellation

A task can be cancelled asynchronously by any context that has a reference to a task or one of its parent tasks. Cancellation can be triggered explicitly by calling `cancel()` on the task. Cancellation can also trigger automatically, for example when a parent task throws an error out of a scope with unawaited child tasks (such as an `async let`).

The effect of cancellation within the cancelled task is fully cooperative and synchronous. That is, cancellation has no effect at all unless something checks for cancellation. Conventionally, most functions that check for cancellation report it by throwing `CancellationError()`; accordingly, they must be throwing functions, and calls to them must be decorated with some form of `try`. As a result, cancellation introduces no additional control-flow paths within asynchronous functions; you can always look at a function and see the places where cancellation can occur. As with any other thrown error, `defer` blocks can be used to clean up effectively after cancellation.

With that said, the general expectation is that asynchronous functions should attempt to respond to cancellation by promptly throwing or returning. In most functions, it should be sufficient to rely on lower-level functions that can wait for a long time (for example, I/O functions or `Task.Handle.get()`) to check for cancellation and abort early. Functions which perform a large amount of synchronous computation may wish to periodically check for cancellation explicitly.

Cancellation has two effects which trigger immediately with the cancellation:

- A flag is set in the task which marks it as having been cancelled; once this flag is set, it is never cleared. Operations running synchronously as part of the task can check this flag and are conventionally expected to throw a `CancellationError`.

- Any cancellation handlers which have been registered on the task are immediately run. This permits functions which need to respond immediately to do so.

We can illustrate cancellation with a version of the `chopVegetables()` function we saw previously:

```swift
func chopVegetables() async throws -> [Vegetable] {
  async let carrot = try chop(Carrot()) // (1) throws UnfortunateAccidentWithKnifeError()!
  async let onion = try chop(Onion()) // (2)
  
  return await try [carrot, onion] // (3)
}
```

On line *(1)*, we start a new child task to chop a carrot. Suppose that this call to the `chop` function throws an error. Because this is asynchronous, that error is not immediately observed in `chopVegetables`, and we proceed to start a second child task to chop an onion *(2)*. On line *(3)*, we `await` the carrot-chopping task, which causes us to throw the error that was thrown from `chop`. Since we do not handle this error, we exit the scope without having yet awaited the onion-chopping task. This causes that task to be automatically cancelled. Because cancellation is cooperative, and because structured concurrency does not allow child tasks to outlast their parent context, control does not actually return until the onion-chopping task actually completes; any value it returns or throws will be discarded.

As we mentioned before, the effect of cancellation on a task is synchronous and cooperative. Functions which do a lot of synchronous computation may wish to check explicitly for cancellation. They can do so by inspecting the task's cancelled status:

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

Note also that no information is passed to the task about why it was cancelled.  A task may be cancelled for many reasons, and additional reasons may accrue after the initial cancellation (for example, if the task fails to immediately exit, it may pass a deadline). The goal of cancellation is to allow tasks to be cancelled in a lightweight way, not to be a secondary method of inter-task communication.

#### Cancellation with Deadlines

A very common use case for cancellation is cancelling tasks because they are taking too long to complete. This proposal introduces the concept of *deadlines* and enables them to cause a task to consider itself as cancelled if such deadline is exceeded.

We intentionally use _deadlines_ ("points in time") as opposed to _timeouts_ ("durations of time"). This is because deadlines compose correctly: working with timeouts is prone to errors where the deadline is accidentally extended because a full timeout is reused rather than being adjusted for the time already passed. For convenience, we allow code to use a relative timeout when setting the deadline up; this will be immediately translated to an absolute deadline.

To further analyze the semantics of deadlines, let's extend our dinner preparation example with deadlines.

```swift
func makeDinnerWithDeadline() async throws -> Meal {
  await try Task.withDeadline(in: .hours(2)) {
    // intentionally wait until the vegetables have been chopped before starting any child tasks
    let veggies = await try chopVegetables()
    async let meat = Task.withDeadline(in: .minutes(30)) {
      marinateMeat()
    }
    async let oven = try preheatOven(temperature: 350)
    
    let dish = Dish(ingredients: await [veggies, meat])
    return await try oven.cook(dish, duration: .hours(3))
  }
}

func cook(dish: Dish, duration: Duration) async throws -> Meal {
  await try checkCancellation()
  // ...
}
```

In the example above, we set two deadlines. The first deadline is for two hours from the start and applies to the entire dinner preparation task. The second deadline is for 30 minutes from the time we start the marinade, and it applies only to that portion of the task.

Note that we await the chopped vegetables before beginning the marinade. This is to illustrate the following point: imagine, somehow, that chopping up the vegetables for some reason took 1 hour and 40 minutes. Now that we get to the meat marination step, we only have 20 minutes left in our outer deadline, yet we attempt to set a deadline in "30 minutes from now." If we had just set a timeout for 30 minutes here, we would be well past the outer deadline. Instead, the task automatically notices that the new deadline of `now + 30 minutes` is actually greater than the current deadline, and thus it is ignored; the task will be cancelled appropriately at the two-hour mark.

Deadlines are also available to interact with programmatically. For example, the `cook` function knows exactly how much time it will take to complete. Just checking for cancellation at the beginning of the `cook()` function only means that the deadline hasn't yet been exceeded, but we can do better than that: we can check whether we actually have three hours left. If not, we can throw immediately to tell the user that we aren't going to meet the deadline:

```swift
func cook(dish: Dish, duration: Duration) async throws -> Meal {
  guard await Task.currentDeadline().remaining > duration else { 
    throw await NotEnoughTimeToPrepareMealError("Not enough time to prepare meal!")
  }
  // ...
}
```

Thanks to this, functions which have a known execution time can proactively cancel themselves before even starting the work which we know would miss the deadline in the end anyway.

### Child tasks with `async let`

Asynchronous calls do not by themselves introduce concurrent execution. However, `async` functions may conveniently request work to be run in a child task, permitting it to run concurrently, with an `async let`:

```swift
async let result = try fetchHTTPContent(of: url)
```

Any reference to a variable that was declared in an `async let` is a suspension point, equivalent to a call to an asynchronous function, so it must occur within an `await` expression. The initializer of the `async let` is considered to be enclosed by an implicit `await` expression.

If the initializer of the `async let` can throw an error, then each reference to a variable declared within that `async let` clause is considered to throw an error, and therefore must also be enclosed in one of `try`/`try!`/`try?`:

```swift
{
  async let (yay, nay) = ("yay", throw Nay())
  
  await try yay // must be marked with `try`; throws Nay()
  // implicitly guarantees `nay` also be completed at this point
}
```

The simplest way to think about it is that anything to the right hand side of the `=` of an `async let` is initiated together (as-if in an asynchronous closure), implying that if any of the values initialized by this closure throws, all other left-hand side to-be-initialized variables must also be considered as it they had thrown that error. 

There is one additional case which may need a short explanation. Multiple clauses in a single `async let` may be written like this:

```swift
{
  async
let 
    ok = "ok",
    (yay, nay) = ("yay", throw Nay())
  
  await ok
  await try yay
  // okay
}
```

In the above example one can consider each clause as it's own asynchronously initialized variable, i.e. the `ok`  is initialized on its own, and the `(yay, nay)` are initialized together as was discussed previously. 

At least one of the variables for a given `async let` clause must be awaited at least once along all execution paths (that don't throw an error) before it goes out of scope. For example:

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

If the scope of an `async let` exits *by throwing an error*, the child task corresponding to the `async let` is implicitly cancelled. If the child task has already completed, its result (or thrown error) is discarded.

> **Rationale**: The requirement to await a variable from each `async let` along all (non-throwing) paths ensures that child tasks aren't being created and implicitly cancelled during the normal course of execution. Such code is likely to be needlessly inefficient and should probably be restructured to avoid creating child tasks that are unnecessary.
 
### Child Tasks with Nurseries

In addition to `async let` this proposal also introduces an explicit `Nursery` type, which allows for fine grained scoping of tasks within such task group. 

Tasks may be added dynamically to a task group, meaning one may add a task for each element of a dynamically sized collection to a task group and have them all be bound to the task group lifecycle. This is in contrast to `async let` declarations which only allow for a statically known at compile time number of tasks to be declared.

```swift
extension Task {

  /// Starts a new task group which provides a scope in which a dynamic number of
  /// tasks may be spawned.
  ///
  /// Tasks added to the group by `group.add()` will automatically be awaited on
  /// when the scope exits. If the group exits by throwing, all added tasks will
  /// be cancelled and their results discarded.
  ///
  /// ### Implicit awaiting
  /// When results of tasks added to the group need to be collected, one can
  /// gather their results using the following pattern:
  ///
  ///     while let result = await group.next() {
  ///       // some accumulation logic (e.g. sum += result)
  ///     }
  ///
  /// ### Cancellation
  /// If an error is thrown out of the task group, all of its remaining tasks
  /// will be cancelled and the `withGroup` call will rethrow that error.
  ///
  /// Individual tasks throwing results in their corresponding `try group.next()`
  /// call throwing, giving a chance to handle individual errors or letting the
  /// error be rethrown by the group.
  ///
  /// Postcondition:
  /// Once `withGroup` returns it is guaranteed that the `group` is *empty*.
  ///
  /// This is achieved in the following way:
  /// - if the body returns normally:
  ///   - the group will await any not yet complete tasks,
  ///     - if any of those tasks throws, the remaining tasks will be cancelled,
  ///   - once the `withGroup` returns the group is guaranteed to be empty.
  /// - if the body throws:
  ///   - all tasks remaining in the group will be automatically cancelled.
  public static func withGroup<TaskResult, BodyResult>(
    resultType: TaskResult.Type,
    returning returnType: BodyResult.Type = BodyResult.self,
    body: (inout Task.Group<TaskResult>) async throws -> BodyResult
  ) async rethrows -> BodyResult { ... } 
}
```

A task group can be launched from any asynchronous context, eventually returns a single value (the `BodyResult`). Tasks many be added to it dynamically, as we saw in the `chopVegetables` example in the *Proposed solution: Nurseries* section, and the task group enforces awaiting for all tasks before it returns by asserting that is empty when returning the final result.

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
    
    /// Query whether the task group has any remaining tasks.
    /// Nurseries are always empty upon entry to the Task.withGroup body.
    public var isEmpty: Bool { ... } 

    /// Cancel all the remaining tasks in the task group.
    /// Any results, including errors thrown, are discarded.
    public mutating func cancelAll() { ... } 
  }
}
```

A task group _guarantees_ that it will `await` for all tasks that were added to it before it returns.

This waiting can be performed either: 
- by the code within the task group itself, or
- by transparently task group itself when returning from it.

In the `chopVegetables()` example we not only added vegetable chopping tasks to the task group, but also collected the chopped up results. See below for simplified reminder of the general pattern:

```swift
func chopVegetables(rawVeggies: [Vegetable]) async throws -> [ChoppedVegetable] {
  await try Task.withGroup(resultType: ChoppedVegetable.self) { task group in    
    var choppedVeggies: [ChoppedVegetable] = []
    choppedVeggies.reserveCapacity(veggies.count)
        
    // add all chopping tasks and process them concurrently
    for v in rawVeggies {
      await try task group.add { // await the successful adding of the task 
        await v.chopped() // await the processing result of task
      }
    }

    while let choppedVeggie = await try task group.next() { 
      choppedVeggies.append(choppedVeggie)
    }
    
    return choppedVeggies
  }
}
```

#### Nurseries: Throwing and cancellation

Worth pointing out here is that adding a task to a task group could fail because the task group could have been cancelled when we were about to add more tasks to it. To visualize this, let us consider the following example:

Tasks in a task group by default handle thrown errors using like the musketeers would, that is: "*One for All, and All for One!*" In other words, if a single task throws an error, which escapes into the task group, all other tasks will be cancelled and the task group will re-throw this error.

To visualize this, let us consider chopping vegetables again. One type of vegetable that can be quite tricky to chop up is onions, they can make you cry if you don't watch out. If we attempt to chop up those vegetables, the onion will throw an error into the task group, causing all other tasks to be cancelled automatically:

```swift
func chopOnionsAndCarrots(rawVeggies: [Vegetable]) async throws -> [Vegetable] {
  await try Task.withGroup { task group in // (3) will re-throw the onion chopping error
    // kick off asynchronous vegetable chopping:
    for v in rawVeggies {
      await try task group.add { 
        await try v.chopped() // (1) throws
      }
    }
    
    // collect chopped up results:
    while let choppedVeggie = await try task group.next() { // (2) will throw for the onion
      choppedVeggies.append(choppedVeggie)
    }
  }
}
```

Let us break up the `chopOnionsAndCarrots()` function into multiple steps to fully understand its semantics:

- first add vegetable chopping tasks to the task group
- then chopping of the various vegetables beings asynchronously,
- eventually an onion will be chopped and `throw`

#### Task Groups: Parent task cancellation

So far we did not yet discuss the cancellation of task groups. A task group can be cancelled if the task in which it was created is cancelled. Cancelling a task group cancels all the tasks within it. Attempting to add more tasks into a cancelled task group will throw a `CancellationError`. The following example illustrates these semantics:

```swift
struct WorkItem { 
  func process() async throws {
    await try Task.checkCancellation() // (4)
    // ... 
  } 
}

let handle = Task.runDetached {
  await try Task.withGroup(resultType: Int.self) { task group in
    var processed = 0
    for w in workItems { // (3)
      try await task group.add { await w.process() }
    }
    
    while let result = try await task group.next() { 
      processed += 1
    }
    
    return processed
  }
}

handle.cancel() // (1)

try await handle.get() // will throw CancellationError // (2)
```

There are various ways a task could be cancelled, however for this example let us consider a detached task being cancelled explicitly. This task is the parent task of the task group, and as such the cancellation will be propagated to it once the parent task's handle `cancel()` is invoked.

Task Groups automatically check for the cancellation of the parent task when creating a new child task or waiting for a child task for complete. Adding a new task may also suspend if the system is under substantial load, as a form of back-pressure on the "queue" of new tasks being added to the system. These considerations allow the programmer to write straightforward, natural-feeling code that will still usually do the right thing by default.

#### Task Groups: Implicitly awaited tasks
Sometimes it is not necessary to gather the results of asynchronous functions (e.g. because they may be `Void` returning, "uni-directional"), in this case we can rely on the task group implicitly awaiting for all tasks started before returning. 

In the following example we need to confirm each order that we received, however that confirmation does not return any useful value to us (either it is `Void` or we simply choose to ignore the return values):

```swift
func confirmOrders(orders: [Order]) async throws {
  await try Task.withGroup { task group in 
    for order in orders {
      await try task group.add { await order.confirm() } 
    }
  }
}
```

The `confirmOrders()` function will only return once all confirmations have completed, because the task group will await any outstanding tasks "at the end-edge" of its scope.

 
### Detached Tasks

Detached tasks are one of the two "escape hatch" APIs offered in this proposal (the other being the `UnsafeContinuation` APIs discussed in the next section), for when structured concurrency rules are too rigid for a specific asynchronous operations.


Looking at the previously mentioned example of making dinner in a detached task, but filling in the missing types and details:


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

### Low-level code and integrating with legacy APIs with `UnsafeContinuation`

The low-level execution of asynchronous code occasionally requires escaping the high-level abstraction of an async functions and task groups. Also, it is important to enable APIs to interact with existing non-`async` code yet still be able to present to the users of such API a pleasant to use async function based interface.

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

Unsafe continuations allow for wrapping existing complex callback-based APIs and presenting them to the caller as if it was a plain async function.

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

> **The challenge with diagnostics for Unsafe**: It is theoretically possible to provide compiler diagnostics to help developers avoid *simple* mistakes with resuming the continuation multiple times (or not at all).
> 
> However, since the primary use case of this API is often integrating with complicated callback-style APIs (such as the `buyVegetables` shown above) it is often impossible for the compiler to have enough information about each callback's semantics to meaningfully produce diagnostic guidance about correct use of this unsafe API. 
> 
> Developers must carefully place the `resume` calls guarantee the proper resumption semantics of unsafe continuations, lack of consideration for a case where resume should have been called will result in a task hanging forever, justifying the unsafe denotation of this API.

### Miscellaneous minor Task APIs

#### Voluntary Suspension

For certain tasks of long running operations, say performing many tasks in a tight loop, it might be beneficial for tasks to sometimes check in if they should perhaps suspend and offer a chance for other tasks to proceed (e.g. if all are executing on a shared, limited-concurrency pool). For this use-case `Task` includes a `yield()` operation, which is a way to explicitly suspend and give other tasks a chance to run for a while. 

This is not a perfect cure for task starvation–if the task is the highest-priority task in the system, it might go immediately back to executing–however it can be useful specific patterns of long running tasks.

```swift
extension Task {
  public static func yield() async { ... }
}
```

A task can also be suspended until an arbitrary `Deadline`. This is similar to what "sleeping the thread" is in synchronous functions, however does not incur the cost of blocking any threads. The `Task.sleep(until:)` function is asynchronous and only suspends the _task_ until the given point in time. 

```swift
extension Task {

  /// Suspend until a given point in time.
  ///
  /// ### Cancellation
  /// Does not check for cancellation and suspends the current context until the
  /// given deadline.
  ///
  /// - Parameter until: point in time until which to suspend.
  public static func sleep(until: Deadline) async {
    fatalError("\(#function) not implemented yet.")
  }
}
```

The function does not check for cancellation automatically, so if one wanted to check for exceeding a deadline this would have be done manually before sleeping the task.

 
## Source compatibility

This change is purely additive to the source language. The additional use of the contextual keyword `async` in `async let` accepts new code as well-formed but does not break or change the meaning of existing code.

## Effect on ABI stability

This change is purely additive to the ABI.

## Effect on API resilience

All of the changes described in this document are additive to the language and are locally scoped, e.g., within function bodies. Therefore, there is no effect on API resilience.
