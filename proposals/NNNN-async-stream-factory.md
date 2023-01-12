# Convenience Async[Throwing]Stream.makeStream methods

* Proposal: [SE-NNNN](NNNN-async-stream-factory.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: [Becca Royal-Gordon](https://github.com/beccadax)
* Status: **Awaiting review**
* Pitch: [Convenience Async[Throwing]Stream.makeStream methods](https://forums.swift.org/t/pitch-convenience-async-throwing-stream-makestream-methods/61030)
* Implementation: [apple/swift#62968](https://github.com/apple/swift/pull/62968)

<details>
<summary><b>Revision history</b></summary>

|            |                                                   |
| ---------- | ------------------------------------------------- |
| 2022-10-26 | Initial pitch.                                    |
| 2023-01-12 | Switch to concrete return type                    |

</details>

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
around an implicitly unwrapped optional. Furthermore, the closure implies
that the continuation lifetime is scoped to the closure which it isn't.

## Proposed solution

In order to fill this gap, I propose to add a new static method `makeStream` on
`AsyncStream` and `AsyncThrowingStream` that returns both the stream
and the continuation.

## Detailed design

I propose to add the following code to `AsyncStream` and `AsyncThrowingStream`
respectively.

```swift
extension AsyncStream {
  /// Struct for the return type of ``AsyncStream/makeStream(elementType:limit:)``.
  ///
  /// This struct contains two properties:
  /// 1. The ``continuation`` which should be retained by the producer and is used
  /// to yield new elements to the stream and finish it.
  /// 2. The ``stream`` which is the actual ``AsyncStream`` and
  /// should be passed to the consumer.
  public struct NewStream: Sendable {
    /// The continuation of the ``AsyncStream`` used to yield and finish.
    public let continuation: AsyncStream<Element>.Continuation

    /// The stream which should be passed to the consumer.
    public let stream: AsyncStream<Element>

    public init(stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
      self.stream = stream
      self.continuation = continuation
    }
  }

  /// Initializes a new ``AsyncStream`` and an ``AsyncStream/Continuation``.
  ///
  /// - Parameters:
  ///   - elementType: The element type of the stream.
  ///   - limit: The buffering policy that the stream should use.
  /// - Returns: A ``NewStream`` struct which contains the stream and its continuation.
  public static func makeStream(
      of elementType: Element.Type = Element.self,
      bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
  ) -> NewStream {
    let storage: _Storage = .create(limit: limit)
    let stream = AsyncStream<Element>(storage: storage)
    let continuation = Continuation(storage: storage)
    return .init(stream: stream, continuation: continuation)
  }
}

extension AsyncThrowingStream {
  /// Struct for the return type of ``AsyncThrowingStream/makeStream(elementType:limit:)``.
  ///
  /// This struct contains two properties:
  /// 1. The ``continuation`` which should be retained by the producer and is used
  /// to yield new elements to the stream and finish it.
  /// 2. The ``stream`` which is the actual ``AsyncThrowingStream`` and
  /// should be passed to the consumer.
  public struct NewStream: Sendable {
    /// The continuation of the ``AsyncThrowingStream`` used to yield and finish.
    public let continuation: AsyncThrowingStream<Element, Failure>.Continuation

    /// The stream which should be passed to the consumer.
    public let stream: AsyncThrowingStream<Element, Failure>

    public init(stream: AsyncThrowingStream<Element, Failure>, continuation: AsyncThrowingStream<Element, Failure>.Continuation) {
      self.stream = stream
      self.continuation = continuation
    }
  }

  /// Initializes a new ``AsyncThrowingStream`` and an ``AsyncThrowingStream/Continuation``.
  ///
  /// - Parameters:
  ///   - elementType: The element type of the stream.
  ///   - failureType: The failure type of the stream.
  ///   - limit: The buffering policy that the stream should use.
  /// - Returns: A ``NewStream`` struct which contains the stream and its continuation.
  public static func makeStream(
      of elementType: Element.Type = Element.self,
      throwing failureType: Failure.Type = Failure.self,
      bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
  ) -> NewStream {
    let storage: _Storage = .create(limit: limit)
    let stream = AsyncThrowingStream<Element, Failure>(storage: storage)
    let continuation = Continuation(storage: storage)
    return .init(stream: stream, continuation: continuation)
  }
}
```

## Source compatibility, Effect on ABI stability, Effect on API resilience

As this is an additive change, it should not have any compatibility, stability or resilience problems. The only potential problem would be if someone has already run into this shortcoming and decided to define their own `makeStream` methods.

## Alternatives considered

### Return a tuple instead of a concrete type
My initial pitch was using a tuple as the return paramter of the factory;
however, I walked back on it since I think we can provide better documentation on
the concrete type. Furthermore, it makes it more discoverable as well.

The upside of using a tuple based approach is that we can backdeploy it. 

An implementation returning a tuple would look like this;

```swift
extension AsyncStream 
  /// Initializes a new ``AsyncStream`` and an ``AsyncStream/Continuation``.
  ///
  /// - Parameters:
  ///   - elementType: The element type of the stream.
  ///   - limit: The buffering policy that the stream should use.
  /// - Returns: A tuple which contains the stream and its continuation.
  @available(SwiftStdlib 5.8, *)
  public static func makeStream(
      of elementType: Element.Type = Element.self,
      bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
  ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
    let storage: _Storage = .create(limit: limit)
    let stream = AsyncStream<Element>(storage: storage)
    let continuation = Continuation(storage: storage)
    return (stream: stream, continuation: continuation)
  }
}
```

### Do nothing alternative
We could just leave the current creation of `Async[Throwing]Stream` as is;
however, since it is part of the standard library we should provide
a better method to create a stream and its continuation.