# Rename `flatten()` to `joined()`

* Proposal: [SE-0133](0133-rename-flatten-to-joined.md)
* Author: [Jacob Bandes-Storch](https://github.com/jtbandes)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000265.html)
* Implementation: [apple/swift#3809](https://github.com/apple/swift/pull/3809),
                  [apple/swift#3838](https://github.com/apple/swift/pull/3838),
                  [apple/swift#3839](https://github.com/apple/swift/pull/3839)

## Introduction

Swift currently defines two similar functions, `joined(separator:)` and `flatten()`. `joined(separator:)` has a specialized implementation for Strings, and `flatten()` has implementations for various kinds of collections.

```swift
extension Sequence where Iterator.Element : Sequence {
  public func joined<Separator: Sequence>(separator: Separator) -> JoinedSequence<Self>
  public func flatten() -> FlattenSequence<Self>
}

extension Collection where Element : Collection {  // and similar variants
  public func flatten() -> FlattenCollection<Self>
}
```

This proposal renames `flatten()` to `joined()` (with no separator argument). It also adds a default separator of `""` to the String-specific version of `joined(separator:)`.

https://github.com/apple/swift/blob/f72a82327b172e1a2979e46cb7a579e3cc2f3bd6/stdlib/public/core/Join.swift
https://github.com/apple/swift/blob/c6e828f761fc30f7ce444431de7da52814f96595/stdlib/public/core/String.swift#L769
https://github.com/apple/swift/blob/f72a82327b172e1a2979e46cb7a579e3cc2f3bd6/stdlib/public/core/Flatten.swift.gyb

Swift-evolution threads:
- [[Pitch] Unify joined(separator:) and flatten()](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/025136.html)
- [[Pitch] Rename flatten() to joined() and give joined() for string sequences the empty string as the default parameter](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/025234.html)

## Motivation

To a user, there should be **no distinction** between `flatten()`ing a sequence or collection, and "joining" it with no separator.

Hence, the following expressions should be valid:

```swift
[[1,2],[3]].joined()                // [1,2,3]  -- currently named flatten()
[[1,2],[3]].joined(separator: [])   // [1,2,3]
[[1,2],[3]].joined(separator: [0])  // [1,2,0,3]

["ab","d"].joined()                // "abd"  -- currently no nullary function to do this
["ab","d"].joined(separator: "")   // "abd"
["ab","d"].joined(separator: "_")  // "ab_d"
```

## Proposed solution

Rename `flatten()` to `joined()` with no argument. For now, it's acceptable to keep the code currently in Join.swift and that in Flatten.swift.gyb separate — in the future it might make sense to unify the algorithms.

The String-specific version of `joined(separator:)` is independent of the Sequence protocol extension (since String is not a Sequence), but the functionality is still useful. For consistency, a default value of `""` should be added to the `separator` parameter:

```swift
extension Sequence where Iterator.Element == String {
  func joined(separator: String = "") -> String {
    ...
  }
}
```
(Or, if the standard library team deems it a better solution, `joined()` could be a separate method that simply calls `joined(separator: "")`.)

## Impact on existing code

Users of `flatten()` will need to migrate to `joined()`; this is straightforward with an availability attribute. Application behavior should not change.

## Alternatives considered

An alternative is to leave `flatten()` and `joined(separator:)` as separate APIs. The distinction, however, seems unnecessary, and unifying them is a minor win for API clarity.

