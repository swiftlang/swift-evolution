# Change `filter` to return an associated type

* Proposal: [SE-0174](0174-filter-range-replaceable.md)
* Author: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Accepted**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2017-May/000374.html)
* Bug: [SR-3444](https://bugs.swift.org/browse/SR-3444)

## Introduction

This proposal changes the `filter` operation on `Sequence` to return an
associated type, and adds a default implementation to
`RangeReplaceableCollection` to return the same type as the filtered collection.

## Motivation

The recently accepted
[SE-165](https://github.com/apple/swift-evolution/blob/master/proposals/0165-dict.md)
introduced a version of `filter` on `Dictionary` that returned a
`Dictionary`. This had both performance and usability benefits: in most cases,
a `Dictionary` is what the user wanted from the filter, and creating one
directly from the filter operation is much more efficient than first creating
an array then creating a `Dictionary` from it.

However, this does result in some inconsistencies. Users may be surprised that
this one specific collection returns `Self`, while other collections that would
benefit from the same change still return `[Element]`. And some collections,
such as `String`, might also benefit from usability and performance win similar
to `Dictionary`. Additionally, these wins will be lost in generic code – if you
pass a `Dictionary` into an algorithm that takes a `Sequence`, then when you
filter it, you will still get an `Array`.

## Proposed solution

The existing protocol requirement on `filter` will be changed to return an
associated type, `Filtered`. The extension providing a default implementation
will remain as-is, resulting in an inferred value for `Filtered` of
`[Element]`. `Dictionary` will automatically infer a filtered type of
`Dictionary` as a result of this change.

A default implementation on `RangeReplaceableCollection` will be provided,
using `init()` and `append(_:)`, so all range-replaceable collections will
have a `Filtered` of `Self`. Per [SE-163](https://github.com/apple/swift-evolution/blob/master/proposals/0163-string-revision-1.md),
this will include `String`.

Note, many sequences (for example, strides or ranges), cannot represent a
filtered `self` as `Self` and will continue to return an array. If this is a
performance problem, `lazy` remains a good solution.

## Detailed design

Add a `Filtered` associated type to `Sequence`, and change the requirement to
return it:

```swift
protocol Sequence {
  associatedtype Filtered
  /// Returns an filtered sequence containing, in order, the elements of the 
  /// sequence that satisfy the given predicate.
  ///
  /// In this example, `filter` is used to include only names shorter than
  /// five characters.
  ///
  ///     let cast = ["Vivien", "Marlon", "Kim", "Karl"]
  ///     let shortNames = cast.filter { $0.characters.count < 5 }
  ///     print(shortNames)
  ///     // Prints "["Kim", "Karl"]"
  ///
  /// - Parameter isIncluded: A closure that takes an element of the
  ///   sequence as its argument and returns a Boolean value indicating
  ///   whether the element should be included in the returned sequence.
  /// - Returns: An array of the elements that `includeElement` allowed.
  func filter(
    _ isIncluded: (Iterator.Element) throws -> Bool
  ) rethrows -> Filtered
}
```

Add a default implementation of `filter` to `RangeReplaceableCollection`
returning `Self`:

```swift
extension RangeReplaceableCollection {
    func filter(_ isIncluded: (Iterator.Element) throws -> Bool) rethrows -> Self {
        var result = Self()
        for element in self {
            if try isIncluded(element) {
                result.append(element)
            }
        }
        return result
    }
}
```

Specific concrete collections may choose to implement a faster version, but
this is an implementation detail.

## Source compatibility

This change is subtly source breaking. In most cases users will not notice.
They may be be relying on an array being returned (albeit often in order to
then transform it back into the original type), but this version will still
be available (via the extension on `Sequence`) and will be called if forced
through type context. The only code that will break is if this operation spans
multple lines:

```swift
// filtered used to be [Character], now String
let filtered = "abcd".filter { $0 == "a" }
useArray(filtered) // won't compile
```

Because of this, the new implementation of `RangeReplaceableCollection.filter`
will only be available in Swift 4.

## Effect on ABI stability

This change will affect the ABI of `Sequence` and needs to be made before
declaring ABI stability.

## Effect on API resilience

N/A

## Alternatives considered

Status-quo. There are benefits to the consistency of always returning `[Element]`.

It could be worthwhile to make a similar change to `map`, but this is beyond
the capabilities of the current generics system because `map` does not preserve
the element type (more specifically, you cannot express a type that is `Self`
except with a different `Element` in order to provide the default
implementation on `RangeReplaceableCollection`).

