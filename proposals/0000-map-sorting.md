# Map Sorting

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis), [Cal Stephens](https://github.com/calda)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: [apple/swift#23156](https://github.com/apple/swift/pull/23156)

## Introduction

This proposal presents an addition to the Standard Library that makes it easy to sort a collection over some set of mapped values, provided via a transform closure or `KeyPath`, in a way that is ergonomic, idiomatic, and performant.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/map-sorting/21421)

## Motivation

To sort a `Collection`, you're currently required to specify an `areInIncreasingOrder` predicate of the form `(Element, Element) -> Bool`. If you're sorting on the `Element` itself, you can use simple comparators like `<` and `>`.

Sorting a `Collection` on some *property* or *value* derived from the `Element` is more complex, and currently requires specifying a closure that welds together both the accessing and comparison of values.

```swift
struct Person {
  ...
  var age: Int
}

struct Chat {
  ...
  var lastMessage: Message
}

var people: [Person] = ...
var chats: [Chat] = ...

people.sort { $0.age < $1.age }
chats.sort { $0.lastMessage.date > $1.lastMessage.date }
```

In many circumstances, this approach can cause issues:
* The `$0.property < $1.property` syntax often leads to copy-and-paste bugs.
* For long property names or complicated multi-line predicates, this syntax can be especially verbose since it requires duplicating the logic for retrieving the values.
* When the values are expensive to retrieve or calculate, this type of predicate becomes an obstacle for optimizations. It may be desirable to trade memory for speed such that each value is computed once per element rather than O(*n* log*n*) times. For an ϴ(*n*) operation, this optimization can theoretically speed up sorting by a factor of 10 for an array of 1000 elements. This is called the  [Schwartzian Transform](https://en.wikipedia.org/wiki/Schwartzian_transform).

Thereby, the goal of this proposal is to introduce an API that decouples the comparison of values from their retrieval, bringing ergonomic benefits for an ample range of cases, and opening the door for new optimizations.

## Proposed solution

The authors propose to add an overload for both the nonmutating `sorted` and in-place `sort` methods on `Sequence` and `MutableCollection` respectively. A mapping closure `(Element) -> Value` will lead the argument list, followed by the well known `areInIncreasingOrder` predicate of the type `(Value, Value) -> Bool`. Additionally, we propose a flag for opting in to the Schwartzian Transform optimization.
 
 Here are some example usages:

```swift
people.sort(on: { $0.age }, by: <)
chats.sort(on: { $0.lastMessage.date }, by: >)

fileUnits.sort(
  on: { $0.raw.count(of: "func") },
  by: <,
  isExpensiveTransform: true
)
```
Following the acceptance of [SE-0249](https://github.com/apple/swift-evolution/blob/master/proposals/0249-key-path-literal-function-expressions.md), the examples above can also be written with a key-path:

```swift
people.sort(on: \.age, by: <)
chats.sort(on: \.lastMessage.date, by: >)
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

## Future Directions

### Provide `<` as the default `areInIncreasingOrder` predicate when `Value: Comparable`

A future addition to the Standard Library's sorting API could provide a version of `sort(on:)` and `sorted(on:)` where `<` is provided as the default sorting predicate for `Comparable` values:

```swift
people.sort(on: { $0.age })
people.sort(on: \.age)
```

This follows the precedent set by the existing `sort(by:)` and `sorted(by:)` methods. We chose to exclude these additional overloads from this initial proposal, as they are purely additive and could be included in either a later proposal or a final stage of this proposal (pending feedback during the review process).

## Alternatives considered

### Argument labels

#### `people.sort(over: { $0.age }, by: <)`

`over` has more of a mathematical flavor to it, where the `transform` argument is read as a set of values with an injective (one-to-one) relation to the elements of the sequence. For that matter, «map sorting» can be thought of as sorting the set of transformed values and permuting the elements of the original sequence accordingly. While this variant emphasizes the strong correlation of mathematics and computer science, Swift as a multi-paradigm language should strive to settle with generally understandable names that, ideally, can be easily recognized regardless of the user's background.

#### `people.sort(by: { $0.age }, using: <)`

The `by` label is a perfect candidate to describe the metric used to sort the sequence. `using`, on its turn, is just as fitting for a predicate or an operator. The pair in question is perhaps the only one that always boils down to a proper
sentence - «*Sort(ed) **by** a metric **using** a predicate*». Nevertheless, the author is convinced in the superior importance of preserving API uniformity and consistency with existing API the Standard Library developers have worked so hard to keep. With ABI Stability kicking in, we no longer have the opportunity for amendments to public API signatures and must be especially careful in this regard.

### Argument order

Before adding the `isExpensiveTransform` flag, it was discussed that one could rearrange the arguments such that the `transform` closure follows the `areInInreasingOrder` predicate. That would have allowed the caller to make use of trailing-closure syntax:

`people.sort(by: <) { $0.age }`

The authors concluded that `transform` should be positioned *before* the `areInIncreasingOrder` predicate. This better mirrors the flow of data, where the `transform` closure is always called before the `areInIncreasingOrder` predicate  `(Element) -> (Value), (Value, Value) -> (Bool)`.

### `isExpensiveTransform`

The `isExpensiveTransform` is an optional flag included in the proposed method so that the caller may opt-in to using the [Schwartzian Transform](https://en.wikipedia.org/wiki/Schwartzian_transform). The authors think that this optimization is useful enough to be worth including as a part of the proposal. Since it is an optional parameter (defaulting to `false`), it could alternatively be excluded. Callers seeking this sort of optimization would otherwise have to use a more complex pattern that is both easy to get wrong and generally less efficient than the implementation provided in this proposal.

```swift
array.map { ($0, $0.count) }
    .sorted(by: { $0.1 })
    .map { $0.0 }
```
