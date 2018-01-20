# One-sided Ranges

* Proposal: [SE-0172](0172-one-sided-ranges.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift), [Dave Abrahams](https://github.com/dabrahams), [Brent Royal-Gordon](https://github.com/brentdax)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 4)** 
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170424/036125.html)

## Introduction

This proposal introduces the concept of a "one-sided" range, created via 
prefix/postfix versions of the existing range operators.

It also introduces a new protocol, `RangeExpression`, to simplify the creation
of methods that take different kinds of ranges.

## Motivation

It is common, given an index into a collection, to want a slice up to or from
that index versus the start/end.

For example (assuming `String` is once more a `Collection`):

```swift
let s = "Hello, World!"
let i = s.index(of: ",")!
let greeting = s[s.startIndex..<i]
```

When performing lots of slicing like this, the verbosity of repeating
`s.startIndex` is tiresome to write and harmful to readability.

Swift 3’s solution to this is a family of methods:

```swift
let greeting = s.prefix(upTo: i)
let withComma = s.prefix(through: i)
let location = s.suffix(from: i)
```

The two very different-looking ways to perform a similar task is jarring. And
as methods, the result cannot be used as an l-value.

A variant of the one-sided slicing syntax found in Python (i.e. `s[i:]`) is
proposed to resolve this.

## Proposed solution

Introduce a one-sided range syntax, where the "missing" side is inferred to be
the start/end:

```swift
// half-open right-handed range
let greeting = s[..<i]
// closed right-handed range
let withComma = s[...i]
// left-handed range (no need for half-open variant)
let location = s[i...]
```

Additionally, when the index is a countable type, `i...` should form a
`Sequence` that counts up from `i` indefinitely. This is useful in forming
variants of `Sequence.enumerated()` when you either want them non-zero-based
i.e. `zip(1..., greeting)`, or want to flip the order i.e. `zip(greeting,
0...)`.

This syntax would supercede the existing `prefix` and `suffix` operations that
take indices, which will be deprecated in a later release. Note that the
versions that take distances are not covered by this proposal, and would remain.

This will require the introduction of new range types (e.g.
`PartialRangeThrough`). There are already multiple range types (e.g.
`ClosedRange`, `CountableHalfOpenRange`), which require overloads to allow them
to be used wherever a `Range` can be.

To unify these different range types, a new protocol, `RangeExpression` will be
created and all ranges conformed to it. Existing overloads taking concrete
types other than `Range` can then be replaced with a single generic method that
takes a `RangeExpression`, converts it to a `Range`, and then forward the
method on. 

A generic version of `~=` will also be implemented for all range
expressions:

```swift
switch i {
case 9001...: print("It’s over NINE THOUSAAAAAAAND")
default: print("There's no way that can be right!")
}
```

The existing concrete overloads that take ranges other than `Range` will be
deprecated in favor of generic ones that take a `RangeExpression`.

## Detailed design

Add the following to the standard library:

