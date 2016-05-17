# Add `last(where:)` and `lastIndex(where:)` Methods to Bidirectional Collections

* Proposal: [SE-0000]()
* Author: [Nate Cook](https://github.com/natecook1000)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

The standard library should include methods for finding the last element of a bidirectional collection that matches a predicate, along with the index of that element.

* Swift-evolution thread: [\[swift-evolution\] (Draft) Add last(where:) and lastIndex(where:)	methods](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/017048.html)
* Related Bug: [\[SR-1504\] RFE: index(of:) but starting from end](https://bugs.swift.org/browse/SR-1504)

## Motivation

The standard library currently has methods that perform a linear search from the beginning of a collection to find an element or the index of an element that matches a predicate:

```swift
let a = [20, 30, 10, 40, 20, 30, 10, 40, 20]
a.first(where: { $0 > 25 })         // 30
a.index(of: 10)                     // 2
a.index(where: { $0 > 25 })         // 1
```

Unfortunately, there are no such methods that search from the end of a bidirectional collection. Finding the last of a particular kind of element has multiple applications, particularly with text, such as wrapping a long string into lines of a maximum length or trimming whitespace from the beginning and end of a string.

You can work around this limitation by using the methods above on a reversed view of a collection, but the resulting code is truly dreadful. For example, to find the corresponding last index to `a.index(where: { $0 > 25 })`, this unholy incantation is required:

```swift
(a.reversed().index(where: { $0 > 25 })?.base).flatMap({ a.index(before: $0) })
```

## Proposed solution

Bidirectional collections should include three new methods for symmetry with the existing forward-searching APIs: `last(where:)`, `lastIndex(where:)`, and `lastIndex(of:)`.

These additions remove the need for searching in a reversed collection and allow code like the following:

```swift
a.last(where: { $0 > 25 })          // 40
a.lastIndex(of: 10)                 // 6
a.lastIndex(where: { $0 > 25 })     // 7
```
Much better!

## Detailed design

The three new methods will be added to the standard library in extensions to `BidirectionalCollection`. The implementation is straightforward:

```swift
extension BidirectionalCollection {
    /// Returns the index of the last element of the collection that satisfies 
    /// the given predicate, or `nil` if no element does.
    func lastIndex(where predicate: @noescape (Iterator.Element) throws -> Bool) 
        rethrows -> Index? 
    {
        var i = endIndex
        while i != startIndex {
            formIndex(before: &i)
            if try predicate(self[i]) {
                return i
            }
        }
        return nil
    }

    /// Returns the last element of the collection that satisfies the given
    /// predicate, or `nil` if no element does.
    func last(where predicate: @noescape (Iterator.Element) throws -> Bool) 
        rethrows -> Iterator.Element? 
    {
        if let i = try lastIndex(where: predicate) {
            return self[i]
        }
        return nil
    }
}

extension BidirectionalCollection where Iterator.Element: Equatable {
    /// Returns the index of the last element equal to the given element, or 
    /// `nil` if there's no equal element.
    func lastIndex(of element: Iterator.Element) -> Index? {
        var i = endIndex
        while i != startIndex {
            formIndex(before: &i)
            if element == self[i] {
                return i
            }
        }
        return nil
    }
}
```
## Impact on existing code

This change is strictly additive and should have no impact on existing code.

## Alternatives considered

For consistency, one suggestion was to rename `index(of:)` and `index(where:)` to `firstIndex(of:)` and `firstIndex(where:)`, respectively. That change is outside the scope of this proposal.
