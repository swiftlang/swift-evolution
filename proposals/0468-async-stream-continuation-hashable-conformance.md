# `Hashable` conformance for `Async(Throwing)Stream.Continuation`

* Proposal: [SE-0468](0468-async-stream-continuation-hashable-conformance.md)
* Authors: [Mykola Pokhylets](https://github.com/nickolas-pohilets)
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Status: **Implemented (Swift 6.2)**
* Implementation: [swiftlang/swift#79457](https://github.com/swiftlang/swift/pull/79457)
* Review: ([pitch](https://forums.swift.org/t/pitch-add-hashable-conformance-to-asyncstream-continuation/77897)) ([review](https://forums.swift.org/t/se-0468-hashable-conformance-for-async-throwing-stream-continuation/78487)) ([acceptance](https://forums.swift.org/t/accepted-se-0468-hashable-conformance-for-async-throwing-stream-continuation/79116))

## Introduction

This proposal adds a `Hashable` conformance to `Async(Throwing)Stream.Continuation`
to simplify working with multiple streams.

## Motivation

Use cases operating with multiple `AsyncStream`s may need to store multiple continuations.
When handling `onTermination` callback, client code needs to remove the relevant continuation.

To identify the relevant continuation, client code needs to be able to compare continuations.

It is possible to associate a lookup key with each continuation, but this is inefficient.
`AsyncStream.Continuation` already stores a reference to `AsyncStream._Storage`,
whose identity can be used to provide simple and efficient `Hashable` conformance.

Consider this simple Observer pattern with an `AsyncSequence`-based API.
To avoid implementing `AsyncSequence` from scratch it uses `AsyncStream` as a building block.
To support multiple subscribers, a new stream is returned every time.

```swift
@MainActor private class Sender {
    var value: Int = 0 {
        didSet {
            for c in continuations {
                c.yield(value)
            }
        }
    }

    var values: some AsyncSequence<Int, Never> {
        AsyncStream<Int>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(value)
            self.continuations.insert(continuation)
            continuation.onTermination = { _ in
                DispatchQueue.main.async {
                    self.continuations.remove(continuation)
                }
            }
        }
    }

    private var continuations: Set<AsyncStream<Int>.Continuation> = []
}
```

Without a `Hashable` conformance, each continuation needs to be associated with an artificial identifier.
E.g. wrapping continuation in a class, identity of the wrapper object can be used:

```swift
@MainActor private class Sender {
    var value: Int = 0 {
        didSet {
            for c in continuations {
                c.value.yield(value)
            }
        }
    }

    var values: some AsyncSequence<Int, Never> {
        AsyncStream<Int> { (continuation: AsyncStream<Int>.Continuation) -> Void in
            continuation.yield(value)
            let box = ContinuationBox(value: continuation)
            self.continuations.insert(box)
            continuation.onTermination = { _ in
                DispatchQueue.main.async {
                    self.continuations.remove(box)
                }
            }
        }
    }

    private var continuations: Set<ContinuationBox> = []

    private final class ContinuationBox: Hashable, Sendable {
        let value: AsyncStream<Int>.Continuation

        init(value: AsyncStream<Int>.Continuation) {
            self.value = value
        }

        static func == (lhs: Sender.ContinuationBox, rhs: Sender.ContinuationBox) -> Bool {
            lhs === rhs
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }
    }
}
```

Note that capturing `continuation` or `box` in `onTermination` is safe, because `onTermination` is dropped after being called
(and it is _always_ called, even if `AsyncStream` is discarded without being iterated).

## Proposed solution

Add a `Hashable` conformance to `Async(Throwing)Stream.Continuation`.

## Detailed design

Every time when the `build` closure of the `Async(Throwing)Stream.init()` is called,
it receives a continuation distinct from all other continuations.
All copies of the same continuation should compare equal.
Yielding values or errors, finishing the stream, or cancelling iteration should not affect equality.
Assigning `onTermination` closures should not affect equality.

## Source compatibility

This is an additive change.

Retroactive conformances are unlikely to exist, because current public API of the `Async(Throwing)Stream.Continuation` 
does not provide anything that could be reasonably used to implement `Hashable` or `Equatable` conformances.

## ABI compatibility

This is an additive change. 

## Implications on adoption

Adopters will need a new version of the standard library.
