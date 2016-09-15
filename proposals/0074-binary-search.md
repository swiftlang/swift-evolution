# Implementation of Binary Search functions

* Proposal: [SE-0074](0074-binary-search.md)
* Authors: [Lorenzo Racca](https://github.com/lorenzoracca), [Jeff Hajewski](https://github.com/j-haj), [Nate Cook](https://github.com/natecook1000)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000148.html)

## Introduction

Swift does not offer any way to efficiently search sorted collections.
This proposal seeks to add a few different functions that implement the binary search algorithm.

- Swift-evolution thread: [\[Proposal\] Add Binary Search functions to SequenceType](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/012680.html)
- JIRA: [Swift/SR-368](https://bugs.swift.org/browse/SR-368)

## Motivation

Searching through wide arrays (more than 100k elements) is inherently inefficient as the existing `Sequence.contains(_:)` performs a linear search that has to test the given condition for every element of the array.

Storing data in a sorted array would typically improve the efficiency of this search from O(n) to O(log n) by allowing a binary search algorithm that cuts the search space in half with each iteration. Unfortunately, the standard library has no built-in ability to search on a collection that is known to be sorted.

## Proposed solution

The proposed solution is to add three new methods that implement the binary search algorithm, called `partitionedIndex(where:)`, `sortedIndex(of:)`, and `sortedRange(of:)`, as well as a partitioning method called `partition(where:)`. These methods would be added to the `Collection` protocol as default implementations.

To support future sorted collections, this proposal also suggests the addition of customization points for `contains(_:)` and `index(of:)` for collections with `Comparable` elements: `Sequence._customContainsComparableElement(_:)` and `Collection._customIndexOfComparableElement(_:)`.

Finally, this proposal suggests the removal of the two existing `partition()` methods from public API, as they are not as generally useful as the proposed `partition(where:)` method and are subsumed by the new functionality.

The following arrays will be used in the examples below:

    let a = [10, 20, 30, 30, 30, 40, 60]
    let r = [60, 40, 30, 30, 30, 20, 10]  // i.e., a.reversed()

- `partitionedIndex(where:)` accepts a unary predicate and returns the index of the first value in the collection that does not satisfy the predicate. The elements of the collection must already be partitioned by the predicate. This method corresponds with `partition_point` in the C++11 STL.

        a.partitionedIndex(where: { $0 < 20 })      // 1

    If you have a binary (two-argument) predicate, like `<`, you can construct unary predicates for `partitionedIndex(where:)` that find the lower and upper bound for a given value:

        a.partitionedIndex(where: { $0 < 30 })      // 2 - lower bound
        a.partitionedIndex(where: { !(30 < $0) })   // 5 - upper bound

- `sortedIndex(of:)` finds the position of a given value in a sorted collection. If the value isn't found, the method returns `nil`. An additional version of the method takes a value and a binary `isOrderedBefore` closure. This method loosely corresponds with `binary_search` in the C++ STL, but returns the value's index if found, rather than just `true`.

        a.sortedIndex(of: 30)        // 2
        a.sortedIndex(of: 60)        // 6
        a.sortedIndex(of: 100)       // nil
        r.sortedIndex(of: 60, isOrderedBefore: >)  // 0

- `sortedRange(of:)` finds the range of all consecutive elements that are equivalent to a given value. If the value isn't found, the range is empty with `lowerBound(value)` as its `startIndex`. An additional version of the method takes a value and a binary `isOrderedBefore` closure. This method corresponds with `equal_range` in the C++ STL.

        a.sortedRange(of: 30)        // 2..<5
        a.sortedRange(of: 50)        // 6..<6

- `partition(where:)` is a mutating method that accepts a unary (one-argument) predicate. The elements of the collection are partitioned according to the predicate, so that there is a pivot index `p` where every element before `p` matches the predicate and every element at and after `p` doesn't match the predicate. This method corresponds with `partition` in the C++ STL.

        var n = [30, 40, 20, 30, 30, 60, 10]
        let p = n.partition(where: { $0 < 30 })
        // n == [30, 20, 30, 30, 10, 40, 60]
        // p == 5

    After partitioning, the predicate returns `true` for every element in `n.prefix(upTo: p)` and `false` for every element in `n.suffix(from: p)`.

## Detailed design

The proposed APIs are collected here:

```swift
extension MutableCollection {
    /// Reorders the elements of the collection such that all the
    /// elements that match the predicate are ordered before all the
    /// elements that do not match the predicate.
    ///
    /// - Returns: The index of the first element in the reordered
    ///   collection that does not match the predicate.
    @discardableResult
    mutating func partition(
        where predicate: @noescape (Iterator.Element) throws-> Bool
        ) rethrows -> Index
}

extension Collection {
    /// Returns the index of the first element in the collection
    /// that doesn't match the predicate.
    ///
    /// The collection must already be partitioned according to the
    /// predicate, as if `x.partition(where: predicate)` had already
    /// been called.
    func partitionedIndex(
        where predicate: @noescape (Iterator.Element) throws -> Bool
        ) rethrows -> Index
        var low = self.startIndex, high = self.endIndex
        while low != high {
            let mid = index(low, offsetBy: distance(from: low, to: high) / 2)
            if try predicate(self[mid]) { low = index(after: mid) }
            else { high = mid }
        }
        return low
    }

    /// Returns the index of `element`, using `isOrderedBefore` as the
    /// comparison predicate while performing a binary search.
    ///
    /// The elements of the collection must already be sorted according
    /// to `isOrderedBefore`, or at least partitioned by `element`.
    ///
    /// - Returns: The index of `element`, or `nil` if `element` isn't
    ///   found.
    func sortedIndex(of element: Iterator.Element,
        isOrderedBefore: @noescape (Iterator.Element, Iterator.Element)
            throws -> Bool
        ) rethrows -> Index?
        {
        let index = try self.partitionedIndex({ try isOrderedBefore($0, element) })
        
        return try (index != self.endIndex) && !isOrderedBefore(element, self[index]) ? index : nil
        }

    /// Returns the range of elements equivalent to `element`, using
    /// `isOrderedBefore` as the comparison predicate while performing
    /// a binary search.
    ///
    /// The elements of the collection must already be sorted according
    /// to `isOrderedBefore`, or at least partitioned by `element`.
    ///
    /// - Returns: The range of indices corresponding with elements
    ///   equivalent to `element`, or an empty range with its
    ///   `startIndex` equal to the insertion point for `element`.
    func sortedRange(of element: Iterator.Element,
        isOrderedBefore: @noescape (Iterator.Element, Iterator.Element)
            throws -> Bool
        ) rethrows -> Range<Index>
}

extension Collection where Iterator.Element: Comparable {
    /// Returns the index of `element`, performing a binary search.
    ///
    /// The elements of the collection must already be sorted, or at
    /// least partitioned by `element`.
    ///
    /// - Returns: The index of `element`, or `nil` if `element` isn't
    ///   found.
    func sortedIndex(of element: Iterator.Element) -> Index?

    /// Returns the range of elements equal to `element`, performing
    /// a binary search.
    ///
    /// The elements of the collection must already be sorted, or at
    /// least partitioned by `element`.
    ///
    /// - Returns: The range of indices corresponding with elements
    ///   equal to `element`, or an empty range with its `startIndex`
    ///   equal to the insertion point for `element`.
    func sortedRange(of element: Iterator.Element) -> Range<Index>
}
```

The customization points will need to be added to the protocol declarations for `Sequence` and `Collection`, with default implementations that simply return `nil`.

```swift
protocol Sequence {
    // existing Sequence declarations...
    
    /// Returns `Optional(true)` if an element was found;
    /// `Optional(false)` if an element was searched for but not found;
    /// `nil` otherwise.
    func _customContainsComparableElement(element: Iterator.Element) -> Bool?
}

extension Sequence {
    func _customContainsComparableElement(element: Iterator.Element) -> Bool? { 
        return nil
    }
}

protocol Collection {
    // existing Collection declarations...
            
    /// Returns `Optional(Optional(index))` if an element was found;
    /// `Optional(nil)` if an element was searched for but not found;
    /// `nil` otherwise.
    func _customIndexOfComparableElement(element: Iterator.Element) -> Index??
}

extension Collection {
    func _customIndexOfComparableElement(element: Iterator.Element) -> Index?? {
        return nil
    }
}
```

## Example usage

As an example of how the `partitionedIndex(of:)` method enables heterogeneous binary search, this `SortedDictionary` type uses an array of `(Word, Definition)` tuples as its storage, sorted by `Word`.

Better explained examples can be found in the Swift playground available [here to download](https://github.com/lorenzoracca/Swift-binary-search/blob/binarysearch/Binary%20Search%20Proposal.playground.zip).

```swift
struct SortedDictionary<Word: Comparable, Definition>:
    Collection, DictionaryLiteralConvertible
{
    var _storage: [(word: Word, definition: Definition)]
    
    // Collection
    var startIndex: Int { return _storage.startIndex }
    var endIndex: Int { return _storage.endIndex }
    subscript(index: Int) -> (word: Word, definition: Definition) {
        return _storage[index]
    }

    // DictionaryLiteralConvertible
    init(dictionaryLiteral elements: (Word, Definition)...) {
        self._storage = elements
            .sorted { $0.0 < $1.0 }
            .map { (word: $0, definition: $1) }
    }

    // key/value access
    subscript(word: Word) -> Definition? {
        get {
            let i = _storage.partitionedIndex(where: { $0.word < word })
            if i != endIndex && _storage[i].word == word {
                return _storage[i].definition
            }
            return nil
        }
        set {
            // find insertion point
            let i = _storage.partitionedIndex(where: { $0.word < word })
            
            if i != endIndex && _storage[i].word == word {
                // update or delete
                if let newValue = newValue {
                    _storage[i].definition = newValue
                } else {
                    _storage.remove(at: i)
                }
            } else if let newValue = newValue {
                // insert
                _storage.insert((word, newValue), at: i)
            }
        }
    }
}
```
## Impact on existing code

The impact of the change will be the availability of four (plus overloads) functions implementing partitioning and binary search and the removal of the existing `partition` methods.

#### Removal of `partition()` / `partition(isOrderedBefore:)`

The current `partition()` methods, which partition on the value of the first element of a collection, are used by the standard library's current sorting algorithm but don't offer the more general partitioning functionality of the proposed `partition(where:)` method. If this proposal is accepted without removing the existing methods, there would be three `partition` methods available, which seems excessive:

- `partition(isOrderedBefore:)`
- `partition()` (an overload of `partition(isOrderedBefore:)` for `Comparable` elements)
- `partition(where:)`

Uses of the existing `partition()` methods could be flagged or in theory be replaced programmatically. The replacement code, on a mutable collection `c`:

```swift
// old
c.partition()

// new
if let first = c.first {
    c.partition(where: { $0 < first })
}
```
A thorough, though not exhaustive, search of GitHub for the existing `partition` method found no real evidence of its use. The discovered uses of a `partition` method were mainly tests from the Swift project and third-party implementations similar to the one proposed.

## Alternatives considered

The authors considered a few alternatives to the current proposal:

- `lower_bound` / `upper_bound`: The C++ STL includes two functions that help when searching sorted collections and when sorting or merging. However, both are subsumed by the functionality of `partition_point` and its unary predicate, and as such are not needed. Whether these methods should accept unary or binary predicates was also a matter of discussion.

- `binary_search`: The STL function analogous to the proposed `sortedIndex(of:)` method returns only a Boolean value. We determined that a method returning an optional index was more useful: the `.none` case conveys "not found", and the returned index (when found) provides easy access to the matched element.

## Rationale

On [May 11, 2016](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000148.html), the core team decided to **Reject** this proposal.  The feedback on the proposal was generally positive about the concept of adding binary search functionality, but  negative about the proposal as written, with feedback that it was adding too much complexity to the API.
