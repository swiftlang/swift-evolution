# Add Collection Operations on Noncontiguous Elements

* Proposal: [SE-NNNNNNNN](NNNN-rangeset-and-friends.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Review Manager: TBD
* Status: **Awaiting review**

### Changelog

* _October 24, 2019:_ Renamed the `move(...)` methods to `gather(...)` for multiple-range moves and `shift(from:toJustBefore:)` for single-range and single-element moves to better reflect their behavior, and removed the `move(from:to:)` method. Added `elements(within:)` method for getting the individual index values in a `RangeSet` when the `Bound` type isn't integer-strideable.
* _October 31, 2019:_ Removed `SetAlgebra` conformance and the `Elements` collection view, as `RangeSet` can't guarantee correct semantics for individual index operations without the parent collection. Renamed `elements(within:)` to `individualIndices(within:)`. Deferred the rotating and partitioning methods to a future pitch.
* _November 6, 2019:_ Removed the `individualIndices(within:)` method. Simplified argument labels for the `shift` and `gather` methods. Revised the proposal to make the relation between individual indices and the ranges in a range set more clear, among other things. Renamed `IndexingCollection` to `DiscontiguousSlice`, and made it its own slice type.

## Introduction

We can use a `Range<Index>` to refer to a group of consecutive positions in a collection, but the standard library doesn't currently provide a way to refer to discontiguous positions in an arbitrary collection. I propose the addition of a `RangeSet` type that can store any number of positions, along with collection algorithms that operate on those positions.

## Motivation

There are varied uses for tracking multiple elements in a collection, such as maintaining the selection in a list of items, or refining a filter or search result set after getting more input from a user.

The Foundation data type most suited for this purpose, `IndexSet`, uses integers only, which limits its usefulness to arrays and other random-access collection types. The standard library is missing a collection that can efficiently store ranges of indices, and is missing the operations that you might want to perform with such a collection. These operations themselves can be challenging to implement correctly, and have performance traps as well — see last year's [Embracing Algorithms](https://developer.apple.com/videos/wwdc/2018/?id=223) WWDC talk for a demonstration. 

## Proposed solution

This proposal adds a `RangeSet` type for representing multiple, noncontiguous ranges, as well as a variety of collection operations for creating and working with range sets.

```swift
var numbers = Array(1...15)

// Find the indices of all the even numbers
let indicesOfEvens = numbers.indices(where: { $0.isMultiple(of: 2) })

// Perform an operation with just the even numbers
let sumOfEvens = numbers[indicesOfEvens].reduce(0, +)
// sumOfEvens == 56

// You can gather the even numbers at the beginning
let rangeOfEvens = numbers.gather(indicesOfEvens, justBefore: numbers.startIndex)
// numbers[rangeOfEvens] == [2, 4, 6, 8, 10, 12]
// numbers == [2, 4, 6, 8, 10, 12, 1, 3, 5, 7, 9, 11, 13, 15]

// Reset `numbers`
numbers = Array(1...15)

// You can also build range sets by hand using array literals...
let notTheMiddle: RangeSet = [0..<5, 10..<15]
print(Array(numbers[notTheMiddle]))
// Prints [1, 2, 3, 4, 5, 11, 12, 13, 14, 15]

// ...or by using set operations
let smallEvens = indicesOfEvens.intersection(
    numbers.indices(where: { $0 < 10 }))
print(Array(numbers[smallEvens]))
// Prints [2, 4, 6, 8]
```

These are just a few examples; the complete proposal includes operations like inverting a range set and inserting and removing ranges, which are covered in the next section.

## Detailed design

`RangeSet` is generic over any `Comparable` type, and supports fast containment checks for ranges and individual values, as well as adding and removing ranges of that type. 

```swift
/// A set of ranges of any comparable value.
public struct RangeSet<Bound: Comparable> {
    /// Creates an empty range set.
    public init() {}

    /// Creates a range set containing the given range.
    public init(_ range: Range<Bound>)
    
    /// Creates a range set containing the given ranges.
    public init<S: Sequence>(_ ranges: S) where S.Element == Range<Bound>
    
    /// A Boolean value indicating whether the range set is empty.
    public var isEmpty: Bool { get }
    
    /// Returns a Boolean value indicating whether the given value is
    /// contained by the ranges in the range set.
    ///
    /// - Complexity: O(log *n*), where *n* is the number of ranges in the
    ///   range set.
    public func contains(_ value: Bound) -> Bool
        
    /// Returns a Boolean value indicating whether the given range is
    /// contained by the ranges in the range set.
    ///
    /// This method returns `true` if and only if one of the ranges that 
    /// comprises the range set fully contains `range`. This example shows
    /// ranges that are and are not contained by a range set:
    /// 
    ///     let set: RangeSet = [0..<5, 10..<15]
    ///     print(set.contains(1..<4))
    ///     // Prints "true"
    ///     print(set.contains(4..<7))
    ///     // Prints "false"
    ///     print(set.contains(4..<12))
    ///     // Prints "false"
    ///
    /// - Complexity: O(log *n*), where *n* is the number of ranges in the
    ///   range set.
    public func contains(_ range: Range<Bound>) -> Bool
    
    /// Inserts the given range into the range set.
    public mutating func insert(_ range: Range<Bound>)
        
    /// Removes the given range from the range set.
    public mutating func remove(_ range: Range<Bound>)
}
```

`RangeSet` conforms to `Equatable`, to `CustomStringConvertible`, and, when its `Bound` type conforms to `Hashable`, to `Hashable`. `RangeSet` also has `ExpressibleByArrayLiteral` conformance, using arrays of ranges as its literal type.

#### `SetAlgebra`-like methods

`RangeSet` implements a subset of the `SetAlgebra` protocol. Because of its efficient representation for contiguous ranges, there is no way to insert a single element into a `RangeSet` .

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

Working with collection indices is a primary use case for `RangeSet`. To support this, `RangeSet` includes initializers and insertion and removal methods for working with individual indices and range expressions, as well as a way to "invert" a range set with respect to a collection.

Calling one of these methods with an individual index is equivalent to calling the related `RangeSet` method with a range that contains only that index. In this example, the two ways of inserting a range containing `indexOfI` into the range set are equivalent:

```swift
let str = "Fresh cheese in a breeze"
var set = str.indices(where: { $0 == "e" })
let indexOfI = str.firstIndex(of: "i")!

// (1) Creating a range, then inserting it into 'set'
let rangeOfI = indexOfI ..< str.index(after: indexOfI)
set.insert(rangeOfI)

// (2) Inserting the index with the convenience method
set.insert(indexOfI, within: str)
```

The initializers and methods are listed below: 

```swift
extension RangeSet {
    /// Creates a new range set containing a range that contains only the 
    /// specified index in the given collection.
    public init<C>(_ index: Bound, within collection: C)
        where C: Collection, C.Index == Bound
    
    /// Creates a new range set containing ranges that contain only the
    /// specified indices in the given collection.
    public init<S, C>(_ indices: S, within collection: C)
        where S: Sequence, C: Collection, S.Element == C.Index, C.Index == Bound
    
    /// Creates a new range set containing the range represented by the 
    /// specified range expression.
    public init<R, C>(_ range: R, within collection: C)
        where C: Collection, C.Index == Bound, R: RangeExpression, R.Bound == Bound
    
    /// Inserts a range that contains only the specified index into the range 
    /// set.
    public mutating func insert<C>(_ index: Bound, within collection: C)
        where C: Collection, C.Index == Bound
    
    /// Inserts the range represented by the specified range expression into 
    /// the range set.
    public mutating func insert<R, C>(_ range: R, within collection: C)
        where C: Collection, C.Index == Bound, R: RangeExpression, R.Bound == Bound
    
    /// Removes a range that contains only the specified index from the range 
    /// set.
    public mutating func remove<C>(_ index: Bound, within collection: C)
        where C: Collection, C.Index == Bound
    
    /// Removes the range represented by the specified range expression from 
    /// the range set.
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

#### Accessing Underlying Ranges and Individual Indices

`RangeSet` provides access to its ranges as a random-access collection via the `ranges` property. 
You can access the individual indices represented by the range set by using it as a subscript parameter to a collection's `indices` property.

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
```

The ranges that are exposed through this collection are always in ascending order, are never empty, and never overlap or adjoin. For this reason, inserting an empty range or a range that is subsumed by the ranges already in the set has no effect on the range set. Inserting a range that adjoins an existing range simply extends that range.

```swift
var set: RangeSet = [0..<5, 10..<15]
set.insert(7..<7)
set.insert(11.<14)
// Array(set.ranges) == [0..<5, 10..<15] 

set.insert(5..<7)
// Array(set.ranges) == [0..<7, 10..<15]

set.insert(7..<10)
// Array(set.ranges) == [0..<15]
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
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    public func indices(of element: Element) -> RangeSet<Index>
}
```

#### Accessing elements via `RangeSet`

When you have a `RangeSet` describing a group of indices for a collection, you can access those elements via a new subscript. This new subscript returns a new `DiscontiguousSlice` type, which couples the collection and range set to provide access.

```swift
extension Collection {
    /// Accesses a view of this collection with the elements at the given
    /// indices.
    ///
    /// - Complexity: O(1)
    public subscript(indices: RangeSet<Index>) -> DiscontiguousSlice<Self> { get }
}

extension MutableCollection {
    /// Accesses a mutable view of this collection with the elements at the
    /// given indices.
    ///
    /// - Complexity: O(1) to access the elements, O(*m*) to mutate the
    ///   elements at the positions in `indices`, where *m* is the number of
    ///   elements indicated by `indices`.
    public subscript(indices: RangeSet<Index>) -> DiscontiguousSlice<Self> { get set }
}

/// A collection wrapper that provides access to the elements of a collection,
/// indexed by a set of indices.
public struct DiscontiguousSlice<Base: Collection>: Collection {
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
    public subscript(bounds: Range<Index>) -> Self { get }
}
```

`DiscontiguousSlice` conforms to `Collection`, and conditionally conforms to `BidirectionalCollection` and `MutableCollection` if its base collection conforms.  

#### Moving elements

Within a mutable collection, you can gather the elements represented by a range set, inserting them in a contiguous range before the element at a specific index, and otherwise preserving element order. This proposal also adds a method for gathering all the elements matched by a predicate, and methods for shifting a contiguous region of elements, denoted by a single index, range, or range expression, to a specific insertion point.

The elements that you shift or gather don't necessarily end up at exactly the specified insertion point, because other elements slide over to fill gaps left by the elements that move. For that reason, these gathering and shifting methods return the new range or index of the elements that are moved.

To visualize these operations, divide a collection into two parts, before and after the insertion point. The elements to gather or shift are collected in order in that gap, and the resulting range (or index, for single element moves) is returned. As an example, consider a shift from a range at the beginning of an array of letters to a position further along in the array:

```swift
var array = ["a", "b", "c", "d", "e", "f", "g"]
let newSubrange = array.shift(from: 0..<3, to: 5)
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
let newPosition = array.shift(from: 1, to: 5)
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
    /// Collects the elements at the given indices just before the element at 
    /// the specified index.
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
        _ indices: RangeSet<Index>, at insertionPoint: Index
    ) -> Range<Index>

    /// Collects the elements that satisfy the given predicate just before the
    /// element at the specified index.
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
        at insertionPoint: Index, where predicate: (Element) -> Bool
    ) -> Range<Index>
    
    /// Shifts the elements in the given range to just before the element at 
    /// the specified index.
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
        from range: Range<Index>, to insertionPoint: Index
    ) -> Range<Index>

    /// Shifts the elements in the given range expression to just before the 
    /// element at the specified index.
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
        from range: R, to insertionPoint: Index
    ) -> Range<Index> where R.Bound == Index

    /// Moves the element at the given index to just before the element at the
    /// specified index.
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
        from source: Index, to insertionPoint: Index
    ) -> Index
}
```

#### Removing elements

Within a range-replaceable collection, you can remove the elements represented by a range set. `removeAll(at:)` is a new `RangeReplaceableCollection` requirement with a default implementation, along with additional overload for collections that also conform to `MutableCollection`.

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

All the proposed additions are versioned.

## Alternatives considered

### `SetAlgebra` Conformance

An earlier version of this proposal included `SetAlgebra` conformance when the `Bound` type was `Stridable` with an integer `Stride`. The idea behind this constraint was that with an integer-strideable bound, `RangeSet` could translate an individual value into a `Range` which contained just that value. This translation enabled the implementation of `SetAlgebra` methods like insertion and removal of individual elements.

However, when working with collection indices, there is no guarantee that the correct stride distance is the same for all integer-stridable types. For example, when working with a collection `C` that uses even integers as its indices, removing a single integer from a `RangeSet<C.Index>` could leave an odd number as the start of one of the constitutive ranges:

```swift
let numbers = (0..<20).lazy.filter { $0.isMultiple(of: 2) }
var set = RangeSet(0..<10)
set.remove(4)
// set.ranges == [0..<4, 5..<10]
```

Since `5` is not a valid index of `numbers`, it's an error to use it when subscripting the collection.

One way of avoiding this issue would be to change the internal representation of `RangeSet` to store an enum of single values, ranges, and fully open ranges:

```swift
enum _RangeSetValue {
    case single(Bound)
    case halfOpen(Range<Bound>)
    case fullyOpen(lower: Bound, upper: Bound)
}
```

This implementation would allow correct `SetAlgebra` conformance, but lose the ability to always have a maximally efficient representation of ranges and a single canonical empty state. Through additions and removals, you could end up with a series of a fully-open ranges, none of which actually contain any values in the `Bound` type.

```swift
var set: RangeSet = [1..<4]
set.remove(2)
set.remove(3)
set.remove(4)
// set.ranges == [.fullyOpen(1, 2), .fullyOpen(2, 3), .fullyOpen(3, 4)]
```

### `Elements` View

In an earlier version of the proposal, `RangeSet` included a collection view of the indices, conditionally available when the `Bound` type was strideable with an integer stride. This collection view was removed for the same reasons as covered in the section above. Users can access these indices by using a `RangeSet` as a subscript for the source collection's `indices` property.
