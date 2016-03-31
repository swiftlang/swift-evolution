# Implement a rotate algorithm, equivalent to std::rotate() in C++

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-implement-a-rotate-algorithm.md)
* Author(s): [Nate Cook](https://github.com/natecook1000), [Sergey Bolshedvorsky](https://github.com/bolshedvorsky)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is to add rotation and in-place reversing methods to Swift's
standard library collections.

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002213.html)

## Motivation

Rotation is one of the most important algorithms. It is a fundamental tool used in many 
other algorithms with applications even in GUI programming. 

The "rotate" algorithm performs a left rotation on a range of elements.
Specifically, it swaps the elements in the range `startIndex..<endIndex`
according to a `middle` index in such a way that the element at `middle` becomes
the first element of the new range and `middle - 1` becomes the last element.
The result of the algorithm is the new index of the element that was originally
first in the collection.

```swift
var a = [10, 20, 30, 40, 50, 60, 70]
let i = a.rotate(2)
// a == [30, 40, 50, 60, 70, 10, 20]
// i == 5
```

The index returned from a rotation can be used as the pivot in a second rotation
to return the collection to its original state, like this:

```swift
a.rotate(i)
// a == [10, 20, 30, 40, 50, 60, 70]
```

There are three different versions of the rotate algorithm, optimized for
collections with forward, bidirectional, and random access indices. The
complexity of the implementation of these algorithms makes the generic rotate
algorithm a perfect candidate for the standard library.

<details>
  <summary>**Example C++ Implementations**</summary>

**Forward indices** are the simplest and most general type of index and support 
only one-directional traversal.

The C++ implementation of the rotate algorithm for the `ForwardIterator` 
(`ForwardIndex` in Swift's' standard library) may look like this:

```C++
template <ForwardIterator I>
I rotate(I f, I m, I l, std::forward_iterator_tag) {
    if (f == m) return l;
    if (m == l) return f;
    pair<I, I> p = swap_ranges(f, m, m, l);
    while (p.first != m || p.second != l) {
        if (p.second == l) {
            rotate_unguarded(p.first, m, l);
            return p.first;
        }
        f = m;
        m = p.second;
        p = swap_ranges(f, m, m, l);
    }
    return m;
}
```

**Bidirectional indices** are a refinement of forward indices that
additionally support reverse traversal.

