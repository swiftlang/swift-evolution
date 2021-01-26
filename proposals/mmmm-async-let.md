# `async let` bindings

* Proposal: [SE-MMMM](mmmm-async-let.md)
* Authors: [John McCall](https://github.com/rjmccall), [Joe Groff](https://github.com/jckarter), [Doug Gregor](https://github.com/DougGregor), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

[Structured concurrency](nnnn-structured-concurrency.md) provides a paradigm
for spawning concurrent *child tasks* in scoped *task groups*, establishing
a well-defined hierarchy of tasks which allows for cancellation, error
propagation, priority management, and other tricky details of concurrency
management to be handled transparently. This proposal aims to make the common
task of spawning child tasks to run asynchronously and pass their eventual
results up to their parent, using lightweight syntax similar to `let` bindings.

<!-- Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/) -->

## Motivation

Task groups allow for concurrent child tasks to be spawned, automatically
waiting for all of them to complete when the task group goes out of scope,
and automatically propagating cancellation and error status from child tasks
through the parent scope. For instance, we can farm out three independent
subtasks of a dinner recipe to run concurrently like so:

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

`Task.withGroup` nicely delineates the potential concurrency, making
it possible to safely assume that the child tasks have completed successfully
if execution continues after the call to `withGroup`, which means that child
tasks can read and modify captured state from their parent scope, and the
parent can then safely observe those modifications after the task group is
completed. However, in this example, each child task is really producing a
single value and returning it back to the parent task. We achieve this here
by assigning into a shared `Optional` variable, but this is not ideal, since
although the code is correct as written, it would not be hard for a programmer
modifying this code to add a variable and forget to assign a value to it, or
remove a `group.add` call without also removing the variable and force unwrap
it populated, leading to runtime crashes Swift normally protects against.
This dataflow pattern from child tasks to parents is common, and we want to
make it as lightweight and safe as possible.

## Proposed solution

This proposal introduces an easy way to create child tasks with `async let`.
Using `async let`, our example looks like this:

```swift
func makeDinner() async throws -> Meal {
  async let veggies = chopVegetables()
  async let meat = marinateMeat()
  async let oven = preheatOven(temperature: 350)

  let dish = Dish(ingredients: await [try veggies, meat])
  return try await oven.cook(dish, duration: .hours(3))
}
```

`async let` is similar to a `let`, in that it defines a local constant that is
initialized by the expression on the right- hand side of the `=`. However, it
differs in that the initializer expression is evaluated in a separate,
concurrently-executing child task. The child task beginning running as soon as
the `async let` is encountered. On normal completion, the child task will
initialize the variables in the `async let`.

Because the main body of the function executes concurrently with its child
tasks, it is possible that the parent task (the body of `makeDinner` in this
example) will reach the point where it needs the value of an `async let` (say,
`veggies`) before that value has been produced. To account for that, reading a
variable defined by an `async let` is treated as a potential suspension point,
and therefore must be marked with `await`. When the expression on right-hand
side of the `=` of an `async let` can throw an error, that thrown error will be
propagated through the parent task when reading the variable, and therefore
accessing the variable must be marked with some form of `try`.
The task will suspend until the child task has completed initialization of the
variable (or thrown an error), and then resume.

Bringing it back to our example, note that the `chopVegetables()` function
might throw an error if, say, there is an incident with the kitchen knife. That
thrown error completes the child task for chopping the vegetables. The error
will then be propagated out of the `makeDinner()` function, as expected. On
exiting the body of the `makeDinner()` function with this error, any child
tasks that have not yet completed (marinating the meat or preheating the oven,
maybe both) will be automatically cancelled.  `async let` is similar to a
`let`, in that it defines a local constant that is initialized by the
expression on the right-hand side of the `=`. However, it differs in that the
initializer expression is evaluated in a separate, concurrently-executing child
task which runs as part of an implicit task group.  The child task can begin
running as soon as the `async let` is encountered.  On normal completion, the
child task will initialize the variables in the `async let`. The parent task
can `await` the value of the variable, at which point it suspends execution
until the result is available; if the child task can raise an error, then the
parent task must `try` awaiting its value, and the child task's error will
propagate through the parent.

