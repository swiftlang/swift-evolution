# Add `last(where:)` and `lastIndex(where:)` Methods to Collections

* Proposal: [SE-0000]()
* Author: [Nate Cook](https://github.com/natecook1000)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

The standard library should include methods for finding the last element of a collection that matches a predicate, along with the index of that element.

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

Unfortunately, there are no such methods that search from the end. Finding the last of a particular kind of element has multiple applications, particularly with text, such as wrapping a long string into lines of a maximum length or trimming whitespace from the beginning and end of a string.

You can work around this limitation by using the methods above on a reversed view of a collection, but the resulting code is truly dreadful. For example, to find the corresponding last index to `a.index(where: { $0 > 25 })`, something like this unholy incantation is required:

```swift
(a.reversed().index(where: { $0 > 25 })?.base).flatMap({ a.index(before: $0) })
```

## Proposed solution

The `Collection` protocol should include three new methods for symmetry with the existing forward-searching APIs: `last(where:)`, `lastIndex(where:)`, and `lastIndex(of:)`. In addition, the two forward-searching methods `index(of:)` and `index(where:)` should be renamed to `firstIndex(of:)` and `firstIndex(where:)`. This renaming would link these methods with the new `first(where:)` method, disambiguate them from index manipulation methods like `index(after:)`, and set up a consistent relationship between the `first...` and `last...` methods.

These additions remove the need for searching in a reversed collection and allow code like the following:

```swift
a.last(where: { $0 > 25 })          // 40
a.lastIndex(of: 10)                 // 6
a.lastIndex(where: { $0 > 25 })     // 7
```
Much better!

## Detailed design

`lastIndex(where:)` and `last(where:)` will be added to the standard library as `Collection` protocol requirements with default implementations in both `Collection` and `BidirectionalCollection`, which can provide a more efficient implementation. `lastIndex(of:)` while be in an extension constrained to equatable elements. The new and renamed APIs are shown here:

```swift
protocol Collection {
    // New methods:

    /// Returns the last element of the collection that satisfies the given
    /// predicate, or `nil` if no element does.
    func last(where predicate: @noescape (Iterator.Element) throws -> Bool) 
        rethrows -> Iterator.Element?

    /// Returns the index of the last element of the collection that satisfies 
    /// the given predicate, or `nil` if no element does.
    func lastIndex(where predicate: @noescape (Iterator.Element) throws -> Bool) 
        rethrows -> Index? 

    // Renamed method:

    /// Returns the index of the first element of the collection that satisfies 
    /// the given predicate, or `nil` if no element does.
    func firstIndex(where predicate: @noescape (Iterator.Element) throws -> Bool) 
        rethrows -> Index? 
}

extension Collection where Iterator.Element: Equatable {
    // New method:

    /// Returns the index of the last element equal to the given element, or 
    /// `nil` if there's no equal element.
    func lastIndex(of element: Iterator.Element) -> Index?

    // Renamed method:

    /// Returns the index of the first element equal to the given element, or 
    /// `nil` if there's no equal element.
    func firstIndex(of element: Iterator.Element) -> Index?
}
```

Implementations of these methods can be explored in [this Swift sandbox](http://swiftlang.ng.bluemix.net/#/repl/e812a36cfa66647e1dbd7ab5be5376f78c769924262178d62c25aa0124c45810).

## Impact on existing code

The addition of the `last...` methods is strictly additive and should have no impact on existing code. The migration tools should be able to provide a fixit for the simple renaming of `index(of:)` and `index(where:)`.

## Alternatives considered

An earlier proposal limited the proposed new methods to the `BidirectionalCollection` protocol. This isn't a necessary limitation, as the standard library already has methods on forward collections with the same performance characteristics. That earlier proposal also did not include renaming `index(of:)` and `index(where:)` to `firstIndex(of:)` and `firstIndex(where:)`, respectively.
