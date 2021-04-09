# `spawn let` bindings

* Proposal: [SE-MMMM](mmmm-async-let.md)
* Authors: [John McCall](https://github.com/rjmccall), [Joe Groff](https://github.com/jckarter), [Doug Gregor](https://github.com/DougGregor), [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

[Structured concurrency](nnnn-structured-concurrency.md) provides a paradigm
for spawning concurrent *child tasks* in scoped *task groups*, establishing
a well-defined hierarchy of tasks which allows for cancellation, error
propagation, priority management, and other tricky details of concurrency
management to be handled transparently. 

This proposal aims to make the common
task of spawning child tasks to run asynchronously and pass their eventual
results up to their parent, using lightweight syntax similar to `let` bindings.

Discussion threads:

- TODO

## Motivation

In [SE-304: Structured Concurrency](https://github.com/apple/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) we introduced concept of tasks and task groups, which can be used to spawn multiple concurrently executing child-tasks anc collect their results before exiting out of the task group.

Task groups are a very powerful, yet low-level, building block useful for creating powerful parallel computing patterns, such as collecting the "first few" successful results, and other typical fan-out or scatter/gather patterns. They work best for spreading out computation of same-typed operations. For example, a parallelMap could be implemented in terms of a TaskGroup. In that sense, task groups are a low level implementation primitive, and not the end-user API that developers are expected to interact with a lot, rather, it is expected that more powerful primivites are built on top of task groups.

Task Groups also automatially propagate task cancellation, priority, and task-local values through to child-tasks and offer an flexible API to collect results from those child-tasks _in completion order_, which is impossible to achieve otherwise using other structured concurrency APIs. They do all this while upholding the structured concurrency guarantees that a child-task may never "out-live" (i.e. keep running after the task group scope has exited) the parent task.

While task groups are indeed very powerful, they are hard to use with *heterogenous results* and step-by-step initialization patterns. 

The following example, an asynchronous `makeDinner` function, consists of both of those patterns. It consists of three tasks which can be performed in parallel, all yielding different result types. To proceed to the final step of the cooking process, all those results need to be obtained, and fed into the final `oven.cook(...)` function. In a way, this is the trickiest situation to implement well using task groups. Let us examine it more closely:

```swift
func makeDinner() async -> Meal {
  // Create a task group to scope the lifetime of our three child tasks
  return try await withThrowingTaskGroup(of: CookingTask.self) { group in
    // spawn three cooking tasks and execute them in parallel:
    group.spawn {
      CookingTask.veggies(try await chopVegetables())
    }
    group.spawn {
      CookingTask.meat(await marinateMeat())
    }
    group.spawn {
      CookingTask.oven(await preheatOven(temperature: 350))
    }

    // prepare variables to collect the results
    var veggies: [Vegetable]? = nil
    var meat: Meat? = nil
    var oven: Oven? = nil

    // collect the results
    for try await task in group {
      switch task {
      case .veggies(let v):
        veggies = v
      case .meat(let m):
        meat = m
      case .oven(let o):
        oven = o
      }
    }

    // ensure every variable was initialized as expected
    assert(veggies != nil)
    assert(meat != nil)
    assert(oven != nil)

    // prepare the ingredients
    var ingredients: [Ingredient] = veggies!
    ingredients.append(meat!)

    // and, finally, cook the meal, awaiting inside the group
    let dish = Dish(ingredients: ingredients)
    return try await oven!.cook(dish, duration: .hours(3))
  }
}
```

The `withTaskGroup` scope explicitly delineates any potential concurrency, because it guarantees that any child tasks spawned within it are awaited on as the group scope exits. Any results can be collected using iterating through the group. Errors and cancellation are handled automatically for us by the group.

However, this example showcases the weaknesses of the TaskGroups very well: heterogenous result processing and variable initialization become very boiler plate heavy. While there exist ideas to make this boiler plate go away in future releases, with smarter analysis and type checking, the fundamental issue remains. 

If we step back a little, we can notice that in the example each child task is really producing a *single value* and returning it back to the *parent task*, which then needs to assamble the pieces and proceed with calling some other function. We achieve this by preparing, and assigning into `Optional` variables dedicated for each of the spawned tasks. This is not ideal, since
although the code is correct as written, modifying this code to add a variable is not only boilerplate heavy, but also potentially quite error prone, leading to runtime crashes due to the force-unwraps which a well written Swift program usually would not have to resort to. 

This dataflow pattern from child tasks to parents is very common, and we want to make it as lightweight and safe as possible.

## Proposed solution

This proposal introduces a simple way to create child tasks with and await their results: `spawn let` declarations.

Using `spawn let`, our example looks like this:

```swift
// given: 
//   func chopVegetables() async throws -> [Vegetables]
//   func marinateMeat() async -> Meat
//   func preheatOven(temperature: Int) -> Oven

func makeDinner() async throws -> Meal {
  spawn let veggies = chopVegetables()
  spawn let meat = marinateMeat()
  spawn let oven = preheatOven(temperature: 350)

  let dish = Dish(ingredients: await [try veggies, meat])
  return try await oven.cook(dish, duration: .hours(3))
}
```

`spawn let` is similar to a `let`, in that it defines a local constant that is initialized by the expression on the right-hand side of the `=`. However, it differs in that the initializer expression is evaluated in a separate, concurrently-executing child task. 

The child task begins running as soon as the `spawn let` is encountered. By default, child tasks use the global, width-limited,  concurrent executor, in the same manner as task group child-tasks do. It is a future direction to allow customizing which executor these should be executing on. On normal completion, the child task will initialize the variables in the `spawn let`.

The right-hand side of a `spawn let` expression can be thought of as an implicit `@Sendable closure`, similar to how the `detach { ... }` API works, however the resulting task is a *child task* of the currently executing task. Because of this, and the need to suspend to await the results of such expression, `spawn let` declarations may only occur within an asynchronous context, i.e. an `async` function or closure.

For single statement expressions in the `spawn let` initializer, the `await` and `try` keywords may be omitted. The effects they represent carry through to the introduced constant and will have to be used on when waiting on the constant. For example, in the example shown above, the veggies are declared as `spawn let veggies = chopVegetables()`, and even through `chopVegetables` is `async` and `throws`, the `await` and `try` keywords do not have to be used on that line of code. Once waiting on the value of that `async let` constant, the compiler will enforce that the expression where the `veggies` appear must be covered by both `await` and some form of `try`.

Because the main body of the function executes concurrently with its child tasks, it is possible that the parent task (the body of `makeDinner` in this example) will reach the point where it needs the value of an `spawn let` (say,`veggies`) before that value has been produced. To account for that, reading a variable defined by an `spawn let` is treated as a potential suspension point,
and therefore must be marked with `await`. 

## Detailed design

### Declaring `spawn let` constants

`spawn let` declarations are similar to `let` declarations, however they can only appear in specific contexts.

Because the asynchronous task must be able to be awaited on in the scope it is created, it is only possible to declare `spawn let`s in contexts where it would also be legal to write an explicit `await`, i.e. asynchronous functions:

```swift
func greet() async -> String { "hi" }

func asynchronous() async {
  spawn let hello = greet()
  // ... 
  await hello
}
```

and inside asynchronous closures:

```swift
func callMe(_ maybe: () async -> String) async -> String 
  return await maybe()
}

callMe { // async closure
  spawn let hello = greet()
  // ... 
  return await hello
}
```

It is not allowed to declare `spawn let` as top-level code, in synchronous functions or closures:

```swift
spawn let top = ... // error: 'spawn let' in a function that does not support concurrency

func sync() { // note: add 'async' to function 'sync()' to make it asynchronous
  spawn let x = ... // error: 'spawn let' in a function that does not support concurrency
}

func syncMe(later: () -> String) { ... }
syncMe {
  spawn let x = ... // error: invalid conversion from 'async' function of type '() async -> String' to synchronous function type '() -> String'
}
```

A `spawn let` creates a child-task, which inherits its parent task's priority as well as task-local values. Semantically, this is equivalent to creating a one-off `TaskGroup` which spawns a single task and returns its result, however the implementation of `async let`s can make more assumptions and optimizations around the lifetime and usage of those values.

The child-task created to initialize the `spawn let` by default runs on the global concurrent, width-limited, executor that comes with the Swift Concurrency runtime. 

> Customizing the execution context of spawn lets is a future direction we are likely to explore with the introduction of Custom Executors.

The initializer of the `spawn let` can be thought of as a closure that runs the code contained within it in a separate task, very much like the explicit `group.spawn { <work here/> }` API of task groups.

Similarily to the `group.spawn()` function, the closure is `@Sendable` and `nonisolated`, meaning that it cannot access non sendable state of the enclosing context. For example, it will result in a compile time-error, preventing a potential race condition, for a `spawn let` initializer to attempt mutating a closed over variable:

```swift
var localText: [String] = ...
spawn let w = localText.removeLast() // error: mutation of captured var 'localText' in concurrently-executing code
```

The spawn let initializer may refer to any sendable state, same as any non-isolated sendable closure.

The initializer of a `spawn let` permits the omission of the `await` keyword if it is directly calling an asynchronous function, like this:

```swift
func order() async -> Order { ... }

spawn let o1 = await order()
// should be written intead as
spawn let o2 = order()
```

This is because by looking at the spawn let declaration, it is obvious that the right-hand side function will be used to initialize the left hand side, by waiting on it. This is similar to single-expression `return` keyword omission, and also applies only to single expression initializers.

It is not legal to declare a `spawn var`, as due to the complex initialization that an `async let` represents, it does not make sense to allow further external modification of them. Doing so would tremendously complicate the understandability of such asynchronous code, and undermine potential optimizations by making it harder to make assumptions about the data-flow of the values.

```swift
spawn var x = nope() // error: 'spawn' can only be used with 'let' declarations
```

### Awaiting `spawn let` values

Since `spawn let`s introduce constants that will be "filled in later" by their right-hand-side concurrently-executing task, refering to them must be covered by an `await` keyword:

```swift
spawn let name = getName() 
spawn let surname = getSurname() 
await name
await surname
```

It is also possible to simply cover the entire expression where a `spawn let` is used with just a single `await`, similar to how the same can be done with `try`:

```swift
greet(await name, await surname)
await greet(name, surname)
// or even
await print("\(name) \(surname)")
```

If the initializer of the specific `spawn let` was throwing, then awaiting on the `spawn let` constant must be covered using a variant of the `try` keyword:

```swift
spawn let ohNo = throwThings()
try await ohNo
try? await ohNo
try! await ohNo
```

Currently, it is required to cover every reference to a `spawn let` using the apropriate try and await keywords, like this:

```swift
spawn let yes = ""
spawn let ohNo = throwThings()

_ = await yes
_ = await yes
_ = try await ohNo
_ = try await ohNo
```

This is a simple rule and allows us to bring the feature forward already. It might be possible to employ control flow based analysis to enable "only the first reference to the specific `spawn let` on each control flow path has to be an `await`", as technically speaking, every following await will be a no-op and will not suspend as the value is already completed and the placeholder has been filled in.

Special attention needs to be given to the `spawn let _ = ...` form of spawn let declarations. This form of is interesting because it creates a child-task of the right hand-side initializer, however actively chooses to ignore the result. Such declaration, and the associated child-task will run, and be awaited-on implicitly as the scope it was declared is about to exit - the same way as an un-used spawn let declaration would be.

> It may be interesting for a future proposal to explore the viability of sugar to `spawn voidReturningFunction()` directly, as a `Void` returning function may often not necessarily want to be awaited on for control-flow reasons, as variables of interesting types would be.

### `spawn let` error propagation 

While it is legal to declare a `spawn let` and never await on it, it also implies that we do not particuilary care about its result.

This is the same as spawning a number of child-tasks in a task group, and not collecting their results, like so:

```swift
withTaskGroup(of: Int.self) { group in 
  group.spawn { throw Boom() }
                             
  return 0 // we didn't care about the child-task at all(!)
}
```

The above TaskGroup example will ignore the `Boom` thrown by its child task. However, it _will_ await for the task (and any other tasks it had spawned) to run to completion. If we wanted to surface all potential throws of tasks spawned in the group, we should have written: `for try await _ in group {}` which would have re-thrown the `Boom()`.

The same concept carries over to `spawn let`, where the scope of the group is replaced by the syntactic scope in which the `spawn let` was declared. For example, the following snippet is semantically equivalent to the above TaskGroup one:

```swift
// func boom() throws -> Int { throw Boom() }

func work() async -> Int {
  spawn let work: Int = boom()
  // never await work...
  return 0
}
```

This work function, will never throw, because we didn't await on the throwing `spawn let`. If we modified it to explicitly await on it, the compiler would force us to spell out not only the `await` but also the `try` keyword. The presence of the `try` keyword woult then force us to annotate the `work()` function as `throws`, as expected from normal, non-asynchronous code in Swift:

```swift
// func boom() throws -> Int { throw Boom() }

func work() async throws -> Int { // throws is enforced due to 'try await'
  spawn let work: Int = boom()
  // ... 
  return try await work // 'try' is enforced since 'boom()' was throwing
}
```

Alternatively, we could have handled the error of `work` by wrapping it in a do/catch.

### Cancellation and `spawn let` child tasks

Cancellation propagates recursively through the task hierarchy from parent to child tasks.

Because tasks spawned by `spawn let` are child task, they naturally participate in their parent's cancellation.

Cancellation of the parent task means that the scope in which the `spawn let` declarations exist is cancelled, and any of those tasks are then cancelled as well. Because cancellation in Swift is co-operative, it does not prevent the spawning of tasks automatically. The exhibits the same semantics as `TaskGroup.spawn` which, when used from an already cancelled task, _will_ spawn more child-tasks, however they will be immediately created as _cancelled_ tasks. 

It imply though that at the moment of starting a child task, it may be begin its life already, immediately, cancelled (!). We can observe this in the following example:

```swift
func printStatus(_ id: Int) { 
  print("Task(\(id)).isCancelled = \(Task.isCancelled)")
}

let handle = detach { 
  // for illustration purposes, assume we slept long enough 
  // for the cancel of this (parent) task to be in effect already
  await Task.sleep(...)
  
  spawn let one = print(1) // Task(1).isCancelled = true
  
  _ = await one
}

handle.cancel() 
```

The example uses APIs defined in the Structured Concurrency proposal: `detach` and task handle cancellation to allow us to easily illustrate that a `spawn let` performed within a task that _already is cancelled_ still spawns the child task, yet the spawned task will be immediately cancelled.

This works well with the co-operative nature of task cancellation in Swift's concurrency story. Tasks which are able and willing to participate in cancellation handling, need to check for its status using `Task.isCancelled` or `try Task.checkCancellation()` where apropriate.

> Keep in mind that cancellation always best effort and technically racy. There always exists a chance of cancellation happening before or after a specific `Task.isCancelled` check. These are the expected semantics.

### `spawn let` as sugar to task groups

**TODO NOT UPDATED YET**

`spawn let` can be be thought of as syntactic sugar to what one might otherwise express using task groups.

Each `spawn let` declaration
behaves as if it creates a new task group whose scope begins at the
`spawn let` and extends to the end of the declaration's formal scope. The
right-hand expression in the declaration is then `add`-ed as a child task.
`await`-ing the value of one of the declared variables acts like invoking
`next()` on the task group to await the result of its single child task, if
the task has not yet been completed. For example, this `spawn let` code:

```swift
// given:
//   func produceFoo() async throws -> Foo
//   func produceBar() async -> Bar
//   var shouldConsumeFooFirst: Bool

spawn let foo = produceFoo()
spawn let bar = produceBar()

if shouldConsumeFooFirst {
  consumeFoo(try await foo)
}
consumeBar(await bar)
consumeFooAgain(try await foo)
```

behaves as if it was written as this explicit task group based code:

```swift
// Await the result of an `spawn let` task group's single child task,
// saving the result in case it is dynamically awaited multiple times
func getAsyncLetGroupValue<T>(
  _ group: Task.Group<T>,
  _ cache: inout Result<T, Error>?
) async throws -> T {
  // Use the existing value if we already completed the task
  if let existingValue = cache {
    return try existingValue.get()
  } else {
    // Await the single child task
    do {
      let result = try await group.next()!
      cache = .success(result)
      return result
    } catch {
      cache = .error(error)
      throw error
    }
  }
}

// spawn let foo = produceFoo()
withTaskGroup(resultType: Foo.self) { fooGroup in
  foogroup.spawn { try await produceFoo() }
  var foo: Result<Foo, Error>?

  // spawn let bar = produceFoo()
  withTaskGroup(resultType: Bar.self) { barGroup in
    bargroup.spawn { await produceBar() }
    var bar: Result<Bar, Error>?

    if shouldConsumeFooFirst {
      // consumeFoo(try await foo)
      consumeFoo(try await getAsyncLetGroupValue(fooGroup, &foo))
    }
    // consumeBar(await bar)
    consumeBar(try! await getAsyncLetGroupValue(barGroup, &bar))
    // consumeFoo(try await foo)
    consumeFoo(try await getAsyncLetGroupValue(fooGroup, &foo))
  }
}
```

This desugaring is illustrative of the semantics of `spawn let`; the actual
implementation can take advantage of several specific properties of this code
structure to potentially be more efficient than a literal expansion into this
form.

### Limitations of `spawn let`

#### Comparison with futures

**TODO NOT UPDATED YET**

One can think of `spawn let` as introducing a (hidden) future, which is
created at the point of declaration of the `spawn let` and whose value is
retrieved at the `await`. In this sense, `spawn let` is syntactic sugar to
futures. However, child tasks in the proposed structured-concurrency model are
(intentionally) more restricted than general-purpose futures. Unlike in a
typical futures implementation, a child task does not persist beyond the scope
in which it was created. By the time the scope exits, the child task must
either have completed, or it will be implicitly awaited. When the scope exits
via a thrown error, the child task will be implicitly cancelled before it is
awaited. These limitations intentionally preserve the same properties of
structured concurrency that explicit task groups provide.

#### No dynamic child task generation

**TODO NOT UPDATED YET**

`spawn let` cannot be used to generate a dynamic number of child tasks, because
the scope of the `spawn let` is always tied to its innermost block statement,
just like a regular `let`; therefore one cannot accumulate multiple subtasks in
a loop. For instance, if we try something like this:

```swift
func chopVegetables() async throws -> [Vegetable] {
  var veggies: [Vegetable] = gatherRawVeggies()
  for i in veggies.indices {
    spawn let chopped = veggies[i].chopped()
    ...
  }
}
```

it would not produce any meaningful concurrency, because each `spawn let`
child task would be awaited for completion when it goes out of scope, before
the next iteration of the loop could start. Because Swift's conditional and
loop constructs all introduce scopes of their own, representing a dynamic
number of child tasks necessarily requires separating the scope of the child
tasks' lifetime from any one syntactic scope, and furthermore, accumulating
the results of the subtasks is likely to require more involved logic than
awaiting a single value. For these reasons, it is unlikely that syntax
sugar would give a significant advantage over using `withTaskGroup` explicitly
or over using the group's `next` method to process the child task results.
`spawn let` therefore does not try to address this class of use case.

## Source compatibility

This change is purely additive to the source language.

## Effect on ABI stability

This change is purely additive to the ABI.

## Effect on API resilience

All of the changes described in this document are additive to the language and are locally scoped, e.g., within function bodies. Therefore, there is no effect on API resilience.

## Future directions

### Custom executors and `spawn let` 

It is reasonable to request that specific `spawn let` initializers run on specific executors. 

While this usually not necessary to actor based code, because actor invocations will implicitly "hop" to the right actor as it is called, like in the example below:

```swift
actor Worker { func work() {} }
let worker: Worker = ...

spawn let x = worker.work() // implicitly hops to the worker to perform the work
```

The reasons it may be beneficial to specify an executor child-tasks should run are multiple, and the list is by no means exhaustive, but to give an idea, specifying the executor of child-tasks may:

- pro-actively fine-tune executors to completely avoid any thread and executor hopping in such tasks,
- execute child-tasks concurrently however _not_ in parallel with the creating task (e.g. make child tasks run on the same serial executor as the calling actor),
- if the child-task work is known to be heavy and blocking, it may be beneficial to delegate it to a specific "blocking executor" which would have a dedicated, small, number of threads on which it would execute the blocking work; Thanks to such separation, the main global thread-pool would not be impacted by starvation issues which such blocking tasks would otherwise cause.
- various other examples where tight control over the execution context is required...

We should be able to allow such configuration based on scope, like this:

```swift
await withTask(executor: .globalConcurrentExecutor) { 
  spawn let x = ...
  spawn let y = ...
  // x and y execute in parallel; this is equal to the default semantics
}

actor Worker {
  func work(first: Work, second: Work) async {
    await withTask(executor: self.serialExecutor) {
      // using any serial executor, will cause the tasks to be completed one-by-one,
      // concurrently, however without any real parallelism.
      spawn let x = process(first)
      spawn let y = process(second)
      // x and y do NOT execute in parallel
    }
  }
}
```

The details of the API remain to be seen, but the general ability to specify an executor for child-tasks is useful and will be considered in the future.

## Alternatives considered

### Alternative name: `async let`

The feature was previously known as `async let` yet as the work on Swift concurrency continued, based on community feedback as well as our own findings with regards of implied meanings of specific words used throughout all of Swift's concurrency APIs, we found that the word `async` is not quite right for this feature.

As `spawn let` should be thought of a specialization of TaskGroups and the child-tasks spawned by either of them inherit the same kind of semantics from their enclosing parent task, it makes sense to share the same name across the two features.

We feel that using the word `spawn` in _every_ case that involves the creation of a child-task is simple to understand and allows developers to learn and assume about both features in tandem. 

### Explicit futures

As discussed in the [structured concurrency proposal](nnnn-structured-concurrency.md#Prominent-futures),
we choose not to expose futures or `Task.Handle`s for child tasks in task groups,
because doing so either can undermine the hierarchy of tasks, by escaping from
their parent task group and being awaited on indefinitely later, or would result
in there being two kinds of future, one of which dynamically asserts that it's
only used within the task's scope. `spawn let` allows for future-like data
flow from child tasks to parent, without the need for general-purpose futures
to be exposed.

### "Don't spawn tasks when in cancelled parent"

It would be very confusing to have automatically "not run" if the parent task were cancelled. Such semantics are offered by task groups via the `group.spawnUnlessCancelled` API, however would be quite difficult to express using plain `let` declarations, as effectively all such declarations would have to become implicitly throwing, which would sacrifice their general usability. We are convienced that following through with the co-operative cancellation strategy works well for `spawn let` tasks, because it composes well with what all asynchronous functions should be handling cancellation to begin with: only when they want to, in apropriate places within their execution, and deciding by themselfes if they prefer to throw a `Task.CancellationError` or rather return a partial result when cancellation ocurrs.

## Revision history

After initial pitch (as part of Structured Concurrency):

- renamed `spawn let` to `spawn let` to be consistent with `spawn` usage in the rest of structured concurrency APIs,
- added details of cancellation handling
- added details of await handling
