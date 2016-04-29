# Add scan, prefix(while:), drop(while:), and unfold to the stdlib

* Proposal: [SE-0045](0045-scan-takewhile-dropwhile.md)
* Author(s): [Kevin Ballard](https://github.com/kballard)
* Status: **Active review: April 28...May 3, 2016**
* Review manager: [Chris Lattner](http://github.com/lattner)
* Revision: 3
* Previous Revisions: [1][rev-1], [2][rev-2]

[rev-1]: https://github.com/apple/swift-evolution/blob/b39d653f7e3d5e982b562664343f26c826652291/proposals/0045-scan-takewhile-dropwhile.md
[rev-2]: https://github.com/apple/swift-evolution/blob/baec22a8a5ddaa0407086380da32b5cad2144800/proposals/0045-scan-takewhile-dropwhile.md

## Introduction

Add 3 new `Sequence` functions `scan(_:combine:)`, `prefix(while:)`, and
`drop(while:)`, with overrides as appropriate on `Collection`,
`LazySequenceProtocol`, and `LazyCollectionProtocol`, as well as a global
function `unfold(_:applying:)`.

Swift-evolution thread:
[Proposal: Add scan, takeWhile, dropWhile, and iterate to the stdlib](http://thread.gmane.org/gmane.comp.lang.swift.evolution/1515)

## Motivation

The Swift standard library provides many useful sequence manipulators like
`dropFirst(_:)`, `filter(_:)`, etc. but it's missing a few common methods that
are quite useful.

## Proposed solution

Add the following extension to `Sequence`:

```swift
extension Sequence {
  /// Returns an array containing the results of
  ///
  ///     p.reduce(initial, combine: combine)
  ///
  /// for each prefix `p` of `self` in order from shortest to longest, starting
  /// with the empty prefix and ending with `self`.
  ///
  /// For example:
  ///
  ///     (1..<6).scan(0, combine: +) // [0, 1, 3, 6, 10, 15]
  ///
  /// - Complexity: O(N)
  @warn_unused_result
  public func scan<T>(_ initial: T, @noescape combine: (T, Self.Iterator.Element) throws -> T) rethrows -> [T]
}
```

Modify the declaration of `Sequence` with two new members:

```swift
protocol Sequence {
  // ...
  /// Returns a subsequence by skipping elements while `predicate` returns
  /// `true` and returning the remainder.
  @warn_unused_result
  func drop(@noescape while predicate: (Self.Iterator.Element) throws -> Bool) rethrows -> Self.SubSequence
  /// Returns a subsequence containing the initial elements until `predicate`
  /// returns `false` and skipping the remainder.
  @warn_unused_result
  func prefix(@noescape while predicate: (Self.Iterator.Element) throws -> Bool) rethrows -> Self.SubSequence
}
```

Also provide default implementations on `Sequence` that return `AnySequence`,
and default implementations on `Collection` that return a slice.

`LazySequenceProtocol` and `LazyCollectionProtocol` will also be extended with
implementations of `scan(_:combine:)`, `drop(while:)`, and `prefix(while:)`
that return lazy sequence/collection types. Like the lazy `filter(_:)`,
`drop(while:)` will perform the filtering when `startIndex` is accessed.

Add a global function:

```swift
/// Builds a sequence from a seed and a function that operates on this value.
/// Each successive value of the sequence is produced by calling `applying` with
/// the state returned from the previous call (or the seed). The sequence is
/// evaluated lazily and is terminated when `applying` returns `nil`. For
/// example:
///
///     unfold(10, applying: { $0 == 0 ? nil : ($0, $0-1) }
///     // yields: [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
///
/// This function is the dual to `reduce(_:combine:)`.
@warn_unused_result
public func unfold<T, State>(_ initialState: State, applying: State -> (T, State)?) -> UnfoldSequence<T>
```

as well as an override:

```swift
/// Returns a sequence of lazy applications of `applying` to the
/// previous value, starting with a given seed. The sequence is terminated when
/// `applying` returns `nil`. For example:
///
///     unfold(1, applying: { $0 * 2 }) // yields: 1, 2, 4, 8, 16, 32, 64, ...
///
/// The sequence terminates when `applying` returns `nil`.
@warn_unused_result
public func unfold<T>(_ initialElement: T, apply: T -> T) -> UnfoldSequence<T>
```

## Detailed design

In addition to the above declarations, provide default implementations based on
`AnySequence`, similarly to how functions like `dropFirst(_:)` and `prefix(_:)`
are handled:

```swift
extension Sequence where
  SubSequence : Sequence,
  SubSequence.Iterator.Element == Iterator.Element,
  SubSequence.SubSequence == SubSequence {

  @warn_unused_result
  public func drop(@noescape while predicate: (Self.Iterator.Element) throws -> Bool) rethrows -> AnySequence<Self.Iterator.Element>
  @warn_unused_result
  public func prefix(@noescape while predicate: (Self.Iterator.Element) throws -> Bool) rethrows -> AnySequence<Self.Iterator.Element>
}
```

These default implementations produce an `AnySequence` that wraps an `Array`
(as the functions must be implemented eagerly so as preserve the convention of
not holding onto a user-provided closure past the function call without the
explicit appearance of `.lazy`).

Provide default implementations on `Collection` as well:

```swift
extension Collection {
  func drop(@noescape while predicate: (Self.Iterator.Element) throws -> Bool) rethrows -> Self.SubSequence
  func prefix(@noescape while predicate: (Self.Iterator.Element) throws -> Bool) rethrows -> Self.SubSequence
}
```

Also provide overrides as needed on `AnySequence`, `AnyCollection`,
`AnyBidirectionalCollection`, and `AnyRandomAccessCollection`.

Extend `LazySequenceProtocol` with lazy versions of the functions:

```swift
extension LazySequenceProtocol {
  func scan<T>(_ initial: T, combine: (T, Self.Iterator.Element) -> T) -> LazyScanSequence<Self.Elements, T>
  func drop(while predicate: (Self.Iterator.Element) -> Bool) -> LazyDropWhileSequence<Self.Elements>
  func prefix(while predicate: (Self.Iterator.Element) -> Bool) -> LazyPrefixWhileSequence<Self.Elements>
}
```

The types `LazyScanSequence`, `LazyDropWhileSequence`, and
`LazyPrefixWhileSequence` all conform to `LazySequenceProtocol`.

Extend `LazyCollectionProtocol` with collection variants for the functions:

```swift
extension LazyCollectionProtocol {
  func scan<T>(_ initial: T, combine: (T, Self.Iterator.Element) -> T) -> LazyScanCollection<Self.Elements, T>
  func drop(while predicate: (Self.Iterator.Element) -> Bool) -> LazyDropWhileCollection<Self.Elements>
  func prefix(while predicate: (Self.Iterator.Element) -> Bool) -> LazyPrefixWhileCollection<Self.Elements>
}
```

The types `LazyScanCollection`, `LazyDropWhileCollection`, and
`LazyPrefixWhileCollection` conform to `LazyCollectionProtocol`.

The type `UnfoldSequence` from the function `unfold(_:applying:)` conforms to
`Sequence`.

## Impact on existing code

None, this feature is purely additive.

## Alternatives considered

#### Naming

The names here are likely to cause some bikeshedding. Here are some alternatives
I've heard proposed:

* `suffixFrom(firstElementSatisfying:)` instead of `drop(while:)` – Not only is
  it rather long, it's also focusing on taking a suffix while the actual
  expected usage of the function is focused around skipping elements at the
  start. There's also the potential confusion around whether it's the first
  element from the beginning or the first element from the end (since the term
  "suffix" implies working from the end backwards).
* `skip(while:)` instead of `drop(while:)` – I'm actually partial to this one,
  but we'd need to rename `dropFirst(_:)` as well. The benefit of this is it
  removes the potential confusion around whether the method is mutating.
* `take(while:)` instead of `prefix(while:)` – This was actually the original
  name proposed, and it matches precedent from other languages, but I eventually
  decided that consistency with `prefix(_:)` was desired. However, there is an
  argument to be made that `prefix(while:)` is using the term "prefix" like a
  verb instead of a noun, and the verb form means something different.
* `prefix(to:)` instead of `prefix(while:)` – The name here doesn't make it
  obvious that the argument is a predicate, and this also requires inverting the
  meaning of the predicate which I don't like. The focus of this function is on
  retaining the initial elements that have a desired characteristic, which
  suggests that the predicate should describe the characteristic the desired
  elements have, not the inverse.
* `prefix(having:)` instead of `prefix(while:)` – Reasonable. I chose
  `prefix(while:)` for consistency with `drop(while:)` but `prefix(having:)`
  makes more grammatical sense (since we're using the noun meaning of prefix
  rather than the verb meaning).
* `reducedPrefixes(_:combine:)` instead of `scan(_:combine:)` – Seems somewhat
  awkward.
* `unfold(_:applying:)` originally didn't have the override that includes
  `State` and was called `iterate(_:apply:)`. We could split this into two
  functions, one with the `State` called `unfold(_:applying:)` and one without
  it called `iterate(_:applying:)`.

#### `unfold(_:applying:)`

As noted previously, this function was originally proposed as
`iterate(_:apply:)` and it didn't have the override that included `State`. This
naming has precedent in Haskell at least. But it was suggested that we should
include the version with `State` (which is called `unfold` in existing
languages), and then convert `iterate(_:apply:)` into an overload of `unfold`.
Considering just Swift alone, having `unfold` with an override seems like a
sensible choice, but if we were to match existing precedent in other languages
(e.g. Haskell) we'd need to split it into separate `unfold` and `iterate`
methods (and remove the optional return value of the `iterate` closure, turning
it into an infinite sequence).
