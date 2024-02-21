# Custom isolation checking for SerialExecutor

* Proposal: [SE-NNNN](NNNN-advanced-custom-isolation-checking-for-serialexecutor.md)
* Author: [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: ???
* Status:  **Work in Progress**
* Implementation: [PR #71172](https://github.com/apple/swift/pull/71172)
* Review: ???

## Introduction

[SE-0392 (Custom Actor Executors)](https://github.com/apple/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md) added support for custom actor executors, but its support is incomplete. Safety checks like [`Actor.assumeIsolated`](https://developer.apple.com/documentation/swift/actor/assumeisolated(_:file:line:)) work correctly when code is running on the actor through a task, but they don't work when code is scheduled to run on the actor's executor through some other mechanism. For example, if an actor uses a serial `DispatchQueue` as its executor, a function dispatched _directly_ to the queue with DispatchQueue.async cannot use `assumeIsolated` to assert that the actor is currently isolated. This proposal fixes this by allowing custom actor executors to provide their own logic for these safety checks.

## Motivation

The Swift concurrency runtime already provides means of dynamically tracking and checking the tasks's current executor, and APIs like `assertIsolated` and `assumeIsolated` are built on top of that functionality.

In those APIs the expected executor is compared with the "current" executor of a current task which is tracked by the runtime. If the code calling the comparison logic is not running within a Swift concurrency task, the comparison fails, as there are no two executors that can be compared.

This logic is not sufficient to be able to handle the situation in which code is runnin on the correct queue or thread, and mutual exclusion is properly ensured, however, the calling code is not being called from a task and therefore the check fails unexpectedly. The following example demonstrates such situation:

```swift
import Dispatch

actor Caplin {
  let queue: DispatchSerialQueue(label: "CoolQueue")

  var num: Int // actor isolated state

  // use the queue as this actor's `SerialExecutor`
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }
  
  nonisolated func connect() {
    queue.async {
      // guaranteed to execute on `queue`
      // which is the same as self's serial executor
      queue.assertIsolated() // CRASH: Incorrect actor executor assumption
      self.assumeIsolated {  // CRASH: Incorrect actor executor assumption
        num += 1
      }
    }
  }
}
```

Even though the code is executing on the correct Dispatch**Serial**Queue, the assertions trigger and we're left unable to access the actor's state, even though isolation wise it would be safe and correct to do so.

This use-case is common and important enough, that the runtime actually has special cased the MainActor's isolation checking handling. A fallback check exists, which is used when the target executor is the MainActors', and the current code is not running within a task, however it is running on the *main thread*. The Swift runtime handles this special case already, however, the same problem exists for all kinds of threads which may be used as actor executors. Specifically, the problem becomes quite common when the use of `SerialDispatchQueues` as actor executors becomes prevalent, in projects migrating their pre-concurrency code-bases towards the use of actors and swift concurrency.

Therefore, this proposal extends this "fallback" check mechanism to all SerialExecutors, rather than keeping it specialized to the MainActor.

## Proposed solution

We propose to add an additional last-resort mechanism to executor comparison, to be used ty the above mentioned APIs.

This will be done by providing a new `checkIsolation()` protocol requirement on `SerialExecutor`:

```swift
protocol SerialExecutor: Executor {
  // ...
 
  /// Invoked as last-resort when the swift concurrency runtime is performing an isolation
  /// assertion, and could not confirm that the current execution context belongs to this
  /// "expected" executor.
  ///
  /// This function MUST crash the program with a fatal error if it is unable 
  /// to prove that the calling context can be safely assumed to be the same isolation 
  /// context as represented by this ``SerialExecutor``.
  ///
  /// A default implementation is provided that unconditionally causes a fatal error.
  func checkIsolation()
}

extension SerialExecutor {
  public func checkIsolation() {
    fatalError("Incorrect actor executor assumption, expected: \(self)")
  }
}
```

## Detailed design

This proposal adds another customization point to the Swift concurrency runtime that hooks into isolation context comparison mechanisms used by `assertIsolated`, `preconditionIsolated`, `assumeIsolated` as well as implicitly injected assertions used in `@preconcurrency` code.

### Extended executor comparison mechanism

With this proposal, the logic for checking if the "current" executor is the same as the "expected" executor changes becomes as follows:

- obtain current executor
  - if no current executor exists, ​​use heurystics to detect the "main actor" executor 
    - These heurystics could be removed by using this proposal's `checkIsolation()` API, however we'll first need to expose the MainActor's SerialExecutor as a global property which this proposal does not cover. Please see **Future Directions** for more discussion of this topic.
  - if a current executor exists, perform basic object comparison between them
- if unable to prove the executors are equal:
  - compare the executors using "complex equality" (see [SE-0392: Custom Actor Executors](https://github.com/apple/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md) for a detailed description of complex exector equality)
- if still unable to prove the executors are equal:
  - :arrow_right: call the expected executor's `checkIsolation()` method

The last step of this used to be just to unconditionally fail the comparison, leaving no space for an executor to take over and use whatever it's own tracking -- usually expressed using thread-locals the executor sets as it creates its own worker thread -- to actually save the comparison from failing.

Specific use-cases of this API include `DispatchSerialQueue`, which would be able to implement the requirement as follows:

```swift
// Dispatch 

extension DispatchSerialQueue { 
  public func checkIsolated(message: String) {
    dispatchPrecondition(condition: .onQueue(self)) // existing Dispatch API
  }
}
```

Other executors would have the same capability, if they used some mechanisms to identify their own worker threads.

### Impact on async code and isolation assumtions

The `assumeIsolated(_:file:line:)` APIs purposefully only accept a **synchronous** closure. This is correct, and with the here proposed additions, it remains correct -- we may be executing NOT inside a Task, however we may be isolated and can safely access actor state. 

This means that the following code snippet, while a bit unusual remains correct isolation-wise:

```swift
actor Worker {
  var number: Int 
  
  nonisolated func canOnlyCallMeWhileIsolatedOnThisInstance() -> Int {
    self.preconditionIsolated("This method must be called while isolated to \(self)")

    return self.assumeIsolated { // () throws -> Int
      // suspensions are not allowed in this closure.
      
      self.number // we are guaranteed to be isolated on this actor; read is safe
    }
  }
      
```

As such, there is no negative impact on the correctness of these APIs.

## Future directions

### Introduce `globalMainExecutor` global property and utilize `checkIsolated` on it

This proposal also paves the way to clean up this hard-coded aspect of the runtime, and it would be possible to change these heurystics to instead invoke the `checkIsolation()` method on a "main actor executor" SerialExecutor reference if it were available.

This proposal does not introduce a `globalMainActorExecutor`, however, similar how how [SE-0417: Task ExecutorPreference](https://github.com/apple/swift-evolution/blob/main/proposals/0417-task-executor-preference.md) introduced a:

```swift
nonisolated(unsafe)
public var globalConcurrentExecutor: any TaskExecutor { get }
```

the same could be done to the MainActor's executor:

```swift
nonisolated(unsafe)
public var globalMainExecutor: any SerialExecutor { get }
```

The custom heurystics that are today part of the Swift Concurrency runtime to detect the "main thread" and "main actor executor", could instead be delegated to this global property, and function correctly even if the MainActor's executor is NOT using the main thread (which can happen on some platforms):

```swift
// concurrency runtime pseudo-code
if expectedExecutor.isMainActor() {
  expectedExecutor.checkIsolated(message: message)
}
```

This would allow the isolation model to support different kinds of main executor and properly assert their isolation, using custom logic, rather than hardcoding the main thread assumptions into the Swift runtime.

## Alternatives considered

### Do not provide customization points, and just hardcode DispatchQueue handling

Alternatively, we could harcode detecting dispatch queues and triggering `dispatchPrecondition` from within the Swift runtime.

This is not a good direction though, as our goal is to have the concurrency runtime be less attached to Dispatch and allow Swift to handle each and every execution environment equally well. As such, introducing necessary hooks as official and public API is the way to go here.


## Revisions
- 1.0
  - initial revision
