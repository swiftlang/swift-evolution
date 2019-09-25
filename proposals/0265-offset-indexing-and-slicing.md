# Offset-Based Access to Indices, Elements, and Slices

* Proposal: SE-0265
* Author: [Michael Ilseman](https://github.com/milseman)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Awaiting review (October 7th – October 21st, 2019)**
* Implementation: [apple/swift#24296](https://github.com/apple/swift/pull/24296)

## Introduction

This proposal introduces `OffsetBound`, which can represent a position in a collection specified as an offset from either the beginning or end of the collection (i.e. the collection’s “bounds”). Corresponding APIs provide a more convenient abstraction over indices. The goal is to alleviate an expressivity gap in collection APIs by providing easy and safe means to access elements, indices, and slices from such offsets.

If you would like to try it out, you can just copy-paste from [this gist](https://gist.github.com/milseman/1461e4f3e195974a5d1ad76cefdd6961), which includes the functionality as well as test cases and examples. This work is the culmination of prior discussion from an [earlier thread](https://forums.swift.org/t/pitch-offsetting-indices-and-relative-ranges/23837),  the [thread before that](https://forums.swift.org/t/call-for-users-and-authors-offset-indexing-pitch/21444), and [@Letan](https://forums.swift.org/u/letan) ’s  [original thread](https://forums.swift.org/t/shorthand-for-offsetting-startindex-and-endindex/9397). The latest pitch thread can be found [here](https://forums.swift.org/t/offset-indexing-and-slicing/28333).


## Motivation

### Easily and Safely Getting Indices, Elements, and Slices from Offsets

`Collection`’s current index manipulation methods are meant to represent the lowest level programming interface, and as such they impose requirements on their use which are important for performance. Violations of these requirements are treated as irrecoverable logic errors, trapping whenever they lead to a potential memory safety issue. But, `Collection` lacks higher-level APIs that allow the programmer to treat such violations as recoverable domain errors. This proposal addresses the gap.

Extracting elements and slices from offsets into a collection is an onerous task, requiring manually advancing indices. This proposal offers an ergonomic approach to offsetting from the start or end of collections, including their slices.

This commonly comes up with casual `String` usage, and aligns with the [String Essentials](https://forums.swift.org/t/string-essentials/21909) effort.

For a simple example taken from [Advent of Code 2018 Day 7](https://adventofcode.com/2018/day/7) , we want a function taking a string where each line is of the form `Step C must be finished before step A can begin.` , and returns an array representing the requirement `(finish: "C", before: "A")`.

```swift
func parseRequirements(_ s: String) -> [(finish: Character, before: Character)] {
  s.split(separator: "\n").map { line in
    let finishIdx = line.index(line.startIndex, offsetBy: 5) // 5 after first
    let beforeIdx = line.index(line.endIndex, offsetBy: -12) // 11 before last
    return (line[finishIdx], line[beforeIdx])
  }
}
```

Advancing indices by hand through `line.index(line.startIndex, offsetBy: 5)` is fairly obnoxious and distracts from the intent of the code.

Alternatively, we could take a detour through forming `SubSequence`s:

```swift
func parseRequirements(_ s: String) -> [(finish: Character, before: Character)] {
  s.split(separator: "\n").map { line in
    (line.dropFirst(5).first!, line.dropLast(11).last!)
  }
}
```

This results in less boilerplate code, but the detour through slicing APIs increases the cognitive load. Anyone reading the code has to jump through mental hoops, and the code author has more details to reason through (when we first wrote this example, we had an off-by-one error).

Instead, this proposal provides a way to directly extract elements from known offsets.


### Common Bugs and Assumptions in Int-Indexed Collections

When a collection’s index type happens to be `Int`, it’s a common mistake to assume that such indices start from zero. For an example from [this forum post](https://forums.swift.org/t/subscripting-a-range-seems-unintuitive/23278), an `Int` range’s indices are the very elements themselves; they don’t start at zero.

```swift
print((3..<10)[5...]) // 5..<10
```

Slices share the same indices with the base collection. Assuming indices start from zero can be especially pernicious in generic code and when working with self-sliced types such as `Data`.

```swift
func fifth<C: Collection>(_ c: C) -> C.Element? where C.Index == Int {
  return c.count >= 5 ?? c[4] : nil
}

let array = [1,2,3,4,5,6,7,8,9]
print(fifth(array)!) // 5
print(fifth(array[2...])!) // still `5`, but `7` would be the real fifth item

func fifth(_ data: Data) -> UInt8? {
  return data.count >= 5 ?? data[4] : nil
}

var data = Data([1, 2, 3, 4, 5, 6, 7, 8, 9])
print(fifth(data)!) // 5

data = data.dropFirst(2)
print(fifth(data)!) // still `5`, but `7` is the real fifth item
```

Common advice when working with `Data` is to index by adding to the start index, as in `data[data.startIndex + 4]`. However, even this approach is not valid in a generic context (even for random access collections). Fetching an index and then performing integer arithmetic is different than advancing a position:

```swift
struct EveryOther<C: RandomAccessCollection>: RandomAccessCollection {
  internal var storage: C

  var startIndex: C.Index { storage.startIndex }
  var endIndex: C.Index {
    if storage.count % 2 == 0 { return storage.endIndex }
    return storage.index(before: storage.endIndex)
  }

  subscript(position: C.Index) -> C.Element { storage[position] }

  func index(before i: C.Index) -> C.Index { storage.index(i, offsetBy: -2) }
  func index(after i: C.Index) -> C.Index { storage.index(i, offsetBy: 2) }
  // ... and override `distance`, `index(_:offsetBy:)` for performance ...
}

let everyOther = EveryOther(storage: [1,2,3,4,5,6,7,8])
print(everyOther.contains(2)) // false
print(everyOther.contains(3)) // true

let startIdx = everyOther.startIndex
print(everyOther[startIdx + 1]) // 2, but everyOther doesn't even contain 2!
print(everyOther[everyOther.index(after: startIdx)]) // 3
```

This proposal provides a way to have offset-based element access for such collections, with similar expressivity but with explicit bounds for clarity.


## Proposed solution

We propose convenient subscripts for slicing, single-element retrieval, and fetching an index from an offset:

```swift
let str = "abcdefghijklmnopqrstuvwxyz"
print(str[.first + 3 ..< .first + 6]) // "def"
print(str[.first + 3 ..< .last - 2]) // "defghijklmnopqrstuvw"
print(str[.first + 3 ..< .last - 22]) // "",
print(str[.last]) // Optional("z")
print(str[.last - 1]) // Optional("y")
print(str[.first + 26]) // nil
print(str[(.last - 3)...]) // "wxyz"

print(str.index(at: .last - 1)) // Optional(... index of "y")
print(str.index(at: .last - 25)) // Optional(... index of "a")
print(str.index(at: .last - 26)) // nil
```

The `parseRequirements` example from above can be written as:

```swift
func parseRequirements(_ s: String) -> [(finish: Character, before: Character)] {
  s.split(separator: "\n").map { line in
    (line[.first + 5]!, line[.last - 11]!)
  }
}
```

These APIs are available on all Collections, allowing a more general solution. The Advent of Code exercise only requires the extraction and comparison of the elements at the corresponding positions, so we can generalize to:

```swift
func parseRequirements<C: Collection>(
  _ c: C, lineSeparator: C.Element
) -> [(finish: C.Element, before: C.Element)] where C.Element: Comparable {
  c.split(separator: lineSeparator).map { line in
    (line[.first + 5]!, line[.last - 11]!)
  }
}
```

Here, the `line[.last - 11]` will run in constant-time if `c` conforms to `BidirectionalCollection`, or in linear-time if it does not (since we have to count from the front). This algorithmic guarantee is added as part of this proposal, without which this generalization cannot be done.

These also address the expressivity issues and assumptions with Int-indexed Collections above:

```swift
print((3..<10)[(.first + 5)...]) // 8..<10

func fifth<C: Collection>(_ c: C) -> C.Element? { return c[.first + 4] }

let array = [1,2,3,4,5,6,7,8,9]
print(fifth(array)!) // 5
print(fifth(array[2...])!) // 7

var data = Data([1, 2, 3, 4, 5, 6, 7, 8, 9])
print(fifth(data)!) // 5
data = data.dropFirst(2)
print(fifth(data)!) // 7

let everyOther = EveryOther(storage: [1,2,3,4,5,6,7,8])
print(everyOther[.first + 1]!) // 3
```



## Detailed design

This proposal adds an `OffsetBound` struct, representing a position at an offset from the start or end of a collection.

```swift
/// A position in a collection specified as an offset from either the first
/// or last element of the collection (i.e. the collection's bounds).
///
/// You can use an `OffsetBound` to access an index or element of a collection
/// as well as extract a slice. For example:
///
///       let str = "abcdefghijklmnopqrstuvwxyz"
///       print(str[.last]) // Optional("z")
///       print(str[.last - 2]) // Optional("x")
///       print(str[.first + 26]) // nil
///       print(str[.first + 3 ..< .first + 6]) // "def"
///       print(str[.first + 3 ..< .last - 2]) // "defghijklmnopqrstuvw"
///
/// `OffsetBound`s also provide a convenient way of working with slice types
/// over collections whose index type is `Int`. Slice types share indices with
/// their base collection, so `0` doesn't always mean the first element. For
/// example:
///
///     let array = [1,2,3,4,5,6]
///     print(array[2...][3) // 4
///     print(array[2...][.first + 3]!) // 6
///
public struct OffsetBound {
  /* internally stores an enum, not ABI/API */

  /// The position of the first element of a nonempty collection, corresponding
  /// to `startIndex`.
  public static var first: OffsetBound

  /// The position of the last element of a nonempty collection, corresponding
  /// to `index(before: endIndex)`.
  public static var last: OffsetBound

  /// Returns a bound that offsets the given bound by the specified distance.
  ///
  /// For example:
  ///
  ///     .first + 2  // The position of the 3rd element
  ///     .last + 1   // One past the last element, corresponding to `endIndex`
  ///
  public static func +(_ lhs: OffsetBound, _ rhs: Int) -> OffsetBound

  /// Returns a bound that offsets the given bound by the specified distance
  /// backwards.
  ///
  /// For example:
  ///
  ///     .last - 2 // Two positions before the last element's position
  ///
  public static func -(_ lhs: OffsetBound, _ rhs: Int) -> OffsetBound
}
```


`OffsetBound` is `Comparable`, and as such can be used as a bound type for `RangeExpression`s.

```swift
extension OffsetBound: Comparable {
  /// Compare the positions represented by two `OffsetBound`s.
  ///
  /// Offsets relative to `.first` are always less than those relative to
  /// `.last`, as there are arbitrarily many offsets between the two
  /// extremities. Offsets from the same bound are ordered by their
  /// corresponding positions. For example:
  ///
  ///     .first + n < .last - m    // true for all values of n and m
  ///     .first + n < .first + m  // equivalent to n < m
  ///     .last - n < .last - m      // equivalent to n > m
  ///
  public static func < (_ lhs: OffsetBound, _ rhs: OffsetBound) -> Bool

  /// Compare two `OffsetBound`s to see if they represent equivalent positions.
  ///
  /// This is only true if both offset the same bound by the same amount. For
  /// example:
  ///
  ///     .first + n == .last - m    // false for all values of n and m
  ///     .first + n == .first + m  // equivalent to n == m
  ///
  public static func == (_ lhs: OffsetBound, _ rhs: OffsetBound) -> Bool
}
```


`Collection` gets an API to retrieve an index from an `OffsetBound` if it exists, a subscript to retrieve an element from an `OffsetBound` if it exists, and a slicing subscript to extract a range.

```swift
extension Collection {
  /// Returns the corresponding index for the provided offset, if it exists,
  /// else returns nil.
  ///
  /// - Complexity:
  ///   - O(1) if the collection conforms to `RandomAccessCollection`.
  ///   - O(*k*) where *k* is equal to the offset if the collection conforms to
  ///     `BidirectionalCollection`.
  ///   - O(*k*) if `position` is `.first + n` for any n, or `.last + 1`.
  ///   - Otherwise, O(*n*) where *n* is the length of the collection.
  public func index(at position: OffsetBound) -> Index?

  /// Returns the corresponding element for the provided offset, if it exists,
  /// else returns nil.
  ///
  /// Example:
  ///
  ///       let abcs = "abcdefg"
  ///       print(abcs[.last]) // Optional("g")
  ///       print(abcs[.last - 2]) // Optional("e")
  ///       print(abcs[.first + 8]) // nil
  ///
  /// - Complexity:
  ///   - O(1) if the collection conforms to `RandomAccessCollection`.
  ///   - O(*k*) where *k* is equal to the offset if the collection conforms to
  ///     `BidirectionalCollection`.
  ///   - O(*k*) if `position` is `.first + n` for any n, or `.last + 1`.
  ///   - Otherwise, O(*n*) where *n* is the length of the collection.
  public subscript(position: OffsetBound) -> Element?

  /// Returns the contiguous subrange of elements corresponding to the provided
  /// offsets.
  ///
  /// Example:
  ///
  ///       let abcs = "abcdefg"
  ///       print(abcs[.first + 1 ..< .first + 6]) // "bcdef"
  ///       print(abcs[.first + 1 ..< .last - 1]) // "bcde"
  ///
  /// - Complexity:
  ///   - O(1) if the collection conforms to `RandomAccessCollection`.
  ///   - O(*k*) where *k* is equal to the larger offset if the collection
  ///     conforms to `BidirectionalCollection`.
  ///   - O(*k*) if the offsets are `.first + n` for any n or `.last + 1`.
  ///   - Otherwise, O(*n*) where *n* is the length of the collection.
  public subscript<ORE: RangeExpression>(
    range: ORE
  ) -> SubSequence where ORE.Bound == OffsetBound
}
```


RangeReplaceableCollection gets corresponding APIs in terms of OffsetBound, as well as subscript setters.

```swift
extension RangeReplaceableCollection {
  /// Replaces the specified subrange of elements with the given collection.
  ///
  /// This method has the effect of removing the specified range of elements
  /// from the collection and inserting the new elements at the same location.
  /// The number of new elements need not match the number of elements being
  /// removed.
  ///
  /// In this example, two characters in the middle of a string are
  /// replaced by the three elements of a `Repeated<Character>` instance.
  ///
  ///      var animals = "🐕🐈🐱🐩"
  ///      let dogFaces = repeatElement("🐶" as Character, count: 3)
  ///      animals.replaceSubrange(.first + 1 ... .last - 1, with: dogFaces)
  ///      print(animals)
  ///      // Prints "🐕🐶🐶🐶🐩"
  ///
  /// If you pass a zero-length range as the `subrange` parameter, this method
  /// inserts the elements of `newElements` at `subrange.startIndex`. Calling
  /// the `insert(contentsOf:at:)` method instead is preferred.
  ///
  /// Likewise, if you pass a zero-length collection as the `newElements`
  /// parameter, this method removes the elements in the given subrange
  /// without replacement. Calling the `removeSubrange(_:)` method instead is
  /// preferred.
  ///
  /// Calling this method may invalidate any existing indices for use with this
  /// collection.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the collection to replace, specified as
  ///   offsets from the collection's bounds.
  ///   - newElements: The new elements to add to the collection.
  ///
  /// - Complexity: O(*n* + *m*), where *n* is length of this collection and
  ///   *m* is the length of `newElements`. If the call to this method simply
  ///   appends the contents of `newElements` to the collection, the complexity
  ///   is O(*m*).
  public mutating func replaceSubrange<C: Collection, R: RangeExpression>(
    _ subrange: R, with newElements: __owned C
  ) where C.Element == Element, R.Bound == OffsetBound

  /// Inserts a new element into the collection at the specified position.
  ///
  /// The new element is inserted before the element currently at the specified
  /// offset. If you pass `.last + 1` as the `position` parameter, corresponding
  /// to the collection's `endIndex`, the new element is appended to the
  /// collection.
  ///
  ///     var numbers = "12345"
  ///     numbers.insert("Ⅸ", at: .first + 1)
  ///     numbers.insert("𐄕", at: .last + 1)
  ///
  ///     print(numbers)
  ///     // Prints "1Ⅸ2345𐄕"
  ///
  /// Calling this method may invalidate any existing indices for use with this
  /// collection.
  ///
  /// - Parameter newElement: The new element to insert into the collection.
  /// - Parameter `position`: The position at which to insert the new element,
  ///   specified as offsets from the collection's bounds
  ///
  /// - Complexity: O(*n*), where *n* is the length of the collection. If
  ///   `position == .last + 1`, this method is equivalent to `append(_:)`.
  public mutating func insert(
    _ newElement: __owned Element, at position: OffsetBound
  )

  /// Inserts the elements of a sequence into the collection at the specified
  /// position.
  ///
  /// The new elements are inserted before the element currently at the
  /// specified offset. If you pass `.last + 1` as the `position` parameter,
  /// corresponding to the collection's `endIndex`, the new elements are
  /// appended to the collection.
  ///
  /// Here's an example of inserting vulgar fractions in a string of numbers.
  ///
  ///     var numbers = "12345"
  ///     numbers.insert(contentsOf: "↉⅖⅑", at: .first + 2)
  ///     print(numbers)
  ///     // Prints "12↉⅖⅑345"
  ///
  /// Calling this method may invalidate any existing indices for use with this
  /// collection.
  ///
  /// - Parameter newElements: The new elements to insert into the collection.
  /// - Parameter `position`: The position at which to insert the new elements,
  ///   specified as offsets from the collection's bounds
  ///
  /// - Complexity: O(*n* + *m*), where *n* is length of this collection and
  ///   *m* is the length of `newElements`. If `position == .last + 1`, this
  ///   method is equivalent to `append(contentsOf:)`.
  public mutating func insert<S: Collection>(
    contentsOf newElements: __owned S, at position: OffsetBound
  ) where S.Element == Element

  /// Removes and returns the element at the specified position, if it exists,
  /// else returns nil.
  ///
  /// All the elements following the specified position are moved to close the
  /// gap.
  ///
  /// Example:
  ///     var measurements = [1.2, 1.5, 2.9, 1.2, 1.6]
  ///     let removed = measurements.remove(at: .last - 2)
  ///     print(measurements)
  ///     // Prints "[1.2, 1.5, 1.2, 1.6]"
  ///     print(measurements.remove(at: .first + 4))
  ///     // Prints nil
  ///
  /// Calling this method may invalidate any existing indices for use with this
  /// collection.
  ///
  /// - Parameter position: The position of the element to remove, specified as
  ///   an offset from the collection's bounds.
  /// - Returns: The removed element if it exists, else nil
  ///
  /// - Complexity: O(*n*), where *n* is the length of the collection.
  public mutating func remove(at position: OffsetBound) -> Element?

  /// Removes the elements in the specified subrange from the collection.
  ///
  /// All the elements following the specified position are moved to close the
  /// gap. This example removes two elements from the middle of a string of
  /// rulers.
  ///
  ///     var rulers = "📏🤴👑📐"
  ///     rulers.removeSubrange(.first + 1 ... .last - 1)
  ///     print(rulers)
  ///     // Prints "📏📐"
  ///
  /// Calling this method may invalidate any existing indices for use with this
  /// collection.
  ///
  /// - Parameter range: The range of the collection to be removed, specified
  ///   as offsets from the collection's bounds.
  ///
  /// - Complexity: O(*n*), where *n* is the length of the collection.
  public mutating func removeSubrange<R: RangeExpression>(
    _ range: R
  ) where R.Bound == OffsetBound

  /// Accesses the element corresponding to the provided offset. If no element
  /// exists, `nil` is returned from the getter. Similarly, setting an element
  /// to `nil` will remove the element at that offset.
  ///
  /// Example:
  ///
  ///       let abcs = "abcdefg"
  ///       print(abcs[.last]) // Optional("g")
  ///       print(abcs[.last - 2]) // Optional("e")
  ///       print(abcs[.first + 8]) // nil
  ///       abcs[.first + 2] = "©"
  ///       print(abcs) // "ab©defg"
  ///       abcs[.last - 1] = nil
  ///       print(abcs) // "ab©deg"
  ///
  /// - Complexity (get):
  ///   - O(1) if the collection conforms to `RandomAccessCollection`.
  ///   - O(*k*) where *k* is equal to the offset if the collection conforms to
  ///     `BidirectionalCollection`.
  ///   - O(*k*) if `position` is `.first + n` for any n, or `.last + 1`.
  ///   - Otherwise, O(*n*) where *n* is the length of the collection.
  ///
  /// - Complexity (set):
  ///   - O(*n*) where *n* is the length of the collection.
  public subscript(position: OffsetBound) -> Element? { get set }

  /// Accesses the contiguous subrange of elements corresponding to the provided
  /// offsets.
  ///
  /// Example:
  ///
  ///       var abcs = "abcdefg"
  ///       print(abcs[.first + 1 ..< .first + 6]) // "bcdef"
  ///       print(abcs[.first + 1 ..< .last - 1]) // "bcde"
  ///       abcs[.first ... .first + 3] = "🔡"
  ///       print(abcs) // "🔡efg"
  ///
  /// - Complexity (get):
  ///   - O(1) if the collection conforms to `RandomAccessCollection`.
  ///   - O(*k*) where *k* is equal to the larger offset if the collection
  ///     conforms to `BidirectionalCollection`.
  ///   - O(*k*) if the offsets are `.first + n` for any n or `.last + 1`.
  ///   - Otherwise, O(*n*) where *n* is the length of the collection.
  ///
  /// - Complexity (set):
  ///   - O(*n*) where *n* is the length of the collection.
  public subscript<ORE: RangeExpression>(
    range: ORE
  ) -> SubSequence where ORE.Bound == OffsetBound { get set }
```


This proposal adds a new “internal” (i.e. underscored) customization hook to `Collection` to apply a reverse offset to a given index. Unlike `index(_:offsetBy:limitedBy:)` which will trap if the collection is not bidirectional, this will instead advance `startIndex`.

```swift
public protocol Collection: Sequence {
  /// Returns an index `distance` positions prior to `i` if it exists.
  ///
  /// Other methods such as `index(_:offetBy:)` must not be passed a negative
  /// offset if the collection is bidirectional. This method will perform a
  /// negative offset even if the collection is not bidirectional, by using a
  /// less efficient means. `BidirectionalCollection` customizes this with a
  /// more efficient implementation.
  ///
  /// - Parameters
  ///   - i: a valid index of the collection.
  ///   - distance: The distance to offset `i` backwards. `distance` must be
  ///     positive or zero.
  /// - Returns: The index `distance` positions prior to `i` if in bounds, else
  ///   `nil`.
  ///
  /// - Complexity:
  ///   - O(1) if the collection conforms to `RandomAccessCollection`.
  ///   - O(*k*), where *k* is equal to `distance` if the collection conforms
  ///     to `BidirectionalCollection`.
  ///   - Otherwise, O(*n*), where *n* is the length of the collection.
  func _reverseOffsetIndex(_ i: Index, by distance: Int) -> Index?
}

extension Collection {
  // Scans from the start
  public func _reverseOffsetIndex(_ i: Index, by distance: Int) -> Index?
}
extension BidirectionalCollection {
  // Reverse offsets
  public func _reverseOffsetIndex(_ i: Index, by distance: Int) -> Index?
}
```


Change `Collection.suffix()` and `Collection.dropLast()` to use this hook, which will improve algorithmic complexity in generic code when the collection happens to be bidirectional.
 
```diff
extension Collection {
   /// Returns a subsequence containing all but the specified number of final
   /// elements.
   ///
   /// If the number of elements to drop exceeds the number of elements in the
   /// collection, the result is an empty subsequence.
   ///
   ///     let numbers = [1, 2, 3, 4, 5]
   ///     print(numbers.dropLast(2))
   ///     // Prints "[1, 2, 3]"
   ///     print(numbers.dropLast(10))
   ///     // Prints "[]"
   ///
   /// - Parameter k: The number of elements to drop off the end of the
   ///   collection. `k` must be greater than or equal to zero.
   /// - Returns: A subsequence that leaves off the specified number of elements
   ///   at the end.
   ///
-  /// - Complexity: O(1) if the collection conforms to
-  ///   `RandomAccessCollection`; otherwise, O(*n*), where *n* is the length of
-  ///   the collection.
+  /// - Complexity:
+  ///   - O(1) if the collection conforms to `RandomAccessCollection`.
+  ///   - O(*k*), where *k* is equal to `distance` if the collection conforms
+  ///     to `BidirectionalCollection`.
+  ///   - Otherwise, O(*n*), where *n* is the length of the collection.
   @inlinable
   public __consuming func dropLast(_ k: Int = 1) -> SubSequence

   /// Returns a subsequence, up to the given maximum length, containing the
   /// final elements of the collection.
   ///
   /// If the maximum length exceeds the number of elements in the collection,
   /// the result contains all the elements in the collection.
   ///
   ///     let numbers = [1, 2, 3, 4, 5]
   ///     print(numbers.suffix(2))
   ///     // Prints "[4, 5]"
   ///     print(numbers.suffix(10))
   ///     // Prints "[1, 2, 3, 4, 5]"
   ///
   /// - Parameter maxLength: The maximum number of elements to return. The
   ///   value of `maxLength` must be greater than or equal to zero.
   /// - Returns: A subsequence terminating at the end of the collection with at
   ///   most `maxLength` elements.
   ///
-  /// - Complexity: O(1) if the collection conforms to
-  ///   `RandomAccessCollection`; otherwise, O(*n*), where *n* is the length of
-  ///   the collection.
+  /// - Complexity:
+  ///   - O(1) if the collection conforms to `RandomAccessCollection`.
+  ///   - O(*k*), where *k* is equal to `maxLength` if the collection conforms
+  ///     to `BidirectionalCollection`.
+  ///   - Otherwise, O(*n*), where *n* is the length of the collection.
   @inlinable
   public __consuming func suffix(_ maxLength: Int) -> SubSequence
}
```

Finally, `BidirectionalCollection`’s overloads are obsoleted in new versions as they are fully redundant with `Collection`’s.

## Source compatibility

This change preserves source compatibility.

## Effect on ABI stability

This does not change any existing ABI.

## Effect on API resilience

All additions are versioned. The `_reverseOffsetIndex` customization hook is `@inlinable`, while all other added ABI are fully resilient.

## Alternatives considered

### Add a `.start` and `.end`

The previous version of this pitch also had a `.start` and `.end`, where `.start == .first && .end == .last + 1`. Having `.end` made it easier to refer to an open upper bound corresponding to the collection’s `endIndex`, which mostly manifests in documentation. However, in actual usage, `.first` and `.last` are almost always clearer.

We chose to eschew `.start` and `.end` members, simplifying the programming model and further distinguishing `OffsetBound` as an element-position abstraction more akin to working with `Collection.first/last` than `Collection.startIndex/endIndex`.


### Don’t add the customization hook

An alternative to the customization hook is adding overloads to both `Collection` and `BidirectionalCollection` for every API. This would result in slower code in a generic context over `Collection` even if that collection happened to also conform to `BidirectionalCollection`, as this is statically dispatched. Since this is a frequent enough access pattern in the standard library, we feel a customization hook to share and accelerate the functionality is warranted.

This proposal adapts Collection’s `suffix` and `dropLast` to use the new hook, improving their performance as well.


### Offset Arbitrary Indices

More general than offsetting from the beginning or end of a Collection is offsetting from a given index. Relative indices, that is indices with offsets applied to them, could be expressed in a `RelativeBound<Bound>` struct, where `Bound` is the index type of the collection it will be applied to (phantom-typed for pure-offset forms). The prior pitch proposed this feature alongside the `++`/`--` operators, but doing this presents problems in `RangeExpression` conformance as well as type-checker issues with generic operator overloading.

These issues can be worked around (as shown below), but each workaround comes with its own drawbacks. All in all, offsetting from an arbitrary index isn’t worth the tradeoffs and can be mimicked with slicing (albeit with more code).

#### The Trouble with Generic Operator Overloading

Overloading an operator for a type with a generic parameter complicates type checking for that operator. The type checker has to open a type variable and associated constraints for that parameter, preventing the constraint system from being split. This increases the complexity of type checking *all* expressions involving that operator, not just those using the overload.

This increased complexity may be tolerable for a brand new operator, such as the previously pitched `++` and `--`, but it is a downside of overloading an existing-but-narrowly-extended operator such as `..<` and `...`. It is a total non-starter for operators such as `+` and `-`, which already have complex resolution spaces.

#### The Trouble with RangeExpression

`RangeExpression` requires the ability to answer whether a range contains a bound, where `Bound` is constrained to be `Comparable`. Pure-offset ranges can answer this similarly to other partial ranges by putting the partial space between `.first` and `.last`.

Unlike pure-offset ranges, containment cannot be consistently answered for a range of relative indices without access to the original collection. Similarly, `RelativeBound<Bound>` cannot be comparable.

A workaround could be to introduce a new protocol `IndexRangeExpression` without these requirements and add new overloads for it. Some day in the future when the compiler supports it, `RangeExpression` can conform to it and the existing `RangeExpression` overloads would be deprecated.

This would also require a new `RelativeRange` type and new generic overloads for range operators `..<` and `...` producing it. This is a hefty amount of additional machinery and would complicate type checking of all ranges, as explained next.


### Other Syntax

#### `idx++2` or `idx-->2`

The original pitch introduced `++` and `--` whose left-hand side could be omitted. Alternatives included symmetric `-->` and `<--`. This syntax was used for alternatives that offset existing indices, omitting a side for an implied start or end, and thus did not introduce a generic overload of `+`. However, in addition to the issues mentioned above in “Offset Arbitrary Indices”, these operators were met with considerable resistance: `++/--` carries C-baggage for many developers, and `++/--` and `-->/<--` are both new glyphs that don’t carry their weight when limited to the start or end of a collection.

#### Use an `offset:` label and literal convention

An alternative syntax (prototyped in [this gist](https://gist.github.com/milseman/7f7cf3b764618ead6011700fdce2ad83)) is to have `OffsetBound` be `ExpressibleByIntegerLiteral` with the convention that a negative literal produces an offset from the end. E.g.:

```swift
// Proposed
"abc"[.first + 1 ..< .last] // "b"

// Offset label
"abc"[offset: 1..<(-1)] // "b"
```

Negative values meaning from-the-end is only a convention on top of literals, i.e. this would *not* provide wrap-around semantics for a value that happens to be negative. 

In the end, we believe that the proposed syntax is more readable. There is less cognitive load in reading `.last` than mentally mapping the literal convention of `-1`, and that literal convention would be inconsistent with run-time values.


#### No Syntax

Alternative approaches include avoiding any syntax such as `+` or the use of the range operators `..<` and `...` by providing labeled subscript overloads for all combinations.

```swift
// Proposed
collection[.first + 5 ..< .last - 1]

// No ranges
collection[fromStart: 5, upToEndOffsetBy: -2]
```

We feel range-less variants are not in the direction and spirit of Swift. Swift uses range syntax for subscripts rather than multiple parameter labels:

```swift
// Existing Swift style
collection[lowerIdx ..< upperIdx] // Up-to
collection[lowerIdx ... upperIdx] // Up-through

// Not Swift style
collection[from: lowerIdx, upTo: upperIdx]
collection[from: lowerIdx, upThrough: upperIdx]
```



### Don’t Make it Easy

One objection to this approach is that it makes it less obnoxious to write poorly performing formulations of simple iteration patterns. Advancing the start index in every iteration of a loop can be a quadratic formulation of an otherwise linear algorithm. Currently, writing the quadratic formulation requires significantly more complex and unwieldy code compared to efficient approaches. The fear is that ergonomic improvements to legitimate use cases in this pitch would also improve the ergonomics of inefficient code.

```swift
// Linear, for when you want `element`
for element in collection { ... }

// Linear, for when you want `idx` and `element`
for idx in collection.indices {
  let element = collection[idx]
  ...
}

// Linear time and linear space, for when you want `element`, `i`, and random-access to `indices`.
let indices = Array(collection.indices)
for i in 0..<indices.count {
  let element = collection[indices[i]]
  ...
}

// Quadratic, obnoxious to write
for i in 0..<collection.count {
  let element = collection[collection.index(collection.startIndex, offsetBy: i)]
  ...
}

// Quadratic, arguably too convenient
for i in 0..<collection.count {
  let element = collection[.first + i]!
  ...
}
```

We argue that the more efficient approaches are still clearer, simpler, and provide more functionality and richness than the quadratic approach. While it’s always better to discourage bad code, we argue this is out-weighed by expressivity wins for legitimate use cases and reducing bugs for Int-indexed collections.


### Don’t Return Optional `Index` or `Element`

The optionality of `index(at:)` and single-element subscript’s return values cover an important expressivity gap in `Collection` and follows the standard library’s API design philosophy.

#### Trapping APIs

Index manipulation through methods such as `index(after:)`, `index(_:offsetBy:)`, and subscripting with an index represent the lowest level programming interface for accessing elements and advancing positions in a collection. As such, they impose requirements on their use which are important for performance. E.g.:

* `index(after:)` must not be called on `endIndex`.
* `index(_:offsetBy:)`’s offset must not advance an index past the collection’s bounds and must not be negative unless the collection is also bidirectional.
* `subscript(_:Index) -> Element` must be passed a valid index less than `endIndex`.

A violation of the above requirements leading to a potential memory safety issue causes a trap. I.e. such violations are [irrecoverable logic errors](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst#logic-failures) and the process is safely taken down.

Additionally, such low-level index-manipulation-heavy code is most often written within a context where indices are known to be valid, e.g. because the indices were vended by the collection itself. Subscript taking an index is similarly non-optional, as an index is an assumed-valid “key” to a specific element. Swift, being a memory-safe language, will still bounds-check the access, but this is not surfaced to the programmer’s code and bounds checks can be eliminated by the optimizer if safe to do so. Again, invalid indices for these operations represent irrecoverable logic errors, so a trap is issued.

#### Optional Returning APIs

In contrast, higher-level operations are often written in a context where the existence of a desired element is not known. Whether there is or is not such an element represents cases that should be handled explicitly by code, most often through the use of an optional result. That is, non-existence is not a logic error but a simple domain error, for which Optional is [the best tool for the job](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst#simple-domain-errors).

For example, Dictionary has the regular `subscript(_:Index) -> Element` trapping subscript for indices derived from the dictionary itself, but additionally provides a `subscript(_:Key) -> Value?`, which returns `nil` if the key is not present in the dictionary. A missing key is not necessarily a logic error, just another case to handle in code. Similarly, `first`, `last`, `.randomElement()`, `min()`, etc., all return optionals, where emptiness is not necessarily a logic error, but a case to be handled in code.

Optional handling is a strength of Swift and known-valid access is an acceptable use of `!`, which has the effect of converting a simple domain error into an irrecoverable logic error.

Single element offset-based subscripting follows this pattern by returning `nil` if the offset is not valid for the collection. While this does introduce optional-handling code at the use site, handling such access would be necessary anyways outside of a context where the offset is known to be less than the count. Otherwise, in these contexts, the programmer would have to remember to guard a trapping subscript’s use site by an explicit check against `count`. Offset ranges are clamped, resulting in empty slice return values, just like other partial ranges. 

This means that `collection.last` matches `collection.index(at: .last)` and `collection[.last]` in optionality, and the latter two can be offset.

#### Example of Known-Valid Offset Context

For an example of a known-valid-offset context highlighting the differences between the lowest level and higher level APIs, consider the below binary-search algorithm on Collection. This formulation is constant in space and linear in indexing complexity if the collection is not random-access (and logarithmic if it is). Fetching `idx` in the loop body could be written using either `index(_:offsetBy:)`, `index(atOffset:)`, or `index(_:offsetBy:limitedBy:)`, all of which have the same complexity. However, `index(_:offsetBy)` is the lowest-level API available and assumes the given offset is valid (a trap will be issued only for those misuses that lead to a memory safety violation). That is, it treats an invalid offset as a logic error and doesn’t surface this distinction in code, unlike the higher level `index(atOffset:)` and `index(_:offsetBy:limitedBy)` APIs which return optionals. This allows its implementation to skip branches checking the past-the-end condition on every loop iteration, and it allows the caller to skip a branch checking if there was a result. It is unreasonable (at least in general) to expect an optimizer to perform this transformation automatically based on scalar evolution of `count` and an understanding of the implementation of the customizable indexing APIs (which may be dynamically dispatched).

```swift
extension Collection {
  func binarySearch(for element: Element) -> Index? {
    assert(self.elementsEqual(self.sorted()), "only valid if sorted")

    var slice = self[...]
    var count = self.count // O(n) if non-RAC
    while count > 1 {
      defer { assert(slice.count == count) }

      let middle = count / 2

      // Either of the below formulations sum to a total of O(n) index
      // advancement operations across all loop iterations if non-RAC.
      let idx = slice.index(slice.startIndex, offsetBy: middle)
      // let idx = slice.index(at: .first + middle)!
      // let idx = slice.index(
      //   slice.startIndex, offsetBy: middle, limitedBy: slice.endIndex)!

      let candidate = self[idx]
      if candidate == element { return idx }
      if candidate < element {
        slice = slice[idx...]
        count = count &- middle // because division truncates
      } else {
        slice = slice[..<idx]
        count = middle
      }
    }
    return slice.first == element ? slice.startIndex : nil
  }
}
```

The alternatives that use an explicit `!` are not wrong to do so, as they are validly bounded by the nature of a binary search. But, using `index(_:offsetBy:)` is a more efficient alternative.


