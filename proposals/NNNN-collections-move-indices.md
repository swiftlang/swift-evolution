# New collections model

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-collections-move-indices.md)
* Author(s): [Dmitri Gribenko](https://github.com/gribozavr),
  [Dave Abrahams](https://github.com/dabrahams),
  [Maxim Moiseev](https://github.com/moiseev)
* [Swift-evolution thread](http://news.gmane.org/find-root.php?message_id=CA%2bY5xYfqKR6yC2Q%2dG7D9N7FeY%3dxs1x3frq%3d%3dsyGoqYpOcL9yrw%40mail.gmail.com)
* Status: **Awaiting review**
* Review manager: TBD

## Summary

We propose a new model for `Collection`s wherein responsibility for
index traversal is moved from the index to the collection itself.  For
example, instead of writing `i.successor()`, one would write
`c.successor(i)`.  We also propose the following changes as a
consequence of the new model:

* A collection's `Index` can be any `Comparable` type.
* The distinction between intervals and ranges disappears, leaving
  only ranges.
* A closed range that includes the maximal value of its `Bound` type
  is now representable and does not trap.
* Make existing “private” in-place index traversal methods available
  publicly.

## Motivation

In collections that don't support random access, (string views, sets,
dictionaries, trees, etc.) it's very common that deriving one index
value from another requires somehow inspecting the collection's data.
For example, you could represent an index into a hash table as an
offset into the underlying storage, except that one needs to actually
look at *structure* of the hash table to reach the next bucket.  In
the current model, supporting `i.successor()` means that the index
must additionally store not just an offset, but a reference to the
collection's structure.

The consequences for performance aren't pretty:

* Code that handles indices has to perform reference counting, which
  blocks some optimizations, and definitely means more work at runtime.

* Indices that keep references to collections' storage block the
  copy-on-write optimization.  A live index makes underlying storage
  non-uniquely referenced, forcing unnecessary copies when the
  collection is mutated.  In the standard library, `Dictionary` and
  `Set` use a double-indirection trick to work around this issue.
  Unfortunately, even this trick is not a solution, because (as we
  have just realized) it isn't threadsafe. [^1]

By giving responsibility for traversal to the collection, we ensure
that operations that need the collection's structure always have it,
without the costs of holding references in indices.

## Other Benefits

Although this change is primarily motivated by performance, it has
other significant benefits:

* Simplifies implementation of non-trivial indices.
* Allows us to eliminate the `Range`/`Interval` distinction.
* Makes it feasible to fix existing concurrency issues in `Set` and
  `Dictionary` indices.
* Allows `String` views to share a single index type, letting us
  eliminate the need for cumbersome index conversion functions (not
  part of this proposal, but planned).

## Out of Scope

This proposal intentionally does not:

* Expand the set of concrete collections provided by the standard
  library.
* Expand the set of collection protocols to provide functionality
  beyond what is already provided (for example, protocols for sorted
  collections, queues etc.)  Discussing how other concrete collections
  fit into the current protocol hierarchy is in scope, though.

## Proposed solution

We propose to allow implementing collections whose indices don't have
reference-countable stored properties.

From the API standpoint, this implies that indices can't be moved
forward or backward by themselves (for example, calling `i.successor()`
is not possible anymore for an arbitrary index).  Only the corresponding
collection instance can advance indices (e.g., `c.next(i)`).  By
removing API requirements from indices, we reduce the required amount of
information that indices need to store or reference.

In this model indices can store the minimal amount of information only
about the element position in the collection.  Usually index can be
represented a few of word-sized integers (typically, just one) that
efficiently encode the "path" in the data structure from the root to the
element.  Since one is free to choose the encoding of the "path", we
think that it should be possible to choose it in such a way that indices
are cheaply comparable.

### Protocol hierarchy

In the proposed model indices don't have any method or property
requirements (these APIs were moved to Collection), so index protocols
are eliminated.  Instead, we are introducing `BidirectionalCollection`
and `RandomAccessCollection`.  These protocols naturally compose with
existing `MutableCollection` and `RangeReplaceableCollection` to
describe the collection's capabilities:

```swift
protocol Sequence { ... }
protocol Collection : Sequence { ... }

protocol MutableCollection : Collection { ... }
protocol RangeReplaceableCollection : Collection { ... }

protocol BidirectionalCollection : Collection { ... } // new
protocol RandomAccessCollection : BidirectionalCollection { ... } // new
```

```
                         Sequence
                            ^
                            |
                            +
                        Collection
                         ^      ^
                         |      +--------+
    BidirectionalCollection     |        |
                         ^      |   MutableCollection
                         |      |
                         |      |
     RandomAccessCollection    RangeReplaceableCollection
```

### Analysis

Advantages of the proposed model:

* Indices don't need to keep a reference to the collection.
  - Indices are simpler to implement.
  - Indices are not reference-countable, and thus cheaper to
    handle.
  - Handling indices does not cause refcounting, and does not block
    optimizations.

* The hierarchy of index protocols is removed, and is replaced with
  protocols for forward, bidirectional and random-access
  collections.
  - This is closer to how people generally talk about collections.
  - Writing a generic constraint for bidirectional and
    random-access collections becomes simpler.

* Indices can conform to `Comparable` without incurring extra
  memory overhead.  Indices need to store all the necessary data
  anyway.

  This allows, for example, to relax the precondition on the
  `distance(from:to:)` method: even for forward collections, it is now
  possible to measure the distance from a later index to an earlier
  index.

* `Dictionary` and `Set` indices (and other non-trivial indices) can't
  create opportunities for data races.

* While this model allows to design indices that are not
  reference-countable, it does not prohibit defining indices that
  *are* reference countable.
  - All existing collection designs are still possible to
    implement, but some are less efficient than the new model allows.
  - If there is a specialized collection that needs
    reference-countable indices for algorithmic or memory
    efficiency, where such tradeoff is reasonable, such a
    collection is still possible to implement in the new model.
    See the discussion of trees below, the tree design (2)(c).

Neutral as compared to the current collections:

* A value-typed linked list still can't conform to `Collection`.
  A reference-typed one can.

Disadvantages of the proposed collections model:

* Advancing an index forward or backward becomes harder -- the statement
  now includes two entities (collection and index):

  ```
    j = c.next(i)    vs.    j = i.successor()
  ```

  In practice though, we found that when the code is performing index
  manipulations, the collection is typically still around stored in a
  variable, so the code does not need to reach out for it in a
  non-trivial way.

* Collection's API now includes methods for advancing indices.

### Implementation difficulties

We have a couple of implementation difficulties that will be solved with
further improvements to the compiler or the generics system.  These
issues will cause the new API to be suboptimal in the short term, but as
the necessary compiler features will be implemented, the API will
improve.  We don't consider any of these issues to be blockers to adopt
the proposed collections model.

* `Range` has conflicting requirements:

  - range bounds need to be comparable and incrementable, in order
     for `Range` to conform to `Collection`,

  - we frequently want to use `Range` as a "transport" data type, just
    to carry a pair of indices around (for example, as an argument for
    `removeSubrange(_:)`).  Indices are neither comparable nor
    incrementable.

  Solution: add conditional a conformance for `Range` to `Collection`
  when the bounds conform to `Strideable`.  We don't have this compiler
  feature now.  As a workaround, we will introduce a parallel type,
  `StrideableRange`.

2. We can't specify constraints on associated types.  This forces many
   algorithms to specify constraints that should be implied by
   `Sequence` or `Collection` conformances.

   Solution: constraints on associated types are a desirable
   language feature, part of the Swift generics model.  This issue
   will be fixed by compiler improvements.

## Case study: trees

Trees are very interesting data structures with many unique
requirements.  We are interested in allowing efficient and memory-safe
implementations of collections based on a search trees (e.g., RB trees
or B-trees).  The specific requirements are as follows.

- The collection and indices should be memory-safe.  They should provide
  good QoI in the form of precondition traps.  Ensuring memory-safety
  shouldn't cause unreasonable performance or memory overhead.

- Collection instances should be able to share nodes on mutation
  (persistent data structures).

- Subscript on an index should cost at worst amortized O(1).

- Advancing an index to the next or previous position should cost
  at worst amortized O(1).

- Indices should not contain reference countable stored properties.

- Mutating or deleting an element in the collection should not
  invalidate indices pointing at other elements.

  This design constraint needs some extra motivation, because it might
  not be obvious.  Preserving index validity across mutation is
  important for algorithms that iterate over the tree and mutate it in
  place, for example, removing a subrange of elements between two
  indices, or removing elements that don't satisfy a predicate.  When
  implementing such an algorithm, you would typically have an index that
  points to the current element.  You can copy the index, advance it,
  and then remove the previous element using its index.  If the mutation
  of the tree invalidates all indices, it is not possible to continue
  the iteration.  Thus, it is desired to invalidate just one index for
  the element that was deleted.

It is not possible to satisfy all of these requirements at the same
time.  Designs that cover some of the requirements are possible.

1. Persistent trees with O(log n) subscripting and advancing, and strict
   index invalidation.

   If we choose to make a persistent data structure with node reuse,
   then the tree nodes can't have parent pointers (a node can have
   multiple different parents in different trees).  This means that it
   is not possible to advance an index in O(1).  If we need to go up the
   tree while advancing the index, without parent pointers we would need
   to traverse the tree starting from the root in O(log n).

   Thus, index has to essentially store a path through the tree from the
   root to the node (it is usually possible to encode this path in a
   64-bit number).  Since the index stores the path, subscripting on
   such an index would also cost O(log n).

   We should note that persistent trees typically use B-trees, so the
   base of the logarithm would be typically large (e.g., 32).  We also
   know that the size of the RAM is limited.  Thus, we could treat the
   O(log n) complexity as effectively constant for all practical
   purposes.  But the constant factor will be much larger than in other
   designs.

   Swift's collection index model does not change anything as compared
   to other languages.  The important point is that the proposed index
   model allows such implementations of persistent collections.

2. Trees with O(1) subscripting and advancing.

   If we want subscripting to be O(1), then the index has to store a
   pointer to a tree node.  Since we want avoid reference countable
   properties in indices, the node pointer should either be
   `unsafe(unowned)` or an `UnsafePointer`.  These pointers can't be
   dereferenced safely without knowing in advance that it is safe to do
   so.  We need some way to quickly check if it is safe to dereference
   the pointer stored in the node.

   A pointer to a tree node can become invalid when the node was
   deallocated.  A tree node can be deallocated if the corresponding
   element is removed from the tree.

   (a) Trees with O(1) subscripting and advancing, and strict index
       invalidation.

       One simple way to perform the safety check when
       dereferencing the unsafe pointer stored within the index
       would be to detect any tree mutation between the index
       creation and index use.  It is simple to do with version
       numbers: we add an ID number to every tree.  This ID would
       be unique among all trees created within the process, and it
       would be re-generated on every mutation.  The tree ID is
       copied into every index.  When the index is used with the
       collection, we check that the ID of the tree matches the
       tree ID stored in the index.  This fast check ensures memory
       safety.

   (b) Trees with O(1) subscripting and advancing, permissive index
       invalidation, and extra storage to ensure memory safety.

       Another way to perform the safety check would be to directly
       check if the unsafe pointer stored in the index is actually
       linked into the tree.  To do that with acceptable time
       complexity, we would need to have an extra data structure
       for every tree, for example, a hash table-based set of all
       node pointers.  With this design, all index operations get
       an O(1) hit for the hash table lookup for the safety check,
       but we get an O(log n) memory overhead for the extra data
       structure.  On the other hand, a tree already has O(log n)
       memory overhead for allocating nodes themselves, thus the
       extra data structure would only increase the constant factor
       on memory overhead.

|                                      | (1)      | (2)(a)  | (2)(b) |
| -------------------------------------|----------|---------|------- |
|                          Memory-safe | Yes      | Yes     | Yes    |
|    Indices are not reference-counted | Yes      | Yes     | Yes    |
|                         Shares nodes | Yes      | No      | No     |
|             Subscripting on an index | O(log n) | O(1)    | O(1)   |
|                   Advancing an index | O(log n) | O(1)    | O(1)   |
| Deleting does not invalidate indices | No       | No      | Yes    |
| Extra O(n) storage just for safety checks | No       | No      | Yes |

Each of the designs discussed above has its uses, but the intuition
is that (2)(a) is the one most commonly needed in practice.  (2)(a)
does not have the desired index invalidation properties.  There is
a small number of commonly used algorithms that require that
property, and they can be provided as methods on the collection,
for example `removeAll(in: Range<Index>)` and
`removeAll(_: (Element)->Bool)`.

If we were to allow reference-counted indices (basically, the
current collections model), then an additional design is possible
-- let's call it (2)(c) for the purpose of discussion.  This design
would be like (2)(b), but won't require extra storage that is used
only for safety checks.  Instead, every index would pay a RC
penalty and carry a strong reference to the tree node.

Note that (2)(c) is still technically possible to implement in the
new collection index model, it just goes against a goal of having
indices free of reference-counted stored properties.

## Collection APIs

This is a rough sketch of the API.

There are a few API details that we can't express in Swift today because of the
missing compiler features, or extra APIs that only exist as workarounds.  It is
important to see what they are to understand the grand plan, so we marked them
with `FIXME(compiler limitation)` below.

There are a few minor open questions that are marked with `FIXME(design)`.

```swift
// No changes from the current scheme.
public protocol IteratorProtocol {
  associatedtype Element
  mutating func next() -> Element?
}

// No changes from the current scheme.
public protocol Sequence {
  associatedtype Iterator : IteratorProtocol

  /// A type that represents a subsequence of some of the elements.
  associatedtype SubSequence
  // FIXME(compiler limitation):
  // associatedtype SubSequence : Sequence
  //   where Iterator.Element == SubSequence.Iterator.Element

  func makeIterator() -> Iterator

  // Defaulted requirements, algorithms.

  @warn_unused_result
  func map<T>(
    @noescape transform: (Generator.Element) throws -> T
  ) rethrows -> [T]

  @warn_unused_result
  func dropFirst(n: Int) -> SubSequence

  // Other algorithms have been omitted for brevity since their signatures
  // didn't change.
}

/*
FIXME(compiler limitation): we can't write this extension now because
concrete typealiases in extensions don't work well.

extension Sequence {
  /// The type of elements that the sequence contains.
  ///
  /// It is just a shorthand to simplify generic constraints.
   typealias Element = Iterator.Element
}
*/

// `Indexable` protocol is an unfortunate workaround for a compiler limitation.
// Without this workaround it is not possible to implement `IndexingIterator`.
//
// FIXME(compiler limitation): remove `Indexable`, and move all of its
// requirements to `Collection`.
public protocol Indexable {
  /// A type that represents a valid position in the collection.
  ///
  /// Valid indices consist of the position of every element and a
  /// "past the end" position that's not valid for use as a subscript.
  associatedtype Index : Comparable

  associatedtype _Element
  var startIndex: Index { get }
  var endIndex: Index { get }

  /// Returns the element at the given `position`.
  ///
  /// - Complexity: O(1).
  subscript(position: Index) -> _Element { get }

  /// Returns the next consecutive index after `i`.
  ///
  /// - Precondition: `self` has a well-defined successor.
  ///
  /// - Complexity: O(1).
  @warn_unused_result
  func next(i: Index) -> Index

  /// Equivalent to `i = self.next(i)`, but can be faster because it
  /// does not need to create a new index.
  ///
  /// - Precondition: `self` has a well-defined successor.
  ///
  /// - Complexity: O(1).
  func _nextInPlace(i: inout Index)
  // This method has a default implementation.

  /// Traps if `index` is not in `bounds`, or performs
  /// a no-op if such a check is not possible to implement in O(1).
  ///
  /// Use this method to implement cheap fail-fast checks in algorithms
  /// and wrapper data structures to bring the failure closer to the
  /// source of the bug.
  ///
  /// Do not use this method to implement checks that guarantee memory
  /// safety.  This method is allowed to be implemented as a no-op.
  ///
  /// - Complexity: O(1).
  func _failEarlyRangeCheck(index: Index, inBounds: Range<Index>)
  // This method has a default implementation.
  // FIXME(design): this API can be generally useful, maybe we should
  // de-underscore it, and make it a public API?

  /// Traps if `subRange` is not in `bounds`, or performs
  /// a no-op if such a check is not possible to implement in O(1).
  ///
  /// Use this method to implement cheap fail-fast checks in algorithms
  /// and wrapper data structures to bring the failure closer to the
  /// source of the bug.
  ///
  /// Do not use this method to implement checks that guarantee memory
  /// safety.  This method is allowed to be implemented as a no-op.
  ///
  /// - Complexity: O(1).
  func _failEarlyRangeCheck(subRange: Range<Index>, inBounds: Range<Index)
  // This method has a default implementation.
  // FIXME(design): this API can be generally useful, maybe we should
  // de-underscore it, and make it a public API?
}

/// A multi-pass sequence with addressable positions.
///
/// Positions are represented by an associated `Index` type.  Whereas
/// an arbitrary sequence may be consumed as it is traversed, a
/// collection is multi-pass: any element may be revisited merely by
/// saving its index.
///
/// The sequence view of the elements is identical to the collection
/// view.  In other words, the following code binds the same series of
/// values to `x` as does `for x in self {}`:
///
///     for i in startIndex..<endIndex {
///       let x = self[i]
///     }
public protocol Collection : Sequence, Indexable {
  /// A type that provides the sequence's iteration interface and
  /// encapsulates its iteration state.
  ///
  /// By default, a `Collection` satisfies `Sequence` by
  /// supplying a `IndexingIterator` as its associated `Iterator`
  /// type.
  associatedtype Iterator : IteratorProtocol = IndexingIterator<Self>

  /// A type that represents a slice of some of the elements.
  associatedtype SubSequence : Sequence, Indexable = Slice<Self>
  // FIXME(compiler limitation):
  // associatedtype SubSequence : Collection
  //   where
  //   Iterator.Element == SubSequence.Iterator.Element,
  //   SubSequence.SubSequence == SubSequence
  //
  // These constraints allow processing collections in generic code by
  // repeatedly slicing them in a loop.

  /// A signed integer type that can represent the number of steps between any
  /// two indices.
  associatedtype IndexDistance : SignedIntegerType = Int

  /// Returns the result of advancing `i` by `n` positions.
  ///
  /// - Returns:
  ///   - If `n > 0`, the result of applying `next` to `i` `n` times.
  ///   - If `n < 0`, the result of applying `previous` to `i` `-n` times.
  ///   - Otherwise, `i`.
  ///
  /// - Precondition: `n >= 0` if `self` only conforms to `Collection`.
  /// - Complexity:
  ///   - O(1) if `self` conforms to `RandomAccessCollection`.
  ///   - O(`abs(n)`) otherwise.
  @warn_unused_result
  func advance(i: Index, by n: IndexDistance) -> Index
  // This method has a default implementation.

  /// Returns the result of advancing `i` by `n` positions or until it reaches
  /// `limit`.
  ///
  /// - Returns:
  ///   - If `n > 0`, the result of applying `next` to `i` `n` times,
  ///     but not past `limit`.
  ///   - If `n < 0`, the result of applying `previous` to `i` `-n` times,
  ///     but not past `limit`.
  ///   - Otherwise, `i`.
  ///
  /// - Precondition: `n >= 0` if `self` only conforms to `Collection`.
  /// - Complexity:
  ///   - O(1) if `self` conforms to `RandomAccessCollection`.
  ///   - O(`abs(n)`) otherwise.
  @warn_unused_result
  func advance(i: Index, by n: IndexDistance, limit: Index) -> Index
  // This method has a default implementation.

  /// Measure the distance between `start` and `end`.
  ///
  /// - Precondition: `start` and `end` are valid indices into this
  ///   collection.
  ///
  /// - Complexity:
  ///   - O(1) if `self` conforms to `RandomAccessCollection`.
  ///   - O(`abs(n)`) otherwise, where `n` is the function's result.
  @warn_unused_result
  func distance(from start: Index, to end: Index) -> IndexDistance
  // This method has a default implementation.

  /// A type for the collection of indices for this collection.
  ///
  /// An instance of `Indices` can hold a strong reference to the collection
  /// itself, causing the collection to be non-uniquely referenced.  If you
  /// need to mutate the collection while iterating over its indices, use the
  /// `next()` method to produce indices instead.
  associatedtype Indices : Sequence, Indexable = DefaultCollectionIndices<Self>
  // FIXME(compiler limitation):
  // associatedtype Indices : Collection
  //   where
  //   Indices.Iterator.Element == Index,
  //   Indices.Index == Index,
  //   Indices.SubSequence == Indices

  /// A collection of indices for this collection.
  var indices: IndexRange { get }
  // This property has a default implementation.

  /// Returns the number of elements.
  ///
  /// - Complexity: O(1) if `self` conforms to `RandomAccessCollection`;
  ///   O(N) otherwise.
  var count: IndexDistance { get }
  // This property has a default implementation.

  /// Returns the element at the given `position`.
  ///
  /// - Complexity: O(1).
  subscript(position: Index) -> Generator.Element { get }

  /// - Complexity: O(1).
  subscript(bounds: Range<Index>) -> SubSequence { get }
  // This property has a default implementation.

  // Other algorithms (including `first`, `isEmpty`, `index(of:)`, `sorted()`
  // etc.) have been omitted for brevity since their signatures didn't change.
}

/// A collection whose indices can be advanced backwards.
public protocol BidirectionalCollection : Collection {
  // FIXME(compiler limitation):
  // associatedtype SubSequence : BidirectionalCollection

  // FIXME(compiler limitation):
  // associatedtype Indices : BidirectionalCollection

  /// Returns the previous consecutive index before `i`.
  ///
  /// - Precondition: `self` has a well-defined predecessor.
  ///
  /// - Complexity: O(1).
  @warn_unused_result
  func previous(i: Index) -> Index

  /// Equivalent to `i = self.previous(i)`, but can be faster because it
  /// does not need to create a new index.
  ///
  /// - Precondition: `self` has a well-defined predecessor.
  ///
  /// - Complexity: O(1).
  func _previousInPlace(i: inout Index)
  // This method has a default implementation.

  // Other algorithms (including `last`, `popLast(_:)`, `dropLast(_:)`,
  // `suffix(_:)` etc.) have been omitted for brevity since their
  // signatures didn't change.
}

/// A collection whose indices can be advanced by an arbitrary number of
/// positions in O(1).
public protocol RandomAccessCollection : BidirectionalCollection {
  // FIXME(compiler limitation):
  // associatedtype SubSequence : RandomAccessCollection

  // FIXME(compiler limitation):
  // associatedtype Indices : RandomAccessCollection

  associatedtype Index : Strideable
  // FIXME(compiler limitation): where Index.Distance == IndexDistance
  // FIXME(design): does this requirement to conform to `Strideable`
  // limit possible collection designs?
}

public protocol MyMutableCollectionType : MyForwardCollectionType {
  associatedtype SubSequence : Collection = MutableSlice<Self>
  // FIXME(compiler limitation):
  // associatedtype SubSequence : MutableCollection

  /// Access the element at `position`.
  ///
  /// - Precondition: `position` indicates a valid position in `self` and
  ///   `position != endIndex`.
  ///
  /// - Complexity: O(1)
  subscript(i: Index) -> Generator.Element { get set }

  /// Returns a collection representing a contiguous sub-range of
  /// `self`'s elements.
  ///
  /// - Complexity: O(1) for the getter, O(`bounds.count`) for the setter.
  subscript(bounds: Range<Index>) -> SubSequence { get set }
  // This subscript has a default implementation.
}

// No changes from the current scheme.
public protocol RangeReplaceableCollection : Collection { ... }
```

## Impact on existing code

Code that **does not need to change**:

* Code that works with `Array`, `ArraySlice`, `ContiguousArray`, their
  indices (`Int`s), performs index arithmetic.

* Code that operates on arbitrary collections and indices (on concrete
  instances or in generic context), but does not advance indices

* Iteration over collection's indices with `c.indices` does not change
  when:
  - the underlying collection is not mutated,
  - or it is known that `c.indices` is trivial (for example, in
    `Array`),
  - or when performance is not a concern:

  ```swift
  // No change, because 'c' is not mutated, only read.
  for i in c.indices {
    print(i, c[i])
  }

  // No change, because Array's index collection is trivial and does not
  // hold a reference to Array's storage.  There is no performance
  // impact.
  for i in myArray.indices {
    c[i] *= 2
  }

  // No change, because 'c' is known to be small, and doing a copy on
  // the first loop iteration is acceptable.
  for i in c.indices {
    c[i] *= 2
  }
  ```

* APIs of high-level collection algorithms don't change, even for
  algorithms that accept indices as parameters or return indices (e.g.,
  `index(of:)`, `min()`, `sort()`, `prefix()`, `prefix(upTo:)` etc.)

Code that **needs to change**:

* Code that advances indices (`i.successor()`, `i.predecessor()`,
  `i.advanced(by:)` etc.) or calculates distances between indices
  (`i.distance(to:)`) now needs to call a method on the collection
  instead.

  ```swift
  // Before:
  var i = c.indexOf { $0 % 2 == 0 }
  i = i.successor()
  print(c[i])

  // After:
  var i = c.indexOf { $0 % 2 == 0 } // No change in algorithm API.
  i = c.next(i)                     // Advancing an index requires a collection instance.
  print(c[i])                       // No change in subscripting.
  ```

  The transformation from `i.successor()` to `c.next(i)` is non-trivial.
  Performing it correctly requires knowing extra information -- how to
  get the corresponding collection.  In the general case, it is not
  possible to perform this migration automatically.  In some cases, a
  sophisticated migrator could handle the easy cases.

* Custom collection implementations need to change.  A simple fix would
  be to just move the the methods from indices to collections to satisfy
  new protocol requirements.  This is a more or less mechanical fix that
  does not require design work.  This fix would allow the code to
  compile and run.

  In order to take advantage of the performance improvements in
  the new model, and remove reference-counted stored properties from
  indices, the representation of the index might need to be redesigned.

  Implementing custom collections, as compared to using collections, is
  a niche case.  We believe that for custom collection types it is
  sufficient to provide clear steps for manual migration that don't
  require a redesign.  Implementing this in an automated migrator might
  be possible, but would be a heroic migration for a rare case.

## Implementation status

Since this is a large change to the collection model, to evaluate it, we have
prepared [a prototype
implementation](https://github.com/apple/swift/blob/master/test/Prototypes/CollectionsMoveIndices.swift).
Shawn Erickson and Austin Zheng have been working on re-implementing the
prototype in the core library on the [swift-3-indexing-model
branch](https://github.com/apple/swift/tree/swift-3-indexing-model).

The prototype and this proposal have one major difference around the use
of unowned references.  In the prototype, we are suggesting to use
unowned references to implement `c.indices`.  Unfortunately, we realized
that this design can create an unpredictable user model.  For example:

```swift
let c = getCollection()
for i in c.indices {
  if i.isRed {
    print(c[i])
  }
  print("no")
}
```

If ARC can prove that the collection does not contain indices where
`i.isRed` is true, then it can deinit the collection right after
constructing the index collection, before starting the loop.  Then, the
first time we need to advance the index, dereferencing the unowned
reference to the collection storage (which is gone now) will cause a
trap.

## Alternatives considered

We considered index-less models, for example, [D's
std.range](https://dlang.org/library/std/range.html) (see also [On
Iteration by Andrei
Alexandrescu](http://www.informit.com/articles/printerfriendly/1407357)).
Ranges work well for reference-typed collections, but it is not clear
how to adjust the concept of D's range (similar to `Slice` in Swift) for
mutable value-typed collections.  In D, you process a collection by
repeatedly slicing off elements.  Once you have found an element that
you would like to mutate, it is not clear how to actually change the
original collection, if the collection and its slice are value types?

----

[^1]: `Dictionary` and `Set` use a double-indirection trick to avoid
disturbing the reference count of the storage with indices.

```
    +--+    class                       struct
    |RC|---------+          +-----------------+
    +--+ Storage |<---------| DictionaryIndex |
      |          |          | value           |
      +----------+          +-----------------+
          ^
    +--+  |     class                struct
    |RC|-------------+        +------------+
    +--+ Indirection |<-------| Dictionary |
      |  ("owner")   |        | value      |
      +--------------+        +------------+
```

Instances of `Dictionary` point to an indirection, while
instances of `DictionaryIndex` point to the storage itself.
This allows us to have two separate reference counts.  One of
the refcounts tracks just the live `Dictionary` instances, which
allows us to perform precise uniqueness checks.

The issue that we were previously unaware of is that this scheme
is not thread-safe.  When uniquely-referenced storage is being
mutated in place, indices can be concurrently being incremented
(on a different thread).  This would be a read/write data race.

Fixing this data race (to provide memory safety) would require
locking dictionary storage on every access, which would be an
unacceptable performance penalty.

