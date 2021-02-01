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
  let veggies = try await chopVegetables()
  let meat = await marinateMeat()
  let oven = try await preheatOven(temperature: 350)

  let dish = Dish(ingredients: [veggies, meat])
  return try await oven.cook(dish, duration: .hours(3))
}
```

Each step in our dinner preparation is an asynchronous operation, so there are numerous suspension points. While waiting for the vegetables to be chopped, `makeDinner` won't block a thread: it will suspend until the vegetables are available, then resume. Presumably, many dinners could be in various stages of preparation, with most suspended until their current step is completed.

However, even though our dinner preparation is asynchronous, it is still *sequential*. It waits until the vegetables have been chopped before starting to marinate the meat, then waits again until the meat is ready before preheating the oven. Our hungry patrons will be very hungry indeed by the time dinner is finally done.

To make dinner preparation go faster, we need to perform some of these steps *concurrently*. To do so, we can break down our recipe into different tasks that can happen in parallel. The vegetables can be chopped at the same time that the meat is marinating and the oven is preheating. Sometimes there are dependencies between tasks: as soon as the vegetables and meat are ready, we can combine them in a dish, but we can't put that dish into the oven until the oven is hot. All of these tasks are part of the larger task of making dinner. When all of these tasks are complete, dinner is served.

This proposal aims to provide the necessary tools to carve work up into smaller tasks that can run concurrently, to allow tasks to wait for each other to complete, and to effectively manage the overall progress of a task.

## Structured concurrency

Any concurrency system must offer certain basic tools. There must be some way to create a new thread that will run concurrently with existing threads. There must also be some way to make a thread wait until another thread signals it to continue. These are powerful tools, and you can write very sophisticated systems with them. But they're also very primitive tools: they make very few assumptions, but in return they give you very little support.

Imagine there's a function which does a large amount of work on the CPU. We want to optimize it by splitting the work across two cores; so now the function creates a new thread, does half the work in each thread, and then has its original thread wait for the new thread to finish. (In a more modern system, the function might add a task to a global thread pool, but the basic concept is the same.) There is a relationship between the work done by these two threads, but the system doesn't know about it. That makes it much harder to solve systemic problems.

For example, suppose a high-priority operation needs the function to hurry up and finish. The operation might know to escalate the priority of the first thread, but really it ought to escalate both. At best, it won't escalate the second thread until the first thread starts waiting for it. It's relatively easy to solve this problem narrowly, maybe by letting the function register a second thread that should be escalated. But it'll be an ad hoc solution that might need to be repeated in every function that wants to use concurrency.

Structured concurrency solves this by asking programmers to organize their use of concurrency into high-level tasks and their child component tasks. These tasks become the primary units of concurrency, rather than lower-level concepts like threads. Structuring concurrency this way allows information to naturally flow up and down the hierarchy of tasks which would otherwise require carefully-written support at every level of abstraction and on every thread transition. This in turn permits many different high-level problems to be addressed with relative ease.

For example:

- It's common to want to limit the total time spent on a task. Some APIs support this by allowing a timeout to be passed in, but it takes a lot of work to propagate timeouts down correctly through every level of abstraction. This is especially true because end-programmers typically want to write timeouts as relative durations (e.g. 20ms), but the correctly-composing representation for libraries to pass around internally is an absolute deadline (e.g. now + 20ms). Under structured concurrency, a deadline can be installed on a task and naturally propagate through arbitrary levels of API, including to child tasks.

- Similarly, it's common to want to be able to cancel an active task. Asynchronous interfaces that support this often do so by synchronously returning a token object that provides some sort of `cancel()` method. This significantly complicates the design of an API and so often isn't provided. Moreover, propagating tokens, or composing them to cancel all of the active work, can create significant engineering challenges for a program. Under structured concurrency, cancellation naturally propagates through APIs and down to child tasks, and APIs can install handlers to respond instantaneously to cancellation.

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
    - Code can wait for a task to become completed in various ways, most notably by `await`-ing on it.

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

Swift provides a default executor implementation, but both actor classes and global actors (described in separate proposals) can suppress this and provide their own implementation.

Generally end-users need not interact with executors directly, but rather use them implicitly by invoking functions which happen to use executors to perform the invoked asynchronous functions.

### Task priorities

A task is associated with a specific priority.

Task priority may inform decisions an executor makes about how and when to schedule tasks submitted to it. An executor may utilize priority information to attempt to run higher priority tasks first, and then continuing to serve lower priority tasks. It may also use priority information to affect the platform thread priority.

The exact semantics of how priority is treated are left up to each platform and specific executor implementation.

Child tasks automatically inherit their parent task's priority. Detached tasks do not inherit priority (or any other information) because they semantically do not have a parent task.

The priority of a task does not necessarily match the priority of its executor. For example, the UI thread on Apple platforms is a high-priority executor; any task submitted to it will be run with high priority for the duration of its time on the thread. This helps to ensure that the UI thread will be available to run higher-priority work if it is submitted later. This does not affect the formal priority of the task.

### Priority Escalation

In some situations the priority of a task must be escalated in order to avoid a priority inversion:

- If a task is running on behalf of an actor, and a higher-priority task is enqueued on the actor, the task may temporarily run at the priority of the higher-priority task. This does not affect child tasks or the reported priority; it is a property of the thread running the task, not the task itself.

- If a task is created with a task handle, and a higher-priority task waits for that task to complete, the priority of the task will be permanently increased to match the higher-priority task.  This does affect child tasks and the reported task priority.

## Proposed solution

Our approach follows the principles of *structured concurrency* described above. All asynchronous functions run as part of an asynchronous task. Tasks can make child tasks that will perform work concurrently. This creates a hierarchy of tasks, and information can naturally flow up and down the hierarchy, making it convenient to manage the whole thing holistically.

### Task groups and child tasks

A *task group* defines a scope in which one can create new child tasks programmatically. As with all child tasks, the child tasks within the task group scope must complete when the scope exits, and will be implicitly cancelled first if the scope exits with a thrown error.

To illustrate task groups, let's start by showing how we can introduce some
real concurrency to our `makeDinner` example:

```swift
func makeDinner() async throws -> Meal {
  // Prepare some variables to receive results from our concurrent child tasks
  var veggies: [Vegetable]?
  var meat: Meat?
  var oven: Oven?

  // Create a task group to scope the lifetime of our three child tasks
  try await Task.withGroup(resultType: Void.self) { group in
    await group.add {
      veggies = try await chopVegetables()
    }
    await group.add {
      meat = await marinateMeat()
    }
    await group.app {
      oven = await preheatOven(temperature: 350)
    }
  }

  // If execution resumes normally after `Task.withGroup`, then we can assume
  // that all child tasks added to the group completed successfully. That means
  // we can confidently force-unwrap the variables containing the child task
  // results here.
  let dish = Dish(ingredients: [veggies!, meat!])
  return try await oven!.cook(dish, duration: .hours(3))
}
```

The `Task.withGroup` API gives us access to a task group, and governs the
lifetime of the *child tasks* we subsequently add to the group using its
`add` method. By the time `withGroup` finishes executing, we know that all of
the subtasks have completed.  A child task does not persist beyond the scope in
which it was created. By the time the scope exits, the child task must either
have completed, or it will be implicitly awaited. When the scope exits via a
thrown error, the child task will be implicitly cancelled before it is awaited.

These properties allow us to nicely contain the effects of the concurrency we
introduce inside the task group: although `chopVegetables`, `marinateMeat`,
and `preheatOven` will run concurrently, and may make progress in any order,
we can be sure that they have all finished executing in one way or another
by the time `withGroup` returns or throws an error. In either case, task groups
naturally propagate status from child tasks to the parent; in this example,
the `chopVegetables()` function might throw an error if, say, there is an
incident with the kitchen knife. That thrown error completes the child task for
chopping the vegetables. The error will then be propagated out of the
`makeDinner()` function, as expected. On exiting the body of the `makeDinner()`
function with this error, any child tasks that have not yet completed
(marinating the meat or preheating the oven, maybe both) will be automatically
cancelled. Structured concurrency means we don't have to manually propagate
errors and manage cancellation; if execution continues normally after a call
into `Task.withGroup`, we can assume that all of its child tasks completed
successfully.

Let's stretch our example even further and focus in on our `chopVegetables()` operation, which produces an array of `Vegetable` values. With enough cooks, we could chop our vegetables even faster if we divided up the chopping for each kind of vegetable. Let's start with a sequential version of `chopVegetables()`:

```swift
/// Sequentially chop the vegetables.
func chopVegetables() async throws -> [Vegetable] {
  let rawVeggies: [Vegetable] = gatherRawVeggies()
  var choppedVeggies: [Vegetable] = []
  for v in rawVeggies {
    choppedVeggies.append(try await v.chopped())
  }
  return choppedVeggies
}
```

Unlike the top-level `makeDinner` task, here we have a dynamic amount of
potential concurrency; depending on how many vegetables we can get from
`gatherRawVeggies`, each vegetable could in principle be chopped in parallel
with the rest. We also don't need to necessarily gather the chopped vegetables
in any specific order, and can collect the results as they become ready.

To create a dynamic number of child tasks and gather their results, we still introduce a new task group via `Task.withGroup`, specifying a `resultType`
for the child tasks, and using the group's `next` method to collect those
results as they become ready:

```swift
/// Concurrently chop the vegetables.
func chopVegetables() async throws -> [Vegetable] {
  // Create a task group where each child task produces a Vegetable.
  try await Task.withGroup(resultType: Vegetable.self) { group in 
    var veggies: [Vegetable] = gatherRawVeggies()
    
    // Create a new child task for each vegetable that needs to be 
    // chopped.
    for i in veggies.indices {
      await group.add { 
        return veggies[i].chopped()
      }
    }

    // Wait for all of the chopping to complete, collecting the veggies into
    // the result array in whatever order they're ready.
    while let choppedVeggie = try await group.next() {
      veggies.append(choppedVeggie)
    }
    
    return veggies
  }
}
```

As in the first example, if the closure passed to `Task.withGroup` exited without having completed all its child tasks, the task group will still wait until all child tasks have completed before returning. If the closure exits with a thrown error, the outstanding child tasks will first be cancelled before propagating
the error to the parent.

By contrast with future-based task APIs, there is no way in which a reference to the child task can escape the scope in which the child task is created. This ensures that the structure of structured concurrency is maintained. It both makes it easier to reason about the concurrent tasks that are executing within a given scope, and also unlocks numerous optimization opportunities for the compiler and runtime.

### Detached tasks

Thus far, every task we have created is a child task, whose lifetime is limited by the scope in which it is created. A *detached task* is one that is independent of any scope and has no parent task. One can create a new detached task with the `Task.runDetached` function, for example, to start making some dinner:

```swift
let dinnerHandle = Task.runDetached {
  try await makeDinner()
}
```

A detached task is represented by a task handle (in this case, `Task.Handle<Meal, Error>`) referencing the newly-launched task. Task handles can be used to await the result of the task, e.g.,

```swift
let dinner = try await dinnerHandle.get()
```

Detached tasks run to completion even if there are no remaining uses of their task handle, so `runDetached` is suitable for operations for which the program does not need to observe completion. However, the task handle can be used to explicitly cancel the operation, e.g.,

```swift
dinnerHandle.cancel()
```

### Asynchronous programs

A program can use `@main` with a `main()` function that is `async`:

```swift
@main
struct Eat {
  static func main() async {
    let meal = try! await makeDinner()
    print(meal)
  }
}
```

Semantically, Swift will create a new task that will execute `main()`. Once that task completes, the program terminates.

Top-level code can also make use of asynchronous calls. For example:


```swift
// main.swift or a Swift script
let meal = try await makeDinner()
print(meal)
```

The model is the same as for `@main`: Swift creates a task to execute top-level code, and completion of that task terminates the program.

### Cancellation

A task can be cancelled asynchronously by any context that has a reference to a task or one of its parent tasks. Cancellation can be triggered explicitly by calling `cancel()` on the task handle. Cancellation can also trigger automatically, for example when a parent task throws an error out of a scope with unawaited child tasks.

The effect of cancellation within the cancelled task is fully cooperative and synchronous. That is, cancellation has no effect at all unless something checks for cancellation. Conventionally, most functions that check for cancellation report it by throwing `CancellationError()`; accordingly, they must be throwing functions, and calls to them must be decorated with some form of `try`. As a result, cancellation introduces no additional control-flow paths within asynchronous functions; you can always look at a function and see the places where cancellation can occur. As with any other thrown error, `defer` blocks can be used to clean up effectively after cancellation.

With that said, the general expectation is that asynchronous functions should attempt to respond to cancellation by promptly throwing or returning. In most functions, it should be sufficient to rely on lower-level functions that can wait for a long time (for example, I/O functions or `Task.Handle.get()`) to check for cancellation and abort early. Functions which perform a large amount of synchronous computation may wish to periodically check for cancellation explicitly.

Cancellation has two effects which trigger immediately with the cancellation:

- A flag is set in the task which marks it as having been cancelled; once this flag is set, it is never cleared. Operations running synchronously as part of the task can check this flag and are conventionally expected to throw a `CancellationError`.

- Any cancellation handlers which have been registered on the task are immediately run. This permits functions which need to respond immediately to do so.

We can illustrate cancellation with a version of the `chopVegetables()` function we saw previously:

```swift
func chopVegetables() async throws -> [Vegetable] {
  var veggies: [Vegetable] = []

  try await Task.withGroup(resultType: Vegetable.self) { group in
    await group.add {
      return try await chop(Carrot()) // (1) throws UnfortunateAccidentWithKnifeError()
    }
    await group.add {
      return try await chop(Onion()) // (2)
    }

    while let veggie = try await group.next() { // (3)
      veggies.append(veggie)
    }
  }
  
  return veggies
}
```

On line *(1)*, we start a new child task to chop a carrot. Suppose that this call to the `chop` function throws an error. Because this is asynchronous, that error is not immediately observed in `chopVegetables`, and we proceed to start a second child task to chop an onion *(2)*. On line *(3)*, we await the `next` completed task, which could be either of the child tasks we spawned, but for the sake of discussion we'll say happens to be the `chop(Carrot())` child task from *(1)*. This causes us to throw the error that was thrown from `chop`. Since we do not handle this error, we exit the scope without having yet awaited the onion-chopping task. This causes that task to be automatically cancelled. Because cancellation is cooperative, and because structured concurrency does not allow child tasks to outlast their parent context, control does not actually return until the onion-chopping task actually completes; any value it returns or throws will be discarded.

As we mentioned before, the effect of cancellation on a task is synchronous and cooperative. Functions which do a lot of synchronous computation may wish to check explicitly for cancellation. They can do so by inspecting the task's cancelled status:

```swift
func chop(_ vegetable: Vegetable) async throws -> Vegetable {
  try Task.checkCancellation() // automatically throws `CancellationError`
  // chop chop chop ...
  // ... 
  
  guard Task.isCancelled else { 
    print("Cancelled mid-way through chopping of \(vegetable)!")
    throw CancellationError() 
  } 
  // chop some more, chop chop chop ...
}
```

Note also that no information is passed to the task about why it was cancelled.  A task may be cancelled for many reasons, and additional reasons may accrue after the initial cancellation (for example, if the task fails to immediately exit, it may pass a deadline). The goal of cancellation is to allow tasks to be cancelled in a lightweight way, not to be a secondary method of inter-task communication.

### Access from synchronous functions

As already shown in the above examples, it is possible to call functions that inspect the "current task" in order to check if it was e.g. cancelled. However, those functions are on purpose not `async` and _can_ be called from synchronous functions as well.

This is possible because of the existence of the `Task.unsafeCurrent` API:

```swift
extension Task { 
  static var unsafeCurrent: UnsafeCurrentTask? { get }
}
```

The `unsafeCurrent` API returns `nil` if the function is called from a context in which a Task is not available. In practice this means that nowhere in the call chain until this invocation, was any asynchronous function involved. If there is an asynchronous function in the call chain until the invocation of `unsafeCurrent`, that task will be returned.

This API is the callable-from-synchronous contexts version of `Task.current` which is an asynchronous function and therefore always has a `Task` available that it can return:

```swift
extension Task { 
  static func current() async -> Task { get }
  // If async computed properties proposal is accepted, this can become a static property
}
```

The `UnsafeCurrentTask` is purposefully named unsafe as it *may* expose APIs which can *only* be invoked safely from within task itself, and would exhibit undefined behavior if used from another task. It is therefore unsafe to store and "use later" an `UnsafeCurrentTask`. Examples of such unsafe API are interacting with task local values on a task object, which must be equal to the "current" task to be performed safely. This is by design, and offers the runtime optimization opportunities for the normal, and safe, access patterns to task storage.

`Task` defines APIs which are *always safe* to invoke, regardless if from the same task or from another task. Such safe APIs include `isCancelled`, `priority`.

It is possible to get a `Task` out of an `UnsafeCurrentTask`

## Detailed design

### Task API

Much of the proposed implementation of structured concurrency is in the APIs for creating, querying, and managing APIs described here. 

#### `Task` type

The `Task` type is used as a namespace for types and operations related to task management. 

```swift
struct Task: Equatable, Hashable { ... }
```

The "current task" can be obtained from inside of an async function using the `current` static function, like this:

```swift
func foo() async { 
  let task = await Task.current()
}
```

An asynchronous function _always_ executes within a task. As the `current` function itself is also asynchronous, it can only be invoked from an asynchronous function and is guaranteed to return the appropriate `Task`. The task object obtained this way is safe access by other tasks/threads. The APIs surfaced on it are specifically designed to also be safe, and relatively cheap, to be called from other tasks.

Tasks are `Equatable` and `Hashable`, this can be used to store and compare them, and can be used e.g. to answer questions such as "is this the same task I was called from before" etc. Keep in mind though, that tasks should not be held onto unnecessarily.

#### `UnsafeCurrentTask` type

It is also possible to obtain a reference to the "current" task from _synchronous_ functions.

This type is the core underlying type used to implement most of the APIs discussed in the following sections (which may be used from non-async contexts). Accessing using this API performs a thread-local lookup of a specific thread-local variable that is maintained by the Swift concurrency runtime.

The `UnsafeCurrentTask` is unsafe because it offers APIs which must not be invoked from any other task than the task it represents. In other words, it must not be stored, or accessed from other tasks/threads. Invoking some of its APIs from other contexts will result in undefined behavior.

```swift
func synchronous() {
  if let task = Task.unsafeCurrent {
    print("Seems I was invoked as part of a Task!")
  }
}
```

Unlike the `current` function, the `unsafeCurrent` function returns an _optional_ `UnsafeCurrentTask`, this is because such synchronous function may be invoked from a task (i.e. from within asynchronous Swift code) or outside of it (e.g. some Task unaware API, like a raw pthread thread calling into Swift code).

`UnsafeCurrentTask` has all the same query operations as `Task` (i.e. `isCancelled`, `priority`, ...) which are equally safe to invoke on the unsafe task as on a normal task, however it may define more APIs in the future that are more fragile and must only ever be invoked while executing on the same task (e.g. access to [Task Local Values](https://github.com/apple/swift-evolution/pull/1245) which are defined in a separate proposal).

#### Task priorities

The priority of a task is used by the executor to help make scheduling decisions. The priorities are listed from highest (most important) to lowest (least important).

```swift
extension Task {
  /// Describes the priority of a task.
  enum Priority: Int, Comparable {
    /// The task is important for user interaction, such as animations, event handling, or
    /// updating your app's user interface 
    case userInteractive

