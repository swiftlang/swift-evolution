# Offset Range Subscript

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Letanyan Arumugam](https://github.com/Letanyan)
* Review Manager: TBD
* Status: [apple/swift#14389](https://github.com/apple/swift/pull/14389)

## Introduction
A collection that has an `Index` type that cannot be offset independently of its
collection can cause overly verbose code that obfuscates one's intent. To help 
improve this we propose adding a `subscript(offset:)` method to `Collection` and
`MutableCollection` that would accept an offsetting range.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/shorthand-for-offsetting-startindex-and-endindex/9397)

## Motivation
Working with an index that cannot be offset independently, without its 
corresponding collection, causes the intent of code to get lost in an overly 
verbose call site.

Currently to get a slice of a `String`, not anchored at the start or end of
the collection, one might use the following subscript method:
```
let s = "Hello, Swift!"
let subject = s[s.index(s.startIndex, offsetBy: 7)...s.index(s.startIndex, offsetBy: 11)]
```
This approach unfortunately suffers from redundancy and is in general unwieldy 
to handle. 

A shorter approach, that is also available, is to use combinations of `prefix`, 
`suffix` and the `drop` variants. A solution using these would follow like such:
```
let subject = s.suffix(6).prefix(5)
```
While this is much shorter it suffers from multiple drawbacks. It is not as 
natural as using a range, due to it using a 'sliding' co-ordinate system, which
increases the cognitive load for a user. This solution also suffers from 
API discoverability issues, since a user must learn multiple methods and figure
out that they can be composed in this way. 

## Proposed solution
A solution we propose to this problem is to extend `Collection` and 
`MutableCollection` with a subscript method, that takes a range, which would be 
used to offset the starting index of a collection.

Using the above example, along with our solution, we will be able to write the 
following.
```
let subject = s[offset: 7...11]
```

### Future Directions

It would be nice to have the ability to offset using the `endIndex` as a base, 
however, no design has yet to emerge that will allow us to do this expressively. 

## Detailed design
Subscript method protocol requirements should be added to `Collection` and 
`MutableCollection`.
```
protocol Collection {
  ...

  /// Accesses a contiguous subrange of the collection's elements with an
  /// offsetting range.
  ///
  /// The accessed slice uses the same indices for the same elements as the
  /// original collection uses. Always use the slice's `startIndex` property
  /// instead of assuming that its indices start at a particular value.
  ///
  ///
  /// - Parameter offset: A range of values that will offset the collections 
  ///   starting index to form a new range of indices relative to the 
  ///   collection.
  subscript(offset offset: Range<Int>) -> SubSequence { get }
}

protocol MutableCollection {
  ...

  /// Accesses a contiguous subrange of the collection's elements with an
  /// offsetting range.
  ///
  /// The accessed slice uses the same indices for the same elements as the
  /// original collection uses. Always use the slice's `startIndex` property
  /// instead of assuming that its indices start at a particular value.
  ///
  ///
  /// - Parameter offset: A range of values that will offset the collections 
  ///   starting index to form a new range of indices relative to the 
  ///   collection.
  subscript(offset offset: Range<Int>) -> SubSequence { get set }
}
```

Default implementations should be provided for the methods in `Collection` and 
`MutableCollection`.
```
extension Collection {
  subscript<R: RangeExpression>(offset offset: R) -> SubSequence 
  where R.Bound == Int {
    ...
  }
}

extension MutableCollection {
  subscript<R: RangeExpression>(offset offset: R) -> SubSequence 
  where R.Bound == Int {
    get { ... }
    set { ... }
  }
}
```

## Source compatibility
None

## Effect on ABI stability
N/A

## Effect on API resilience
N/A

## Alternatives considered

### Add methods to offset startIndex and/or endIndex
Adding convenience methods to offset `startIndex` and `endIndex` would help make
intent more obvious, however,  it still is not ideal. The following is an 
illustration of what this might look like:
```
let subject = s[s.startIndex(offsetBy: 7)...s.endIndex(offsetBy: -2)]
```

### Only add a method to offset startIndex 
If we were to include only a `startIndex(offsetBy:)` we might want to reconsider
a rename. One suggested name was `index(atOffset:)`.

### Use a KeyPath
Add an `index(_:offsetBy:)` method that would take a KeyPath as its first 
argument. This will give us the following usage.
```
let subject = s[s.index(\.startIndex, offsetBy: 7)..<s.index(\.endIndex, offsetBy: -1)]
```
While this will shorten code, when the collection instance name is long, it is 
still redundant and relatively verbose.