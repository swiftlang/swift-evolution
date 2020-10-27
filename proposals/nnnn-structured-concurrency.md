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

  let dish = Dish(ingredients: [veggies, meat])
  return await try oven.cook(dish, duration: .hours(3))
}
``` 

Each step in our dinner preparation is an asynchronous operation, so there are numerous suspension points. While waiting for the vegetables to be chopped, `makeDinner` won't block a thread: it will suspend until the vegetables are available, then resume. Presumably, many dinners could be in various stages of preparation, with most suspended until their current step is completed.

However, even though our dinner preparation is asynchronous, it is still *sequential*. It waits until the vegetables have been chopped before starting to marinate the meat, then waits again until the meat is ready before preheating the oven. Our hungry patrons will be very hungry indeed by the time dinner is finally done.

To make dinner preparation go faster, we want to use concurrency. The vegetables can be chopped at the same time as the meat is marinating and the oven is preheating. We can be combining the ingredients into the dish while the oven preheats. By overlapping the steps, we can cook our dinner faster.

## Proposed solution

Structured concurrency provides an ergonomic way to introduce concurrency into asynchronous functions. Every asynchronous function runs as part of an asynchronous *task*, which is the analogue of a thread. Structured concurrency allows a task to easily create child tasks, which perform some work on behalf of---and concurrently with---the task itself.

### Child tasks
This proposal introduces an easy way to create child tasks with `async let`:

```swift
func makeDinner() async throws -> Meal {
  async let veggies = chopVegetables()
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

Bringing it back to our example, note that the `preheatOven(temperature:)` function might throw an error if, say, the oven breaks. That thrown error completes the child task for preheating the oven. The error will then be propagated out of the `makeDinner()` function, as expected. On exiting the body of the `makeDinner()` function, any child tasks that have not yet completed (chopping the vegetables or marinating the meat, may be both) will be automatically cancelled.

### Nurseries

The `async let` construct makes it easy to create a set number of child tasks and associate them with variables. However, the construct does not work as well with dynamic workloads, where we don't know the number child tasks we will need to create because (for example) it is dependent on the size of a data structure. For that, we need a more dynamic construct: a task *nursery*.

A nursery defines a scope in which one can create new child tasks programmatically. As with all child tasks, the child tasks within the nursery must complete when the scope exits or they will be implicitly cancelled. Nurseries also provide utilities for working with the child tasks, e.g., by waiting until the next child task completes.

To stretch our example even further, let's consider our `chopVegetables()` operation, which produces an array of `Vegetable` values. With enough cooks, we could chop our vegetables even faster if we divided up the chopping for each kind of vegetable. Let's start with a sequential version of `chopVegetables()`:

```swift
/// Sequentially chop the vegetables.
func chopVegetables() async -> [Vegetable] {
  var veggies: [Vegetable] = gatherRawVeggies()
  for i in veggies.indices {
    veggies[i] = await veggies[i].chopped()
  }
  return veggies
}
```

Introducing `async let` into the loop would not produce any meaningful concurrency, because each `async let` would need to complete before the next iteration of the loop could start. To create child tasks programmatically, we introduce a nursery within a new scope via `withNursery`:

```swift
/// Sequentially chop the vegetables.
func chopVegetables() async -> [Vegetable] {
  // Create a task nursery where each task produces (Int, Vegetable).
  Task.withNursery(resultType: (Int, Vegetable).self) { nursery in 
    var veggies: [Vegetable] = gatherRawVeggies()
    
    // Create a new child task for each vegetable that needs to be 
    // chopped.
    for i in rawVeggies.indices {
      await nursery.add { 
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

A task can be in one of three states:

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

### Partial tasks

The execution of a task can be seen as a succession of periods where the task was running, each of which ends at a suspension point or — finally — at the completion of the task.  These periods are called partial tasks.  Partial tasks are the basic units of schedulable work in the system.  They are also the primitive through which asynchronous functions interact with the underlying synchronous world.  For the most part, programmers should not have to work directly with partial tasks unless they are implementing a custom executor.

### Executors

An executor is a service which accepts the submission of partial tasks and arranges for some thread to run them.  The system assumes that executors are reliable and will never fail to run a partial task.  An asynchronous function that is currently running always knows the executor that it's running on.  This allows the function to avoid unnecessarily suspending when making a call to the same executor, and it allows the function to resume executing on the same executor it started on.

An executor is called exclusive if the partial tasks submitted to it will never be run concurrently.  (Specifically, the partial tasks must be totally ordered by the happens-before relationship: given any two tasks that were submitted and run, the end of one must happen-before the beginning of the other.)  Executors are not required to run partial tasks in the order they were submitted; in fact, they should generally honor task priority over submission order.

### Cancellation

A task can be cancelled asynchronously by any context that has a reference to a task or one of its parent tasks.  However, the effect of cancellation on the task is cooperative and synchronous.  Cancellation sets a flag in the task which marks it as having been cancelled; once this flag is set, it is never cleared.  Executing a suspension point alone does not check cancellation. Operations running synchronously as part of the task can check this flag and are conventionally expected to throw a `CancellationError`. As with thrown errors, `defer` blocks are still executed when a task is cancelled, allowing code to introduce cleanup logic.

No information is passed to the task about why it was cancelled.  A task may be cancelled for many reasons, and additional reasons may accrue after the initial cancellation (for example, if the task fails to immediately exit, it may pass a deadline).  The goal of cancellation is to allow tasks to be cancelled in a lightweight way, not to be a secondary method of inter-task communication.

### Child tasks with `async let`

Asynchronous calls do not by themselves introduce concurrent execution. However, `async` functions may conveniently request work to be run in a child task, permitting it to run concurrently, with an `async let`:

```swift
async let result = try fetchHTTPContent(of: url)
```

Any reference to a variable declared within an `async let` is a suspension point, equivalent to a call to an asynchronous function, so it must occur within an `await` expression. The initializer of the `async let` is considered to be enclosed by an implicit `await` expression.

If the initializer of the `async let` can throw an error, then each reference to a variable declared within that `async let` is considered to throw an error, and therefore must also be enclosed in one of `try`/`try!`/`try?`. 

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
