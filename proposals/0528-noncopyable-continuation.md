# `Continuation` — Safe and Performant Async Continuations

* Proposal: [SE-0528](0528-noncopyable-continuation.md)
* Authors: [Fabian Fett](https://github.com/fabianfett), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Active Review (April 15...28, 2026)** 
* Implementation: [swiftlang/swift#88182](https://github.com/swiftlang/swift/pull/88182)
* Related Proposals: 
    - [SE-0300: Continuations for interfacing async tasks with synchronous code](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0300-continuation.md)
    - [SE-0390: Noncopyable structs and enums](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md)
    - [SE-0413: Typed throws](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-rigidarray-and-uniquearray/85455))
    ([review](https://forums.swift.org/t/se-0528-non-copyable-continuation/86055))

## Summary

We propose `Continuation<Success, Failure>`, a noncopyable continuation type that makes double-resume a compile-time error and missing-resume a guaranteed runtime trap, with no allocations and no atomic operations on the fast path. By leveraging move-only semantics and consuming methods, Continuation closes the safety gap between `UnsafeContinuation` and `CheckedContinuation` without paying for runtime checks.

## Motivation

Continuations are the primary mechanism for bridging callback-based APIs into Swift's structured concurrency world. Today, developers face an uncomfortable choice between two options:

- **`UnsafeContinuation`** — Zero overhead, but resuming twice is undefined behavior and forgetting to resume silently leaks the awaiting task forever. Neither mistake produces a diagnostic.
- **`CheckedContinuation`** — Adds runtime bookkeeping to detect these mistakes.

### The type system should help

Swift has a strong tradition of using the type system to prevent entire categories of bugs at compile time.

Continuation misuse should be in this category. A continuation is a *use-exactly-once* value: it must be resumed exactly once, and any deviation is a bug. This is precisely the contract that move-only types enforce.

Furthermore, the recent landing of new collection types that allow noncopyable Elements in swift-collections demonstrates that the ecosystem is ready to work with noncopyable types as first-class building blocks.

## Proposed Solution

We introduce `Continuation<Success: ~Copyable, Failure: Error>`, a `~Copyable` struct that enforces correct usage through three complementary mechanisms:

1. **Move-only semantics (`~Copyable`)**: The continuation cannot be copied, so it is impossible to resume it from two different code paths. Attempting to use a continuation after it has been moved is a compile-time error.

2. **`consuming` methods**: Every `resume` method consumes `self`, meaning the continuation is moved into the call and becomes unavailable afterward. A second call to `resume` on the same binding does not compile.

3. **`deinit` trap with `discard self`**: If a `Continuation` is dropped without being resumed, its `deinit` calls `fatalError`. The `resume` methods use `discard self` to suppress the `deinit` on the success path, so correctly used continuations incur no overhead.

### Double-resume — fixed

```swift
actor LegacyBridge {
    var continuation: Continuation<String, Never>?

    func store(_ continuation: consuming Continuation<String, Never>) {
        self.continuation = consume continuation
    }

    func complete(with value: String) {
        if let continuation {
            continuation.resume(returning: value) // ✅ consumes continuation

            continuation.resume(returning: value) // ❌ compile error:
                                                  // 'continuation' used after consuming use
        }
    }
}

```

The move-only semantics prevent the continuation from being resumed twice — the second call is a compile-time error because `continuation` was already consumed.

### Missing-resume — caught at runtime

```swift
actor LegacyBridge {
    var continuation: Continuation<String, any Error>?

    func store(_ continuation: consuming Continuation<String, any Error>) {
        self.continuation = consume continuation
    }

    func cancel() {
        // Bug: forgets to resume the continuation before clearing it.
        self.continuation = nil // 💥 runtime trap: "This continuation was dropped."
    }
}
```

When the stored continuation is overwritten or the actor is deallocated without resuming the continuation, the `deinit` fires immediately with a clear diagnostic — turning a silent hang into a diagnosable crash.

## Detailed Design

### The `Continuation` type

The new continuation type is defined as follows:

```swift
@frozen
public struct Continuation<Success: ~Copyable, Failure: Error>: ~Copyable, Sendable {
		// ... 
  
    deinit {
        fatalError("The continuation was dropped without resuming.")
    }

    @inlinable
    public consuming func resume(returning value: consuming sending Success) { ... }

    @inlinable
    public consuming func resume(throwing error: Failure) { ... }
}
```

**Key design points:**

- **`Sendable`** — `Continuation` is `Sendable` because its purpose is to be resumed form different tasks/threads and therefore "wake up" the task that was suspended on it. This allows passing the continuation across isolation boundaries, which is essential for bridging callbacks from other threads.
- **`consuming`** — Each `resume` method consumes `self`, transferring ownership into the method and preventing subsequent use.
- **`sending Success`** — The `value` parameter is marked `sending`, matching the semantics of `UnsafeContinuation.resume(returning:)` and enabling safe transfer of non-`Sendable` values into the async task.
- **`consuming Success`** — The `value` parameter allows the use of noncopyable types.
- **`discard self`** — Suppresses the `deinit` on the success path. 
  - This is critical: without it, every successful resume would trigger `fatalError`. The `discard self` statement tells the compiler that the value has been fully consumed and no cleanup is needed.

We also offer two convenience `resume` functions, accepting void or a Result type:

```swift
extension Continuation {  
    @inlinable
    public consuming func resume() where Success == Void { ... }

    @inlinable
    public consuming func resume(with result: consuming sending Result<Success, Failure>) { ... }
}
```

### Suspending on a continuation

It is not possible to directly instantiate a `Continuation` type, and instead one has to use the `withContinuation` function to obtain one, and at the same time, potentially suspend the calling task.

```swift
public nonisolated(nonsending) func withContinuation<Success: ~Copyable, Failure: Error>(
    of: Success.Type,
    throws: Failure.Type,
    _ body: (consuming Continuation<Success, Failure>) -> Void
) async throws(Failure) -> Success { ... }

public nonisolated(nonsending) func withContinuation<Success: ~Copyable>(
    of: Success.Type,
    _ body: (consuming Continuation<Success, Never>) -> Void
) async -> Success { ... }
```

**The `of:` parameter:**

The `of:` label serves both a practical and an ergonomic purpose. With the existing `with*Continuation` API, the `Success` type is inferred from usage inside the closure, which often requires an explicit type annotation on the continuation parameter:

```swift
// Today: type annotation required inside the closure
let data = await withCheckedContinuation { (continuation: UnsafeContinuation<Data, Never>) in
    bridge.store(continuation)
}
```

This pattern is verbose and buries the return type inside the closure signature. Compare with the proposed API:

```swift
// Proposed: type is clear at the call site
let data = await withContinuation(of: Data.self) { continuation in
    bridge.store(continuation)
}
```

This follows the same pattern used by other standard library APIs like `withThrowingTaskGroup`.
The type flows naturally at the call site, and the closure parameter needs no annotation.

**The `throws:` parameter and typed throws:**

SE-0300 introduced two separate free functions — `withCheckedContinuation` and `withCheckedThrowingContinuation` — because Swift had no way to express a single function that was conditionally throwing based on a type parameter. The only option was duplication.

SE-0413 (typed throws) removes that limitation. A single function parameterized over `Failure: Error` can now declare `throws(Failure)`, and the compiler handles all three cases uniformly:

- `Failure == Never` — `throws(Never)` is non-throwing; the `await` expression requires no `try`.
- `Failure == MySpecificError` — the call site must `try` and the compiler knows the thrown type exactly.
- `Failure == any Error` — equivalent to the old untyped `throws`.

The `throws:` parameter is the type witness for `Failure`, serving the same role as `of:` does for `Success`: it surfaces the type at the call site rather than burying it in a closure signature.

```swift
// Non-throwing — throws: defaults to Never.self, no try needed
let data = await withContinuation(of: Data.self) { continuation in
        // ...
}

// Typed throwing — compiler knows only NetworkError can be thrown
let data = try await withContinuation(of: Data.self, throws: NetworkError.self) { continuation in
    // ...
}

// Untyped throwing — matches the old withCheckedThrowingContinuation behavior
let data = try await withContinuation(of: Data.self, throws: (any Error).self) { continuation in
    // ...
}
```

Two separate functions (`withContinuation` / `withThrowingContinuation`) would cover only the `Never` and `any Error` cases, forcing an API design that is already obsolete. A typed-throws API like `withNetworkContinuation` would be impossible to express without the unified form. The single parameterized function is both more expressive and forwards-compatible.

### Converting to CheckedContinuation

Not all use-cases can make use of the non-copyable Continuation type. For example, situations where the continuation must be passed to multiple callbacks, where some library guarantees that only one of the callbacks is executed, e.g.:

```swift
try await withContinuation(of: Int.self, throws: (any Error).self) { c in // ❌ (2): 'c' consumed more than once
  // not guaranteed at compile time that these closures execute exactly once (!)
  // ❌ (1): noncopyable 'c' cannot be consumed when captured by an escaping closure
  someLib.onSuccess { c.resume(returning: $0) } // note (2): consumed here
  
  // not guaranteed at compile time that only ONE of those callbacks executes (!)
  someLib.onFailure { c.resume(throwing: $0) } // note (2): consumed again here
}
```

In general, callbacks are not guaranteed to run exactly-one, so even for this reason the above code is not compatible with the new non-copyable continuation type.

In these situations, it may be necessary to convert an **existing** `Continuation` (e.g. passed to you through another function), to a `CheckedContinuation`, which will allow this use case to be handled with dynamic safety checks in place:

```swift
try await withContinuation(of: Int.self, throws: (any Error).self) { c in
  let checked = CheckedContinuation(c)
  // or:   
  //   let unsafeCC = UnsafeContinuation(c)
  someLib.onSuccess { checked.resume(returning: $0) } // OK! Safe use is checked at runtime
  someLib.onFailure { checked.resume(throwing: $0) }
}
```

For this reason, `CheckedContinuation` and `UnsafeContinuation` remain available and will _not_ be deprecated, as they still serve an important use-case when the non-copyable continuation simply cannot be used.

### Behavior guarantees

Comparing the new Continuation type with the existing types:

| Scenario | `UnsafeContinuation` | `CheckedContinuation` | `Continuation` |
|--------------------|-----------------------|-------------------------|-----------------------|
| Exactly one resume | ✅ Works              | ✅ Works                | ✅ Works              |
| Double resume      | ⚠️ Undefined behavior | 💥 Runtime trap         | ❌ Compile-time error |
| Missing resume     | 😶 Silent hang        | ⚠️ Runtime warning      | 💥 Runtime trap       |
| Runtime overhead   | None                  | Allocation + atomic ops | None                  |

## Source Compatibility

This proposal is purely additive. No existing code is affected.

The names `withContinuation` and `Continuation` do not conflict with any existing standard library API.

## ABI Compatibility

This proposal is purely additive and does not change any existing ABI.

## Implications on Adoption

Migrating from `CheckedContinuation` to `Continuation` is mechanical:

| Before | After |
|---|---|
| `withCheckedContinuation { … }` | `withContinuation(of: T.self) { … }` |
| `withCheckedThrowingContinuation { … }` | `withContinuation(of: T.self, throws: (any Error).self) { … }` |
| `CheckedContinuation<T, E>` | `Continuation<T, E>` |

Because `Continuation` is `~Copyable`, some code patterns that implicitly copy the continuation (e.g., capturing it in a closure) will produce compile-time errors after migration. In those cases developers have to use the existing `Checked/UnsafeContinuation` syntax, depending on their use-case. 

If and when Swift gains gained "called once" closures, such uses of continuations may slowly move over to `Continuation` 

## Future Directions

### Introduction of `~Discardable` protocol

While the new `Continuation` improves the ergonomics of continuations in a lot of places, we still rely on a runtime trap, if a continuation is dropped. Since we use a noncopyable type here, the compiler already injects deinit calls at the places where a continuation is dropped. We could consider adding a new mode for `~Copyable` types, that signals, that instead of adding `deinit`s the compiler enforces that a type must be explicitly consumed. This would turn the runtime trap into a compiler error.
