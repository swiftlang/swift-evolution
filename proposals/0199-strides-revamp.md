# Revamp the StrideTo/StrideThrough types

* Proposal: [SE-0199](0199-strides-revamp.md)
* Authors: [Max Moiseev](https://github.com/moiseev), [Xiaodi Wu](https://github.com/xwu)
* Review Manager: TBD
* Status: **Awaiting implementation**

* Implementation: [apple/swift#14288](https://github.com/apple/swift/pull/14288)

<!--

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

-->

## Introduction

The Swift standard library provides two sequence types `StrideTo` and
`StrideThrough`, instances of which are returned from `stride(from:to:by:)` and
`stride(from:through:by:)` respectively. These types are designed to be more
flexible versions of Swift ranges, allowing start values greater than end values
and stride values other than 1.

Both of these types currently conform to `Sequence`. This is quite unfortunate,
because for integer values a `StrideTo` instance can conform to
`RandomAccessCollection` and provide more performant implementations for methods
like `prefix(_:)`, `dropFirst(_:)`, etc. That is *O(1)* for
`RandomAccessCollection` as opposed to *O(n)* for `Sequence`.

## Motivation

We are going to use `StrideTo` type in the motivating examples for brevity, but
the same reasoning applies to `StrideThrough` as well.

Let's consider the following snippet:

```swift
let myStride = stride(from: 1, to: 10, by: 3)
_ = myStride.dropFirst(1)
```

The `dropFirst(_:)` method call will return a type-erased `AnySequence`; that
involves allocating a whole new class instance (although this is an
implementation detail) instead of just advancing the start value by one step.

With the addition of [conditional conformances][1] to the language, the result
of `zip(_:_:)` can now be a `Collection` if both containers being zipped conform
to `Collection`. (See
[apple/swift#13941](https://github.com/apple/swift/pull/13941) for the details.)
Unfortunately, without `StrideTo` conforming to `Collection` as proposed,
expressions such as the following do not take advantage of `zip`’s conditional
conformance.

```swift
zip([1,2,3], stride(from: 2, to: 42, by: 2))
```

The result of this expression only conforms to `Sequence` and as such provides
none of the `Collection` APIs.

## Proposed solution

We propose to make the following changes to the stride types `StrideTo` and
`StrideThrough`.

* Make them conform to `RandomAccessCollection` on condition that the
  `Element.Stride` conforms to `BinaryInteger` (see the [Detailed design](#detailed-design) section for the explanation of the condition)

```swift
extension StrideTo : RandomAccessCollection
where Element.Stride : BinaryInteger { }

extension StrideThrough : RandomAccessCollection
where Element.Stride : BinaryInteger { }
```

Since currently both `StrideTo` and `StrideThrough` define `SubSequence` as `AnySequence<Element>`, and it only conforms to `Sequence`, another modification needs to be made.

* Make both types their own `SubSequence`:

```swift
struct StrideTo<Element> {
  typealias SubSequence = StrideTo
}

struct StrideThrough<Element> {
  typealias SubSequence = StrideThrough
}
```

We believe these changes will solve the problems outlined in the
[Motivation](#motivation) section and make code using results of
`stride(from:to:by)` and `stride(from:through:by:)` more powerful and more
performant without any modifications to the call sites.

## Detailed design

Turning `StrideTo` and `StrideThrough` into slice types (making them their own
sub-sequences) only requires implementation, not much of a design. Conforming to
the `Collection` family of protocols, however, is another topic and is worth
discussing in a little more detail.

### Condition for `Collection` conformance

There are other `Strideable` types in the standard library, including all
floating point number types. However, floating point types represent real
numbers, and striding over even a modest interval may involve a very large
number of iterations if the stride is small. The protocol `Collection`, however,
uses `Int` as the type of its `count` property. So reading the value of `count`
for an innocuous stride could easily result in trapping on integer overflow if
one is not careful.

This same argument can, of course, be applied to strides of integer values
containing many more elements than an `Int` can represent, but we believe this
is a far less frequent situation. Besides, the same behavior can already be
observed with the types provided by the standard library. For example, taking a
`distance(from: startIndex, to: endIndex)` of a range `-1..<Int.max` will result
in an overflow.

Besides, as mentioned at the very beginning of this proposal, `StrideTo` and
`StrideThrough` types are more general versions of Swift's ranges, that allow
*stride* or *step* other than `1`, and ranges only conform to
`RandomAccessCollection` if they are *countable*, which is expressed as:

```swift
extension Range: RandomAccessCollection
where Bound: Strideable, Bound.Stride: SignedInteger { }
```

The proposed design for `StrideTo` and `StrideThrough` is therefore:

```swift
extension StrideTo : RandomAccessCollection
where Element.Stride : BinaryInteger { }

extension StrideThrough : RandomAccessCollection
where Element.Stride : BinaryInteger { }
```

### Chosing the right `Index` type

Another item worth noting is that there are at least 2 possible ways to
represent indices for the new collection types.

 1) Zero-based `Int` indices
 2) Use `typealias Index = Element`
 3) Use option 1 for `StrideTo` and re-use `ClosedRange.Index` for `StrideThrough`

Zero-based indexing is somewhat simpler to implement, but the downside is that
indices of such collections are no longer intechangeable with its sub-sequence's,
which is not the behavior all other standard library collection exhibit. For
example:

```swift
let r = 5..<10
let sub = r[7...]
r[sub.startIndex] == sub[sub.startIndex] // results in true
```

`ClosedRange.Index` type is designed to allow for an explicit `pastEnd` case
and might be a good candidate for `StrideThrough`, but stride-through is
slightly more complicated than a `ClosedRange` because the last value can be
*jumped over* when it does not fall on the stride boundary. This detail will
unnecessarily complicate the implementation of `Collection` conformance with no
benefits over option 2.

Therefore, we're left with what seems to be the only option for `Index` type:

```swift
extension StrideTo: Collection
where Element.Stride: BinaryInteger {
  typealias Index = Element
}

extension StrideThrough: Collection
where Element.Stride: BinaryInteger {
  typealias Index = Element
}
```

## Source compatibility

This is a source breaking change, as demonstrated by the following example that
would no longer compile.

```swift
func consume(_ xs: AnySequence<Int>) { }
consume(stride(from: 1, to: 10, by: 2).dropFirst(1))
```

However, running the test compatiblity test suite on the branch that implements
this proposal did not reveal any related breakage. We also believe that results
of `stride(from:to:by:)` and `stride(from:through:by:)` functions are rarely
used in a way that would be incompatible with this change. The majority of the
usages would be to just loop over strides using `for..in` or calling `Sequence`
combinators, both of which are not affected.

Making this change in a backward-compatible way would be much harder and may
result in a worse API overall. (See [Alternatives
considered](#alternatives-considered) section for details.)

## Effect on ABI stability

This work is meant to *fix* the ABI of the standard library.

## Alternatives considered

One other option, and a backward-compatible one in fact, would be to preserve
`StrideTo` conformance to `Sequence` with the default `SubSequence` and
introduce a new type `StrideToCollection` unconditionally contrained to
`Element.Stride: BinaryInteger`. This solution would also require introducing
new overloads for `stride(from:to:by:)` and `stride(from:through:by:)`
functions, similarly constrained, to produce instances of `StrideToCollection` /
`StrideThroughCollection`. We believe that this solution results in a less
understandable API that also creates extra work for the type checker.

[1]: https://github.com/apple/swift-evolution/blob/master/proposals/0143-conditional-conformances.md
