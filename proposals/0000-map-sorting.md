# Map Sorting

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis), [Cal Stephens](https://github.com/calda)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: [apple/swift#23156](https://github.com/apple/swift/pull/23156)

## Introduction

This proposal presents an addition to the Standard Library in an effort to make map sorting and, eventually, closureless key-path sorting a functional prerequisite for Swift.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/map-sorting/21421)

## Motivation

The straightforward way to sort a collection over a `Comparable` property of its `Element` type is to use a regular predicate, welding together the accessing and comparison of values.

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

Most often, however, all we need to determine sorting is a key-path. Other times, a comparator on its own becomes inconvenient or inefficient.
* The `$0.property < $1.property` syntax often leads to copy-and-paste bugs.
* The base metric is not always trivial to obtain, in which case a predicate alone instigates duplication and makes it harder to grasp the sorting order.
* When the values are expensive to retrieve, the predicate obscuring the comparison also becomes a major obstacle for optimizations, such as trading memory for speed to warrant that each value is computed once per element rather than O(*n* log*n*) times. To clarity the impact, applying the latter to a ϴ(*n*) operation theoretically speeds up sorting by a factor of 10 for an array of 1000 elements. 
Thereby, the goal is to introduce an API that decouples the comparison of values from their calculations, favoring optimizations and bringing ergonomic benefits for an ample range of cases.

## Proposed solution

Add an overload for both the nonmutating `sorted` and in-place `sort` methods on `Sequence` and `MutableCollection` respectively. A mapping closure on `Element` will lead the argument list, followed by the well known `areInIncreasingOrder` predicate and, finally, a flag for opting into the already mentioned [Schwartzian Transform](https://en.wikipedia.org/wiki/Schwartzian_transform) optimization. `transform` is deliberately positioned before the predicate to respect logical and type-checking order. Here are some example usages:

```swift
chats.sort(on: { $0.lastMsg.date }, by: >)

fileUnits.sort(
  on: { $0.raw.count(of: "func") },
  by: <,
  isExpensiveTransform: true
)
```
Having accepted [SE-0249](https://github.com/apple/swift-evolution/blob/master/proposals/0249-key-path-literal-function-expressions.md), the first example can now also be written with a key-path:

```swift
chats.sort(on: \.lastMsg.date, by: >)
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

### Argument label naming  

#### `people.sort(over: { $0.age }, by: <)`

`over` has more of a mathematical flavor to it, where the `transform` argument is read as a set of values with an injective (one-to-one) relation to the elements of the sequence. For that matter, «map sorting» can be thought of as sorting the set of transformed values and permuting the elements of the original sequence accordingly. While this variant emphasizes the strong correlation of mathematics and computer science, Swift as a multi-paradigm language should strive to settle with generally understandable names that, ideally, can be easily recognized regardless of the user's background.

#### `people.sort(by: { $0.age }, using: <)`

The `by` label is a perfect candidate to describe the metric used to sort the sequence. `using`, on its turn, is just as fitting for a predicate or an operator. The pair in question is perhaps the only one that always boils down to a proper
sentence - «*Sort(ed) **by** a metric **using** a predicate*». Nevertheless, the author is convinced in the superior importance of preserving API uniformity and consistency with existing API the Standard Library developers have worked so hard to keep. With ABI Stability kicking in, we no longer have the opportunity for amendments to public API signatures and must be especially careful in this regard.

### Convenience overloads

It has been considered to mirror the `sort()` & `sorted()` precedent by implementing two additional overloads that specialize on ascending order. The latter is known to be by far the most common scenario in practice; abundant enough for the aforementioned API to have overcome the moratorium on trivially composable sugar. [Browsing](https://forums.swift.org/t/map-sorting/21421/20?u=anthonylatsis) the [Swift Source Compatibility Suite](https://github.com/apple/swift-source-compat-suite) shows a 9:1 ratio in favor of parameter-less sorting method usage. At the same time, the presence or absence of a parameter becomes less tangible as the number of parameters increases.

> *Not to be treated as an opposing argument, note that, as of today, trailing closure syntax is not supported for closures at non-trailing positions, even when subsequent parameters have default values. This leaves trailing closure syntax out of the game for now.*
> ```swift
> // OK
> people.sorted(on: { $0.age }) 
> people.sorted(on: { $0.age }, by: <)
> 
> // conflict with sorted(by:)
> people.sorted { $0.age } 
> ```

Overall, the attitude for functional sugar is positive, but the feedback remains somewhat occasional for a solid decision to follow. With the help and advice of the community and Core Team, the author hopes to arrive at a conclusion with everyone on this matter during review.
