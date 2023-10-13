# Adopting typed throws in the `Concurrency` module

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Konrad Malawski](https://github.com/ktoso), [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Proposed**

## Introduction

SE-NNNN introduced typed error throws to Swift which allows developers to explicitly
state the thrown errors.

Swift-evolution threads:

* [Typed throw functions - Evolution / Discussion - Swift Forums](https://forums.swift.org/t/typed-throw-functions/38860)
* [Status check: typed throws](https://forums.swift.org/t/status-check-typed-throws/66637)


## Motivation

There are a number of places in the `Concurrency` library where the adoption of typed
throws will help maintain thrown types through user code.


## Proposed solution

### `Task` creation and completion

The [`Task`](https://developer.apple.com/documentation/swift/task) APIs have a
`Failure` type similarly to `Result`, but use a pattern of overloading on
`Failure == any Error` and `Failure == Never` to handling throwing and
non-throwing versions. For example, the `Task` initializer is defined as the
following overloaded pair:

```swift
init(priority: TaskPriority?, operation: () async -> Success) where Failure == Never
init(priority: TaskPriority?, operation: () async throws -> Success) where Failure == any Error
```

These two initializers can be replaced with a single initializer using typed
throws. Furthermore, a problem that has been brought up is the
`@discardableResult` annotation on the initializers. This annotation silences
any warning if the resulting `Task` is not stored; however, the only cases where
this really makes sense are `Task<Void, Never>` or `Task<Never, Never>`. We
propose to add the following new initializers

```swift
public init(
  priority: TaskPriority? = nil,
  operation: @Sendable @escaping () async throws(Failure) -> Success
)

@discardableResult
public init(
  priority: TaskPriority? = nil,
  operation: @Sendable @escaping () async throws(Failure) -> Success
) where Success == Void, Failure == Never

@discardableResult
public init(
  priority: TaskPriority? = nil,
  operation: @Sendable @escaping () async throws(Failure) -> Success
) where Success == Never, Failure == Never
```

The result is both more expressive (maintaining typed error information) and
simpler. The same transformation can be applied to the `detached` function that
creates detached tasks, where the two overloads are replaced with the following:

```swift
public static func detached(
  priority: TaskPriority? = nil,
  operation: @Sendable @escaping () async throws(Failure) -> Success
)

@discardableResult
public static func detached(
  priority: TaskPriority? = nil,
  operation: @Sendable @escaping () async throws(Failure) -> Success
) where Success == Void, Failure == Never

@discardableResult
public static func detached(
  priority: TaskPriority? = nil,
  operation: @Sendable @escaping () async throws(Failure) -> Success
) where Success == Never, Failure == Never
```

Finally, the `value` property of `Task` is similarly overloaded:

```swift
extension Task where Failure == Never {}
  var value: Success { get async }
}
extension Task where Failure == any Error {
  var value: Success { get async throws }
}
```

These two can be replaced with a single property:

```swift
var value: Success { get async throws(Failure) }
```

### Continuations

Currently, there are two variants of each continuation creation method to
accommodate for the throwing and non-throwing variant. Since, the natural
spelling would be without the `Throwing` in the method name. We propose
to add the following two new methods:

```swift
public func withCheckedContinuation<T, Failure: Error>(
    function: String = #function,
    _ body: (CheckedContinuation<T, Failure>) -> Void
) async throws(Failure) -> T

public func withUnsafeContinuation<T, Failure: Error>(
  _ fn: (UnsafeContinuation<T, Failure>) -> Void
) async throws(Failure) -> T
```

#### Task cancellation

A few of the `Task` APIs are documented to only throw `CancellationError` and
can adopt typed throws. For example, `checkCancellation`:

```swift
public static func checkCancellation() throws(CancellationError)
```

Additionally, the `withTaskCancellationHandler` method can also adopt typed
throws.

```swift
public func withTaskCancellationHandler<T, Failure: Error>(
  operation: () async throws(Failure) -> T,
  onCancel handler: @Sendable () -> Void
) async throws(Failure) -> T
```

### Task groups

The task group APIs also need to gain support for typed throws. The important
detail here is that there are two layers of failures involved. First, the
failures produced by the child task themselves. Secondly, the failure returned
by `withThrowingTaskGroup` API itself. We propose to add the following API:

```swift
public func withTaskGroup<ChildTaskResult, ChildTaskFailure: Error, GroupResult, GroupFailure: Error>(
  of childTaskResultType: ChildTaskResult.Type,
  childTaskFailureType: ChildTaskFailure.Type = Never.self,
  returning returnType: GroupResult.Type = GroupResult.self,
  throwing failureType: GroupFailure.Type = Never.self,
  body: (inout ThrowingTaskGroup<ChildTaskResult, ChildTaskFailure>) async throws(GroupFailure) -> GroupResult
) async throws(GroupFailure) -> GroupResult
```

Additionally, we propose to add typed throws to following the
`ThrowingTaskGroup` APIs.

```swift
public struct ThrowingTaskGroup<ChildTaskResult: Sendable, Failure: Error> {
  public mutating func next() async throws(Failure) -> ChildTaskResult?
  public mutating func waitForAll() async throws(Failure)
}

struct ThrowingTaskGroup<ChildTaskResult: Sendable, Failure: Error> {
  public struct Iterator: AsyncIteratorProtocol {
    public mutating func next() async throws(Failure) -> Element? 
  }
}
```

### Task locals

The `withValue` method can also adopt typed throws.

```swift
public final class TaskLocal<Value: Sendable> {
  public func withValue<R, Failure: Error>(
    _ valueDuringOperation: Value,
    operation: () async throws(Failure) -> R,
    file: String = #fileID,
    line: UInt = #line
  ) async throws(Failure) -> R 
}
```

### MainActor

The `MainActor` provides a static rethrowing `run` method. This method can also
adopt typed throws:

```swift
public static func run<T: Sendable, Failure: Error>(
  resultType: T.Type = T.self,
  body: @MainActor @Sendable () throws(Failure) -> T
) async throws(Failure) -> T
```

### `AsyncSequence` & `AsyncIteratorProtocol`

`AsyncSequence` iterators can throw during iteration, as described by the
`throws` on the `next()` operation on async iterators:

```swift
public protocol AsyncIteratorProtocol {
  associatedtype Element
  mutating func next() async throws -> Element?
}
```

Introduce a new associated type `Failure` into this protocol to use as the
thrown error type of `next()`, i.e.,

```swift
associatedtype Failure: Error = any Error
mutating func next() async throws(Failure) -> Element?
```

Then introduce an associated type `Failure` into `AsyncSequence` that provides a
more convenient name for this type, i.e.,

```swift
associatedtype Failure where AsyncIterator.Failure == Failure
```

With the new `Failure` associated type, async sequences can be composed without
losing information about whether (and what kind) of errors they throw.

With the new `Failure` type in place, we can adopt [primary asociated
types](https://github.com/apple/swift-evolution/blob/main/proposals/0346-light-weight-same-type-syntax.md)
for these protocols:

```swift
public protocol AsyncIteratorProtocol<Element, Failure> {
  associatedtype Element
  associatedtype Failure: Error = any Error
  mutating func next() async throws(Failure) -> Element?
}

public protocol AsyncSequence<Element, Failure> {
  associatedtype AsyncIterator: AsyncIteratorProtocol
  associatedtype Element where AsyncIterator.Element == Element
  associatedtype Failure where AsyncIterator.Failure == Failure
  func makeAsyncIterator() -> AsyncIterator
}
```

This allows the use of `AsyncSequence` with both opaque types (`some
AsyncSequence<String, any Error>`) and existential types (`any
AsyncSequence<Image, NetworkError>`). 

### AsyncThrowingStream

The non-throwing variant `AsyncStream` cannot adopt typed throws
since it does not have a generic `Failure` parameter; however,
the throwing variant `AsyncThrowingStream` already contains a `Failure`
generic parameter and can be extended to adopt typed throws.
The current initializers of `AsyncThrowingStream` are constraining
the `Failure` type to `Error`.

```swift
public init(
  _ elementType: Element.Type = Element.self,
  bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded,
  _ build: (Continuation) -> Void
) where Failure == Error

public init(
  unfolding produce: @escaping () async throws -> Element?
) where Failure == Error 
```

We propose to add two new initializers that drop the `Failure` constraint:

```swift
public init(
  of elementType: Element.Type = Element.self,
  throwing failureType: Failure.Type = Failure.self,
  bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded,
  _ build: (Continuation) -> Void
)

public init(
  unfolding produce: @escaping () async throws(Failure) -> Element?
)
```

Furthermore, we propose to add a new `makeStream` method that
similarly drop the `Failure` constraint:

```swift
@backDeployed(before: SwiftStdlib 5.9)
public static func makeStream(
    of elementType: Element.Type = Element.self,
    throwing failureType: Failure.Type = Failure.self,
    bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
) -> (stream: AsyncThrowingStream<Element, Failure>, continuation: AsyncThrowingStream<Element, Failure>.Continuation) {
  var continuation: AsyncThrowingStream<Element, Failure>.Continuation!
  let stream = AsyncThrowingStream<Element, Failure>(bufferingPolicy: limit) { continuation = $0 }
  return (stream: stream, continuation: continuation!)
}
```

### Throwing transformation sequences

The `Concurrency` module contains a few algorithms for `AsyncSequence`. Those
algorithms are backed by concrete types and have both a throwing and
non-throwing variant. The throwing types do not contain a generic `Failure`
parameter so we cannot adopt typed throws on them. However, we propose to add
new underlying types with a generic `Failure` parameter and use opaque result
types. Importantly though those new methods cannot be back-deployed since they
introduce new types. Those are the new typed throw APIs that we propose to add:

```swift
extension AsyncSequence {
  public func map<Transformed, Failure: Error>(
    _ transform: @Sendable @escaping (Element) async throws -> Transformed
  ) -> some AsyncSequence<ElementOfResult, Failure>

  public func compactMap<ElementOfResult, Failure: Error>(
    _ transform: @Sendable @escaping (Element) async throws(Failure) -> ElementOfResult?
  ) -> some AsyncSequence<ElementOfResult, Failure>
  
  public func drop(
    while predicate: @Sendable @escaping (Element) async throws(Failure) -> Bool
  ) -> some AsyncSequence<ElementOfResult, Failure>

  public func filter(
    _ isIncluded: @Sendable @escaping (Element) async throws(Failure) -> Bool
  ) -> some AsyncSequence<ElementOfResult, Failure>

  public func flatMap<SegmentOfResult: AsyncSequence>(
    _ transform: @Sendable @escaping (Element) async throws(Failure) -> SegmentOfResult
  ) -> some AsyncSequence<ElementOfResult, Failure>

  public func prefix(
    while predicate: @Sendable @escaping (Element) async throws(Failure) -> Bool
  ) -> some AsyncSequence<ElementOfResult, Failure> // This is currently rethrows for no reason: https://github.com/apple/swift/issues/66922
}
```

Open question:
- I am unsure if we can actually adopt opaque return types here due to the `Sendable` constraints. By default
those do not propagate through opaque return types. We could overload those methods to conditionally return `some (AsyncSequence<ElementOfResult, Failure> & Sendable)`. 
- The `@Sendable` on the various closures feels overly restrictive and once we solve the hopping of `next` it shouldn't be required. In line with the previous
open question we probably want to make the sendability of the return type be conditional on if the closure is `Sendable`

## Source compatibility

TODO

## Effect on ABI stability

The ABI between an function with an untyped throws and one that uses typed
throws will be different, so that typed throws can benefit from knowing the
precise type. For most of the proposed changes, an actual ABI break can
be avoided because the implementations can make use of
[`@backDeploy`](https://github.com/apple/swift-evolution/blob/main/proposals/0376-function-back-deployment.md).
However, the suggested change to `AsyncIteratorProtocol` might not be able to be
made in a manner that does not break ABI stability.

## Effect on API resilience

TODO

## Future directions

TODO

## Alternatives considered

### Adopt typed throws for `Clock.sleep`

Most of the clock implementation only throw a `CancellationError` from their
`sleep` method; however, nothing enforces this right now and there might be
implementations out there that throw a different error. Restricting the protocol
to only throw `CancellationError`s would be a breaking change