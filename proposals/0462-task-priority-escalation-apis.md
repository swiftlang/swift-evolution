# Task Priority Escalation APIs

* Proposal: [SE-0462](0462-task-priority-escalation-apis.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: [Freddy Kellison-Linn](https://github.com/jumhyn)
* Status: **Implemented (Swift 6.2)**
* Implementation: https://github.com/swiftlang/swift/pull/78625
* Review: ([pitch](https://forums.swift.org/t/pitch-task-priority-escalation-apis/77702)) ([review](https://forums.swift.org/t/se-0462-task-priority-escalation-apis/77997))([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0462-task-priority-escalation-apis/78488))

## Introduction

A large part of Swift Concurrency is its Structured Concurrency model, in which tasks automatically form parent-child relationships, and inherit certain traits from their parent task. For example, a task started from a medium priority task, also starts on the medium priority, and not only that – if the parent task gets awaited on from a higher priority task, the parent's as well as all of its child tasks' task priority will be escalated in order to avoid priority inversion problems.

This feature is automatic and works transparently for any structured task hierarchy. This proposal will discuss exposing user-facing APIs which can be used to participate in task priority escalation.

## Motivation

Generally developers can and should rely on the automatic task priority escalation happening transparently–at least for as long as all tasks necessary to escalate are created using structured concurrency primitives (task groups and `async let`). However, sometimes it is not possible to entirely avoid creating an unstructured task. 

One such example is the async sequence [`merge`](https://github.com/apple/swift-async-algorithms/blob/4c3ea81f81f0a25d0470188459c6d4bf20cf2f97/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Merge.md) operation from the [swift-async-algorithms](https://github.com/apple/swift-async-algorithms/) project where the implementation is forced to create an unstructured task for iterating the upstream sequences, which must outlive downstream calls. These libraries would like to participate in task priority escalation to boost the priority of the upstream consuming task, however today they lack the API to do so.

```swift
// SIMPLIFIED EXAMPLE CODE
// Complete source: https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/Merge/MergeStorage.swift

struct AsyncMergeSequenceIterator: AsyncIterator {
  struct State {
    var task: Task<Void, any Error>? // unstructured upstream consumer task
    var buffer: Deque<Element>
    var upstreamContinuations: [UnsafeContinuation<Void, Error>]
    var downstreamContinuation: UnsafeContinuation<Element?, Error>?
  }
  
  let state = Mutex<State>(State())
  
  func next() async throws {
    self.state.withLock { state in
      if state.task == nil {
        state.task = Task {
          // Consume from the base iterators
          // ... 
        }
      }
    }

    if let element = self.state.withLock { $0.buffer.popFirst() } {
      return element
    } else {
      // We are handling cancellation here and need to handle task escalation here as well
      try await withTaskCancellationHandler { 
        // HERE: need to handle priority escalation and boost `state.task`
        try await withCheckedContinuation { cont in
          self.state.withLock { $0.consumerContinuation = cont }
        }
      } onCancel: {
        // trigger cancellation of tasks and fail continuations
      }
    }
  }
}
```

The above example showcases a common pattern: often a continuation is paired with a Task used to complete it. Around the suspension on the continuation, waiting for it to be resumed, developers often install a task cancellation handler in order to potentially break out of potentially unbounded waiting for a continuation to be resumed. Around the same suspension (marked with `HERE` in the snippet above), we might want to insert a task priority escalation handler in order to priority boost the task that is used to resume the continuation. This can be important for correctness and performance of such operations, so we should find a way to offer these libraries a mechanism to participate in task priority handling.

Another example of libraries which may want to reach for manual task priority escalation APIs are libraries which facilitate communication across process boundaries, and would like to react to priority escalation and propagate it to a different process. Relying on the built-in priority escalation mechanisms won't work, because they are necessarily in-process, so libraries like this need to be able to participate and be notified when priority escalation happens, and also be able to efficiently cause the escalation inside the other process.

## Proposed solution

In order to address the above use-cases, we propose to add a pair of APIs: to react to priority escalation happening within a block of code, and an API to _cause_ a priority escalation without resorting to trickery by creating new tasks whose only purpose is to escalate the priority of some other task:

```swift
enum State {
  case initialized
  case task(Task<Void, Never>)
  case priority(TaskPriority)
}
let m: Mutex<State> = .init(.initialized) 

await withTaskPriorityEscalationHandler {
  await withCheckedContinuation { cc in
    let task = Task { cc.resume() }
    
    let newPriority: TaskPriority? = state.withLock { state -> TaskPriority? in
      defer { state = .task(task) }
      switch state {
      case .initialized:
          return nil
      case .task:
          preconditionFailure("unreachable")
      case .priority(let priority):
          return priority
      }
    }
    // priority was escalated just before we stored the task in the mutex
    if let newPriority {
        Task.escalatePriority(of: task, to: newPriority)
    }
  } onPriorityEscalated: { oldPriority, newPriority in
    state.withLock { state in
      switch state {
      case .initialized, .priority:
        // priority was escalated just before we managed to store the task in the mutex
        state = .priority(newPriority)
      case .task(let task):
        Task.escalatePriority(of: task, to: newPriority)
      }
    }
  }
}
```

The above snippet handles edge various ordering situations, including the task escalation happening after
the time the handler is registered but _before_ we managed to create and store the task.

In general, task escalation remains a slightly racy affair, we could always observe an escalation "too late" for it to matter,
and have any meaningful effect on the work's execution, however this API and associated patterns handle most situations which 
we care about in practice.

## Detailed design

We propose the addition of a task priority escalation handler, similar to task cancellation handlers already present in the concurrency library:

```swift
public func withTaskPriorityEscalationHandler<T, E>(
  operation: () async throws(E) -> T,
  onPriorityEscalated handler: @Sendable (TaskPriority, TaskPriority) -> Void,
  isolation: isolated (any Actor)? = #isolation
) async throws(E) -> T
```

The shape of this API is similar to the `withTaskCancellationHandler` API present since initial Swift Concurrency release, however–unlike a cancellation handler–the `onPriorityEscalated` callback may be triggered multiple times. There are two `TaskPriority` arguments passed to the handler. The first argument is the "old" priority, from before the task priority was escalated, and the second argument is the new escalated-to task priority.

It is guaranteed that priority is ever only increasing, as Swift Concurrency does not allow for a task priority to ever be lowered after it has been escalated. If attempts are made to escalate the task priority from multiple other threads to the same priority, the handler will only trigger once. However if priority is escalated to a high and then even higher priority, the handler may be invoked twice.

Task escalation handlers are inherently racy, and may sometimes miss an escalation, for example if it happened immediately before the handler was installed, like this:

```swift
// priority: low
// priority: high!
await withTaskPriorityEscalationHandler {
  await work()
} onPriorityEscalated: { oldPriority, newPriority in // may not be triggered if ->high escalation happened before handler was installed
  // do something
}
```

This is inherent to the nature of priority escalation and even with this behavior, we believe handlers are a worthy addition. One could also check for the `Task.currentPriority` and match it against our expectations inside the `operation` wrapped by the `withTaskPriorityEscalationHandler` if that could be useful to then perform the operation at an already _immediately_ heightened priority.

Escalation handlers work with any existing task kind (child, unstructured, unstructured detached), and trigger at every level of the hierarchy in an "outside in" order:

```swift
let t = Task {
  await withTaskPriorityEscalationHandler {
    await withTaskGroup { group in 
      group.addTask { 
        await withTaskPriorityEscalationHandler {
          try? await Task.sleep(for: .seconds(1))
        } onPriorityEscalated: { oldPriority, newPriority in print("inner: \(newPriority)") }
      }
    }
  } onPriorityEscalated: { oldPriority, newPriority in print("outer: \(newPriority)") }
}

// escalate t -> high
// "outer: high"
// "inner: high"
```

The API can also be freely composed with `withTaskCancellationHandler` or there may even be multiple task escalation handlers registered on the same task (but in different pieces of the code).

### Manually propagating priority escalation

While generally developers should not rely on manual task escalation handling, this API also does introduce a manual way to escalate a task's priority. Primarily this should be used in combination with a task escalation handler to _propagate_ an escalation to an _unstructured task_ which otherwise would miss reacting to the escalation.

The `escalatePriority(of:to:)` API is offered as a static method on `Task` in order to slightly hide it away from using it accidentally by stumbling upon it if it were directly declared as a member method of a Task.

```swift
extension Task {
  public static func escalatePriority(of task: Task, to newPriority: TaskPriority)
}

extension UnsafeCurrentTask {
  public static func escalatePriority(of task: UnsafeCurrentTask, to newPriority: TaskPriority)
}
```

It is possible to escalate both a `Task` and `UnsafeCurrentTask`, however great care must be taken to not attempt to escalate an unsafe task handle if the task has already been destroyed. The `Task` accepting API is always safe.

Currently it is not possible to escalate a specific child task (created by `async let` or a task group) because those do not return task handles. We are interested in exposing task handles to child tasks in the future, and this design could then be easily amended to gain API to support such child task handles as well.

## Source compatibility

This proposal is purely additive, and does not cause any source compatibility issues.

## ABI compatibility

This proposal is purely ABI additive.

## Alternatives considered

### New Continuation APIs

We did consider if offering a new kind of continuation might be easier to work with for developers. One shape this might take is:

```swift
struct State {
  var cc = CheckedContinuation<Void, any Error>?
  var task: Task<Void, any Error>?
}
let C: Mutex<State>

await withCheckedContinuation2 { cc in
  // ...
  C.withLock { $0.cc = cc }
    
  let t = Task { 
    C.withLock { 
      $0.cc?.resume() // maybe we'd need to add 'tryResume'
    }
  }
  C.withLock { $0.task = t }
} onCancel: { cc in
  // remember the cc can only be resumed once; we'd need to offer 'tryResume'
  cc.resume(throwing: CancellationError()) 
} onPriorityEscalated: { cc, newPriority in
  print("new priority: \(newPriority)")
  C.withLock { Task.escalatePriority(of: $0.task, to: newPriority) }
}
```

While at first this looks promising, we did not really remove much of the complexity -- careful locking is still necessary, and passing the continuation into the closures only makes it more error prone than not since it has become easier to accidentally multi-resume a continuation. This also does not compose well, and would only be offered around continuations, even if not all use-cases must necessarily suspend on a continuation to benefit from the priority escalation handling.

Overall, this seems like a tightly knit API that changes current idioms of `with...Handler ` without really saving us from the inherent complexity of these handlers being invoked concurrently, and limiting the usefulness of those handlers to just "around a continuation" which may not always be the case.

### Acknowledgements 

I'd like to thank John McCall, David Nadoba for their input on the APIs during early reviews.
