# Add Array binary search to the  standard library

* Proposal: TBD
* Authors: [Igor Vasilenko](https://github.com/vasilenkoigor), [Timofey Khomutnikov](https://github.com/khomTima)
* Review Manager: TBD
* Status: TBD

## Introduction

Right now, for Array implemented array.contains(element) and array.indexOf(element)for searching in an array. Both of these methods iterate over all elements in the array, starting at index 0, until they find a match. In the worst case (there is no match), they have to iterate over the entire array. In big O notation, the methods’ performance characteristic is O(n). This is usually not a problem for small arrays with only a few dozen elements. But if your code regularly needs to find objects in arrays with thousands of elements, you may want to look for a faster search algorithm.

Swift-evolution threads: [Late Pitch](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160905/026976.html)

## Motivation

If the array is sorted by the search key, binary search can give you a huge boost in performance. By comparing the middle element in the array to the search item, the algorithm effectively halves the number of elements it has to search trough with each iteration. Binary search has O(log n) performance. What does this mean in practice? Searching a sorted array of 100,000 elements using binary search would require at most 17 comparisons compared to the 50,000 comparisons a naive linear search would take on average.

## Detailed design

```swift
extension Array where Element : Comparable {
    
    // Binary search.
    // Passed Array should be only sorted.
    public func indexOf(key: Element, range: Range<Int>) -> Int? {
        if self.count == 1 {
            return self.first == key ? 0 : nil
        }
        
        var lowerBound = range.startIndex
        var upperBound = range.endIndex
        while lowerBound < upperBound {
            let midIndex = lowerBound + (upperBound - lowerBound) / 2
            if self[midIndex] == key {
                return midIndex
            } else if self[midIndex] < key {
                lowerBound = midIndex + 1
            } else {
                upperBound = midIndex
            }
        }
        
        return nil
    }
}

// Example of usage
let numbers = [1, 2, 3, 4, 5, 6]
numbers.indexOf(5, range: 2..<numbers.count)
```
