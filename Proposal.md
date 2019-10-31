# Add RangeSet and Related Collection Operations

* Proposal: [SE-NNNNNNNN](NNNN-rangeset-and-friends.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: TBD
* Status: **Awaiting review**

### Changelog

* _October 24, 2019:_ Renamed the `move(...)` methods to `gather(...)` for multiple-range moves and `shift(from:toJustBefore:)` for single-range and single-element moves to better reflect their behavior, and removed the `move(from:to:)` method. Added `elements(within:)` method for getting the individual index values in a `RangeSet` when the `Bound` type isn't integer-strideable.
* _October 31, 2019:_ Removed `SetAlgebra` conformance and the `Elements` collection view, as `RangeSet` can't guarantee correct semantics for individual index operations without the parent collection. Renamed `elements(within:)` to `individualIndices(within:)`. Deferred the rotating and partitioning methods to a future pitch.

## Introduction

We can use a range to address a single range of consecutive elements in a collection, but the standard library doesn't currently provide a way to access discontiguous elements. This proposes the addition of a `RangeSet` type that can store the location of any number of collections indices, along with collection operations that let us use a range set to access or modify the collection.

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

// You can gather the multiples of 3 at the beginning
let rangeOfThree = numbers.gather(indicesOfThree, justBefore: 0)
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

The `RangeSet` type is generic over any `Comparable` type, and supports fast containment checks for individual values, as well as adding and removing ranges of that type. 

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

#### `SetAlgebra`-like methods

`RangeSet` implements the methods of the `SetAlgebra` protocol that don't traffic in individual indices. Without access to a collection that can provide the index after an individual value, `RangeSet` can't reliably maintain the semantic guarantees of working with collection indices.

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
```

#### Collection APIs

Adding or removing individual index values or range expressions requires passing the relevant collection, as well, for context. `RangeSet` includes initializers and insertion and removal methods for working with these kinds of values, as well as a way to "invert" a range set with respect to a collection.

```swift
extension RangeSet {
    /// Creates a new range set with the specified index in the given 
    /// collection.
    ///
    /// - Parameters:
    ///   - index: The index to include in the range set. `index` must be a
    ///     valid index of `collection` that isn't the collection's `endIndex`.
    ///   - collection: The collection that contains `index`.
    public init<C>(_ index: Bound, within collection: C)
        where C: Collection, C.Index == Bound
    
    /// Creates a new range set with the specified indices in the given
    /// collection.
    ///
    /// - Parameters:
    ///   - index: The index to include in the range set. `index` must be a
    ///     valid index of `collection` that isn't the collection's `endIndex`.
    ///   - collection: The collection that contains `index`.
    public init<S, C>(_ indices: S, within collection: C)
        where S: Sequence, C: Collection, S.Element == C.Index, C.Index == Bound
    
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
    
    /// Removes the specified range expression from the range set.
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

#### Accessing Ranges and Individual Indices

`RangeSet` provides access to its ranges as a random-access collection via the `ranges` property. The individual indices in a collection that are represented by a range set are available as a bidirectional collection through the `individualIndices(within:)` method (see below for more about this method's return type).

```swift
extension RangeSet {
    public struct Ranges: RandomAccessCollection {
        public var startIndex: Int { get }
        public var endIndex: Int { get }
        public subscript(i: Int) -> Range<Bound>
    }
    
    /// A collection of the ranges that make up the range set.
    ///
    /// The ranges in this collection never overlap or adjoin, are never empty,
    /// and are always in ascending order.
    public var ranges: Ranges { get }
}

extension RangeSet {
    /// Returns a collection of all the indices represented by this range set
    /// within the given collection.
    ///
    /// The indices in the returned collection are unique and are stored in 
    /// ascending order. 
    ///
    /// - Parameter collection: The collection that the range set is relative
    ///   to.
    /// - Returns: A collection of the indices within `collection` that are
    ///   represented by this range set.
    public func individualIndices<C>(within collection: C) -> IndexingCollection<C.Indices>
        where C: Collection, C.Index == Bound
}
```

#### Storage

`RangeSet` will store its ranges in a custom type that will optimize the storage for known, simple `Bound` types. This custom type will avoid allocating extra storage for common cases of empty or single-range range sets.


### New `Collection` APIs

#### Finding multiple elements

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
    /// - Returns: A set of the indices of the elements that are equal to 
    ///   `element`.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public func indices(of element: Element) -> RangeSet<Index>
}
```

#### Accessing elements via `RangeSet`

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

#### Moving elements

Within a mutable collection, you can gather the elements represented by a range set, inserting them before a specific index. This proposal also adds a method for gathering all the elements matched by a predicate, and methods for shifting a single range, a range expression, or a single element to a specific insertion point.

Whether you're working with a range set, a single range, or a single index, moving elements around in a collection can shift the relative position of the expected destination point. For that reason, these gathering and shifting methods return the new range or index of the elements that have been moved. To visualize this operation, divide the collection into two parts, before and after the insertion point. The elements to move are collected in order in that gap, and the resulting range (or index, for single element moves) is returned.

As an example, consider a shift from a range at the beginning of an array of letters to a position further along in the array:

```swift
var array = ["a", "b", "c", "d", "e", "f", "g"]
let newSubrange = array.shift(from: 0..<3, toJustBefore: 5)
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

When shifting a single element, this can mean that the element ends up at the insertion point (when moving backward), or ends up at a position one before the insertion point (when moving forward, because the elements in between move forward to make room).

```swift
var array = ["a", "b", "c", "d", "e", "f", "g"]
let newPosition = array.shift(from: 1, toJustBefore: 5)
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

The new gathering and shifting methods are listed below.

```swift
extension MutableCollection {
    /// Collects the elements at the given indices just before the specified
    /// index.
    ///
    /// This example finds all the uppercase letters in the array and gathers
    /// them between `"i"` and `"j"`.
    ///
    ///     var letters = Array("ABCdeFGhijkLMNOp")
    ///     let uppercase = letters.indices(where: { $0.isUppercase })
    ///     let rangeOfUppercase = letters.gather(uppercase, justBefore: 10)
    ///     // String(letters) == "dehiABCFGLMNOjkp"
    ///     // rangeOfUppercase == 4..<13
    ///
    /// - Parameters:
    ///   - indices: The indices of the elements to move.
    ///   - insertionPoint: The index to use as the destination of the elements.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func gather(
        _ indices: RangeSet<Index>, justBefore insertionPoint: Index
    ) -> Range<Index>

    /// Collects the elements that satisfy the given predicate just before the
    /// specified index.
    ///
    /// This example gathers all the uppercase letters in the array between
    /// `"i"` and `"j"`.
    ///
    ///     var letters = Array("ABCdeFGhijkLMNOp")
    ///     let rangeOfUppercase = letters.gather(justBefore: 10) { $0.isUppercase }
    ///     // String(letters) == "dehiABCFGLMNOjkp"
    ///     // rangeOfUppercase == 4..<13
    ///
    /// - Parameters:
    ///   - predicate: A closure that returns `true` for elements that should
    ///     move to `destination`.
    ///   - insertionPoint: The index to use as the destination of the elements.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n* log *n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func gather(
        justBefore: Index, where predicate: (Element) -> Bool
    ) -> Range<Index>
    
    /// Shifts the elements in the given range to the specified insertion point.
    ///
    /// - Parameters:
    ///   - range: The range of the elements to move.
    ///   - insertionPoint: The index to use as the insertion point for the 
    ///     elements. `insertionPoint` must be a valid index of the collection.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Returns: The new bounds of the moved elements.
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func shift(
        from range: Range<Index>, toJustBefore insertionPoint: Index
    ) -> Range<Index>

    /// Shifts the elements in the given range expression to the specified
    /// insertion point.
    ///
    /// - Parameters:
    ///   - range: The range of the elements to move.
    ///   - insertionPoint: The index to use as the insertion point for the 
    ///     elements. `insertionPoint` must be a valid index of the collection.
    /// - Returns: The new bounds of the moved elements.
    ///
    /// - Complexity: O(*n*) where *n* is the length of the collection.
    @discardableResult
    public mutating func shift<R : RangeExpression>(
        from range: R, toJustBefore insertionPoint: Index
    ) -> Range<Index> where R.Bound == Index

    /// Moves the element at the given index to just before the specified
    /// insertion point.
    ///
    /// This method moves the element at position `i` to immediately before
    /// `insertionPoint`. This example shows moving elements forward and
    /// backward in an array of integers.
    ///
    ///     var numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    ///     let newIndexOfNine = numbers.shift(from: 9, toJustBefore: 7)
    ///     // numbers == [0, 1, 2, 3, 4, 5, 6, 9, 7, 8, 10]
    ///     // newIndexOfNine == 7
    ///
    ///     let newIndexOfOne = numbers.shift(from: 1, toJustBefore: 4)
    ///     // numbers == [0, 2, 3, 1, 4, 5, 6, 9, 7, 8, 10]
    ///     // newIndexOfOne == 3
    ///
    /// To move an element to the end of a collection, pass the collection's
    /// `endIndex` as `insertionPoint`.
    ///
    ///     numbers.shift(from: 0, toJustBefore: numbers.endIndex)
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
    public mutating func shift(
        from source: Index, toJustBefore insertionPoint: Index
    ) -> Index
}
```

#### Removing elements

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

extension Collection {
    /// Returns a collection of the elements in this collection that are not
    /// represented by the given range set.
    ///
    /// For example, this code sample finds the indices of all the vowel
    /// characters in the string, and then retrieves a collection that omits
    /// those characters.
    ///
    ///     let str = "The rain in Spain stays mainly in the plain."
    ///     let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    ///     let vowelIndices = str.indices(where: { vowels.contains($0) })
    ///
    ///     let disemvoweled = str.removingAll(at: vowelIndices)
    ///     print(String(disemvoweled))
    ///     // Prints "Th rn n Spn stys mnly n th pln."
    ///
    /// - Parameter indices: A range set representing the elements to remove.
    /// - Returns: A collection of the elements that are not in `indices`.
    public func removingAll(at indices: RangeSet<Index>) -> IndexingCollection<Self>
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
