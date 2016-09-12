# Add StaticString.UnicodeScalarView

* Proposal: [SE-0010](0010-add-staticstring-unicodescalarview.md)
* Author: [Kevin Ballard](https://github.com/kballard)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-February/000045.html)

## Introduction

There is no way to create a substring of a `StaticString` that is still typed
as `StaticString`. There should be.

[Swift Evolution Discussion Thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151130/000535.html), [Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/005609.html)

## Motivation

It is occasionally useful to be able to produce a substring of a `StaticString`
that can be passed to APIs expecting a `StaticString`. For example, extracting
the filename from `__FILE__`. But there is no way to do this today, as
`StaticString` does not provide any means by which to create a new instance
beyond the trivial nullary `init()` initializer (which creates an empty
string).

## Proposed solution

We add a new type `StaticString.UnicodeScalarView` that conforms to
`CollectionType` and a new property `unicodeScalars` on `StaticString`. We also
add 2 initializers to `StaticString`

```swift
init(_ unicodeScalars: UnicodeScalarView)
init(_ unicodeScalars: Slice<UnicodeScalarView>)
```

Together, this allows the user to manipulate the unicode scalar view to produce
the desired slice, and then to create a `StaticString` from the results. This
has the added benefit of providing a convenient way to work with
`StaticString`s as a sequence of `UnicodeScalar`s instead of as a UTF8 buffer.

## Detailed design

The API looks like this:

```swift
extension StaticString {
  /// The value of `self` as a collection of [Unicode scalar values](http://www.unicode.org/glossary/#unicode_scalar_value).
  public var unicodeScalars: UnicodeScalarView { get }

  /// Construct the `StaticString` corresponding to the given
  /// `UnicodeScalarView`.
  public init(_: UnicodeScalarView)

  /// Construct the `StaticString` corresponding to the given
  /// `UnicodeScalarView` slice.
  public init(_: Slice<UnicodeScalarView>)

  /// A collection of [Unicode scalar values](http://www.unicode.org/glossary/#unicode_scalar_value) that
  /// encode a `StaticString`.
  public struct UnicodeScalarView : CollectionType {

    init(_: StaticString)

    /// A position in a `StaticString.UnicodeScalarView`.
    public struct Index : BidirectionalIndexType, Comparable {
      /// Returns the next consecutive value after `self`.
      ///
      /// - Requires: The next value is representable.
      @warn_unused_result
      public func successor() -> Index

      /// Returns the previous consecutive value before `self`.
      ///
      /// - Requires: The previous value is representable.
      @warn_unused_result
      public func predecessor() -> Index
    }

    /// The position of the first `UnicodeScalar` if the `StaticString` is
    /// non-empty; identical to `endIndex` otherwise.
    public var startIndex: Index { get }

    /// The "past the end" position.
    ///
    /// `endIndex` is not a valid argument to `subscript`, and is always
    /// reachable from `startIndex` by zero or more applications of
    /// `successor()`.
    public var endIndex: Index { get }

    /// Returns `true` iff `self` is empty.
    public var isEmpty: Bool { get }

    public subscript(position: Index) -> UnicodeScalar { get }
  }
}
```

## Impact on existing code

None.

## Alternatives considered

We could add a `subscript(bounds: Range<Index>)` to `StaticString` directly,
but there's no good way to define `Index` (for the same reasons `String`
doesn't conform to `CollectionType`).

We could expose an unsafe initializer from a pointer, so the user can
manipulate `utf8Start` to produce the desired pointer, but this would be very
unsafe and allow users to try and trick code taking `StaticString` into
accepting a dynamic string instead.
