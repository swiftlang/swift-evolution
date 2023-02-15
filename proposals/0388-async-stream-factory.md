# Convenience Async[Throwing]Stream.makeStream methods

* Proposal: [SE-0388](0388-async-stream-factory.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: [Becca Royal-Gordon](https://github.com/beccadax)
* Status: **Active review (February 15...26, 2023)**
* Implementation: [apple/swift#62968](https://github.com/apple/swift/pull/62968)
* Review: ([pitch](https://forums.swift.org/t/pitch-convenience-async-throwing-stream-makestream-methods/61030)) ([review](https://forums.swift.org/t/se-0388-convenience-async-throwing-stream-makestream-methods/63139))

## Introduction

We propose introducing helper methods for creating `AsyncStream` and `AsyncThrowingStream`
instances which make the stream's continuation easier to access.

## Motivation

With [SE-0314](https://github.com/apple/swift-evolution/blob/main/proposals/0314-async-stream.md)
we introduced `AsyncStream` and `AsyncThrowingStream` which act as a root
`AsyncSequence` that the standard library offers.

After having used `Async[Throwing]Stream` for some time, a common usage
is to pass the continuation and the `Async[Throwing]Stream` to different places.
This requires escaping the `Async[Throwing]Stream.Continuation` out of 
the closure that is passed to the initialiser.
Escaping the continuation is slightly inconvenient since it requires a dance
around an implicitly unwrapped optional. Furthermore, the closure implies
that the continuation lifetime is scoped to the closure which it isn't. This is how
an example usage of the current `AsyncStream` API looks like.

```swift
var cont: AsyncStream<Int>.Continuation!
let stream = AsyncStream<Int> { cont = $0 }
// We have to assign the continuation to a let to avoid sendability warnings
let continuation = cont

await withTaskGroup(of: Void.self) { group in
  group.addTask {
    for i in 0...9 {
      continuation.yield(i)
    }
    continuation.finish()
  }

  group.addTask {
    for await i in stream {
      print(i)
    }
  }
}
```

## Proposed solution

In order to fill this gap, I propose to add a new static method `makeStream` on
`AsyncStream` and `AsyncThrowingStream` that returns both the stream
and the continuation. An example of using the new proposed convenience methods looks like this:

```swift
let newStream = AsyncStream.makeStream(of: Int.self)

await withTaskGroup(of: Void.self) { group in
  group.addTask {
    for i in 0...9 {
      newStream.continuation.yield(i)
    }
    newStream.continuation.finish()
  }

  group.addTask {
    for await i in newStream.stream {
      print(i)
    }
  }
}
```

## Detailed design

I propose to add the following code to `AsyncStream` and `AsyncThrowingStream`
respectively.

```swift
extension AsyncStream {
  /// Struct for the return type of ``AsyncStream/makeStream(of:bufferingPolicy:)``.
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

    private init(stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
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
  /// Struct for the return type of ``AsyncThrowingStream/makeStream(of:throwing:bufferingPolicy:)``.
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

    private init(stream: AsyncThrowingStream<Element, Failure>, continuation: AsyncThrowingStream<Element, Failure>.Continuation) {
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

## Source compatibility
This change is additive and does not affect source compatibility.

## Effect on ABI stability
This change introduces new concurrency library ABI in the form of the two `makeStream` methods and `NewStream` structs, but it does not affect the ABI of existing declarations.

## Effect on API resilience
None; adding nested types and static methods is permitted by the existing resilience model.

## Alternatives considered

### Return a tuple instead of a concrete type
My initial pitch was using a tuple as the result type of the factory;
however, I walked back on it since I think we can provide better documentation on
the concrete type. Furthermore, it makes it more discoverable as well.

The upside of using a tuple based approach is that we can backdeploy it. 

An implementation returning a tuple would look like this;

```swift
extension AsyncStream {
  /// Initializes a new ``AsyncStream`` and an ``AsyncStream/Continuation``.
  ///
  /// - Parameters:
  ///   - elementType: The element type of the stream.
  ///   - limit: The buffering policy that the stream should use.
  /// - Returns: A tuple which contains the stream and its continuation.
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

### Expose an initializer on the `NewStream` type
During the pitch it was brought up that we could expose an `init` on the `NewStream` types
that this proposal wants to add. I decided against that since one would have to spell out
`AsyncStream<Element>.NewStream()` to access the `init`. This is quite hard to discover in
my opinion.

### Pass a continuation to the `AsyncStream<Element>.init()`
During the pitch it was brought up that we could let users pass a continuation to the
`AsyncStream<Element>.init()`; however, this opens up a few problems:
1. A continuation could be passed to multiple streams
2. A continuation which is not passed to a stream is useless

In the end, the `AsyncStream.Continuation` is deeply coupled to one instance of an
`AsyncStream` hence we should create an API that conveys this coupling and prevents
users from misuse. 

### Do nothing alternative
We could just leave the current creation of `Async[Throwing]Stream` as is;
however, since it is part of the standard library we should provide
a better method to create a stream and its continuation.
