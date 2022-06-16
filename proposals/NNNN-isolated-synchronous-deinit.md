# Isolated synchronous deinit

* Proposal: [SE-NNNN](NNNN-isolated-synchronous-deinit.md)
* Authors: [Mykola Pokhylets](https://github.com/nickolas-pohilets)
* Review Manager: TBD
* Status: **WIP**

## Introduction

This feature lifts restrictions on `deinit` of actors and GAITs imposed by [SE-0327](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md) by providing runtime support for hopping onto executors in `__deallocating_deinit()`'s.

## Motivation

Combination of automatics reference counting and deterministic deinitialization makes `deinit` in Swift a powerful tool for resource management. It greatly reduces need for `close()`-like methods (`unsubscribe()`, `cancel()`, `shutdown()`, etc.) in the public API. Such methods not only clutter public API, but also introduce a state where object is already unusable but is still referencable.

Restrictions imposed by [SE-0327](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md) reduce usefullness of explicit `deinit`s in actors and GAITs. Workarounds for these limitations may involve creation of `close()`-like methods, or even manual reference counting, if API should be able to serve several clients.

In cases when `deinit` belongs to a subclass of `UIView` or `UIViewController` which are known to call deinitializer on the main thread, developers may be tempted to silence the diagnostic by adopting `@unchecked Sendable` in types that are not actually  sendable. This undermines concurrency checking by the compiler, and may lead to data races when using incorrectly marked types in other places.

## Proposed solution

... is to allow execution of `deinit` and object deallocation to be the scheduled on the executor, if needed.

Let's consider [examples from SE-0327](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md#data-races-in-deinitializers):

In case of several instances with shared data isolated on common actor problem is completely eliminated:

```swift
class NonSendableAhmed { 
  var state: Int = 0
}

@MainActor
class Maria {
  let friend: NonSendableAhmed

  init() {
    self.friend = NonSendableAhmed()
  }

  init(sharingFriendOf otherMaria: Maria) {
    // While the friend is non-Sendable, this initializer and
    // and the otherMaria are isolated to the MainActor. That is,
    // they share the same executor. So, it's OK for the non-Sendable value
    // to cross between otherMaria and self.
    self.friend = otherMaria.friend
  }

  deinit {
    // Used to be a potential data race.
    // Now deinit is also isolated on the MainActor.
    // So this code is perfectly correct.
    friend.state += 1
  }
}

func example() async {
  let m1 = await Maria()
  let m2 = await Maria(sharingFriendOf: m1)
  doSomething(m1, m2)
} 
```

In case of escaping self, race condition is eliminated but problem of escaping `self` remains. This problem exists for synchronous code as well and is orthogonal to the concurrency features.

```swift
actor Clicker {
  var count: Int = 0

  func click(_ times: Int) {
    for _ in 0..<times {
      self.count += 1 
    }
  }

  deinit {
    let old = count
    let moreClicks = 10000
    
    Task { await self.click(moreClicks) } // ❌ This WILL keep `self` alive after the `deinit`!

    for _ in 0..<moreClicks {
        // No data race.
        // Actor job created by the task is either
        // not created yet or is waiting in the queue.
      self.count += 1 
    }

    assert(count == old + moreClicks) // Always works
    assert(count == old + 2 * moreClicks) // Always fails
  }
}
```

## Detailed design

### Runtime

Proposal introduces new runtime function that is used to schedule task-less block of synchronous code on the executor by wrapping it into an ad hoc task. If no switching is needed, block is executed immediately on the current thread. It does not do any reference counting and can be safely used even with references that were released for the last time but not deallocated yet.

```cpp
using AdHocWorkFunction = SWIFT_CC(swift) void (void *);
  
SWIFT_EXPORT_FROM(swift_Concurrency) SWIFT_CC(swift)
void swift_task_performOnExecutor(void *context, AdHocWorkFunction *work, ExecutorRef newExecutor);
```

```swift
@_silgen_name("swift_task_performOnExecutor")
@usableFromInline
internal func _performOnExecutor(_ ctx: __owned AnyObject,
                               _ work: @convention(thin) (__owned AnyObject) -> Void,
                               _ executor: UnownedSerialExecutor)
```

If `deinit` is isolated, code that normally is emitted into `__deallocating_init` gets emitted into new entity - `__isolated_deallocating_init`. And `__deallocating_init` is emitted as a thunk that reads executor from `self` (for actors) or global actor (for GAITs) and calls `swift_task_performOnExecutor` passing `self`, `__isolated_deallocating_init` and desired executor.

![Last release from background thread](https://aws1.discourse-cdn.com/swift/original/3X/a/0/a06988cfffdacaef2387da035789f965c2345c5b.png)

![Dealloc on main thread](https://aws1.discourse-cdn.com/swift/original/3X/d/8/d8098cdc104b2c87072d63a22060106c4dc5b4e7.png)

Non-deallocting deinit is not affected by the changes.

### Rules for computing isolation

Isolation of deinit comes with runtime and code size cost. Classes that don't perform custom actions in deinit and only need to release references don't need isolated deinit. Releasing child objects can be done from any thread. If those objects are concerned about isolation, they should adopt isolation themselves.

```swift
@MainActor
class Foo {
    let bar: Bar
    
    // No isolated deinit generated.
    // Reference to Bar can be released from any thread.
    // Class Bar is responsible for correctly isolating its own deinit.
}

actor MyActor {
    let bar: Bar
    
    // Similar
}
```

If there is explicit `deinit`, then isolation is computed following usual rules for isolation of class instance members. It takes into account isolation attributes on the parent class, deinit itself, and allows `nonisolated` keyword to be used to supress isolation of the parent class:

```swift
@MainActor
class Foo {
    deinit {} // Isolated on MainActor
}

@FirstActor
class Bar {
    @SecondActor
    deinit {} // Isolated on SecondActor
}

@MainActor
class Baz {
    nonisolated deinit {} // Not isolated
}

actor MyActor {
    deinit {} // Isolated on self
}

actor AnotherActor {
    nonisolated deinit {} // Not isolated
}
```

When inheritance is involved, classes can add isolation to the non-isolated `deinit` of the base class, but they cannot change (remove or change actor) existing isolation.

```swift
@FirstActor
class Base {} // deinit is not isolated

class Derived: Base {
    @SecondActor deinit { // Isolated on SecondActor
    }
}

class IsolatedBase {
    @FirstActor deinit {} // Isolated on FirstActor
}

class Derived1: IsolatedBase {
    // deinit is still isolated on FirstActor
}

class Derived2: IsolatedBase {
    nonisolated deinit {} // ERROR
}

class Derived3: IsolatedBase {
    @SecondActor deinit {} // ERROR
}
```

## Source compatibility

Proposal makes previously invalid code valid.

## Effect on ABI stability

Proposal does not change ABI of the existing language features, but introduces new runtime function.

## Effect on API resilience

Isolation attributes of the `deinit` become part of the public API, but it matters only when inheriting from the class.

Changing deinitializer from nonisolated to isolated is allowed on final classes. But for non-final classes it may effect how deinitializers of the subclasses are generated.

The same is true for changing identity of the isolating actor.

Changing deinitializer from isolated to nonisolated does not break ABI. Any unmodified subclasses will keep calling `deinit` of the superclass on the original actor.

## Future Directions

### Managing priority of the deinitialization job 

Currently job created for the isolated `deinit` inherits priority of the task/thread that performed last release. If there are references from different tasks/threads, value of this priority is racy. It is impossible to reason about which tasks/threads can reference the object based on local analysis, especially since object can be referenced by other objects. Ideally deinitialization should happen with a predictable priority. Such priority could be set using attributes on the deinitializer or be provided by the isolating actor.

### Clearing task local values

Current implementation preserves task local values if last release happened on the desired executor, or runs deinitializer without any task local values. Ideally deinitialization should happen with a predictable state of task local values. This could be achieved by blocking task-local values even if deinitializer is immediately executed. This could implemented as adding a node that stops lookup of the task-local values into the linked list.

### Asynchronous `deinit`

Similar approach can be used to start a detached task for executing `async` deinit, but this is out of scope of this proposal.

## Alternatives considered

### Placing hopping logic in `swift_release()` instead.

`UIView` and `UIViewController` implement hopping to the main thread by overriding `release` method. But in Swift there are no vtable/wvtable slots for releasing, and adding them would also affect a lot of code that does not need isolated deinit.
