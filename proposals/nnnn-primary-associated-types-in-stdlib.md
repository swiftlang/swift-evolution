# Primary Associated Types in the Standard Library

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: TBD
* Status: **Pitch**
* Implementation: [apple/swift#41843](https://github.com/apple/swift/pull/41843)

<!--
*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

[SE-0346] introduced the concept of primary associated types to the
language. This document proposes to adopt this feature in the Swift
Standard Library, adding primary associated types to select existing
protocols.

[SE-0346]: https://github.com/apple/swift-evolution/blob/main/proposals/0346-light-weight-same-type-syntax.md

**Swift-evolution thread:**<br>[[Pitch] Primary associated types in the Standard Library][thread]

[thread]: https://forums.swift.org/t/pitch-primary-associated-types-in-the-standard-library/56426

## Motivation

See [SE-0346] for several motivating examples for these changes.

## Proposed solution

The table below lists all public protocols in the Standard Library
with associated type requirements, along with their proposed primary
associated type, as well as a list of other associated types.

[note]: #alternatives-considered

| Protocol                                             | Primary        | Others                                                                                                                                                                                                               |
|------------------------------------------------------|----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Identifiable`                                       | `ID`           | --                                                                                                                                                                                                                   |
| `Sequence`                                           | `Element`      | `Iterator`                                                                                                                                                                                                           |
| `IteratorProtocol`                                   | `Element`      | --                                                                                                                                                                                                                   |
| `Collection`                                         | `Element`      | `Index`, `Iterator`, `SubSequence`, `Indices`                                                                                                                                                                        |
| `MutableCollection`                                  | `Element`      | `Index`, `Iterator`, `SubSequence`, `Indices`                                                                                                                                                                        |
| `BidirectionalCollection`                            | `Element`      | `Index`, `Iterator`, `SubSequence`, `Indices`                                                                                                                                                                        |
| `RandomAccessCollection`                             | `Element`      | `Index`, `Iterator`, `SubSequence`, `Indices`                                                                                                                                                                        |
| `RangeReplaceableCollection`                         | `Element`      | `Index`, `Iterator`, `SubSequence`, `Indices`                                                                                                                                                                        |
| `LazySequenceProtocol`                               | -- [(1)][note] | `Element`, `Iterator`, `Elements`                                                                                                                                                                                    |
| `LazyCollectionProtocol`                             | -- [(1)][note] | `Element`, `Index`, `Iterator`, `SubSequence`, `Indices`, `Elements`                                                                                                                                                 |
| `SetAlgebra`                                         | `Element`      | `ArrayLiteralElement`                                                                                                                                                                                                |
| `OptionSet`                                          | `Element`      | `ArrayLiteralElement`, `RawValue`                                                                                                                                                                                    |
| `RawRepresentable`                                   | `RawValue`     | --                                                                                                                                                                                                                   |
| `RangeExpression`                                    | `Bound`        | --                                                                                                                                                                                                                   |
| `Strideable`                                         | `Stride`       | --                                                                                                                                                                                                                   |
| `Numeric`                                            | --             | `IntegerLiteralType`, `Magnitude`                                                                                                                                                                                    |
| `SignedNumeric`                                      | --             | `IntegerLiteralType`, `Magnitude`                                                                                                                                                                                    |
| `BinaryInteger`                                      | --             | `IntegerLiteralType`, `Magnitude`, `Stride`, `Words`                                                                                                                                                                 |
| `UnsignedInteger`                                    | --             | `IntegerLiteralType`, `Magnitude`, `Stride`, `Words`                                                                                                                                                                 |
| `SignedInteger`                                      | --             | `IntegerLiteralType`, `Magnitude`, `Stride`, `Words`                                                                                                                                                                 |
| `FixedWidthInteger`                                  | --             | `IntegerLiteralType`, `Magnitude`, `Stride`, `Words`                                                                                                                                                                 |
| `FloatingPoint`                                      | --             | `IntegerLiteralType`, `Magnitude`, `Stride`, `Exponent`                                                                                                                                                              |
| `BinaryFloatingPoint`                                | --             | `IntegerLiteralType`, `FloatLiteralType`, `Magnitude`, `Stride`, `Exponent`, `RawSignificand`, `RawExponent`                                                                                                         |
| `SIMD`                                               | `Scalar`       | `ArrayLiteralElement`, `MaskStorage`                                                                                                                                                                                 |
| `SIMDStorage`                                        | --             | `Scalar`                                                                                                                                                                                                             |
| `SIMDScalar`                                         | --             | `SIMDMaskScalar`, `SIMD2Storage`, `SIMD4Storage`, ..., `SIMD64Storage`                                                                                                                                               |
| `Clock`                                              | `Duration`     | `Instant`                                                                                                                                                                                                            |
| `InstantProtocol`                                    | `Duration`     | --                                                                                                                                                                                                                   |
| `AsyncIteratorProtocol`                              | -- [(2)][note] | `Element`                                                                                                                                                                                                            |
| `AsyncSequence`                                      | -- [(2)][note]   | `AsyncIterator`, `Element`                                                                                                                                                                                           |
| `GlobalActor`                                        | --             | `ActorType`                                                                                                                                                                                                          |
| `KeyedEncodingContainerProtocol`                     | --             | `Key`                                                                                                                                                                                                                |
| `KeyedDecodingContainerProtocol`                     | --             | `Key`                                                                                                                                                                                                                |
| `ExpressibleByIntegerLiteral`                        | --             | `IntegerLiteralType`                                                                                                                                                                                                 |
| `ExpressibleByFloatLiteral`                          | --             | `FloatLiteralType`                                                                                                                                                                                                   |
| `ExpressibleByBooleanLiteral`                        | --             | `BooleanLiteralType`                                                                                                                                                                                                 |
| `ExpressibleByUnicodeScalarLiteral`                  | --             | `UnicodeScalarLiteralType`                                                                                                                                                                                           |
| `ExpressibleByExtended-`<br>`GraphemeClusterLiteral` | --             | `UnicodeScalarLiteralType`, `ExtendedGraphemeClusterLiteralType`                                                                                                                                                     |
| `ExpressibleByStringLiteral`                         | --             | `UnicodeScalarLiteralType`, `ExtendedGraphemeClusterLiteralType`, `StringLiteralType`                                                                                                                                |
| `ExpressibleByStringInterpolation`                   | --             | `UnicodeScalarLiteralType`, `ExtendedGraphemeClusterLiteralType`, `StringLiteralType`, `StringInterPolation`                                                                                                         |
| `ExpressibleByArrayLiteral`                          | --             | `ArrayLiteralElement`                                                                                                                                                                                                |
| `ExpressibleByDictionaryLiteral`                     | --             | `Key`, `Value`                                                                                                                                                                                                       |
| `StringInterpolationProtocol`                        | --             | `StringLiteralType`                                                                                                                                                                                                  |
| `Unicode.Encoding`                                   | --             | `CodeUnit`, `EncodedScalar`, `ForwardParser`, `ReverseParser`                                                                                                                                                        |
| `UnicodeCodec`                                       | --             | `CodeUnit`, `EncodedScalar`, `ForwardParser`, `ReverseParser`                                                                                                                                                        |
| `Unicode.Parser`                                     | --             | `Encoding`                                                                                                                                                                                                           |
| `StringProtocol`                                     | --             | `Element`, `Index`, `Iterator`, `SubSequence`, `Indices`, `UnicodeScalarLiteralType`, `ExtendedGraphemeClusterLiteralType`, `StringLiteralType`, `StringInterPolation`, `UTF8View`, `UTF16View`, `UnicodeScalarView` |
| `CaseIterable`                                       | --             | `AllCases`                                                                                                                                                                                                           |

As of Swift 5.6, the following public protocols don't have associated type requirements, so they are outside of the scope of this proposal.

```swift
Equatable, Hashable, Comparable, Error, AdditiveArithmetic,
DurationProtocol, Sendable, UnsafeSendable, Actor, AnyActor, Executor,
SerialExecutor, Encodable, Decodable, Encoder, Decoder,
UnkeyedEncodingContainer, UnkeyedDecodingContainer,
SingleValueEncodingContainer, SingleValueDecodingContainer,
ExpressibleByNilLiteral, CodingKeyRepresentable,
CustomStringConvertible, LosslessStringConvertible, TextOutputStream,
TextOutputStreamable, CustomPlaygroundDisplayConvertible,
CustomReflectable, CustomLeafReflectable, MirrorPath,
RandomNumberGenerator, CVarArg
```

## Detailed design

```swift
public protocol Identifiable<ID>
public protocol Sequence<Element>
public protocol IteratorProtocol<Element>
public protocol Collection<Element>: Sequence
public protocol MutableCollection<Element>: Collection
public protocol BidirectionalCollection<Element>: Collection
public protocol RandomAccessCollection<Element>: BidirectionalCollection
public protocol RangeReplaceableCollection<Element>: Collection

public protocol RawRepresentable<RawValue>
public protocol RangeExpression<Bound>
public protocol Strideable<Stride>: Comparable

public prococol SetAlgebra<Element>: Equatable, ExpressibleByArrayLiteral
public protocol OptionSet<Element>: SetAlgebra, RawRepresentable

public protocol SIMD<Scalar>: ...

public protocol Clock<Duration>: Sendable
public protocol InstantProtocol<Duration>: Comparable, Hashable, Sendable
```

## Source compatibility

None. The new annotations enable new ways to use these protocols, but
they are tied to new syntax, and they do not affect existing code.

## Effect on ABI stability

None. The annotations aren't ABI impacting, and the new capabilities
deploy back to any previous Swift Standard Library release.

## Effect on API resilience

Once introduced, primary associated types cannot be removed from a
protocol or reordered without breaking source compatibility.

[SE-0346] requires usage sites to always list every primary associated
type defined by a protocol. Until/unless this restriction is lifted,
adding a new primary associated type to a protocol that already has
some will also be a source breaking change.

Therefore, we will not be able to make any changes to the list of
primary associated types of any of the protocols that are affected by
this proposal once this ships in a Standard Library release.

## Alternatives considered

(1) It is tempting to declare `Element` as the primary associated type for `LazySequenceProtocol` and `LazyCollectionProtocol`, for consistency with other protocols in the collection hierarchy. However, in actual use, `Elements` seems just as useful (if not more) to be easily constrained. We left the matter of selecting one of these as primary unresolved for now; as we get more experience with lightweight same-type requirements, we may revisit these protocols.

(2) `AsyncSequence` and `AsyncIteratorProtocol` logically ought to have `Element` as their primary associated type. However, we have [ongoing evolution discussions][rethrows] about adding a precise error type to these. If those discussions bear fruit, then it's possible we may want to _also_ mark the potential new `Error` associated type as primary. To prevent source compatibility complications, adding primary associated types to these two protocols is deferred to a future proposal.

[rethrows]: https://forums.swift.org/t/se-0346-lightweight-same-type-requirements-for-primary-associated-types/55869/70
