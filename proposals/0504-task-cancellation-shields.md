# Task Cancellation Shields

* Proposal: [SE-0504](0504-task-cancellation-shields.md)
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Active review (January 12...26, 2026)**
* Implementation: [PR #85637](https://github.com/swiftlang/swift/pull/85637)
* Review: ([pitch](https://forums.swift.org/t/pitch-task-cancellation-shields/83379)) ([review](https://forums.swift.org/t/se-0504-task-cancellation-shields/84095))

## Introduction

This proposal introduces a new mechanism to temporarily "ignore" task cancellation, called task cancellation shields.

This can be used to ensure certain pieces of code will execute regardless of the task's cancelled status. A common situation where this is useful is running clean-up code, which must execute regardless of a task's cancellation status.

This proposal dovetails nicely with asynchronous defer statements which were recently introduced in [SE-0493: Support `async` calls in `defer` bodies](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0493-defer-async.md), which are frequently used to express such resource clean-up functionality.

## Motivation

Task cancellation is _final_ and can not be ignored or undone. Once a task has been cancelled, it remains cancelled for the rest of its existence. 

Child tasks are also affected by task cancellation, and cancellation propagates throughout the entire task tree, allowing for efficient and holistic cancelling of entire hierarchies of work, represented as a tree of child tasks.

Today, there is no great way to ignore cancellation, and some pieces of code may therefore by accident not execute to completion. This is especially problematic in clean-up or resource tear-down, where a tear-down method's implementation details might be checking for cancellation, however, we _must_ have this code execute, regardless of the task's cancellation status to properly cleanup some resource, like this:

```swift
extension Resource { 
  func cleanup() { // our "cleanup" implementation looks correct...
    system.performAction(CleanupAction())
  }
}

extension SomeSystem { 
  func performAction(_ action: some SomeAction) { 
    guard !Task.isCancelled else {
      // oh no! 
      // If Resource.cleanup calls this while being in a cancelled task,
      // the action would never be performed!
      return 
    }
    // ... 
  }
}
```

In the above example, while the resource clean-up may be implemented correctly, the caller could be unaware that such code may short-circuit if the current task is cancelled. In order for the caller to influence this behavior, it must somehow be able to "shield" the cleanup code from observing the current task's cancellation state.

Today, developers work around this problem by creating unstructured tasks, which creates unnecessary scheduling and may have a performance and even correctness impact on such cleanup code:

```swift
// WORKAROUND, before cancellation shields were introduced
func example() async {
  let resource = makeResource()

  await Task {
    assert(!Task.isCancelled)
    await resource.cleanup()
  }.value // break out of task tree, in order to prevent cleanup from observing cancellation
}
```

This is sub-optimal for a few reasons:

- We are introducing an unstructured task which needs to be scheduled to execute, and therefore delaying the timing when a cleanup may be executed.
- It is not possible to use this pattern in a synchronous function, as we need to await the unstructured task.

Task cancellation shields directly resolve these problems.

## Proposed solution

We propose the introduction of a `withTaskCancellationShield` method which temporarily prevents code from **observing** the cancellation status, and thus allowing code to execute as-if the surrounding task was not cancelled:

```swift
public func withTaskCancellationShield<Value, Failure>(
  _ operation: () throws(Failure) -> Value,
  file: String = #fileID, line: Int = #line
) throws(Failure) -> Value

public nonisolated(nonsending) func withTaskCancellationShield<Value, Failure>(
  _ operation: nonisolated(nonsending) () async throws(Failure) -> Value,
  file: String = #fileID, line: Int = #line
) async throws(Failure) -> T
```

Shields also prevent the automatic propagation of cancellation into child tasks, including `async let` and task groups. 

They do not prevent a task from being cancelled, however, they affect the observation of the cancelled status while executing in a "shielded" piece of code. This is best explained with an example:

```swift 
print(Task.isCancelled) // true
withTaskCancellationShield { 
  print(Task.isCancelled) // false
}
print(Task.isCancelled) // true
```

### Cancellation Shields and Child Tasks

Cancellation shielding also prevents the automatic propagation of the cancellation through the task tree. 

Specifically, if a structured child task is created within a task cancellation shield block and the outer task is cancelled, the outer task will be cancelled. However, we will not observe this flag change until we exit the cancellation shield. At the same time, the child tasks which are running within the task cancellation shield will not become cancelled automatically, as would be otherwise the case:

```swift
Task {
  withUnsafeCurrentTask { $0?.cancel() } // immediately cancel the Task
  
  // without shields:
  async let a = compute() // 🛑 async let child task is immediately cancelled
  await withDiscardingTaskGroup { group in // 🛑 task group is immediately cancelled
    group.addTask { compute() }  // 🛑 child task is immediately cancelled
    group.addTaskUnlessCancelled { compute() }  // 🛑 child task is not started at all
  }
  
  // with shields:
  await withTaskCancellationShield { 
    async let a = compute() // 🟢 async let child task is NOT cancelled immediately
    await withDiscardingTaskGroup { group in // 🟢 not cancelled
      group.addTask { compute() } // 🟢 not cancelled
      group.addTaskUnlessCancelled { compute() } // 🟢 not cancelled
    }
  }
}
```

However if a child task (or entire task group) were to be cancelled explicitly, the shield of the parent task has no effect, as it only shields from "incoming" cancellation from the outer scope and not the child task's own status.

```swift
await withTaskCancellationShield {
  async let a = compute() // when exiting scope, un-awaited async lets will still be cancelled and awaited
  await withDiscardingTaskGroup { group in 
    group.addTask { ... }
    group.cancelAll() // cancels all tasks within the group, as expected
  }
}
```

It is meaningless to try to shield the `addTask` operation of a task group as it does not enclose the lifetime or any part of the child task's execution. Instead you should shield the child task within the `addTask` function if shielding a specific task is your goal:

```swift
await withDiscardingTaskGroup { group in 
  // ❌ has no effect on child task observing cancellation:
  withTaskCancellationShield { 
    group.addTask { ... } 
  } 
  
  
  // 🟢 does properly shield specific child task observing cancellation:
  group.addTask { 
    withTaskCancellationShield { ... }
  } 
}
```

All examples shown using `isCancelled` behave exactly the same for `Task.checkCancellation`, i.e. whenever `isCancelled` would be true, the `checkCancelled` API would throw a `CancellationError`.

### Cancellation Shields and Cancellation Handlers

Swift concurrency offers task cancellation handlers which are invoked immediately when a task is cancelled. This allows you to dynamically react to cancellation happening without explicitly checking the `isCancelled` property of a task. 

Task cancellation shields also prevent cancellation handlers from firing if the handler was stored while a shield was active. Again, this does not extend to child tasks, but only to the current task that is being shielded. 

For example, the task cancellation shield installed around the `slowOperation` in the snippet below, would effectively prevent the cancellation handler inside the `slowOperation` function from ever triggering:

```swift
func slowOperation() -> ComputationResult {
  await withTaskCancellationHandler { 
    return < ... slow operation ... >
  } onCancel: {
    print("Let's cancel the slow operation!")
  }
}

func cleanup() {
  withTaskCancellationShield {
    slowOperation()
  }
}
```

### Cancellation Shields and Task handles

Unstructured tasks, as well as the use of `withUnsafeCurrentTask`, offer a way to obtain a task handle which may be interacted with outside of the task.

For example, you may obtain a task handle for an unstructured task, which then immediately enters a task cancellation shield scope:

```swift
let task = Task { 
  Task.isCancelled // true
  withTaskCancellationShield { 
    Task.isCancelled // false
  }
  Task.isCancelled // true
}

task.cancel()
print(task.isCancelled) // _always_ true
```

The instance method `task.isCancelled` queried from the outside of the task will return the _actual_ cancelled state, regardless if the task is right now executing a section of code under a cancellation shield or not. This is because from the outside it would be racy to query the cancellation state and rely on wether or not the task is currently executing a section of code under a shield. This could lead to confusing behavior where querying the same `task.isCancelled` could be flip flopping between cancelled and not cancelled.

The static method `Task.isCancelled` always reports the cancelled status of "this context" and thus respects the structure of the program with regards to nesting in `withTaskCancellationShield { ... }` blocks. This static method was, and remains, the primary way tasks interact with cancellation.

We believe these semantics are the right, understandable, and consistent choice of behavior:

- **static methods** observe the cancellation status "in this context", and thus, respect task cancellation shields,
  - This includes the: `Task.isCancelled`, `Task.checkCancellation` and `withTaskCancellationHandler` methods.
- **instance methods** on `Task` (and `UnsafeCurrentTask` discussed next) observe the actual cancellation state, ignoring any task cancellation shields because they are not called "in a scope" but just called on a specific task handle.
  - These methods are called rarely, and are only accessible on the "current" task through APIs on the `UnsafeCurrentTask`.


### Debugging and Observing Task Cancellation Shields

While it isn't common to explicitly cancel the current task your code is executing in, it is possible and may lead to slightly unexpected behaviors which nevertheless are correct. For example, if attempting to cancel the current task while it is running under a cancellation shield, that cancellation would not be able to be observed, even in the next line just after triggering the "current task" cancellation:

```swift
withTaskCancellationShield { 
  // ...
  withUnsafeCurentTask { $0?.cancel() }
  assert(Task.isCancelled == false) // Even though we just cancelled, we're not observing the cancellation
}
```

While this code pattern is not really often encountered in real-world code, it could confuse developers unaware of task cancellation shields, especially in deep call hierarchies.

In order to aid understanding and debuggability of cancellation in such systems, we also introduce a new property to query for a cancellation shield being active in a specific task.

This API is not intended to be used in "normal" code, and should only be used during debugging issues with cancellation, to check if a shield is active in a given task. This API is _only_ available on `UnsafeCurrentTask`, in order to dissuade from its use in normal code.

The `hasActiveTaskCancellationShield` property, which can be used to determine if a cancellation shield is active. Primarily this can be used for debugging "why isn't my task getting cancelled?" kinds of issues.

```swift
extension UnsafeCurrentTask {
  public static var hasActiveTaskCancellationShield: Bool { get }
}
```

Here is an example, how `UnsafeCurrentTask`'s  `isCancelled` as well as the new `hasActiveTaskCancellationShield` behave inside of a cancelled, but shielded task. The instance method `UnsafeCurrentTask/isCancelled` behaves the same way as the `Task/isCancelled` method, which was discussed above. However, using the unsafe task handle, we are able to react to task cancellation shields if necessary:

```swift
let task = Task { 
  Task.isCancelled // true
  
  withTaskCancellationShield { 
    Task.isCancelled // false
    
    withUnsafeCurrentTask { unsafeTask in 
      unsafeTask.isCancelled // true
      unsafeTask.hasTaskCancellationShield // true
                           
      // can replicate respecting shield if necessary (racy by definition, if this was queried from outside)
      let isCancelledRespectingShield = 
        if unsafeTask.hasTaskCancellationShield { false }
        else { unsafeTask.isCancelled }
    }
  }
}

task.cancel()
print(task.isCancelled) // true
```

It is also important to remember that a task cancellation shield does _not_ interract with any other task than the current one, so e.g. querying cancellation of a task handle, while executing in a task shield block has no effect on that query:

```swift
let task = Task { }

task.cancel()
task.isCancelled // true
withTaskCancellationShield { 
  task.isCancelled // true, the shield has no interaction with other tasks, just the "current" one
}
```

### Modifying the `isCancelled` behavior contract

Previously, the static `Task.isCancelled` property declared on Task was documented as:

```swift
  /// After the value of this property becomes `true`, it remains `true` indefinitely.
  /// There is no way to uncancel a task.
```

With cancellation shields, this wording may be slightly confusing. It is true that cancellation is terminal and cannot be "undone", however this proposal does allow an `isCancelled` on a task that previously returned `true` to return `false`, if and only if, that task has now entered a task cancellation shield scope:

```swift
Task.isCancelled // true
withTaskCancellationShield { 
    Task.isCancelled // false
}
Task.isCancelled // true
```

Therefore the API documentation will be changed to reflect this change:

```swift
/// ... 
/// A task's cancellation is final and cannot be undone.
/// However, it is possible to cause the `isCancelled` property to return `false` even 
/// if the task was previously cancelled by entering a ``withTaskCancellationShield(_:)`` scope.
/// ...
public var isCancelled: Bool {

```

The instance method `task.isCancelled` retains its existing behavior.

### Compatibility with defer

While there isn't anything special with regards to defer blocks and cancellation shields, it is worth calling out that they are intended to often be used in tandem. Since defer statements are often used to ensure some cleanup or shutdown logic gets executed when a function exits, cancellation shields inside the defer blocks are a natural fit:

```swift
let resource = makeResource()

defer { 
  await withCancellationShield { // ensure that cleanup always runs, regardless of cancellation
    await resource.cleanup()
  }
}
```

## Source compatibility

This proposal is purely additive.

## ABI compatibility

This proposal is purely additive.

## Implications on adoption

Since this feature requires a number of runtime changes, it will not be available in back-deployment.

## Alternatives considered

### Do nothing

Doing nothing is always an option, and we suggest developers have to keep using the unstructured task workaround. 

This doesn't seem viable though as the problem indeed is real, and the workaround is problematic scheduling wise, and may not even be usable in certain situations.

### Naming the feature "ignore cancellation" or similar

During the pitch a variety of name alternatives for this feature were proposed. Among them were "`ignoringCancellation { ... }`", or "`suppressingCancellation{ ... }`".

We discussed these and believe it is _more_ confusing to introduce a descriptive name for this feature because the descriptions never _quite_ capture the actual feature's behavior, and would give a false sense of understanding without looking up API docs and/or extended documentation explaining the behavior.

Specifically, this feature does _not_ ignore cancellation, it only prevents observing it while within the scope of a shield within a task.

## Acknowledgments

The term cancellation "shield" was originally coined in the Trio concurrency project, and we think the term is quite suitable and well-fitting to Swift as well.
