# Async/Await: Sequences

* Proposal: [SE-NNNN](Async-Await-Series.md.md)
* Authors: [Tony Parker](https://github.com/parkera), [Philippe Hausler](https://github.com/phausler)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: **TODO** [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)

## Introduction

Swift's proposed [async/await](https://github.com/DougGregor/swift-evolution/blob/async-await/proposals/nnnn-async-await.md) feature provides an intuitive, built-in way to write and use functions that return a single value at some future point in time. We propose building on top of this feature to create an intuitive, built-in way to write and use functions that return many values over time.

This proposal is composed of the following pieces:

1. A standard library definition of a protocol that represents an asynchronous sequence of values
2. Compiler support to use `for...in` syntax on an asynchronous sequence of values
3. A standard library implementation of commonly needed functions that operate on an asynchronous sequence of values

## Motivation

We'd like iterating over asynchronous sequences of values to be as easy as iterating over synchronous sequences of values. An example use case is iterating over the lines in a file, like this:

```swift
for await try line in myFile.lines() {
  // Do something with each line
}
```

Using the `for...in` syntax that Swift developers are already familiar with will reduce the barrier to entry when working with asynchronous APIs. Consistency with other Swift types and concepts is therefore one of our most important goals. The requirement of using the `await` keyword in this loop will distinguish it from synchronous sequences.
### `for/in` Syntax

To enable the use of `for in`, we must define the return type from `func lines()` to be something that the compiler understands can be iterated. Today, we have the `Sequence` protocol. Let's try to use it here:

```swift
extension URL {
  struct Lines: Sequence { /* ... */ }
  func lines() async -> Lines
}
```

Unfortunately, what this function actually does is wait until *all* lines are available before returning. What we really wanted in this case was to await *each* line. While it is possible to imagine modifications to `lines` to behave differently (e.g., giving the result reference semantics), it would be better to define a new protocol to make this iteration behavior as simple as possible.

```swift
extension URL {
  struct Lines: AsyncSequence { /* ... */ }
  func lines() async -> Lines
}
```

`AsyncSequence` allows for waiting on each element instead of the entire result by defining an asynchronous `next()` function on its associated iterator type.

### Additional AsyncSequence functions

Going one step further, let's imagine how it might look to use our new `lines` function in more places. Perhaps we only want the first line of a file because it contains a header that we are interested in:

```swift
let header: String?
do {
  for await try line in myFile.lines() {
    header = line
    break
  }
} catch {
  header = nil // file didn't exist
}
```

Or, perhaps we actually do want to read all lines in the file before starting our processing:

```swift
var allLines: [String] = []
do {
  for await try line in myFile.lines() {
    allLines.append(line)
  }
} catch {
  allLines = []
}
```

There's nothing wrong with the above code, and it must be possible for a developer to write it. However, it does seem like a lot of boilerplate for what might be a common operation. One way to solve this would be to add more functions to `URL`:

```swift
extension URL {
  struct Lines : AsyncSequence { }

  func lines() -> Lines
  func firstLine() throws async -> String?
  func collectLines() throws async -> [String]
}
```

It doesn't take much imagination to think of other places where we may want to do similar operations, though. Therefore, we believe the best place to put these functions is instead as an extension on `AsyncSequence` itself, specified generically -- just like `Sequence`.

## Proposed solution

The standard library will define the following protocols:

```swift
public protocol AsyncSequence {
  associatedtype AsyncIterator: AsyncIteratorProtocol where AsyncIterator.Element == Element
  associatedtype Element
  func makeAsyncIterator() -> AsyncIterator
}

public protocol AsyncIteratorProtocol {
  associatedtype Element
  mutating func next() async throws -> Element?
  __consuming mutating func cancel()
}
```

The compiler will generate code to allow use of a `for in` loop on any type which conforms with `AsyncSequence`. The standard library will also extend the protocol to provide familiar generic algorithms. Here is an example which does not actually call an `async` function within its `next`, but shows the basic shape:

```swift
struct Counter : AsyncSequence {
  let howHigh: Int

  struct AsyncIterator : AsyncIteratorProtocol {
    let howHigh: Int
    var current = 1
    mutating func next() async -> Int? {
      guard current <= howHigh else {
        return nil
      }

      let result = current
      current += 1
      return result
    }

    mutating func cancel() {
      current = howHigh + 1 // Make sure we do not emit another value
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    return AsyncIterator(howHigh: howHigh)
  }
}
```

At the call site, using `Counter` would look like this:

```swift
for await i in Counter(howHigh: 3) {
  print(i)
}

/* 
Prints the following, and finishes the loop:
1
2
3
*/


for await i in Counter(howHigh: 3) {
  print(i)
  if i == 2 { break }
}
/*
Prints the following, then calls cancel before breaking out of the loop:
1
2
*/
```

Any other exit (e.g., `return` or `throw`) from the `for` loop will also call `cancel` first.

## Detailed design

Returning to our earlier example:

```swift
for await try line in myFile.lines() {
  // Do something with each line
}
```

The compiler will emit the equivalent of the following code:

```swift
var it = myFile.lines().makeAsyncIterator()
while let value = await try it.next() {
  // Do something with each line
}
```

All of the usual rules about error handling apply. For example, this iteration must be surrounded by `do/catch`, or be inside a `throws` function to handle the error. All of the usual rules about `await` also apply. For example, this iteration must be inside a context in which calling `await` is allowed like an `async` function.

### Cancellation

If `next()` returns `nil` then the iteration ends naturally and the compiler does not insert a call to `cancel()`.  If `next()` throws an error, then iteration also ends and the compiler does not insert a call to `cancel()`. In both of these cases, it was the `AsyncSequence` itself which decided to end iteration and there is no need to tell it to cancel.

If, inside the body of the loop, the code calls `break`, `return` or `throw`, then the compiler first inserts a synchronous call to `cancel()` on the `it` iterator.

If this iteration is itself in a context in which cancellation can occur, then it is up to the developer to check for cancellation themselves and break out of the loop:

```swift
for await try line in myFile.lines() {
  // Do something
  ...
  // Check for cancellation
  await try Task.checkCancellation()
}
```

In this case, control of cancellation (which is a potential suspension point, and may be something to do either before or after receiving a value) is up to the author of the code.

#### Cancellation on Reference Types

If the `AsyncIterator` is a `class` type, it should assume that `deinit` is equivalent to calling `cancel`. This will prevent leaking of resources in cases where the iterator is used manually and `cancel` is not called. It also provides a future-proofing path for move-only iterators.
#### Automatic Cancellation

"Automatic" calls to `cancel` are conceptually compatible with `defer`. Given the following code:

```swift
for await x in seq {
  // code
}
```

The compiler generates code equivalent to this:

```swift
do {
  var $_iterator = seq.makeAsyncIterator()
  var $_element: Element? = await $_iterator.next()
  defer { if $_element != nil { $_iterator.cancel() } }
  while let x = $_element {
    // code
    $_element = await $_iterator.next()
  }
}
```

### Rethrows

This proposal will take advantage of a separate proposal to add specialized `rethrows` conformance in a protocol, pitched [here](https://forums.swift.org/t/pitch-rethrowing-protocol-conformances/42373). With the changes proposed there for `rethrows`, it will not be required to use `try` when iterating an `AsyncSequence` which does not itself throw.

The `await` is always required because the definition of the protocol is that it is always asynchronous.

## AsyncSequence Functions

The existence of a standard `AsyncSequence` protocol allows us to write generic algorithms for any type that conforms to it. There are two categories of functions: those that return a single value (and are thus marked as `async`), and those that return a new `AsyncSequence` (and are not marked as `async` themselves).

The functions that return a single value are especially interesting because they increase usability by changing a loop into a single `await` line. Functions in this category are `first`, `contains`, `count`, `min`, `max`, `reduce`, and more. Functions that return a new `AsyncSequence` include `filter`, `map`, and `compactMap`.

### AsyncSequence to single value

Algorithms that reduce a for loop into a single call can improve readability of code. They remove the boilerplate required to set up and iterate a loop.

For example, here is the `first` function:

```swift
extension AsyncSequence {
  public func first() async rethrows -> Element?
}
```

With this extension, our "first line" example from earlier becomes simply:

```swift
let first = await try? myFile.lines().first()
```

The following functions will be added to `AsyncSequence`:

| Function | Note |
| - | - |
| `contains(_ value: Element) async rethrows -> Bool` | Requires `Equatable` element |
| `contains(where: (Element) async throws -> Bool) async rethrows -> Bool` | The `async` on the closure allows optional async behavior, but does not require it |
| `allSatisfy(_ predicate: (Element) async throws -> Bool) async rethrows -> Bool` | |
| `first(where: (Element) async throws -> Bool) async rethrows -> Element?` | |
| `first() async rethrows -> Element?` | Not a property since properties cannot `throw` |
| `min() async rethrows -> Element?` | Requires `Comparable` element |
| `min(by: (Element, Element) async throws -> Bool) async rethrows -> Element?` | |
| `max() async rethrows -> Element?` | Requires `Comparable` element |
| `max(by: (Element, Element) async throws -> Bool) async rethrows -> Element?` | |
| `reduce<T>(_ initialResult: T, _ nextPartialResult: (T, Element) async throws -> T) async rethrows -> T` | |
| `reduce<T>(into initialResult: T, _ updateAccumulatingResult: (inout T, Element) async throws -> ()) async rethrows -> T` | |

### AsyncSequence to AsyncSequence

These functions on `AsyncSequence` return a result which is itself an `AsyncSequence`. Due to the asynchronous nature of `AsyncSequence`, the behavior is similar in many ways to the existing `Lazy` types in the standard library. Calling these functions does not eagerly `await` the next value in the sequence, leaving it up to the caller to decide when to start that work by simply starting iteration when they are ready.

As an example, let's look at `map`:

```swift
extension AsyncSequence {
  public func map<Transformed>(
    _ transform: @escaping (Element) async throws -> Transformed
  ) -> AsyncMapSequence<Self, Transformed>
}

public struct AsyncMapSequence<Upstream: AsyncSequence, Transformed>: AsyncSequence {
  public let upstream: Upstream
  public let transform: (Upstream.Element) async throws -> Transformed
  public struct Iterator : AsyncIterator { 
    public mutating func next() async rethrows -> Transformed?
    public mutating func cancel()
  }
}
```

For each of these functions, we first define a type which conforms with the `AsyncSequence` protocol. The name is modeled after existing standard library `Sequence` types like `LazyDropWhileCollection` and `LazyMapSequence`. Then, we add a function in an extension on `AsyncSequence` which creates the new type (using `self` as the `upstream`) and returns it.

| Function |
| - |
| `map<T>(_ transform: (Element) async throws -> T) -> AsyncMapSequence` |
| `compactMap<T>(_ transform: (Element) async throws -> T?) -> AsyncCompactMapSequence` |
| `flatMap<SegmentOfResult: AsyncSequence>(_ transform: (Element) async throws -> SegmentOfResult) async rethrows -> AsyncFlatMapSequence` |
| `drop(while: (Element) async throws -> Bool) async rethrows -> AsyncDropWhileSequence` |
| `dropFirst(_ n: Int) async rethrows -> AsyncDropFirstSequence` |
| `prefix(while: (Element) async throws -> Bool) async rethrows -> AsyncPrefixWhileSequence` |
| `prefix(_ n: Int) async rethrows -> AsyncPrefixSequence` |
| `filter(_ predicate: (Element) async throws -> Bool) async rethrows -> AsyncFilterSequence` |

## Future Proposals

The following topics are things we consider important and worth discussion in future proposals:
### Additional `AsyncSequence` functions

We've aimed for parity with the most relevant `Sequence` functions. There may be others that are worth adding in a future proposal.

API which uses a time argument must be coordinated with the discussion about `Executor` as part of the [structured concurrency proposal](https://github.com/DougGregor/swift-evolution/blob/structured-concurrency/proposals/nnnn-structured-concurrency.md).

### AsyncSequence Builder

In the standard library we have not only the `Sequence` and `Collection` protocols, but concrete types which adopt them (for example, `Array`). We will need a similar API for `AsyncSequence` that makes it easy to construct a concrete instance when needed, without declaring a new type and adding protocol conformance.

## Source compatibility

This new functionality will be source compatible with existing Swift.

## Effect on ABI stability

This change is additive to the ABI.

## Effect on API resilience

This change is additive to API.

## Alternatives considered

### Asynchronous cancellation

The `cancel()` function on the iterator could be marked as `async`. However, this means that the implicit cancellation done when leaving a `for/in` loop would require an implicit `await` -- something we think is probably too much to hide from the developer. Most cancellation behavior is going to be as simple as setting a flag to check later, so we leave it as a synchronous function and encourage adopters to make cancellation fast and non-blocking.
### Opaque Types

Each `AsyncSequence`-to-`AsyncSequence` algorithm will define its own concrete type. We could attempt to hide these details behind a general purpose type eraser. We believe leaving the types exposed gives us (and the compiler) more optimization opportunities. A great future enhancement would be for the language to support `some AsyncSequence where Element=...`-style syntax, allowing hiding of concrete `AsyncSequence` types at API boundaries.

### Reusing Sequence

If the language supported a `reasync` concept, then it seems plausible that the `AsyncSequence` and `Sequence` APIs could be merged. However, we believe it is still valuable to consider these as two different types. The added complexity of a time dimension in asynchronous code means that some functions need more configuration options or more complex implementations. Some algorithms that are useful on asynchronous sequences are not meaningful on synchronous ones. We prefer not to complicate the API surface of the synchronous collection types in these cases.

### Naming

The names of the concrete `AsyncSequence` types is designed to mirror existing standard library API like `LazyMapSequence`. Another option is to introduce a new pattern with an empty enum or other namespacing mechanism.

We considered `AsyncGenerator` but would prefer to leave the `Generator` name for future language enhancements. `Stream` is a type in Foundation, so we did not reuse it here to avoid confusion.

### `await in`

We considered a shorter syntax of `await...in`. However, since the behavior here is fundamentally a loop, we feel it is important to use the existing `for` keyword as a strong signal of intent to readers of the code. Although there are a lot of keywords, each one has purpose and meaning to readers of the code.

### Add APIs to iterator instead of sequence

We discussed applying the fundamental API (`map`, `reduce`, etc.) to the `AsyncIterator` protocol instead of `AsyncSequence`. There has been a long-standing (albeit deliberate) ambiguity in the `Sequence` API -- is it supposed to be single-pass or multi-pass? This new kind of iterator & sequence could provide an opportunity to define this more concretely.

While it is tempting to use this new API to right past wrongs, we maintain that the high level goal of consistency with existing Swift concepts is more important. 

For example, `for...in` cannot be used on an `Iterator` -- only a `Sequence`. If we chose to make `AsyncIterator` use `for...in` as described here, that leaves us with the choice of either introducing an inconsistency between `AsyncIterator` and `Iterator` or giving up on the familiar `for...in` syntax. Even if we decided to add `for...in` to `Iterator`, it would still be inconsistent because we would be required to leave `for...in` syntax on the existing `Sequence`.

Another point in favor of consistency is that implementing an `AsyncSequence` should feel familiar to anyone who knows how to implement a `Sequence`.

We are hoping for widespread adoption of the protocol in API which would normally have instead used a `Notification`, informational delegate pattern, or multi-callback closure argument. In many of these cases we feel like the API should return the 'factory type' (an `AsyncSequence`) so that it can be iterated again. It will still be up to the caller to be aware of any underlying cost of performing that operation, as with iteration of any `Sequence` today.

### Move-only iterator and removing Cancel

We discussed waiting to introduce this feature until move-only types are available in the future. This is a tradeoff in which we look to the Core Team for advice, but the authors believe the benefit of having this functionality now has the edge. It will likely be the case that move-only types will bring changes to other `Sequence` and `Iterator` types when it arrives in any case.

Prototyping of the patch does not seem to indicate undue complexity in the compiler implementation. In fact, it appears that the existing ideas around `defer` actually match this concept cleanly. 

We have included a `__consuming` attribute on the `cancel` function, which should allow move-only iterators to exist in the future.
