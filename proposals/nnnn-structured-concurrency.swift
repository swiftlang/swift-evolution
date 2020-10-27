# Structured concurrency

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [John McCall](https://github.com/rjmccall), [Joe Groff](https://github.com/jckarter), [Doug Gregor](https://github.com/DougGregor)
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
func chopVegetables() async -> [Vegetable] { ... }
func marinateMeat() async -> Meat { ... }
func preheatOven(temperature: Double) async throws -> Oven { ... }

// ...

func makeDinner() async throws -> Meal {
  let veggies = await chopVegetables()
  let meat = await marinateMeat()
  let oven = await try preheatOven(temperature: 350)

  let dish = Dish(ingredients: await [veggies, meat])
  return await try oven.cook(dish, duration: .hours(3))
}
``` 




## Proposed solution

### Tasks

An asynchronous task (just "task" hereafter) is the analogue of a thread for asynchronous functions.  All asynchronous functions run as part of some task.  When an asynchronous function calls another asynchronous function, the callee is still running as part of the same task as the parent.  The task is therefore a persistent identity.  If two asynchronous functions are executing concurrently, they are necessarily running as part of different tasks.  (The tasks may be related; see "Child tasks" below.)

A task always begins at the beginning of some asynchronous function, called its initial function.  A task can be in one of three states:

* A **suspended** task has more work to do but is not currently running.  It may be schedulable, meaning that it’s ready to run and is just waiting for the system to instruct a thread to begin executing it, or it may be waiting on some external event before it can become schedulable.
* A **running** task is currently running on a thread.  It will run until it either returns from its initial function (and becomes completed) or reaches a suspension point (and becomes suspended).  At a suspension point, it may become immediately schedulable if, say, its execution just needs to change actors.
* A **completed** task has no more work to do and will never enter any other state.  Code can wait for a task to become completed in various ways described in the detailed language design.

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

Child tasks can most easily be created with the `async let` construct, which creates a child task whose result can be accessed by reading the declared variable(s) in an `await` expression. For example:

```swift
func makeDinner() async throws -> Meal {
  async let veggies = chopVegetables()
  async let meat = marinateMeat()
  async let oven = try preheatOven(temperature: 350)

  let dish = Dish(ingredients: await [veggies, meat])
  return await try oven.cook(dish, duration: .hours(3))
}
``` 

Each `async let` creates a new child task, and these tasks can execute asynchronously. All of these child tasks must complete (or be cancelled) before the `makeDinner` function returns. If an error is thrown, any child tasks will implicitly be cancelled.

A separate proposal for task management will introduce additional ways to create and manage child tasks. 

If a program wishes to initiate independent concurrent work that can outlast its spawning context, it should create a new detached task rather than a bounded child task. Although the specific API is again left to a separate proposal for task management, it will have a form similar to:

```swift
let handle = Task.runDetached { await longRunningSeparateTask() }
```

The `handle` is a reference to that task, and can be used to cancel the task, check the task's priority, etc.

### Partial tasks

The execution of a task can be seen as a succession of periods where the task was running, each of which ends at a suspension point or — finally — at the completion of the task.  These periods are called partial tasks.  Partial tasks are the basic units of schedulable work in the system.  They are also the primitive through which asynchronous functions interact with the underlying synchronous world.  For the most part, programmers should not have to work directly with partial tasks unless they are implementing a custom executor.

### Executors

An executor is a service which accepts the submission of partial tasks and arranges for some thread to run them.  The system assumes that executors are reliable and will never fail to run a partial task.  An asynchronous function that is currently running always knows the executor that it's running on.  This allows the function to avoid unnecessarily suspending when making a call to the same executor, and it allows the function to resume executing on the same executor it started on.

An executor is called exclusive if the partial tasks submitted to it will never be run concurrently.  (Specifically, the partial tasks must be totally ordered by the happens-before relationship: given any two tasks that were submitted and run, the end of one must happen-before the beginning of the other.)  Executors are not required to run partial tasks in the order they were submitted; in fact, they should generally honor task priority over submission order.

### Cancellation

A task can be cancelled asynchronously by any context that has a reference to a task or one of its parent tasks.  However, the effect of cancellation on the task is cooperative and synchronous.  Cancellation sets a flag in the task which marks it as having been cancelled; once this flag is set, it is never cleared.  Executing a suspension point alone does not check cancellation. Operations running synchronously as part of the task can check this flag and are conventionally expected to throw a `CancellationError`. As with thrown errors, `defer` blocks are still executed when a task is cancelled, allowing code to introduce cleanup logic.

No information is passed to the task about why it was cancelled.  A task may be cancelled for many reasons, and additional reasons may accrue after the initial cancellation (for example, if the task fails to immediately exit, it may pass a deadline).  The goal of cancellation is to allow tasks to be cancelled in a lightweight way, not to be a secondary method of inter-task communication.

## Detailed design

### Child tasks with `async let`

Asynchronous calls do not by themselves introduce concurrent execution. However, `async` functions may conveniently request work to be run in a child task, permitting it to run concurrently, with an `async let`:

```swift
async let result = try fetchHTTPContent(of: url)
```

Any reference to a variable declared within an `async let` is a suspension point, so it must occur within either an `await` expression or the initializer of another `async let`. If the initializer of the `async let` can throw an error, then each reference to a variable declared within that `async let` is considered to throw an error, and therefore must be enclosed in one of `try`/`try!`/`try?`. 

One of the variables for a given `async let` must be awaited at least once along all execution paths (that don't throw an error) before it goes out of scope. For example:

```swift
{
  async let result = try fetchHTTPContent(of: url)
  if condition {
    let header = await result.header
    // okay, awaited `result`
  } else {
    // error: did not await 'result' along this path. Fix this with, e.g.,
    //   _ = await result
  }
}
```

If the scope of an `async let` exits with a thrown error, the child task corresponding to the `async let` is implicitly cancelled. If the child task has already completed, its result (or thrown error) is discarded.

> **Rationale**: The requirement to await a variable from each `async let` along all (non-throwing) paths ensures that child tasks aren't being created and implicitly cancelled during the normal course of execution. Such code is likely to be needlessly inefficient and should probably be restructured to avoid creating child tasks that are unnecessary.
 
## Source compatibility

This change is purely additive to the source language. The additional use of the contextual keyword `async` in `async let` accepts new code as well-formed but does not break or change the meaning of existing code.

## Effect on ABI stability

This change is purely additive to the ABI.

## Effect on API resilience

All of the changes described in this document are additive to the language and are locally scoped, e.g., within function bodies. Therefore, there is no effect on API resilience.
