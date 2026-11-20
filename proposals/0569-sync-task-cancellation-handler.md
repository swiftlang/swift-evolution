# Synchronous `withTaskCancellationHandler`

* Proposal: [SE-0569](0569-sync-task-cancellation-handler.md)
* Authors: [Yaroslav Petryk](https://github.com/malien), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#94512](https://github.com/swiftlang/swift/pull/94512)
* Review: ([pitch](https://forums.swift.org/t/synchronous-overload-of-withtaskcancellationhandler/90894/8))

## Summary of changes

Introduces a synchronous overload of the `withTaskCancellationHandler` function
for use in sync code, where the async suspension boundary might not be desirable.

## Motivation

There currently exists friction when integrating with third-party code that
provides their own mechanism of signaling cancellation. To bridge Swift's
concepts of task cancellation onto external code we currently have two
mechanisms: `Task.isCancelled` and `withTaskCancellationHandler`.

The most common and idiomatic way of interrupting a, possibly expensive, block
of synchronous computation is `Task.isCancelled` and `Task.checkCancellation`.
These facilities are not available in non-Swift code, and third-party code,
usually, cannot be instrumented in order to interleave checks of task
cancellation status.

```swift
while true {
    // We can check before/after making a call from Swift
    // but once we are within the callee, there is no way to abort
    try Task.checkCancellation()
    let code = sqlite3_step(statement) // <- possibly slow operation
    if code == SQLITE_DONE { break }
}
```

`withTaskCancellationHandler` is an alternative method, to signal the
cancellation of the task, that unfortunately imposes an async calling
convention onto the caller.

```swift
try await withTaskCancellationHandler { // <- forces an async caller context
    let code = sqlite3_step(statement) // <- possibly slow operation
    if code == SQLITE_INTERRUPT { // <- emitted by the library when cancellation was signaled
        throw CancellationError()
    }
  }
} onCancel: {
  sqlite3_interrupt(statement) // <- library mechanism to signal cancellation
}
```

## Proposed solution

A new overload of the existing `withTaskCancellationHandler(operation:onCancel:)`,
where the operation parameter is not marked `async`:

```swift
try withTaskCancellationHandler { // <- no longer awaited
    let code = sqlite3_step(statement)
    if code == SQLITE_INTERRUPT {
        throw CancellationError()
    }
  }
} onCancel: {
  sqlite3_interrupt(statement)
}
```

When called on a thread that isn't running a task, there is no task that could
be canceled, so the `operation` closure runs and the cancellation handler is
never called.

## Detailed design

```swift
/// Execute a synchronous operation with a cancellation handler that's
/// immediately invoked if the current task is canceled.
///
/// - Parameters:
///   - operation: The operation to perform.
///   - handler: A closure to execute on cancellation.
///     If the task is canceled, this closure is called at most once;
///     otherwise, it isn't called.
///
/// This is the synchronous counterpart of the asynchronous
/// `withTaskCancellationHandler(operation:onCancel:)`. Use it in synchronous
/// code, for example in a synchronous function that's called from a task and
/// blocks until some external work completes:
///
/// ```
/// func readAll(from source: Source) -> [UInt8] {
///   withTaskCancellationHandler {
///     source.readUntilClosed()
///   } onCancel: {
///     // This onCancel closure might execute concurrently with the operation.
///     source.close()
///   }
/// }
/// ```
///
/// ### Execution order and semantics
/// The `operation` closure is always invoked, even when the
/// `withTaskCancellationHandler(operation:onCancel:)` function is called from a
/// task that was already canceled.
///
/// When called from code that runs in a task, the cancellation handler
/// behaves exactly like the one of the asynchronous
/// `withTaskCancellationHandler(operation:onCancel:)`: if the task has already
/// been canceled, the handler is executed immediately before the `operation`
/// closure gets to execute; if the task is canceled while the operation is
/// running, the handler executes *concurrently* with the operation.
///
/// When called on a thread that isn't running a task, there is no task that
/// could be canceled, so the `operation` closure runs and the cancellation
/// handler is never called.
///
/// ### Cancellation handlers and locks
///
/// Cancellation handlers which acquire locks must take care to avoid deadlock.
/// The cancellation handler may be invoked while holding internal locks
/// associated with the task or other tasks. Other operations on the task, such
/// as resuming a continuation, may acquire these same internal locks.
/// Therefore, if a cancellation handler must acquire a lock, other code should
/// not cancel tasks or resume continuations while holding that lock.
@available(SwiftStdlib 6.5, *)
@export(implementation)
public func withTaskCancellationHandler<Return, Failure>(
  operation: () throws(Failure) -> Return,
  onCancel handler: sending () -> Void
) throws(Failure) -> Return
  where Return: ~Copyable,
        Failure: Error {
```

It uses the same internal mechanism of registering handlers of
`Builtin.taskAddCancellationHandler(handler:)` / 
`Builtin.taskRemoveCancellationHandler(record:)` as their async counterparts, 
with a notable difference that those routines now need to handle the case where
there is no encompassing task scope to be attached to.

Previously we could've asserted that `withTaskCancellationHandler` is always
run in an async context of a Task. With this introduction, that assumption is no
longer true.

## Source compatibility

The following code stays unaffected:
```swift
func operation() async {}

await withTaskCancellationHandler {
    await operation()
} onCancel: {}
```

Callsites which have no explicit closure async marking, and otherwise are not
inferred as being async (has no `await` points in its body) will now select a
different overload. That will emit a warning:

```swift
func operation() {}

await withTaskCancellationHandler {
// ^ No 'async' operations occur within 'await' expression
    operation()
} onCancel: {}
```

Under `-warnings-as-errors` this will now be a build error. The solution is to
remove the now-redundant `await`s.

## ABI compatibility

This change is a purely additive change to the Concurrency library.

## Implications on adoption

The additions described in this proposal require a new version of the Swift
standard library and runtime. Libraries that want to adopt synchronous
cancellation handlers while supporting older platforms have to either eschew
this particular cancellation path, or require an async calling context on their
callers.

Backporting to code running an older stdlib version is not immediately viable,
since the change requires altering the builtin runtime functions to handle the
possibility of no parent task scope existing in the current thread of execution.

## Alternatives considered

### Expose the lower-level registration primitives
Basically standardizing internal `Builtin.taskAddCancellationHandler(handler:)` 
/ `Builtin.taskRemoveCancellationHandler(record:)`
for clients to incorporate for themselves. Exposing the two ends is much more
error-prone and is subject to leakage. They have to be kept in sync. Similar
symmetry to `malloc` / `free` calls.

```swift
let record = Task.addCancellationHandler { sqlite3_interrupt(statement) }
defer { record.unregister() }

let code = sqlite3_step(statement)
```

This does permit more flexible designs implementable in userland, such as an 
RAII-style token mentioned below, as an alternative.

Careful consideration must be given when using these primitives. Records have
to never leave the task scope. Every `addCancellationHandler` **has** to have a
corresponding `unregister` call. The current scope-based design always preserves
these constraints safely and covers most of the known use cases.

### Expose RAII-style registration token

```swift
struct CancellationHandler: ~Copyable, ~Sendable {
    init(operation: sending () -> Void)
    consuming func unregister()
    deinit // implicit removal
}
```

A higher-level primitive then the raw operations described above. Preserves the
symmetry between `taskAddCancellationHandler`/`taskRemoveCancellationHandler`.
Still potentially unsafe, since the lifetime of the `CancellationHandler` can
outlive the task it was defined in. What would be the effect of an escaped
registration token is unclear.

---

Providing a singular overload of the existing closure-based API, with which 
users are already familiar with, is the simplest approach. It provides safer 
and more Swift-idiomatic API.
