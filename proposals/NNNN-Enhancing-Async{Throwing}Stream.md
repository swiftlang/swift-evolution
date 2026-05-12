# Enhancing `Async{Throwing}Stream`

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [NotTheNHK](https://github.com/NotTheNHK)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Implementation: TBD
* Upcoming Feature Flag: StreamContinuationTracking
* Review: ([pitch](https://forums.swift.org/t/pitch-enhancing-async-throwing-stream/86339))

## Summary of changes

This proposal introduces the following changes:

1. Typed throws support for `AsyncThrowingStream`.
2. Update the unfolding initializer by adopting `nonisolated(nonsending)` and replacing `onCancel`’s `@Sendable` requirement with `sending`.
3. Terminate the stream when its continuation is discarded.
4. `Hashable` conformance for `Async{Throwing}Stream` and nested types.

## Motivation

### Typed Throws

Thrown errors are type-erased to `any Error`, requiring additional boilerplate to preserve the thrown error's type and integrate into typed contexts.

```swift
let locationStream = AsyncThrowingStream<Location, LocationError> { ... } // Error: Initializer 'init(_:bufferingPolicy:_:)' requires the types 'LocationError' and 'any Error' be equivalent

func processLocations() async throws(LocationError) {
  for try await location in locationStream { // Error: Thrown expression type 'any Error' cannot be converted to error type 'LocationError'
    ...
  }
}
```

There are two suboptimal workarounds.

1. Type cast:

```swift
let locationStream = AsyncThrowingStream<Location, any Error> { ... }

func processLocations() async throws(LocationError) {
  do {
    for try await location in locationStream {
      ...
    }
  } catch {
    throw error as! LocationError
  }
}
```

2. Result type:

```swift
let locationStream = AsyncStream<Result<Location, LocationError>> { ... }

func processLocations() async throws(LocationError) {
  for await result in locationStream {
    switch result {
    case .success(let location):
      ...
    case .failure(let locationError):
      throw locationError
    }
  }
}
```

### Unfolding initializer

[SE-0314](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0314-async-stream.md#detailed-design) proposed the following Unfolding initializers:

```swift
// AsyncStream
public init(
  unfolding produce: @escaping () async -> Element?, 
  onCancel: (@Sendable () -> Void)? = nil
)

// AsyncThrowingStream
public init(
  unfolding produce: @escaping () async throws -> Element?, 
  onCancel: (@Sendable () -> Void)? = nil
)
```

However, the `AsyncThrowingStream` variant was never implemented with an `onCancel` parameter, creating a discrepancy between the two APIs. 

Furthermore, [SE-0338](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md#proposed-solution) clarified the execution semantics of `nonisolated` asynchronous functions by specifying that such functions formally run on the Global Concurrent Executor (GCE), potentially introducing unnecessary actor hops. 

Additionally, the `@Sendable` requirement on `onCancel` is overly restrictive, as `onCancel` is invoked at most once and never concurrently with itself.

```swift
let stream = AsyncStream {
  ...
} onCancel: {
  ...
}

let throwingStream = AsyncThrowingStream {
  ...
} // no `onCancel` parameter

func process(on locationActor: isolated LocationActor) { // starts running on `locationActor`
  let locationStream = AsyncStream<Location> { ... }

  for await location in locationStream { // implicit call to `produce`, hop off `locationActor`
    locationActor.update(location) // hop back on `locationActor`
  }
}
```

The `process(on:)` function is actor-isolated to its `locationActor` parameter.
This means its formal isolation is that of the passed-in actor instance. However, the for await-in loop implicitly calls the `nonisolated` asynchronous `produce` function-type parameter to receive the next element. 

As a result, `process(on:)` continuously hops off and back onto `locationActor` for each iteration.

### Continuation and Stream Termination

When the continuation of an active stream is discarded, task cancellation becomes the only way to terminate the stream.

```swift
let stream = AsyncStream<Int> { continuation in
  continuation.onTermination = { reason in 
    print(reason)
  }

  for number in 0..<10 {
    continuation.yield(number)
  }
} // continuation discarded here

for await element in stream { // indefinitely suspended
  print(element) // prints: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
} 
```

Unless the consumer's task is cancelled, the for await-in loop remains indefinitely suspended.

### `Hashable` conformance

Extending `Hashable` conformance to `Async{Throwing}Stream` and its nested types would allow them to be used as stored properties or associated values in `Hashable`-conforming types, as `Dictionary` keys, and as elements of `Set`s.

The inherited `Equatable` conformance from `Hashable` enables equality comparisons, which can be useful for testing.

## Proposed solution

### Typed Throws

`AsyncThrowingStream` already defines a type parameter `Failure: Error`. Until now, `Failure` has been constrained to `any Error`. 

This proposal extends `AsyncThrowingStream` with new unconstrained initializers and a `makeStream` method, eliminating existing boilerplate and enabling seamless use in typed contexts. However, the existing `Failure == any Error` constraint cannot be lifted without breaking backward compatibility.

```swift
let locationStream = AsyncThrowingStream<Location, LocationError> { ... }

func processLocations() async throws(LocationError) {
  for try await location in locationStream {
    ...
  }
}
```

### Unfolding Initializer

This proposal adds an `onCancel` parameter to the unfolding initializer of `AsyncThrowingStream`, aligning it with `AsyncStream` and with the original variant proposed in SE-0314.

Additionally, this proposal adopts `nonisolated(nonsending)`. As described in [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md), this allows the `produce` closure to run on the caller’s actor, avoiding unnecessary actor hops.

The `@Sendable` requirement on the `onCancel` closure is removed and replaced with the `sending` keyword.

```swift
let locationStream = Async{Throwing}Stream { // consistent API
  ...
} onCancel: {
  ...
}

for {try} await location in locationStream { // executes on the caller's actor
  ...
}
```

### Stream termination when its continuation is discarded

The continuation-based variant is updated to track outstanding references to the stream’s continuation, including the continuation itself and any copies of it. When the last reference to the continuation is discarded, the stream is canceled. 

The change is staged in via an upcoming feature flag (`StreamContinuationTracking`).

```swift
let stream = AsyncStream<Int> { continuation in
  continuation.onTermination = { reason in 
    print(reason)
  }

  for number in 0..<10 {
    continuation.yield(number)
  }
} // continuation discarded here

for await element in stream {
  print(element) // prints: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
} // `onTermination` invoked with `.cancelled`
```

`stream` is canceled after the for-in loop completes, since the continuation is discarded.

## Detailed design

Updated:

```swift
extension AsyncStream {
  init(
    unfolding produce: nonisolated(nonsending) @escaping @Sendable () async -> Element?,
    onCancel: sending (() -> Void)? = nil
  )
}

extension AsyncThrowingStream {
  public init(
    unfolding produce: nonisolated(nonsending) @escaping @Sendable () async throws(Failure) -> Element?,
    onCancel: sending (() -> Void)? = nil
  ) where Failure == any Error
}
```

New:

```swift
extension AsyncThrowingStream {
  public init(
    unfolding produce: nonisolated(nonsending) @escaping @Sendable () async throws(Failure) -> Element?,
    onCancel: sending (() -> Void)? = nil
  )

  public init(
    of elementType: Element.Type = Element.self,
    throwing failureType: Failure.Type = Failure.self,
    bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded,
    _ build: (Continuation) -> Void
  )

  public static func makeStream(
    of elementType: Element.Type = Element.self,
    throwing failureType: Failure.Type = Failure.self,
    bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
  ) -> (stream: AsyncThrowingStream<Element, Failure>, continuation: AsyncThrowingStream<Element, Failure>.Continuation)
}
```

`Hashable` conformance:

```swift
// AsyncStream

extension AsyncStream: Hashable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    // ... 
  }

  public func hash(into hasher: inout Hasher) {
    // ...
  }
}

extension AsyncStream.Continuation.BufferingPolicy: Hashable {}

extension AsyncStream.Continuation.YieldResult: Equatable, Hashable where Element: Equatable, Element: Hashable {}

// AsyncThrowingStream

extension AsyncThrowingStream: Hashable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    return lhs.context === rhs.context
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self.context))
  }
}

extension AsyncThrowingStream.Continuation.BufferingPolicy: Hashable {}

extension AsyncThrowingStream.Continuation.YieldResult: Equatable, Hashable where Element: Equatable, Element: Hashable {}

extension AsyncThrowingStream.Continuation.Termination: Equatable, Hashable where Failure: Hashable, Failure: Equatable {}
```

## Source compatibility

This proposal changes the behavior around stream termination when the stream’s continuation is discarded. To avoid silently changing behavior, this change is gated behind an upcoming feature flag (`StreamContinuationTracking`).

The `sending` keyword on `onCancel` will allow a wider range of functions and closures to be passed to it.

## ABI compatibility

Adopting `nonisolated(nonsending)` for `produce` and replacing `@Sendable` on `onCancel` is an ABI change. // TODO: Finish this

## Implications on adoption

Terminating the stream implicitly when the stream’s continuation is discarded would break code that relies on the current behavior, for example to create an indefinite suspension point.

## Future directions

### `~Copyable` Support

In principle, it should be possible to support `~Copyable` types. But, several blockers currently prevent their adoption. 
The key issue is the lack of support for iterating over a `~Copyable` sequence. 
It is not as simple as declaring `{Async}Sequence`’s `Element` associated type as `~Copyable`. Changes to the compiler would be required.

However, progress is being made in other areas. Swift Collections now includes multiple types that support `~Copyable` elements, such as `UniqueDeque` and, `UniqueArray`. There is also ongoing discussion about moving `UniqueArray` into the standard library. In addition, [SE-0528](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0528-noncopyable-continuation.md) introduced a `~Copyable` continuation type.

## Alternatives considered
An alternative approach to staging in change Nr. 3 (“Terminate the stream when its continuation is discarded”) via an upcoming feature flag 
is to introduce a new continuation-based initializer and `makeStream` method that explicitly signals this new behavior to the user.

There are three problems with this approach:

1. It would require introducing five additional initializer overloads and two `makeStream` methods.
2. To disambiguate them, this would require adding some form of clear differentiation.
3. It would not help with staging in the new behavior, as users of the API would need to switch to the new, more verbose, API 
and the old, less verbose, API would eventually need to be deprecated.

## Acknowledgments
I would like to thank @jamieQ for initial guidance and continued feedback, as well as @phausler and @FranzBusch for their feedback.
