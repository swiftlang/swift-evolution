# Map Sorting

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Draft**
* Implementation: [apple/swift#23156](https://github.com/apple/swift/pull/23156)

## Introduction

This proposal presents an addition to the Standard Library in an effort to make map sorting and, eventually, closureless key-path sorting a functional prerequisite for Swift.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/map-sorting/21421)

## Motivation

A straightforward way to sort a collection over a `Comparable` property of its `Element` type is to use a regular predicate, welding together the accessing and comparison of values.

```swift
struct Person {
    ...
    var age: Int
}

struct Chat {
    ...
    var lastMsg: Message
}

var people: [Person] = ...
var chats: [Chat] = ...

people.sort { $0.age < $1.age }
chats.sort { $0.lastMsg.date > $1.lastMsg.date }
```

Most often, however, all we need to determine sorting is a key-path on an element. Other times, a comparison closure on its own happens to be inconvenient or inefficient: the base metric might be obtained through non-trivial computation, where a predicate alone instigates code duplication and makes it harder to spot the sorting order. When the values are expensive to retrieve, the predicate obscuring the computations also becomes a major obstacle for optimizations, such as trading memory for speed to warrant that each value is computed once per element rather than O(nlogn) times. For clarity, applying the latter to a ϴ(n) operation theoretically speeds sorting up by a factor of 10 for an array of 1000 elements; in reality, the difference is even greater. The goal is therefore to introduce an API that decouples the comparison of values from their calculations, favouring optimizations and bringing ergonomic advantages for an ample range of cases.

## Proposed solution

Add an overload for both the non-mutating `sorted` and in-place `sort` methods on `Sequence` and `MutableCollection` respectively. A mapping closure on `Element` will lead the argument list, followed by the well known `areInIncreasingOrder` predicate and, finally, a flag that triggers the already mentioned [Schwarzian Transform](https://en.wikipedia.org/wiki/Schwartzian_transform) optimization. `transform` is positioned before the predicate specifically because the latter is type-dependent on and logically precedes the former, meaning, above all, fundamental type-checker and autocompletion support. Here are some example usages:

```swift
chats.sort(on: { $0.lastMsg.date }, by: >)
fileUnits.sort(
  on: { $0.raw.count(of: "func") },
  by: <,
  isExpensiveTransform: true
)
```


### Implementation

```swift
extension Sequence {

  @inlinable
  public func sorted<Value>(
    on transform: (Element) throws -> Value,
    by areInIncreasingOrder: (Value, Value) throws -> Bool,
    isExpensiveTransform: Bool = false
  ) rethrows -> [Element] {
    guard isExpensiveTransform else {
      return try sorted {
        try areInIncreasingOrder(transform($0), transform($1))
      }
    }
    var pairs = try map {
      try (element: $0, value: transform($0))
    }
    try pairs.sort {
      try areInIncreasingOrder($0.value, $1.value)
    }

    return pairs.map { $0.element }
  }
}

extension MutableCollection where Self: RandomAccessCollection {

  @inlinable
  public mutating func sort<Value>(
    on transform: (Element) throws -> Value,
    by areInIncreasingOrder: (Value, Value) throws -> Bool,
    isExpensiveTransform: Bool = false
  ) rethrows {
    guard isExpensiveTransform else {
      return try sort {
        try areInIncreasingOrder(transform($0), transform($1))
      }
    }
    var pairs = try map {
      try (element: $0, value: transform($0))
    }
    try pairs.sort {
      try areInIncreasingOrder($0.value, $1.value)
    }

    for (i, j) in zip(indices, pairs.indices) {
      self[i] = pairs[j].element
    }
  }
}
```

## Source compatibility & ABI stability

This is an ABI-compatible addition with no impact on source compatibility.

## Alternatives considered

### Why not key-paths?

**Swift 4** key-path expressions enable us to get rid of the closure and hence retain the argument label, giving the call a surprising resemblance to actual human language:

```swift
people.sort(by: \.age)
chats.sort(by: \.lastMsg.date, >)
``` 

Like [`sort()`](https://developer.apple.com/documentation/swift/mutablecollection/2802575-sort)
and [`sorted()`](https://developer.apple.com/documentation/swift/sequence/1641066-sorted), key-path sorting is a highly common practice and a fundamental case that deserves some out-of-the-box convenience. The only issue with focusing solely on key-paths in an ABI-stable world is that we risk API sprawl by neglecting custom transforms, whereas the generalized approach is both flexible and provident in leaving space for key-paths [were we to support implicit key-path-to-function conversions](https://github.com/apple/swift-evolution/pull/977) sometime in the future. Ideally, swapping property-based transforms for key-paths will be a matter of style.

```swift
chats.sort(on: { $0.lastMsg.date }, by: >)
chats.sort(on: \.lastMsg.date, by: >)
```

### Argument label naming  

* people.sort(over: { $0.age }, by: <)
* people.sort(through: { $0.age }, by: <)
* people.sort(by: { $0.age }, using: <)
