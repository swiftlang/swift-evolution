# discardResults for TaskGroups

* Proposal: [SE-NNNN](NNNN-task-group-discard-results.md)
* Authors: [Cory Benfield](https://github.com/Lukasa), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: Pull request available at https://github.com/apple/swift/pull/62271

### Introduction

We propose to introduce a new boolean parameter, `discardResults`, to `TaskGroup` and `ThrowingTaskGroup`. This parameter controls whether the `TaskGroup` retains the results of its completed child `Task`s for passing to `next()`, or whether it discards those results immediately.

Pitch thread: [Task Pools](https://forums.swift.org/t/pitch-task-pools/61703).

## Motivation

Task groups are the building block of structured concurrency, allowing for the Swift runtime to relate groups of tasks together. This enables powerful features such as automatic cancellation propagation, correctly propagating errors, and ensuring well-defined lifetimes, as well as providing diagnostic information to programming tools.

The version of Task Groups introduced in [SE-0304](https://github.com/apple/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) provides all of these features. However, it also provides the ability to propagate return values to the user of the task group. This capability provides an unexpected limitation in some use-cases.

As users of Task Groups are able to retrieve the return values of child tasks, it implicitly follows that the Task Group preserves at least the `Result` of any completed child task. As a practical matter, the task group actually preseves the entire `Task` object. This data is preserved until the user consumes it via one of the Task Group consumption APIs, whether that is `next()` or by iterating the Task Group.

The result of this is that Task Groups are ill-suited to running for a potentially unbounded amount of time. An example of such a use-case is managing connections accepted from a listening socket. A simplified example of such a workload might be:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    while let newConnection = try await listeningSocket.accept() {
        group.addTask {
            handleConnection(newConnection)
        }
    }
}
```

As written, this task group will leak all the child `Task` objects until the listening socket either terminates or throws. If this was written for a long-running server, it is entirely possible for this Task Group to survive for a period of days, leaking thousands of Task objects. For stable servers, this will eventually drive the process into memory exhaustion, forcing it to be killed by the OS.

The current implementation of Task Groups do not provide a practical way to avoid this issue. Task Groups are (correctly) not `Sendable`, so neither the consumption of completed `Task` results nor the submission of new work can be moved to a separate `Task`.

The most natural attempt to avoid this unbounded memory consumption would be to attempt to occasionally purge the completed task results. An example might be:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    while let newConnection = try await listeningSocket.accept() {
        group.addTask {
            handleConnection(newConnection)
        }
        try await group.next()
    }
}
```

Unfortunately, all of the methods for attempting to pop the queue of completed `Task`s will suspend if all currently live child `Task`s are executing. This means that the above pattern (or any similar pattern) is at risk of occasional livelocks, where pending connections could be accepted, but the `Task` is blocked waiting for existing work to complete.

There is only one design pattern to avoid this issue, which involves forcibly bounding the maximum concurrency of the Task Group. This pattern looks something like the below:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    // Fill the task group up to maxConcurrency
    for _ in 0..<maxConcurrency {
	    guard let newConnection = try await listeningSocket.accept() else {
	        break
	    }
	    
	    group.addTask { handleConnection(newConnection) }
	}
	
	// Now follow a one-in-one-out pattern
	while true {
	    _ = try await group.next()
	    guard let newConnection = try await listeningSocket.accept() else {
	        break
	    }
	    group.addTask { handleConnection(newConnection) }
	}
}
```

While this is workable, it forces users to determine a value for `maxConcurrency`. This is frequently very hard to decide _a priori_. Practically users tend to guess, and either get a value far too large (causing memory to be wasted) or far too low (causing the system to be underutilized). While there is value in developing a strategy for bounding the maximum concurrency of a `TaskGroup`, that problem is sufficiently complex to be worth its own separate discussion.

## Proposed Solution

We propose adding a new Boolean option to `TaskGroup` and `ThrowingTaskGroup` factory functions (`withTaskGroup` and `withThrowingTaskGroup`), called `discardResults`. This option defaults to `false`, which causes `TaskGroup` and `ThrowingTaskGroup` to behave as they do today. When the user sets this value to `true`, the runtime behaviour of `TaskGroup` and `ThrowingTaskGroup` changes in the following ways:

1. `[Throwing]TaskGroup` automatically cleans up its child `Task`s when those `Task`s complete.
2. `[Throwing]TaskGroup` always returns `nil` from its `next()` method, behaving like an empty `AsyncSequence`.

This has the effect of automatically discarding the return type from the child tasks.

In this mode, `[Throwing]TaskGroup` maintains many of the same behaviours as when `discardResults` is set to `false`, albeit in some cases with slightly different manifestations:

1. `ThrowingTaskGroup`s are automatically cancelled when one of their child `Task`s terminates with a thrown error, as if `next()` had been immediately called in the parent `Task`.
2. `ThrowingTaskGroup`s that are cancelled in this way will, after awaiting all their child `Task`s, throw the error that originally caused them to be auto-cancelled, again as if `next()` had been immediately called in the parent `Task`.
3. Automatic cancellation propagation works as usual, so cancelling the `Task` that owns a `[Throwing]TaskGroup` automatically cancels all child `Task`s.

### API Surface

```swift
public func withTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  returning returnType: GroupResult.Type = GroupResult.self,
  discardResults: Bool = false,
  body: (inout TaskGroup<ChildTaskResult>) async -> GroupResult
) async -> GroupResult {

public func withThrowingTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  returning returnType: GroupResult.Type = GroupResult.self,
  discardResults: Bool = false,
  body: (inout ThrowingTaskGroup<ChildTaskResult, Error>) async throws -> GroupResult
) async rethrows -> GroupResult {
```

## Alternatives Considered

### Introducing new types

The [original pitch](https://forums.swift.org/t/pitch-task-pools/61703) introduced two new types, `TaskPool` and `ThrowingTaskPool`. These types were introduced in order to expose at the type system level the inability to iterate the pool for new tasks. This would avoid the `next()` behaviour introduced in this pitch, where `next()` always returns `nil`. This was judged a worthwhile change to justify introducing new types.

Several reviewers of the pitch felt that this was not a sufficiently useful capability to justify the introduction of the new types, and that the pitched behaviour more properly belonged as a "mode" of operation on `TaskGroup`. In line with that feedback, this proposal has moved to using the `discardResults` option.

### Error throwing behaviour

The pitch proposes that `ThrowingTaskGroup` with `discardResults` set to `true` will throw only the _first_ error thrown by a child `Task`. This means that all subsequent errors will be discarded, which is an unfortunate loss of information. Two alternative behaviours could be chosen: we could not add `discardResults` to `ThrowingTaskGroup` at all, or we could throw an aggregate error that contains all errors thrown by the child `Task`s.

Not allowing `discardResults` on `ThrowingTaskGroup` is a substantial ergonomic headache. Automatic error propagation is one of the great features of structured concurrency, and not being able to use it in servers or other long-running processes is an unnecessary limitation, especially as it's not particularly technically challenging to propagate errors. For this reason, we do not think it's wise to omit `discardResults` on `ThrowingTaskGroup`.

The other alternative is to throw an aggregate error. This would require that `ThrowingTaskGroup` persist all (or almost all) errors thrown by child tasks and merge them together into a single error `struct` that is thrown. This idea is a mixed bag.

The main advantage of throwing an aggregate error is that no information is lost. Programs can compute on all errors that were thrown, and at the very least can log or provide other metrics based on those errors. Avoiding data loss in this way is valuable, and gives programmers more flexibility.

Throwing an aggregate error has two principal disadvantages. The first is that aggregate errors do not behave gracefully in `catch` statements. If a child task has thrown `MyModuleError`, programmers would like to write `catch MyModuleError` in order to handle it. Aggregate errors break this situation, even if only one error is thrown: programmers have to write `catch let error = error as? MyAggregateError where error.baseErrors.contains(where: { $0 is MyModuleError })`, or something else equally painful.

The other main disadvantage is the storage bloat from `CancellationError`. The first thrown error will auto-cancel all child `Task`s. This is great, but that cancellation will likely manifest in a thrown `CancellationError`, which will presumably bubble to the top and be handled by the `ThrowingTaskGroup`. This means that a `ThrowingTaskGroup` will likely store a substantial collection of errors, where all but the first are `CancellationError`. This is a substantial regression in convenience for the mainline case, with additional costs in storage, without providing any more meaningful information.

For these reasons we've chosen the middle behaviour, where only one error is thrown. We think there is merit in throwing an aggregate error, however, and we'd like community feedback on this alternative.

### Child Task for reaping

An alternative would be to have Task Group spin up a child `Task` that can be used to consume tasks from the group. The API surface would look something like this:

```swift
withTaskGroupWithChildTask(of: Void.self) { group in
    group.addTask {
        handleConnection(newConnection)
    }
}
consumer: { group in
    for task in group { }
}
```

The advantage of this variant is that it is substantially more flexible, and allows non-`Void`-returning tasks. The downside of this variant is that it muddies the water on the question of whether Task Groups are `Sendable` (requiring a specific-exemption for this use-case) and forces users to understand the lifetime of a pair of different closures.

## Future Directions

### Error Handling

A number of concerns were raised during the pitch process that the "throw the first error only" pattern may be insufficiently flexible. Community members were particularly interested in having some sort of error filter function that could be used to filter, accumulate, or discard errors as needed.

The proposers feel that introducing this API surface in the first version of this feature adds significant complexity to this type. This requires us to be confident that the API surface proposed is going to serve the necessary use-cases, without adding unnecessary cognitive load. It's also not entirely clear where the line is between features that can be handled using `try`/`catch` and features that require a new error filter function.

As a result, the proposrs have elected to defer implementing anything here until there are real-world examples to generalise from. Having some sort of error filter is likely to be valuable, and the implementation will preserve the capability to implement such a function, but for now the proposal is going to be kept relatively small.