# Feature name

* Proposal: TBD
* Author(s): [Kevin Ballard](https://github.com/kballard)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Add 3 new `SequenceType` functions `scan(_:combine:)`, `takeWhile(_:)`, and
`dropWhile(_:)`, with overrides as appropriate on `CollectionType`,
`LazySequenceType`, and `LazyCollectionType`, as well as a global function
`iterate(_:apply:)`.

Swift-evolution thread:
[Proposal: Add scan, takeWhile, dropWhile, and iterate to the stdlib](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151228/004690.html)

## Motivation

The Swift standard library provides many useful sequence manipulators like
`dropFirst(_:)`, `filter(_:)`, etc. but it's missing a few common methods that
are quite useful.

## Proposed solution

Add the following extension to `SequenceType`:

```swift
extension SequenceType {
  /// Returns an array containing the results of
  ///
  ///     p.reduce(initial, combine: combine)
  ///
  /// for each prefix `p` of `self`, in order from shortest to longest.
  /// For example:
  ///
  ///     (1..<6).scan(0, combine: +) // [0, 1, 3, 6, 10, 15]
  ///
  /// - Complexity: O(N)
  func scan<T>(initial: T, @noescape combine: (T, Self.Generator.Element) throws -> T) rethrows -> [T]
}
```

Modify the declaration of `SequenceType` with two new members:

```swift
protocol SequenceType {
  // ...
  /// Returns a subsequence by skipping elements while `dropElement` returns
  /// `true` and returning the remainder.
  func dropWhile(@noescape dropElement: (Self.Generator.Element) throws -> Bool) rethrows -> Self.SubSequence
  /// Returns a subsequence containing the elements until `takeElement` returns
  /// `false` and skipping the remainder.
  func takeWhile(@noescape takeElement: (Self.Generator.Element) throws -> Bool) rethrows -> Self.SubSequence
}
```

Also provide default implementations on `SequenceType` that return
`AnySequence`, and default implementations on `CollectionType` that return a
slice.

`LazySequenceType` and `LazyCollectionType` will also be extended with
implementations of `scan(_:combine:)`, `dropWhile(_:)`, and `takeWhile(_:)`
that return lazy sequence/collection types. Like the lazy `filter(_:)`,
`dropWhile(_:)` will perform the filtering when `startIndex` is accessed.

Add a global function:

```swift
/// Returns an infinite sequence of lazy applications of `apply` to the
/// previous value. For example:
///
///     iterate(1, apply: { $0 * 2 }) // yields: 1, 2, 4, 8, 16, 32, 64, ...
func iterate<T>(initial: T, apply: T -> T) -> IterateSequence<T>
```

## Detailed design

In addition to the above declarations, provide default implementations based on
`AnySequence`, similarly to how functions like `dropFirst(_:)` and `prefix(_:)`
are handled:

```swift
extension SequenceType {
  func dropWhile(@noescape dropElement: (Self.Generator.Element) throws -> Bool) rethrows -> AnySequence<Self.Generator.Element>
  func takeWhile(@noescape takeElement: (Self.Generator.Element) throws -> Bool) rethrows -> AnySequence<Self.Generator.Element>
}
```

These default implementations produce an `AnySequence` that wraps an `Array`
(as the functions must be implemented eagerly to match expected behavior).

Provide default implementations on `CollectionType` as well:

```swift
extension CollectionType {
  func dropWhile(@noescape dropElement: (Self.Generator.Element) throws -> Bool) rethrows -> Self.SubSequence
  func takeWhile(@noescape takeElement: (Self.Generator.Element) throws -> Bool) rethrows -> Self.SubSequence
}
```

Extend `LazySequenceType` with lazy versions of the functions:

```swift
extension LazySequenceType {
  func scan<T>(initial: T, combine: (T, Self.Generator.Element) -> T) -> LazyScanSequence<Self.Elements, T>
  func dropWhile(dropElement: (Self.Generator.Element) -> Bool) -> LazyDropWhileSequence<Self.Elements>
  func takeWhile(takeElement: (Self.Generator.Element) -> Bool) -> LazyTakeWhileSequence<Self.Elements>
}
```

The types `LazyScanSequence`, `LazyDropWhileSequence`, and
`LazyTakeWhileSequence` all conform to `LazySequenceType`.

Extend `LazyCollectionType` with collection variants for `dropWhile(_:)` and
`takeWhile(_:)` (but not `scan(_:combine:)` because there's no way to recover
the value from an index without re-scanning from the start):

```swift
extension LazyCollectionType {
  func dropWhile(dropElement: (Self.Generator.Element) -> Bool) -> LazyDropWhileCollection<Self.Elements>
  func takeWhile(takeElement: (Self.Generator.Element) -> Bool) -> LazyTakeWhileCollection<Self.Elements>
}
```

The types `LazyDropWhileCollection` and `LazyTakeWhileCollection` conform to
`LazyCollectionType`.

The type `IterateSequence` from the function `iterate(_:apply:)` conforms to
`SequenceType`.

## Impact on existing code

None, this feature is purely additive.

## Alternatives considered

None
