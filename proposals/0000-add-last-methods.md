# Add `last(where:)` and `lastIndex(where:)` Methods

* Proposal: [SE-NNNN](0000-add-last-methods.md)
* Author: [Nate Cook](https://github.com/natecook1000)
* Status: **Awaiting review**
* Review manager: TBD
* Implementation: [Branch on natecook1000/swift](https://github.com/apple/swift/compare/master...natecook1000:nc-last)
* Related Bug: [\[SR-1504\] RFE: index(of:) but starting from end](https://bugs.swift.org/browse/SR-1504)

## Introduction

The standard library should include methods for finding the last element in a sequence, and the index of the last element in a collection, that match a given predicate.

* Swift-evolution thread: [\[swift-evolution\] (Draft) Add last(where:) and lastIndex(where:) methods](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/017048.html)

## Motivation

The standard library currently has methods that perform a linear search to find an element or the index of an element that matches a predicate:

```swift
let a = [20, 30, 10, 40, 20, 30, 10, 40, 20]
a.first(where: { $0 > 25 })         // 30
a.index(where: { $0 > 25 })         // 1
a.index(of: 10)                     // 2
```

Unfortunately, there are no such methods that search from the end. Finding the last of a particular kind of element has multiple applications, particularly with text, such as wrapping a long string into lines of a maximum length or trimming whitespace from the beginning and end of a string.

You can work around this limitation by using the methods above on a reversed view of a collection, but the resulting code is frankly appalling. For example, to find the corresponding last index to `a.index(where: { $0 > 25 })`, something like this unholy incantation is required:

```swift
(a.reversed().index(where: { $0 > 25 })?.base).map({ a.index(before: $0) })
```

## Proposed solution

The `Sequence` protocol should add a `last(where:)` method, and the `Collection` protocol should add `lastIndex(where:)` and `lastIndex(of:)` methods. These new methods create symmetry with the existing forward-searching APIs that are already part of `Sequence` and `Collection`.

These additions remove the need for searching in a reversed collection and allow code like this:

```swift
a.last(where: { $0 > 25 })          // 40
a.lastIndex(where: { $0 > 25 })     // 7
a.lastIndex(of: 10)                 // 6
```

Much better!

## Detailed design

`last(where:)` and `lastIndex(where:)` will be added to the standard library as `Sequence` and `Collection` protocol requirements, respectively. These methods will have default implementations in their respective protocols and in `BidirectionalCollection`, which can provide a more efficient implementation. `lastIndex(of:)` will be provided in `Collection` and `BidirectionalCollection` extensions constrained to `Equatable` elements. 

The new APIs are shown here:

```swift
protocol Sequence {
    // Existing declarations...

    /// Returns the last element of the collection that satisfies the given
    /// predicate, or `nil` if no element does. The sequence must be finite.
    func last(where predicate: (Element) throws -> Bool) 
        rethrows -> Element?
}

protocol Collection {
    // Existing declarations...
    
    /// Returns the index of the last element of the collection that satisfies 
    /// the given predicate, or `nil` if no element does.
    func lastIndex(where predicate: (Element) throws -> Bool) 
        rethrows -> Index? 
}

extension BidirectionalCollection {
    func last(where predicate: (Element) throws -> Bool) 
        rethrows -> Element? { ... }

    func lastIndex(where predicate: (Element) throws -> Bool) 
        rethrows -> Index? { ... }
}

extension Collection where Element: Equatable {
    /// Returns the index of the last element equal to the given element, or 
    /// no matching element is found.
    func lastIndex(of element: Element) -> Index? { ... }
}

extension BidirectionalCollection where Element: Equatable {
    func lastIndex(of element: Element) -> Index? { ... }
}
```

You can explore the usage (but not really the performance) of these methods in [this Swift sandbox](http://swift.sandbox.bluemix.net/#/repl/5a0345476e726279e5c6f486).

## Source compatibility

The addition of the `last(where:)`, `lastIndex(where:)`, and `lastIndex(of:)` methods is strictly additive and should have no impact on existing code.

## Effect on ABI stability & API resilience

This change does not affect ABI stability or API resilience beyond the addition of the new methods.

## Alternatives considered

A previous proposal limited the new methods to the `BidirectionalCollection` protocol. This isn't a necessary limitation, as the standard library already has methods on sequences and forward collections with the same performance characteristics. 

Another previous proposal included renaming `index(of:)` and `index(where:)` to `firstIndex(of:)` and `firstIndex(where:)`, respectively. This version of the proposal removes that source-breaking change.
