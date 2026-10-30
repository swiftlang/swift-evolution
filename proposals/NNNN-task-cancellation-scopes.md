# Task cancellation scopes

* Proposal: [SE-NNNN](NNNN-task-cancellation-scopes.md)
* Authors: [Konrad Malawski](https://github.com/ktoso), [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: Available as SPI on `main` ([swiftlang/swift#91516](https://github.com/swiftlang/swift/pull/91516))
* Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

Introduces `withTaskCancellationScope` and `TaskCancellationScope`. A scope
makes a part of a task cancellable on its own without cancelling the entire task.
This allows libraries to cancel an operation without creating child tasks only
for the purpose of getting a separate cancellation boundary.

## Motivation

[SE-0304] introduced task cancellation. Cancellation is a property of a whole
task. Once a task is cancelled it stays cancelled, and the cancellation
propagates to all of its children. Today, the only safe way to cancel just a
part of the work that a task is doing is to run that part in a new child task
and cancel the child task.

This is a very common pattern in server-side and networking code. Often we want
to run an operation and cancel it once some external event happens, e.g. the
peer closed the connection, a graceful shutdown was triggered, or a deadline
expired. The external event is not a cancellation of the current task, so the
code has to create a task group, run the operation in one child task, wait for
the event in another child task and then cancel the group. This pattern has a
few problems:

1. It allocates at least one or two child tasks for every operation. In a server
   this is often done per connection or even per request.
2. The operation must be `sending` and `@escaping` since it runs in a child
   task. Furthermore, the result of the operation must be `sending`.
3. The operation runs in a different task and loses the isolation of the
   caller's task.
4. The code to correctly race the operation against the event and cancel the
   other side is verbose and easy to get wrong.

Let's look at two concrete examples from the server ecosystem.

### Cancelling request handling when the client goes away

[swift-http-server] wants to cancel the user's request handler when the client
closes the connection. This prevents the request handler from doing unnecessary
work after the peer has gone away. The [current implementation][http-server-pr]
is a channel handler that notices the closed connection and yields into an
`AsyncStream`. The request handling is then raced against this stream in a task
group. Simplified, it looks like this:

```swift
func withCancellationWhenClientCloses(
    signalledBy clientClosed: AsyncStream<Void>,
    operation: sending @escaping () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            for await _ in clientClosed {
                return
            }
        }
        // Whichever child task finishes first cancels the other one
        try await group.next()
        group.cancelAll()
    }
}
```

The `operation` here is an HTTP/1.1 request loop or an HTTP/2 or HTTP/3 stream.
This means that for every connection or stream the server has to create two
additional child tasks. Additionally, the user's request handler has to run in a
child task, which means that everything the request handler needs, such as the
request reader and response writer, has to be `Sendable`.

In the end, all that we really need is a scope that we can cancel once the
client closes the connection.

### Cancelling an operation on graceful shutdown

[swift-service-lifecycle] offers a
[`cancelWhenGracefulShutdown`][cancel-when-graceful-shutdown] method that
cancels an operation once a graceful shutdown is triggered. A common use-case is
to stop consuming an infinite asynchronous sequence when the application shuts
down. The implementation looks like this:

```swift
public func cancelWhenGracefulShutdown<T>(
    _ operation: sending @escaping () async throws -> sending T
) async rethrows -> T {
    return try await withThrowingTaskGroup(of: ValueOrGracefulShutdown<T>.self) { group in
        group.addTask {
            let value = try await operation()
            return .value(value)
        }

        group.addTask {
            switch await CancellationWaiter().wait() {
            case .cancelled:
                return .cancelled
            case .gracefulShutdown:
                return .gracefulShutdown
            }
        }

        let result = try await group.next()
        group.cancelAll()

        switch result {
        case .value(let t):
            return t

        case .gracefulShutdown, .cancelled:
            switch try await group.next() {
            case .value(let t):
                return t
            case .gracefulShutdown, .cancelled:
                fatalError("Unexpectedly got gracefulShutdown from group.next()")
            case nil:
                fatalError("Unexpectedly got nil from group.next()")
            }

        case nil:
            fatalError("Unexpectedly got nil from group.next()")
        }
    }
}
```

This method has the same problems as above. It creates two child tasks, requires
the operation to be `sending` and `@escaping`, requires the result to be
`sending`, and needs a helper type and a few `fatalError`s to handle the results
of the task group. At the same time, `swift-service-lifecycle` already offers
`withGracefulShutdownHandler` which runs a synchronous handler once a graceful
shutdown is triggered. Similar to the HTTP server, the only missing piece is
something to cancel from that handler.

### Cancelling the current task instead of a child task

Besides creating a child task, there is a second workaround. To avoid the cost
of a child task, developers sometimes run the operation directly in the current
task and cancel the whole task once the operation should stop. This is common
with APIs that run a loop internally and call a closure for every element, where
the closure can't just `break` out of the loop. Since there is no safe API to
get the current task, this requires `UnsafeCurrentTask`:

```swift
func waitForCompletion(of job: Job) async throws {
    try await client.subscribe(to: job.events) { event in
        if event.isCompletion {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}
```

This is only correct if nothing else runs in the task after the operation, since
cancelling a task can't be undone. Code that runs after the operation, e.g. the
code of the caller, observes the cancellation as well, even though it was never
meant to be cancelled.

## Proposed solution

A new `withTaskCancellationScope` method runs an operation inside a scope and
passes a `TaskCancellationScope` to the operation. Cancelling the scope has the
same effect as cancelling a task, but only for the code that runs inside the
scope.

```swift
await withTaskCancellationScope { scope in
    print(Task.isCancelled) // false

    scope.cancel()

    print(Task.isCancelled) // true
    try? await Task.sleep(for: .seconds(1)) // returns immediately
}

print(Task.isCancelled) // false, the task itself was never cancelled
```

The `TaskCancellationScope` is `~Escapable` and `Sendable`. It can only be used
while the operation is running; however, it can be captured by non-escaping
closures such as structured event handlers. This allows to cancel the scope from
a handler that runs concurrently to the operation.

With this, the HTTP server can cancel the request handler directly from the
callback passed to `withClientCloseHandler`. This significantly simplifies the
code by composing both scoped methods.

```swift
func handle(request: HTTPRequest, reader: RequestReader, writer: ResponseWriter) async throws {
    try await withTaskCancellationScope { scope in
        try await withClientCloseHandler {
            try await requestHandler.handle(request, reader, writer)
        } onClientClose: {
            scope.cancel()
        }
    }
}
```

Similarly, `cancelWhenGracefulShutdown` can be implemented without any child
task by cancelling the scope from the handler of `withGracefulShutdownHandler`.

```swift
public func cancelWhenGracefulShutdown<T>(
    _ operation: () async throws -> T
) async rethrows -> T {
    try await withTaskCancellationScope { scope in
        try await withGracefulShutdownHandler {
            try await operation()
        } onGracefulShutdown: {
            scope.cancel()
        }
    }
}
```

## Detailed design

### `withTaskCancellationScope`

```swift
/// Executes an operation inside a cancellation scope.
///
/// The `operation` closure receives a ``TaskCancellationScope`` which can be
/// used to cancel the scope.
///
/// Cancelling the scope causes `Task.isCancelled` to return `true` for code
/// executing inside `operation`, and triggers any other effects task cancellation does.
///
/// ## Cancellation Semantics
/// Cancelling a scope is semantically equivalent to cancelling as-if the scope were its own task.
///
/// The scope's effects on `Task.isCancelled` are strictly contained for the duration
/// of executing the `operation`; the enclosing task's own cancellation state is unchanged.
///
/// Cancellation cascades to nested scopes, to task groups and to structured
/// child tasks (`async let`, child tasks of task groups created inside the
/// scope) created inside the scope.
///
/// - Parameter operation: The work to perform. Receives the scope which can
///   be used to cancel the operation. The scope can't escape `operation`.
/// - Returns: the result returned by the `operation` closure.
/// - Throws: if an error is thrown by the `operation` closure.
public nonisolated(nonsending) func withTaskCancellationScope<Return: ~Copyable, Failure: Error>(
    _ operation: nonisolated(nonsending) (TaskCancellationScope) async throws(Failure) -> Return
) async throws(Failure) -> Return
```

The operation runs in the calling task and on the isolation of the caller.
`withTaskCancellationScope` always runs the operation, even if the task or an
outer scope is already cancelled. Similar to `withDeadline` it is up to the
operation to check for cancellation.

```swift
/// Executes a synchronous operation inside a cancellation scope.
///
/// See the asynchronous `withTaskCancellationScope(_:)` for the details.
public func withTaskCancellationScope<Return: ~Copyable, Failure: Error>(
    _ operation: (TaskCancellationScope) throws(Failure) -> Return
) throws(Failure) -> Return
```

The synchronous overload allows a synchronous function to cancel a part of the
work it does, e.g. a blocking operation that checks `Task.isCancelled`. Outside
of a task scopes have no effect similar to the synchronous
`withTaskCancellationShield` from [SE-0504][SE-0504].

### `TaskCancellationScope`

```swift
/// Represents an independently-cancellable region within a task, distinct from whole-task cancellation.
///
/// ## Cancellation Semantics
/// Cancelling a scope is semantically equivalent to cancelling as-if the scope were its own task.
///
/// The scope's effects on `Task.isCancelled` are strictly contained for the duration
/// of executing the `operation`; the enclosing task's own cancellation state is unchanged.
///
/// Cancellation cascades to nested scopes, to task groups and to structured
/// child tasks (`async let`, child tasks of task groups created inside the
/// scope) created inside the scope.
public struct TaskCancellationScope: ~Escapable, Sendable {
    /// Cancel this scope.
    ///
    /// - Parameter reason: The ``CancellationError/Reason`` to record on the
    ///   scope; observable via ``Task/cancellationReason`` from code
    ///   running inside the scope, and passed to reason-aware cancellation
    ///   handlers. Defaults to ``CancellationError/Reason/unspecified``.
    public func cancel(reason: CancellationError.Reason = .unspecified)

    /// A Boolean value indicating whether this scope has been cancelled.
    ///
    /// - Returns: `true` if this scope has been cancelled (via
    ///   ``cancel(reason:)`` or by the cancellation of an enclosing task or
    ///   scope), `false` otherwise. Once `true`, remains `true` for the
    ///   scope's lifetime.
    public var isCancelled: Bool { get }

    /// A value indicating the reason this scope has been cancelled.
    ///
    /// - Returns: A non-`nil` reason if this scope has been cancelled (via
    ///   ``cancel(reason:)`` or by the cancellation of an enclosing task or
    ///   scope), `nil` otherwise. Once this returns a reason, it keeps
    ///   returning the same reason for the scope's lifetime.
    public var cancellationReason: CancellationError.Reason? { get }
}
```

`TaskCancellationScope` is `Sendable` and `Copyable`. Cancelling a scope and
checking whether a scope is cancelled are safe to do from any thread, the same
as cancelling a task. This allows to cancel a scope from closures that run
concurrently to the operation, such as a structured event handlers.

### Cancellation semantics

Since, cancellation scopes introduce a new concept to Swift's cancellation, this
section lays out the up-to-date cancellation semantics.

The goal of cancellation scopes is that cancelling a scope behaves the same as
if the operation would run in its own child task that gets cancelled. Tasks,
their scopes and their task groups form a tree, and the following rules apply to
each of them.

#### Cancellation happens once

A task, a task group, and a cancellation scope can each only be cancelled once.
The first cancellation decides their reason. Any later cancellation has no
further effect on them.

#### Cancellation propagates down

Cancelling a task, task group, or a cancellation scope also cancels everything
inside of it with the same reason, including:

- Nested cancellation scopes
- Cancellation handlers
- Task groups
- Structured child tasks created via `async let` or task groups

> Importantly, cancellation never propagates up from a child task to its
parent or from a cancellation scope to any enclosing scope or task.

#### Cancellation shields prevent observing everything outside of them

A [task cancellation shield][SE-0504] prevents the code inside the shield from
observing the cancellation of every scope and of the task that encloses the
shield.

A scope inside the shield can still be cancelled individually, and code inside
that scope observes its cancellation. Once the shield ends, the code outside of
it observes the cancellation again.

```swift
await withTaskCancellationShield {
    await withTaskCancellationScope { scope in
        scope.cancel()
        print(Task.isCancelled) // true, the outer shield doesn't shield the scope
        await withTaskCancellationShield {
            print(Task.isCancelled) // false, the inner shield shields the scope
        }
    }
}
```

#### Child tasks and scopes inherit the cancellation on creation

A task group, a child task, a cancellation scope or a cancellation handler that
is created inside an already cancelled task or scope inherits the cancellation
state and reason. A cancellation handler is run right away.

#### Child tasks inherit the cancellation of the group

Child tasks inherit the cancellation status and reason of the task group they
belong to and not the context they are created in. Cancellation shields and
scopes around the `addTask` calls have no effect on the cancellation behavior of
the child.

#### Cancellation is observed from the nearest scope

`Task.isCancelled`, `Task.cancellationReason` and `Task.checkCancellation()`
report the cancellation of the nearest enclosing scope, even if the enclosing
task is cancelled but the cancellation didn't reach the scope yet. Outside of
any scope they report the cancellation of the task.

#### `Task` and `UnsafeCurrentTask` instances only observe the task

Instance properties and methods declared on `Task` and `UnsafeCurrentTask`,
such as `isCancelled` and `cancellationReason`, only report whether the task
itself is cancelled. They don't take cancellation scopes or shields into
account.

#### Deadlines are scopes

A `withDeadline` from [SE-0526][SE-0526] runs its operation inside a
cancellation scope that is cancelled once the deadline expires. The same rules
apply to it. In particular, a shield prevents the code inside of it from
observing the deadlines outside of it: `Task.activeDeadline(for:)` and
`Task.hasActiveDeadline` don't report them, and a `withDeadline` inside the
shield always installs its own deadline, even if an outer deadline expires
earlier.

```swift
await withDeadline(in: .seconds(1)) {
    await withTaskCancellationShield {
        print(Task.hasActiveDeadline) // false
        await withDeadline(in: .seconds(2)) {
            try? await Task.sleep(for: .seconds(3)) // returns after 2 seconds
        }
    }
}
```

## Source compatibility

This proposal is purely additive and doesn't affect source compatibility.

## ABI compatibility

This proposal is purely an extension of the ABI of the Concurrency library and
doesn't change any existing features. The runtime functions for cancellation
scopes already exist since they are used by `withDeadline`.

## Implications on adoption

The additions described in this proposal require a new version of the Swift
standard library and runtime. Libraries that want to adopt cancellation scopes
while supporting older platforms have to keep their current task group based
implementation for those platforms.

## Alternatives considered

### Keep using task groups

We could keep using task groups for these use-cases. As shown in the motivation,
this requires additional child tasks, `sending` and `@escaping` operations and
`sending` results, and loses the isolation of the caller.

### Make child tasks cheaper and more flexible instead

Instead of adding scopes, we could address the problems of the task group based
implementations by improving child tasks:

- Better support for `~Copyable` and `~Escapable` values in tasks and task
  groups, so that operations and their results don't have to be `sending` and
  `@escaping`.
- A cheap way to run a statically known number of child tasks in the same
  isolation as the caller.

We think both improvements are valuable and should be done independently of this
proposal. They make child tasks easier to use for all kinds of concurrent work.
However, they are orthogonal to cancellation scopes and don't remove the need
for them. The examples in the motivation don't need concurrency. They need a
cancellation boundary around an operation that runs in the current task. With
child tasks, the operation still runs in a different task, and a cheaper child
task is still more expensive than a scope.

### Make `TaskCancellationScope` `Escapable`

The scope points directly to the record of the scope in the task. This record is
allocated with the task allocator and is deallocated once the scope ended.
Making the scope `Escapable` would allow it to outlive the record.

### Make `TaskCancellationScope` `~Copyable`

The scope could be `~Copyable` and be passed to the operation as `borrowing`.
However, nothing relies on the scope having a unique owner. Cancelling a scope
doesn't consume it and can be done multiple times, and since the scope is
`Sendable` it can already be shared with a handler that runs concurrently.

### Naming

We considered a few other names for `withTaskCancellationScope` and
`TaskCancellationScope`:

- `withCancellationScope` and `CancellationScope`: Shorter, but a scope only
  affects the cancellation of a task, and the existing APIs that are about task
  cancellation all include the word "task", e.g. `withTaskCancellationHandler`
  and `withTaskCancellationShield`.
- `withCancellableScope`: Describes what the scope can do, but reads as if the
  code outside of a scope weren't cancellable.
- `withCancellationToken` and `CancellationToken`: Other ecosystems, e.g.
  [.NET][dotnet-cancellation], use cancellation tokens. A token is usually
  passed explicitly to every operation that should be cancellable. A scope in
  contrast affects all code that runs inside of it, the same as the cancellation
  of a task.

The term "cancel scope" is also used by structured concurrency libraries in
other languages, e.g. Python's [Trio][trio-cancel-scopes], for the same concept.

[SE-0304]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md
[SE-0504]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0504-task-cancellation-shields.md
[SE-0526]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0526-deadline.md
[swift-http-server]: https://github.com/swift-server/swift-http-server
[http-server-pr]: https://github.com/swift-server/swift-http-server/pull/134
[swift-service-lifecycle]: https://github.com/swift-server/swift-service-lifecycle
[dotnet-cancellation]: https://learn.microsoft.com/en-us/dotnet/standard/threading/cancellation-in-managed-threads
[trio-cancel-scopes]: https://trio.readthedocs.io/en/stable/reference-core.html#cancellation-and-timeouts
[cancel-when-graceful-shutdown]: https://github.com/swift-server/swift-service-lifecycle/blob/5e3b0e9a1ef23aa50d1350413c059edc93261ed8/Sources/ServiceLifecycle/GracefulShutdown.swift#L170