The C++ implementation of the rotate algorithm for the BidirectionalIterator 
(BidirectionalIndex in Swift's stdlib) may look like this:

```C++
template <BidirectionalIterator I>
I rotate(I f, I m, I l, bidirectional_iterator_tag) {
    reverse(f, m);
    reverse(m, l);
    pair<I, I> p = reverse_until(f, m, l);
    reverse(p.first, p.second);
    if (m == p.first) return p.second;
    return p.first;
}
```

**Random access indices** access to any element in constant time (both far and fast).

The C++ implementation of the rotate algorithm for the RandomAccessIterator 
(RandomAccessIndex in Swift's stdlib) may look like this:

```C++
template <RandomAccessIterator I>
I rotate(I f, I m, I l, std::random_access_iterator_tag) {
    if (f == m) return l;
    if (m == l) return f;
    DifferenceType<I> cycles = gcd(m - f, l - m);
    rotate_transform<I> rotator(f, m, l);
    while (cycles-- > 0) rotate_cycle_from(f + cycles, rotator);
    return rotator.m1;
}
```

</details>


## Proposed solution

The Swift standard library should provide generic implementations of the
"rotate" algorithm for all three index types, in both mutating and nonmutating
forms. The mutating form is called `rotate(firstFrom:)` and rotates the elements 
of a collection in-place. The nonmutating form of the "rotate"
algorithm is called `rotated(firstFrom:)` and return views onto the original
collection with the elements rotated, preserving the level of the original
collection's index type.

In addition, since the bidirectional algorithm depends on reversing the
collection's elements in-place, the standard library should also provide an
in-place `reverse()` method to complement the existing nonmutating `reversed()`
collection method.

## Detailed design

Rotation algorithms, structs and extensions will be implemented in
`swift/stdlib/public/core/Rotate.swift`.

The mutating methods will have the following declarations:

```swift
extension MutableCollection { // where Index: ForwardIndex
    /// Rotates the elements of the collection so that the element
    /// at `pivot` ends up first.
    ///
    /// - Returns: The new index of the element that was first 
    ///   pre-rotation.
    public mutating func rotate(firstFrom pivot: Index) -> Index
}

extension MutableCollection where Index: BidirectionalIndex {
    /// Reverses the elements of the collection in-place.
    public mutating func reverse()

    /// Rotates the elements of the collection so that the element
    /// at `pivot` ends up first.
    ///
    /// - Returns: The new index of the element that was first 
    ///   pre-rotation.
    public mutating func rotate(firstFrom pivot: Index) -> Index
}

extension MutableCollection where Index: RandomAccessIndex {
    /// Reverses the elements of the collection in-place.
    public mutating func reverse()

    /// Rotates the elements of the collection so that the element
    /// at `pivot` ends up first.
    ///
    /// - Returns: The new index of the element that was first 
    ///   pre-rotation.
    public mutating func rotate(firstFrom pivot: Index) -> Index
}
```

The nonmutating methods would return a tuple containing both a rotated view of
the original collection and the new index of the element that was previously
first. For forward- and bidirectional-collections, these methods would return
`FlattenCollection` and `FlattenBidirectionalCollection` instances, respectively:

```swift
extension Collection where Index: ForwardIndex,
    SubSequence: Collection, SubSequence.Index == Index
{
    /// Returns a rotated view of the elements of the collection, where the 
    /// element at `pivot` ends up first, and the index of the element that
    /// was previously first.
    func rotated(firstFrom pivot: Index) -> 
        (collection: FlattenCollection<[Self.SubSequence]>, 
        rotatedStart: FlattenCollectionIndex<[Self.SubSequence]>)
}

extension Collection where Index: BidirectionalIndex,
    SubSequence: Collection, SubSequence.Index == Index
{
    /// Returns a rotated view of the elements of the collection, where the 
    /// element at `pivot` ends up first, and the index of the element that
    /// was previously first.
    func rotated(firstFrom pivot: Index) -> 
        (collection: FlattenBidirectionalCollection<[Self.SubSequence]>, 
        rotatedStart: FlattenBidirectionalCollectionIndex<[Self.SubSequence]>)
}
```

There isn't a random-access `FlattenCollection`, since it can't walk an unknown
number of subcollections in O(1) time. However, a rotated random-access
collection has exactly two subcollections, so a specialized type can be created
to provide the rotated elements with a random-access index. This type will be
added as `RotatedCollection`:

```swift
/// A rotated view of an underlying random-access collection.
public struct RotatedCollection<
    Base: Collection where Base.Index: RandomAccessIndex>: Collection {
    // standard collection innards
}

/// The index type for a `RotatedCollection`.
public struct RotatedCollectionIndex<Base: RandomAccessIndex>: RandomAccessIndex {
    // standard index innards
}

extension Collection where Index: RandomAccessIndex,
    SubSequence: Collection, SubSequence.Index == Index
{
    /// Returns a rotated view of the elements of the collection, where the 
    /// element at `pivot` ends up first, and the index of the element that
    /// was previously first.
    func rotated(firstFrom pivot: Index) -> (collection: RotatedCollection<Self>, 
        rotatedStart: RotatedCollectionIndex<Self.Index>)
}
```

Lazy collections will also be extended with rotate methods that provide lazy rotation:

```swift
extension LazyCollection where
    Elements.Index: ForwardIndex, Elements.SubSequence: Collection,
    Elements.SubSequence.Index == Elements.Index, Elements.Index == Index
{
    func rotated(firstFrom pivot: Index) -> 
        (collection: LazyCollection<FlattenCollection<[Elements.SubSequence]>>, 
        rotatedStart: FlattenCollectionIndex<[Elements.SubSequence]>)
}

extension LazyCollection where Elements.Index: BidirectionalIndex,
    Elements.SubSequence: Collection, Elements.SubSequence.Index == Elements.Index,
    Elements.Index == Index
{
    func rotated(firstFrom pivot: Index) -> 
        (collection: LazyCollection<FlattenBidirectionalCollection<[Elements.SubSequence]>>, 
        rotatedStart: FlattenBidirectionalCollectionIndex<[Elements.SubSequence]>)
}

extension LazyCollection where
    Elements.Index: RandomAccessIndex, Elements.SubSequence: Collection,
    Elements.SubSequence.Index == Elements.Index, Elements.Index == Index
{
    func rotated(firstFrom pivot: Index) -> 
        (collection: LazyCollection<RotatedCollection<Elements>>, 
        rotatedStart: RotatedCollectionIndex<Elements.Index>)
}
```

Unit tests will be implemented in `swift/test/1_stdlib/Rotate.swift`

## Usage examples

Example of rotating all elements of the collection:

```swift
var numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9]
numbers.rotate(firstFrom: 3)
expectEqual(numbers, [4, 5, 6, 7, 8, 9, 1, 2, 3])
```

```swift
var numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9]
let rotated = numbers.rotated(firstFrom: 3).collection
expectEqual(rotated, [4, 5, 6, 7, 8, 9, 1, 2, 3])
```

Example of reversing in place:

```swift
var numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9]
numbers.reverse()
expectEqual(numbers, [9, 8, 7, 6, 5, 4, 3, 2, 1])
numbers[0..<5].reverse()
expectEqual(numbers, [5, 6, 7, 8, 9, 4, 3, 2, 1])
```

## Impact on existing code

This is an additive feature that doesn’t impact existing code.

## Alternatives considered

The alternative is to keep the current behaviour, but the user will need to develop 
their custom implementation of the rotate algorithms tailored for their needs.
