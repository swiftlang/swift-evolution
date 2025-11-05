# Run nonisolated async functions on the caller's actor by default

* Proposal: [SE-0461](0461-async-function-isolation.md)
* Authors: [Holly Borla](https://github.com/hborla), [John McCall](https://github.com/rjmccall)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Implemented (Swift 6.2)**
* Vision: [Improving the approachability of data-race safety](/visions/approachable-concurrency.md)
* Upcoming Feature Flag: `NonisolatedNonsendingByDefault`
* Previous Proposal: [SE-0338](0338-clarify-execution-non-actor-async.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-inherit-isolation-by-default-for-async-functions/74862)) ([first review](https://forums.swift.org/t/se-0461-run-nonisolated-async-functions-on-the-callers-actor-by-default/77987)) ([acceptance with focused re-review](https://forums.swift.org/t/accepted-with-modifications-and-focused-re-review-se-0461-run-nonisolated-async-functions-on-the-callers-actor-by-default/78920)) ([second review](https://forums.swift.org/t/focused-re-review-se-0461-run-nonisolated-async-functions-on-the-callers-actor-by-default/78921)) ([second acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0461-run-nonisolated-async-functions-on-the-caller-s-actor-by-default/79117))

## Introduction

Swift's general philosophy is to prioritize safety and ease-of-use over
performance, while still providing tools to write more efficient code. The
current behavior of nonisolated async functions prioritizes main actor
responsiveness at the expense of usability.

This proposal changes the behavior of nonisolated async functions to run on
the caller's actor by default, and introduces an explicit way to state that an
async function always switches off of an actor to run.

## Table of Contents

- [Motivation](#motivation)
- [Proposed solution](#proposed-solution)
- [Detailed design](#detailed-design)
  - [`nonisolated(nonsending)` functions](#nonisolatednonsending-functions)
  - [`@concurrent` functions](#concurrent-functions)
  - [Task isolation inheritance](#task-isolation-inheritance)
  - [`#isolation` macro expansion](#isolation-macro-expansion)
  - [Isolation inference for closures](#isolation-inference-for-closures)
  - [Function conversions](#function-conversions)
    - [Non-`@Sendable` function conversions](#non-sendable-function-conversions)
  - [Region isolation rules](#region-isolation-rules)
  - [Executor switching](#executor-switching)
  - [Dynamic actor isolation APIs in async contexts](#dynamic-actor-isolation-apis-in-async-contexts)
  - [Import-as-async heuristic](#import-as-async-heuristic)
- [Source compatibility](#source-compatibility)
- [ABI compatibility](#abi-compatibility)
- [Implications on adoption](#implications-on-adoption)
- [Alternatives considered](#alternatives-considered)
  - [Changing isolation inference behavior to implicitly capture isolated parameters](#changing-isolation-inference-behavior-to-implicitly-capture-isolated-parameters)
  - [Use `nonisolated` instead of a separate `@concurrent` attribute](#use-nonisolated-instead-of-a-separate-concurrent-attribute)
  - [Alternative syntax choices](#alternative-syntax-choices)
    - [No explicit spelling for `nonisolated(nonsending)`](#no-explicit-spelling-for-nonisolatednonsending)
    - [Justification for `@concurrent`](#justification-for-concurrent)
    - [`@executor`](#executor)
    - [`@isolated`](#isolated)
    - [`nonisolated` argument spelling](#nonisolated-argument-spelling)
  - [Deprecate `nonisolated`](#deprecate-nonisolated)
  - [Don't introduce a type attribute for `@concurrent`](#dont-introduce-a-type-attribute-for-concurrent)
- [Revisions](#revisions)

## Motivation

[SE-0338: Clarify the Execution of Non-Actor-Isolated Async Functions][SE-0338]
specifies that nonisolated async functions never run on an actor's executor.
This design decision was made to prevent unnecessary serialization and
contention for the actor by switching off of the actor to run the nonisolated
async function, and any new tasks it creates that inherit isolation. The actor
is then free to make forward progress on other work. This behavior is
especially important for preventing unexpected overhang on the main actor.

This decision has a number of unfortunate consequences.

**`nonisolated` is difficult to understand.** There is a semantic difference
between the isolation behavior of nonisolated synchronous and asynchronous
functions; nonisolated synchronous functions always run on the caller's actor,
while nonisolated async functions always switch off of the caller's actor. This
means that sendable checking applies to arguments and results of nonisolated
async functions, but not nonisolated synchronous functions.

For example:

```swift
class NotSendable {
  func performSync() { ... }
  func performAsync() async { ... }
}

actor MyActor {
  let x: NotSendable

  func call() async {
    x.performSync() // okay

    await x.performAsync() // error
  }
}
```

The call to `performAsync` from the actor results in a data-race safety error
because the call leaves the actor to run the function. This frees up the actor
to run other tasks, but those tasks can access the non-`Sendable` value `x`
concurrently with the call to `performAsync`, which risks a data race.

It's confusing that the two calls to methods on `NotSendable` have different
isolation behavior, because both methods are `nonisolated`.

**Async functions that run on the caller's actor are difficult to express.**
It's possible to write an async function that does not leave an actor to run
using isolated parameters and the `#isolation` macro as a default argument:

```swift
class NotSendable {
  func performAsync(
    isolation: isolated (any Actor)? = #isolation
  ) async { ... }
}

actor MyActor {
  let x: NotSendable

  func call() async {
    await x.performAsync() // okay
  }
}
```

This resolves the data-race safety error because `performAsync` now runs on the
actor. However, this isn't an obvious solution, it's onerous boilerplate to
write, and the default argument is lost if the method is used in a higher-order
manner.

**It's easy to write invalid async APIs.** If the `performAsync` method were in
a library that the programmer doesn't own, it's not possible to workaround the
data-race safety error without using unsafe opt outs. It's common for library
authors to mistakenly vend an API like this, because the data-race safety error
only manifests when calling the API from an actor.

The concurrency library itself has made this mistake, and many of the async
APIs in the concurrency library have since transitioned to inheriting the
isolation of the caller using isolated parameters; see [SE-0421][SE-0421] for
an example.

**It's difficult to write higher-order async APIs.** Consider the following
async API which provides a `with`-style method for acquiring a resource and
performing a scoped operation:

```swift
public struct Resource {
  internal init() {}
  internal mutating func close() async {}
}

public func withResource<Return>(
  isolation: isolated (any Actor)? = #isolation,
  _ body: (inout Resource) async -> Return
) async -> Return {
  var resource = Resource()
  let result = await body(&resource)
  await resource.close()
  return result
}
```

Despite `withResource` explicitly running on the caller's actor by default,
there's no way to specify that the async `body` function value should also run
in the same context. The compiler treats the async function parameter as
switching off of the actor to run, so it requires sendable checking on the
arguments and results. This particular example happens to pass a value in a
disconnected region to `body`, but passing an argument in the actor's region
would be invalid. In most cases, the call doesn't cross an isolation boundary
at runtime, because the function type is not `@Sendable`, so calling the API
from an actor-isolated context and passing a trailing closure will treat the
closure as isolated to the same actor. This sendable checking is often a source
of false positives that make higher-order async APIs extremely difficult to
write. The checking can't just be eliminated, because it's valid to pass a
nonisolated async function that will switch off the actor to run, which would
lead to a data race if actor-isolated state is passed to the `body` parameter.

Moreover, the above explanation of isolation rules for async closures is
extremely difficult to understand; the default isolation rules are too
complicated.

## Proposed solution

This proposal changes the execution semantics of nonisolated async functions
to always run on the caller's actor by default. This means that nonisolated
functions will have consistent execution semantics by default, regardless of
whether the function is synchronous or asynchronous.

This change makes the following example from the motivation section
valid, because the call to `x.performAsync()` does not cross an isolation
boundary:

```swift
class NotSendable {
  func performSync() { ... }
  func performAsync() async { ... }
}

actor MyActor {
  let x: NotSendable

  func call() async {
    x.performSync() // okay

    await x.performAsync() // okay
  }
}
```

Changing the default execution semantics of async functions can change the
behavior of existing code, so the change is gated behind the
`NonisolatedNonsendingByDefault` upcoming feature flag. To help stage in the new
behavior, new syntax can be used to explicitly specify the
execution semantics of an async function in any language mode.

A new `nonsending` argument can be written with `nonisolated` to indicate
that by default, the argument and result values are not sent over an
isolation boundary when the function is called:

```swift
class NotSendable {
  nonisolated(nonsending)
  func performAsync() async { ... }
}

actor MyActor {
  let x: NotSendable

  func call() async {
    await x.performAsync() // okay
  }
}
```

The `@concurrent` attribute is an explicit spelling for the behavior of
async functions in language modes <= Swift 6. `@concurrent` indicates
that calling the function always switches off of an actor to run, so
the function will run concurrently with other tasks on the caller's actor:

```swift
class NotSendable {
  @concurrent
  func alwaysSwitch() async { ... }
}

actor MyActor {
  let x: NotSendable

  func call() async {
    await x.alwaysSwitch() // error
  }
}
```

`@concurrent` is the current default for nonisolated async
functions. `nonisolated(nonsending)` will become the default for async functions
when the `NonisolatedNonsendingByDefault` upcoming feature is enabled.

## Detailed design

The sections below will explicitly use `@concurrent` and
`nonisolated(nonsending)` to demonstrate examples that will behave consistently
independent of upcoming features or language modes. However, note that the
end state under the `NonisolatedNonsendingByDefault` upcoming feature will mean
that `(nonsending)` is not necessary to explicitly write, and
`@concurrent` will likely be used sparingly because it has far
stricter data-race safety requirements.

### `nonisolated(nonsending)` functions

Async functions annotated with `nonisolated(nonsending)` will always run on the
caller's actor:

```swift
class NotSendable {
  func performSync() { ... }

  nonisolated(nonsending)
  func performAsync() async { ... }
}

actor MyActor {
  let x: NotSendable

  func call() async {
    x.performSync() // okay

    await x.performAsync() // okay
  }
}
```

In the above code, the call to `x.performAsync()` continues running on the
`self` actor instance. The code does not produce a data-race safety error,
because the `NotSendable` instance `x` does not leave the actor. In other
words, the arguments are not sent across an isolation boundary when calling
`performAsync` by default.

This behavior is accomplished by implicitly passing an optional actor parameter
to the async function. The function will run on this actor's executor. See the
[Executor switching](#executor-switching) section for more details on why the
actor parameter is necessary.

The type of an `nonisolated(nonsending)` function declaration is an
`nonisolated(nonsending)` function type. For example:

```swift
class NotSendable { ... }

@MainActor let global: NotSendable = .init()

nonisolated(nonsending)
func runOnActor(ns: NotSendable) async {}

@MainActor
func callSendableClosure() async {
  // the type of 'closure' is '@Sendable nonisolated(nonsending) (NotSendable) -> Void'
  let closure = runOnActor(ns:) 

  let ns = NotSendable()
  await closure(ns) // okay
  await closure(global) // okay
}

callSendableClosure()
```

In the above code, the calls to `closure` from `callSendableClosure` run on the
main actor, because `closure` is `nonisolated(nonsending)` and `callSendableClosure`
is main actor isolated.

### `@concurrent` functions

Async functions can be declared to always switch off of an actor to run using
the `@concurrent` attribute:

```swift
struct S: Sendable {
  @concurrent
  func alwaysSwitch() async { ... }
}
```

Only (implicitly or explicitly) `nonisolated` functions can be marked with
`@concurrent`; it is an error to use this attribute with
an isolation other than `nonisolated`, including global actors, isolated
parameters, and `@isolated(any)`:

```swift
actor MyActor {
  var value = 0

  // error: '@concurrent' can only be used with 'nonisolated' methods
  @concurrent
  func isolatedToSelf() async {
    value += 1
  }

  @concurrent
  nonisolated func canRunAnywhere() async {
    // cannot access 'value' or other actor-isolated state
  }
}
```

`@concurrent` can be used together with `@Sendable` or `sending`.

`@concurrent` cannot be applied to synchronous
functions. This is an artificial limitation that could later be lifted if use
cases arise.

The type of an `@concurrent` function declaration is an
`@concurrent` function type. Details on function conversions are
covered in a [later section](#function-conversions).

When an `@concurrent` function is called from a context that can
run on an actor, including `nonisolated(nonsending)` functions or actor-isolated
functions, sendable checking is performed on the argument and result values.
Either the argument and result values must have a type that conforms to
`Sendable`, or the values must be in a disconnected region so they can be sent
outside of the actor:

```swift
class NotSendable {}

@concurrent
func alwaysSwitch(ns: NotSendable) async { ... }

actor MyActor {
  let ns: NotSendable = .init()

  func callConcurrent() async {
    await alwaysSwitch(ns: ns) // error

    let disconnected = NotSendable()
    await alwaysSwitch(ns: disconnected) // okay
  }
}
```

### Task isolation inheritance

Unstructured tasks created in nonisolated functions never run on an actor
unless explicitly specified. This behavior is consistent for all nonisolated
functions, including synchronous functions, `nonisolated(nonsending)` async
functions, and `@concurrent` async functions.

For example:

```swift
class NotSendable {
  var value = 0
}

nonisolated(nonsending)
func createTask(ns: NotSendable) async {
  Task {
    // This task does not run on the same actor as `createTask`

    ns.value += 1 // error
  }
}
```

Capturing `ns` in the unstructured task is an error, because the value can
be used concurrently between the caller of `createTask` and the newly
created task.

This decision is deliberate to match the semantics of unstructured task
creation in nonisolated synchronous functions. Note that unstructured task
creation in methods with isolated parameters also do not inherit isolation
if the isolated parameter is not explicitly captured.

### `#isolation` macro expansion

Uses of the `#isolation` macro will expand to the implicit isolated parameter.
For example, the following program prints `Optional(Swift.MainActor)`:

```swift
nonisolated func printIsolation() async {
  let isolation = #isolation
  print(isolation)
}

@main
struct Program {
  // implicitly isolated to @MainActor
  static func main() async throws {
    await printIsolation()
  }
}
```

This behavior allows async function calls that use `#isolation` as a default
isolated argument to run on the same actor when called from an
`nonisolated(nonsending)` function. For example, the following code is valid because
the call to `explicitIsolationInheritance` does not cross an isolation
boundary:

```swift
class NotSendable { ... }

func explicitIsolationInheritance(
  ns: NotSendable,
  isolation: isolated (any Actor)? = #isolation
) async { ... }

nonisolated(nonsending)
func printIsolation(ns: NotSendable) async {
  await explicitIsolationInheritance(ns: ns) // okay
}
```

Note that this introduces a semantic difference compared to synchronous
nonisolated functions, where there is no implicit isolated parameter and
`#isolation` always expands to `nil`. For example, the following program prints
`nil`:

```swift
func printIsolation() {
  let isolation = #isolation
  print(isolation)
}

@main
struct Program {
  // implicitly isolated to @MainActor
  static func main() async throws {
    printIsolation()
  }
}
```

In an `@concurrent` function, the `#isolation` macro expands to
`nil`.

### Isolation inference for closures

Note that the rules in this section are not new with this proposal. However,
these rules have not been specified in any other proposal, and they are
necessary for understanding the execution semantics of async closures.

The isolation of a closure can be explicitly specified with a type annotation
or in the closure signature. If no isolation is specified,  the inferred
isolation for a closure depends on two factors:
1. The isolation of the context where the closure is formed.
2. Whether the contextual type of the closure is `@Sendable` or `sending`.

If the contextual type of the closure is neither `@Sendable` nor `sending`, the
inferred isolation of the closure is the same as the enclosing context:

```swift
class NotSendable { ... }

@MainActor
func closureOnMain(ns: NotSendable) async {
  let syncClosure: () -> Void = {
    // inferred to be @MainActor-isolated

    // capturing main-actor state is okay
    print(ns)
  }

  // runs on the main actor
  syncClosure()

  let asyncClosure: (NotSendable) async -> Void = {
    // inferred to be @MainActor-isolated

    print($0)
  }

  // runs on the main actor;
  // passing main-actor state is okay
  await asyncClosure(ns)
}
```

If the type of the closure is `@Sendable` or if the closure is passed to a
`sending` parameter, the closure is inferred to be `nonisolated`.

The closure is also inferred to be `nonisolated` if the enclosing context
has an isolated parameter (including `self` in actor-isolated methods), and
the closure does not explicitly capture the isolated parameter. This is done to
avoid implicitly capturing values that are invisible to the programmer, because
this can lead to reference cycles.

### Function conversions

Function conversions can change isolation. You can think of this like a
closure with the new isolation that calls the original function, asynchronously
if necessary. For example, a function conversion from one global-actor-isolated
type to another can be conceptualized as an async closure that calls the
original function with `await`:

```swift
@globalActor actor OtherActor { ... }

func convert(
  closure: @OtherActor () -> Void
) {
  let mainActorFn: @MainActor () async -> Void = closure

  // The above conversion is the same as:

  let mainActorEquivalent: @MainActor () async -> Void = {
    await closure()
  }
}
```

A function conversion that crosses an isolation boundary must only
pass argument and result values that are `Sendable`; this is checked
at the point of the function conversion. For example, converting an
actor-isolated function type to a `nonisolated` function type requires
that the argument and result types conform to `Sendable`:

```swift
class NotSendable {}
actor MyActor {
  var ns = NotSendable()

  func getState() -> NotSendable { ns }
}

func invalidResult(a: MyActor) async -> NotSendable {
  let grabActorState: nonisolated(nonsending) () async -> NotSendable = a.getState // error

  return await grabActorState()
}
```

In the above code, the conversion from the actor-isolated method `getState`
to a `nonisolated(nonsending)` function is invalid, because the
result type does not conform to `Sendable` and the result value could be
actor-isolated state. The `nonisolated` function can be called from
anywhere, which would allow access to actor state from outside the actor.

Not all function conversions cross an isolation boundary, and function
conversions that don't can safely pass non-`Sendable` arguments and results.
For example, a `nonisolated(nonsending)` function type can always be converted to an
actor-isolated function type, because the `nonisolated(nonsending)` function will
simply run on the actor:

```swift
class NotSendable {}

nonisolated(nonsending)
func performAsync(_ ns: NotSendable) async { ... }

@MainActor
func convert(ns: NotSendable) async {
  // Okay because 'performAsync' will run on the main actor
  let runOnMain: @MainActor (NotSendable) async -> Void = performAsync

  await runOnMain(ns)
}
```

The following table enumerates each function conversion rule and specifies
which function conversions cross an isolation boundary. Function conversions
that cross an isolation boundary require `Sendable` argument and result types,
and the destination function type must be `async`. Note that the function
conversion rules for synchronous `nonisolated` functions and asynchronous
`nonisolated(nonsending)` functions are the same; they are both
represented under the "Nonisolated" category in the table:

| Old isolation        | New isolation          | Crosses Boundary |
|----------------------|------------------------|------------------|
| Nonisolated          | Actor isolated         | No               |
| Nonisolated          | `@isolated(any)`       | No               |
| Nonisolated          | `@concurrent`          | Yes              |
| Actor isolated       | Actor isolated         | Yes              |
| Actor isolated       | `@isolated(any)`       | No               |
| Actor isolated       | Nonisolated            | Yes              |
| Actor isolated       | `@concurrent`          | Yes              |
| `@isolated(any)`     | Actor isolated         | Yes              |
| `@isolated(any)`     | Nonisolated            | Yes              |
| `@isolated(any)`     | `@concurrent`          | Yes              |
| `@concurrent`        | Actor isolated         | Yes              |
| `@concurrent`        | `@isolated(any)`       | No               |
| `@concurrent`        | Nonisolated            | Yes              |

#### Non-`@Sendable` function conversions

If a function type is not `@Sendable`, only one isolation domain can
reference the function at a time, and calls to the function may never
happen concurrently. These rules for non-`Sendable` types are enforced
through region isolation. When a non-`@Sendable` function is converted
to an actor-isolated function, the function value itself is merged into the
actor's region, along with any non-`Sendable` function captures:

```swift
class NotSendable {
  var value = 0
}

nonisolated(nonsending)
func convert(closure: () -> Void) async {
  let ns = NotSendable()
  let disconnectedClosure = {
    ns.value += 1
  }
  let valid: @MainActor () -> Void = disconnectedClosure // okay
  await valid()

  let invalid: @MainActor () -> Void = closure // error
  await invalid()
}
```

The function conversion for the `invalid` variable is an error because the
non-`Sendable` captures of `closure` could be used concurrently from the caller
of `convert` and the main actor.

Converting a non-`@Sendable` function type to an actor-isolated one is invalid
if the original function must leave the actor in order to be called:

```swift
nonisolated(nonsending)
func convert(
    fn1: @escaping @concurrent () async -> Void,
) async {
    let fn2: @MainActor () async -> Void = fn1 // error

    await withDiscardingTaskGroup { group in
      group.addTask { await fn2() }
      group.addTask { await fn2() }
    }
}
```

In general, a conversion from an actor-isolated function type to a
`nonisolated` function type crosses an isolation boundary, because the
`nonisolated` function type can be called from an arbitrary isolation domain.
However, if the conversion happens on the actor, and the new function type is
not `@Sendable`, then the function must only be called from the actor. In this
case, the function conversion is allowed, and the resulting function value
is merged into the actor's region:

```swift
class NotSendable {}

@MainActor class C {
  var ns: NotSendable

  func getState() -> NotSendable { ns }
}

func call(_ closure: () -> NotSendable) -> NotSendable {
  return closure()
}

@MainActor func onMain(c: C) {
  // 'result' is in the main actor's region
  let result = call(c.getState)
}
```

### Region isolation rules

`nonisolated(nonsending)` functions have the same region isolation rules as
synchronous `nonisolated` functions. When calling an `nonisolated(nonsending)`
function, all non-`Sendable` parameter and result values are merged into
the same region, but they are only merged into the caller's actor region if
one of those non-`Sendable` values is already in the actor's region.

For example:

```swift
class NotSendable {}

nonisolated(nonsending)
func identity<T>(_ t: T) async -> T {
  return t
}

actor MyActor {
  func isolatedToSelf() async -> sending NotSendable {
    let ns = NotSendable()
    return await identity(ns)
  }
}
```

The above code is valid; the implementation of `identity` can't access the
actor's state unless isolated state is passed in via one of the parameters.
Note that this code would be invalid if `identity` accepted an isolated
parameter, because the non-`Sendable` parameters and results would always be
merged into the actor's region.

This proposal allows you to access `#isolation` in the implementation of an
`nonisolated(nonsending)` function for the purpose of forwarding it along to a
method that accepts an `isolated (any Actor)?`. This is still safe, because
there's no way to access the actor's isolated state via the `Actor` protocol,
and dynamic casting to a concrete actor type will not result in a value that
the function is known to be isolated to.

### Executor switching

Async functions switch executors in the implementation when entering the
function, and after any calls to other async functions. Note that synchronous
functions do not have the ability to switch executors. If a call to a
synchronous function crosses an isolation boundary, the call must happen in an
async context and the executor switch happens at the caller.

`@concurrent` async functions switch to the generic executor, and
all other async functions switch to the isolated actor's executor.

```swift
@MainActor func runOnMainExecutor() async {
  // switch to main actor executor

  await runOnGenericExecutor()

  // switch to main actor executor
}

@concurrent func runOnGenericExecutor() async {
  // switch to generic executor

  await Task { @MainActor in
    // switch to main actor executor

    ...
  }.value

  // switch to generic executor
}
```

`nonisolated(nonsending)` functions will switch to the executor of the implicit
actor parameter passed from the caller instead of switching to the generic
executor:

```swift
@MainActor func runOnMainExecutor() async {
  // switch to main actor executor
  ...
}

class NotSendable {
  var value = 0
}

actor MyActor {
  let ns: NotSendable = .init()

  func callNonisolatedFunction() async {
    await inheritIsolation(ns)
  }
}

nonisolated func inheritIsolation(_ ns: NotSendable) async {
  // switch to isolated parameter's executor

  await runOnMainExecutor()

  // switch to isolated parameter's executor

  ns.value += 1
}
```

For most calls, the switch upon entering the function will have no effect,
because it's already running on the executor of the actor parameter.

A task executor preference can still be used to configure where a nonisolated
async function runs. However, if the nonisolated async function was called from
an actor with a custom executor, the task executor preference will not apply.
Otherwise, the code will risk a data-race, because the task executor preference
does not apply to actor-isolated methods with custom executors, and the
nonisolated async method can be passed mutable state from the actor.

### Dynamic actor isolation APIs in async contexts

Because nonisolated async functions may now execute on a specific actor at
runtime, the APIs in the Concurrency library for enforcing actor isolation
assertions and preconditions are now useful in these contexts. As such, the
`noasync` attribute will be removed from `assertIsolated`, `assumeIsolated`,
and `preconditionIsolated` on `Actor` and `MainActor`.

### Import-as-async heuristic

Nonisolated functions imported from Objective-C that match the import-as-async
heuristic from [SE-0297: Concurrency Interoperability with Objective-C][SE-0297]
will implicitly be imported as `nonisolated(nonsending)`. Objective-C async
functions already have bespoke code generation that continues running on
the caller's actor to match the semantics of the original completion handler
function, so `nonisolated(nonsending)` already better matches the semantics of these
imported `async` functions. This change will eliminate many existing data-race
safety issues that happen when calling an async function on an Objective-C
class from the main actor. Because the only effect of this change is
eliminating concurrency diagnostics -- the runtime behavior of the code will
not change -- it will not be gated behind the upcoming feature.

## Source compatibility

This proposal changes the semantics of nonisolated async functions when the
upcoming feature flag is enabled. Without the upcoming feature flag, the default
for nonisolated async functions is `@concurrent`. When the upcoming
feature flag is enabled, the default for nonisolated async functions changes to
`nonisolated(nonsending)`. This applies to both function declarations and function
values that are nonisolated (either implicitly or explicitly).

Changing the default execution semantics of nonisolated async functions has
minor source compatibility impact if the implementation calls an
`@concurrent` function and passes non-Sendable state in the actor's
region. In addition to the source compatibility impact, the change can also
regress performance of existing code if, for example, a specific async function
relied on running off of the main actor when called from the main actor to
maintain a responsive UI.

To avoid breaking source compatibility or silently changing behavior of
existing code, this change must be gated behind an upcoming feature flag.
However, unlike most other changes gated behind upcoming feature flags, this
change allows writing code that is valid with and without the upcoming feature
flag, but means something different. Many programmers have internalized the
SE-0338 semantics, and making this change several years after SE-0338 was
accepted creates an unfortunate intermediate state where it's difficult to
understand the semantics of a nonisolated async function without understanding
the build settings of the module you're writing code in.

To make it easy to discover what kind of async function you're working with,
SourceKit will surface the implicit `nonisolated(nonsending)` or `@concurrent`
attribute for IDE inspection features like Quick Help in Xcode and Hover in
VSCode. To ease the transition to the upcoming feature flag, [migration
tooling][adoption-tooling] will provide fix-its to preserve behavior by
annotating nonisolated async functions with `@concurrent`.

## ABI compatibility

Adopting the semantics to run on the caller's actor for an existing nonisolated
async function is an ABI change, because the caller's actor must be passed as
a parameter. However, a number of APIs in the concurrency library have staged
in similar changes using isolated parameters and `#isolation`, and it may be
possible to offer tools to do this transformation automatically for resilient
libraries that want to adopt this behavior.

For example, if a nonisolated async function is ABI-public and is available
earlier than a version of the Swift runtime that includes this change, the
compiler could emit two separate entry points for the function:

```swift
@_alwaysEmitIntoClient
public func myAsyncFunc() async {
  // original implementation
}

@concurrent
@_silgen_name(...) // to preserve the original symbol name
@usableFromInline
internal func abi_myAsyncFunc() async {
  // existing compiled code will continue to always run calls to this function
  // on the generic executor.
  await myAsyncFunc()
}
```

This transformation only works if the original function implementation
can be made inlinable.

## Implications on adoption

`nonisolated(nonsending)` functions must accept an implicit actor parameter. This
means that adding `nonisolated(nonsending)` to a function that is actor-isolated, or
changing a function from `@concurrent` to `nonisolated(nonsending)`, is
not a resilient change.

## Alternatives considered

### Changing isolation inference behavior to implicitly capture isolated parameters

The current isolation inference behavior in contexts with isolated parameters
is often surprising with respect to data-race safety. However, this proposal
does not suggest changing the rules, because implicitly capturing an isolated
parameter can lead to silently causing new memory leaks in existing code. One
potential compromise is to keep the current isolation inference behavior, and
offer fix-its to capture the actor if there are any data-race safety errors
from capturing state in the actor's region.

### Use `nonisolated` instead of a separate `@concurrent` attribute

It's tempting to not introduce a new attribute to control where an async
function executes, and instead control this behavior with an explicit
`nonisolated` annotation. However, this approach falls short for the following
reasons:

1. It does not accomplish the goal of having consistent semantics for
   `nonisolated` by default, regardless of whether it's applied to synchronous
   or async functions.
2. This approach cuts off the future direction of allowing
   `@concurrent` on synchronous functions.

### Alternative syntax choices

Several different options for the spelling of `nonisolated(nonsending)`
and `@concurrent` were explored. An earlier iteration of this proposal
used the same base attribute for both annotations. However, these two
annotations serve very different purposes. `@concurrent` is the long-term
right way to move functions and closures off of actors.
`nonisolated(nonsending)` is necessary for the transition to the new behavior,
but it's not a syntax that will stick around long term in Swift codebases; the
ideal end state is that this is expressed via the default behavior for
(explicitly or implicitly) `nonisolated` async functions.

Note that it is well understood that there is no perfect syntax which will
explain the semantics without other context such as educational material or
documentation. This is true for all syntax design decisions.

#### No explicit spelling for `nonisolated(nonsending)`

It's reasonable to question whether `nonisolated(nonsending)` is necessary
at all given that its only purpose is transitioning to the new behavior
for async functions. An explicit spelling that has consistent behavior
independent of upcoming features and language modes is valuable when
undertaking a transition that changes the meaning of existing code.

An explicit, transitory attribute is valuable because there will be a period of
time where it is not immediately clear from source what kind of async function
a programmer is working with. It's necessary to be able to discover that
information from source, such as by showing an inferred attribute explicitly
in SourceKit's cursor info request (surfaced by "Quick Help" in Xcode and
"Hover" in LSP / VSCode). An explicit spelling that has consistent behavior
independent of language mode is also valuable for code generation tools like
macros, so that they do not have to consider build settings to determine the
right code to generate, it's valuable for posting code snippets on the forums
during the transition period, etc.

#### Justification for `@concurrent`

This proposal was originally pitched using the `@concurrent` syntax, and many
reviewers surfaced objects about why `@concurrent` may be misleading, such as:

* `@concurrent` is not the only source of concurrency; concurrency can arise from
  many other things.
* The execution of an `@concurrent` function is not concurrent from the local
  perspective of the current task.

It's true that concurrency can only arise if there are multiple "impetuses"
(such as tasks or event sources) in the program that are running with different
isolation. But for the most part, we can assume that there are multiple
impetuses; and while those impetuses might otherwise share isolation,
`@concurrent` is the only isolation specification under this proposal that
guarantees that they do not and therefore forces concurrency. Indeed, we expect
that programmers will be reaching for `@concurrent` exactly for that reason:
they want the current function to run concurrently with whatever else might
happen in the process. So, this proposal uses `@concurrent` because out of the
other alternatives we explored, it best reflects the programmer's intent for
using the attribute.

#### `@executor`

A previous iteration of this proposal used the syntax `@execution(concurrent)`
instead of `@concurrent`. The review thread explored several variations of
this syntax, including `@executor(concurrent)` and `@executor(global)`.

However, `@execution` or `@executor` encourages
thinking about async function semantics in terms of the lower level model of
executors and threads, and we should be encouraging programmers to think about
these semantics at the higher abstraction level of actor isolation and tasks.
Trying to understand the semantics in proposal in terms of executors can also
be misleading, both because isolation does not always map naively to executor
requests and because executors are used for other things than isolation.
For example, an `@executor(global)` function could end up running on some
executor other than the global executor via task executor preferences.

#### `@isolated`

An alternative to `nonisolated(nonsending)` is to use the "isolated"
terminology, such as `@isolated(caller)`. However, this approach has very
unsatisfying answers for how it interacts with `nonisolated`. There are
two options:

1. `@isolated(caller)` must be written together with `nonisolated`, 

   This approach leads to the verbose and oxymoronic spelling
   `@isolated(caller) nonisolated`. Though there
   exists a perfectly reasonable explanation about how `nonisolated` is the
   static isolation while `@isolated(caller)` is the dynamic isolation, most
   programmers do not have this deep of an understanding of actor isolation,
   and they should not have to in order to make basic use of nonisolated async
   functions.
2. `@isolated(caller)` implies `nonisolated` and can be written alone as an
   alternative.

   This direction means that programmers would sometimes write
   `nonisolated` and sometimes write `@isolated(caller)`, which is not a good
   end state to be in because programmers have to learn a separate syntax for
   `async` functions that accomplishes the same effect as a `nonisolated`
   synchronous function. Or, if we view `@isolated(caller)` as only used for
   the transition to the new behavior, then the assumption is that some day
   people will remove `@isolated(caller)` if it is written in source. If
   `@isolated(caller)` implies `nonisolated`, then the code could change
   behavior if it's in a context where global or instance actor isolation would
   otherwise be inferred.

Going in the oppose direction, this proposal could effectively deprecate
`nonisolated` and allow you to use `@isolated(caller)` everywhere that
`nonisolated` is currently supported, including synchronous methods, stored
properties, type declarations, and extensions. This direction was not chosen
for the following reasons:

1. This would lead to much more code churn than the current proposal. Part of
   the goal of this proposal is to minimize the change to only what is absolutely
   necessary to solve the major usability problem with async functions on
   non-`Sendable` types, because it's painful both to transition code and to
   re-learn parts of the model that have already been internalized.
2. `nonisolated` is nicer to write than `@isolated(caller)`
   or any other alternative attribute + argument syntax.

#### `nonisolated` argument spelling

An argument to `nonisolated` is more compelling than a separate attribute
to specify that an async function runs on the caller's actor because it
defines away the problem of whether this annotation implies `nonisolated` when
written alone.

A few different options for the argument to `nonisolated` were explored.

**`nonisolated(nosend)`**.
`nonisolated(nosend)` effectively the same as `nonisolated(nonsending)` as
proposed, but it states that the call itself does not constitute a "send",
rather than stating that the call is not "sending" its argument and result
values over an isolation boundary. `nonisolated(nosend)` is shorter, but
`nonisolated(nonsending)` is more consistent with existing Swift naming
conventions.

**`nonisolated(caller)`**.
`nonisolated(caller)` is meant to indicate that the function is statically
`nonisolated` and dynamically isolated to the caller. However, putting those
terms together into one `nonisolated(caller)` attribute is misleading, because
it appears the mean exactly the opposite of what it actually means;
`nonisolated(caller)` reads "not isolated to the caller".

**`nonisolated(nonconcurrent)`**.
If `@concurrent` is applied to a function, then the function must run
concurrently with the caller's actor (assuming multiple isolated tasks
in the program). `nonconcurrent` conveys the inverse; if `nonconcurrent` is
applied to an async function, then the function must not run concurrently
with the caller's actor. However, this statement isn't quite true, because the
implementation of the function can perform work concurrently, though that work
cannot involve the non-`Sendable` parameter values.

**`nonisolated(static)`**.
`nonisolated(static)` is meant to convey that a function is only `nonisolated`
statically, but it may be dynamically isolated to a specific actor at runtime.
However, we have not yet introduced "static" into the language surface to mean
"at compile time". `static` also has an existing, different meaning;
`nonisolated static func` would mean something quite different from
`nonisolated(static) func`, despite having extremely similar spelling.

## Revisions

The proposal was revised with the following changes after the first review:

* Renamed `@execution(concurrent)` back to `@concurrent`.
* Renamed `@execution(caller)` to `nonisolated(nonsending)`
* Removed the unconditional warning about nonisolated async functions that
  don't explicitly specify `nonisolated(nonsending)` or `@concurrent`.
* Removed `noasync` from the `assumeIsolated` API family.
* Specified the region isolation rules for `nonisolated(nonsending)` functions [as
  discussed in the first review][region-isolation].

The proposal was revised with the following changes after the pitch discussion:

* Gate the behavior change behind an `NonisolatedNonsendingByDefault` upcoming
  feature flag.
* Change the spelling of `@concurrent` to `@execution(concurrent)`, and add an
  `@execution(caller)` attribute to allow expressing the new behavior this
  proposal introduces when the upcoming feature flag is not enabled.
* Apply `@execution(caller)` to nonisolated async function types by default to
  make the execution semantics consistent between async function declarations
  and values.
* Change the terminology in the proposal to not use the "inherits isolation"
  phrase.

[SE-0297]: /proposals/0297-concurrency-objc.md
[SE-0338]: /proposals/0338-clarify-execution-non-actor-async.md
[SE-0421]: /proposals/0421-generalize-async-sequence.md
[adoption-tooling]: https://forums.swift.org/t/pitch-adoption-tooling-for-upcoming-features/77936
[region-isolation]: https://forums.swift.org/t/se-0461-run-nonisolated-async-functions-on-the-callers-actor-by-default/77987/36