    /// The task was initiated by the user and prevents the user from actively using
    /// your app.
    case userInitiated

    /// Default priority for tasks. 
    case `default`

    /// Priority for a utility function that the user does not track actively.
    case utility

    /// Priority for maintenance or cleanup tasks.
    case background
  }
  
  /// Determine the priority of the currently-executing task.
  var priority: Priority { ... }
}
```

The `priority` operation queries the priority of the task.

Task priorities are set on task creation (e.g., `Task.runDetached` or `Task.Group.add`) and can be escalated later, e.g., if a higher-priority task waits on the task handle of a lower-priority task.

The `currentPriority` operation queries the priority of the currently-executing task. Task priorities are set on task creation (e.g., `Task.runDetached` or `Task.Group.add`) and can be escalated later, e.g., if a higher-priority task waits on the task handle of a lower-priority task.

#### Task handles

A task handle provides a reference to a task whose primary purpose is to retrieve the result of the task.

```swift
extension Task {
  struct Handle<Success, Failure: Error>: Equatable, Hashable {
    /// Retrieve the result produced the task, if is the normal return value, or
    /// throws the error that completed the task with a thrown error.
    func get() async throws -> Success
    
    /// Retrieve the result produced by the task as a \c Result instance.
    func getResult() async -> Result<Success, Failure>
  }
}

