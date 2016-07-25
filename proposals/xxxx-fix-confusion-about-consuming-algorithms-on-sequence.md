# Fixing the confusion between non-mutating algorithms and single-pass sequences

* Proposal: [SE-NNNN](xxxx-fix-confusion-about-consuming-algorithms-on-sequence.md)
* Author: [Dmitri Gribenko](https://github.com/gribozavr)
* Status: **Awaiting review**
* Review manager: TBD

Swift-evolution thread: [Fixing the confusion between non-mutating algorithms and single-pass sequences](http://thread.gmane.org/gmane.comp.lang.swift.evolution/23821).

## Motivation

I'd like to continue the discussion of the issue raised by David Waite in
http://thread.gmane.org/gmane.comp.lang.swift.evolution/21295/:

> My main motivation for proposing this is the potential for developer
> confusion. As stated during one of the previous threads on the naming
> of map, flatMap, filter, etc. methods on Sequence, Sequence has a
> naming requirement not typical of the rest of the Swift standard
> library in that many methods on Sequence may or may not be
> destructive. As such, naming methods for any extensions on Sequence is
> challenging as the names need to not imply immutability.

I'd like to focus on a particular point: methods on `Sequence` can consume
elements, but the APIs are not marked `mutating`.

Dave Abrahams, Max Moiseev, and I have discussed this issue and we agree this
problem is severe and worth solving, we also think that the likely solutions
would be source-breaking, so it is important that we discuss it now.

## Design options

We have discussed a few options.

<details>
  <summary>(Click to unfold) Rejected option: remove `Sequence`, let `IteratorProtocol` model single-pass data streams</summary>

- Remove `Sequence`; make `IteratorProtocol` be the only protocol for
  single-pass data streams; `Collection` continues to be multi-pass.

  This was the most promising option until we realized how bad the resulting
  API is -- see the API sketch in the alternatives section.  We get massive API
  duplication because single-pass and multi-pass data streams don't have a
  common protocol.  If you are adding API that works on single-pass streams (for
  example, `map()` or `split()`), then you need to implement it as protocol
  extensions for both `IteratorProtocol` and `Collection`.

  Note that API duplication does not end with methods on `IteratorProtocol`, it
  will equally apply to any APIs that consume single-pass streams.  Consider
  `RangeReplaceableCollection.append(contentsOf:)`: it only needs to
  make one pass over the data, so it should accept an iterator.  However, in
  practice, most of the time developers will want to append contents of another
  collection.  Either we will require developers to call `makeIterator()`
  (e.g., `myArray.append(contentsOf: anotherArray.makeIterator()`), or we will
  add a convenience API that accepts collections.

  We think that forcing API duplication will not be recieved well.  Probably
  developers will implement one variant of their APIs, only for the kind of
  data stream that they have.

</details>

<details>
  <summary>(Click to unfold) Rejected option: use a syntactic marker, like `sequence.consumedIn.map {}`</summary>

- Add a syntactic marker to the callsite of algorithms that consume elements:

  ```Swift
  mySinglePassSequence.consumedIn.map { $0 + 1 }.filter { $0 > 0 }
  ```

  How do we implement this, though?  If we want to have only one implementation
  of `map()` shared between collections and single-pass sequences, then `map()`
  should be defined on a protocol that both collections and
  `mySinglePassSequence.consumedIn` confrom to.  So we are back to the same
  issue that we were trying to solve -- we have a protocol that models
  single-pass and multi-pass entities, and APIs can't be marked `mutating`; so
  algorithm authors don't get any additional hints about potentially consuming
  elements.  The callsite is a more explicit about the mutation though.

</details>

<details>
  <summary>(Click to unfold) Rejected option: mutating APIs on Sequence, non-mutating APIs on Collection</summary>

- Keep the refinement between `Collection` and `Sequence`; mark APIs as
  `mutating` on `Sequence`, and non-`mutating` on `Collection`.

  ```Swift
  protocol Sequence {
    mutating func map()
  }
  protocol Collection : Sequence {
    func map()
  }
  ```

  This approach will provide the users with the right mutation semantics at the
  callsite, but still has the disadvantage of duplicating APIs.

  Another disadvantage is the syntax at the callsite when passing collections
  to APIs that are expressed in terms of sequences.

  ```Swift
  func printFirstTwoElements<S : Sequence>(of s: inout S) {
    print(s.prefix(2))
  }

  printFirstFiveElements([1,2,3,4]) // error: can't pass an r-value as inout.

  var data = [1,2,3,4]
  printFirstFiveElements(&data) // OK
  ```

  Since `printFirstTwoElements()` only consumes the first two elements, it
  takes the sequence `inout`, so that the caller can consume the rest.
  Unfortunately this means that we can only pass collections stored in
  variables to this function.

</details>

- **Proposed:** rename `Sequence` to `IterableOnce` or `TraversableOnce`.  We think that
  `Sequence` does not convey the single-pass restriction clearly.  The term
  "sequence" has been used in math (as in "integer sequence"), and since the
  math domain does not have mutation, "sequence" can be understood to mean
  "multi-pass", since you can traverse a sequence of integers an arbitrary
  number of times.

We think that only the last option is viable in the Swift language as it exists
now, without creating an undue burden for API vendors and users.

We will also replace `Sequence` with `IterableOnce` in type names (e.g., the
names of lazy sequences).

## Migration

Trivial, just renaming the protocol.  We can keep a deprecated `typealias
Sequence = IterableOnce` for a while.

## Alternative: remove `Sequence`, let `IteratorProtocol` model single-pass data streams

<details>
  <summary>(Click to unfold) Long discussion of this alternative</summary>

We were actually considering proposing this approach, until we realized how
much API duplication we will have to introduce.  The idea was to do the following:

- Remove `Sequence`.

- Make `IteratorProtocol` be the only protocol for single-pass data streams,
  both finite and infinite.

- Make `IteratorProtocol` for-in-able.

- Move algorithms from `Sequence` to `IteratorProtocol`.

The rationale is:

- `IteratorProtocol` already exists in the library and allows to model
  single-pass data streams.

- The common `Sequence` protocol that unifies single-pass and multi-pass streams
  forces conforming single-pass streams to misrepresent mutation semantics in API
  signatures (e.g., `map()` is non-mutating on both `Sequence` and
  `Collection`), which confuses our users.

### API changes

For algorithms on `IteratorProtocol` we are following the usual principles that
should be familiar from the collection design:

- Algorithms that accept a user-provided closure are eager, so that
  side-effects from these closures happen at predictable points in program
  execution.

- Where possible, algorithms have a lazy variant that can be accessed through
  the lazy iterator wrapper.  For example, `it.lazy.map { $0 + 1 }`.

- Algorithms that eagerly consume elements are marked `mutating`.

- Algorithms that are lazy are non-mutating.

We are also using additional criteria to decide which algorithms should be
left out:

- We don't provide algorithms that can be trivially implemented without loss of
  efficiency by putting the contents into an array first (e.g., `sorted()`,
  `reversed()`).

The principle that lazy algoritms are non-mutating in the type system is
probably the most contentious one, and we'd like more community feedback on
this point.

While evaluating the API, please remember that Swift has a language rule that
temporary values (r-values) can't be mutated:

```Swift
let r = getArray().mutateAndReturnSomething() // error

var array = getArray()
array.mutateAndReturnSomething() // OK
```

For example, if we make `IteratorProtocol.lazy.map()` and
`IteratorProtocol.lazy.filter()` lazy and mutating (while producing
`MappingIterator<Self>` and `FilteringIterator<Self>`), then chaining does not
work:

```Swift
// error: 'filter()' can not mutate the temporary returned by 'map()'
it.lazy.map { $0 + 1 }.filter { $0 > 0 }
```

Here's the proposed design of `IteratorProtocol`:

```Swift
protocol IteratorProtocol {
  associatedtype Element

  // No change in semantics.
  mutating func next() -> Element?

  // New APIs.

  // `underestimateCount` is the only non-mutating API on `IteratorProtocol`.
  /// - Complexity: O(1)
  var underestimatedCount: Int { get }

  /// Eager operation.  Consumes all elements.
  /// - Complexity: O(N)
  mutating func count() -> Int

  /// Eager operation.  Consumes all elements.
  mutating func map<T>(
    _ transform: @noescape (Element) throws -> T
  ) rethrows -> [T]

  /// Eager operation.  Consumes all elements.
  mutating func filter(
    _ includeElement: @noescape (Element) throws -> Bool
  ) rethrows -> [Element]

  /// Eager operation.  Consumes all elements.
  mutating func forEach(_ body: @noescape (Element) throws -> Void) rethrows

  // Can also be named `take(_:)`.  The lazy variant is available as
  // `.lazy.prefix()`.  We need an eager variant because extracting the first
  // `n` items leaves the iterator in a valid, defined, documentable state.
  /// Eager operation.  Consumes `maxLength` elements.
  mutating func prefix(_ maxLength: Int) -> [Element]

  /// Eager operation.  Consumes all elements.
  mutating func suffix(_ maxLength: Int) -> [Element]

  /// Eager operation.  Consumes all elements.
  mutating func split(
    maxSplits: Int,
    omittingEmptySubsequences: Bool,
    isSeparator: @noescape (Element) throws -> Bool
  ) rethrows -> [[Element]]

  /// Eager operation.  Consumes elements until the predicate returns `true`.
  mutating func first(
    where: @noescape (Element) throws -> Bool
  ) rethrows -> Element?

  /// Eager operation.  Consumes elements until it finds an equal element.
  mutating func _customContainsEquatableElement(
    _ element: Element
  ) -> Bool?

  /// Create a `ContiguousArray` containing the elements of `self`,
  /// in the same order.
  ///
  /// Eager operation.  Consumes all elements.
  mutating func _copyToContiguousArray() -> ContiguousArray<Element>

  /// Copy the elements into a memory block, returning the number of elements
  /// copied.
  ///
  /// This is an eager operation.  It returns the number of consumed elements.
  @discardableResult
  mutating func _copyContents(
    initializing ptr: UnsafeMutableBufferPointer<Element>
  ) -> Int
}

/// Eager operations that consume all elements.
extension IteratorProtocol {
  public mutating func min(
    isOrderedBefore: @noescape (Element, Element) throws -> Bool
  ) rethrows -> Element?

  public mutating func max(
    isOrderedBefore: @noescape (Element, Element) throws -> Bool
  ) rethrows -> Element?

  public mutating func flatMap<SegmentOfResult : IteratorProtocol>(
    _ transform: @noescape (Element) throws -> SegmentOfResult
  ) rethrows -> [SegmentOfResult.Element]

  public mutating func flatMap<SegmentOfResult : Collection>(
    _ transform: @noescape (Element) throws -> SegmentOfResult
  ) rethrows -> [SegmentOfResult.Element]

  public mutating func flatMap<ElementOfResult>(
    _ transform: @noescape (Element) throws -> ElementOfResult?
  ) rethrows -> [ElementOfResult]

  public mutating func reduce<T>(
    _ initial: T, combine: @noescape (T, Element) throws -> T
  ) rethrows -> T {
}

/// Eager operations that consume all elements.
extension IteratorProtocol where Element : Comparable {
  public mutating func min() -> Element?
  public mutating func max() -> Element?
}

extension IteratorProtocol where Element : IteratorProtocol {
  public mutating func flatten() -> [Element.Element]
}

extension IteratorProtocol where Element : Collection {
  public mutating func flatten() -> [Element.Iterator.Element]
}

/// Eager operation.  Consumes elements until it finds an equal element.
extension IteratorProtocol where Element : Equatable {
  public mutating func contains(_ element: Element) -> Bool
}

/// Eager operation.  Consumes elements until the predicate returns `true`.
extension IteratorProtocol {
  public mutating func contains(
    _ predicate: @noescape (Element) throws -> Bool
  ) rethrows -> Bool {
}

/// Eager operations that consume only the elements necessary to compute
/// the result.
extension IteratorProtocol where Element : Equatable {
  public mutating func starts<PossiblePrefix : IteratorProtocol>(
    with possiblePrefix: PossiblePrefix
  ) -> Bool
  where PossiblePrefix.Element == Element

  public mutating func starts<PossiblePrefix : Collection>(
    with possiblePrefix: PossiblePrefix
  ) -> Bool
  where PossiblePrefix.Iterator.Element == Element
}

/// Eager operations that consume only the elements necessary to compute
/// the result.
extension IteratorProtocol {
  public mutating func starts<PossiblePrefix : IteratorProtocol>(
    with possiblePrefix: PossiblePrefix,
    isEquivalent: @noescape (Element, Element) throws -> Bool
  ) rethrows -> Bool
  where PossiblePrefix.Element == Element

  public mutating func starts<PossiblePrefix : Collection>(
    with possiblePrefix: PossiblePrefix,
    isEquivalent: @noescape (Element, Element) throws -> Bool
  ) rethrows -> Bool
  where PossiblePrefix.Element == Element
}

/// Eager operations that consume only the elements necessary to compute
/// the result.
extension IteratorProtocol where Element : Equatable {
  public mutating func elementsEqual<OtherIterator : IteratorProtocol>(
    _ other: OtherIterator
  ) -> Bool
  where OtherIterator.Element == Element

  public mutating func elementsEqual<OtherIterator : Collection>(
    _ other: OtherIterator
  ) -> Bool
  where OtherIterator.Iterator.Element == Element
}

/// Eager operations that consume only the elements necessary to compute
/// the result.
extension IteratorProtocol {
  public mutating func elementsEqual<OtherSequence : IteratorProtocol>(
    _ other: OtherSequence,
    isEquivalent: @noescape (Element, Element) throws -> Bool
  ) rethrows -> Bool
  where OtherSequence.Element == Element

  public mutating func elementsEqual<OtherCollection : Collection>(
    _ other: OtherCollection,
    isEquivalent: @noescape (Element, Element) throws -> Bool
  ) rethrows -> Bool
  where OtherCollection.Iterator.Element == Element
}

/// Eager operations that consume only the elements necessary to compute
/// the result.
extension IteratorProtocol where Element : Equatable {
  public mutating func lexicographicallyPrecedes<OtherIterator : IteratorProtocol>(
    _ other: OtherIterator
  ) -> Bool
  where OtherIterator.Element == Element

  public mutating func lexicographicallyPrecedes<OtherCollection : Collection>(
    _ other: OtherCollection
  ) -> Bool
  where OtherCollection.Iterator.Element == Element
}

/// Eager operations that consume only the elements necessary to compute
/// the result.
extension IteratorProtocol {
  public mutating func lexicographicallyPrecedes<OtherSequence : IteratorProtocol>(
    _ other: OtherSequence,
    isOrderedBefore: @noescape (Element, Element) throws -> Bool
  ) rethrows -> Bool
  where OtherSequence.Element == Element

  public mutating func lexicographicallyPrecedes<OtherCollection : Collection>(
    _ other: OtherCollection,
    isOrderedBefore: @noescape (Element, Element) throws -> Bool
  ) rethrows -> Bool
  where OtherCollection.Iterator.Element == Element
}

// Lazy operations that leave the iterator in indeterminate state.
// After calling any of these functions, you can use any APIs on `self`.
// These APIs are not marked `mutating` so that chaining works.
extension IteratorProtocol where Element : Equatable {
  public func split(
    separator: Element,
    maxSplits: Int = Int.max,
    omittingEmptySubsequences: Bool = true
  ) -> LazySplitByEqualityIterator<Self>
}

// Lazy operations that leave the iterator in indeterminate state.
// After calling any of these functions, you can use any APIs on `self`.
// These APIs are not marked `mutating` so that chaining works.
extension IteratorProtocol {
  public func dropFirst(_ n: Int) -> LazyDropFirstIterator<Self>

  public func enumerated() -> LazyEnumeratedIterator<Self>

  public func lazy() -> LazyIterator<Self>
}

extension IteratorProtocol where Self : LazyIteratorProtocol {
  public func lazy() -> Self { // Don't re-wrap already-lazy iterators
    return self
  }
}

protocol LazyIteratorProtocol : IteratorProtocol {
  /// An `Iterator` that can contain the same elements as this one,
  /// possibly with a simpler type.
  ///
  /// - See also: `elements`
  associatedtype Elements : IteratorProtocol = Self
}

/// When there's no special associated `Elements` type, the `elements`
/// property is provided.
extension LazyIteratorProtocol where Elements == Self {
  /// Identical to `self`.
  public var elements: Self { return self }
}

// Lazy operations that leave the iterator in indeterminate state.
// After calling any of these functions, you can use any APIs on `self`.
// These APIs are not marked `mutating` so that chaining works.
extension LazyIteratorProtocol {
  public func map<T>(
    _ transform: @noescape (Element) -> T
  ) -> LazyMapIterator<Self.Elements>

  public func filter(
    _ includeElement: @noescape (Element) -> Bool
  ) -> LazyFilterIterator<Self.Elements>

  public func flatMap<SegmentOfResult : IteratorProtocol>(
    _ transform: @noescape (Element) throws -> SegmentOfResult
  ) rethrows -> LazyFlatMapIterator<Self>

  public func flatMap<SegmentOfResult : Collection>(
    _ transform: @noescape (Element) throws -> SegmentOfResult
  ) rethrows -> LazyFlatMapIterator<Self>

  public func flatMap<ElementOfResult>(
    _ transform: @noescape (Element) throws -> ElementOfResult?
  ) rethrows -> LazyFlatMapIterator<Self>

  public func prefix(_ maxLength: Int) -> LazyPrefixIterator<Self>

  public func split(
    maxSplits: Int,
    omittingEmptySubsequences: Bool,
    isSeparator: @noescape (Element) -> Bool
  ) -> LazySplitByPredicateIterator<Self>
}

extension LazyIteratorProtocol where Element : IteratorProtocol {
  public func flatten() -> LazyFlattenIterator<Self>
}

extension LazyIteratorProtocol where Element : Collection {
  public func flatten() -> LazyFlattenIteratorOverCollections<Self>
}

struct LazyIterator<Base : IteratorProtocol> : LazyIteratorProtocol {
  /// Construct an instance with `base` as its underlying Iterator
  /// instance.
  internal init(_base: Base) {
    self._base = _base
  }

  internal var _base: Base

  public mutating func next() -> Element?
}
```

Collection APIs will get new overloads that work on iterators:

```Swift
extension RangeReplaceableCollection {
  public mutating func append<I : IteratorProtocol>(contentsOf newElements: inout I)
    where I.Iterator.Element == Iterator.Element
}
```

The `sequence()` function will start returning an iterator (maybe it should
also be renamed to `iterator()`):

```Swift
public func sequence<T>(first: T, next: (T) -> T?) -> UnfoldFirstIterator<T>
public func sequence<T, State>(state: State, next: (inout State) -> T?)
    -> UnfoldIterator<T, State>
```

</details>


