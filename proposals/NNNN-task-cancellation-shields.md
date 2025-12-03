# Task Cancellation Shields

* Proposal: [SE-NNNN](NNNN-task-cancellation-shields.md)
* Authors: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TODO
* Status: TODO
* Implementation: [PR #85637](https://github.com/swiftlang/swift/pull/85637)
* Review: 
  * TODO

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
    guard Task.isCancelled else {
      // oh no! 
      // If Resource.cleanup calls this while being in a cancelled task,
      // the action would never be performed!
      return 
    }
    // ... 
  }
}
```

In the above example, while we may have implemented the resource clean-up correctly, we may be unaware of the system only performing actions while the task it is executing in is not cancelled. In order to ensure certain actions execute regardless if called from a cancelled or not cancelled task, we're going to have to "shield" the cleanup code from observing the cancellation status of the calling task.

Today, developers work around this problem by creating unstructured tasks, which creates unnecessary scheduling and may have a performance and even correctness impact on such cleanup code:

```swift
// WORKAROUND, before cancellation shields were introduced
func example() async {
  let resource = makeResource()
  
  assert(Task.isCancelled())
  await Task {
    assert(!Task.isCancelled())
    await resource.cleanup() 
  }.value // break out of task tree, in order to ignore cancellation
}
```

This is sub-optimal for a few reasons:

- We are introducing an unstructured task which needs to be scheduled to execute, and therefore delaying the timing when a cleanup may be executed,
- It is not possible to use this pattern in a synchronous function, as we need to await the unstructured task.

Task cancellation shields directly resolve these problems.

## Proposed solution

We propose the introduction of a `withTaskCancellationShield` method which temporarily prevents code from **observing** the cancellation status, and thus allowing code to execute as-if the surrounding task was not cancelled:

```swift
public func withTaskCancellationShield<T, E>(
  _ operation: () throws(E) -> T,
  file: String = #fileID, line: Int = #line
) throws(E) -> T

public nonisolated(nonsending) func withTaskCancellationShield<T, E>(
  _ operation: nonisolated(nonsending) () async throws(E) -> T, // FIXME: order of attrs
  file: String = #fileID, line: Int = #line
) async throws(E) -> T
```

Shields also prevent the automatic propagation of cancellation into child tasks, including `async let` and task groups. 

They do not prevent a task from being cancelled, however, they affect the observation of the cancelled status while executing in a "shielded" piece of code. This is best explained with an example:

```swift 
assert(Task.isCancelled) // 🛑
withTaskCancellationShield { 
  assert(Task.isCancelled == false) // 🟢
}
assert(Task.isCancelled) // 🛑
```

### Cancellation Shields and Child Tasks

Cancellation shielding also prevents the automatic propagation of the cancellation through the task tree. 

Specifically, if a structured child task is created within a task cancellation shield block and the outer task is canceled, the outer task will be canceled. However, we will not observe this flag change until we exit the cancellation shield. At the same time, the child tasks which are running within the task cancellation shield will not become canceled automatically, as would be otherwise the case:

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

However if a child task were to be cancelled explicitly the shield of the parent, has no effect on the child itself becoming cancelled:

```swift
await withTaskCancellationShield {
  await withDiscardingTaskGroup { group in 
    group.addTask { ... }
    group.cancelAll() // cancels all tasks within the group, as expected
  }
}
```

It is meaningless to try to shield the `addTask` operation of a task group as it does not enclose the lifetime or any part of the child tasks execution. Instead you should shield the child task within the `addTask` function if shielding a specific task is your goal:

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
    
  }
}
```

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

In order to aid understanding and debuggability of cancellation in such systems, we also introduce two new query functions: 

First, the `isTaskCancellationShielded` static property, which can be used to determine if a cancellation shield is active. Primarily this can be used for debugging "why isn't my task getting cancelled?" kinds of issues.

```swift
extension Task where Success == Never, Failure == Never {
  public static var isTaskCancellationShielded: Bool { get }
  // TODO: or hasActiveTaskCancellationShield ???
}

extension UnsafeCurrentTask where Success == Never, Failure == Never {
  public var isTaskCancellationShielded: Bool { get }
}
```

As well as, a version of `isCancelled()` which allows ignoring the cancellation shield:

```swift
extension Task where Success == Never, Failure == Never {
  public static func isCancelled(ignoringCancellationShield: Bool) -> Bool
}
extension UnsafeCurrentTask where Success == Never, Failure == Never {
  public func isCancelled(ignoringCancellationShield: Bool) -> Bool
}
```

This overload should not really be used by normal code trying to act on cancellation, and we believe the long name should indicate as much, as will the documentation on those methods. However, we believe offering it is may be beneficial for certain code paths which can benefit from seeing the whole picture, and/or software logging and reporting statuses of tasks etc.

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

## Acknowledgments

The term cancellation "shield" was originally coined in the Trio concurrency project, and we think the term is quite suitable and well-fitting to Swift as well.
