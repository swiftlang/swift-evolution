# Substring performance affordances

* Proposal: [SE-0183](0183-substring-affordances.md)
* Author: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2017-July/000395.html)
* Bug: [SR-4933](https://bugs.swift.org/browse/SR-4933)

## Introduction

This proposal modifies a small number of methods in the standard library that
are commonly used with the `Substring` type:

 - Modify the `init` on floating point and integer types, to construct them
   from `StringProtocol` rather than `String`. 
- Change `join` to be an extension `where Element: StringProtocol`
- Have `Substring.filter` to return a `String`

## Motivation

Swift 4 introduced `Substring` as the slice type for `String`. Previously,
`String` had been its own slice type, but this leads to issues where string
buffers can be unexpectedly retained. This approach was adopted instead of the
alternative of having the slicing operation make a copy. A copying slicing
operation would have negative performance consequences, and would also conflict
with the requirement that `Collection` be sliceable in constant time. In cases
where an API requires a `String`, the user must construct a new `String` from a
`Substring`. This can be thought of as a "deferral" of the copy that was
avoided at the time of the slice.

There are a few places in the standard library where it is notably inefficient
to force a copy of a substring in order to use it with a string: joining
substrings, and converting substrings to integers. In particular, these
operations are likely to be used inside a loop over a number of substrings
extracted from a string – for example, splitting a string into substrings,
then rejoining them.

Additionally, per SE-163, operations on `Substring` that produce a fresh string
(such as `.uppercase`) should return a `String`. This changes
`Substring.filter` to do so.

## Proposed solution

Add the following to the standard library:

```swift
extension FixedWidthInteger {
  public init?<S : StringProtocol>(_ text: S, radix: Int = 10)
}

extension Float/Double/Float80 {
  public init?<S : StringProtocol>(_ text: S, radix: Int = 10)
}

extension Sequence where Element: StringProtocol {
  public func joined(separator: String = "") -> String
}

extension Substring {
  public func filter(_ isIncluded: (Element) throws -> Bool) rethrows -> String
}
```

These additions are deliberately narrow in scope. They are _not_ intended to
solve a general problem of being able to interchange substrings for strings (or
more generally slices for collections) generically in different APIs. See the
alternatives considered section for more on this.

## Source compatibility

No impact, these are generalizing an existing API to a protocol (in case of numeric conversion/joining) or modify a type newly introduced in Swift 4 (in
case of `filter`).

## Effect on ABI stability

The switch from conrete to generic types needs to be made before ABI stability.

## Alternatives considered

The goal of this proposal is to generalize existing methods that are specific
to string processing. Further affordances, such as implicit or explicit
conversions of `String` to `Substring`, might solve this problem more generally
but are considered out of scope for this proposal.