extension Task.Handle where Failure == Never {
  /// Retrieve the result produced by a task that is known to never throw.
  func get() async -> Success
}
```

The `get()` operation is the primary consumer interface to a task handle: it produces the result returned by the task or (if the task exits via a thrown error) throws the error produced by the task. For example:

```swift
func eat(mealHandle: Task.Handle<Meal, Error>) {
  let meal = try await mealHandle()
  meal.eat() // yum
}
```

Task handles also provide the ability to cancel a task programmatically:

```swift
extension Task.Handle {
  /// Cancel the task referenced by this handle.
  func cancel()
  
  /// Determine whether the task was cancelled.
  var isCancelled: Bool { get }
}
```

As noted elsewhere, cancellation is cooperative: the task will note that it has been cancelled and can choose to return earlier (either via a normal return or a thrown error, as appropriate). `isCancelled` can be used to determine whether a particular task was ever cancelled.

It is possible to obtain a task that the handle refers to by using `handle.task`:

```swift
extension Task.Handle { 
  /// Returns the task object the handle is refering to.
  var task: Task { get }
}
```

Getting the handle's task allows us to check if the work we're about to wait on perhaps was already cancelled (by calling `handle.task.isCancelled`), or query at what priority the task is executing.

#### Detached tasks

A new, detached task can be created with the `Task.runDetached` operation. The resulting task is represented by a `Task.Handle`.

```swift
extension Task {
  /// Create a new, detached task that produces a value of type `T`.
  @discardableResult
  static func runDetached<T>(
    priority: Priority = .default,
    startingOn executor: ExecutorRef? = nil,
    operation: @escaping () async -> T
  ) -> Handle<T>

