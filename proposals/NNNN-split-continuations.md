# Split continuations

* Proposal: [SE-NNNN](NNNN-split-continuations.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#91981](https://github.com/swiftlang/swift/pull/91981)
* Related Proposals:
    - [SE-0300: Continuations for interfacing async tasks with synchronous code][SE-0300]
    - [SE-0392: Custom Actor Executors][SE-0392]
    - [SE-0417: Task Executor Preference][SE-0417]
    - [SE-0462: Task Priority Escalation APIs][SE-0462]
    - [SE-0528: `Continuation` - Safe and Performant Async Continuations][SE-0528]
* Review: ([pitch](https://forums.swift.org/t/pitch-split-continuation/90096))

## Summary of changes

Introduces a new form of `withContinuation` whose body is `async` and receives
both halves of a continuation: the existing `Continuation` that is used to
resume and a new `ContinuationWaiter` that is used to wait. Waiting on the
waiter can install cancellation and priority escalation handlers that are only
active while the task is suspended on the continuation.

Additionally, this proposal adds new `resumeSynchronously` methods to
`Continuation`, `UnsafeContinuation` and `CheckedContinuation` that allow an
executor to offer its current execution context to the resumed task. If the task
resumes on the same executor, it runs inline instead of being enqueued.

Lastly, this proposal amends [SE-0462] so that priority escalation handlers are
always called once with the task's current priority when they are installed.
This closes a race where an escalation that happens before the handler is
installed is never reported.

## Motivation

[SE-0528] introduced `Continuation`, a noncopyable continuation that enforces
that it is resumed exactly once. Its `withContinuation` method follows the shape
of the continuation APIs from [SE-0300]. The body is synchronous and receives
the continuation. Once the body returns the task suspends until the continuation
is resumed. Creating the continuation and awaiting it are coupled together in
one call.

### Cancellation and escalation handlers race with the continuation

When creating a continuation, it is very common to also want to handle
cancellation of the waiting task. For example, an I/O system that is waiting for
a read to complete wants to cancel the pending read once the task is cancelled.
Similarly, a thread pool might want to move a work item up in its queue once the
priority of the waiting task is escalated.

The only way to do this today is to set up the handlers around the
`withContinuation` call:

```swift
func read(into buffer: ReadBuffer) async throws(IOError) -> Int {
    // We need an identity that both the body and the handler know about
    let id = eventLoop.makeOperationID()
    return try await withTaskCancellationHandler {
        try await withContinuation(of: Int.self, throwing: IOError.self) { continuation in
            eventLoop.register(id, .read(fd, buffer), continuation)
        }
    } onCancel: {
        eventLoop.cancel(id)
    }
}
```

While it looks simple enough it has a few hard-to-handle problems:

1. The cancellation handler can run before the continuation is even created. If
   the task is already cancelled `onCancel` runs inline, before the body of
   `withContinuation` is executed. It can also run concurrently with the body
   from another thread.
2. Since the handler can't get the continuation, the code has to create an id or
   another token up front so that the handler and the body can be related each
   other.
3. The event loop has to handle a `cancel(id)` for an id that it hasn't
   registered an operation for yet. This can either mean the operation was not
   registered yet, or that it already completed. To tell those apart the event
   loop has to remember the cancelled ids and it has to clean them up again at
   some point. This state tracking is very easy to get wrong.

The same problems exist for priority escalation handlers from [SE-0462] when
they are placed around a `withContinuation` call. If both handlers are needed,
they have to be nested which makes the code even harder to read.

What we really want is to first create the continuation, hand it to whoever is
going to resume it, and then await it with the handlers installed. This way the
handlers can only run once the continuation is already registered.

### Resuming a continuation always enqueues the task

Continuations can be resumed from an executor such as when the executor also
handles I/O operations. For example reading from a socket or a file. Once a read
completes, the event loop resumes the continuation of the task that is waiting
for that read.

```swift
final class EventLoop: SerialExecutor {
    func run() {
        while true {
            for completion in selector.waitForCompletions() {
                // The task is enqueued on this event loop and runs later
                completion.continuation.resume(returning: completion.bytesRead)
            }
            runEnqueuedJobs()
        }
    }
}
```

Today resuming a continuation always enqueues the task on the executor that it
resumes on. Even if this executor is the event loop that is currently resuming
the continuation. This adds latency with an extra round through the job queue for
every I/O operation.

Executors can already run a job synchronously with
`ExecutorJob.runSynchronously(on:)` from [SE-0392] and
`runSynchronously(isolatedTo:taskExecutor:)` from [SE-0417]. However, there is
no way to do the same when resuming a continuation.

## Proposed solution

### Splitting creating and awaiting a continuation

A new `withContinuation` method passes both halves of a continuation to an
`async` body. The `Continuation` is used to resume, and the
`ContinuationWaiter` is used to wait.

```swift
func read(into buffer: ReadBuffer) async throws(IOError) -> Int {
    try await withContinuation(of: Int.self, throwing: IOError.self) { continuation, waiter in
        let id = eventLoop.register(.read(fd, buffer), continuation)
        return try await waiter.wait(onCancel: { _ in eventLoop.cancel(id) })
    }
}
```

The handlers are only installed while the task awaits the continuation. When
`onCancel` runs, the read is guaranteed to be registered already. The event loop
only has to handle a `cancel(id)` for an operation that already completed, which
it can just ignore.

Similar to the existing `withContinuation` method, the continuation can be
resumed before `wait()` is called on the waiter. In this case `wait()` returns
right away without suspending.

### Resuming on the current executor

New `resumeSynchronously` methods on `Continuation` allow the resumer to offer
the executor that it is currently running on.

```swift
final class EventLoop: SerialExecutor {
    func run() {
        while true {
            for completion in selector.waitForCompletions() {
                // If the task resumes on this event loop it runs right here
                completion.continuation.resumeSynchronously(
                    returning: completion.bytesRead,
                    isolatedTo: self.asUnownedSerialExecutor()
                )
            }
            runEnqueuedJobs()
        }
    }
}
```

If the awaiting task resumes on the offered executor, the task runs inline until
its next suspension point, and `resumeSynchronously` returns afterwards. If the
task resumes on another executor, it is enqueued as usual. This mirrors how
`ExecutorJob.runSynchronously(on:)` runs a job.

## Detailed design

### `withContinuation`

```swift
/// Creates a continuation and hands `body` both halves: the *resume* half
/// (a ``Continuation``) to give to whoever performs the work, and the *await*
/// half (a ``ContinuationWaiter``) for the task to wait on.
///
/// The continuation must be resumed exactly once, and the waiter waited on
/// exactly once, before `body` returns.
///
/// - Parameters:
///   - of: The `Success` type the continuation is resumed with.
///   - throwing: The `Failure` type the continuation can be resumed by
///     throwing.
///   - body: Receives both halves of the continuation. Its own result
///     becomes the result of this function.
public nonisolated(nonsending) func withContinuation<
    Success: ~Copyable,
    Failure: Error,
    BodyResult: ~Copyable,
    BodyFailure: Error
>(
    of: Success.Type = Success.self,
    throwing: Failure.Type,
    _ body: nonisolated(nonsending) (
        consuming Continuation<Success, Failure>,
        consuming ContinuationWaiter<Success, Failure>
    ) async throws(BodyFailure) -> BodyResult
) async throws(BodyFailure) -> BodyResult
```

The body runs in the calling task and on the isolation of the caller. Unlike the
existing `withContinuation`, the result and error of the body are independent of
the ones of the continuation. This allows the body to transform the value of the
continuation or to catch its error and throw another one.

```swift
let description = await withContinuation(of: Int.self, throwing: Never.self) { continuation, waiter in
    continuation.resume(returning: 42)
    let value = await waiter.wait()
    return "value: \(value)"
}
```

The continuation that is passed to the body is the same `Continuation` type from
[SE-0528]. This means that all existing code that resumes a `Continuation` works
without any changes with a continuation that was created by the new method.

### `ContinuationWaiter`

```swift
/// The *wait* half of a continuation, can be used by a task to suspend until
/// the continuation is resumed.
///
/// It must be waited on exactly once and cannot leave the
/// ``withContinuation(of:throwing:_:)`` scope it was passed into, and it traps
/// if it is destroyed without being waited on.
public struct ContinuationWaiter<Success: ~Copyable, Failure: Error>: ~Copyable, ~Escapable {
    /// Suspend until the paired ``Continuation`` is resumed, with a
    /// cancellation handler and a priority-escalation handler installed for the
    /// duration of the suspension.
    ///
    /// If the continuation was already resumed before `wait` is called, this
    /// call does not suspend at all and returns the value immediately.
    ///
    /// If the current task is already cancelled, `onCancel` runs before this
    /// function suspends.
    ///
    /// `onPriorityEscalated` is always called once when `wait` is called, with
    /// the task's current priority as both arguments, so that an escalation that
    /// happened before the handler was installed is not missed.
    ///
    /// - Parameters:
    ///   - onCancel: Run with the reason the task was cancelled with when it is
    ///     cancelled while suspended here. It may run concurrently with the
    ///     resumption, and on any thread.
    ///   - onPriorityEscalated: Run once when `wait` is called, and then when the
    ///     task's priority is escalated while suspended here. The first argument
    ///     is the old priority (before escalation), and the second argument is
    ///     the new escalated priority. It may run concurrently with the
    ///     resumption, and on any thread.
    public nonisolated(nonsending) consuming func wait(
        onCancel handleCancellation: sending (CancellationError.Reason) -> Void,
        onPriorityEscalated handlePriorityEscalation: @Sendable (TaskPriority, TaskPriority) -> Void
    ) async throws(Failure) -> sending Success

    /// Similar to the above, but only installs a cancellation handler.
    public nonisolated(nonsending) consuming func wait(
        onCancel handleCancellation: sending (CancellationError.Reason) -> Void
    ) async throws(Failure) -> sending Success

    /// Similar to the above, but only installs a priority-escalation handler.
    public nonisolated(nonsending) consuming func wait(
        onPriorityEscalated handlePriorityEscalation: @Sendable (TaskPriority, TaskPriority) -> Void
    ) async throws(Failure) -> sending Success

    /// Similar to the above, but doesn't install any handlers.
    public nonisolated(nonsending) consuming func wait() async throws(Failure) -> sending Success
}
```

The waiter is `~Copyable` since it must be waited on exactly once. All `wait`
methods are `consuming`, so the compiler prevents waiting on it twice. Similar
to `Continuation`, dropping the waiter without waiting on it traps at runtime.

The waiter is `~Escapable` since the storage of the continuation is allocated
with the task allocator and is deallocated once `withContinuation` returns.
Hence, must not escape the body, but it can be passed to other functions
including functions with different isolation.

The handlers follow the same rules as `withTaskCancellationHandler` and
`withTaskPriorityEscalationHandler`. The latter is amended by this proposal, as
described in the next section.

- The handlers are installed when `wait` is called and removed again before
  `wait` returns. Cancelling or escalating the task after `wait` returned
  doesn't run them.
- If the task is already cancelled when `wait` is called, `onCancel` runs inline
  before the task suspends.
- `onCancel` runs at most once, and receives the reason that the task was
  cancelled with, like the handler of `withTaskCancellationHandler`.
- `onPriorityEscalated` runs once inline when `wait` is called, and then once
  for every escalation while the task is suspended. Calls to it are never
  concurrent with each other.
- Both handlers can run concurrently to resuming the continuation and on any
  thread.

### Calling escalation handlers when they are installed

Code that wants to propagate priority escalation reads the current priority,
hands the work to some other system at that priority, and then installs an
escalation handler:

```swift
let priority = Task.currentPriority
let job = queue.enqueue(request, priority: priority, resuming: continuation)
return try await waiter.wait(onPriorityEscalated: { _, newPriority in
    queue.escalate(job, to: newPriority)
})
```

If the task is escalated after `Task.currentPriority` is read but before the
handler is installed, the handler is never told about it and the work stays at
the old priority. Cancellation doesn't have this problem since `onCancel` runs
inline if the task is already cancelled. There is no equivalent for escalation,
since the runtime can't know which priority the caller last observed. To close
this gap, an escalation handler is always called once with the task's current
priority as both arguments when it is installed.

The handler can be called with a priority that the work already runs at. It
should compare against the priority that the work was enqueued with and only act
if the new priority is higher:

```swift
let priority = Task.currentPriority
let job = queue.enqueue(request, priority: priority, resuming: continuation)
return try await waiter.wait(onPriorityEscalated: { _, newPriority in
    guard newPriority > priority else { return }
    queue.escalate(job, to: newPriority)
})
```

#### Amendment to SE-0462

The same race exists for `withTaskPriorityEscalationHandler`. Therefore, this
proposal changes it to also call its handler once with the task's current
priority when the handler is installed, before `operation` runs:

```swift
let priority = Task.currentPriority
let job = queue.enqueue(request, priority: priority)
return try await withTaskPriorityEscalationHandler {
    try await job.value
} onPriorityEscalated: { _, newPriority in
    guard newPriority > priority else { return }
    queue.escalate(job, to: newPriority)
}
```

### Resuming on executors

```swift
extension Continuation where Success: ~Copyable {
    /// Resume the task awaiting this continuation by having it return the given
    /// value, offering the current execution context to run the resumed task.
    ///
    /// The offered execution context is used only if it belongs to the executors
    /// the awaiting task resumes on. If the context doesn't match, the task is
    /// enqueued on its expected execution context instead.
    ///
    /// If the offer is taken, the resumed task runs synchronously, nested inside
    /// this call. This method must therefore only be called from the context of
    /// the offered executors, at a point where they could run one of their own
    /// jobs.
    ///
    /// - Parameters:
    ///   - value: The value to return from the continuation.
    ///   - serialExecutor: The serial executor the resuming thread is running on.
    ///   - taskExecutor: The task executor the resuming thread is running on.
    public consuming func resumeSynchronously(
        returning value: consuming sending Success,
        isolatedTo serialExecutor: UnownedSerialExecutor,
        taskExecutor: UnownedTaskExecutor
    )

    /// Resume the task awaiting this continuation by having it throw the given
    /// error, offering the current execution context to run the resumed task.
    ///
    /// The offered execution context is used only if it belongs to the executors
    /// the awaiting task resumes on. If the context doesn't match, the task is
    /// enqueued on its expected execution context instead.
    ///
    /// If the offer is taken, the resumed task runs synchronously, nested inside
    /// this call. This method must therefore only be called from the context of
    /// the offered executors, at a point where they could run one of their own
    /// jobs.
    ///
    /// - Parameters:
    ///   - error: The error to throw from the continuation.
    ///   - serialExecutor: The serial executor the resuming thread is running on.
    ///   - taskExecutor: The task executor the resuming thread is running on.
    public consuming func resumeSynchronously(
        throwing error: Failure,
        isolatedTo serialExecutor: UnownedSerialExecutor,
        taskExecutor: UnownedTaskExecutor
    )

    /// Resume the task awaiting this continuation by having it either return or
    /// throw based on the given `Result`, offering the current execution context
    /// to run the resumed task.
    ///
    /// The offered execution context is used only if it belongs to the executors
    /// the awaiting task resumes on. If the context doesn't match, the task is
    /// enqueued on its expected execution context instead.
    ///
    /// If the offer is taken, the resumed task runs synchronously, nested inside
    /// this call. This method must therefore only be called from the context of
    /// the offered executors, at a point where they could run one of their own
    /// jobs.
    ///
    /// - Parameters:
    ///   - result: A value to either return or throw from the continuation.
    ///   - serialExecutor: The serial executor the resuming thread is running on.
    ///   - taskExecutor: The task executor the resuming thread is running on.
    public consuming func resumeSynchronously(
        with result: consuming sending Result<Success, Failure>,
        isolatedTo serialExecutor: UnownedSerialExecutor,
        taskExecutor: UnownedTaskExecutor
    )

    /// Similar to the above, but only offers a serial executor.
    public consuming func resumeSynchronously(
        returning value: consuming sending Success,
        isolatedTo serialExecutor: UnownedSerialExecutor
    )

    /// Similar to the above, but only offers a serial executor.
    public consuming func resumeSynchronously(
        throwing error: Failure,
        isolatedTo serialExecutor: UnownedSerialExecutor
    )

    /// Similar to the above, but only offers a serial executor.
    public consuming func resumeSynchronously(
        with result: consuming sending Result<Success, Failure>,
        isolatedTo serialExecutor: UnownedSerialExecutor
    )

    /// Similar to the above, but only offers a task executor. The offer is only
    /// taken if the awaiting task resumes without any serial isolation.
    public consuming func resumeSynchronously(
        returning value: consuming sending Success,
        on taskExecutor: UnownedTaskExecutor
    )

    /// Similar to the above, but only offers a task executor. The offer is only
    /// taken if the awaiting task resumes without any serial isolation.
    public consuming func resumeSynchronously(
        throwing error: Failure,
        on taskExecutor: UnownedTaskExecutor
    )

    /// Similar to the above, but only offers a task executor. The offer is only
    /// taken if the awaiting task resumes without any serial isolation.
    public consuming func resumeSynchronously(
        with result: consuming sending Result<Success, Failure>,
        on taskExecutor: UnownedTaskExecutor
    )
}
```

The three variants mirror the existing `runSynchronously` methods on
`ExecutorJob`:

| `Continuation`                                            | `ExecutorJob`                                     |
| --------------------------------------------------------- | ------------------------------------------------- |
| `resumeSynchronously(returning:isolatedTo:taskExecutor:)` | `runSynchronously(isolatedTo:taskExecutor:)`      |
| `resumeSynchronously(returning:isolatedTo:)`              | `runSynchronously(on: UnownedSerialExecutor)`     |
| `resumeSynchronously(returning:on:)`                      | `runSynchronously(on: UnownedTaskExecutor)`       |

Offering an executor is a best effort. The executor that the task resumes on is
decided when the task awaits the continuation. The resumer, however, gets the
continuation earlier and can't know in advance whether its executor will match.
For example, the task might change its isolation or take a task executor
preference between handing out the continuation and awaiting it. In these cases,
the offer simply isn't taken and the task is enqueued instead.

Since the resumed task runs nested inside of the `resumeSynchronously` call,
these methods must only be called from the context of the offered executors, at
a point where they could run one of their own jobs. Typically, this is from
within the implementation of an executor, between running jobs, just like
`ExecutorJob.runSynchronously`. It is not valid to offer an executor that the
calling code merely happens to be isolated to, such as
`#isolation.unownedSerialExecutor` inside of an actor method. Running the
resumed task from there re-enters the actor outside of a suspension point, which
breaks the guarantee that actors are only re-entered at suspension points. It
can also cause new exclusivity violations.

These methods work for every `Continuation`, independent of whether it was
created by the existing `withContinuation` or by the new split form. The same
methods are also added to `UnsafeContinuation` and `CheckedContinuation`.

```swift
extension UnsafeContinuation {
    public func resumeSynchronously(returning value: sending T, isolatedTo serialExecutor: UnownedSerialExecutor, taskExecutor: UnownedTaskExecutor)
    public func resumeSynchronously(throwing error: E, isolatedTo serialExecutor: UnownedSerialExecutor, taskExecutor: UnownedTaskExecutor)
    public func resumeSynchronously(with result: sending Result<T, E>, isolatedTo serialExecutor: UnownedSerialExecutor, taskExecutor: UnownedTaskExecutor)

    public func resumeSynchronously(returning value: sending T, isolatedTo serialExecutor: UnownedSerialExecutor)
    public func resumeSynchronously(throwing error: E, isolatedTo serialExecutor: UnownedSerialExecutor)
    public func resumeSynchronously(with result: sending Result<T, E>, isolatedTo serialExecutor: UnownedSerialExecutor)

    public func resumeSynchronously(returning value: sending T, on taskExecutor: UnownedTaskExecutor)
    public func resumeSynchronously(throwing error: E, on taskExecutor: UnownedTaskExecutor)
    public func resumeSynchronously(with result: sending Result<T, E>, on taskExecutor: UnownedTaskExecutor)
}

extension CheckedContinuation {
    public func resumeSynchronously(returning value: sending T, isolatedTo serialExecutor: UnownedSerialExecutor, taskExecutor: UnownedTaskExecutor)
    public func resumeSynchronously(throwing error: E, isolatedTo serialExecutor: UnownedSerialExecutor, taskExecutor: UnownedTaskExecutor)
    public func resumeSynchronously(with result: sending Result<T, E>, isolatedTo serialExecutor: UnownedSerialExecutor, taskExecutor: UnownedTaskExecutor)

    public func resumeSynchronously(returning value: sending T, isolatedTo serialExecutor: UnownedSerialExecutor)
    public func resumeSynchronously(throwing error: E, isolatedTo serialExecutor: UnownedSerialExecutor)
    public func resumeSynchronously(with result: sending Result<T, E>, isolatedTo serialExecutor: UnownedSerialExecutor)

    public func resumeSynchronously(returning value: sending T, on taskExecutor: UnownedTaskExecutor)
    public func resumeSynchronously(throwing error: E, on taskExecutor: UnownedTaskExecutor)
    public func resumeSynchronously(with result: sending Result<T, E>, on taskExecutor: UnownedTaskExecutor)
}
```

## Source compatibility

The new APIs are purely additive and don't affect source compatibility.

The amendment to [SE-0462] doesn't change any API, but it changes the behavior
of `withTaskPriorityEscalationHandler`. Its handler is now called once when it
is installed. Handlers already had to cope with being called at any time while
the operation runs, and calling them with the current priority doesn't change
the priority of the task.

## ABI compatibility

This proposal is purely an extension of the ABI of the Concurrency library and
doesn't change any existing features. It adds the `ContinuationWaiter` type and
new runtime entry points to create, await, destroy and resume split
continuations.

The storage of a split continuation is laid out such that the existing runtime
functions for resuming a continuation keep working. This means that code that
was compiled before split continuations existed can resume a `Continuation` that
was created by the new `withContinuation`.

The amendment to [SE-0462] is implemented in the existing runtime entry points
for adding escalation handlers and escalating tasks, and doesn't add any new
ones. Existing binaries get the new behavior when they run on a new runtime.

## Implications on adoption

The additions described in this proposal require a new version of the Swift
standard library and runtime. Libraries that want to adopt split continuations
while supporting older platforms have to keep their current implementation with
the handlers around `withContinuation` for those platforms.

On older runtimes, `withTaskPriorityEscalationHandler` doesn't call its handler
when it is installed. Code that compares against the priority that it observed,
as shown above, works the same on both.

## Alternatives considered

### Add handler parameters to the existing `withContinuation`

Instead of splitting the continuation, we could add `onCancel` and
`onPriorityEscalated` parameters to the existing `withContinuation` method and
install the handlers after the body returned. This solves the race with the
handlers, but it is less flexible. The body still has to be synchronous so it
can't await anything before the task suspends, e.g. registering the continuation
with an actor. The split form allows to do any async work between creating and
awaiting the continuation and composes with other scoped methods.

### Return both halves instead of using a scope

We could return both halves from a method; however, this doesn't work since the
storage of the continuation is allocated with the task allocator, which requires
that it is deallocated in a stack discipline. The scope of `withContinuation`
defines the lifetime of the storage and the waiter being `~Escapable` ensures
that it can't outlive it.

### Only calling the escalation handler if the priority changed

Instead of always calling the escalation handler when it is installed, the
runtime could take a snapshot of the priority when the waiter is created and
only call the handler from `wait` if the priority has changed since then. A
variant of this would be to pass a snapshot of the priority to `wait`
explicitly.

However, the snapshot that matters is the priority at which the work was
handed off, and only the caller knows when that happens. The body might hand
the continuation through several layers, await, or change isolation before it
enqueues the work. A snapshot taken by the runtime is either too early, which
leads to spurious calls, or requires another parameter that users have to know
how to fill in. The handler has to compare against its own snapshot in either
case, so always calling it keeps the rules simple and the same for
`withTaskPriorityEscalationHandler`.

### Requiring explicit handlers

The `wait` overloads without an `onCancel` handler make it easy to ignore
cancellation. We considered requiring both handlers, so that ignoring them is
an explicit choice, e.g. by passing an empty closure, or naming the overloads
less invitingly, e.g. `waitWithoutHandlingTaskCancellation()`. Optional closure
parameters don't work since they are always `@escaping`. Requiring the closures
has a cost since installing a handler isn't free, and an empty closure can't be
detected to skip installing it.

### Naming the wait half `ContinuationAwaiter`

We considered naming the wait half `ContinuationAwaiter`. However, the method to
suspend on it is called `wait()` since `await` is a keyword. Naming the type
`ContinuationWaiter` matches the name of its method.

[SE-0300]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0300-continuation.md
[SE-0392]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
[SE-0417]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md
[SE-0462]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0462-task-priority-escalation-apis.md
[SE-0528]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0528-noncopyable-continuation.md
