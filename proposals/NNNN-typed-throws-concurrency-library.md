# Typed throws

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

These two initializers can be replaced with a single initializer using typed throws:

```swift
init(priority: TaskPriority?, operation: () async throws(Failure) -> Success)
```

The result is both more expressive (maintaining typed error information) and
simpler (because a single initializer suffices). The same transformation can be
applied to the `detached` function that creates detached tasks, where the two
overloads are replaced with the following:

```swift
@discardableResult
static func detached(
    priority: TaskPriority? = nil,
    operation: @escaping () async throws(Failure) -> Success
) -> Task<Success, Failure>
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

Similarly, the `sleep` APIs will only throw on cancellation:

```swift
public static func sleep<C: Clock>(
  until deadline: C.Instant,
  tolerance: C.Instant.Duration? = nil,
  clock: C = ContinuousClock()
) async throws(CancellationError)

public static func sleep<C: Clock>(
  for duration: C.Instant.Duration,
  tolerance: C.Instant.Duration? = nil,
  clock: C = ContinuousClock()
) async throws(CancellationError)
```

Additionally, the `ContinuousClock` and `SuspendingClock` `sleep` methods will also
adopt typed throws:

```swift
public func sleep(
  until deadline: Instant, tolerance: Swift.Duration? = nil
) async throws(CancellationError)
```

Lastly, the `withTaskCancellationHandler` needs a new variant
that supports a typed error `operation` closure:

```swift
public func withTaskCancellationHandler<T, Failure: Error>(
  operation: () async throws(Failure) -> T,
  onCancel handler: @Sendable () -> Void
) async rethrows -> T
```

### Task groups

The task group APIs also need to gain support for typed throws. The important
detail here is that there are two layers of failures involved. First, the
failures produced by the child task themselves. Secondly, the failure returned
by `withThrowingTaskGroup` API itself. We propose to add the following API:

```swift
public func withTaskGroup<ChildTaskResult, ChildTaskFailure: Error, GroupResult, GroupFailure: Error>(
  of childTaskResultType: ChildTaskResult.Type,
  childTaskFailureType: ChildTaskFailure.Type,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout ThrowingTaskGroup<ChildTaskResult, ChildTaskFailure>) async throws(GroupFailure) -> GroupResult
) async rethrows -> GroupResult
```

Additionally, we propose to add typed throws to following the
`ThrowingTaskGroup` APIs.

```swift
public mutating func next() async throws(Failure) -> ChildTaskResult?
public mutating func waitForAll() async throws(Failure)
```


### Task locals

`withValue` TODO

### MainActor

The `MainActor` provides a static rethrowing `run` method. This method can also
adopt typed throws:

```swift
public static func run<T: Sendable, Failure: Error>(
  resultType: T.Type = T.self,
  body: @MainActor @Sendable () throws(Failure) -> T
) async rethrows -> T
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
  __consuming func makeAsyncIterator() -> AsyncIterator
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
  _ elementType: Element.Type = Element.self,
  _ failureType: Failure.Type = Failure.self,
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

- AsyncThrowingCompactMapSequence
- AsyncThrowingDropWhileSequence
- AsyncThrowingFilterSequence
- AsyncThrowingFlatMapSequence
- AsyncThrowingMapSequence
- AsyncThrowingPrefixWhileSequence

TODO: All of those don't have a generic error type so we can't adopt typed throws for them.

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

TODO