  /// Create a new, detached task that produces a value of type `T` or throws an error.
  @discardableResult
  static func runDetached<T>(
    priority: Priority = .default,
    startingOn executor: ExecutorRef? = nil,
    operation: @escaping () async throws -> T
  ) -> Handle<T, Error>
}
```

Detached tasks will typically be created using a closure, e.g.,

```swift
let dinnerHandle: Task.Handle<Meal, Error> = Task.runDetached {
  try await makeDinner()
}

try await eat(dinnerHandle)
```

By default, the new task will be initially scheduled on the default global
concurrent executor. `runDetached` may optionally be given a `startingOn`
executor on which to schedule the new task instead.

#### Cancellation

A task can check whether it has been cancelled with the `Task.isCancelled` operation, and act accordingly. For tasks that would prefer to immediately exit with a thrown error on cancellation, the task API provides a common error type, `CancellationError`, to communicate that the task was cancelled. The `Task.checkCancellation()` will throw `CancellationError` when the task has been cancelled, and is provided as a convenience.

```swift
extension Task { 
  /// Returns `true` if the task is cancelled, and should stop executing.
  var isCancelled: Bool

  /// The default cancellation thrown when a task is cancelled.
  ///
  /// This error is also thrown automatically by `Task.checkCancellation()`,
  /// if the current task has been cancelled.
  struct CancellationError: Error {
    // no extra information, cancellation is intended to be light-weight
    init() {}
  }

