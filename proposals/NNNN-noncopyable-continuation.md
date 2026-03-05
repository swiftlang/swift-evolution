# `Continuation` — Safe and Performant Async Continuations

- **Proposal:** SE-NNNN
- **Authors:** [Fabian Fett](https://github.com/fabianfett), [Konrad Malawski](https://github.com/ktoso)
- **Review Manager:** TBD
- **Status:** Pitch
- **Implementation:** [PR in Swift Async Algorithms](https://github.com/apple/swift-async-algorithms/pull/404)
- **Related Proposals:** 
    - [SE-0300: Continuations for interfacing async tasks with synchronous code](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0300-continuation.md)
    - [SE-0390: Noncopyable structs and enums](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md)
    - [SE-0413: Typed throws](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md)

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

We introduce `Continuation<Success: ~Copyable, Failure: Error>`, a `~Copyable` struct that wraps `UnsafeContinuation` and enforces correct usage through three complementary mechanisms:

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

### `Continuation` struct

```swift
@frozen
public struct Continuation<Success: ~Copyable, Failure: Error>: ~Copyable, Sendable {

    @usableFromInline
    let unsafeContinuation: UnsafeContinuation<Success, Failure>
    @usableFromInline
    let file: StaticString
    @usableFromInline
    let line: Int

    @inlinable
    init(_ unsafeContinuation: UnsafeContinuation<Success, Failure>, file: StaticString, line: Int) {
        self.unsafeContinuation = unsafeContinuation
        self.file = file
        self.line = line
    }

    deinit {
        fatalError("The continuation created in \(self.file):\(self.line) was dropped.")
    }

    @inlinable
    public consuming func resume() where Success == Void {
        self.unsafeContinuation.resume()
        discard self // prevent deinit
    }

    @inlinable
    public consuming func resume(returning value: consuming sending Success) {
        self.unsafeContinuation.resume(returning: value)
        discard self // prevent deinit
    }

    @inlinable
    public consuming func resume(throwing error: Failure) {
        self.unsafeContinuation.resume(throwing: error)
        discard self // prevent deinit
    }

    @inlinable
    public consuming func resume(with result: consuming sending Result<Success, Failure>) {
        self.unsafeContinuation.resume(with: result)
        discard self // prevent deinit
    }
}
```

**Key design points:**

- **`Sendable`** — `Continuation` is `Sendable` because `UnsafeContinuation` is `Sendable`. This allows passing the continuation across isolation boundaries, which is essential for bridging callbacks from other threads.
- **`consuming`** — Each `resume` method consumes `self`, transferring ownership into the method and preventing subsequent use.
- **`sending Success`** — The `value` parameter is marked `sending`, matching the semantics of `UnsafeContinuation.resume(returning:)` and enabling safe transfer of non-`Sendable` values into the async task.
- **`consuming Success`** — The `value` parameter allows the use of noncopyable types.
- **`discard self`** — Suppresses the `deinit` on the success path. This is critical: without it, every successful resume would trigger `fatalError`. The `discard self` statement tells the compiler that the value has been fully consumed and no cleanup is needed.
- **`deinit`** — Acts as the safety net for the missing-resume case. If control flow drops a `Continuation` without calling `resume`, the `deinit` fires and traps immediately with a clear diagnostic message.

### Free function

```swift
public func withContinuation<Success: ~Copyable, Failure: Error>(
    of: Success.Type,
    throws: Failure.Type = Never.self,
    file: StaticString = #file,
    line: Int = #line,
    _ body: (consuming Continuation<Success, Failure>) -> Void
) async throws(Failure) -> Success {
    await withUnsafeContinuation { (continuation: UnsafeContinuation<Success, Failure>) in
        body(Continuation(continuation, file: file, line: line))
    }
}
```

**The `of:` parameter:**

The `of:` label serves both a practical and an ergonomic purpose. With the existing `with*Continuation` API, the `Success` type is inferred from usage inside the closure, which often requires an explicit type annotation on the continuation parameter:

```swift
// Today: type annotation required inside the closure
let data = await withUnsafeContinuation { (continuation: UnsafeContinuation<Data, Never>) in
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

**Capturing file and line:**

File and line are captured to enable a better developer experience. This allows us to inform developers where a `Continuation` was created that leaked.

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

Because `Continuation` is `~Copyable`, some code patterns that implicitly copy the continuation (e.g., capturing it in a closure) will produce compile-time errors after migration. In those cases developers have to use the existing Checked/UnsafeContinuation syntax, depending on their use-case. Once Swift has gained call once closures, theses use of Checked/UnsafeContinuation can be migrated to the new Continuation syntax as well.

## Future Directions

### Capturing Noncopyable types in closures

Currently, Swift does not support capturing non Copyable types in closures. The reason for this is, that Swift currently does not have an annotation that allows closures to just be called once. In those cases users should continue to use the existing Continuation types.

### Introduction of `~Discardable` protocol

While the new `Continuation` improves the ergonomics of continuations in a lot of places, we still rely on a runtime trap, if a continuation is dropped. Since we use a noncopyable type here, the compiler already injects deinit calls at the places where a continuation is dropped. The Swift team could consider adding a new mode for `~Copyable` types, that signals, that instead of adding `deinit`s the compiler enforces that a type must be explicitly consumed. This would turn the runtime trap into a compiler error.