(a fuller work-in-progress implementation can be found here: https://github.com/apple/swift/pull/8710)

NOTE: The following is subject to change depending on pending compiler
features. Methods may actually be on underscored protocols, and then moved once
recursive protocols are implemented. Types may be collapsed using conditional
conformance. This should not matter from a usage perspective – users are not
expected to use these types directly or override any of the behaviors in their
own types. Any final implementation will follow the below in spirit if not in
practice.

```swift
public protocol RangeExpression {
    associatedtype Bound: Comparable

    /// Returns `self` expressed as a range of indices within `collection`.
    ///
    /// -Parameter collection: The collection `self` should be
    ///                        relative to.
    ///
    /// -Returns: A `Range<Bound>` suitable for slicing `collection`.
    ///           The return value is *not* guaranteed to be inside
    ///           its bounds. Callers should apply the same preconditions
    ///           to the return value as they would to a range provided
    ///           directly by the user.
    func relative<C: _Indexable>(to collection: C) -> Range<Bound> where C.Index == Bound

    func contains(_ element: Bound) -> Bool
}

extension RangeExpression {
  public static func ~= (pattern: Self, value: Bound) -> Bool
}

prefix operator ..<
public struct PartialRangeUpTo<T: Comparable>: RangeExpression {
  public init(_ upperBound: T) { self.upperBound = upperBound }
  public let upperBound: T
}
extension Comparable {
  public static prefix func ..<(x: Self) -> PartialRangeUpTo<Self>
}

prefix operator ...
public struct PartialRangeThrough<T: Comparable>: RangeExpression {
  public init(_ upperBound: T)
  public let upperBound: T
}
extension Comparable {
  public static prefix func ...(x: Self) -> PartialRangeThrough<Self>
}

postfix operator ...
public struct PartialRangeFrom<T: Comparable>: RangeExpression {
  public init(_ lowerBound: T)
  public let lowerBound: T
}
extension Comparable {
  public static postfix func ...(x: Self) -> PartialRangeFrom<Self>
}

// The below relies on Conditional Conformance. Pending that feature,
// this may require an additional CountablePartialRangeFrom type temporarily.
extension PartialRangeFrom: Sequence 
  where Index: _Strideable, Index.Stride : SignedInteger


extension Collection {
  public subscript<R: RangeExpression>(r: R) -> SubSequence
   where R.Bound == Index { get }
}
extension MutableCollection {
  public subscript<R: RangeExpression>(r: R) -> SubSequence
   where R.Bound == Index { get set }
}
  
extension RangeReplaceableColleciton {
  public mutating func replaceSubrange<C: Collection, R: RangeExpression>(
    _ subrange: ${Range}<Index>, with newElements: C
  ) where C.Iterator.Element == Iterator.Element, R.Bound == Index

  public mutating func removeSubrange<R: RangeExpression>(
    _ subrange: ${Range}<Index>
  ) where R.Bound == Index
}
```

Additionally, these new ranges will implement appropriate protocols such as
`CustomStringConvertible`.

It is important to note that these new methods and range types are _extensions
only_. They are not protocol requirements, as they should not need to be
customized for specific collections. They exist only as shorthand to expand
out to the full slicing operation.

Where `PartialRangeFrom` is a `Sequence`, it is left up to the type of `Index`
to control the behavior when the type is incremented past its bounds. In the
case of an `Int`, the iterator will trap when iterating past `Int.max`. Other
types, such as a `BigInt` that could be incremented indefinitely, would behave
differently.

The `prefix` and `suffix` methods that take an index _are_ currently protocol
requirements, but should not be. This proposal will fix that as a side-effect.

## Source compatibility

The new operators/types are purely additive so have no source compatibility
consequences. Replacing the overloads taking concrete ranges other than `Range` 
with a single generic version is source compatible. `prefix` and `suffix` will
be deprecated in Swift 4 and later removed.

## Effect on ABI stability

The `prefix`/`suffix` methods being deprecated should be eliminated before
declaring ABI stability.

## Effect on API resilience

The new operators/types are purely additive so have no resilience
consequences.

## Alternatives considered

`i...` is favored over `i..<` because the latter is ugly. We have to pick one,
two would be redundant and likely to cause confusion over which is the "right" one.
Either would be reasonable on pedantic correctness grounds – `(i as Int)...`
includes `Int.max` consistent with `...`, whereas `a[i...]` is interpreted as
`a[i..<a.endIndex]` consistent with `i..<`.

It might be nice to consider extend this domain-specific language inside the
subscript in other ways. For example, to be able to incorporate the index
distance versions of prefix, or add distance offsets to the indices used within
the subscript. This proposal explicitly avoids proposals in this area. Such
ideas would be considerably more complex to implement, and would make a good
project for investigation by an interested community member, but would not fit
within the timeline for Swift 4.


