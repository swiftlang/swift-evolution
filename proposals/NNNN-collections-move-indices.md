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

* Code that handles indices has to perform atomic reference counting,
  which has significant overhead and can prevent the optimizer from
  making other improvements.

* Additional references to a collections storage block the
  library-level copy-on-write optimization: in-place mutation of
  uniquely-referenced data.  A live index makes underlying storage
  non-uniquely referenced, forcing unnecessary copies when the
  collection is mutated.  In the standard library, `Dictionary` and
  `Set` use a double-indirection trick to work around this issue.
  Unfortunately, even this trick is not a solution, because (as we
  have recently realized) it isn't threadsafe. [^1]

By giving responsibility for traversal to the collection, we ensure
that operations that need the collection's structure always have it,
without the costs of holding references in indices.

## Other Benefits

Although this change is primarily motivated by performance, it has
other significant benefits:

* Simplifies implementation of non-trivial indices.
* Allows us to eliminate the `Range`/`Interval` distinction.
* Making traversal a direct property of the `Collection` protocol,
  rather than its associated `Index` type, is closer to most peoples'
  mental model for collections, and simplifies the writing of many
  generic constraints.
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

## Overview of Changes

To facilitate evaluation, we've submitted a
[pull request](https://github.com/apple/swift/pull/2108) for the code
and documentation changes implementing this proposal.  See below for a 
discussion of the major points.

### Collection Protocol Hierarchy

In the proposed model, indices don't have any requirements beyond
`Comparable`, so index protocols are eliminated.  Instead, we
introduce `BidirectionalCollection` and `RandomAccessCollection` to
provide the same index traversal distinctions, as shown here:

```
                     +--------+
                     |Sequence|
                     +---+----+
                         |                                                                               .
                    +----+-----+
                    |Collection|
                    +----+-----+
                         |
          +--------------+-------------+
          |              |             |
          |     +--------+--------+    |
          |     |MutableCollection|    |
          |     +-----------------+    |
          |                            |
+---------+-------------+    +---------+----------------+
|BidirectionalCollection|    |RangeReplaceableCollection|
+---------+-------------+    +--------------------------+
          |
 +--------+-------------+
 |RandomAccessCollection|
 +----------------------+
```

These protocols compose naturally with the existing protocols
`MutableCollection` and `RangeReplaceableCollection` to describe a
collection's capabilities, e.g.

```swift
struct Array<Element> 
  : RandomAccessCollection, 
    MutableCollection, 
    RangeReplaceableCollection { ... }
    
struct UnicodeScalarView : BidirectionalCollection { ... }
```

### Range Protocols and Types

The proposal adds several new types and protocols to support ranges:

```
                 +-------------+
                 |RangeProtocol|
                 +-----+-------+
                       |
          +------------+---------------------+
          |                                  |
+---------+-----------+           +----------+--------+
|HalfOpenRangeProtocol|           |ClosedRangeProtocol|
+----+------+---------+    :      +-------+------+----+
     |      |              :              |      |
+----+---+  |  +...........+...........+  |  +---+----------+
|Range<T>|  |  : RandomAccessCollection:  |  |ClosedRange<T>|
+========+  |  +....+...............+..+  |  +==============+
            |       |               |     |
       +----+-------+----+       +--+-----+--------------+
       |CountableRange<T>|       |CountableClosedRange<T>|
       +=================+       +=======================+
```

* The old `Range<T>`, `ClosedInterval<T>`, and
  `OpenInterval<T>` are replaced with four new generic range types:

  * Two for general ranges whose bounds are `Comparable`: `Range<T>`
    and `ClosedRange<T>`.  Having a separate `ClosedRange` type allows
    us to address the vexing inability of the old `Range` to represent
    a range containing the maximal value of its bound.
  
  * Two for ranges that additionally conform to
    `RandomAccessCollection`, requiring bounds that are `Strideable`
    with `Stride` conforming to `Integer` : `CountableRange<T>` and
    `CountableClosedRange<T>`. [These types can be folded into 
    `Range` and `ClosedRange` when Swift acquires conditional 
    conformance capability.]

We also introduce three new protocols:

* `RangeProtocol`
* `HalfOpenRangeProtocol`
* `ClosedRangeProtocol`

These protocols mostly exist facilitate implementation-sharing among
the range types, and would seldom need to be implemented outside the
standard library.

### The `Comparable` Requirement on Indices

In this model indices store the minimal amount of information required
to describe an element's position.  Usually an index can be
represented with one or two `Int`s that efficiently encode the path to
the element from the root of a data structure.  Since one is free to
choose the encoding of the “path”, we think it is possible to choose
it in such a way that indices are cheaply comparable.  That has been
the case for all of the indices required to implement the standard
library, and a few others we investigated while researching this
change.

It's worth noting that this requirement isn't strictly
necessary. Without it, though, indices would have no requirements
beyond `Equatable`, and creation of a `Range<T>` would have to be
allowed for any `T` conforming to `Equatable`. As a consequence, most
interesting range operations, such as containment checks, would be
unavailable unless `T` were also `Comparable`, and we'd be unable to
provide comple bounds-checking in the general case.

That said, the requirement has real benefits.  For example, it allows
us to support distance measurement between arbitrary indices, even in
collections without random access traversal.  In the old model,
`x.distance(to: y)` for these collections had the undetectable
precondition that `x` precede `y`, with unpredictable consequences for
violation in the general case.

## Downsides

The proposed approach has several disadvantages, which we explore here
in the interest of full disclosure:

* Index movement is more complex in principle, since it now involves
  not only the index, but the collection as well. The impact of this
  complexity is limited somewhat because it's very common that code
  moving indices occurs in a method of the collection type, where
  “implicit `self`” kicks in.  The net result is that index
  manipulations end up looking like free function calls:
      
  ```swift
  let j = successor(i)            // self.successor(i)
  let k = index(5, stepsFrom: j)  // self.index(5, stepsFrom: j)
  ```
  
* The
  [new index manipulation methods](https://github.com/apple/swift/blob/swift-3-indexing-model/stdlib/public/core/Collection.swift#L135)
  increase the API surface area of `Collection`, which is already
  quite large since algorithms are implemented as extensions.

* Because Swift is unable to express conditional protocol
  conformances, implementing this change has required us to create a
  great deal of complexity in the standard library API.  Aside from
  the two excess “`Countable`” range types, there are new overloads
  for slicing and twelve distinct slice types that capture all the
  combinations of traversal, mutability, and range-replaceability.
  While these costs are probably temporary, they are very real in the
  meantime.
  
* The API complexity mentioned above stresses the type checker,
  requiring
  [several](https://github.com/apple/swift/commit/1a875cb922fa0c98d51689002df8e202993db2d3)
  [changes](https://github.com/apple/swift/commit/6c56af5c1bc319825872a25041ec33ab0092db05)
  just to get our test code to type-check in reasonable time.  Again,
  an ostensibly temporary—but still real—cost.

## Limitations of the Model

Ideally, our collection model would allow us to implement every
interesting data structure with memory safety, optimal performance,
value semantics, and a variety of other useful properties such as
minimal invalidation of indexes upon mutation.  In practice, these
goals and the Swift language model interact in complicated ways,
preventing some designs altogether, and suggesting a variety of
implementation strategies for others that can be selected based on
one's priorities.  We've done some in-depth investigation of these
implications, but presenting and explaining them is well beyond the
scope of this proposal.

We can, however, be fairly sure that this change does not regress our
ability to build any Collections that could have been built in Swift
2.2.  After all, it is still *possible* to implement indices that store
references and have the old traversal methods (the collection's
traversal methods would simply forward to those of the index), so we
haven't lost the ability to express anything.

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
