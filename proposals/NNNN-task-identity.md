# Task Identity

* Proposal: [SE-NNNN](NNNN-task-identity.md)
* Authors: [Joakim Hassila](https://github.com/hassila), [Konrad 'ktoso' Malawski](https://github.com/ktoso)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: TBD
* Review: ([pitch](https://forums.swift.org/t/pitch-cheap-task-identity-for-high-performance-instrumentation/86666))

## Summary of changes

Adds a cheap, stable, process-unique identifier for the currently executing `Task`. `Task.currentIdentifier`, with instance accessors on `Task` and `UnsafeCurrentTask`, returns an opaque `Task.Identifier` at a cost comparable to a thread-local read — enabling always-on instrumentation like tracing and structured logging on the hot path.

## Motivation

Swift Concurrency exposes a number of useful ways to look at the current task: `withUnsafeCurrentTask { … }`, `Task.currentPriority`, `Task.name`, and so on. For most application code these APIs are perfectly fine.

They are, however, not designed for the always-on instrumentation path. Consider a tracing or structured logging library that wants to tag every emitted event with the identifier of the task it was produced on, so that consumers can later reconstruct per-task timelines, attribute latency, and follow logical flows across suspension points. To be acceptable, such attribution has to be effectively free — on the order of a few nanoseconds — because it runs inside the user's hot path on every event.

The closest thing available today is `withUnsafeCurrentTask`, combined with either `unsafeBitCast` to extract a numeric identity or `hashValue` to obtain a hashable one. Measured on Apple Silicon (M-series) with an opt-build of the standard library, the underlying runtime entry point takes a couple of nanoseconds; going through `withUnsafeCurrentTask` and one of the standard conversions costs roughly 15x more. Full benchmark setup and per-approach numbers are in the [pitch thread](https://forums.swift.org/t/pitch-cheap-task-identity-for-high-performance-instrumentation/86666).

The closure-shaped APIs are not expensive because the runtime call is slow — it is not. The cost comes from the generic `withUnsafeCurrentTask` entry point: existential boxing of the closure, dynamic stack allocation, witness-table indirection and type-metadata lookup all add up before user code runs.

For context, a bespoke span library that bypasses the generic closure path can complete a full span begin/end pair in around 25 ns on the same hardware — small enough to leave instrumentation enabled in production. Cheap task identity is one of the building blocks that makes that possible. The runtime already maintains exactly the identifier we need; exposing it as a stable API would let instrumentation libraries reach this performance level without leaning on internal runtime entry points.

The use cases that benefit from this are broader than tracing alone:

- **Real-time and latency-sensitive systems** — trading infrastructure, audio pipelines, game engines — where production instrumentation has to be on by default and effectively invisible in profiles.
- **Profilers and developer tools** that want to attribute samples or events to tasks without imposing a measurable cost on the program being observed.
- **Lock-free data structures** that want to key per-task state, where pointer identity is unsafe because the runtime may reuse the heap address of a freed task.
- **Custom executors** that need to maintain a side-table indexed by task identity, for example to implement per-task accounting.
- **Structured logging** where each emitted line carries the originating task identifier as metadata, so that later log analysis can reconstruct per-task flows even when many tasks share an underlying thread.

In all these cases, the requirement is the same: a stable, equatable, hashable identifier for the current task, obtainable in the single-digit-nanosecond range.

## Proposed solution

We propose to expose the Swift runtime's existing process-unique task identifier as a public API on `Task`.

```swift
// Constrained to Task<Never, Never> so callers can write `Task.currentIdentifier`
// without specifying generic arguments — matches the shape of Task.sleep.
extension Task where Success == Never, Failure == Never {
  /// The identifier of the currently executing task, or `nil` if no Swift
  /// `Task` is currently running on this thread.
  public static var currentIdentifier: Task.Identifier? { get }
}
```

A new opaque value type is introduced as the result type. It is declared at top level and surfaced through a typealias on `Task` so that `Task.Identifier` is one canonical type rather than a family parameterised over `Task`'s generic arguments:

```swift
@frozen
public struct TaskIdentifier: Sendable, Hashable {
  public var rawValue: UInt64 { get }
}

extension Task {
  public typealias Identifier = TaskIdentifier
}
```

`rawValue` is the documented escape hatch for serialisation — binary wire formats, shared-memory regions, and bridges to non-Swift consumers — where an explicit 64-bit integer representation is required. The type intentionally has no public initialiser; see *Alternatives considered* for the rationale.

The same identifier can also be read off a held `Task` reference and off `UnsafeCurrentTask`:

```swift
extension Task {
  public var identifier: Task.Identifier { get }
}

extension UnsafeCurrentTask {
  public var identifier: Task.Identifier { get }
}
```

In typical use, hot-path instrumentation looks like this:

```swift
@inline(__always)
func emit(_ event: Event) {
  let id = Task.currentIdentifier  // a few nanoseconds, no allocations
  buffer.append(event, taskID: id)
}
```

## Detailed design

### `Task.Identifier`

`Task.Identifier` is an opaque value type wrapping a 64-bit unsigned integer produced by the runtime. The underlying integer value is accessible through `rawValue` for serialisation. No public initialiser is provided; the rationale for both choices is in *Alternatives considered*.

```swift
@frozen
public struct TaskIdentifier: Sendable, Hashable {
  public var rawValue: UInt64 { get }
}

extension Task {
  public typealias Identifier = TaskIdentifier
}
```

The struct is declared at top level rather than nested inside `Task`. Because `Task` is generic over `Success` and `Failure`, a directly-nested `Task.Identifier` would be `Task<Success, Failure>.Identifier` — a separate type per instantiation, which is the wrong model for a single canonical identifier type. The typealias gives the user-facing `Task.Identifier` spelling while keeping one canonical underlying type.

A consequence of this shape is that both `Task.Identifier` and the underlying `TaskIdentifier` resolve to the same type and are spellable at call sites. `Task.Identifier` is the canonical, documented spelling and should be preferred; `TaskIdentifier` exists as the unparameterised backing type because Swift's name resolution does not support nesting a non-generic type publicly inside a generic enclosing type.

The type serves two distinct usage shapes. **In-process consumers** — dictionaries keyed by task identity, sets of live tasks, typed API parameters carrying a task identifier across module boundaries — work with `Task.Identifier` directly and never reach for the underlying integer. **Wire-format and cross-language consumers** extract `rawValue` to put a stable 64-bit integer on the wire. The API is shaped to be ergonomic for both.

`rawValue` is the one supported escape hatch from the wrapper. Wire-format authors emit `rawValue` on the producer side and treat the value as an opaque integer on the consumer side; the consumer typically does not need to reconstruct a `Task.Identifier` instance to log it, key on it, or join it against other data. Serialised values are intended for exporting observations (logs, traces, joins against other data) — not for asserting task identity in another process, where the value carries no semantic guarantees beyond being a 64-bit integer. `MemoryLayout<Task.Identifier>.size` is a compile-time constant of `8`, fixed by `@frozen`.

No `Codable`, `Encodable`, or `Decodable` conformance is proposed. The documented serialisation path is to encode `rawValue` directly in whatever schema the caller uses; a conformance would either pick an encoded representation on the caller's behalf (which schema design should determine, not the stdlib) or duplicate what `rawValue` already provides. A conformance could be considered in a separate proposal if a use case emerges.

The identifier has the following semantic guarantees:

- **Process-unique.** Two live tasks within the same process always have distinct identifiers.
- **Never reused.** Once assigned, an identifier is never reassigned to another task, even after the original task has been destroyed. This is the property that makes the identifier safe as a key in long-lived side tables, and is a stronger guarantee than pointer identity provides.
- **Stable for the lifetime of a task.** A task's identifier is set at task creation and never changes.
- **Not stable across processes.** Identifiers are process-local and should not be persisted or transmitted with the expectation of cross-process meaning.

The runtime today allocates identifiers monotonically, but this is an implementation property, not part of the contract. `Task.Identifier` does not conform to `Comparable`; the underlying `rawValue` is exposed for serialisation, not for ordering reasoning. Future runtimes may shard the counter, mix in a startup nonce, or otherwise change the allocation scheme without source breakage, provided the guarantees above continue to hold.

Counter-space exhaustion (2⁶⁴ identifier allocations within a single process) is not specified behaviour. The 64-bit space is large enough to make this unreachable in any realistic process lifetime — at one billion task allocations per second it would take roughly 584 years to wrap — so the proposal does not mandate a specific outcome.

### `Task.currentIdentifier`

```swift
extension Task where Success == Never, Failure == Never {
  public static var currentIdentifier: Task.Identifier? { get }
}
```

The constraint mirrors how `Task.sleep` and similar static members are declared today: the static accessor does not depend on `Success` or `Failure`, so binding it to the canonical `Task<Never, Never>` namespace lets callers write `Task.currentIdentifier` without specifying generic arguments.

Returns the identifier of the task currently executing on this thread, or `nil` if no Swift `Task` is currently running (for example, when called from a synchronous context originating outside the concurrency runtime).

This accessor is the performance-critical entry point. Its design target is the single-digit nanosecond range, comparable to a thread-local read, with no allocations. See [Performance contract](#performance-contract) below for the full envelope the implementation is asked to deliver.

### Instance accessors

```swift
extension Task {
  public var identifier: Task.Identifier { get }
}

extension UnsafeCurrentTask {
  public var identifier: Task.Identifier { get }
}
```

`Task.identifier` is always safe to call, including after the task has completed. The identifier is fixed at task creation and never changes thereafter; no synchronisation is required.

`UnsafeCurrentTask.identifier` carries the same safety contract as every other property on `UnsafeCurrentTask`: the unsafe task reference does not keep the task alive, and reading from a deallocated task is undefined behaviour. Because the property returns a trivial value type, callers can read the identifier inside the `withUnsafeCurrentTask` closure and continue to use the resulting value after the closure has exited.

### Performance contract

The runtime already maintains a 64-bit identifier for every task; the implementation is primarily a question of exposing that field through a stable API at a cost callers can rely on. The contract this proposal asks of the implementation is:

- The steady-state cost of `Task.currentIdentifier` is in the single-digit nanosecond range on contemporary Apple Silicon, with comparable cost on other modern 64-bit hardware. The accessor should be no more expensive than a thread-local read.
- The call performs no allocations, no dynamic dispatch on the common path, and no synchronisation beyond what the underlying runtime read already requires.
- The instance accessors on `Task` and `UnsafeCurrentTask` deliver the same cost characteristics.
- The synthesised `Equatable` and `Hashable` operations on `Task.Identifier` compile to the same instruction sequences as their `UInt64` equivalents for concrete-typed call sites.

The specific inlining strategy, ABI symbol shape, and back-deployment floor are matters for implementation review.

`Task.Identifier` is `@frozen` to pin its layout: this is part of the API contract, not an inlining hint. The `rawValue` accessor and the `MemoryLayout<Task.Identifier>.size == 8` guarantee both depend on it. The 64-bit width is similarly part of the contract via `rawValue`. Internal *interpretation* of those bits — for example, partitioning into a `(generation, slot)` pair, or mixing in a process-startup nonce — remains a free implementation choice as long as the semantic guarantees stated under [`Task.Identifier`](#taskidentifier) (process-unique, never reused) continue to hold.

### Interaction with task names

`Task.name` ([SE-0469](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0469-task-names.md)) provides a human-readable label assigned at task creation. The identifier proposed here is complementary: it is small, cheap, always present, and process-unique. Instrumentation systems are expected to use the identifier as the join key (in logs, in tables, in side data structures) and to materialise the name only when rendering for human consumption — much in the same way that an OS thread has both a numeric `tid` and an optional pthread name.

## Source compatibility

This proposal is purely additive. All existing code continues to compile without changes.

## ABI compatibility

This proposal is purely additive at the public API level. No existing types or entry points are modified. The new `Task.Identifier` type is `@frozen` with a single `UInt64` payload; its layout is part of the ABI from the day the API ships. Whether the implementation introduces new ABI symbols or builds entirely on existing runtime entry points is a matter for implementation review.

## Implications on adoption

The deployment floor depends on the implementation choices discussed in [Performance contract](#performance-contract). The feature is otherwise purely additive and can be freely adopted and un-adopted in source code with no effect on source or ABI compatibility for clients of an adopting library.

## Future directions

### `Comparable` conformance

As noted under [`Task.Identifier`](#taskidentifier), ordering is not part of the API contract and the type does not conform to `Comparable`. A conformance could be considered in a separate proposal if a use case emerges.

### Cross-process correlation

For distributed tracing across process or host boundaries the identifier proposed here is intentionally not sufficient — it is process-local. Cross-process correlation remains the domain of `swift-distributed-tracing` and similar libraries, which build their own globally-unique identifiers on top.

## Alternatives considered

### Expose pointer identity instead

The most direct alternative is to expose the raw task pointer (as an `UnsafeRawPointer`, or wrapped in an opaque type). This is what most callers reach for today via `unsafeBitCast`.

We reject this for one main reason: the runtime is free to recycle the heap address of a destroyed task. Long-lived side tables keyed by pointer identity therefore risk silently confusing two different tasks that happen to share an address — and in the case of an instrumentation system that caches per-task metadata (a name, a span context, …), this leads to mis-attribution that is essentially impossible to diagnose after the fact.

A never-reused, process-unique identifier eliminates this entire class of bug.

### Make `withUnsafeCurrentTask` cheap instead

In principle the cost of `withUnsafeCurrentTask` could be reduced by specialising the generic closure path, by adding `@inlinable` shims, or by introducing a non-generic overload. We considered this and concluded that even the best case still pays for materialising and passing an `UnsafeCurrentTask?` value, whereas in practice most callers only want a small identifier. A direct accessor is both simpler and faster, and it does not preclude future improvements to `withUnsafeCurrentTask` along these lines.

### Return `UInt64` directly

The accessor could simply return `UInt64?`, sidestepping the wrapper type entirely. This was considered and rejected.

A bare `UInt64?` does not document intent at the call site. The same shape is used for thread IDs, file descriptors, sequence numbers, byte offsets and a host of other things; in a function signature `taskID: UInt64?` reads no differently from any of those. Swift is a strongly-typed language, and its standard library consistently uses distinct nominal types for identifiers and quantities even when the underlying representation is a primitive — `ObjectIdentifier`, `Duration` and `Unicode.Scalar` all follow this pattern. `Task.Identifier` belongs to the same family: a wrapper that closes the type-confusion hole at the type system level, and as a side effect disallows nonsense operations like `id + 1` that the compiler would otherwise have to accept.

The cost of the wrapper is zero at runtime: `@frozen` with a single trivial `UInt64` payload lowers to the same machine code as a bare `UInt64` and is passed in the same register. For direct concrete-typed call sites, the synthesised `Equatable` / `Hashable` operations compile to the same instruction sequences as their `UInt64` equivalents.

### Conform `Task.Identifier` to `RawRepresentable`, or otherwise provide a public initialiser

The type exposes `rawValue` but no way to construct an identifier from a `UInt64`. Two related possibilities were considered:

**Conform to `RawRepresentable`.** This is the natural-looking shape for a typed wrapper around an integer, and would have given us `Codable` synthesis for free where `RawValue: Codable`. The protocol requires `init?(rawValue:)`, however — a failable initialiser, built around enum-like types where only some raw values are valid. For `Task.Identifier` every `UInt64` is structurally a valid identifier; the runtime cannot retroactively tell us which integers it issued, and no receiver can validate raw bytes off the wire. Conforming would mean shipping an initialiser that returns `nil` for no input, forcing every caller to unwrap an `Optional` that cannot be `.none`. That is the wrong default.

**Provide a non-failable `init(_ rawValue: UInt64)`** without the protocol conformance, following the precedent set by `os.OSSignpostID`. The objection here is semantic rather than ergonomic: `Task.Identifier` values are *issued by the runtime*, and synthesising one from an arbitrary integer produces a value that does not correspond to any task in this process. Most consumer-side wire-format code does not actually need to reconstruct a `Task.Identifier` at all — it logs the integer, keys a dictionary on it, or joins it against other data, all of which can be done with the bare `UInt64`. The wrapper is most valuable on the *producer* side, where the runtime hands you a typed value and the type system prevents confusion with unrelated integers.

The chosen shape — `rawValue` for one-way extraction, no public initialiser, no `RawRepresentable` conformance — reflects this asymmetry. The proposal intentionally provides no supported reconstruction API; unsafe tools remain outside the semantic contract.

### Return a non-optional `Task.Identifier` with a reserved sentinel

`Task.currentIdentifier` is specified to return `Task.Identifier?`, where `nil` signals that no Swift `Task` is currently running on this thread. Because `UInt64` has no spare bits, on contemporary 64-bit Swift ABIs `Optional<Task.Identifier>` is 16 bytes and is returned in two registers; an unconditional `Task.Identifier` would be 8 bytes and returned in one. On the hot path this is a small but real difference.

An alternative is to reserve a value within `Task.Identifier` — most naturally zero, since the runtime never assigns it today — to mean "no current task", and to have the accessor return non-optional `Task.Identifier`. This trades a small amount of static type-system safety (callers must check `id != .none` rather than unwrap an `Optional`) for a measurably cheaper return convention and a slightly simpler call site for the common case where the caller does not care about the absent case (it just stores whatever it gets).

We chose `Task.Identifier?` for the proposal because it is the idiomatic Swift shape for "may not be present", and because the absent case is not entirely uncommon (synchronous callers from outside the concurrency runtime). The sentinel form remains available as a future addition: a separately-named non-optional accessor could be introduced without affecting `currentIdentifier`. This is one of the affordances a wrapper type enables that a bare `UInt64?` would not.

### Synthesise the identifier in user code

A library could in principle assign its own identifiers — by attaching a task-local, by maintaining a side table keyed on `withUnsafeCurrentTask`, or by other means. All such approaches either inherit the pointer-reuse problem described above, pay the `withUnsafeCurrentTask` overhead on every emission, or both. The runtime already maintains exactly the identifier we want; the only thing missing is a way to read it cheaply.

### Place the API on `UnsafeCurrentTask` only

We considered exposing the identifier only on `UnsafeCurrentTask` and requiring callers to go through `withUnsafeCurrentTask`. This preserves the existing API shape but loses the entire performance benefit, which is the point of the proposal.

## Acknowledgments

Thanks to **Franz Busch** for the suggestion to surface the runtime's existing monotonic `task_id` rather than the task pointer — the design pivot that shaped this proposal. Thanks to **John McCall** for confirming the underlying runtime fields can be made ABI-stable, and to **tera** for surfacing the pointer-reuse hazard that informed the "never reused" guarantee. Thanks also to the other participants of the [pitch thread](https://forums.swift.org/t/pitch-cheap-task-identity-for-high-performance-instrumentation/86666).
