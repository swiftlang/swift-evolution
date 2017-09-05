# Add `unicodeScalars` property to `Character`

* Proposal: [SE-0178](0178-character-unicode-view.md)
* Author: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170515/036714.html)
* Implementation: [apple/swift#9675](https://github.com/apple/swift/pull/9675)

## Introduction

This proposal adds a `unicodeScalars` view to `Character`, similar to that on `String`.

## Motivation

The `Character` element type of `String` is currently a black box that provides
little functionality besides comparison, literal construction, and to be used
as an argument to `String.init`.

Many operations on `String` could be neatly/readably implemented as operations
on each character in the string, if `Character` exposed its scalars more
directly. Many useful things can be determined by examining the scalars in a
grapheme (for example is this an ASCII character?).

For example, today you can write this:

```swift
let s = "one two three"
s.split(separator: " ")
```

But you cannot write this:

```swift
let ws = CharacterSet.whitespacesAndNewlines
s.split { $0.unicodeScalars.contains(where: ws.contains) }
```

## Proposed solution

Add a `unicodeScalars` property to `Character`, presenting a lazy view of the
scalars in the character, along similar lines to the one on `String`.

Unlike the view on `String`, this will _not_ be a mutable view – it will be
read-only. The preferred method for creating and manipulating non-literal
`Character` values will be through `String`. While there may be some good
use cases to manipulating a `Character` directly, these are outweighed by the 
complexity of ensuring the invariant that it contain exactly one grapheme.

## Detailed design

Add the following nested type to `Character`:

```swift
extension Character {
  public struct UnicodeScalarView : BidirectionalCollection {
    public struct Index
    public var startIndex: Index { get }
    public var endIndex: Index { get }
    public func index(after i: Index) -> Index
    public func index(before i: Index) -> Index
    public subscript(i: Index) -> UnicodeScalar
  }
  public var unicodeScalars: UnicodeScalarView { get }
}
```

Additionally, this type will conform to appropriate convenience protocols such 
as `CustomStringConvertible`.

All initializers will be declared internal, as unlike the `String` equivalent,
this type will only ever be vended by `Character`.

## Source compatibility

Purely additive, so no impact.

## Effect on ABI stability

Purely additive, so no impact.

## Effect on API resilience

Purely additive, so no impact.

## Alternatives considered

Adding other views, such as `utf8` or `utf16`, was considered but not deemed useful
enough compared to using these operations on `String` instead.

In the future, this feature could be used to implement convenience methods such as
`isASCII` on `Character`. This could be done additively, given this building block,
and is outside the scope of this initial proposal.