  func checkCancellation() throws
}
```

#### Cancellation handlers

For tasks that want to react immediately to cancellation (rather than, say, waiting until a cancellation error propagates upward), one can install a cancellation handler:

```swift
extension Task {
  /// Execute an operation with cancellation handler which will immediately be
  /// invoked if the current task is cancelled.
  ///
  /// This differs from the operation cooperatively checking for cancellation
  /// and reacting to it in that the cancellation handler is _always_ and
  /// _immediately_ invoked when the task is cancelled. For example, even if the
  /// operation is running code which never checks for cancellation, a cancellation
  /// handler still would run and give us a chance to run some cleanup code.
  ///
  /// Does not check for cancellation, and always executes the passed `operation`.
  ///
  /// This function returns instantly and will never suspend.
  static func withCancellationHandler<T>(
    handler: /* @concurrent */ () -> Void,
    operation: () async throws -> T
  ) async rethrows -> T
}
```

Note that the `handler` runs `@concurrent` with the rest of the task, because it
is executed immediately when the task is cancelled, which can happen at any
point. If the task has already been cancelled at the point `withCancellationHandler` is called, the cancellation handler is invoked immediately, before the
`operation` block is executed.

These properties place rather strict limitations on what a
cancellation handler closure can safely do, but the ability to be triggered at
any point makes cancellation handlers useful for managing the state of related
objects, in cases where either polling cancellation state from within the task
or else propagating it by throwing `CancellationError` is not possible. As one
example, cancellation handlers can be useful in conjunction with
[continuations](0300-continuation.md) to help thread cancellation through
non-`async` event-driven interfaces. For example, if one wanted to wrap up
Foundation's `URLSession` object in an async function interface, cancelling the
`URLSession` if the async task is itself cancelled, then it might look
something like this:

```
func download(url: URL) async throws -> Data? {
  var urlSessionTask: URLSessionTask?

  return try Task.withCancellationHandler {
    urlSessionTask?.cancel()
  } operation: {
    return try await withUnsafeThrowingContinuation { continuation in
      urlSessionTask = URLSession.shared.dataTask(with: url) { data, _, error in
        if let error = error {
          // Ideally translate NSURLErrorCancelled to CancellationError here
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: data)
        }
      }
      urlSessionTask?.resume()
    }
  }
}
```

#### Voluntary Suspension

For long running operations, say performing many computations in a tight loop
without natural suspend points, it might be beneficial to occasionally check in if the task should perhaps suspend and offer a chance for other tasks to proceed (e.g. if all are executing on a shared, limited-concurrency pool). For this use case, `Task` includes a `yield()` operation, which is a way to explicitly suspend the current task and give other tasks a chance to run for a while. 

```swift
extension Task {
  static func yield() async
}
```

#### Querying Task status from synchronous functions

While all APIs defined on `Task` so far have been *instance* functions and properties, this implies that in order to query them one first would have to obtain a Task object. Obtaining a task object safely is perfomed by invoking the `Task.current()` asynchronous function, leading to the question: how do we check if a task we're running in, has been cancelled if we are in the in a synchronous function which was invoked from an asynchronous function?

Thankfully, thanks to the previously discussed `UnsafeCurrentTask` Swift also can offer safe, and usable from synchronous contexts, static versions of almost all functions defined in the previous sections.

##### Cancelation

It is possible to query for cancellation from within a synchronous task, e.g. while iterating over a loop and wanting to check if we should abort its execution by using the static `Task.isCancelled` function:

```swift
extension Task { 

