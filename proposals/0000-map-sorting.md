# Map Sorting

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Draft**
* Implementation: [apple/swift#23156](https://github.com/apple/swift/pull/23156)

## Introduction

This proposal presents a minor addition to the Standard Library in an effort to make map sorting and, eventually, closureless key-path sorting a functional prerequisite for Swift.

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

Most often, however, all we need to determine sorting is a key-path on an element. Other times, a comparison closure on its own happens to be inconvenient or inefficient: the base metric might be obtained through non-trivial computation, where a predicate alone instigates code duplication and makes it harder to spot the sorting order. When the values are expensive to retrieve, the predicate obscuring the computations also becomes a major obstacle for optimizations, such as trading memory for speed to warrant that each value is computed once per element. For clarity, applying the latter to a ϴ(n) operation can speed up sorting by a factor of 10 for an array of 1500 elements. The goal is therefore to introduce an API that decouples the comparison of values from their calculations, favouring optimizations and providing greater convenience for an ample range of cases.

### Key-paths

**Swift 4** key-path expressions enable us to get rid of the closure and hence retain the argument label, giving the call a surprising resemblance to actual human language.

```swift
people.sort(by: \.age)
chats.sort(by: \.lastMsg.date, >)
``` 

Just like [`sort()`](https://developer.apple.com/documentation/swift/mutablecollection/2802575-sort)
and [`sorted()`](https://developer.apple.com/documentation/swift/sequence/1641066-sorted), key-path sorting is a highly common practice and a fundamental case that deserves a convenience method in the Standard Library, the author believes. The only problem with focusing solely on key-paths is that we neglect custom transforms, whereas a general approach is both flexible and provident in leaving space for key-path conveniences were we to support implicit key-path-to-function conversions sometime in the future.

## Proposed solution

Add an overload for both the non-mutating `sorted` and in-place `sort` methods on `Sequence` and `MutableCollection` respectively. The predicate will lead the argument list, followed by a mapping closure. The ordering is such as to ensure a trailing position for the argument with a higher demand on closure expansion. Ideally, swapping property-based transforms for key-paths will be a matter of style. 

```swift
chats.sort(using: >) { $0.lastMsg.date }
chats.sort(using: >, by: \.lastMsg.date)
```


### Implementation

```swift
extension Sequence {

  @inlinable
  public func sorted<Value>(
    using areInIncreasingOrder: (Value, Value) throws -> Bool,
    by transform: (Element) -> Value
  ) rethrows -> [Element] {
    return try sorted {
      try areInIncreasingOrder(transform($0), transform($1))
    }
  }
}

extension MutableCollection where Self: RandomAccessCollection {

  @inlinable
  public mutating func sort<Value>(
    using areInIncreasingOrder: (Value, Value) throws -> Bool,
    by transform: (Element) -> Value
  ) rethrows {
    try sort {
      try areInIncreasingOrder(transform($0), transform($1))
    }
  }
}
```

## Source compatibility & ABI stability

This is an ABI-compatible addition with no impact on source compatibility.


## Alternatives considered

The implementation could be constrained to only accept transforms to `Comparable` types - so we can make calls shorter for ascending order by defaulting to the less-than (`<`) operator in exchange for flexibility: `people.sort { $0.age }`. Nevertheless, explicit sorting order has its readability merits and the advantage of saving the reader from looking up documentation notes on defaults.

