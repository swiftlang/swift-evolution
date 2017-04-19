# String Revision: Collection Conformance, C Interop, Transcoding

* Proposal: [SE-0163](0163-string-revision-1.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift), [Dave Abrahams](http://github.com/dabrahams/)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Accepted with revisions**

## Introduction

This proposal is to implement a subset of the changes from the [Swift 4
String
Manifesto](https://github.com/apple/swift/blob/master/docs/StringManifesto.md).

Specifically:

 * Make `String` conform to `BidirectionalCollection`
 * Make `String` conform to `RangeReplaceableCollection` 
 * Create a `Substring` type for `String.SubSequence`
 * Create a `Unicode` protocol to allow for generic operations over both types.
 * Consolidate on a concise set of C interop methods.
 * Revise the transcoding infrastructure.

Other existing aspects of `String` remain unchanged for the purposes of this 
proposal.

## Motivation

This proposal follows up on a number of recommendations found in the manifesto:

`Collection` conformance was dropped from `String` in Swift 2. After
reevaluation, the feeling is that the minor semantic discrepancies (mainly with
`RangeReplaceableCollection`) are outweighed by the significant benefits of
restoring these conformances. For more detail on the reasoning, see
[here](https://github.com/apple/swift/blob/master/docs/StringManifesto.md#string-should-be-a-collection-of-characters-again)

While it is not a collection, the Swift 3 string does have slicing operations.
`String` is currently serving as its own subsequence, allowing  substrings
to share storage with their "owner". This can lead to memory leaks when small substrings of larger
strings are stored long-term (see [here](https://github.com/apple/swift/blob/master/docs/StringManifesto.md#substrings)
for more detail on this problem). Introducing a separate type of `Substring` to
serve as `String.Subsequence` is recommended to resolve this issue, in a similar
fashion to `ArraySlice`.

As noted in the manifesto, support for interoperation with nul-terminated C
strings in Swift 3 is scattered and incoherent, with 6 ways to transform a C
string into a `String` and four ways to do the inverse. These APIs should be
replaced with a simpler set of methods on `String`.

## Proposed solution

A new type, `Substring`, will be introduced. Similar to `ArraySlice` it will
be documented as only for short- to medium-term storage:

> **Important**
>
> Long-term storage of `Substring` instances is discouraged. A substring holds a
> reference to the entire storage of a larger string, not just to the portion it
> presents, even after the original string’s lifetime ends. Long-term storage of
> a substring may therefore prolong the lifetime of elements that are no longer
> otherwise accessible, which can appear to be memory leakage.

Aside from minor differences, such as having a `SubSequence` of `Self` and a
larger size to describe the range of the subsequence, `Substring`
will be near-identical from a user perspective.

In order to be able to write extensions accross both `String` and `Substring`,
a new `Unicode` protocol to which the two types will conform will be
introduced. For the purposes of this proposal, `Unicode` will be defined as a
protocol to be used whenver you would previously extend `String`. It should be
possible to substitute `extension Unicode { ... }` in Swift 4 wherever
`extension String { ... }` was written in Swift 3, with one exception: any
passing of `self` into an API that takes a concrete `String` will need to be
rewritten as `String(self)`. If `Self` is a `String` then this should
effectively optimize to a no-op, whereas if `Self` is a `Substring` then this
will force a copy, helping to avoid the "memory leak" problems described above.

The exact nature of the protocol – such as which methods should be protocol
requirements vs which can be implemented as protocol extensions, are considered
implementation details and so not covered in this proposal.

`Unicode` will conform to `BidirectionalCollection`.
`RangeReplaceableCollection` conformance will be added directly onto the
`String` and `Substring` types, as it is possible future `Unicode`-conforming
types might not be range-replaceable (e.g. an immutable type that wraps 
a `const char *`).

The C string interop methods will be updated to those described
[here](https://github.com/apple/swift/blob/master/docs/StringManifesto.md#c-string-interop):
a single `withCString` operation and two `init(cString:)` constructors, one for
UTF8 and one for arbitrary encodings. The primary change is to remove
"non-repairing" variants of construction from nul-terminated C strings. In both
of the construction APIs, any invalid encoding sequence detected will have its
longest valid prefix replaced by `U+FFFD`, the Unicode replacement character,
per the Unicode specification. This covers the common case. The replacement is
done physically in the underlying storage and the validity of the result is
recorded in the String's encoding such that future accesses need not be slowed
down by possible error repair separately. Construction that is aborted when
encoding errors are detected can be accomplished using APIs on the encoding.

The current transcoding support will be updated to improve usability and
performance. The primary changes will be:

 - to allow transcoding directly from one encoding to another without having
   to triangulate through an intermediate scalar value
 - to add the ability to transcode an input collection in reverse, allowing the
   different views on `String` to be made bi-directional
 - to have decoding take a collection rather than an iterator, and return an
   index of its progress into the source, allowing that method to be static

The standard library currently lacks a `Latin1` codec, so a 
`enum Latin1: UnicodeEncoding` type will be added.

## Detailed design

The following additions will be made to the standard library:

```swift
protocol Unicode: BidirectionalCollection {
  // Implementation detail as described above
}

extension String: Unicode, RangeReplaceableCollection {
  typealias SubSequence = Substring
}

struct Substring: Unicode, RangeReplaceableCollection {
  typealias SubSequence = Substring
  // near-identical API surface area to String
}
```

The subscript operations on `String` will be amended to return `Substring`:

```swift
struct String {
  subscript(bounds: Range<String.Index>) -> Substring { get }
  subscript(bounds: ClosedRange<String.Index>) -> Substring { get }
}
```

Note that properties or methods that due to their nature create new `String`
storage (such as `lowercased()`) will _not_ change.

C string interop will be consolidated on the following methods:

```swift
extension String {
  /// Constructs a `String` having the same contents as `nulTerminatedUTF8`.
  ///
  /// - Parameter nulTerminatedUTF8: a sequence of contiguous UTF-8 encoded 
  ///   bytes ending just before the first zero byte (NUL character).
  init(cString nulTerminatedUTF8: UnsafePointer<CChar>)
  
  /// Constructs a `String` having the same contents as `nulTerminatedCodeUnits`.
  ///
  /// - Parameter nulTerminatedCodeUnits: a sequence of contiguous code units in
  ///   the given `encoding`, ending just before the first zero code unit.
  /// - Parameter encoding: describes the encoding in which the code units
  ///   should be interpreted.
  init<Encoding: UnicodeEncoding>(
    cString nulTerminatedCodeUnits: UnsafePointer<Encoding.CodeUnit>,
    encoding: Encoding)
    
  /// Invokes the given closure on the contents of the string, represented as a
  /// pointer to a null-terminated sequence of UTF-8 code units.
  func withCString<Result>(
    _ body: (UnsafePointer<CChar>) throws -> Result) rethrows -> Result
}
```

Additionally, the current ability to pass a Swift `String` into C methods that
take a C string will remain as-is.

A new protocol, `UnicodeEncoding`, will be added to replace the current 
`UnicodeCodec` protocol:

```swift
public enum UnicodeParseResult<T, Index> {
/// Indicates valid input was recognized.
///
/// `resumptionPoint` is the end of the parsed region
case valid(T, resumptionPoint: Index)  // FIXME: should these be reordered?
/// Indicates invalid input was recognized.
///
/// `resumptionPoint` is the next position at which to continue parsing after
/// the invalid input is repaired.
case error(resumptionPoint: Index)

/// Indicates that there was no more input to consume.
case emptyInput

  /// If any input was consumed, the point from which to continue parsing.
  var resumptionPoint: Index? {
    switch self {
    case .valid(_,let r): return r
    case .error(let r): return r
    case .emptyInput: return nil
    }
  }
}

/// An encoding for text with UnicodeScalar as a common currency type
public protocol UnicodeEncoding {
  /// The maximum number of code units in an encoded unicode scalar value
  static var maxLengthOfEncodedScalar: Int { get }
  
  /// A type that can represent a single UnicodeScalar as it is encoded in this
  /// encoding.
  associatedtype EncodedScalar : EncodedScalarProtocol

  /// Produces a scalar of this encoding if possible; returns `nil` otherwise.
  static func encode<Scalar: EncodedScalarProtocol>(
    _:Scalar) -> Self.EncodedScalar?
  
  /// Parse a single unicode scalar forward from `input`.
  ///
  /// - Parameter knownCount: a number of code units known to exist in `input`.
  ///   **Note:** passing a known compile-time constant is strongly advised,
  ///   even if it's zero.
  static func parseScalarForward<C: Collection>(
    _ input: C, knownCount: Int /* = 0, via extension */
  ) -> ParseResult<EncodedScalar, C.Index>
  where C.Iterator.Element == EncodedScalar.Iterator.Element

  /// Parse a single unicode scalar in reverse from `input`.
  ///
  /// - Parameter knownCount: a number of code units known to exist in `input`.
  ///   **Note:** passing a known compile-time constant is strongly advised,
  ///   even if it's zero.
  static func parseScalarReverse<C: BidirectionalCollection>(
    _ input: C, knownCount: Int /* = 0 , via extension */
  ) -> ParseResult<EncodedScalar, C.Index>
  where C.Iterator.Element == EncodedScalar.Iterator.Element
}

/// Parsing multiple unicode scalar values
extension UnicodeEncoding {
  @discardableResult
  public static func parseForward<C: Collection>(
    _ input: C,
    repairingIllFormedSequences makeRepairs: Bool = true,
    into output: (EncodedScalar) throws->Void
  ) rethrows -> (remainder: C.SubSequence, errorCount: Int)
  
  @discardableResult    
  public static func parseReverse<C: BidirectionalCollection>(
    _ input: C,
    repairingIllFormedSequences makeRepairs: Bool = true,
    into output: (EncodedScalar) throws->Void
  ) rethrows -> (remainder: C.SubSequence, errorCount: Int)
  where C.SubSequence : BidirectionalCollection,
        C.SubSequence.SubSequence == C.SubSequence,
        C.SubSequence.Iterator.Element == EncodedScalar.Iterator.Element
}
```


`UnicodeCodec` will be updated to refine `UnicodeEncoding`, and all
existing codecs will conform to it.

Note, depending on whether this change lands before or after some of the
generics features, generic `where` clauses may need to be added temporarily.

## Source compatibility

Adding collection conformance to `String` should not materially impact source
stability as it is purely additive: Swift 3's `String` interface currently
fulfills all of the requirements for a bidirectional range replaceable
collection.

Altering `String`'s slicing operations to return a different type is source
breaking. The following mitigating steps are proposed:

 - Add a deprecated subscript operator that will run in Swift 3 compatibility
   mode and which will return a `String` not a `Substring`.
 
 - Add deprecated versions of all current slicing methods to similarly return a
   `String`.
   
i.e.:

```swift
extension String {
  @available(swift, obsoleted: 4)
  subscript(bounds: Range<Index>) -> String {
    return String(characters[bounds])
  }

  @available(swift, obsoleted: 4)
  subscript(bounds: ClosedRange<Index>) -> String {
    return String(characters[bounds])
  }
}
```       

In a review of 77 popular Swift projects found on GitHub, these changes
resolved any build issues in the 12 projects that assumed an explicit `String`
type returned from slicing operations.

Due to the change in internal implementation, this means that these operations
will be _O(n)_ rather than _O(1)_. This is not expected to be a major concern,
based on experiences from a similar change made to Java, but projects will be
able to work around performance issues without upgrading to Swift 4 by
explicitly typing slices as `Substring`, which will call the Swift 4 variant,
and which will be available but not invoked by default in Swift 3 mode.

The C string interoperability methods outside the ones described in the
detailed design will remain in Swift 3 mode, be deprecated in Swift 4 mode, and
be removed in a subsequent release. `UnicodeCodec` will be similarly deprecated.

## Effect on ABI stability

As a fundamental currency type for Swift, it is essential that the `String`
type (and its associated subsequence) is in a good long-term state before being
locked down when Swift declares ABI stability. Shrinking the size of `String`
to be 64 bits is an important part of this.

## Effect on API resilience

Decisions about the API resilience of the `String` type are still to be
determined, but are not adversely affected by this proposal.

## Alternatives considered

For a more in-depth discussion of some of the trade-offs in string design, see
the manifesto and associated [evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170116/thread.html#30497).

This proposal does not yet introduce an implicit conversion from `Substring` to
`String`. The decision on whether to add this will be deferred pending feedback
on the initial implementation. The intention is to make a preview toolchain
available for feedback, including on whether this implicit conversion is
necessary, prior to the release of Swift 4.

Several of the types related to `String`, such as the encodings, would ideally
reside inside a namespace rather than live at the top level of the standard
library. The best namespace for this is probably `Unicode`, but this is also
the name of the protocol. At some point if we gain the ability to nest enums
and types inside protocols, they should be moved there. Putting them inside
`String` or some other enum namespace is probably not worthwhile in the
mean-time.