  /// Returns `true` if the task is cancelled, and should stop executing.
  ///
  /// Always returns `false` when called from code not currently running inside of a `Task`.
  static var isCancelled: Bool { get }
  
  /// Check if the task is cancelled and throw an `CancellationError` if it was.
  ///
  /// It is intentional that no information is passed to the task about why it
  /// was cancelled. A task may be cancelled for many reasons, and additional
  /// reasons may accrue / after the initial cancellation (for example, if the
  /// task fails to immediately exit, it may pass a deadline).
  ///
  /// The goal of cancellation is to allow tasks to be cancelled in a
  /// lightweight way, not to be a secondary method of inter-task communication.
  ///
  /// Never throws if invoked from code not currently running inside of a `Task`.
  static func checkCancellation() throws
}
```

The functions work the same as their instance counter parts, except that if invoked from a context that has no Task available, e.g. if invoked from outside of Swift's concurrency model (e.g. directly from a pthread) a default value is returned.

The isCancelled function is implemented as:

```swift
extension Task {
  static var isCancelled: Bool { 
    Task.unsafeCurrent?.isCancelled ?? false
  }
}
```

Which makes sense, because if not executing within a task, such code can never "be cancelled" using Swift's task infrastructure.

This static `isCancelled` function is always safe to invoke, as the use of `UnsafeCurrentTask` is such that it can never escape or be stored somewhere, which is the only unsafe part about that API.

##### Task priorities

Similarily, a static `currentPriority` function is available on all task objects:

```swift
extension Task { 
  static var currentPriority: Task.Priority { 
    Task.unsafeCurrent.?.priority ?? Task.Priority.default
  }
}
```

The rationale for the default value is that if running outside of the Task infrastructure, there is no way to impact the priority of 

#### Task Groups

Task groups are created using `Task.withGroup` in any asynchronous context, providing a scope in which new tasks can be created and executed concurrently. 

```swift
extension Task {
  /// Starts a new task group which provides a scope in which a dynamic number of
  /// tasks may be spawned.
  ///
  /// Tasks added to the group by `group.add()` will automatically be awaited on
  /// when the scope exits. If the group exits by throwing, all added tasks will
  /// be cancelled and their results discarded.
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
  static func withGroup<TaskResult, BodyResult>(
    resultType: TaskResult.Type,
    startingChildTasksOn executor: ExecutorRef? = nil,
    returning returnType: BodyResult.Type = BodyResult.self,
    body: (inout Task.Group<TaskResult>) async throws -> BodyResult
  ) async throws -> BodyResult { ... } 
  
