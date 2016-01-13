# Implement a rotate algorithm, equivalent to std::rotate() in C++

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-implement-a-rotate-algorithm.md)
* Author(s): [Sergey Bolshedvorsky](https://github.com/bolshedvorsky)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This is one of the most important algorithms. It is a fundamental tool used in many 
other algorithms with applications even in GUI programming. 

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002213.html)

## Motivation

std::rotate() method performs a left rotation on a range of elements. 
Specifically, it swaps the elements in the range [first, last) 
in such a way that the element middle becomes the first element 
of the new range and middle - 1 becomes the last element.
A precondition of this function is that [first, n_first) and 
[middle, last) are valid ranges.

There are 3 different versions of rotate algorithm for ForwardIndexType, 
BidirectionalIndexType and RandomAccessIndexType protocols. 

The **Forward indices** are the simplest and most general and support 
only one-directional traversal.

The C++ implementation of the rotate algorithm for the ForwardIterator 
(ForwardIndexType in Swift's' stdlib) may look like this:

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
(BidirectionalIndexType in Swift's stdlib) may look like this:

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
(RandomAccessIndexType in Swift's stdlib) may look like this:

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

The complexity of the implementation of these algorithms makes the generic rotate algorithm 
a perfect candidate for the standard library.

## Proposed solution

The Swift standard library should provide generic implementations of the rotate algorithms 
for all CollectionTypes.

Standard library will provide implementations of algorithm for all 3 index types:
- ForwardIndexType
- BidirectionalIndexType
- RandomAccessIndexType

Different collection types conforms to different index types, therefore the user will use the 
most optimal algorithm for his collection type.

## Detailed design

Rotated algorithms, structs and extensions will be implemented in `swift/stdlib/public/core/Rotate.swift`

A precondition of this function is that:
0 <= first <= middle <= last < count

Extension to CollectionType with generic implementation will be added. 
Implementation will return rotated sequence and an index of the old first element: 

```Swift
extension CollectionType {
    @warn_unused_result
    public func rotatedFirstFrom(middle: Index) -> (FlattenSequence<Array<Self.SubSequence>>, Index) {
        let slice1 = self[middle..<endIndex]
        let slice2 = self[startIndex..<middle]
        let flatten = [slice1, slice2].flatten()

        let distance = middle.distanceTo(endIndex)
        let index = startIndex.advancedBy(distance, limit: endIndex)

        return (flatten, index)
    }
}
```

Extensions to CollectionType will be added. These extensions will rotate elements in place:

```Swift
extension CollectionType where Index : ForwardIndexType {
    @warn_unused_result
    public mutating func rotateFirstFrom(middle: Index) -> Index {
        if middle == startIndex { return startIndex }

        // Implement ForwardIndexType algorithm
        // Return the index of the old start element
    }
}


extension CollectionType where Index : BidirectionalIndexType {
    @warn_unused_result
    public mutating func rotateFirstFrom(middle: Index) -> Index {
        if middle == startIndex { return startIndex }
        
        // Implement BidirectionalIndexType algorithm
        // Return the index of the old start element
    }
}


extension CollectionType where Index : RandomAccessIndexType {
    @warn_unused_result
    public mutating func rotateFirstFrom(middle: Index) -> Index {
        if middle == startIndex { return startIndex }
        
        // Implement RandomAccessIndexType algorithm
        // Return the index of the old start element
    }
}
```

Extensions to LazyCollectionType will be added:

```Swift
extension LazyCollectionType where Index : ForwardIndexType {
    @warn_unused_result
    public func rotateFirstFrom(middle: Index) /* -> Return Type */ {
        // An eager algorithm can be implemented by copying lazy views to an array.
    }
}

extension LazyCollectionType where Index : BidirectionalIndexType {
    @warn_unused_result
    public func rotateFirstFrom(middle: Index) /* -> Return Type */ {
        // An eager algorithm can be implemented by copying lazy views to an array.
    }
}

extension LazyCollectionType where Index : RandomAccessIndexType {
    @warn_unused_result
    public func rotateFirstFrom(middle: Index) /* -> Return Type */ {
        // An eager algorithm can be implemented by copying lazy views to an array.
    }
}
```

Unit tests will be implemented in `swift/test/1_stdlib/Rotate.swift`

## Usage examples

Example of rotating all elements of the collection:

```Swift
var numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9]
numbers.rotateFirstFrom(3)
expectEqual(numbers, [4, 5, 6, 7, 8, 9, 1, 2, 3])
```

```Swift
var numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9]
let rotated = numbers.rotatedFirstFrom(3)
expectEqual(rotated, [4, 5, 6, 7, 8, 9, 1, 2, 3])
```

## Impact on existing code

This is an additive feature that doesn’t impact existing code.

## Alternatives considered

The alternative is to keep the current behaviour, but the user will need to develop 
their custom implementation of the rotate algorithms tailored for their needs.
