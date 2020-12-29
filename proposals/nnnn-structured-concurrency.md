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
- 
## Proposed solution

Our approach follows the principles of *structured concurrency* described above. All asynchronous functions run as part of an asynchronous task. Tasks can make child tasks that will perform work concurrently. This creates a hierarchy of tasks, and information can naturally flow up and down the hierarchy, making it convenient to manage the whole thing holistically.

### Child tasks

This proposal introduces an easy way to create child tasks with `async let`:

```swift
func makeDinner() async throws -> Meal {
  async let veggies = chopVegetables()
  async let meat = marinateMeat()
  async let oven = preheatOven(temperature: 350)

  let dish = Dish(ingredients: await [try veggies, meat])
  return try await oven.cook(dish, duration: .hours(3))
}
``` 

`async let` is similar to a `let`, in that it defines a local constant that is initialized by the expression on the right-hand side of the `=`. However, it differs in that the initializer expression is evaluated in a separate, concurrently-executing child task. On normal completion, the child task will initialize the variables in the `async let`.

Because the main body of the function executes concurrently with its child tasks, it is possible that `makeDinner` will reach the point where it needs the value of an `async let` (say, `veggies`) before that value has been produced. To account for that, reading a variable defined by an `async let` is treated as a potential suspension point, and therefore must be marked with `await`. When the expression on right-hand side of the `=` of an `async let` can throw an error, that thrown error can be observed when reading the variable, and therefore must be marked with some form of `try`.
The task will suspend until the child task has completed initialization of the variable (or thrown an error), and then resume.

One can think of `async let` as introducing a (hidden) future, which is created at the point of declaration of the `async let` and whose value is retrieved at the `await`. In this sense, `async let` is syntactic sugar to futures.

However, child tasks in the proposed structured-concurrency model are (intentionally) more restricted than general-purpose futures. Unlike in a typical futures implementation, a child task does not persist beyond the scope in which it was created. By the time the scope exits, the child task must either have completed, or it will be implicitly awaited. When the scope exits via a thrown error, the child task will be implicitly cancelled before it is awaited.

Bringing it back to our example, note that the `chopVegetables()` function might throw an error if, say, there is an incident with the kitchen knife. That thrown error completes the child task for chopping the vegetables. The error will then be propagated out of the `makeDinner()` function, as expected. On exiting the body of the `makeDinner()` function with this error, any child tasks that have not yet completed (marinating the meat or preheating the oven, maybe both) will be automatically cancelled.

### Task groups

A *task group* defines a scope in which one can create new child tasks programmatically. As with all child tasks, the child tasks within the task group scope must complete when the scope exits, and will be implicitly cancelled first if the scope exits with a thrown error. This is equivalent to the behavior of `async let` variables, but is more suitable for a dynamic set of child tasks.

To illustrate task groups, we'll stretch our example even and consider our `chopVegetables()` operation, which produces an array of `Vegetable` values. With enough cooks, we could chop our vegetables even faster if we divided up the chopping for each kind of vegetable. 

Let's start with a sequential version of `chopVegetables()`:

```swift
/// Sequentially chop the vegetables.
func chopVegetables() async throws -> [Vegetable] {
  var veggies: [Vegetable] = gatherRawVeggies()
  for i in veggies.indices {
    veggies[i] = try await veggies[i].chopped()
  }
  return veggies
}
```

Introducing `async let` into the loop would not produce any meaningful concurrency, because each `async let` would need to complete before the next iteration of the loop could start. To create child tasks programmatically, we introduce a new task group via `Task.withGroup`:

```swift
/// Concurrently chop the vegetables.
func chopVegetables() async throws -> [Vegetable] {
  // Create a task group where each task produces (Int, Vegetable).
  try await Task.withGroup(resultType: (Int, Vegetable).self) { group in 
    var veggies: [Vegetable] = gatherRawVeggies()
    
    // Create a new child task for each vegetable that needs to be 
    // chopped.
    for i in veggies.indices {
      await group.add { 
        (i, veggies[i].chopped())
      }
    }

    // Wait for all of the chopping to complete, slotting each result
    // into its place in the array as it becomes available.
    while let (index, choppedVeggie) = try await group.next() {
      veggies[index] = choppedVeggie
    }
    
    return veggies
  }
}
```

