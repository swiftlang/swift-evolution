# Add Array binary search to the  standard library

* Proposal: TBD
* Author: [Igor Vasilenko](https://github.com/vasilenkoigor)
* Review Manager: TBD
* Status: TBD

## Introduction

Right now, for Array implemented array.contains(element) and array.indexOf(element)for searching in an array. Both of these methods iterate over all elements in the array, starting at index 0, until they find a match. In the worst case (there is no match), they have to iterate over the entire array. In big O notation, the methods’ performance characteristic is O(n). This is usually not a problem for small arrays with only a few dozen elements. But if your code regularly needs to find objects in arrays with thousands of elements, you may want to look for a faster search algorithm.

Swift-evolution threads: [Late Pitch](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160905/026976.html)

## Motivation

If the array is sorted by the search key, binary search can give you a huge boost in performance. By comparing the middle element in the array to the search item, the algorithm effectively halves the number of elements it has to search trough with each iteration. Binary search has O(log n) performance. What does this mean in practice? Searching a sorted array of 100,000 elements using binary search would require at most 17 comparisons compared to the 50,000 comparisons a naive linear search would take on average.

## Detailed design

```swift
// Passed array into function should be sorted. 
public func binarySearch<T: Comparable>(array: [T], key: T, range: Range<Int>, sorted: Bool) -> Int? {
    if !sorted {
        return 0
    }
    
    if range.startIndex >= range.endIndex {
        return nil
    } else {
        let midIndex = range.endIndex + (range.endIndex - range.startIndex) / 2
        if array[midIndex] > key {
            return binarySearch(array, key: key, range: range.startIndex ..< midIndex, sorted: sorted)
        } else if array[midIndex] < key {
            return binarySearch(array, key: key, range: midIndex + 1 ..< range.endIndex, sorted: sorted)
        } else {
            return midIndex
        }
    }
}
```

## Alternatives considered

I'm considered to sorting array, if caller pass to false sorted argument.