  /// A group of tasks, each of which produces a result of type `TaskResult`.
  struct Group<TaskResult> {
    // No public initializers
  }
}
```

`Task.Group` has no public initializers; instead, an instance of `Task.Group` is passed in to the `body` function of `withGroup`. This instance should not be copied out of the `body` function, because doing so can break the child task structure.

> **Note**: Swift does not currently have a way to ensure that the task group passed into the `body` function is not copied elsewhere, so we therefore rely on programmer discipline in a similar manner to, e.g., [`Array.withUnsafeBufferPointer`](https://developer.apple.com/documentation/swift/array/2994771-withunsafebufferpointer). However, in the case of task groups, we can at least provide a runtime assertion if one attempts to  use the task group instance after its corresponding scope has ended.

The result of `withGroup` is the result produced by the `body` function, or a thrown error if the `body` function throws an error.

A task group _guarantees_ that it will `await` all tasks that were added to it before it returns.

This waiting can be performed either: 
- by the code within the task group itself (e.g., using `next()` repeatedly until it returns `nil`, described below), or
- implicitly in the task group itself when returning from the `body`.

By default, the task group will schedule child tasks added to the group on the default global concurrent executor. The `startingChildTasksOn` argument can
be provided to override this behavior.

##### Adding tasks to a group

Within the `body` function, tasks may be added dynamically with the `add` operation. Each task produces a value of the same type (the `ResultType` generic parameter):

```swift
extension Task.Group { 
  /// Add a task to the group.
  mutating func add(
      overridingPriority: Priority? = nil,
      operation: @escaping () async throws -> TaskResult
  ) async -> Bool
}
```

`add` creates a new task in the task group, which will execute the given `operation` function concurrently. The task will be a child of the task that initially created the task group (via `Task.withGroup`), and will have the same priority as that task unless given a new priority with a non-`nil` `overridingPriority` argument.

The `add` operation is `async` to allow for a form of back-pressure. If the executor on which the new task will be scheduled is oversubscribed, the `add` call itself can suspend to slow the creation of new tasks. (By default, this is the
default global concurrent executor, though a `withGroup` call can override this if it's passed a different executor argument.)

The `add` operation returns `true` to indicate that the task was added to the group, and
`false` otherwise. The only circumstance under which the task will not be added to the group is when the task group has been cancelled; see the section on [task group cancellation](#task-group-cancellation) for more information.

##### Querying tasks in the group

The `next()` operation allows one to gather the results from the tasks that have been added to the group. It produces the result from one of the tasks in the group, whether it is the normal result or a thrown error. 

```swift
extension Task.Group {
  /// Wait for a task to complete and return the result it returned (or throw if the task
  /// exited with a thrown error), or else return `nil` when there are no tasks left in
  /// the group.
  mutating func next() async throws -> TaskResult? { ... } 

  /// Wait for a task to complete and return the result or thrown error packaged in
  /// a `Result` instance. Returns `nil` only when there are no tasks left in the group.
  mutating func nextResult() async -> Result<TaskResult, Error>?

