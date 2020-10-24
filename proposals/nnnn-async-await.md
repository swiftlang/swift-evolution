# Async/await

* Proposal: [SE-NNNN](NNNN-async-await.md)
* Authors: [John McCall](https://github.com/rjmccall), [Doug Gregor](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

Modern Swift development involves a lot of asynchronous programming using closures and completion handlers, but these APIs are hard to use.  This gets particularly problematic when many asynchronous operations are used, error handling is required, or control flow between asynchronous calls gets complicated.  This proposal describes a language extension to make this a lot more natural and less error prone.

This design introduces a [coroutine model](https://en.wikipedia.org/wiki/Coroutine) to Swift. Functions can opt into to being `async`, allowing the programmer to compose complex logic involving asynchronous operations, providing [structured concurrency](https://en.wikipedia.org/wiki/Structured_concurrency) so that normal control-flow mechanisms (calls, error handling, etc.) work as expect. The compiler is responsible for translating an asychronous function into the appropriate set of closures and state machines.

This proposal defines the semantics of asynchronous functions as well as related concepts such as the task structure, cancellation of tasks, and so on. However, the specific details of the APIs for triggering these operations, such as launching a new (detached) asynchronous task, cancelling a task, or setting the priority for a given task, will be left to separate proposals. 

This draws some inspiration (and most of the Motivation section) from an earlier proposal written by 
[Chris Lattner](https://github.com/lattner) and [Joe Groff](https://github.com/jckarter), available [here](https://gist.github.com/lattner/429b9070918248274f25b714dcfc7619), which itself is derived from a proposal written by [Oleg Andreev](https://github.com/oleganza), available [here](https://gist.github.com/oleganza/7342ed829bddd86f740a). It has been significantly rewritten (again), and many details have changed, but the core ideas of asynchronous functions have remained the same.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation: Completion handlers are suboptimal

To provide motivation for why it is important to do something here, lets look at some of the problems caused by implementing asynchronous code with completion handlers.

#### Problem 1: Pyramid of doom

A sequence of simple asynchroncous operations often involves deeply-nested closures. Here is a made up example showing this:

```swift
func processImageData1(completionBlock: (result: Image) -> Void) {
    loadWebResource("dataprofile.txt") { dataResource in
        loadWebResource("imagedata.dat") { imageResource in
            decodeImage(dataResource, imageResource) { imageTmp in
                dewarpAndCleanupImage(imageTmp) { imageResult in
                    completionBlock(imageResult)
                }
            }
        }
    }
}

processImageData1 { image in
    display(image)
}
```

This "pyramid of doom" makes it difficult to keep track of code that is running, and the stack of closures leads to many second order effects.

#### Problem 2: Error handling

Handling errors becomes difficult and very verbose. Swift 2 introduced an error handling model for synchronous code, but callback-based interfaces do not derive any benefit from it:

```swift
func processImageData2(completionBlock: (result: Image?, error: Error?) -> Void) {
    loadWebResource("dataprofile.txt") { dataResource, error in
        guard let dataResource = dataResource else {
            completionBlock(nil, error)
            return
        }
        loadWebResource("imagedata.dat") { imageResource, error in
            guard let imageResource = imageResource else {
                completionBlock(nil, error)
                return
            }
            decodeImage(dataResource, imageResource) { imageTmp, error in
                guard let imageTmp = imageTmp else {
                    completionBlock(nil, error)
                    return
                }
                dewarpAndCleanupImage(imageTmp) { imageResult in
                    guard let imageResult = imageResult else {
                        completionBlock(nil, error)
                        return
                    }
                    completionBlock(imageResult)
                }
            }
        }
    }
}

processImageData2 { image, error in
    guard let image = image else {
        error("No image today")
        return
    }
    display(image)
}
```

The addition of [`Result`](https://github.com/apple/swift-evolution/blob/main/proposals/0235-add-result.md) to the standard library improved on this for Swift APIs (asynchronous APIs were one of the [main motivators](https://github.com/apple/swift-evolution/blob/main/proposals/0235-add-result.md#asynchronous-apis) for `Result`): 

```swift
func processImageData2(completionBlock: (Result<Image>) -> Void) {
    loadWebResource("dataprofile.txt") { dataResourceResult in
        dataResourceResult.map { dataResource in
            loadWebResource("imagedata.dat") { imageResourceResult in
                imageResultResult.map { imageResource in
                    decodeImage(dataResource, imageResource) { imageTmpResult in
                        imageTmpResult.map { imageTmp in 
                            dewarpAndCleanupImage(imageTmp) { imageResult in
                                completionBlock(imageResult)
                            }
                        }
                    }
                }
            }
        }
    }
}

processImageData2 { result in
    switch result {
    case .success(image):
        display(image)
    case .failure(error):
        error("No image today")
    }
}
```

It's easier to properly thread the error through when using `Result`, and the code is shorter, but the nesting problem remains.

#### Problem 3: Conditional execution is hard and error-prone

Conditionally executing an asynchronous function is a huge pain.  Perhaps the best approach is to write half of the code in a helper "continuation" closure that is conditionally executed, like this:

```swift
func processImageData3(recipient: Person, completionBlock: (result: Image) -> Void) {
    let continuation: (contents: image) -> Void = {
      // ... continue and call completionBlock eventually
    }
    if recipient.hasProfilePicture {
        continuation(recipient.profilePicture)
    } else {
        decodeImage { image in
            continuation(image)
        }
    }
}
```

#### Problem 4: Many mistakes are easy to make

It's easy to bail out by simply returning without calling the appropriate block. When forgotten, the issue is very hard to debug:

```swift
func processImageData4(completionBlock: (result: Image?, error: Error?) -> Void) {
    loadWebResource("dataprofile.txt") { dataResource, error in
        guard let dataResource = dataResource else {
            return // <- forgot to call the block
        }
        loadWebResource("imagedata.dat") { imageResource, error in
            guard let imageResource = imageResource else {
                return // <- forgot to call the block
            }
            ...
        }
    }
}
```

When you do not forget to call the block, you can still forget to return after that.
Thankfully `guard` syntax protects against that to some degree, but it's not always relevant.

```swift
func processImageData5(recipient:Person, completionBlock: (result: Image?, error: Error?) -> Void) {
    if recipient.hasProfilePicture {
        if let image = recipient.profilePicture {
            completionBlock(image) // <- forgot to return after calling the block
        }
    }
    ...
}
```

#### Problem 5: Because completion handlers are awkward, too many APIs are defined synchronously

This is hard to quantify, but the authors believe that the awkwardness of defining and using asynchronous APIs (using completion handlers) has led to many APIs being defined with apparently synchronous behavior, even when they can block.  This can lead to problematic performance and responsiveness problems in UI applications - e.g. spinning cursor.  It can also lead to the definition of APIs that cannot be used when asynchrony is critical to achieve scale, e.g. on the server.

## Proposed solution: async/await

Asynchronous functions--often known as async/await--allow asynchronous code to be written as if it were straight-line, synchronous code.  This immediately addresses many of the problems described above by allowing programmers to make full use of the same language tools that are available in synchronous code.  It also naturally preserves the semantic structure of the code, allowing the language to preserve necessary information dynamically for cross-cutting concerns like priority and cancellation, allowing the language implementation to achieve better performance, and allowing language tooling to provide a more consistent-feeling debugging, profiling, and code exploration experience. The example from the prior section demonstrates how async/await drastically simplifies asynchronous code:

```swift
func loadWebResource(_ path: String) async throws -> Resource
func decodeImage(_ r1: Resource, _ r2: Resource) async throws -> Image
func dewarpAndCleanupImage(_ i : Image) async throws -> Image

func processImageData2() async -> Image {
  let dataResource  = await try loadWebResource("dataprofile.txt")
  let imageResource = await try loadWebResource("imagedata.dat")
  let imageTmp      = await try decodeImage(dataResource, imageResource)
  let imageResult   = await try dewarpAndCleanupImage(imageTmp)
  return imageResult
}
```

Many descriptions of async/await discuss its common implementation mechanism: a compiler pass which divides a function into multiple components.  This is important at a low level of abstraction in order to understand how the machine is operating, but at a high level we’d like to encourage you to ignore it.  Instead, think of an asynchronous function as an ordinary function that has the special power to give up its thread.  Asynchronous functions don’t typically use this power directly; instead, they make calls, and sometimes these calls will require them to give up their thread and wait for something to happen.  When that thing is complete, the function will pick up executing again.

The analogy with synchronous functions is very strong.  A synchronous function can make a call; when it does this, it immediately waits for the call to complete; when the call completes, control returns to the function and it picks up where it was.  The same thing is true with an asynchronous function: it can make calls; when it does this, it (normally) immediately waits for the call to complete; when the call completes, control returns to the function and it picks up where it was.  The only difference is that synchronous functions get to take full advantage of (part of) their thread and its stack, whereas asynchronous functions have to be able to completely give up that stack and use their own, separate storage.  This has some implementation cost, but we can reduce that quite a bit by designing holistically around it.

Because asynchronous functions must be able to abandon their thread, and synchronous functions don’t know how to abandon a thread, a synchronous function can’t ordinarily call an asynchronous function: the asynchronous function would only be able to give up the part of the thread it occupied, and if it tried, its synchronous caller would treat it like a return and try to pick up where it was, only without a return value.  The only way to make this work in general would be to block the entire thread until the asynchronous function was resumed and completed, and that would completely defeat the purpose of asynchronous functions, as well as having nasty systemic effects.

In contrast, an asynchronous function can call either synchronous or asynchronous functions.  While it’s calling a synchronous function, of course, it can’t give up its thread.  In fact, asynchronous functions never just spontaneously give up their thread; they only give up their thread when they reach what’s called a suspension point, marked by `await`.  A suspension point can occur directly within a function, or it can occur within another asynchronous function that the function calls, but in either case the function and all of its asynchronous callers simultaneously abandon the thread.  (In practice, asynchronous functions are compiled to not depend on the thread during an asynchronous call, so that only the innermost function needs to do any extra work.)

When control returns to an asynchronous function, it picks up exactly where it was.  That doesn’t necessarily mean that it’ll be running on the exact same thread it was before, because the language doesn’t guarantee that after a suspension.  In this design, threads are mostly an implementation mechanism, not a part of the intended interface to concurrency.  However, many asynchronous functions are not just asynchronous: they’re also associated with specific actors (which are the subject of a separate proposal), and they’re always supposed to run as part of that actor.  Swift does guarantee that such functions will in fact return to their actor to finish executing.  Accordingly, libraries that use threads directly for state isolation — for example, by creating their own threads and scheduling tasks sequentially onto them — should generally model those threads as actors in Swift in order to allow these basic language guarantees to function properly.

## Tasks and asynchronous scheduling

### Suspension points

A suspension point is a point in the execution of an asynchronous function where it has to give up its thread.  Suspension points are always associated with some deterministic, syntactically explicit event in the function; they’re never hidden or asynchronous from the function’s perspective.  The detailed language design will describe several different operations as suspension points, but the most important one is a call to an asynchronous function associated with a different execution context.

It is important that suspension points are only associated with explicit operations.  In fact, it’s so important that this proposal requires that calls that might suspend be enclosed in an `await` expression. This follows Swift's precedent of requiring `try` expressions to cover calls to function that can throw errors. Marking suspension points is particularly important because suspensions interrupt atomicity.  For example, if an asynchronous function is running within a given context that is protected by a serial queue, reaching a suspension point means that other code can be interleaved on that same serial queue.  A classic but somewhat hackneyed example where this atomicity matters is a modeling a bank: if a deposit is credited to one account, but the operation suspends before processing a matched withdrawal, it creates a window where those funds can be double-spent.  A more germane example for many Swift programmers is a UI thread: the suspension points are the points where the UI can be shown to the user, so programs that build part of their UI and then suspend risk presenting a flickering, partially-constructed UI.  (Note that suspension points are also called out explicitly in code using explicit callbacks: the suspension happens between the point where the outer function returns and the callback starts running.)  Calling out suspension points allows programmers to safely assume that places without suspension points will behave atomically, as well as to more easily recognize problematic non-atomic patterns.

Because suspension points are only associated with explicit operations, and those operations can only be performed by asynchronous functions, long synchronous computations can still block threads.  This might involve calling a synchronous function that just does a lot of work, or it might involve a particularly intense computation loop written directly in an asynchronous function.  In either case, the thread cannot interleave code while this computation is running, which is usually the right choice for correctness, but can also become a scalability problem.  Asynchronous programs that need to do intense computation should generally run it in a separate  context, but when that’s not possible, there will be library facilities to artificially suspend and allow other operations to be interleaved.

Asynchronous functions should avoid calling functions that can actually block the thread, especially if they can block it waiting for work that’s not guaranteed to be currently running.  For example, acquiring a mutex can only block until some currently-running thread gives up the mutex; this is sometimes acceptable but must be used carefully to avoid introducing deadlocks or artificial scalability problems.  In contrast, waiting on a condition variable can block until some arbitrary other work gets scheduled that signals the variable; this is always strongly recommended against.  It will require ongoing library work to provide abstractions that allow programs to avoid these pitfalls.

Between suspension points, asynchronous functions can rely on the thread not being interrupted.  Carefully-written code could even rely on thread-local storage.

This design currently provides no way to block the current context from interleaving code while an asynchronous function is waiting for an operation in a different context.  This is intentional: if this were possible, it would be inherently prone to deadlock.

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

Child tasks can most easily be created with the `async let` construct, which creates a child task whose result can be accessed by reading the declared variable(s). For example:

```swift
func makeDinner() async throws -> Meal {
  async let veggies = chopVegetables()
  async let meat = marinateMeat()
  async let oven = try preheatOven(temperature: 350)

  let dish = Dish(ingredients: [await veggies, await meat])
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

### Asynchronous calls

Calls to an `async` function look and act mostly like calls to a synchronous function. The apparent semantics of a call to an `async` function are:

* Arguments as evaluated using the ordinary rules, including beginning accesses for any `inout` parameters.
* The callee’s executor is determined. This proposal does not describe the rules for determining the callee's executor; see the complementary proposal about actors.
* If the callee’s executor is different from the caller’s executor, a suspension point is reached and a partial task to resume the task is enqueued on the callee’s executor.
* The callee is executed with the given arguments on its executor.
* If the callee’s executor is different from the caller’s executor, a suspension point is reached and a partial task to resume the task is enqueued on the caller’s executor.
* The caller resumes executing on its executor.  If the callee returned normally, the result of the expression is the value returned by the function; otherwise, the expression throws the error that was thrown from the callee.

That is, calls to `async` functions run synchronously from the perspective of their caller, like an ordinary call.  However, they may execute on a different executor, requiring the task to be briefly suspended. Note also that the duration of `inout` accesses is potentially much longer due to the suspension over the call, so `inout` references to shared mutable state that is not sufficiently isolated are more likely to produce a dynamic exclusivity violation.

### Cancellation

A task can be cancelled asynchronously by any context that has a reference to a task or one of its parent tasks.  However, the effect of cancellation on the task is cooperative and synchronous.  Cancellation sets a flag in the task which marks it as having been cancelled; once this flag is set, it is never cleared.  Executing a suspension point alone does not check cancellation. Operations running synchronously as part of the task can check this flag and are conventionally expected to throw a `CancellationError`. As with thrown errors, `defer` blocks are still executed when a task is cancelled, allowing code to introduce cleanup logic.

No information is passed to the task about why it was cancelled.  A task may be cancelled for many reasons, and additional reasons may accrue after the initial cancellation (for example, if the task fails to immediately exit, it may pass a deadline).  The goal of cancellation is to allow tasks to be cancelled in a lightweight way, not to be a secondary method of inter-task communication.

## Detailed design

### Asynchronous functions

Function types can be marked explicitly as `async`, indicating that the function is asynchronous:

```swift
func collect(function: () async -> Int)
```

A function or initializer declaration can also be declared explicitly as `async`:

```swift
class Teacher {
  init(hiringFrom: College) async throws {
    ...
  }
  
  private func raiseHand() async -> Bool {
    ...
  }
}
```

The type of a reference to a function or initializer declared `async` is an `async` function type. If the reference is a “curried” static reference to an instance method, it is the "inner" function type that is `async`, consistent with the usual rules for such references.

Special functions like `deinit` and storage accessors cannot be `async`.

> **Rationale**: Properties that only have a getter could potentially be `async`. However, properties that also have an `async` setter imply the ability to pass the property as `inout`, and to drill down in to the properties of that property itself, which depend on the setter effectively being an "instantaneous" (synchronous, non-throwing) operation. Prohibiting `async` properties is a simpler rule than only allowing get-only `async` properties.
 
If a function is both `async` and `throws` (or `rethrows`), `async` must precede `throws`. 

> **Rationale** : This order restriction is arbitrary, but it's not harmful, and it eliminates the potential for stylistic debates.

### Asynchronous function types

Asynchronous function types are distinct from their synchronous counterparts. There is no implicit conversion from a value of a synchronous function type to the corresponding asynchronous function type. However, the implicit conversion from a value of non-throwing asynchronous function type to its corresponding throwing asynchronous function type is permitted. For example:

```swift
struct FunctionTypes {
  var syncNonThrowing: () -> Void
  var syncThrowing: () throws -> Void
  var asyncNonThrowing: () async -> Void
  var asyncThrowing: () async throws -> Void
  
  mutable func demonstrateConversions() {
    // Okay to convert to throwing form
    syncThrowing = syncNonThrowing
    asyncThrowing = asyncNonThrowing
    
    // Error to convert between asynchronous and synchronous
    asyncNonThrowing = syncNonThrowing // error
    syncNonThrowing = asyncNonThrowing // error
    asyncThrowing = syncThrowing       // error
    syncThrowing = asyncThrowing       // error
  }
}
```

One can manually create an `async` closure that calls synchronous functions, so the lack of implicit conversion does not affect the expressivity of the model. See the section on "Closures" for the syntax to define an `async` closure.

> **Rationale**: We do not propose the implicit conversion from a synchronous function to an asynchronous function because it complicates type checking, particularly in the presence of synchronous and asynchronous overloads of the same function. See the section on "Overloading and overload resolution" for more information.

### Child tasks with `async let`

Asynchronous calls ordinarily run synchronously from the perspective from the caller.  `async` functions may conveniently request work to be run in a child task, permitting it to run concurrently:

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
 
### Await expressions

Any potential suspension point must occur within an asynchronous context (e.g., an `async` function). Furthermore, it must occur within the operand of an `await` expression or the initializer of an `async let`. There are two kinds of suspension points:
* A call to a value of `async` function type (including a direct call to an `async` function).
* A use of a variable introduced by an `async let`.

Consider the following example:

```swift
// func redirectURL(for url: URL) async -> URL
// func dataTask(with: URL) async throws -> URLSessionDataTask

async let newURL = server.redirectURL(for: url)
let (data, response) = await try session.dataTask(with: newURL)
```

In the code example, there are suspension points in the call to `redirectURL(for:)`, the call to `dataTask(with:)`, and the reference to `newURL`. The call to `redirectURL(for:)` is part of the initializer of the `async let`, so it does not need a separate `await` expression. The `await` is required in the final line due to the call to the `async` functions `dataTask(with:)`, as well as for the reference to the `async let` variable `newURL`. The operand of an `await` expression must contain at least one suspension point, although there may be more than one suspension point (the last line of the example above has two).

The `await` has no additional semantics; like `try`, it merely marks that an asynchronous call is being made.  The type of the `await` expression is the type of its operand, and its result is the result of its operand.

> **Rationale**: It is important that asynchronous calls be clearly identifiable within the function because they introduce suspension points, which break the atomicity of the operation.  The suspension points may be inherent to the call (because the asynchronous call must execute on a different executor) or simply be part of the implementation of the callee, but in either case it is semantically important and the programmer needs to acknowledge it. `await` expressions are also an indicator of asynchronous code, which interacts with inference in closures; see the section on "Closures" for more information.

A suspension point must not occur within an autoclosure that is not of `async` function type. A suspension point must not occur within a `defer` block.

### Closures

A closure can have `async` function type. Such closures can be explicitly marked as `async` as follows:

```swift
{ () async -> Int in
  print("here")
  return await getInt()
}
```

An anonymous closure is inferred to have `async` function type if it contains an `await` expression or an `async let`.

```swift
let closure = { await getInt() } // implicitly async

let closure2 = { () -> Int {     // implicitly async
  print("here")
  return await getInt()
}

let closure3 = { () -> Int {     // implicitly async
  async let x = getInt()
  print("here")
  return 0
}
```

Note that inference of `async` ignores nested functions or closures, because those are contexts are (separably) asynchronous or synchronous. For example:

```swift
let closure5 = { () -> Int {     // not 'async'
  let closure6 = { () -> Int {     // implicitly async
    async let x = getInt()
    print("there")
    return await x
  }
  
  print("here")
  return 5
}
```

### Overloading and overload resolution

A Swift program today that includes both synchronous and asynchronous entry points for an operation likely does so by introducing two similarly-named methods:

```swift
func doSomething() -> String { ... }
func doSomething(completionHandler: (String) -> Void) { ... }
```

At the call site, it is clear which is being called by the presence of the completion handler (or lack thereof). With the obvious mapping of the second API into an `async` one, however, the signatures are now quite similar:

```swift
func doSomething() -> String { ... }
func doSomething() async -> String { ... }

doSomething() // synchronous or asynchronous?
```

If we were to replace `async` with `throws`, declaring the two methods above would produce a compiler error about an "invalid redeclaration." However, we propose to allow `async` functions to overload non-`async` functions, so the above code is well-formed. This allows existing Swift programs to evolve `async` versions of existing synchronous functions without spurious renaming.

The ability to overload `async` and non-`async` functions is paired with an overload-resolution rule to select the appropriate function based on the context of the call. Given a call, overload resolution prefers non-`async` functions within a synchronous context (which cannot call an `async` function anyway) and prefers `async` functions within an asynchronous context (because such contexts should avoid synchronous, blocking APIs when there is an alternative). When overload resolution selects an `async` function, that call is subject to the rule that it must occur within an `await` expression.

### Autoclosures

A function may not take an autoclosure parameter of `async` function type unless the function itself is `async`. For example, the following is ill-formed:

```swift
func computeArgumentLater<T>(_ fn: @escaping @autoclosure () async -> T) { } // error: async autoclosure in a function that is not itself 'async'
```

> **Rationale**: This restriction exists for several reasons. Consider the following example:

  ```swift
  let closure = {
    computeArgumentLater(await getIntSlowly())
    print("hello")
  }
  ```

> The `await` expression implies that there is a suspension point prior to the call to `computeArgumentLater(_:)`, which is not the case: the suspension point is actually within the (auto)closure, which is of interest mainly in the body of `computeArgumentLater(_:)`. Moreover, the fact that this `await`  appears to be part of the call means that `closure` will be inferred to have `async` function type, which is also incorrect: all of the code in the closure itself is synchronous. The restriction on `async` autoclosure parameters ensures that `async` autoclosure parameters can only be used in asynchronous contexts.

## Source compatibility

This proposal is generally additive: existing code does not use any of the new features (e.g., does not create `async` functions or closures) will not be impacted. However, it introduces two new contextual keywords, `async` and `await`.

The position of the new uses of `async` within the grammer (function declarations, function types, and as a prefix for `let`) allow us to treat `async` as a contextual keyword without breaking source compatibility. A user-defined `async` can not occur in those grammatical positions in well-formed code.

The 'await' contextual keyword is more problematic, because it occurs within an expression. For example, one could define a function `await` in Swift today:

```swift
func await(_ x: Int, _ y: Int) -> Int { x + y }

let result = await(1, 2)
```

This is well-formed code today, and is a call to the `await` function. With this proposal, this becomes an `await` expression with the subexpression `(1, 2)`. This will manifest as a compile-time error for existing Swift programs, because `await` can only be used within an asynchronous context, and no existing Swift programs have such a context. Such code does not appear to be common, so we believe this to be an acceptable source break as part of the introduction of async/await.

## Effect on ABI stability

Asynchronous functions and function types are additive to the ABI, so there is no effect on ABI stability, because existing (synchronous) functions and function types are unchanged.

## Effect on API resilience

The ABI for an `async` function is completely different from the ABI for a synchronous function (e.g., they have incompatible calling conventions), so the addition or removal of `async` from a function or type is not a resilient change.

## Related proposals

In addition to this proposal, there are a number of related proposals covering different aspects of the Swift Concurrency model:

* [Concurrency Interoperability with Objective-C](https://github.com/DougGregor/swift-evolution/blob/concurrency-objc/proposals/NNNN-concurrency-objc.md): Describes the interaction with Objective-C, especially the relationship between asynchronous Objective-C methods that accept completion handlers and `@objc async` Swift methods.
* Actors: Describes the actor model, which provides state isolation for concurrent programs
* Task management: Describes task-management APIs to for detached tasks, task "nursuries" for dynamically creating child tasks, cancellation, prioritization, and so on.
