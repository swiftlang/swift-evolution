# Inherit isolation by default for async functions

* Proposal: [SE-NNNN](NNNN-async-function-isolation.md)
* Authors: [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Previous Proposal: [SE-0338](0338-clarify-execution-non-actor-async.md)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Swift's general philosophy is to prioritize safety and ease-of-use over
performance, while still providing tools to write more efficient code. The
current behavior of nonisolated async functions prioritizes performance at the
expense of usability.

This proposal changes the behavior of nonisolated async functions to inherit
the isolation of the caller, and introduces an explicit way to state that an
async function always switches off of an actor to run. This effectively
reverses the decision made in
[SE-0338](/proposals/0338-clarify-execution-non-actor-async.md).

## Table of Contents

- [Motivation](#motivation)
- [Proposed solution](#proposed-solution)
- [Detailed design](#detailed-design)
  - [Nonisolated function isolation](#nonisolated-function-isolation)
  - [Concurrent function isolation](#concurrent-function-isolation)
  - [Task isolation inheritance](#task-isolation-inheritance)
  - [`#isolation` macro expansion](#isolation-macro-expansion)
  - [Isolation inference for closures](#isolation-inference-for-closures)
  - [Function conversions](#function-conversions)
  - [Executor switching](#executor-switching)
  - [Import-as-async heuristic](#import-as-async-heuristic)
- [Source compatibility](#source-compatibility)
- [ABI compatibility](#abi-compatibility)
- [Implications on adoption](#implications-on-adoption)
- [Alternatives considered](#alternatives-considered)
  - [Different spelling for `@concurrent`](#different-spelling-for-concurrent)
  - [Don't introduce a type attribute for `@concurrent`](#dont-introduce-a-type-attribute-for-concurrent)

## Motivation

[SE-0338](/proposals/0338-clarify-execution-non-actor-async.md) specifies that
nonisolated async functions never run on an actor's executor. This design
decision was made to prevent unnecessary serialization and contention for the
actor by switching off of the actor to run the nonisolated async function, and
any new tasks it creates that inherit isolation. The actor is then free to make
forward progress on other work. This behavior is especially important for
preventing unexpected overhang on the main actor.

This decision has a number of unfortunate consequences.

**`nonisolated` is difficult to understand.** There is a semantic difference 
between the isolation behavior of nonisolated synchronous and asynchronous
functions; nonisolated synchronous functions always stay in the isolation
domain of the caller, while nonisolated async functions always switch off of
the caller's actor (if there is one). For example:

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

**Inheriting the isolation of the caller is difficult to write.** It's possible
to write an async function that does not leave an actor to run using isolated
parameters and the `#isolation` macro as a default argument:

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
isolation of the caller using isolated parameters; see 
[SE-0421](/proposals/0421-generalize-async-sequence.md) for an example.

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

Despite `withResource` explicitly inheriting the isolation of the caller,
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

I propose changing nonisolated async functions to inherit the isolation of the
caller by default. This means that nonisolated functions always have the same
isolation rules, regardless of whether the function is synchronous or
asynchronous. The `@concurrent` declaration attribute can be used to opt into
async functions always running concurrently with actors.

## Detailed design

### Nonisolated function isolation

Nonisolated async functions inherit the isolation of the caller:

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

This is done by implicitly passing an isolated parameter to the async function.

`@Sendable` and `sending` closures that are nonisolated still run off of any
actor's executor. These closures don't face the same usability issues as
nonisolated async function declarations because they must be able to cross
isolation boundaries by definition.

### Concurrent function isolation

Async functions can be declared to always switch off of an actor to run using
the `@concurrent` declaration attribute:

```swift
struct S: Sendable {
  @concurrent func alwaysSwitch() async { ... }
}
```

The `@concurrent` attribute cannot be applied to synchronous functions. This is
an artifical limitation that could later be lifted if use cases arise.

`@concurrent` is both a declaration attribute and a type attribute. The type
of an `@concurrent` function declaration is an `@concurrent` function type.
Details on function conversions are covered in a
[later section](#function-conversions).

When an `@concurrent` function is called from a non-`@concurrent` function,
sendable checking is performed on the argument and result values. Either the
argument and result values must have a type that conforms to `Sendable`, or the
values must be in a disconnected region so they can be sent outside of the
actor:

```swift
class NotSendable {}

@concurrent func alwaysSwitch(ns: NotSendable) async { ... }

actor MyActor {
  let ns: NotSendable = .init()

  func callConcurrent() async {
    await alwaysSwitch(ns: ns) // error

    let disconnected = NotSendable()
    await alwaysSwitch(ns: disconnected) // okay
  }
}
```

It is an error to use `@concurrent` together with another form of isolation,
including global actors, isolated parameters, `nonisolated`, and
`@isolated(any)`.

### Task isolation inheritance

Unstructured tasks created in nonisolated async functions do not capture the
isolated parameter implicitly, and therefore do not inherit the isolation:

```swift
class NotSendable {
  var value = 0
}

func createTask(ns: NotSendable) async {
  Task {
    // This task does not share the same isolation as `createTask`

    ns.value += 1 // error
  }
}
```

Capturing `ns` in the unstructured task is an error, because the value can
be used concurrently between the caller of `createTask` and the newly
created task.

This decision is deliberate to match the semantics of unstructured task
creation in nonisolated synchronous functions. Note that unstructured task
creation in methods with isolated parameters already do not inherit isolation
if the isolated parameter is not explicitly captured.

Unstructured tasks created in concurrent async functions can also run
concurrently with the enclosing function:

```swift
class NotSendable {
  var value = 0
}

@concurrent func createTask(ns: NotSendable) async {
  Task {
    // This task runs concurrently with 'createTask'

    ns.value += 1 // error
  }
}
```

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
isolated argument to inherit the isolation of the caller. For example, the
following code is valid because the call to `explicitIsolationInheritance` does
not cross an isolation boundary:

```swift
class NotSendable { ... }

func explicitIsolationInheritance(
  ns: NotSendable,
  isolation: isolated (any Actor)? = #isolation
) async { ... }

nonisolated func printIsolation(ns: NotSendable) async {
  await explicitIsolationInheritance(ns: ns) // okay
}
```

Note that this introduces a semantic difference compared to synchronous
nonisolated functions, where there is no implicit isolated parameter and
`#isolation` always expands to `nil`. For example, the following program prints
`nil`:

```swift
nonisolated func printIsolation() {
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

In an `@concurrent` function, the `#isolation` macro expands to `nil`.

### Isolation inference for closures

The isolation of a closure can be explicitly specified with a type annotation
or in the closure signature. If no isolation is specified,  the inferred
isolation for a closure depends on two factors:
1. The isolation of the context where the closure is formed.
2. Whether the contextual type of the closure is `@Sendable` or `sending`.

If the contextual type of the closure is neither `@Sendable` nor `sending`, the
inferred isolation of the closure is the same as the enclosing context. If
either the type of the closure is `@Sendable` or the closure is passed to a
`sending` parameter, the closure is inferred to be nonisolated:

```swift
class NotSendable { ... }

@MainActor
func closureOnMain(ns: NotSendable) {
  let nonSendableClosure: () -> Void = {
    // inferred to be @MainActor-isolated

    // capturing main-actor state is okay
    print(ns)
  }

  let sendableClosure: @Sendable () -> Void = {
    // inferred to be nonisolated

    print(ns) // error
  }
}
```

### Function conversions

A function conversion that changes the isolation of a function value applies
the same checking as calling the original function from the destination
isolation domain. This checking is applied at the point of conversion, because
a function conversion is effectively a closure that wraps a call to the original
function value. For example, a function conversion from one global-actor-isolated
type to another can be conceptualized as an async, isolated closure that calls
the original function with `await`:

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

**Nonisolated to actor-isolated.** Nonisolated async functions can be
converted to actor-isolated function types:

```swift
func performAsync() async { ... }

func convert() async {
  let fn: @MainActor () -> Void = performAsync // okay

  await fn()
}
```

The argument and result values of the nonisolated async function do not need
to conform to `Sendable`, because a call to the function from an actor will
not cross an isolation boundary.

If the nonisolated function value itself is not `Sendable`, it may have
captured non-`Sendable` values from the enclosing context. A conversion to an
actor-isolated function merges the function value to the actor's region:

```swift
class NotSendable {
  var value = 0
}

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

**Actor-isolated to nonisolated.** Actor-isolated synchronous functions can be
converted to nonisolated synchronous functions as long as the conversion
happens on the actor and the nonisolated function is not `@Sendable`:

```swift
@MainActor func onMain() { ... }

@MainActor
func convertOnMain() {
  let fn1: () -> Void = onMain // okay
  fn1()

  let fn2: @Sendable () -> Void = onMain // error
}

func convert() {
  let fn1: () -> Void = onMain // error
  let fn2: @Sendable () -> Void = onMain // error
}
```

Both synchronous and async actor-isolated function types can be converted to
nonisolated, non-`Sendable` async function types if the conversion happens on
the actor:

```swift
class NotSendable { ... }

@MainActor onMain() -> NotSendable { ... }

@MainActor
func convertOnMain async {
  let fn: () async -> NotSendable = onMain // okay
  let ns = await fn()
}

func convertOffMain() {
  let fn: () async -> NotSendable = onMain // error
  await fn()
}
```

From outside the actor, isolated function types can be converted to nonisolated
async function types as long as the argument and result types of the function
conform to `Sendable`:

```swift
class NotSendable { ... }

@MainActor let ns = NotSendable()

@MainActor func isolatedValue() -> NotSendable {
  return ns
}

@MainActor func sendableValue() -> Int {
  return 0
}

@MainActor func sendableValueAsync() async -> Int {
  return 0
}

func convert() async {
  do {
    let valid: () async -> Int = sendableValue // okay
    let int = await valid()
  }

  do {
    let valid: () async -> Int = sendableValueAsync // okay
    let int = await valid()
  }


  let invalid: () async -> NotSendable = isolatedValue // error
  let ns = await invalid()
}
```

The function conversion to the `invalid` variable produces an error because
it would allow main-actor-isolated state to be used from outside the actor.

**Actor-isolated to actor-isolated.** Converting a synchronous isolated
function to another synchronous function that changes isolation is always
invalid. Converting an isolated function to an async function that changes
isolation is valid if the argument and result types conform to `Sendable`:

```swift
class NotSendable { ... }

actor MyActor {
  let ns: NotSendable = .init()
  func perform() {}
  func performAsync() async {}
  func getIsolatedValue() -> NotSendable { ns }
  func getIsolatedValueAsync() async -> NotSendable { ns }
}

@MainActor
func convert(a: MyActor) async {
  do {
    let fn: @MainActor () async -> Void = a.perform // okay
    await fn()
  }

  do {
    let fn: @MainActor () async -> Void = a.performAsync // okay
    await fn()
  }

  do {
    // error
    let invalid: @MainActor () async -> NotSendable = a.getIsolatedValue
    let ns = await invalid()
  }

  do {
    // error
    let invalid: @MainActor () async -> NotSendable = a.getIsolatedValueAsync
    let ns = await invalid()
  }
}
```

**Concurrent to nonisolated or actor-isolated.** Converting an `@concurrent`
function to an async function that changes isolation is valid if the argument
and result types conform to `Sendable`:

```swift
class NotSendable { ... }

@concurrent func useNotSendable(ns: NotSendable) async { ... }
@concurrent func useInt(x: Int) async { ... }

actor MyActor {
  let ns: NotSendable = .init()
  func convert() async {
    let fn: (Int) async -> Void = useInt // okay
    let ns = await fn(10)

    let invalidFn: (NotSendable) async -> Void = useNotSendable // error
    await invalidFn(self.ns)
  }
}
```

**Nonisolated to concurrent.** Converting a nonisolated function to an
`@concurrent` function is always valid. Sendable checking for arguments
and results will be applied when calling the converted function value.

**Actor-isolated to concurrent.** Converting an isolated function to an
`@concurrent` function is valid if the argument and result types conform to
`Sendable`:

```swift
class NotSendable { ... }

@MainActor var globalState: NotSendable = .init()

@MainActor func useNotSendable(ns: NotSendable) async {
  globalState = ns
}

@MainActor func useInt(x: Int) async { ... }

@concurrent func convert() async {
  let fn: @concurrent (Int) async -> Void = useInt // okay
  let ns = await fn(10)

  let ns = NotSendable()
  let invalidFn: @concurrent (NotSendable) async -> Void = useNotSendable // error
  await invalidFn(ns)
  // concurrent access to 'ns' can happen here
}
```

### Executor switching

Async functions switch executors in the implementation when entering the
function, and after any calls to async functions. Isolated functions switch to
the isolated parameter or global actor's executor, and `@concurrent` functions
switch to the generic executor:

```swift
@MainActor func runOnMainExecutor() async {
  // switch to main actor executor

  await runOnGenericExecutor()

  // switch to main actor executor
}

@concurrent func runOnGenericExecutor() async {
  // switch to generic executor

  await Task { @MainActor in ... }.value

  // switch to generic executor
}
```

Executor switching behaves the same way in nonisolated async functions:

```swift
@MainActor func runOnMainExecutor() { ... }

nonisolated func inheritIsolation() async {
  // switch to isolated parameter's executor

  await runOnMainExecutor()

  // switch to isolated parameter's executor
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

### Import-as-async heuristic

Functions imported from Objective-C that match the import-as-async heuristic
from [SE-0297: Concurrency Interoperability with Objective-C](/proposals/0297-concurrency-objc.md)
will inherit the isolation of the caller if they are currently imported as
nonisolated. The `@concurrent` attribute must be declared explicitly in the
Objective-C header for a function to be imported as an `@concurrent` function.

## Source compatibility

TBD

## ABI compatibility

TBD: I'm still figuring out whether this change can be staged in while
preserving ABI for existing nonisolated async functions. A number of APIs
in the concurrency library have transitioned to inheriting the isolation of
the caller using isolated parameters and `#isolation`, and it may be possible
to do this transformation automatically.

## Implications on adoption

Under this proposal, nonisolated async functions must accept an implicit
isolated parameter. This means that adding the `nonisolated` keyword to
a function that is implicitly actor isolated is not a resilient change,
because it adds an additional parameter to represent the isolation of the
caller. Similarly, changing a nonisolated function to an `@concurrent` function
and vice versa is not a resilient change.

## Alternatives considered

### Different spelling for `@concurrent`

I'm open to other spellings for the `@concurrent` declaration modifier and I
welcome other ideas in the pitch and review discussions. I chose `@concurrent`
because the colloquial phrase "runs concurrently with actors" is a good way to
describe the semantics of the function execution. Options that involve a variant
of the word "isolation" such as `@dropsIsolation` would be easily confused with
`nonisolated`, and phrases that describe the executor, e.g. `@genericExecutor` or
similar, are far too formal, and they conflate executor with actor isolation.

### Don't introduce a type attribute for `@concurrent`

There are a lot of existing type attributes for concurrency and it's
unfortunate to introduce another one. However, without `@concurrent` as a type
attribute, referencing `@concurrent` functions unapplied is very restrictive,
because sendable checking would need to be performed at the point of the
function reference instead of when the function is called. That said, I am still
not convinced that the additional concept of `@concurrent` function types is
worth the additional complexity.
