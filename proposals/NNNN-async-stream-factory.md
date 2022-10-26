# Convenience Async[Throwing]Stream.makeStream methods

* Proposal: [SE-NNNN](NNNN-async-stream-factory.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Awaiting implementation**


## Introduction

With [SE-0314](https://github.com/apple/swift-evolution/blob/main/proposals/0314-async-stream.md)
we introduced `AsyncStream` and `AsyncThrowingStream` which act as a source
`AsyncSequence` that the standard library offers.

## Motivation

After having used `Async[Throwing]Stream` for some time, a common usage
is to pass the continuation and the `Async[Throwing]Stream` to different places.
This requires escaping the `Async[Throwing]Stream.Continuation` out of 
the closure that is passed to the initialiser.
Escaping the continuation is slightly inconvenient since it requires a dance
around an implicitly unwrapped optional.

## Proposed solution

In order to fill this gap, I propose to add a new static method `makeStream` on
`AsyncStream` and `AsyncThrowingStream` that returns both the stream
and the continuation.

## Detailed design

I propose to add the following code to `AsyncStream` and `AsyncThrowingStream`
respectively.

```swift
extension AsyncStream {
  /// Initializes a new ``AsyncStream`` and an ``AsyncStream/Continuation``.
  ///
  /// - Parameters:
  ///   - elementType: The element type of the sequence.
  ///   - limit: The buffering policy that the stream should use.
  /// - Returns: A tuple which contains the stream and its continuation.
  @_alwaysEmitIntoClient
  public static func makeStream(
      of elementType: Element.Type = Element.self,
      bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
  ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
    let storage: _Storage = .create(limit)
    let stream = AsyncStream<Element>(storage: storage)
    let continuation = Continuation(storage)
    return (stream: stream, continuation: continuation)
  }

  @_alwaysEmitIntoClient
  init(storage: _Storage) {
    self.context = _Context(storage: storage, produce: storage.next)
  }
}

extension AsyncThrowingStream {
  /// Initializes a new ``AsyncThrowingStream`` and an ``AsyncThrowingStream/Continuation``.
  ///
  /// - Parameters:
  ///   - elementType: The element type of the sequence.
  ///   - failureType: The failure type of the stream.
  ///   - limit: The buffering policy that the stream should use.
  /// - Returns: A tuple which contains the stream and its continuation.
  @_alwaysEmitIntoClient
  public static func makeStream(
      of elementType: Element.Type = Element.self,
      throwing failureType: Failure.Type = Failure.self,
      bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
  ) -> (stream: AsyncThrowingStream<Element, Failure>, continuation: AsyncThrowingStream<Element, Failure>.Continuation) {
    let storage: _Storage = .create(limit)
    let stream = AsyncThrowingStream<Element, Failure>(storage: storage)
    let continuation = Continuation(storage)
    return (stream: stream, continuation: continuation)
  }

  @_alwaysEmitIntoClient
  init(storage: _Storage) {
    self.context = _Context(storage: storage, produce: storage.next)
  }
}
```

## Source compatibility, Effect on ABI stability, Effect on API resilience

As this is an additive change, it should not have any compatibility, stability or resilience problems. The only potential problem would be if someone has already run into this shortcoming and decided to define their own `makeStream` methods.

## Alternatives considered

### Return a concrete type instead of a tuple
My initial proposal was using a concrete type as the return paramter of the factory;
however, I walked back on it since back deployment issues were raised with introducing a new type.

I still believe that there is value in providing a concrete type since 
it is easier to handle than a tuple and documentation can be provided in a nice way.

```swift
extension AsyncStream {
  /// Simple struct for the return type of ``AsyncStream/makeStream(elementType:)``.
  public struct NewStream {
    /// The actual stream.
    public let stream: AsyncStream<Element>
    /// The continuation of the stream
    public let continuation: AsyncStream<Element>.Continuation

    @inlinable
    internal init(
        stream: AsyncStream<Element>,
        continuation: AsyncStream<Element>.Continuation
    ) {
        self.stream = stream
        self.continuation = continuation
    }
  }
```

### Do nothing alternative
We could just leave the current creation of `Async[Throwing]Stream` as is;
however, since it is part of the standard library we should provide
a better method to create a stream and its continuation.