The `Task.withGroup(resultType:body:)` function introduces a new scope in which child tasks can be created (using the task group's `add` method). All tasks in a given task group produce a value of the same type (specified by the `resultType` argument). The `next` method waits for the next child task to complete, providing the result value from the child task. In our example above, each child task produces the index where the result should go, along with the chopped vegetable.

As with the child tasks created by `async let`, if the closure passed to `Task.withGroup` exits without having completed all child tasks, the task group will wait until all child tasks have completed before returning. If the closure exited with a thrown error, the child tasks will first be cancelled.

Although we have explained child tasks "as if" there were a hidden future, that future instance is intentionally not exposed in the interfaces of either `async let` or task groups. Therefore, there is no way in which a reference to the child task can escape the scope in which the child task is created. This ensures that the structure of structured concurrency is maintained. It both makes it easier to reason about the concurrent tasks that are executing within a given scope and also unlocks numerous optimization opportunities for the compiler and runtime. 

### `async let` as sugar to task groups

`async let` can be desugared to task groups. The illustrate, we will implement the `makeDinner()` function using task groups alone. The desugaring requires us to provide a single result type for all of the tasks that go into the task group, so we model each of the `async let`s in scope with a different case of an enum:

```swift
enum DinnerChild {
  case chopVegetables([Vegetable])
  case marinateMeat(Meat)
  case preheatOven(Oven)
}
```

We can then re-implement `makeDinner` with only a task group:

```swift
func makeDinnerTaskGroup() async throws -> Meal {
  withTaskGroup(resultType: DinnerChildTask.self) { group in    
    await group.add {
      DinnerChild.chopVegetables(await chopVegetables())
    }
    
    await group.add {
      DinnerChild.marinateMeat(await marinateMeat())
    }
    
    await group.add {
      DinnerChild.preheatOven(await preheatOven(temperature: 350))
    }
    
    var veggies: [Vegetable]? = nil
    var meat: Meat? = nil
    var oven: Oven? = nil
    var dish: Dish? = nil
    while let child = try await group.next() {
      switch child {
        case .chopVegetables(let newVeggies):
          veggies = newVeggies
        case .marinateMeat(let newMeat):
          meat = newMeat
        case .preheatOven(let newOven):
          oven = newOven
      }
      
      if dish == nil, let veggies = veggies, let meat = meat {
        dish = Dish(ingredients: [veggies, meat])
      }
      
      if let oven = oven, let dish = dish {
        return try await oven.cook(dish, duration: .hours(3))
      }
    }
    
    fatalError("Should have returned above")
  }
}
```

The task-group implementation accounts for the tasks completing in any order by decoding the task result and placing it into one of several named variables. It then implements a simple state machine to (e.g.) prepare the dish once the meat and veggies are available, then cook the meal once the dish is prepared and the oven is preheated.

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

A program can use `@main` with an `async main()` function to initiate asynchronous work:

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

A task can be cancelled asynchronously by any context that has a reference to a task or one of its parent tasks. Cancellation can be triggered explicitly by calling `cancel()` on the task handle. Cancellation can also trigger automatically, for example when a parent task throws an error out of a scope with unawaited child tasks (such as an `async let` or the closure passed to `Task.withGroup`).

The effect of cancellation within the cancelled task is fully cooperative and synchronous. That is, cancellation has no effect at all unless something checks for cancellation. Conventionally, most functions that check for cancellation report it by throwing `CancellationError()`; accordingly, they must be throwing functions, and calls to them must be decorated with some form of `try`. As a result, cancellation introduces no additional control-flow paths within asynchronous functions; you can always look at a function and see the places where cancellation can occur. As with any other thrown error, `defer` blocks can be used to clean up effectively after cancellation.

With that said, the general expectation is that asynchronous functions should attempt to respond to cancellation by promptly throwing or returning. In most functions, it should be sufficient to rely on lower-level functions that can wait for a long time (for example, I/O functions or `Task.Handle.get()`) to check for cancellation and abort early. Functions which perform a large amount of synchronous computation may wish to periodically check for cancellation explicitly.

Cancellation has two effects which trigger immediately with the cancellation:

- A flag is set in the task which marks it as having been cancelled; once this flag is set, it is never cleared. Operations running synchronously as part of the task can check this flag and are conventionally expected to throw a `CancellationError`.

- Any cancellation handlers which have been registered on the task are immediately run. This permits functions which need to respond immediately to do so.

We can illustrate cancellation with a version of the `chopVegetables()` function we saw previously:

```swift
func chopVegetables() async throws -> [Vegetable] {
  async let carrot = chop(Carrot()) // (1) throws UnfortunateAccidentWithKnifeError()!
  async let onion = chop(Onion()) // (2)
  
  return try await [carrot, onion] // (3)
}
```

On line *(1)*, we start a new child task to chop a carrot. Suppose that this call to the `chop` function throws an error. Because this is asynchronous, that error is not immediately observed in `chopVegetables`, and we proceed to start a second child task to chop an onion *(2)*. On line *(3)*, we `await` the carrot-chopping task, which causes us to throw the error that was thrown from `chop`. Since we do not handle this error, we exit the scope without having yet awaited the onion-chopping task. This causes that task to be automatically cancelled. Because cancellation is cooperative, and because structured concurrency does not allow child tasks to outlast their parent context, control does not actually return until the onion-chopping task actually completes; any value it returns or throws will be discarded.

As we mentioned before, the effect of cancellation on a task is synchronous and cooperative. Functions which do a lot of synchronous computation may wish to check explicitly for cancellation. They can do so by inspecting the task's cancelled status:

```
func chop(_ vegetable: Vegetable) async throws -> Vegetable {
  try await Task.checkCancellation() // automatically throws `CancellationError`
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

## Detailed design

### `async let`

Asynchronous calls do not by themselves introduce concurrent execution. However, `async` functions may conveniently request work to be run in a child task, permitting it to run concurrently, with an `async let`:

```swift
async let result = fetchHTTPContent(of: url)
```

Any reference to a variable that was declared in an `async let` is a potential suspension point, equivalent to a call to an asynchronous function, so it must occur within an `await` expression. The initializer of the `async let` is considered to be enclosed by an implicit `await` expression.

If the initializer of the `async let` can throw an error, then each reference to a variable declared within that `async let` clause is considered to throw an error, and therefore must also be enclosed in one of `try`/`try!`/`try?`:

```swift
func throwsNay() throws -> Int { throw Nay() }

{
  async let (yay, nay) = ("yay", throwsNay())
  
  try await yay // must be marked with `try`; throws Nay()
  // implicitly guarantees `nay` also be completed at this point
}
```

The initializer of the `async let` is considered to be enclosed by an implicit `try` expression.

The simplest way to think about it is that anything to the right hand side of the `=` of an `async let` is initiated together (as-if in an asynchronous closure), implying that if any of the values initialized by this closure throws, all other left-hand side to-be-initialized variables must also be considered as it they had thrown that error. 

There is one additional case which may need a short explanation. Multiple clauses in a single `async let` may be written like this:

```swift
{
  async
let 
    ok = "ok",
    (yay, nay) = ("yay", throw Nay())
  
  await ok
  try await yay
  // okay
}
```

In the above example one can consider each clause as it's own asynchronously initialized variable, i.e. the `ok`  is initialized on its own, and the `(yay, nay)` are initialized together as was discussed previously. 
 
A variable defined in an `async let` can not be captured by an escaping closure. 

> **Rationale**: Capture of a variable defined by an `async let` within an escaping closure would allow the implicitly-created child task to escape its lexical context, which otherwise would not be permissible.
 
### Task API

Much of the proposed implementation of structured concurrency is in the APIs for creating, querying, and managing APIs described here. 

#### `Task` type

The `Task` type is an empty `enum` that is used as a namespace for types and operations related to task management.

```swift
@frozen enum Task { }
```

Any operations that pertain to the current task will be `static` `async` functions. This ensures that the operations are only accessible from within `async` functions (which have a task) and they can only operate on the current task (rather than some arbitrary other task). 

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
  static func currentPriority() async -> Priority
}
```

The `currentPriority()` operation queries the priority of the currently-executing task. Task priorities are set on task creation (e.g., `Task.runDetached` or `Task.Group.add`) and can be escalated later, e.g., if a higher-priority task waits on the task handle of a lower-priority task.
 
#### Task handles

A task handle provides a reference to a task whose primary purpose is to retrieve the result of the task.

```swift
extension Task {
  struct Handle<Success, Failure: Error> {
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

#### Detached tasks

A new, detached task can be created with the `Task.runDetached` operation. The resulting task is represented by a `Task.Handle`.

```swift
extension Task {
  /// Create a new, detached task that produces a value of type `T`.
  @discardableResult
  static func runDetached<T>(
    priority: Priority = .default,
    operation: @escaping () async -> T
  ) -> Handle<T>

  /// Create a new, detached task that produces a value of type `T` or throws an error.
  @discardableResult
  static func runDetached<T>(
    priority: Priority = .default,
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

#### Cancellation

TODO write out these APIs


#### Voluntary Suspension

For certain tasks of long running operations, say performing many tasks in a tight loop, it might be beneficial for tasks to sometimes check in if they should perhaps suspend and offer a chance for other tasks to proceed (e.g. if all are executing on a shared, limited-concurrency pool). For this use-case `Task` includes a `yield()` operation, which is a way to explicitly suspend and give other tasks a chance to run for a while. 

```swift
extension Task {
  static func yield() async
}
```

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

A task group _guarantees_ that it will `await` for all tasks that were added to it before it returns.

This waiting can be performed either: 
- by the code within the task group itself (e.g., using `next()`, described below), or
- implicitly in the task group itself when returning from the `body`.

#### Adding tasks to a group

Within the `body` function, tasks may be added dynamically with the `add` operation. Each task produces a value of the same type (the `ResultType` generic parameter):

```swift
extension Task.Group { 
  /// Add a task to the group.
  mutating func add(
      overridingPriority: Priority? = nil,
      operation: @escaping () async throws -> TaskResult
  ) async
}
```

`add` creates a new task in the task group, which will execute the given `operation` function concurrently. The task will be a child of the task that initially created the task group (via `Task.withGroup`), and will have the same priority as that task unless given a new priority with a non-`nil` `overridingPriority` argument.

The `add` operation is `async` to allow for a form of back-pressure. If the executor on which the new task will be scheduled is oversubscribed, the `add` call itself can suspend to slow the creation of new tasks.

### Querying tasks in the group

The `next()` operation allows one to gather the results from the tasks that have been added to the group. It produces the result from one of the tasks in the group, whether it is the normal result or a thrown error. 

```swift
extension Task.Group {
  /// Wait for a task to complete and return the result it returned (or throw if it
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

##### Task Groups: Throwing and cancellation

```swift
extension Task.Group {
  /// Cancel all the remaining tasks in the task group.
  /// Any results, including errors thrown, are discarded.
  mutating func cancelAll() { ... } 
}
```

Worth pointing out here is that adding a task to a task group could fail because the task group could have been cancelled when we were about to add more tasks to it. To visualize this, let us consider the following example:

Tasks in a task group by default handle thrown errors using like the musketeers would, that is: "*One for All, and All for One!*" In other words, if a single task throws an error, which escapes into the task group, all other tasks will be cancelled and the task group will re-throw this error.

To visualize this, let us consider chopping vegetables again. One type of vegetable that can be quite tricky to chop up is onions, they can make you cry if you don't watch out. If we attempt to chop up those vegetables, the onion will throw an error into the task group, causing all other tasks to be cancelled automatically:

```swift
func chopOnionsAndCarrots(rawVeggies: [Vegetable]) async throws -> [Vegetable] {
  try await Task.withGroup { task group in // (3) will re-throw the onion chopping error
    // kick off asynchronous vegetable chopping:
    for v in rawVeggies {
      try await group.add { 
        try await v.chopped() // (1) throws
      }
    }
    
    // collect chopped up results:
    while let choppedVeggie = try await group.next() { // (2) will throw for the onion
      choppedVeggies.append(choppedVeggie)
    }
  }
}
```

Let us break up the `chopOnionsAndCarrots()` function into multiple steps to fully understand its semantics:

- first add vegetable chopping tasks to the task group
- then chopping of the various vegetables beings asynchronously,
- eventually an onion will be chopped and `throw`

##### Task Groups: Parent task cancellation

So far we did not yet discuss the cancellation of task groups. A task group can be cancelled if the task in which it was created is cancelled. Cancelling a task group cancels all the tasks within it. Attempting to add more tasks into a cancelled task group will throw a `CancellationError`. The following example illustrates these semantics:

```swift
struct WorkItem { 
  func process() async throws {
    try await Task.checkCancellation() // (4)
    // ... 
  } 
}

let handle = Task.runDetached {
  try await Task.withGroup(resultType: Int.self) { task group in
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
  try await Task.withGroup { group in 
    for order in orders {
      try await group.add { await order.confirm() } 
    }
  }
}
```

The `confirmOrders()` function will only return once all confirmations have completed, because the task group will await any outstanding tasks "at the end-edge" of its scope.

### Low-level code and integrating with legacy APIs

The low-level execution of asynchronous code occasionally requires escaping the high-level abstraction of an async functions and task groups. Also, it is important to enable APIs to interact with existing non-`async` code yet still be able to present to the users of such API a pleasant to use async function based interface.

For such situations, this proposal introduces the concept of a `Unsafe(Throwing)Continuation`:

```swift
struct UnsafeContinuation<T> {
  func resume(returning: T)
}

func withUnsafeContinuation<T>(
    operation: (UnsafeContinuation<T>) -> ()
) async -> T

struct UnsafeThrowingContinuation<T, E: Error> {
  func resume(returning: T)
  func resume(throwing: E)
}

func withUnsafeThrowingContinuation<T, E: Error>(
    operation: (UnsafeThrowingContinuation<T, E>) -> ()
) async throws -> T
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
  try await withUnsafeThrowingContinuation { continuation in
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

let veggies = try await buyVegetables(shoppingList: ["onion", "bell pepper"])
```

Thanks to weaving the right continuation resume calls into the complex callbacks of the `buyVegetables` function, we were able to offer a much nicer overload of this function, allowing our users to rely on the async/await to interact with this function.

> **The challenge with diagnostics for Unsafe**: It is theoretically possible to provide compiler diagnostics to help developers avoid *simple* mistakes with resuming the continuation multiple times (or not at all).
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

## Revision history

* Changes in the second pitch:
  * Added a "desugaring" of `async let` to task groups and more motivation for the structured-concurrency parts of the design.
  * Reflowed the entire proposal to focus on the general description of structured concurrency first, the programming model with syntax next, and then details of the language features and API design last.
  * Reworked the presentation of the Task APIs with more rationale for the design.
  * "Task nursery" has been replaced with "task group".
  * Added support for asynchronous `@main` and top-level code.
  * Specify that `try` is not required in the initializer of an `async let`, because the thrown error is only observable when reading from one of the variables.
  * `withUnsafe(Throwing)Continuation` functions have been moved out of the `Task` type.
  * Note that an `async let` variable can only be captured by a non-escaping closure.
  * Removed the requirement that an `async let` variable be awaited on all paths.

* Original pitch [document](https://github.com/DougGregor/swift-evolution/blob/06fd6b3937f4cd2900bbaf7bb22889c46b5cb6c3/proposals/nnnn-structured-concurrency.md)
