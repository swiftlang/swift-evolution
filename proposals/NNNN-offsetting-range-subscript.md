# Offsetting Range Subscript

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Letanyan Arumugam](https://github.com/Letanyan)
* Review Manager: TBD
* Status: **Implementation Ready**

* Implementation: [apple/swift#14389](https://github.com/apple/swift/pull/14389)

## Introduction
A collection that has an `Index` type that cannot be offset independently of its
collection can cause overly verbose code that obfuscates one's intent. To help 
improve this, we propose adding a `subscript(offset:)` method to `Collection` and
`RangeReplaceableCollection` that would accept an offsetting range. We will also
add `subscript(offset:)` methods to `Collection` and `MutableCollection` that
only take a single `Int` offset as an argument.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/shorthand-for-offsetting-startindex-and-endindex/9397)

## Motivation
Working with an index that cannot be offset independently, without the corresponding collection, causes the intent of code to get lost in an overly 
verbose call site.

Currently to get a slice of a `String`, not anchored at the start or end of
the collection, one might use the following subscript:
```
let s = "Hello, Swift!"
let subject = s[s.index(s.startIndex, offsetBy: 7)...s.index(s.startIndex, offsetBy: 11)]
```
This approach, unfortunately, suffers from redundancy and is in general unwieldy 
to handle. 

A shorter approach, which is also available, is to use combinations of `prefix`, 
`suffix` and the `drop` variants. A solution using these would follow like such:
```
let subject = s.suffix(6).prefix(5)
```
While this is much shorter, it suffers from multiple drawbacks. It is not as
natural as using a range, which increases the cognitive load for a user. This 
solution also suffers from API discoverability issues, since a user must learn 
multiple methods and figure out that they can be composed in this way. 

## Proposed solution
A solution we propose to this problem is to extend `Collection` and 
`RangeReplaceableCollection` with a subscript that takes a range, which 
would be used to offset the starting index of a collection.
`Collection` and `MutableCollection` will receive subscripts that take a
single `Int` to return a single element from the collection.

A highly request ability for getting a slice of a collection was the ability to
offset relative to the `endIndex` of a collection. Currently range supported can
cover most of the desired requests, however, due to ranges requiring an 
upperBound >= lowerBound constraint certain use cases fall short. To solve this
Four new operators should be added along with a new type to help model this 
behavior. To encapsulate this behavior, a new protocol should also be added.
The other range types will then also conditionally conform to this protocol. 

```
prefix operator ...-
prefix operator ..<-
infix operator ...- : RangeFormationPrecedence
infix operator ..<- : RangeFormationPrecedence

struct RelativeOffsetRange {
  var lowerBound: Int
  var upperBound: Int?
}

protocol RangeOffsetRangeExpression {
  func relativeOffsetRange() -> RelativeOffsetRange
}
```

## Detailed design
A new protocol Should be added:
```
/// A type that can be used to get a slice of a collection relative to the
/// collections start and end indices.
public protocol RelativeOffsetRangeExpression {
  /// A type that represents an offset range to slice a collection relatively.
  func relativeOffsetRange() -> RelativeOffsetRange
}
```
A new type to represent a range offset:
```
/// Returns a relative offset range that represents a slice of a collection
/// given two offset values relative to the collections start and/or end 
/// indices.
///
/// You can use the RelativeOffsetRange to represent a slice of a collection 
/// relative with offset values relative the collections start/end indices.
/// If the offset value is greater or equal to 0 it will be relative to the 
/// `startIndex`, else it will be relative to the `endIndex`. For example:
///
///     let exceptLastFour = ..<(-4)
///
///     let r1 = exceptLastFour.relativeAsOffset()
///     // r1 == 0..<-4
///
/// The `r1` range is bounded on the lower end by `0` because that is the
/// offset that does not change `startIndex`. In the next example we'll see
/// how a partial range from works:
///
///     let greeting = "Hello, Swift!"
///     let greeting = numbers[offset: (-6)...]
///     // greeting == "Swift!"
///
/// Use this method only if you need a range that will be used to slice a 
/// `collection` with offsets relative to the start and/or end indices. To
/// access a relative offset slice of a collection using a relative range 
/// offset expression, use the collection's generic subscript that uses a 
/// relative offset range expression as its parameter.
///
///     let numbersPrefix = numbers[offset: upToFour]
///     // numbersPrefix == [10, 20, 30, 40]
///
/// - Returns: An offset range suitable for slicing `collection` as an offset. 
///   The returned range is *not* guaranteed to be inside the bounds of 
///   `collection`. Callers should apply the same preconditions to the return 
///   value as they would to a range provided directly by the user.
public struct RelativeOffsetRange : RelativeOffsetRangeExpression {
  /// The lower base of the range
  public let lowerBound: Int
  /// The upper base of the range. If `nil` upperBound represents the endIndex.
  public let upperBound: Int?
  
  public func relative<C: Collection>(to c: C) -> Range<Int>
  where C.Index == Int {
    ...
  }
  
  public func relativeOffsetRange() -> RelativeOffsetRange {
    ...
  }
}
```

Other ranges should also conform to RelativeOffsetRangeExpression:
```
extension Range : RelativeOffsetRangeExpression where Bound == Int {
  ...
}
extension ClosedRange : RelativeOffsetRangeExpression where Bound == Int {
  ...
}
extension PartialRangeFrom : RelativeOffsetRangeExpression where Bound == Int {
  ...
}
extension PartialRangeUpTo : RelativeOffsetRangeExpression where Bound == Int {
  ...
}
extension PartialRangeThrough : RelativeOffsetRangeExpression 
where Bound == Int {
  ...
}
```

Add subscripts to `Collection`:
```
extension Collection {
  /// Accesses a contiguous subrange of the collection's elements with a range
  /// that has offsets relative to the start and/or end indices.
  ///
  /// The accessed slice uses the same indices for the same elements as the
  /// original collection uses. Always use the slice's `startIndex` property
  /// instead of assuming that its indices start at a particular value.
  ///
  ///
  /// - Parameter offset: A range of values that will offset the collections 
  ///   starting index to form a new range of indices relative to the 
  ///   collection.
  public subscript<R: RelativeOffsetRangeExpression>(
    offset offset: R
  ) -> SubSequence {
      ...
  }

  /// Accesses an element of the collection at a particular offset. Either from
  /// the start or end of the collection. Where a negative offset would imply
  /// from the end and a positive offset would imply an offset from the start.
  public subscript(offset offset: Int) -> Element {
    ...
  }
}
```

Add a subscript to `MutableCollection`:
```
extension MutableCollection {
  /// Accesses an element of the collection at a particular offset. Either from
  /// the start or end of the collection. Where a negative offset would imply
  /// from the end and a positive offset would imply an offset from the start.
  public subscript(offset offset: Int) -> Element { get set }
}
```

Add a subscript to `RangeReplaceableCollection`:
```
extension RangeReplaceableCollection {
  /// Accesses a contiguous subrange of the collection's elements with a range
  /// that has offsets relative to the start and/or end indices.
  ///
  /// The accessed slice uses the same indices for the same elements as the
  /// original collection uses. Always use the slice's `startIndex` property
  /// instead of assuming that its indices start at a particular value.
  ///
  ///
  /// - Parameter offset: A range of values that will offset the collections 
  ///   starting index to form a new range of indices relative to the 
  ///   collection.
  public subscript<R: RelativeOffsetRangeExpression>(
    offset offset: R
  ) -> SubSequence { get set }
}
```

Implement range operators:
```
public func ...-(lhs: Int, rhs: Int) -> RelativeOffsetRange {
  ...
}

public func ..<-(lhs: Int, rhs: Int) -> RelativeOffsetRange {
  ...
}

public prefix func ...-(bound: Int) -> RelativeOffsetRange {
  ...
}

public prefix func ..<-(bound: Int) -> RelativeOffsetRange {
  ...
}
```

## Source compatibility
None

## Effect on ABI stability
N/A

## Effect on API resilience
N/A

## Alternatives considered

### Custom IndexOffset Enum Type
We could add a new enum to the Standard Library (stdlib), `IndexOffset`.
```
enum IndexOffset {
  case start(Int)
  case end(Int)
}

extension IndexOffset : Comparable {
  public static func <(lhs: IndexOffset, rhs: IndexOffset) -> Bool {
    switch (lhs, rhs) {
    case (.start, .end): 
      return true
    case let (.start(a), .start(b)): 
      return a < b
    case (.end, .start): 
      return false
    case let (.end(a), .end(b)): 
      return a < b
    }
  }
}
```
With these semantics one can do the following:
```
let s = "Hello, Swift!"
let y = s[offset: .start(7) ... .end(-2)]
```
This will leave `y` with the value `"Swift"`. 

This solution, unfortunately, has to wrap all offsets in an enum case, which,
causes friction when working with operators.

### Do not add new operators and a new type
This will remove a highly desired ability but is cleaner in that 
range semantics do not have any effect on them.

### Revive SE-0137
A suggestion was made that reviving [SE-0137](https://github.com/apple/swift-evolution/blob/master/proposals/0132-sequence-end-ops.md)
would address this issue. While this would be worthwhile for other reasons, this
solution would still suffer from API discovery issues and cognitive load, as
addressed in the [motivation section](##-Motivation).

### Use a Method Instead
Some were concerned about using a subscript and hiding non-constant time
complexity. While some may have an idea that subscript access is done in 
constant time, this is not necessarily true.

### Use Something Other than a Range
Using a tuple would allow us to bypass the restrictions of ranges and allow a
positive lowerBound and negative upperBound. This will cause a loss of the 
ability for a user to chose inclusivity.

### Add Methods to Offset startIndex and/or endIndex
Adding convenience methods to offset `startIndex` and `endIndex` would help make
intent more obvious. The following is an illustration of what this might look 
like:
```
let subject = s[s.startIndex(offsetBy: 7)...s.endIndex(offsetBy: -2)]
```

### Only Add a Method to Offset startIndex 
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

### Add an Intermediate between an Index and its Offsetting
We could introduce a new type that would capture the idea of offsetting an index
with a distance. This would then be passed to a collection to compute
the new index. An example will look like the following:

```
let x = [10, 20, 30, 40, 50, 60]
x[offset: (x.startIndex + 2) ..< (x.startIndex + 4)]
```
Any solution such as this will lose type info of the index. This means one 
cannot write the following without an explicit type declaration.
```
let i = x.startIndex + 3
```
This would be surprising to many people and lead them to make the full call in 
the subscript.

`KeyPath`'s can be used instead of raw indices. However, this means people are 
required to learn about `KeyPath`'s to use this feature.

### Only included a new half-open offset range
This lacks any inclusivity options. And no obvious operator set could be found
that makes sense and does not conflict with the current range operators.

### Rename Subscripts Offset Label
A suggestion to rename the `offset` label in the subscript to `ordinal` was 
suggested. The idea behind the name offset is apt as it is the exact operation
that is being done.
