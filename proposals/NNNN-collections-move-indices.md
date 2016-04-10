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

## Overview of Type And Protocol Changes

This section covers the proposed structural changes to the library at
a high level.  Details such as protocols introduced purely to work
around compiler limitations (e.g. `Indexable` or `IndexableBase`) have
been omitted.  For a complete view of the the code
and documentation changes implementing this proposal, please see this
[pull request](https://github.com/apple/swift/pull/2108).

### Collection Protocol Hierarchy

In the proposed model, indices don't have any requirements beyond
`Comparable`, so the `ForwardIndex`, `BidirectionalIndex`, and
`RandomAccessIndex` protocols are eliminated.  Instead, we introduce
`BidirectionalCollection` and `RandomAccessCollection` to provide the
same traversal distinctions, as shown here:

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
                +------+------+
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
    with `Stride` conforming to `Integer`: `CountableRange<T>` and
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

### The Associated `Indices` Type

The following code iterates over the indices of all elements in
`collection`:

```swift
for index in collection.indices { ... }
```

In Swift 2, `collection.indices` returned a `Range<Index>`, but
because a range is a simple pair of indices and indices can no longer
be advanced on their own, `Range<Index>` is no longer iterable.

In order to keep code like the above working, `Collection` has
acquired an associated `Indices` type that is always iterable, and
three generic types were introduced to provide a default `Indices` for
each `Collection` traversal category: `DefaultIndices<C>`,
`DefaultBidirectionalIndices<C>`, and `DefaultRandomAccessIndices<C>`.
These types store the underlying collection as a means of traversal.
Collections like `Array` whose `Indices` don't need the collection
simply use `typealias Indices = CountableRange<Index>`.

### Expanded Default Slice Types
      
Because Swift doesn't support conditional protocol conformances and
the three traversal distinctions have been moved into the `Collection`
hierarchy, the four generic types `Slice`, `MutableSlice`,
`RangeReplaceableSlice`, and `MutableRangeReplaceableSlice` have
become twelve, with the addition of variations such as
`RangeReplaceableBidirectionalSlice`.
      
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
  
## Detailed API Changes

In this section we describe the new APIs at a high level

To facilitate evaluation, we've submitted a
[pull request](https://github.com/apple/swift/pull/2108) for the code
and documentation changes implementing this proposal.  See below for a
discussion of the major points.

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
