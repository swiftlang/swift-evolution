# Synchronous `withTaskCancellationHandler`

* Proposal: [SE-0569](0569-sync-task-cancellation-handler.md)
* Authors: [Yaroslav Petryk](https://github.com/malien), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#94512](https://github.com/swiftlang/swift/pull/94512)
* Review: ([pitch](https://forums.swift.org/t/synchronous-overload-of-withtaskcancellationhandler/90894/8))

## Summary of changes

Introduces synchronous overloads of the `withTaskCancellationHandler` and
`withTaskPriorityEscalationHandler` functions for use in sync code, where the
async suspension boundary might not be desirable.

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

A similar problem exists for task priority escalation, since the
`withTaskPriorityEscalationHandler` doesn't offer a synchronous overload either.

## Proposed solution

We propose to add synchronous overloads to existing `with...` methods
which operate on the task status, such as `withTaskCancellationHandler`,
and `withTaskPriorityEscalationHandler`.

This will allow writing a synchronous version of the above piece of code,
which will work properly when called in a context where there is a current
task available:

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
be canceled or escalated, so the `operation` closure runs and the handler is
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
        Failure: Error
```

```swift
/// Runs the passed synchronous `operation` while registering a task priority
/// escalation handler. The handler will be triggered concurrently to the
/// current task if the current task is subject to priority escalation.
///
/// This is the synchronous counterpart of the asynchronous
/// `withTaskPriorityEscalationHandler(operation:onPriorityEscalated:)`.
///
/// When called from code that runs in a task, the handler behaves exactly like
/// the one of the asynchronous version: it is called once when it is
/// installed, before `operation` runs, with the task's current priority as
/// both arguments, and is then triggered each time a priority escalation of
/// the task occurs while the operation is in progress. Calls to the handler are
/// never concurrent with each other.
///
/// When called on a thread that isn't running a task, there is no task whose
/// priority could be escalated, so the `operation` closure runs and the handler
/// is never called, not even once when it is installed.
///
/// If multiple task escalation handlers are nested they will all be triggered.
///
/// - Parameters:
///   - operation: the operation during which to listen for priority escalation
///   - handler: handler to invoke, concurrently to `operation`,
///              when priority escalation happens.
///              The first argument is the old priority (before escalation),
///              and the second argument is the new escalated priority.
/// - Returns: the value returned by `operation`
/// - Throws: when the `operation` throws an error
@available(SwiftStdlib 6.5, *)
@export(implementation)
public func withTaskPriorityEscalationHandler<T, E>(
  operation: () throws(E) -> T,
  onPriorityEscalated handler: @Sendable (TaskPriority, TaskPriority) -> Void
) throws(E) -> T
  where T: ~Copyable
```

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

The same applies to `withTaskPriorityEscalationHandler`. The solution is to
remove the now-redundant `await`s.

## ABI compatibility

This change is a purely additive change to the Concurrency library.

## Implications on adoption

The additions described in this proposal require a new version of the Swift
standard library and runtime. Libraries that want to adopt synchronous
cancellation or priority escalation handlers while supporting older platforms
have to either eschew this particular path, or require an async calling context
on their callers.

Backporting to code running an older stdlib version is not immediately viable,
since the change requires runtime support for registering handlers when there
is no task in the current thread of execution.

