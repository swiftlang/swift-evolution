# Continuations for interfacing async tasks with synchronous code

* Proposal: [SE-ABCD](ABCD-continuation.md)
* Authors: [John McCall](https://github.com/rjmccall), [Joe Groff](https://github.com/jckarter), [Doug Gregor](https://github.com/DougGregor), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

Asynchronous Swift code needs to be able to work with existing synchronous
code that uses techniques such as completion callbacks and delegate methods to
respond to events. Asynchronous tasks can suspend themselves on
**continuations** which synchronous code can then capture and invoke to
resume the task in response to an event

Swift-evolution thread:

- [Structured concurrency](https://forums.swift.org/t/concurrency-structured-concurrency/41622)
- [Continuations for interfacing async tasks with synchronous code](https://forums.swift.org/t/concurrency-continuations-for-interfacing-async-tasks-with-synchronous-code/43619)

## Motivation

Swift APIs often provide asynchronous code execution by way of a callback. This
may occur either because the code itself was written prior to the introduction
of async/await, or (more interestingly in the long term) because it ties in
with some other system that is primarily event-driven. In such cases, one may
want to provide an async interface to clients while using callbacks internally.
In these cases, the calling async task needs to be able to suspend itself,
while providing a mechanism for the event-driven synchronous system to resume
it in response to an event.

## Proposed solution

The library will provide APIs to get a **continuation** for the current
asynchronous task. Getting the task's continuation suspends the task, and
produces a value that synchronous code can then use a handle to resume the
task. Given a completion callback based API like:

```
func beginOperation(completion: (OperationResult) -> Void)
```

we can turn it into an `async` interface by suspending the task and using its
continuation to resume it when the callback is invoked, turning the argument
passed into the callback into the normal return value of the async function:

```
func operation() async -> OperationResult {
  // Suspend the current task, and pass its continuation into a closure
  // that executes immediately
  return await withUnsafeContinuation { continuation in
    // Invoke the synchronous callback-based API...
    beginOperation(completion: { result in
      // ...and resume the continuation when the callback is invoked
      continuation.resume(returning: result)
    }) 
  }
}
```

## Detailed design

### Raw unsafe continuations

The library provides two functions, `withUnsafeContinuation` and
`withUnsafeThrowingContinuation`, that allow one to call into a callback-based
API from inside async code. Each function takes an *operation* closure,
which is expected to call into the callback-based API. The closure
receives a continuation instance that must be resumed by the callback,
either to provide the result value or (in the throwing variant) the thrown
error that becomes the result of the `withUnsafeContinuation` call when the
async task resumes:


```
struct UnsafeContinuation<T> {
  func resume(returning: T)
}

func withUnsafeContinuation<T>(
    _ operation: (UnsafeContinuation<T>) -> ()
) async -> T

struct UnsafeThrowingContinuation<T> {
  func resume(returning: T)
  func resume(throwing: Error)
  func resume<E: Error>(with result: Result<T, E>)
}

func withUnsafeThrowingContinuation<T>(
    _ operation: (UnsafeThrowingContinuation<T>) -> ()
) async throws -> T
```

The operation must follow one of the following invariants:

- Either the resume function must only be called *exactly-once* on each
  execution path the operation may take (including any error handling paths),
  or else
- the resume function must be called exactly at the end of the operation
  function's execution.

`Unsafe*Continuation` is an unsafe interface, so it is undefined behavior if
these invariants are not followed by the operation. This allows
continuations to be a low-overhead way of interfacing with synchronous code.
Wrappers can provide checking for these invariants, and the library will provide
one such wrapper, discussed below.

Using the `Unsafe*Continuation` API, one may for example wrap such
(purposefully convoluted for the sake of demonstrating the flexibility of
the continuation API) function:

```
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

Thanks to weaving the right continuation resume calls into the complex
callbacks of the `buyVegetables` function, we were able to offer a much nicer
overload of this function, allowing async code to interact with this function in
a more natural straight-line way.

### Checked continuations

`Unsafe*Continuation` provides a lightweight mechanism for interfacing
sync and async code, but it is easy to misuse, and misuse can corrupt the 
process state in dangerous ways. In order to provide additional safety and
guidance when developing interfaces between sync and async code, the
library will also provide a wrapper which checks for invalid use of the
continuation:

```
struct CheckedContinuation<T> {
  func resume(returning: T)
}

func withCheckedContinuation<T>(
    _ operation: (CheckedContinuation<T>) -> ()
) async -> T

struct CheckedThrowingContinuation<T> {
  func resume(returning: T)
  func resume(throwing: Error)
  func resume<E: Error>(with result: Result<T, E>)
}

func withCheckedThrowingContinuation<T>(
    _ operation: (CheckedThrowingContinuation<T>) -> ()
) async throws -> T
```

The API is intentionally identical to the `Unsafe` variants, so that code
can switch easily between the checked and unchecked variants. For instance,
the `buyVegetables` example above can opt into checking merely by turning
its call of `withUnsafeThrowingContinuation` into one of `withCheckedThrowingContinuation`:

```
// returns 1 or more vegetables or throws an error
func buyVegetables(shoppingList: [String]) async throws -> [Vegetable] {
  try await withCheckedThrowingContinuation { continuation in
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
```

Instead of leading to undefined behavior, `CheckedContinuation` will instead
trap if the program attempts to resume the continuation multiple times.
`CheckedContinuation` will also log a warning if the continuation
is discarded without ever resuming the task, which leaves the task stuck in its
suspended state, leaking any resources it holds.

## Additional examples

Continuations can be used to interface with more complex event-driven
interfaces than callbacks as well. As long as the entirety of the process
follows the requirement that the continuation be resumed exactly once, there
are no other restrictions on where the continuation can be resumed. For
instance, an `Operation` implementation can trigger resumption of a
continuation when the operation completes:

```
class MyOperation: Operation {
  let continuation: UnsafeContinuation<OperationResult>
  var result: OperationResult?

  init(continuation: UnsafeContinuation<OperationResult>) {
    self.continuation = continuation
  }

  /* rest of operation populates `result`... */

  override func finish() {
    continuation.resume(returning: result!)
  }
}

func doOperation() async -> OperationResult {
  return await withUnsafeContinuation { continuation in
    MyOperation(continuation: continuation).start()
  }
}
```

Using APIs from the [structured concurrency proposal](https://github.com/DougGregor/swift-evolution/blob/structured-concurrency/proposals/nnnn-structured-concurrency.md),
one can wrap up a `URLSession` in a task, allowing the task's cancellation
to control cancellation of the session, and using a continuation to respond
to data and error events fired by the network activity:

```
func download(url: URL) async throws -> Data? {
  var urlSessionTask: URLSessionTask?

  return try Task.withCancellationHandler {
    urlSessionTask?.cancel()
  } operation: {
    let result: Data? = try await withUnsafeThrowingContinuation { continuation in
      urlSessionTask = URLSession.shared.dataTask(with: url) { data, _, error in
        if case (let cancelled as NSURLErrorCancelled)? = error {
          continuation.resume(returning: nil)
        } else if let error = error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: data)
        }
      }
      urlSessionTask?.resume()
    }
    if let result = result {
      return result
    } else {
      Task.cancel()
      return nil
    }
  }
}
```

## Alternatives considered

### Name `CheckedContinuation` just `Continuation`

We could position `CheckedContinuation` as the "default" API for doing
sync/async interfacing by leaving the `Checked` word out of the name. This
would certainly be in line with the general philosophy of Swift that safe
interfaces are preferred, and unsafe ones used selectively where performance
is an overriding concern. There are a couple of reasons to hesitate at doing
this here, though:

- Although the consequences of misusing `CheckedContinuation` are not as
  severe as `UnsafeContinuation`, it still only does a best effort at checking
  for some common misuse patterns, and it does not render the consequences of
  continuation misuse entirely moot: dropping a continuation without resuming
  it will still leak the un-resumed task, and attempting to resume a
  continuation multiple times will still cause the information passed through
  the continuation to be lost. It is still a serious programming error if
  a `with*Continuation` operation misuses the continuation;
  `CheckedContinuation` only helps make the error more apparent.
- Naming a type `Continuation` now might take the "good" name away if,
  after we have move-only types at some point in the future, we want to
  introduce a continuation type that statically enforces the exactly-once
  property.

### Don't expose `UnsafeContinuation`

One could similarly make an argument that `UnsafeContinuation` shouldn't be
exposed at all, since the `Checked` form can always be used instead. We think
that being able to avoid the cost of checking when interacting with
performance-sensitive APIs is valuable, once users have validated that their
interfaces to those APIs are correct.

### Have `CheckedContinuation` trap on all misuses, or log all misuses

`CheckedContinuation` is proposed to trap when the program attempts to
resume the same continuation twice, but only log a warning if a continuation
is abandoned without getting resumed. We think this is the right tradeoff
for these different situations for the following reasons:

- With `UnsafeContinuation`, resuming multiple times corrupts the process and
  leaves it in an undefined state. By trapping when the task is resumed
  multiple times, `CheckedContinuation` turns undefined behavior into a well-
  defined trap situation.  This is analogous to other checked/unchecked
  pairings in the standard library, such as `!` vs. `unsafelyUnwrapped` for
  `Optional`.
- By contrast, failing to resume a continuation with `UnsafeContinuation`
  does not corrupt the task, beyond leaking the suspended task's resources;
  the rest of the program can continue executing normally. Furthermore,
  the only way we can currently detect and report such a leak is by using
  a class `deinit` in its implementation. The precise moment at which such
  a deinit would execute is not entirely predictable because of refcounting
  variability from ARC optimization. If `deinit` were made to trap, whether that
  trap is executed and when could vary with optimization level, which we
  don't think would lead to a good experience.

### Expose more `Task` API on `*Continuation`, or allow a `Handle` to be recovered from a continuation

The full `Task` and `Handle` API provides additional control over the task
state to holders of the handle, particularly the ability to query and set
cancellation state, as well as await the final result of the task, and one
might wonder why the `*Continuation` types do not also expose this functionality.
The role of a `Continuation` is very different from a `Handle`, in that a handle
represents and controls the entire lifetime of the task, whereas a continuation
only represents a *single suspension point* in the lifetime of the task.
Furthermore, the `*Continuation` API is primarily designed to allow for
interfacing with code outside of Swift's structured concurrency model, and
we believe that interactions between tasks are best handled inside that model
as much as possible.

Note that `*Continuation` also does not strictly need direct support for any
task API on itself. If, for instance, someone wants a task to cancel itself
in response to a callback, they can achieve that by funneling a sentinel
through the continuation's resume type, such as an Optional's `nil`:

```
let callbackResult: Result? = await withUnsafeContinuation { c in
  someCallbackBasedAPI(
    completion: { c.resume($0) },
    cancelation: { c.resume(nil) })
}

if let result = callbackResult {
  process(result)
} else {
  cancel()
}
```