  /// Query whether the task group has any remaining tasks.
  var isEmpty: Bool { ... } 
}
```

The `next()` operation may typically be used within a `while` loop to gather the results of all outstanding tasks in the group, e.g.,

```swift
while let result = try await group.next() {
  // some accumulation logic (e.g. sum += result)
}
```

With this pattern, if a single task throws an error, the error will be propagated out of the `body` function and the task group itself. To handle errors from individual tasks, one can use a do-catch block or the `nextResult()` method.

##### Task group cancellation

There are several ways in which a task group can be cancelled. In all cases, all of the tasks in the group are cancelled and no more tasks can be added to the group (`add` will return `false`). The three ways in which a task group can be cancelled are:

1. When an error is thrown out of the `body` of `withGroup`,
2. When the task in which the task group itself was created is cancelled, or
3. When the `cancelAll()` operation is invoked.


```swift
extension Task.Group {
  /// Cancel all the remaining tasks in the task group.
  /// Any results, including errors thrown, are discarded.
  mutating func cancelAll() { ... } 
}
```

## Source compatibility

This change is purely additive to the source language.

## Effect on ABI stability

This change is purely additive to the ABI.

## Effect on API resilience

All of the changes described in this document are additive to the language and are locally scoped, e.g., within function bodies. Therefore, there is no effect on API resilience.

## Revision history

* Changes in the third pitch:
  * Factored `with*Continuation` into [its own proposal](https://github.com/apple/swift-evolution/pull/1244).
  * Factored `async let` into its own proposal.
  * `Task` becomes a `struct` with instance functions, introduction of `Task.current`, `Task.unsafeCurrent` and the `UnsafeCurrentTask` APIs

* Changes in the second pitch:
  * Added a "desugaring" of `async let` to task groups and more motivation for the structured-concurrency parts of the design.
  * Reflowed the entire proposal to focus on the general description of structured concurrency first, the programming model with syntax next, and then details of the language features and API design last.
  * Reworked the presentation of the Task APIs with more rationale for the design.
  * Added more discussion of why futures aren't more prominent.
  * "Task nursery" has been replaced with "task group".
  * Added support for asynchronous `@main` and top-level code.
  * Specify that `try` is not required in the initializer of an `async let`, because the thrown error is only observable when reading from one of the variables.
  * `withUnsafe(Throwing)Continuation` functions have been moved out of the `Task` type.
  * Note that an `async let` variable can only be captured by a non-escaping closure.
  * Removed the requirement that an `async let` variable be awaited on all paths.

* Original pitch [document](https://github.com/DougGregor/swift-evolution/blob/06fd6b3937f4cd2900bbaf7bb22889c46b5cb6c3/proposals/nnnn-structured-concurrency.md)

## Alternatives Considered

### Prominent futures

The design of task groups intentionally avoids exposing any task handles (futures) for child tasks. This ensures that the structure of structured concurrency, where all child tasks complete before their parent task, is maintained. That helps various properties such as priorities, deadlines, and cancellation to propagate in a meaningful way down the task tree.

However, an alternative design would bring futures to the forefront. One could introduce an `runChild` counterpart to `runDetached` that creates a new child task (of the current task), and then retrieve the result of that child task using the provided `Task.Handle`. To ensure that child tasks complete before the scope exits, we would require some kind of scoping mechanism that provides similar behavior to task groups. For example, the `makeDinner` example would be something like:

```swift
func makeDinner() async throws -> Meal {
  Task.withChildScope { scope in 
    let veggiesHandle = scope.runChild { try await chopVegetables() }
    let meatHandle = scope.runChild { await marinateMeat() }
    let ovenHandle = scope.runChild { await preheatOven(temperature: 350) }

    let dish = Dish(ingredients: await [try veggiesHandle.get(), meatHandle.get()])
    return try await ovenHandle.get().cook(dish, duration: .hours(3))
  }
}
```

The task handles produced by `runChild` should never escape the scope in which they are created, although there is no language mechanism to enforce this. Moreover, the difference between detached and child tasks becomes blurred: both return the same `Task.Handle` type, but some have extra restrictions while others don't. So while it is possible to maintain structured concurrency with a future-centric design, it requires more programmer discipline (even for otherwise simple tasks), and provides less structure for the Swift compiler, optimizer, and runtime to use to provide an efficient implementation of child tasks.

## Future directions

### `async let`

Although our design deemphasizes futures for structured tasks, for the reasons
delineated above, we acknowledge that it will be common to want to pass
heterogeneous values up from child tasks to their parent. This is possible
within the existing task group APIs, though not ideal. Take our
first `makeDinner` example:

```
func makeDinner() async throws -> Meal {
  var veggies: [Vegetable]?
  var meat: Meat?
  var oven: Oven?

  // Create a task group to scope the lifetime of our three child tasks
  try await Task.withGroup(resultType: Void.self) { group in
    await group.add {
      veggies = try await chopVegetables()
    }
    await group.add {
      meat = await marinateMeat()
    }
    await group.app {
      oven = await preheatOven(temperature: 350)
    }
  }

  let dish = Dish(ingredients: [veggies!, meat!])
  return try await oven!.cook(dish, duration: .hours(3))
}
```

Although this works, it imposes a fair amount of boilerplate, and it relies
on programmer discipline to be correct in a way that we generally try to avoid
in Swift. Refactorings of this code could lead to one of the optional variables
no longer getting populated with a value, leading to a crash on unwrap,
or one of the variables potentially getting written accidentally by two
different child tasks, leading to potential race conditions, without any
help from the compiler.

We believe that this pattern is common enough to deserve a targeted solution.
Because child tasks are scoped in a manner very similar to local variables,
we could provide a binding syntax to represent the result of a child task, and 
then treat accesses of that binding as an operation that requires `await`-ing
and/or `try`-ing the result of the child task:

```
func makeDinner() async throws -> Meal {
  async let veggies = chopVegetables()
  async let meat = marinateMeat()
  async let oven = preheatOven(temperature: 350)

  let dish = Dish(ingredients: await [try veggies, meat])
  return await oven.cook(dish, duration: .hours(3))
}
```

This would provide a lightweight syntax for a very common dataflow pattern
between child tasks and parents within a task group. This idea is explored in
its own proposal.
