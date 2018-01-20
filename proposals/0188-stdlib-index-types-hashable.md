# Make Standard Library Index Types Hashable

* Proposal: [SE-0188](0188-stdlib-index-types-hashable.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 4.1)**
* Implementation: [apple/swift#12777](https://github.com/apple/swift/pull/12777)

## Introduction

Key-path expressions can now include subscripts to reference individual positions in collections and other subscriptable types, but only when the subscript parameters are `Hashable`. To provide maximum utility, the standard library index types should all have `Hashable` conformance added.

Swift-evolution "thread:" [[draft] Make Standard Library Index Types Hashable](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171030/040908.html)

## Motivation

You can only use subscripts in key-path expressions when the subscript parameter type is `Hashable`. This means that you can use a subscript as part of a key-path expression with an array, which uses `Int` as its index type, but not with a string, which uses a custom index type.

```swift
let numbers = [10, 20, 30, 40, 50]
let firstValue = \[Int].[0]
print(numbers[keyPath: firstValue])     // 10

let string = "Helloooo!"
let firstChar = \String.[string.startIndex]
// error: subscript index of type 'String.Index' in a key path must be Hashable
```

## Proposed solution

This proposal would add `Hashable` conformance to all the index types in the standard library. With that done, `[Int]`, `String`, and all other standard libary collections would have the same behavior when using subscripts in key paths.

## Detailed design

For index types that wrap an internal offset or other value, adding `Hashable` conformance will be simple. For index types that wrap another index type, such as `ReversedIndex`, `Hashable` conformance must wait until the implementation of conditional conformance is complete. 

This is the breakdown of the standard library's index types:

#### Simple Index Types

- `Int` (already `Hashable`)
- `Dictionary.Index`
- `Set.Index`
- `String.Index`

#### Wrapping Index Types

- `ClosedRangeIndex`
- `FlattenCollectionIndex`
- `LazyDropWhileIndex`
- `LazyFilterIndex`
- `LazyPrefixWhileIndex`
- `ReversedIndex`

`AnyIndex`, which type erases any index type at run-time, would not be hashable since it might wrap a non-hashable type.

## Source compatibility

This is an additive change in the behavior of standard library index types, so it should pose no source compatibility burden. Specifically, this proposal does *not* change the requirements for an index type in the `Collection` protocol, so collections and custom index types that have been written in prior versions of Swift will be unaffected.

## Effect on ABI stability & API resilience

Beyond an additional conformance for the types mentioned above, this proposal has no effect on ABI stability or API resilience.

## Alternatives considered

None.

