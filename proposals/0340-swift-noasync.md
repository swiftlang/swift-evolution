# Unavailable From Async Attribute

* Proposal: [SE-0340](0340-swift-noasync.md)
* Authors: [Evan Wilde](https://github.com/etcwilde)
* Review manager: [Joe Groff](https://github.com/jckarter)
* Status: **Accepted**
* Implementation: [Underscored attribute](https://github.com/apple/swift/pull/40149), [Attribute with optional message](https://github.com/apple/swift/pull/40378), [noasync availability](https://github.com/apple/swift/pull/40769)
* Discussion: [Discussion: Unavailability from asynchronous contexts](https://forums.swift.org/t/discussion-unavailability-from-asynchronous-contexts/53088)
* Pitch: [Pitch: Unavailability from asynchronous contexts](https://forums.swift.org/t/pitch-unavailability-from-asynchronous-contexts/53877)
* Review: [SE-0340: Unavailable from Async Attribute](https://forums.swift.org/t/se-0340-unavailable-from-async-attribute/54852)
* Decision Notes: [Acceptance](https://forums.swift.org/t/accepted-se-0340-unavailable-from-async-attribute/55356)

## Introduction

The Swift concurrency model allows tasks to resume on different threads from the
one they were suspended on. For this reason, API that relies on thread-local
storage, locks, mutexes, and semaphores, should not be used across suspension
points.

```swift
func badAsyncFunc(_ mutex: UnsafeMutablePointer<pthread_mutex_t>, _ op : () async -> ()) async {
  // ...
  pthread_mutex_lock(mutex)
  await op()
  pthread_mutex_unlock(mutex) // Bad! May unlock on a different thread!
  // ...
}
```

The example above exhibits undefined behaviour if `badAsyncFunc` resumes on a
different thread than the one it started on after running `op` since
`pthread_mutex_unlock` must be called from the same thread that locked the
mutex.

We propose extending `@available` with a new `noasync` availability kind to
indicate API that may not be used directly from asynchronous contexts.

Swift evolution thread: [Pitch: Unavailability from asynchronous contexts](https://forums.swift.org/t/pitch-unavailability-from-asynchronous-contexts/53877)

## Motivation

The Swift concurrency model allows tasks to suspend and resume on different
threads. While this behaviour allows higher utility of computational resources,
there are some nasty pitfalls that can spring on an unsuspecting programmer. One
such pitfall is the undefined behaviour from unlocking a `pthread_mutex_t` from
a different thread than the thread that holds the lock, locking threads may
easily cause unexpected deadlocks, and reading from and writing to thread-local
storage across suspension points may result in unintended behaviour that is
difficult to debug.

## Proposed Solution

We propose extending `@available` to accept a `noasync` availability kind.
The `noasync` availability kind is applicable to most declarations, but is not
allowed on destructors as those are not explicitly called and must be callable
from anywhere.

```swift
@available(*, noasync)
func doSomethingNefariousWithNoOtherOptions() { }

@available(*, noasync, message: "use our other shnazzy API instead!")
func doSomethingNefariousWithLocks() { }

func asyncFun() async {
  // Error: doSomethingNefariousWithNoOtherOptions is unavailable from
  //        asynchronous contexts
  doSomethingNefariousWithNoOtherOptions()

  // Error: doSomethingNefariousWithLocks is unavailable from asynchronous
  //        contexts; use our other shanzzy API instead!
  doSomethingNefariousWithLocks()
}
```

The `noasync` availability attribute only prevents API usage in the immediate
asynchronous context; wrapping a call to an unavailable API in a synchronous
context and calling the wrapper will not emit an error. This allows for cases
where it is possible to use the API safely within an asynchronous context, but
in specific ways. The example below demonstrates this with an example of using a
pthread mutex to wrap a critical section. The function ensures that there cannot
be a suspension point between obtaining and releasing the lock, and therefore is
safe for consumption by asynchronous contexts.

```swift
func goodAsyncFunc(_ mutex: UnsafeMutablePointer<pthread_mutex_t>, _ op : () -> ()) async {
  // not an error, pthread_mutex_lock is wrapped in another function
  with_pthread_mutex_lock(mutex, do: op)
}

func with_pthread_mutex_lock<R>(
    _ mutex: UnsafeMutablePointer<pthread_mutex_t>,
    do op: () throws -> R) rethrows -> R {
  switch pthread_mutex_lock(mutex) {
    case 0:
      defer { pthread_mutex_unlock(mutex) }
      return try op()
    case EINVAL:
      preconditionFailure("Invalid Mutex")
    case EDEADLK:
      fatalError("Locking would cause a deadlock")
    case let value:
      fatalError("Unknown pthread_mutex_lock() return value: '\(value)'")
  }
}
```

The above snippet is a safe wrapper for `pthread_mutex_lock` and
`pthread_mutex_unlock`, since the lock is not held across suspension points. The
critical section operation must be synchronous for this to hold true though.
The following snippet uses a synchronous closure to call the unavailable
function, circumventing the protection provided by the attribute.

```swift
@available(*, noasync)
func pthread_mutex_lock(_ lock: UnsafeMutablePointer<pthread_mutex_t>) {}

func asyncFun(_ mutex : UnsafeMutablePointer<pthread_mutex_t>) async {
  // Error! pthread_mutex_lock is unavailable from async contexts
  pthread_mutex_lock(mutex)

  // Ok! pthread_mutex_lock is not called from an async context
  _ = { unavailableFun(mutex) }()

  await someAsyncOp()
}
```

### Replacement API

In some cases, it is possible to provide an alternative that is safe. The
`with_pthread_mutex_lock` is an example of a way to provide a safe way to wrap
locking and unlocking pthread mutexes.

In other cases, it may be safe to use an API from a specific actor. For
example, API that uses thread-local storage isn't safe for consumption by
asynchronous functions in general, but is safe for functions on the MainActor
since it will only use the main thread.

The unavailable API should still be annotated as such, but an alternative
function can be implemented as an extension of the actors that support the
operation.

```swift
@available(*, noasync, renamed: "mainactorReadID()", message: "use mainactorReadID instead")
func readIDFromThreadLocal() -> Int { }

@MainActor
func readIDFromMainActor() -> Int { readIDFromThreadLocal() }

func asyncFunc() async {
  // Bad, we don't know what thread we're on
  let id = readIDFromThreadLocal()

  // Good, we know it's coming from the main actor on the main thread.
  // Note the suspension due to the jump to the main actor.
  let id = await readIDFromMainActor()
}
```

Restricting a synchronous API to an actor is done similarly, as demonstrated in
the example below. The synchronous `save` function is part of a public API, so
it can't just be pulled into the `DataStore` actor without causing a source
break. Instead, it is annotated with a `noasync` available attribute.
`DataStore.save` is a thin wrapper around the original synchronous save
function. Calls from an asynchronous context to `save` may only be done through
the `DataStore` actor, ensuring that the cooperative pool isn't tied up with the
save function. The original save function is still available to synchronous code
as it was before.

```swift
@available(*, noasync, renamed: "DataStore.save()")
public func save(_ line: String) { }

public actor DataStore { }

public extension DataStore {
  func save(_ line: String) {
    save(line)
  }
}
```

## Additional design details

Verifying that unavailable functions are not used from asynchronous contexts is
done weakly; only unavailable functions called directly from asynchronous
contexts are diagnosed. This avoids the need to recursively typecheck the bodies
of synchronous functions to determine whether they are implicitly available from
asynchronous contexts, or to verify that they are appropriately annotated.

While the typechecker doesn't need to emit diagnostics from synchronous
functions, they cannot be omitted entirely. It is possible to declare
asynchronous contexts inside of synchronous contexts, wherein diagnostics should
be emitted.

```swift
@available(*, noasync)
func bad2TheBone() {}

func makeABadAsyncClosure() -> () async -> Void {
  return { () async -> Void in
    bad2TheBone() // Error: Unavailable from asynchronous contexts
  }
}
```

## Source Compatibility

Swift 3 and Swift 4 do not have this attribute, so code coming from Swift 3 and
Swift 4 won't be affected.

The attribute will affect any current asynchronous code that currently contains
use of API that are modified with this attribute later. To ease the transition,
we propose that this attribute emits a warning in Swift 5.6, and becomes a full
error in Swift 6. In cases where someone really wants unsafe behavior and enjoys
living on the edge, the diagnostic is easily circumventable by wrapping the API
in a synchronous closure, noted above.

## Effect on ABI stability

This feature has no effect on ABI.

## Effect on API resilience

The presence of the attribute has no effect on the ABI.

## Alternatives Considered

### Propagation

The initial discussion focused on how unavailability propagated, including the
following three designs;
 - implicitly-inherited unavailability
 - explicit unavailability
 - thin unavailability

The ultimate decision is to go with the thin checking; both the implicit and
explicit checking have high performance costs and require far more consideration
as they are adding another color to functions.

The attribute is expected to be used for a fairly limited set of specialized
use-cases. The goal is to provide some protection without dramatically impacting
the performance of the compiler.

#### Implicitly inherited unavailability

Implicitly inheriting unavailability would transitively apply the unavailability
to functions that called an unavailable function. This would have the lowest
developer overhead while ensuring that one could not accidentally use the
unavailable functions indirectly.

```swift
@unavailableFromAsync
func blarp1() {}

func blarp2() {
  // implicitly makes blarp2 unavailable
  blarp1()
}

func asyncFun() async {
  // Error: blarp2 is impicitly unavailable from async because of call to blarp1
  blarp2()
}
```

Unfortunately, computing this is very expensive, requiring type-checking the
bodies of every function a given function calls in order to determine if the
declaration is available from an async context. Requiring even partial
type-checking of the function bodies to determine the function declaration is
prohibitively expensive, and is especially detrimental to the performance of
incremental compilation.

We would need an additional attribute to disable the checking for certain
functions that are known to be usable from an async context, even though they
use contain unavailable functions. An example of a safe, but "unavailable"
function is `with_pthread_mutex_lock` above.

#### Explicit unavailability

This design behaves much like availability does today. In order to use an
unavailable function, the calling function must be explicitly annotated with the
unavailability attribute or an error is emitted.

Like the implicit unavailability propagation, we still need an additional
attribute to indicate that, while a function may contain unsafe API, it uses
them in a way that is safe for use in asynchronous contexts.

The benefits of this design are that it both ensures that unsafe API are explicitly
handled correctly, avoiding bugs. Additionally, typechecking asynchronous
functions is reasonably performant and does not require recursively
type-checking the bodies of every synchronous function called by the
asynchronous function.

Unfortunately, we would need to walk the bodies of every synchronous function to
ensure that every synchronous function is correctly annotated. This reverses the
benefits of the implicit availability checking, while having a high developer
overhead.

### Separate Attribute

We considered using a separate attribute, spelled `@unavailableFromAsync`, to
annotate the unavailable API. After more consideration, it became apparent that
we would likely need to reimplement much of the functionality of the
`@available` attribute.

Some thoughts that prompted the move from `@unavailableFromAsync` to an
availability kind include:

 - A given API may have different implementations on different platforms, and
   therefore may be implemented in a way that is safe for consumption in
   asynchronous contexts in some cases but not others.
 - An API may be currently implemented in a way that is unsafe for consumption
   in asynchronous contexts, but may be safe in the future.
 - We get `message`, `renamed`, and company, with serializations, for free by
   merging this with `@available`.

Challenges to the merge mostly focus on the difference in the verification model
between this and the other availability modes. The `noasync`, as discussed
above, is a weaker check and does not require API that is using the unavailable
function to also be annotated. The other availability checks do require that the
availability information be propagated.

## Future Directions

[Custom executors](https://forums.swift.org/t/support-custom-executors-in-swift-concurrency/44425)
are pitched to become part of the language as a future feature.
Restricting an API to a custom executor is the same as restricting that API to
an actor. The difference is that the actor providing the replacement API has
it's `unownedExecutor` overridden with the desired custom executor.

Hand-waving around some of the syntax, this protection could look something like
the following example:

```swift
protocol IOActor : Actor { }

extension IOActor {
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    return getMyCustomIOExecutor()
  }
}

@available(*, noasync, renamed: "IOActor.readInt()")
func readIntFromIO() -> String { }

extension IOActor {
  // IOActor replacement API goes here
  func readInt() -> String { readIntFromIO() }
}

actor MyIOActor : IOActor {
  func printInt() {
    // Okay! It's synchronous on the IOActor
    print(readInt())
  }
}

func print(myActor : MyIOActor) async {
  // Okay! We only call `readIntFromIO` on the IOActor's executor
  print(await myActor.readInt())
}
```

The `IOActor` overrides it's `unownedExecutor` with a specific custom IO
executor and provides a synchronous `readInt` function wrapping a call to the
`readIntFromIO` function. The `noasync` availability attribute ensures that
`readIntFromIO` cannot generally be used from asynchronous contexts.
When `readInt` is called, there will be a hop to the `MyIOActor`, which uses the
custom IO executor.

## Acknowledgments

Thank you Becca and Doug for you feedback and help shaping the proposal.
