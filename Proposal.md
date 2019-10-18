# Add RangeSet and Related Collection Operations

* Proposal: [SE-NNNNNNNN](NNNN-rangeset-and-friends.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

We can use a range to address a single range of consecutive elements in a collection, but the standard library doesn't currently provide a way to access discontiguous elements. This proposes the addition of a `RangeSet` type that can store the location of any number of collections indices, along with collection operations that let us use a range set to access or modify the collection. In addition, because these operations depend on mutable collection algorithms that we've long wanted in the standard library, this proposal includes those too.

## Motivation

There are many uses for tracking multiple elements in a collection, such as maintaining the selection in a list of items, or refining a filter or search result set after getting more input.

The Foundation data type most suited for this purpose, `IndexSet`, uses integers only, which limits its usefulness to arrays and other random-access collection types. The standard library is missing a collection that can efficiently store any number of indices, and is missing the operations that you might want to perform with such a collection of indices. These operations themselves can be challenging to implement correctly, and have performance traps as well — see last year's [Embracing Algorithms](https://developer.apple.com/videos/wwdc/2018/?id=223) WWDC talk for a demonstration. 

## Proposed solution

This proposal adds a `RangeSet` type for representing multiple, noncontiguous ranges, as well as a variety of collection operations for creating and working with range sets.

```swift
var numbers = Array(1...15)

// Find the indices of all the multiples of three
let indicesOfThree = numbers.indices(where: { $0.isMultiple(of: 3) })

// Perform an operation with just those multiples
let sumOfThrees = numbers[indicesOfThree].reduce(0, +)
// sumOfThrees == 45

// You can move the multiples of 3 to the beginning
let rangeOfThree = numbers.move(from: indicesOfThree, to: 0)
// numbers[rangeOfThree] == [3, 6, 9, 12, 15]
// numbers == [3, 6, 9, 12, 15, 1, 2, 4, 5, 7, 8, 10, 11, 13, 14]

// Reset `numbers`
numbers = Array(1...15)

// You can also build range sets by hand using array literals...
let myRangeSet: RangeSet = [0..<5, 10..<15]
print(Array(numbers[myRangeSet]))
// Prints [1, 2, 3, 4, 5, 11, 12, 13, 14, 15]

// ...or by using set operations
let evenThrees = indicesOfThree.intersection(
    numbers.indices(where: { $0.isMultiple(of: 2) }))
print(Array(numbers[evenThrees]))
// Prints [6, 12]
```

The remainder of the `RangeSet` and collection operations, like inverting a range set or inserting and removing range expressions, are covered in the next section.

## Detailed design

The `RangeSet` type is generic over any `Comparable` type, with different functionality 

```swift
/// A set of ranges of any comparable value.
public struct RangeSet<Bound: Comparable> {
    /// Creates an empty range set.
    public init() {}

    /// Creates a range set with the given range.
    ///
    /// - Parameter range: The range to use for the new range set.
    public init(_ range: Range<Bound>)
    
    /// Creates a range set with the given ranges.
    ///
    /// - Parameter ranges: The ranges to use for the new range set.
    public init<S: Sequence>(_ ranges: S) where S.Element == Range<Bound>
    
    /// A Boolean value indicating whether the range set is empty.
    public var isEmpty: Bool { get }
    
    /// Returns a Boolean value indicating whether the given element is
    /// contained in the range set.
    ///
    /// - Parameter element: The element to look for in the range set.
    /// - Return: `true` if `element` is contained in the range set; otherwise,
    ///   `false`.
    ///
    /// - Complexity: O(log *n*), where *n* is the number of ranges in the
    ///   range set.
    public func contains(_ element: Bound) -> Bool
        
    /// Inserts the given range into the range set.
    ///
    /// - Parameter range: The range to insert into the set.
    public mutating func insert(_ range: Range<Bound>)
        
    /// Removes the given range from the range set.
    ///
    /// - Parameter range: The range to remove from the set.
    public mutating func remove(_ range: Range<Bound>)
}
```

`RangeSet` conforms to `Equatable`, `CustomStringConvertible`, and `Hashable` when its `Bound` type conforms to `Hashable`. `RangeSet` also has `ExpressibleByArrayLiteral` conformance, using arrays of ranges as its literal type.

#### `SetAlgebra` conformance

`RangeSet` has `SetAlgebra` conformance when its bound type conforms to `Stridable` with an integer stride, but has most of the `SetAlgebra` API no matter what the bound type.

In the following listing, the unconstrained extension includes set algebra operations like finding the union or intersection of range sets. The element-based methods and initializer of `SetAlgebra` are the only pieces that are constrained.

```swift
extension RangeSet {
    public func union(_ other: RangeSet<Bound>) -> RangeSet<Bound>
    public mutating func formUnion(_ other: RangeSet<Bound>)

    public func intersection(_ other: RangeSet<Bound>) -> RangeSet<Bound>
    public mutating func formIntersection(_ other: RangeSet<Bound>)

    public func symmetricDifference(_ other: RangeSet<Bound>) -> RangeSet<Bound>
    public mutating func formSymmetricDifference(_ other: RangeSet<Bound>)
    
    public func subtracting(_ other: RangeSet<Bound>) -> RangeSet<Bound>
    public mutating func subtract(_ other: RangeSet<Bound>)
    
    public func isSubset(of other: RangeSet<Bound>) -> Bool
    public func isSuperset(of other: RangeSet<Bound>) -> Bool
    public func isStrictSubset(of other: RangeSet<Bound>) -> Bool
    public func isStrictSuperset(of other: RangeSet<Bound>) -> Bool
}

extension RangeSet: SetAlgebra where Bound: Strideable, Bound.Stride: SignedInteger {
    public init<S: Sequence>(_ sequence: S) where S.Element == Bound

    @discardableResult
    public mutating func insert(_ newMember: Bound)
        -> (inserted: Bool, memberAfterInsert: Bound)

    @discardableResult
    public mutating func remove(_ member: Bound) -> Bound?

    public mutating func update(with newMember: Bound) -> Bound?
}
```

#### Collection APIs

Adding or removing individual index values or range expressions requires passing the relevant collection, as well, for context. `RangeSet` includes initializers and insertion and removal methods for working with these kinds of values, as well as a way to "invert" a range set with respect to a collection.

```swift
extension RangeSet {
    /// Creates a new range set with the specified index in the given collection.
    /// Creates a new range set with the specified index.
    ///
    /// - Parameters:
    ///   - index: The index to include in the range set. `index` must be a
    ///     valid index of `collection` that isn't the collection's `endIndex`.
    ///   - collection: The collection that contains `index`.
    public init<C>(_ index: Bound, within collection: C)
        where C: Collection, C.Index == Bound
    
    /// Creates a new range set with the specified range expression.
    ///
    /// - Parameters:
    ///   - range: The range expression to use as the set's initial range.
    ///   - collection: The collection that `range` is relative to.
    public init<R, C>(_ range: R, within collection: C)
        where C: Collection, C.Index == Bound, R: RangeExpression, R.Bound == Bound
    
    /// Inserts the specified index into the range set.
    ///
    /// - Parameters:
    ///   - index: The index to insert into the range set. `index` must be a
    ///     valid index of `collection` that isn't the collection's `endIndex`.
    ///   - collection: The collection that contains `index`.
    public mutating func insert<C>(_ index: Bound, within collection: C)
        where C: Collection, C.Index == Bound
    
    /// Inserts the specified range expression into the range set.
    ///
    /// - Parameters:
    ///   - range: The range expression to insert into the range set.
    ///   - collection: The collection that `range` is relative to.
    public mutating func insert<R, C>(_ range: R, within collection: C)
        where C: Collection, C.Index == Bound, R: RangeExpression, R.Bound == Bound
    
    /// Removes the specified index from the range set.
    ///
    /// - Parameters:
    ///   - index: The index to remove from the range set. `index` must be a
    ///     valid index of `collection` that isn't the collection's `endIndex`.
    ///   - collection: The collection that contains `index`.
    public mutating func remove<C>(_ index: Bound, within collection: C)
        where C: Collection, C.Index == Bound
    
    /// Removes the specified range expression into the range set.
    ///
    /// - Parameters:
    ///   - range: The range expression to remove from the range set.
    ///   - collection: The collection that `range` is relative to.
    public mutating func remove<R, C>(_ range: R, within collection: C)
        where C: Collection, C.Index == Bound, R: RangeExpression, R.Bound == Bound

    /// Returns a range set that represents all the elements in the given
    /// collection that aren't represented by this range set.
    ///
    /// The following example finds the indices of the vowels in a string, and
    /// then inverts the range set to find the non-vowels parts of the string.
    ///
    ///     let str = "The rain in Spain stays mainly in the plain."
    ///     let vowels = "aeiou"
    ///     let vowelIndices = str.indices(where: { vowels.contains($0) })
    ///     print(String(str[vowelIndices]))
    ///     // Prints "eaiiaiaaiieai"
    ///
    ///     let nonVowelIndices = vowelIndices.inverted(within: str)
    ///     print(String(str[nonVowelIndices]))
    ///     // Prints "Th rn n Spn stys mnly n th pln."
    ///
    /// - Parameter collection: The collection that the range set is relative
    ///   to.
    /// - Returns: A new range set that represents the elements in `collection`
    ///   that aren't represented by this range set.
    public func inverted<C>(within collection: C) -> RangeSet
        where C: Collection, C.Index == Bound
}
```

#### `Ranges` and `Elements` sub-collections

`RangeSet` provides access to its ranges and, when possible, individual indices through two collection views. The ranges that comprise a range set are available in a random-access collection via the `ranges` property. Individual indices are available as a bidirectional collection via the `elements` property, when a range set's `Bound` type is `Strideable` with an integer range.

```swift
extension RangeSet {
    public struct Ranges: RandomAccessCollection {
        public var startIndex: Int { get }
        public var endIndex: Int { get }
        public subscript(i: Int) -> Range<Bound>
    }
    
    /// A collection of the ranges that make up the range set.
    public var ranges: Ranges { get }
}

extension RangeSet where Bound: Strideable, Bound.Stride: SignedInteger {
    public struct Elements: Sequence, Collection, BidirectionalCollection {
        public typealias Index = FlattenSequence<Ranges>.Index
    
        public var startIndex: Index { get }
        public var endIndex: Index { get }                
        public subscript(i: Index) -> Bound { get }
    }
    
    /// A collection of the individual indices represented by the range set.
    public var elements: Elements { get }
}
```

#### Storage

`RangeSet` will store its ranges in a custom type that will optimize the storage for known, simple `Bound` types. This custom type will avoid allocating extra storage for the common cases of empty or single-range range sets.


### New `Collection` APIs

#### Find multiple elements

Akin to the `firstIndex(...)` and `lastIndex(...)` methods, this proposal introduces `indices(where:)` and `indices(of:)` methods that return a range set with the indices of all matching elements in a collection.

```swift
extension Collection {
    /// Returns the indices of all the elements that match the given predicate.
    ///
    /// For example, you can use this method to find all the places that a
    /// vowel occurs in a string.
    ///
    ///     let str = "Fresh cheese in a breeze"
    ///     let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    ///     let allTheVowels = str.indices(where: { vowels.contains($0) })
    ///     // str[allTheVowels].count == 9
    ///
    /// - Parameter predicate: A closure that takes an element as its argument
    ///   and returns a Boolean value that indicates whether the passed element
    ///   represents a match.
    /// - Returns: A set of the indices of the elements for which `predicate`
    ///   returns `true`.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public func indices(where predicate: (Element) throws -> Bool) rethrows
        -> RangeSet<Index>
}

extension Collection where Element: Equatable {
    /// Returns the indices of all the elements that are equal to the given
    /// element.
    ///
    /// For example, you can use this method to find all the places that a
    /// particular letter occurs in a string.
    ///
    ///     let str = "Fresh cheese in a breeze"
    ///     let allTheEs = str.indices(of: "e")
    ///     // str[allTheEs].count == 7
    ///
    /// - Parameter element: An element to look for in the collection.
    /// - Returns: A set of ranges of the elements that are equal to `element`.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public func indices(of element: Element) -> RangeSet<Index>
}
```

#### Access elements via `RangeSet`

When you have a `RangeSet` describing a group of indices for a collection, you can access those elements via a new subscript. This new subscript returns a new `IndexingCollection` type, which couples the collection and range set to provide access.

```swift
extension Collection {
    /// Accesses a view of this collection with the elements at the given
    /// indices.
    ///
    /// - Parameter indices: The indices of the elements to retrieve from this
    ///   collection.
    /// - Returns: A collection of the elements at the positions in `indices`.
    ///
    /// - Complexity: O(1)
    public subscript(indices: RangeSet<Index>) -> IndexingCollection<Self> { get }
}

extension MutableCollection {
    /// Accesses a mutable view of this collection with the elements at the
    /// given indices.
    ///
    /// - Parameter indices: The indices of the elements to retrieve from this
    ///   collection.
    /// - Returns: A collection of the elements at the positions in `indices`.
    ///
    /// - Complexity: O(1) to access the elements, O(*m*) to mutate the
    ///   elements at the positions in `indices`, where *m* is the number of
    ///   elements indicated by `indices`.
    public subscript(indices: RangeSet<Index>) -> IndexingCollection<Self> { get set }
}

/// A collection wrapper that provides access to the elements of a collection,
/// indexed by a set of indices.
public struct IndexingCollection<Base: Collection>: Collection {
    /// The collection that the indexed collection wraps.
    public var base: Base { get set }

    /// The set of index ranges that are available through this indexing
    /// collection.
    public var ranges: RangeSet<Base.Index> { get set }
    
    /// A position in an `IndexingCollection`.
    struct Index: Comparable {
        // ...
    }
    
    public var startIndex: Index { get }
    public var endIndex: Index { set }
    public subscript(i: Index) -> Base.Element { get }
}
```

`IndexingCollection` will conform to `Collection`, and conditionally conform to `BidirectionalCollection` and `MutableCollection` if its base collection conforms.

#### Move elements

Within a mutable collection, you can move the elements represented by a range set, and insert them at a new index. This proposal also adds convenience methods for moving a single range or range expression, a single element, or the elements matching a predicate.

When moving elements, most moves are to an insertion point, rather than to a specific index. Whether you're working with a range set, a single range, or a single index, moving elements around in a collection can shift the relative position of the expected destination point. To visualize this operation, you can divide the collection into two parts, before and after the insertion point. The elements to move are collected in order in that gap, and the resulting range (or index, for single element moves) is returned.

As an example, consider a move from a range at the beginning of an array of letters to a position further along in the array:

```swift
var array = ["a", "b", "c", "d", "e", "f", "g"]
let newSubrange = array.move(from: 0..<3, insertingAt: 5)
// array == ["d", "e", "a", "b", "c", "f", "g"]
// newSubrange = 2..<5

//     ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┐
//     │  a  │  b  │  c  │  d  │  e  │  f  │  g  │
//     └─────┴─────┴─────┴─────┴─────┴─────┴─────┘
//      ^^^^^^^^^^^^^^^^^               ^
//            source                insertion
//                                    point
//
//    ┌─────┬─────┬─────┐┌─────┬─────┐┌─────┬─────┐
//    │  a  │  b  │  c  ││  d  │  e  ││  f  │  g  │
//    └─────┴─────┴─────┘└─────┴─────┘└─────┴─────┘
//     ^^^^^^^^^^^^^^^^^              ^
//           source               insertion
//                                  point
//
//    ┌─────┬─────┐┌─────┬─────┬─────┐┌─────┬─────┐
//    │  d  │  e  ││  a  │  b  │  c  ││  f  │  g  │
//    └─────┴─────┘└─────┴─────┴─────┘└─────┴─────┘
//                  ^^^^^^^^^^^^^^^^^
//                 newSubrange == 2..<5
```

When moving a single element, this can mean that the element ends up at the insertion index (when moving backward), or ends up at a position one before the insertion point (when moving forward, because the elements in between move forward to make room).

```swift
var array = ["a", "b", "c", "d", "e", "f", "g"]
let newPosition = array.move(from: 1, insertingAt: 5)
// array == ["a", "c", "d", "e", "b", "f", "g"]
// newPosition == 4

//    ┌─────┬─────┬─────┬─────┬─────┐┌─────┬─────┐
//    │  a  │  b  │  c  │  d  │  e  ││  f  │  g  │
//    └─────┴─────┴─────┴─────┴─────┘└─────┴─────┘
//             ^                     ^
//           source              insertion
//                                 point
//
//    ┌─────┬─────┬─────┬─────┐┌─────┐┌─────┬─────┐
//    │  a  │  c  │  d  │  e  ││  b  ││  f  │  g  │
//    └─────┴─────┴─────┴─────┘└─────┘└─────┴─────┘
//                                ^
//                        newPosition == 4
```

To support the case where you care about the ending position of the moved element more than the relative ordering of the elements, we also provide a `move(from:to:)` method that guarantees that the element ends up at the destination position.

```
var array = ["a", "b", "c", "d", "e", "f", "g"]
array.move(from: 1, to: 5)
// array == ["a", "c", "d", "e", "f", "b", "g"]
// array[5] == "b"

//     ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┐
//     │  a  │  b  │  c  │  d  │  e  │  f  │  g  │
//     └─────┴─────┴─────┴─────┴─────┴─────┴─────┘
//              ^                       ^
//            source               destination
//                                                 
//                                                 
//    ┌─────┬─────┬─────┬─────┬─────┐┌─────┐┌─────┐
//    │  a  │  c  │  d  │  e  │  f  ││  b  ││  g  │
//    └─────┴─────┴─────┴─────┴─────┘└─────┘└─────┘
//                                      ^
//                                 destination
//                                                 
```

The new move methods are listed below.

```swift
extension MutableCollection {
    /// Moves the elements at the given indices to the specified insertion
    /// point.
    ///
    /// - Parameters:
    ///   - indices: The indices of the elements to move.
    ///   - insertionPoint: The index to use as the destination of the elements.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func move(
        from indices: RangeSet<Index>, insertingAt insertionPoint: Index
    ) -> Range<Index>

    /// Moves the elements in the given range to the specified insertion point.
    ///
    /// - Parameters:
    ///   - range: The range of the elements to move.
    ///   - insertionPoint: The index to use as the destination of the elements.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Returns: The new bounds of the moved elements.
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func move(
        from range: Range<Index>, insertingAt insertionPoint: Index
    ) -> Range<Index>

    /// Moves the elements in the given range expression to the specified
    /// insertion point.
    ///
    /// - Parameters:
    ///   - range: The range of the elements to move.
    ///   - insertionPoint: The index to use as the destination of the elements.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func move<R : RangeExpression>(
        from range: R, insertingAt insertionPoint: Index
    ) -> Range<Index> where R.Bound == Index

    /// Moves the element at the given index, inserting at the specified
    /// position.
    ///
    /// This method moves the element at position `i` to immediately before
    /// `insertionPoint`. This example shows moving elements forward and
    /// backward in an array of integers.
    ///
    ///     var numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    ///     let newIndexOfNine = numbers.move(from: 9, insertingAt: 7)
    ///     // numbers == [0, 1, 2, 3, 4, 5, 6, 9, 7, 8, 10]
    ///     // newIndexOfNine == 7
    ///
    ///     let newIndexOfOne = numbers.move(from: 1, insertingAt: 4)
    ///     // numbers == [0, 2, 3, 1, 4, 5, 6, 9, 7, 8, 10]
    ///     // newIndexOfOne == 3
    ///
    /// To move an element to the end of a collection, pass the collection's
    /// `endIndex` as `insertionPoint`.
    ///
    ///     numbers.move(from: 0, insertingAt: numbers.endIndex)
    ///     // numbers == [2, 3, 1, 4, 5, 6, 9, 7, 8, 10, 0]
    ///
    /// - Parameters:
    ///   - source: The index of the element to move. `source` must be a valid
    ///     index of the collection that isn't `endIndex`.
    ///   - insertionPoint: The index to use as the destination of the element.
    ///     `insertionPoint` must be a valid index of the collection.
    /// - Returns: The resulting index of the element that began at `source`.
    ///
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func move(
        from source: Index, insertingAt insertionPoint: Index
    ) -> Index

    /// Moves the element at the given index to the specified destination.
    ///
    /// This method moves the element at position `source` to the position given
    /// as `destination`. This example shows moving elements forward and
    /// backward in an array of numbers.
    ///
    ///     var numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    ///     let newIndexOfNine = numbers.move(from: 9, to: 7)
    ///     // numbers == [0, 1, 2, 3, 4, 5, 6, 9, 7, 8, 10]
    ///     // newIndexOfNine == 7
    ///     // numbers[newIndexOfNine] == 9
    ///
    ///     let newIndexOfOne = numbers.move(from: 1, to: 4)
    ///     // newIndexOfOne == 4
    ///     // numbers == [0, 2, 3, 4, 1, 5, 6, 9, 7, 8, 10]
    ///
    /// To move an element to the end of a collection, pass the collection's
    /// `endIndex` as the second parameter to the `move(from:insertingAt:)`
    /// method.
    ///
    /// - Parameters:
    ///   - source: The index of the element to move. `source` must be a valid
    ///     index of the collection that isn't `endIndex`.
    ///   - destination: The index to use as the destination of the element.
    ///     `destination` must be a valid index of the collection that isn't
    ///     `endIndex`.
    ///
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    public mutating func move(from source: Index, to destination: Index)
        
    /// Moves the elements that satisfy the given predicate to the specified
    /// insertion point.
    ///
    /// - Parameters:
    ///   - predicate: A closure that returns `true` for elements that should
    ///     move to `destination`.
    ///   - insertionPoint: The index to use as the destination of the elements.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func move(
        insertingAt insertionPoint: Index, where predicate: (Element) -> Bool
    ) -> Range<Index>
}
```

#### Remove elements

Within a range-replaceable collection, you can remove the elements represented by a range set. The implementation provides an additional, in-place overload for range-replaceable collections that also conform to `MutableCollection`.

```swift
extension RangeReplaceableCollection {
    /// Removes the elements at the given indices.
    ///
    /// For example, this code sample finds the indices of all the vowel
    /// characters in the string, and then removes those characters.
    ///
    ///     var str = "The rain in Spain stays mainly in the plain."
    ///     let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    ///     let vowelIndices = str.indices(where: { vowels.contains($0) })
    ///
    ///     str.removeAll(at: vowelIndices)
    ///     // str == "Th rn n Spn stys mnly n th pln."
    ///
    /// - Parameter indices: The indices of the elements to remove.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public mutating func removeAll(at indices: RangeSet<Index>)
}
```

#### Rotate and Partition

Finally, the proposal adds `MutableCollection` methods for rotation and half- and fully-stable partition. The partitioning methods use similar naming to the standard library's existing `partition(by:)` method.

```swift
extension MutableCollection {
    /// Rotates the elements of the collection so that the element at the
    /// specified index ends up first.
    ///
    /// - Parameter middle: The index of the element to rotate to the front of
    ///   the collection.
    /// - Returns: The new index of the element that was first pre-rotation.
    ///
    /// - Complexity: O(*n*)
    @discardableResult
    public mutating func rotate(shiftingToStart middle: Index) -> Index
    
    /// Moves all elements satisfying `belongsInSecondPartition` into a suffix
    /// of the collection, preserving the relative order of the prefix, and
    /// returns the start of the resulting suffix.
    ///
    /// This code example moves all the negative values in the `numbers` array
    /// to a section at the end of the array.
    ///
    ///     var numbers = Array(-5...5)
    ///     let startOfNegatives = numbers.halfStablePartition(by: { $0 < 0 })
    ///     // numbers == [0, 1, 2, 3, 4, 5, -4, -3, -2, -1, -5]
    ///
    /// Note that while the operation maintains the order of the beginning
    /// section of the array, the elements in the ending section have been
    /// rearranged.
    ///
    ///     // numbers[..<startOfNegatives] == [0, 1, 2, 3, 4, 5]
    ///     // numbers[startOfNegatives...] == [-4, -3, -2, -1, -5]
    ///
    /// - Parameter belongsInSecondPartition: A predicate used to partition the
    ///   collection. All elements satisfying this predicate are ordered after
    ///   all elements not satisfying it.
    /// - Returns: The index of the first element in the reordered collection
    ///   that matches `belongsInSecondPartition`. If no elements in the
    ///   collection match `belongsInSecondPartition`, the returned index is
    ///   equal to the collection's `endIndex`.
    ///
    /// - Complexity: O(*n*) where *n* is the number of elements.
    @discardableResult
    public mutating func halfStablePartition(
        by belongsInSecondPartition: (Element) throws -> Bool
    ) rethrows -> Index
        
    /// Moves all elements satisfying `belongsInSecondPartition` into a suffix
    /// of the collection, preserving their relative order, and returns the
    /// start of the resulting suffix.
    ///
    /// This code example moves all the negative values in the `numbers` array
    /// to a section at the end of the array.
    ///
    ///     var numbers = Array(-5...5)
    ///     let startOfNegatives = numbers.halfStablePartition(by: { $0 < 0 })
    ///     // numbers == [0, 1, 2, 3, 4, 5, -5, -4, -3, -2, -1]
    ///
    /// The partitioning operation maintains the initial relative order of the
    /// elements in each section of the array.
    ///
    ///     // numbers[..<startOfNegatives] == [0, 1, 2, 3, 4, 5]
    ///     // numbers[startOfNegatives...] == [-5, -4, -3, -2, -1]
    ///
    /// - Parameter belongsInSecondPartition: A predicate used to partition the
    ///   collection. All elements satisfying this predicate are ordered after
    ///   all elements not satisfying it.
    /// - Returns: The index of the first element in the reordered collection
    ///   that matches `belongsInSecondPartition`. If no elements in the
    ///   collection match `belongsInSecondPartition`, the returned index is
    ///   equal to the collection's `endIndex`.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the number of elements.
    @discardableResult
    public mutating func stablePartition(
        by belongsInSecondPartition: (Element) throws -> Bool
    ) rethrows -> Index
}

extension Collection {
    /// Returns an array of the elements in this collection, partitioned by the
    /// given predicate, and the index of the start of the second region.
    ///
    /// This code example moves all the negative values in the `numbers` array
    /// to a section at the end of the array.
    ///
    ///     let numbers = Array(-5...5)
    ///     let (partitioned, startOfNegatives) =
    ///         numbers.stablyPartitioned(by: { $0 < 0 })
    ///     // partitioned == [0, 1, 2, 3, 4, 5, -5, -4, -3, -2, -1]
    ///
    /// The partitioning operation maintains the initial relative order of the
    /// elements in each section of the array.
    ///
    ///     // partitioned[..<startOfNegatives] == [0, 1, 2, 3, 4, 5]
    ///     // partitioned[startOfNegatives...] == [-5, -4, -3, -2, -1]
    ///
    /// - Parameter belongsInSecondPartition: A predicate used to partition the
    ///   collection. All elements satisfying this predicate are ordered after
    ///   all elements not satisfying it.
    /// - Returns: The index of the first element in the reordered collection
    ///   that matches `belongsInSecondPartition`. If no elements in the
    ///   collection match `belongsInSecondPartition`, the returned index is
    ///   equal to the collection's `endIndex`.
    ///
    /// - Complexity: O(*n*) where *n* is the number of elements.
    public func stablyPartitioned(
        by belongsInSecondPartition: (Element) throws -> Bool
    ) rethrows -> (partitioned: [Element], partitioningIndex: Int)
}
```

## Other considerations

### Source compatibility

These additions preserve source compatibility.

### Effect on ABI stability

This proposal only makes additive changes to the existing ABI.

### Effect on API resilience

TBD…

## Alternatives considered

TBD…
