# Hashable conformance for `UnownedTaskExecutor`

* Proposal: [SE-0523](0523-hashable-unownedtask-executor.md)
* Authors: [Fabian Fett](https://github.com/fabianfett), [Konrad Malawski](https://github.com/ktoso)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 6.4)**
* Implementation: [apple/swift#73968](https://github.com/swiftlang/swift/pull/73968)
* Review: ([pitch](https://forums.swift.org/t/pitch-hashable-conformance-for-unownedtaskexecutor/85143)) ([review](https://forums.swift.org/t/se-0523-hashable-conformance-for-unownedtaskexecutor/85593)) ([acceptance](https://forums.swift.org/t/accepted-se-0523-hashable-conformance-for-unownedtaskexecutor/85931))

## Summary of changes

This proposal adds `Hashable` conformance to `UnownedTaskExecutor`, enabling its use as a dictionary key and in sets. `UnownedTaskExecutor` already conforms to `Equatable`; this is a natural and source-compatible extension of that conformance.

## Motivation

[SE-0417](https://github.com/apple/swift-evolution/blob/main/proposals/0417-task-executor-preference.md) introduced task executor preferences in Swift 6 and extended `withUnsafeCurrentTask` to expose the `unownedTaskExecutor` of the currently running task. This allows performance-sensitive code to make scheduling decisions based on the executor a task is already running on.

A concrete example arises in connection pooling. A `ConnectionPool` may maintain connections across multiple executors. When a task requests a connection, the pool can minimize context switches by preferring a connection already associated with the requesting task's executor. With only `Equatable` conformance, this requires a linear scan over all known executors:

```swift
// Today: O(n) linear search
func pickConnection(preferring executor: UnownedTaskExecutor) -> Connection {
    for (e, connection) in executorConnectionList {
        if e == executor { return connection }
    }
    // fallback
    return executorConnectionList.first!.connection
}
```

With `Hashable` conformance, this becomes a constant-time dictionary lookup:

```swift
// With Hashable: O(1) dictionary lookup
func pickConnection(preferring executor: UnownedTaskExecutor) -> Connection {
    if let connection = connectionsByExecutor[executor] {
        return connection
    }
    // fallback
    return connectionsByExecutor.values.first!
}
```

This pattern is applicable to any system that indexes resources, caches, or scheduling metadata by executor identity.

## Proposed solution

Add `Hashable` conformance to `UnownedTaskExecutor`.

## Detailed design

`UnownedTaskExecutor` is a struct wrapping a `Builtin.Executor` value. It already provides `Equatable` conformance based on the identity of the underlying executor reference. The `Hashable` conformance hashes the same underlying identity value, maintaining consistency with the existing equality semantics.

```swift
extension UnownedTaskExecutor: Hashable {}
```

### API Surface

The only public API change is the addition of the `Hashable` protocol conformance on `UnownedTaskExecutor`:

```swift
extension UnownedTaskExecutor: Hashable {}
```

This is purely additive and source-compatible with existing code.

## Source compatibility

This proposal is purely additive. All existing code continues to compile without changes. Types that are `Equatable` can adopt `Hashable` without breaking source compatibility.

## ABI compatibility

Adding a protocol conformance is an additive ABI change. This proposal does not modify existing ABI surface.

## Implications on adoption

This feature requires a minimum deployment target matching the Swift standard library version in which it ships. It has no other adoption implications.

## Alternatives considered

### Do nothing

If we don't do anything, users are forced into using the implementation to get the `Hashable` conformance themselves:

```swift
extension UnownedTaskExecutor: Hashable {
  @inlinable
  public func hash(into hasher: inout Hasher) {
    let (ident, impl) = unsafeBitCast(self, to: (Int, Int).self)
    hasher.combine(ident)
    hasher.combine(impl)
  }
}
```
