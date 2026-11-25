# Synchronous `withTaskCancellationHandler` and `withTaskPriorityEscalationHandler`

* Proposal: [SE-NNNN](NNNN-sync-task-cancellation-escalation-handler.md)
* Authors: [Yaroslav Petryk](https://github.com/malien), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#94512](https://github.com/swiftlang/swift/pull/94512)
* Review: ([pitch](https://forums.swift.org/t/synchronous-overload-of-withtaskcancellationhandler/90894/8))

## Summary of changes

Introduces synchronous overloads of the `withTaskCancellationHandler` and
`withTaskPriorityEscalationHandler` functions for use in sync code, which
nevertheless may be executing inside of a Swift Concurrency task context.

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
public func withTaskCancellationHandler<Return, Failure>(
  operation: () throws(Failure) -> Return,
  onCancel handler: sending () -> Void
) throws(Failure) -> Return
  where Return: ~Copyable,
        Failure: Error

public func withTaskCancellationHandler<Return, Failure>(
  operation: () throws(Failure) -> Return,
  onCancel handler: sending (CancellationError.Reason) -> Void
) throws(Failure) -> Return
  where Return: ~Copyable,
        Failure: Error
```

```swift
public func withTaskPriorityEscalationHandler<T, E>(
  operation: () throws(E) -> T,
  onPriorityEscalated handler: @Sendable (TaskPriority, TaskPriority) -> Void
) throws(E) -> T
  where T: ~Copyable
        E: Error
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

