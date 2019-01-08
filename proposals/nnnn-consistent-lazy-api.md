# Consistent `lazy` API

- Proposal: [SE-NNNN](nnnn-consistent-lazy-api.md)
- Author: [Dennis Vennink](https://github.com/dennisvennink)
- Review Manager: To Be Determined
- Status: **Work In Progress**
- Implementation: [apple/swift#21793](https://github.com/apple/swift/pull/21793)
- Bug: [SR-5754](https://bugs.swift.org/browse/SR-5754)

## Introduction

This proposal addresses the absence of lazy implementations of some `Sequence`-related operations.

### Discussion

A formal Swift Evolution forum thread will be posted as soon as possible.

## Motivation

Lazy evaluation defers the computation of an operation until (a part of) its result is needed. In Swift, this strategy is implemented in two ways. The first, [lazy stored properties](https://docs.swift.org/swift-book/LanguageGuide/Properties.html#ID257), enables the user to defer the evaluation of a property's initial value until the first time it's called. The second, `Sequence`'s [`lazy`](https://developer.apple.com/documentation/swift/sequence/1641562-lazy) instance property, enables the user to lazily evaluate subsequent operations by only evaluation those elements that are needed. The latter is the primary focus of this proposal.

`lazy` works by wrapping a `Sequence` in a `LazySequence`. Both `LazySequence` and some of its operations conform to `LazySequenceProtocol` enabling subsequent lazily implemented operations:

```swift
print(type(of: sequence(first: 0, next: { $0 + 1 }).lazy.map(String.init)))
// Prints "LazyMapSequence<UnfoldSequence<Int, (Optional<Int>, Bool)>, String>"
```

However, not all of `LazySequenceProtocol`'s operations `return` types that conform to `LazySequenceProtocol`.

Here, we expect a `LazyMapSequence`, but instead we get an `Array<String>`:

```swift
print(type(of: sequence(first: 0, next: { $0 + 1 }).lazy.prefix(3).map(String.init)))
// Prints "Array<String>"
```

Using any of these operations will lead to a loss of laziness and the immediately evaluation of (a part of) the expression. In certain situations it might lead to less performant code or the usage of more memory than its lazy counterpart.

## Proposed Solution

I propose conforming all existing lazily implemented `Sequence`s to `LazySequenceProtocol`. For those inherited members from `Sequence` on `LazySequenceProtocol` that are eagerly implemented I propose creating overloads along with new types conforming to `LazySequenceProtocol` that are conventionally prefixed with `Lazy`.

## Detailed Design

### Conform Existing `Sequence`s To `LazySequenceProtocol`

The following `Sequence`s *can't* conform to `LazySequenceProtocol`:

- `AnyBidirectionalCollection`
- `AnyCollection`
- `AnyIterator`
- `AnyRandomAccessCollection`
- `AnySequence`
- `Array`
- `ArraySlice`
- `ClosedRange`
- `CollectionOfOne`
- `ContiguousArray`
- `Dictionary`
- `EmptyCollection`
- `EmptyCollection.Iterator`
- `KeyValuePairs`
- `PartialRangeFrom`
- `Range`
- `Repeated`
- `Set`
- `StrideThrough`
- `StrideTo`
- `String`
- `String.UnicodeScalarView`
- `String.UTF16View`
- `String.UTF8View`
- `Substring`
- `Substring.UnicodeScalarView`
- `Substring.UTF16View`
- `Substring.UTF8View`
- `UnfoldSequence`
- `Unicode.Scalar.UTF16View`
- `UnsafeBufferPointer`
- `UnsafeMutableBufferPointer`
- `UnsafeMutableRawBufferPointer`
- `UnsafeRawBufferPointer`
- `UnsafeRawBufferPointer.Iterator`

These `Sequence`s don't contain an underlying `Sequence` and therefore can't conform to both `Sequence` and `LazySequenceProtocol`.

The following `Sequence`s already conform to `LazySequenceProtocol` and require no modifications:

- `LazyFilterSequence`
- `LazyMapSequence`
- `LazyPrefixWhileSequence`
- `LazySequence`
- `ReversedCollection`
- `Slice`

The following `Sequence`s can conform to `LazySequenceProtocol`:

- `LazyFilterSequence.Iterator`
- `LazyPrefixWhileSequence.Iterator`
- `LazyMapSequence.Iterator`

The following `Sequence`s can conform to `LazySequenceProtocol` on the condition that `Base` conforms to `LazySequenceProtocol`:

- `EnumeratedSequence`
- `EnumeratedSequence.Iterator`
- `FlattenSequence`
- `FlattenSequence.Iterator`
- `IteratorSequence`
- `JoinedSequence`
- `PrefixSequence`
- `ReversedCollection.Iterator`

Note that the conformance of `DropFirstSequence` and `DropWhileSequence` to `LazySequenceProtocol` is not possible. The former can't because `makeIterator()` pre-emptively drops elements due to performance reasons. The latter can't because `init(_:dropping:)` pre-emptively drops elements due to the non-escaping nature of `drop(while:)`'s `predicate`.

The conformance of `FlattenSequence` to `LazySequenceProtocol` means we can remove `LazySequence` from the `return` types of `joined()` and `flatMap(_:)` on `LazySequenceProtocol`. The old implementations will be deprecated. It also requires the explicit declaration of `FlattenCollection.SubSequence` as `FlattenCollection.subscript(bounds:)` can't ...

The following `Sequence`s can conform to `LazySequenceProtocol` on the condition that `Elements` conforms to `LazySequenceProtocol`:

- `DefaultIndices`
- `IndexingIterator`

<!-- Todo: `LazySequence.indices` `return`s `Base.indices` which might potentially means a loss of laziness. -->

Finally, `Zip2Sequence` can conform to `LazySequenceProtocol` on the condition that `Sequence1` and `Sequence2` conform to `LazySequenceProtocol`.

#### Implementation

...

### Add Missing Lazy Implementations

#### `dropFirst(_:)`

```swift
extension Sequence {
  @inlinable public __consuming func dropFirst (_ k: Int = 1) -> DropFirstSequence<Self>
}
```

#### `dropLast(_:)`

```swift
extension Sequence {
  @inlinable public __consuming func dropLast (_ k: Int = 1) -> [Self.Element]
}
```

#### `drop(while:)`

```swift
extension Sequence {
  @inlinable public __consuming func drop (while predicate: (Self.Element) throws -> Bool) rethrows -> DropWhileSequence<Self>
}
```

#### `joined()`

```swift
extension Sequence where Self.Element: StringProtocol {
  public func joined (separator: String = "") -> String
}
```

#### `prefix(_:)`

```swift
extension Sequence {
  @inlinable public __consuming func prefix (_ maxLength: Int) -> PrefixSequence<Self>
  @inlinable public __consuming func prefix (while predicate: (Self.Element) throws -> Bool) rethrows -> [Self.Element]
}
```

#### `reversed()`

```swift
extension Sequence {
  @inlinable public __consuming func reversed () -> [Self.Element]
}
```

#### `shuffled()` / `shuffled(using:)`

```swift
extension Sequence {
  @inlinable public func shuffled <T: RandomNumberGenerator> (using generator: inout T) -> [Self.Element]
  @inlinable public func shuffled () -> [Self.Element]
}
```

#### `sorted(by:)` / `sorted()`

```swift
extension Sequence {
  @inlinable public func sorted (by areInIncreasingOrder: (Self.Element, Self.Element) throws -> Bool) rethrows -> [Self.Element]
}
```

```swift
extension Sequence where Self.Element: Comparable {
  @inlinable public func sorted () -> [Self.Element]
}
```

#### `split(maxSplits:omittingEmptySubsequences:isSeparator:)` / `split(separator:maxSplits:omittingEmptySubsequences:)`

```swift
extension Sequence {
  @inlinable public __consuming func split (maxSplits: Int = Int.max, omittingEmptySubsequences: Bool = true,
    whereSeparator isSeparator: (Self.Element) throws -> Bool) rethrows -> [ArraySlice<Self.Element>]
}
```

```swift
extension Sequence where Self.Element: Equatable {
  @inlinable public __consuming func split (separator: Self.Element, maxSplits: Int = Int.max,
    omittingEmptySubsequences: Bool = true) -> [ArraySlice<Self.Element>]
}
```

#### `suffix(_:)`

```swift
extension Sequence {
  @inlinable public __consuming func suffix (_ maxLength: Int) -> [Self.Element]
}
```

## Source Compatibility

...

## Effect on ABI Stability

This proposal doesn't change the ABI of existing language features.

## Effect on API Resilience

...

## Alternatives Considered

No alternative approaches have been considered.