## Detailed design

### `async let` as sugar to task groups

`async let` can be desugared to task groups. Each `async let` declaration
behaves as if it creates a new task group whose scope begins at the
`async let` and extends to the end of the declaration's formal scope. The
right-hand expression in the declaration is then `add`-ed as a child task.
`await`-ing the value of one of the declared variables acts like invoking
`next()` on the task group to await the result of its single child task, if
the task has not yet been completed. For example, this `async let` code:

```swift
// given:
//   func produceFoo() async throws -> Foo
//   func produceBar() async -> Bar
//   var shouldConsumeFooFirst: Bool

async let foo = produceFoo()
async let bar = produceBar()

if shouldConsumeFooFirst {
  consumeFoo(try await foo)
}
consumeBar(await bar)
consumeFooAgain(try await foo)
```

behaves as if it was written as this explicit task group based code:

```swift
// Await the result of an `async let` task group's single child task,
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

// async let foo = produceFoo()
Task.withGroup(resultType: Foo.self) { fooGroup in
  fooGroup.add { try await produceFoo() }
  var foo: Result<Foo, Error>?

  // async let bar = produceFoo()
  Task.withGroup(resultType: Bar.self) { barGroup in
    barGroup.add { await produceBar() }
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

This desugaring is illustrative of the semantics of `async let`; the actual
implementation can take advantage of several specific properties of this code
structure to potentially be more efficient than a literal expansion into this
form.

### Limitations of `async let`

#### Comparison with futures

One can think of `async let` as introducing a (hidden) future, which is
created at the point of declaration of the `async let` and whose value is
retrieved at the `await`. In this sense, `async let` is syntactic sugar to
futures. However, child tasks in the proposed structured-concurrency model are
(intentionally) more restricted than general-purpose futures. Unlike in a
typical futures implementation, a child task does not persist beyond the scope
in which it was created. By the time the scope exits, the child task must
either have completed, or it will be implicitly awaited. When the scope exits
via a thrown error, the child task will be implicitly cancelled before it is
awaited. These limitations intentionally preserve the same properties of
structured concurrency that explicit task groups provide.

#### No dynamic child task generation

`async let` cannot be used to generate a dynamic number of child tasks, because
the scope of the `async let` is always tied to its innermost block statement,
just like a regular `let`; therefore one cannot accumulate multiple subtasks in
a loop. For instance, if we try something like this:

```swift
func chopVegetables() async throws -> [Vegetable] {
  var veggies: [Vegetable] = gatherRawVeggies()
  for i in veggies.indices {
    async let chopped = veggies[i].chopped()
    ...
  }
}
```

it would not produce any meaningful concurrency, because each `async let`
child task would be awaited for completion when it goes out of scope, before
the next iteration of the loop could start. Because Swift's conditional and
loop constructs all introduce scopes of their own, representing a dynamic
number of child tasks necessarily requires separating the scope of the child
tasks' lifetime from any one syntactic scope, and furthermore, accumulating
the results of the subtasks is likely to require more involved logic than
awaiting a single value. For these reasons, it is unlikely that syntax
sugar would give a significant advantage over using `Task.withGroup` explicitly
or over using the group's `next` method to process the child task results.
`async let` therefore does not try to address this class of use case.

## Source compatibility

This change is purely additive to the source language.

## Effect on ABI stability

This change is purely additive to the ABI.

## Effect on API resilience

All of the changes described in this document are additive to the language and are locally scoped, e.g., within function bodies. Therefore, there is no effect on API resilience.

## Alternatives considered

### Explicit futures

As discussed in the [structured concurrency proposal](nnnn-structured-concurrency.md#Prominent-futures),
we choose not to expose futures or `Task.Handle`s for child tasks in task groups,
because doing so either can undermine the hierarchy of tasks, by escaping from
their parent task group and being awaited on indefinitely later, or would result
in there being two kinds of future, one of which dynamically asserts that it's
only used within the task's scope. `async let` allows for future-like data
flow from child tasks to parent, without the need for general-purpose futures
to be exposed.
