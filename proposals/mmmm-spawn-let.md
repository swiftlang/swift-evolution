# `spawn let` bindings

* Proposal: [SE-MMMM](mmmm-spawn-let.md)
* Authors: [John McCall](https://github.com/rjmccall), [Joe Groff](https://github.com/jckarter), [Doug Gregor](https://github.com/DougGregor), [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

[Structured concurrency](0304-structured-concurrency.md) provides a paradigm
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

In [SE-0304: Structured Concurrency](0304-structured-concurrency.md) we introduced the concept of tasks and task groups, which can be used to spawn multiple concurrently executing child-tasks and collect their results before exiting out of the task group.

Task groups are a very powerful, yet low-level, building block useful for creating powerful parallel computing patterns, such as collecting the "first few" successful results, and other typical fan-out or scatter/gather patterns. They work best for spreading out computation of same-typed operations. For example, a parallelMap could be implemented in terms of a TaskGroup. In that sense, task groups are a low level implementation primitive, and not the end-user API that developers are expected to interact with a lot, rather, it is expected that more powerful primitives are built on top of task groups.

Task Groups also automatically propagate task cancellation, priority, and task-local values through to child-tasks and offer an flexible API to collect results from those child-tasks _in completion order_, which is impossible to achieve otherwise using other structured concurrency APIs. They do all this while upholding the structured concurrency guarantees that a child-task may never "out-live" (i.e. keep running after the task group scope has exited) the parent task.

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

The `withThrowingTaskGroup` scope explicitly delineates any potential concurrency, because it guarantees that any child tasks spawned within it are awaited on as the group scope exits. Any results can be collected by iterating through the group. Errors and cancellation are handled automatically for us by the group.

However, this example showcases the weaknesses of the TaskGroups very well: heterogenous result processing and variable initialization become very boiler plate heavy. While there exist ideas to make this boiler plate go away in future releases, with smarter analysis and type checking, the fundamental issue remains. 

If we step back a little, we can notice that in the example each child task is really producing a *single value* and returning it back to the *parent task*, which then needs to assemble the pieces and proceed with calling some other function. We achieve this by preparing, and assigning into `Optional` variables dedicated for each of the spawned tasks. This is not ideal, since
although the code is correct as written, modifying this code to add a variable is not only boilerplate heavy, but also potentially quite error prone, leading to runtime crashes due to the force-unwraps which a well written Swift program usually would not have to resort to. 

This dataflow pattern from child tasks to parents is very common, and we want to make it as lightweight and safe as possible.

## Proposed solution

This proposal introduces a simple way to create child tasks and await their results: `spawn let` declarations.

Using `spawn let`, our example looks like this:

```swift
// given: 
//   func chopVegetables() async throws -> [Vegetables]
//   func marinateMeat() async -> Meat
//   func preheatOven(temperature: Int) async -> Oven

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

For single statement expressions in the `spawn let` initializer, the `await` and `try` keywords may be omitted. The effects they represent carry through to the introduced constant and will have to be used when waiting on the constant. In the example shown above, the veggies are declared as `spawn let veggies = chopVegetables()`, and even through `chopVegetables` is `async` and `throws`, the `await` and `try` keywords do not have to be used on that line of code. Once waiting on the value of that `spawn let` constant, the compiler will enforce that the expression where the `veggies` appear must be covered by both `await` and some form of `try`.

Because the main body of the function executes concurrently with its child tasks, it is possible that the parent task (the body of `makeDinner` in this example) will reach the point where it needs the value of a `spawn let` (say,`veggies`) before that value has been produced. To account for that, reading a variable defined by a `spawn let` is treated as a potential suspension point,
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

A `spawn let` creates a child-task, which inherits its parent task's priority as well as task-local values. Semantically, this is equivalent to creating a one-off `TaskGroup` which spawns a single task and returns its result, however the implementation of `spawn let`s can make more assumptions and optimizations around the lifetime and usage of those values.

The child-task created to initialize the `spawn let` by default runs on the global concurrent, width-limited, executor that comes with the Swift Concurrency runtime. 

> Customizing the execution context of spawn lets is a future direction we are likely to explore with the introduction of Custom Executors.

The initializer of the `spawn let` can be thought of as a closure that runs the code contained within it in a separate task, very much like the explicit `group.spawn { <work here/> }` API of task groups.

Similarly to the `group.spawn()` function, the closure is `@Sendable` and `nonisolated`, meaning that it cannot access non-sendable state of the enclosing context. For example, it will result in a compile-time error, preventing a potential race condition, for a `spawn let` initializer to attempt mutating a closed-over variable:

```swift
var localText: [String] = ...
spawn let w = localText.removeLast() // error: mutation of captured var 'localText' in concurrently-executing code
```

The spawn let initializer may refer to any sendable state, same as any non-isolated sendable closure.

The initializer of a `spawn let` permits the omission of the `await` keyword if it is directly calling an asynchronous function, like this:

```swift
func order() async -> Order { ... }

spawn let o1 = await order()
// should be written instead as
spawn let o2 = order()
```

This is because by looking at the spawn let declaration, it is obvious that the right-hand side function will be used to initialize the left hand side, by waiting on it. This is similar to single-expression `return` keyword omission, and also applies only to single expression initializers.

It is illegal to declare a `spawn var`. This is due to the complex initialization that a `spawn let` represents, it does not make sense to allow further external modification of them. Doing so would tremendously complicate the understandability of such asynchronous code, and undermine potential optimizations by making it harder to make assumptions about the data-flow of the values.

```swift
spawn var x = nope() // error: 'spawn' can only be used with 'let' declarations
```

Other than having to be awaited to access its value, a `spawn let` behaves just like a typical `let`, as such it is not possible to pass it `inout` to other functions - simply because it is a `let`, and those may not be passed as `inout`.

#### Declaring `spawn let` with patterns

It is possible to create a `spawn let` where the left hand side is a pattern, e.g. a tuple, like this:

```swift
func left() async -> String { "l" }
func right() async -> String { "r" }

spawn let (l, r) = (left(), right())

await l // at this point `r` is also assumed awaited-on
```

To understand the execution semantics of the above snippet, we can remember the sugaring rule that the right-hand side of a `spawn let` effectively is just a concurrently executing asynchronous closure:

```swift
spawn let (l, r) = {
  return await (left(), right())
  // -> 
  // return (await left(), await right())
}
```

meaning that the entire initializer of the `spawn let` is a single task, and if multiple asynchronous function calls are made inside it, they are performed one-by one. This is a specific application of the general rule of `spawn let` initializers being allowed to omit a single leading `await` keyword before their expressions. Because in this example, we invoke two asynchronous functions to form a tuple, the await can be moved outside of the expression, and that await is what is omitted in the short hand form of the `spawn let` that we've seen in the first snippet.

This also means that as soon as we enter continue past the line of `await l` it is known that the `r` value also has completed sucessfully (and will not need to emit an "implicit await" which we'll discuss in detail below).

Another implication of these semantics is that if _any_ piece of the initializer throws, any await on such pattern declared `spawn let` shall be considered throwing, as they are initialized "together". To visualize this, let us consider the following:

```swift
spawn let (yay, nay) = ("yay", throw Boom())
try await yay // because the (yay, nay) initializer is throwing
```

Because we know that the right-hand side is simply a single closure, performing the entire initialization, we know that if any of the operations on the right hand size is throwing, the entire initializer will be considered throwing. As such, awaiting even the `yay` here must be ready for that initializer to have thrown and therefore must include the `try` keyword in addition to `await`.

### Awaiting `spawn let` values

Since `spawn let`s introduce constants that will be "filled in later" by their right-hand-side concurrently-executing task, referring to them must be covered by an `await` keyword:

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

Currently, it is required to cover every reference to a `spawn let` using the appropriate `try` and `await` keywords, like this:

```swift
spawn let yes = ""
spawn let ohNo = throwThings()

_ = await yes
_ = await yes
_ = try await ohNo
_ = try await ohNo
```

This is a simple rule and allows us to bring the feature forward already. It might be possible to employ control flow based analysis to enable "only the first reference to the specific `spawn let` on each control flow path has to be an `await`", as technically speaking, every following await will be a no-op and will not suspend as the value is already completed and the placeholder has been filled in.

### Implicit `spawn let` awaiting 

A `spawn let` that was declared but never awaited on *explicitly* as the scope in which it was declared exits, will be awaited on implicitly. These semantics are put in place to uphold the Structured Concurrency guarantees provided by `spawn let`.

To showcase these semantics, let us have a look at this function which spawns two child tasks, `fast` and `slow` but does not await on any of them:

```swift
func go() async { 
  spawn let f = fast() // 300ms
  spawn let s = slow() // 3seconds
  return "nevermind..."
  // implicitly: cancels f
  // implicitly: cancels s
  // implicitly: await f
  // implicitly: await s
}
```

Assuming the execution times of `fast()` and `slow()` are as the comments next to them explain, the `go()` function will _always_ take at least 3 seconds to execute. Or to state the rule more generally, any structured invocation will take as much time to return as the longest of its child tasks takes to complete.

As we return from the `go()` function without ever having awaited on the `f` or `s` values, both of them will be implicitly cancelled and awaited on before returning from the function `go()`. This is the very nature of structured concurrency, and avoiding this can _only_ be done by creating non-child tasks, e.g. by using `detach` or other future APIs which would allow creation of non-child tasks.

If we instead awaited on one of the values, e.g. the fast one (`f`) the emitted code would not need to implicitly cancel or await it, as this was already taken care of explicitly:

```swift
func go2() async {
  spawn let f = fast()
  spawn let s = slow()
  _ = await f
  return "nevermind..."
  // implicitly: cancels s
  // implicitly: awaits s
}
```

The duration of the `go2()` call remains the same, it is always `time(go2) == max(time(f), time(s))`.

Special attention needs to be given to the `spawn let _ = ...` form of declarations. This form is interesting because it creates a child-task of the right-hand-side initializer, however it actively chooses to ignore the result. Such a declaration (and the associated child-task) will run and be awaited-on implicitly, as the scope it was declared in is about to exit — the same way as an unused `spawn let` declaration would be.

> It may be interesting for a future proposal to explore the viability of sugar to `spawn voidReturningFunction()` directly, as a `Void` returning function may often not necessarily want to be awaited on for control-flow reasons, as variables of interesting types would be.

### `spawn let` and closures

Because `spawn let` tasks cannot out-live the scope in which they are defined, passing them to closures needs some further discussion for what is legal and not.

It is legal to capture a `spawn let` in a non-escaping asynchronous closure, like this:

```swift
func greet(_ f: () async -> String) async -> String { await f() }

spawn let name = "Alice"
await greet { await name }
```

Notice how we are required to write the `await` inside the closure as well as in front of the `greet` function. This is on purpose as we do want to be explicit about the await inside the closure. 

The same applies to auto closures, in order to make it explicit that the await is happening _inside_ the closure rather than before it, it is required to await explicitly in parameter position where the auto closure is formed for the argument:

```swift
func greet(_ f: @autoclosure () async -> String) async -> String { await f() }

spawn let name = "Bob"
await greet(await name) // await on name is required, because autoclosure
```

It is *not* legal to escape a `spawn let` value to an escaping closure. This is because structures backing the spawn let implementation may be allocated on the stack rather than the heap. This makes them very efficient, and makes great use of the structured guarantees they have to adhere to. These optimizations, however, make it unsafe to pass them to any escaping contexts:

```swift
func greet(_ f: @escaping () async -> String) async -> String { somewhere = f; somewhere() }

spawn let name = "Bob"
await greet { await name } // error: cannot escape 'spawn let' value
```



> Note: If Swift had a `@useImmediately` annotation that could be used together with even escaping closures, as they would "promise" to be called immediately without detaching or storing the closure elsewhere.

### `spawn let` error propagation

While it is legal to declare a `spawn let` and never explicitly `await` on it, it also implies that we do not particularly care about its result.

This is the same as spawning a number of child-tasks in a task group, and not collecting their results, like so:

```swift
try await withThrowingTaskGroup(of: Int.self) { group in 
  group.spawn { throw Boom() }
                             
  return 0 // we didn't care about the child-task at all(!)
} // returns 0
```

The above TaskGroup example will ignore the `Boom` thrown by its child task. However, it _will_ await for the task (and any other tasks it had spawned) to run to completion before the `withThrowingTaskGroup` returns. If we wanted to surface all potential throws of tasks spawned in the group, we should have written: `for try await _ in group {}` which would have re-thrown the `Boom()`.

The same concept carries over to `spawn let`, where the scope of the group is replaced by the syntactic scope in which the `spawn let` was declared. For example, the following snippet is semantically equivalent to the above TaskGroup one:

```swift
// func boom() throws -> Int { throw Boom() }

func work() async -> Int {
  spawn let work: Int = boom()
  // never await work...
  return 0
  // implicitly: cancels work
  // implicitly: awaits work, discards errors
}
```

This `work()` function will never throw, because we didn't await on the throwing `spawn let`. If we modified it to explicitly await on it, the compiler would force us to spell out not only the `await` but also the `try` keyword. The presence of the `try` keyword would then force us to annotate the `work()` function as `throws`, as expected from normal, non-asynchronous code in Swift:

```swift
// func boom() throws -> Int { throw Boom() }

func work() async throws -> Int { // throws is enforced due to 'try await'
  spawn let work: Int = boom()
  // ... 
  return try await work // 'try' is enforced since 'boom()' was throwing
}
```

Alternatively, we could have handled the error of `work` by wrapping it in a do/catch.

#### Discussion: Should it be required to always await `await` any `spawn let` declaration

The current proposal pitches that one should be able to omit awaiting on declared `spawn let`s, like this:

```swift
func hello(guest name: String) async -> String {
  spawn let registered = register(name: name, delayInSeconds: 3)
  // ... 
  return "Hello \(name)!"
  // implicitly cancels the 'registered' child-task
  // implicitly awaits the 'registered' child-task
}
```

Under the current proposal, this function will execute the x task, and before it returns the "hello!" it will wait cancel the still ongoing task `registered`, and await on it. If the task `registered` were to throw an error, that error would be discarded! This may be suprising.

Especially error handling may become tricky and hard to locate why a piece of code is misbehaving, because the `spawn let` declaration actually has _hidden_ the fact that `register` actually was a throwing function that performed validation if the name is allowed to be greeted or not!

The argument for the current semantics goes that since we did not await the task, we did not care about its result, or even failure to produce a result. 

It could be argued however, that given a more complex function, with many branches in the code, we _do_ want to always await on child-tasks that may produce errors on every code path because those are important, even if not result producing values! Even in our simple `hello` function above we did actually want to ensure we waited on the registered, what we actually wanted to write is:

```swift
func hello(guest name: String) async -> String {
  spawn let registered = register(name: name, delayInSeconds: 3)
  // ... 
  
  _ = try await registered
  // registration didn't throw, let's greet the guest!
  
  return "Hello \(name)!"
}
```

For values and functions like the one above, where the value was _never_ used in the entire body of the function, the existing "*value was not used*" warnings should be able to help developers spot the issue. 

However, in functions with more complex control flow, we wonder if this allowing to ellude awaits is a good notion to follow or not. For example, the following snippet showcases a situation where the programmer made a mistake and forgot to `try await` on the `registered` result in one of the branches before returning:

```swift
func hello(guest name: String) async -> String {
  spawn let registered = register(name: name, delayInSeconds: 3)
  // ... 
 
   if isFriday { 
     print("It's friday!")
   } else {
     _ = try await registered
     // registration didn't throw, let's greet the guest!  
     print("Any other day of the week.")
   }
 
  return "Hello \(name)!"
}
```

By just looking at this code, it is not clear if the programmer _intentionally_ did not await on the registration on the `isFriday` branch, or if it is a real mistake and the check must always throw. In other words, is this a place where everyone is let in on fridays, but on other days only registered members are allowed on? :thinking: The code does not help us understand the real intent of the code and we would have to resort to code comments to understand the intent.

It might be better if it were _enforced_ by the compiler to _always_ (unless throwing or returning) to have to await on all `spawn let` declarations. E.g. in the example above, we could detect that there exist branches on which the registered was not awaited on, and signal this as an error to the programmer, who would have to:

- either fill in the apropriate `try await registered` inside the isFriday branch, or
- move the `spawn let registered` declaration into the else branch of the if -- we indeed only perform this check on non-fridays.

This rule might be too cumbersome for some code though, so perhaps this warrants a future extension where it is possible to require `@exhaustiveSpawnLetWaiting` on function level, to enforce that spawn lets are awaited on on all code paths.

We could also step-back and double down on the correctness and require always waiting on all declared `spawn let` declared values at least once on all code paths. This has a potential to cause an effect of multiple awaits at the end of functions: 

```swift
func work() async throws {
  spawn let one = doTheWork()
  spawn let two = doTheWork()
  spawn let three = doTheWork()
  await one, two, tree
}
```

but then again, perhaps this is showcasing an issue with the functions construction? It would also help with diagnosing accidentally omitted throws, because if any of such omitted throws were forced to be awaited on, we would notice it:

```swift
func work() async throws {
  spawn let one = doTheWork()
  spawn let two = doTheWork()
  spawn let three = boom()
  try await one, two, tree // ah, right three could have thrown
}
```

We would like to get a shared understanding of the tradeoffs leaving the "allow not awaiting" rule as the default has, and if the community is aware of the dangers it implies.

Another potential idea here would be to allow omitting `await` inside the initializer of a `spawn let` if it is a single function call, however _do_ require the `try` keyword nevertheless. This at least would signal some caution to programmers as they would have to remember that the task they spawned may have interesting error information to report.

### Cancellation and `spawn let` child tasks

Cancellation propagates recursively through the task hierarchy from parent to child tasks.

Because tasks spawned by `spawn let` are child tasks, they naturally participate in their parent's cancellation.

Cancellation of the parent task means that the context in which the `spawn let` declarations exist is cancelled, and any tasks created by those declatations will be cancelled as well. Because cancellation in Swift is co-operative, it does not prevent the spawning of tasks, however tasks spawned from a cancelled context are *immediately* marked as cancelled. The exhibits the same semantics as `TaskGroup.spawn` which, when used from an already cancelled task, _will_ spawn more child-tasks, however they will be immediately created as cancelled tasks – which they can inspect by calling `Task.isCancelled`.

We can observe this in the following example:

```swift
let handle = detach { 
  // don't write such spin loops in real code (!!!)
  while !Task.isCancelled {
    // keep spinning
    await Task.sleep(...)
  }
  
  assert(Task.isCancelled) // parent task is cancelled
  spawn let childTaskCancelled = Task.isCancelled // child-task is spawned and is cancelled too
  
  assert(await childTaskCancelled)
}

handle.cancel() 
```

The example uses APIs defined in the Structured Concurrency proposal: `detach` to obtain a handle for the detached task which we can cancel explicitly. This allows us to easily illustrate that a `spawn let` entered within a task that _already is cancelled_ still spawns the child task, yet the spawned task will be immediately cancelled - as witnessed by the `true` returned into the `childTaskCancelled` variable.

This works well with the co-operative nature of task cancellation in Swift's concurrency story. Tasks which are able and willing to participate in cancellation handling, need to check for its status using `Task.isCancelled` or `try Task.checkCancellation()` where apropriate.

### Analysis of limitations and benefits of `spawn let`

#### Comparing with `TaskGroup`

Semantically, one might think of a `spawn let` as sugar for manually using a task group, spawning a single task within it and collecting the result from `group.next()` wherever the spawn let declared value is `await`-ed on. As we saw in the Motivation section of the proposal, such explicit usage of groups ends up very verbos and error prone in practice, thus the need for a "sugar" for the specific pattern.

A `spawn let` declaration, in reality, is not just a plain sugar-syntax for task groups and can make use of additional known-at-compile time structure of the declared tasks. For example, it is possible to avoid heap allocations  for small enough spawn let child tasks, avoid queues and other mechanisms which a task group must make use of to implement it's "by completion order" yielding of values out of `next()`. 

This comes at a price though, spawn let declarations are less flexible than groups, and this is what we'll explore in this section.

Specifically, `spawn let` declarations are not able to express dynamic numbers of tasks executing in parallel, like this group showcases:

```swift
func toyParallelMap<A, B>(_ items: [A], f: (A) async -> B) async -> [B] { 
  return await withTaskGroup(of: (Int, B).self) { 
    var bs: [B] = []
    bs.reserveCapacity(items.count)
    
    // spawn off processing all `f` mapping functions in parallel
		// in reality, one might want to limit the "width" of these
    for i in items.indices { 
      group.spawn { (i, await f(items[i])) }
    }
    
    // collect all results
    for await (i, ) in group {
      bs.append(mapped)
    }
    
    return bs
  }
}
```

In the above `toyParallelMap` the number of child-tasks is _dynamic_ because it depends on the count of elements in the `items` array _at runtime_. Such patterns are not possible to express using `spawn let` because we'd have to know how many `spawn let` declarations to create *at compile time*. One might attempt to simulate these by:

```swift
// very silly example to show limitations of `spawn let` when facing dynamic numbers of tasks
func toyParallelMapExactly2<A, B>(_ items: [A], f: (A) async -> B) async -> [B] { 
  assert(items.count == 2)
  spawn let f0 = f(items[0])
  spawn let f1 = f(items[1])
  
  return await [f0, f1]
}
```

And while the second example reads very nicely, it cannot work in practice to implement such parallel map function, because the size of the input `items` is not known (and we'd have to implement `1...n` versions of such function).

Another API which is not implementable with `spawn let` and will require using a task group is anything that requires some notion of completion order. Because `spawn let` declarations must be awaited on it is not possible to express "whichever completes first" and a task group must be used to implement such API. 

For example, the `race(left:right:)` function shown below, runs two child tasks in parallel, and returns whichever completed first. Such API is not possible to implement using spawn let and must be implemented using a group:

```swift
func race(left: () async -> Int, right: () async -> Int) async -> Int {
  await withTaskGroup(of: Int) { 
    group.spawn { left() }
    group.spawn { right() }

    return await group.next()! // !-safe, there is at-least one result to collect
  }
}
```

#### Comparing with Task.Handle, and (not proposed) futures

It is worth comparing `spawn let` declarations with the one other API proposed so far that is able to start asynchronous tasks: `detach` and the `Task.Handle` that it returns.

First off, `detach` most of the time should not be used at all, because it does _not_ propagate task priority, tash-local values or the execution context of the caller. Not only that but a detached task is inherently not _structued_ and thus may out-live its defining scope.

This immediately shows how `spawn let` and the general concept of child-tasks are superior to detached tasks. They automatically propagate all necessary information about scheduling and metadata necessary for execution tracing. And they can be allocated more efficiently than detached tasks.

So while in theory one can think of `spawn let` as introducing a (hidden) `Task.Handle` or future, which is created at the point of declaration of the `spawn let` and whose value is retrieved at the `await` in practice, this comparison fails to notice the primary strenght of async lets: structured concurrency child-tasks.

Child tasks in the proposed structured-concurrency model are (intentionally) more restricted than general-purpose futures. Unlike in a typical futures implementation, a child task does not persist beyond the scope in which it was created. By the time the scope exits, the child task must either have completed, or it will be implicitly awaited. When the scope exits via a thrown error, the child task will be implicitly cancelled before it is awaited. These limitations intentionally preserve the same properties of structured concurrency that explicit task groups provide.

It is also on purpose, and unlike Task.Handles and futures that it is not possible to pass a "still being computed" value to another function. With handles or futures one is quite used to "pass the handle" to another function like this:

```swift
func take(h: Task.Handle<String, Error>) async -> String {
  return await h.get()
}
```

this goes 

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

As discussed in the [structured concurrency proposal](nnnn-structured-concurrency.md#Prominent-futures), we choose not to expose futures or `Task.Handle`s for child tasks in task groups, because doing so either can undermine the hierarchy of tasks, by escaping from their parent task group and being awaited on indefinitely later, or would result in there being two kinds of future, one of which dynamically asserts that it's only used within the task's scope. `spawn let` allows for future-like data flow from child tasks to parent, without the need for general-purpose futures to be exposed.

### "Don't spawn tasks when in cancelled parent"

It would be very confusing to have automatically "not run" if the parent task were cancelled. Such semantics are offered by task groups via the `group.spawnUnlessCancelled` API, however would be quite difficult to express using plain `let` declarations, as effectively all such declarations would have to become implicitly throwing, which would sacrifice their general usability. We are convienced that following through with the co-operative cancellation strategy works well for `spawn let` tasks, because it composes well with what all asynchronous functions should be handling cancellation to begin with: only when they want to, in apropriate places within their execution, and deciding by themselfes if they prefer to throw a `Task.CancellationError` or rather return a partial result when cancellation ocurrs.

## Revision history

After initial pitch (as part of Structured Concurrency):

- renamed `spawn let` to `spawn let` to be consistent with `spawn` usage in the rest of structured concurrency APIs,
- added details of cancellation handling
- added details of await handling
