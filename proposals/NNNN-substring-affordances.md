# Substring performance affordances

* Proposal: [SE-NNNN](NNNN-substring-affordances.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

This proposal modifies a small number of methods in the standard library that
are commonly used with the `Substring` type:

 - Modify the `init` on floating point and integer types, to construct them
   from `StringProtocol` rather than `String`. 
- Change `join` to be an extension `where Element: StringProtocol`
- Add extensions to `Dictionary where Key == String` and `Set where Element ==
   String` to test for presence of a `Substring`.

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
to force a copy of a substring in order to use it with a string: performing
lookups in hashed containers, joining substrings, and converting substrings to
integers. In particular, these operations are likely to be used inside a loop
over a number of substrings extracted from a string. For example, suppose you
had a string of key/value pairs, where the values were integers and you wanted
to sum them by key. You would be forced to convert both the `Substring` keys
and values to `String` to do this.

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

extension Dictionary where Key == String {
  public subscript(key: Substring) -> Value? { get set }
  public subscript(key: Substring, default defaultValue: @autoclosure () -> Value) -> Value { get set }
}

extension Set where Element == String {
  public func contains(_ member: Substring) -> Bool
  public func index(of member: Substring) -> Index?
  public mutating func insert(_ newMember: Substring) -> (inserted: Bool, memberAfterInsert: Element)
  public mutating func remove(_ member: Substring) -> Element?
}
```

These additions are deliberately narrow in scope. They are _not_ intended to
solve a general problem of being able to interchange substrings for strings (or
more generally slices for collections) generically in different APIs. See the
alternatives considered section for more on this.

## Source compatibility

No impact, these are either additive (in case of hashed containers) or
generalize an existing API to a protocol (in case of numeric
conversion/joining).

## Effect on ABI stability

The hashed container changes are additive so no impact. The switch from conrete
to generic types for the numeric conversions needs to be made before ABI
stability.

## Alternatives considered

While they have a convenience benefit was well, this is not the primary goal of
these additions, but a side-effect of helping avoid a performance problem. In
many other cases, the performance issues can be avoided via modified use e.g.
`Sequence.contains` of a `Substring` in a sequence of strings can be written as
`sequence.contains { $0 == substring }` .

These changes are limited in scope, and further additions could be considered
in the future. For example, should the `Dictionary.init(grouping:by:) where Key
== String` operation be enhanced to similarly take a sequence of substrings?
There is a long tail of these cases, and the need to keep unnecessary overloads
to a minimum, avoiding typechecker work and code bloat, must be weighed against
the likelyhood that string copies will be a performance problems.

There is a more general problem of interoperating between collections and
slices. In the future, there may be other affordances for converting/comparing
them. For example, it might be desirable to require equatable collections to
have equatable slices, and to automatically provide default implementations of
`==` that efficiently compare a collection to its default slice. These
enhancements rely on features such as conditional conformance, and so may be
worth considering in later versions of Swift but are not an option currently.


