<!-- utf8span.md -->

# UTF8Span: Safe UTF-8 Processing Over Contiguous Bytes

* Proposal: [SE-NNNN](nnnn-utf8-span.md)
* Authors: [Michael Ilseman](https://github.com/milseman), [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: rdar://48132971, rdar://96837923
* Implementation: https://github.com/swiftlang/swift/pull/78531
* Upcoming Feature Flag:
* Review: ([pitch 1](https://forums.swift.org/t/pitch-utf-8-processing-over-unsafe-contiguous-bytes/69715)) ([pitch 2](https://forums.swift.org/t/pitch-safe-utf-8-processing-over-contiguous-bytes/72742))


## Introduction

We introduce `UTF8Span` for efficient and safe Unicode processing over contiguous storage. `UTF8Span` is a memory safe non-escapable type [similar to `Span`](https://github.com/swiftlang/swift-evolution/pull/2307).

Native `String`s are stored as validly-encoded UTF-8 bytes in an internal contiguous memory buffer. The standard library implements `String`'s API as internal methods which operate on top of this buffer, taking advantage of the validly-encoded invariant and specialized Unicode knowledge. We propose making this UTF-8 buffer and its methods public as API for more advanced libraries and developers.

## Motivation

Currently, if a developer wants to do `String`-like processing over UTF-8 bytes, they have to make an instance of `String`, which allocates a native storage class, copies all the bytes, and is reference counted. The developer would then need to operate within the new `String`'s views and map between `String.Index` and byte offsets in the original buffer.

For example, if these bytes were part of a data structure, the developer would need to decide to either cache such a new `String` instance or recreate it on the fly. Caching more than doubles the size and adds caching complexity. Recreating it on the fly adds a linear time factor and class instance allocation/deallocation and potentially reference counting.

Furthermore, `String` may not be fully available on tightly constrained platforms, especially those that cannot support allocations. Both `String` and `UTF8Span` have some API that require Unicode data tables and that might not be available on embedded (String via its conformance to `Comparable` and `Collection` depend on these data tables while `UTF8Span` has a couple of methods that will be unavailable).

### UTF-8 validity and efficiency

UTF-8 validation is a particularly common concern and the subject of a fair amount of [research](https://lemire.me/blog/2020/10/20/ridiculously-fast-unicode-utf-8-validation/). Once an input is known to be validly encoded UTF-8, subsequent operations such as decoding, grapheme breaking, comparison, etc., can be implemented much more efficiently under this assumption of validity. Swift's `String` type's native storage is guaranteed-valid-UTF8 for this reason.

Failure to guarantee UTF-8 encoding validity creates security and safety concerns. With invalidly-encoded contents, memory safety would become more nuanced. An ill-formed leading byte can dictate a scalar length that is longer than the memory buffer. The buffer may have bounds associated with it, which differs from the bounds dictated by its contents.

Additionally, a particular scalar value in valid UTF-8 has only one encoding, but invalid UTF-8 could have the same value encoded as an [overlong encoding](https://en.wikipedia.org/wiki/UTF-8#Overlong_encodings), which would compromise code that checks for the presence of a scalar value by looking at the encoded bytes (or that does a byte-wise comparison).


## Proposed solution

We propose a non-escapable `UTF8Span` which exposes `String` functionality for validly-encoded UTF-8 code units in contiguous memory. We also propose rich API describing the kind and location of encoding errors.

## Detailed design

`UTF8Span` is a borrowed view into contiguous memory containing validly-encoded UTF-8 code units.

```swift
@frozen
public struct UTF8Span: Copyable, ~Escapable {
  **TODO**: This might end up being UnsafeRawPointer? like in Span
  public var unsafeBaseAddress: UnsafeRawPointer

  /*
   A bit-packed count and flags (such as isASCII)

   ╔═══════╦═════╦═════╦══════════╦═══════╗
   ║  b63  ║ b62 ║ b61 ║  b60:56  ║ b56:0 ║
   ╠═══════╬═════╬═════╬══════════╬═══════╣
   ║ ASCII ║ NFC ║ SSC ║ reserved ║ count ║
   ╚═══════╩═════╩═════╩══════════╩═══════╝

   ASCII means the contents are all-ASCII (<0x7F).
   NFC means contents are in normal form C for fast comparisons.
   SSC means single-scalar Characters (i.e. grapheme clusters): every
     `Character` holds only a single `Unicode.Scalar`.
   */
  @usableFromInline
  internal var _countAndFlags: UInt64
}

```

<!--
```
TODO: fix below init

  @inlinable @inline(__always)
  init<Owner: ~Copyable & ~Escapable>(
    _unsafeAssumingValidUTF8 start: UnsafeRawPointer,
    _countAndFlags: UInt64,
    owner: borrowing Owner
  ) -> dependsOn(owner) Self { }
}

```
-->

### UTF-8 validation

We propose new API for identifying where and what kind of encoding errors are present in UTF-8 content.

```swift
extension Unicode.UTF8 {
  /**

   The kind and location of a UTF-8 encoding error.

   Valid UTF-8 is represented by this table:

   ╔════════════════════╦════════╦════════╦════════╦════════╗
   ║    Scalar value    ║ Byte 0 ║ Byte 1 ║ Byte 2 ║ Byte 3 ║
   ╠════════════════════╬════════╬════════╬════════╬════════╣
   ║ U+0000..U+007F     ║ 00..7F ║        ║        ║        ║
   ║ U+0080..U+07FF     ║ C2..DF ║ 80..BF ║        ║        ║
   ║ U+0800..U+0FFF     ║ E0     ║ A0..BF ║ 80..BF ║        ║
   ║ U+1000..U+CFFF     ║ E1..EC ║ 80..BF ║ 80..BF ║        ║
   ║ U+D000..U+D7FF     ║ ED     ║ 80..9F ║ 80..BF ║        ║
   ║ U+E000..U+FFFF     ║ EE..EF ║ 80..BF ║ 80..BF ║        ║
   ║ U+10000..U+3FFFF   ║ F0     ║ 90..BF ║ 80..BF ║ 80..BF ║
   ║ U+40000..U+FFFFF   ║ F1..F3 ║ 80..BF ║ 80..BF ║ 80..BF ║
   ║ U+100000..U+10FFFF ║ F4     ║ 80..8F ║ 80..BF ║ 80..BF ║
   ╚════════════════════╩════════╩════════╩════════╩════════╝

   ### Classifying errors

   An *unexpected continuation* is when a continuation byte (`10xxxxxx`) occurs
   in a position that should be the start of a new scalar value. Unexpected
   continuations can often occur when the input contains arbitrary data
   instead of textual content. An unexpected continuation at the start of
   input might mean that the input was not correctly sliced along scalar
   boundaries or that it does not contain UTF-8.

   A *truncated scalar* is a multi-byte sequence that is the start of a valid
   multi-byte scalar but is cut off before ending correctly. A truncated
   scalar at the end of the input might mean that only part of the entire
   input was received.

   A *surrogate code point* (`U+D800..U+DFFF`) is invalid UTF-8. Surrogate
   code points are used by UTF-16 to encode scalars in the supplementary
   planes. Their presence may mean the input was encoded in a different 8-bit
   encoding, such as CESU-8, WTF-8, or Java's Modified UTF-8.

   An *invalid non-surrogate code point* is any code point higher than
   `U+10FFFF`. This can often occur when the input is arbitrary data instead
   of textual content.

   An *overlong encoding* occurs when a scalar value that could have been
   encoded using fewer bytes is encoded in a longer byte sequence. Overlong
   encodings are invalid UTF-8 and can lead to security issues if not
   correctly detected:

   - https://nvd.nist.gov/vuln/detail/CVE-2008-2938
   - https://nvd.nist.gov/vuln/detail/CVE-2000-0884

   An overlong encoding of `NUL`, `0xC0 0x80`, is used in Java's Modified
   UTF-8 but is invalid UTF-8. Overlong encoding errors often catch attempts
   to bypass security measures.

   ### Reporting the range of the error

   The range of the error reported follows the *Maximal subpart of an
   ill-formed subsequence* algorithm in which each error is either one byte
   long or ends before the first byte that is disallowed. See "U+FFFD
   Substitution of Maximal Subparts" in the Unicode Standard. Unicode started
   recommending this algorithm in version 6 and is adopted by the W3C.

   The maximal subpart algorithm will produce a single multi-byte range for a
   truncated scalar (a multi-byte sequence that is the start of a valid
   multi-byte scalar but is cut off before ending correctly). For all other
   errors (including overlong encodings, surrogates, and invalid code
   points), it will produce an error per byte.

   Since overlong encodings, surrogates, and invalid code points are erroneous
   by the second byte (at the latest), the above definition produces the same
   ranges as defining such a sequence as a truncated scalar error followed by
   unexpected continuation byte errors. The more semantically-rich
   classification is reported.

   For example, a surrogate count point sequence `ED A0 80` will be reported
   as three `.surrogateCodePointByte` errors rather than a `.truncatedScalar`
   followed by two `.unexpectedContinuationByte` errors.

   Other commonly reported error ranges can be constructed from this result.
   For example, PEP 383's error-per-byte can be constructed by mapping over
   the reported range. Similarly, constructing a single error for the longest
   invalid byte range can be constructed by joining adjacent error ranges.

   ╔═════════════════╦══════╦═════╦═════╦═════╦═════╦═════╦═════╦══════╗
   ║                 ║  61  ║ F1  ║ 80  ║ 80  ║ E1  ║ 80  ║ C2  ║  62  ║
   ╠═════════════════╬══════╬═════╬═════╬═════╬═════╬═════╬═════╬══════╣
   ║ Longest range   ║ U+61 ║ err ║     ║     ║     ║     ║     ║ U+62 ║
   ║ Maximal subpart ║ U+61 ║ err ║     ║     ║ err ║     ║ err ║ U+62 ║
   ║ Error per byte  ║ U+61 ║ err ║ err ║ err ║ err ║ err ║ err ║ U+62 ║
   ╚═════════════════╩══════╩═════╩═════╩═════╩═════╩═════╩═════╩══════╝

   */
  @frozen
  public struct EncodingError: Error, Sendable, Hashable, Codable {
    /// The kind of encoding error
    public var kind: Unicode.UTF8.EncodingError.Kind

    /// The range of offsets into our input containing the error
    public var range: Range<Int>

    @_alwaysEmitIntoClient
    public init(
      _ kind: Unicode.UTF8.EncodingError.Kind,
      _ range: some RangeExpression<Int>
    )

    @_alwaysEmitIntoClient
    public init(_ kind: Unicode.UTF8.EncodingError.Kind, at: Int)
  }
}

extension UTF8.EncodingError {
  /// The kind of encoding error encountered during validation
  @frozen
  public struct Kind: Error, Sendable, Hashable, Codable, RawRepresentable {
    public var rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8)

    /// A continuation byte (`10xxxxxx`) outside of a multi-byte sequence
    @_alwaysEmitIntoClient
    public static var unexpectedContinuationByte: Self

    /// A byte in a surrogate code point (`U+D800..U+DFFF`) sequence
    @_alwaysEmitIntoClient
    public static var surrogateCodePointByte: Self

    /// A byte in an invalid, non-surrogate code point (`>U+10FFFF`) sequence
    @_alwaysEmitIntoClient
    public static var invalidNonSurrogateCodePointByte: Self

    /// A byte in an overlong encoding sequence
    @_alwaysEmitIntoClient
    public static var overlongEncodingByte: Self

    /// A multi-byte sequence that is the start of a valid multi-byte scalar
    /// but is cut off before ending correctly
    @_alwaysEmitIntoClient
    public static var truncatedScalar: Self
  }
}

@_unavailableInEmbedded
extension UTF8.EncodingError.Kind: CustomStringConvertible {
  public var description: String { get }
}

@_unavailableInEmbedded
extension UTF8.EncodingError: CustomStringConvertible {
  public var description: String { get }
}
```

**QUESTION**: It would be good to expose this functionality via a general purpose validation API. Question is do we want a `findFirstError` or `findAllErrors` style API, both? E.g.:

```swift
extension UTF8 {
  public static func checkForError(
    _ s: some Sequence<UInt8>
  ) -> some UTF8.EncodingError {

  ... or

  public static func checkForAllErrors(
    _ s: some Sequence<UInt8>
  ) -> some Sequence<UTF8.EncodingError> {
```


### Creation and validation

`UTF8Span` is validated at initialization time and encoding errors are diagnosed and thrown.


```swift

extension UTF8Span {
  @lifetime(codeUnits)
  public init(
    _validating codeUnits: consuming Span<UInt8>
  ) throws(UTF8.EncodingError) {

  @lifetime(borrow start)
  internal init(
    _unsafeAssumingValidUTF8 start: borrowing UnsafeRawPointer,
    _countAndFlags: UInt64
  )
}
```

**NOTE**: The final status of underscores, annotations, etc., are pending things like [SE-0456](https://forums.swift.org/t/se-0456-add-span-providing-properties-to-standard-library-types/77233/17) and [Lifetime Dependencies](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency/69865/140).


### Scalar processing

We propose a `UTF8Span.ScalarIterator` type that can do scalar processing forwards and backwards. Note that `ScalarIterator` itself is non-escapable, and thus cannot conform to `IteratorProtocol`, etc.

```swift
extension UTF8Span {
  public func _makeScalarIterator() -> ScalarIterator

  /// Iterate the `Unicode.Scalar`s  contents of a `UTF8Span`.
  public struct ScalarIterator: ~Escapable {
    public var codeUnits: UTF8Span

    /// The byte offset of the start of the next scalar. This is
    /// always scalar-aligned.
    public var currentCodeUnitOffset: Int { get }

    public init(_ codeUnits: UTF8Span)

    /// Decode and return the scalar starting at `currentCodeUnitOffset`.
    /// After the function returns, `currentCodeUnitOffset` holds the
    /// position at the end of the returned scalar, which is also the start
    /// of the next scalar.
    ///
    /// Returns `nil` if at the end of the `UTF8Span`.
    public mutating func next() -> Unicode.Scalar?

    /// Decode and return the scalar ending at `currentCodeUnitOffset`. After
    /// the function returns, `currentCodeUnitOffset` holds the position at
    /// the start of the returned scalar, which is also the end of the
    /// previous scalar.
    ///
    /// Returns `nil` if at the start of the `UTF8Span`.
    public mutating func previous() -> Unicode.Scalar?

    /// Advance `codeUnitOffset` to the end of the current scalar, without
    /// decoding it.
    ///
    /// Returns the number of `Unicode.Scalar`s skipped over, which can be 0
    /// if at the end of the UTF8Span.
    public mutating func skipForward() -> Int

    /// Advance `codeUnitOffset` to the end of `n` scalars, without decoding
    /// them.
    ///
    /// Returns the number of `Unicode.Scalar`s skipped over, which can be
    /// fewer than `n` if at the end of the UTF8Span.
    public mutating func skipForward(by n: Int) -> Int

    /// Move `codeUnitOffset` to the start of the previous scalar, without
    /// decoding it.
    ///
    /// Returns the number of `Unicode.Scalar`s skipped over, which can be 0
    /// if at the start of the UTF8Span.
    public mutating func skipBack() -> Bool

    /// Move `codeUnitOffset` to the start of the previous `n` scalars,
    /// without decoding them.
    ///
    /// Returns the number of `Unicode.Scalar`s skipped over, which can be
    /// fewer than `n` if at the start of the UTF8Span.
    public mutating func skipBack(by n: Int) -> Bool

    /// Reset to the nearest scalar-aligned code unit offset `<= i`.
    ///
    /// **TODO**: Example
    public mutating func reset(roundingBackwardsFrom i: Int)

    /// Reset to the nearest scalar-aligned code unit offset `>= i`.
    ///
    /// **TODO**: Example
    public mutating func reset(roundingForwardsFrom i: Int)

    /// Reset this iterator to code unit offset `i`, skipping _all_ safety
    /// checks.
    ///
    /// Note: This is only for very specific, low-level use cases. If
    /// `codeUnitOffset` is not properly scalar-aligned, this function can
    /// result in undefined behavior when, e.g., `next()` is called.
    ///
    /// For example, this could be used by a regex engine to backtrack to a
    /// known-valid previous position.
    ///
    public mutating func reset(uncheckedAssumingAlignedTo i: Int)

    /// Returns the UTF8Span containing all the content up to the iterator's
    /// current position.
    public func _prefix() -> UTF8Span

    /// Returns the UTF8Span containing all the content after the iterator's
    /// current position.
    public func _suffix() -> UTF8Span
  }
}

```

**QUESTION**: Is it worth also surfacing as `isScalarAligned` API on `UTF8Span` so it's a little easier to find and spell (as well as talk about in doc comments)?


### Character processing

We similarly propose a `UTF8Span.CharacterIterator` type that can do grapheme-breaking forwards and backwards.

The `CharacterIterator` assumes that the start and end of the `UTF8Span` is the start and end of content. 

Any scalar-aligned position is a valid place to start or reset the grapheme-breaking algorithm to, though you could get different `Character` output if if resetting to a position that isn't `Character`-aligned relative to the start of the `UTF8Span` (e.g. in the middle of a series of regional indicators).

<!--

```
    /// **QUESTION**: The notion of `Character` aligned is complex. It can be
    ///   defined as the same as scalar-aligned, as you can run the algorithm
    ///   from any scalar position and get the emergent behavior, even if
    ///   that position would split a `Character` as processed from another
    ///   position. For example, when starting grapheme breaking in the
    ///   middle of a long run of paired regional indicators, you can start
    ///   from odd or even offsets and get different flag emoji out. That can
    ///   occasionally be useful, but can yield counter intuitive results.
    ///
    ///   While we talk about code unit offsets always being scalar-aligned,
    ///   we could go further to talk about `Character` aligned indices 
    ///   (where `Character`-alignment is relative to the start of the 
    ///   `UTF8Span`) and have API for those.

```

-->  

```swift
@_unavailableInEmbedded
extension UTF8Span {
  public func _makeCharacterIterator() -> CharacterIterator

  /// Iterate the `Character` contents of a `UTF8Span`.
  public struct CharacterIterator: ~Escapable {
    public var codeUnits: UTF8Span

    /// The byte offset of the start of the next `Character`. This is 
    /// always scalar-aligned and `Character`-aligned.
    public var currentCodeUnitOffset: Int { get }

    public init(_ span: UTF8Span)

    /// Return the `Character` starting at `currentCodeUnitOffset`. After the
    /// function returns, `currentCodeUnitOffset` holds the position at the
    /// end of the `Character`, which is also the start of the next
    /// `Character`. 
    ///
    /// Returns `nil` if at the end of the `UTF8Span`.
    public mutating func next() -> Character?

    /// Return the `Character` ending at `currentCodeUnitOffset`. After the
    /// function returns, `currentCodeUnitOffset` holds the position at the
    /// start of the returned `Character`, which is also the end of the
    /// previous `Character`. 
    ///
    /// Returns `nil` if at the start of the `UTF8Span`.
    public mutating func previous() -> Character?

    /// Advance `codeUnitOffset` to the end of the current `Character`,
    /// without constructing it.
    ///
    /// Returns the number of `Character`s skipped over, which can be 0
    /// if at the end of the UTF8Span.
    public mutating func skipForward()

    /// Advance `codeUnitOffset` to the end of `n` `Characters`, without
    /// constructing them.
    ///
    /// Returns the number of `Character`s skipped over, which can be
    /// fewer than `n` if at the end of the UTF8Span.
    public mutating func skipForward(by n: Int)

    /// Move `codeUnitOffset` to the start of the previous `Character`,
    /// without constructing it.
    ///
    /// Returns the number of `Character`s skipped over, which can be 0
    /// if at the start of the UTF8Span.
    public mutating func skipBack()

    /// Move `codeUnitOffset` to the start of the previous `n` `Character`s,
    /// without constructing them.
    ///
    /// Returns the number of `Character`s skipped over, which can be
    /// fewer than `n` if at the start of the UTF8Span.
    public mutating func skipBack(by n: Int)

    /// Reset to the nearest character-aligned position `<= i`.
    public mutating func reset(roundingBackwardsFrom i: Int)

    /// Reset to the nearest character-aligned position `>= i`.
    public mutating func reset(roundingForwardsFrom i: Int)

    /// Reset this iterator to code unit offset `i`, skipping _all_ safety
    /// checks.
    ///
    /// Note: This is only for very specific, low-level use cases. If
    /// `codeUnitOffset` is not properly scalar-aligned, this function can
    /// result in undefined behavior when, e.g., `next()` is called. 
    ///
    /// If `i` is scalar-aligned, but not `Character`-aligned, you may get
    /// different results from running `Character` iteration.
    ///
    /// For example, this could be used by a regex engine to backtrack to a
    /// known-valid previous position.
    ///
    public mutating func reset(uncheckedAssumingAlignedTo i: Int)

    /// Returns the UTF8Span containing all the content up to the iterator's
    /// current position.
    public func prefix() -> UTF8Span

    /// Returns the UTF8Span containing all the content after the iterator's
    /// current position.
    public func suffix() -> UTF8Span
  }

}
```

### Comparisons

The content of a `UTF8Span` can be compared in a number of ways, including literally (byte semantics) and Unicode canonical equivalence.

```swift
extension UTF8Span {
  /// Whether this span has the same bytes as `other`.
  @_alwaysEmitIntoClient
  public func bytesEqual(to other: UTF8Span) -> Bool

  /// Whether this span has the same bytes as `other`.
  @_alwaysEmitIntoClient
  public func bytesEqual(to other: some Sequence<UInt8>) -> Bool

  /// Whether this span has the same `Unicode.Scalar`s as `other`.
  @_alwaysEmitIntoClient
  public func scalarsEqual(
    to other: some Sequence<Unicode.Scalar>
  ) -> Bool

  /// Whether this span has the same `Character`s as `other`, using
  /// `Character.==` (i.e. Unicode canonical equivalence).
  @_unavailableInEmbedded
  @_alwaysEmitIntoClient
  public func charactersEqual(
    to other: some Sequence<Character>
  ) -> Bool
}
```

We also support literal (i.e. non-canonical) pattern matching against `StaticString`.

```swift
extension UTF8Span {
  static func ~=(_ lhs: UTF8Span, _ rhs: StaticString) -> Bool
}
```

#### Canonical equivalence and ordering

`UTF8Span` can perform Unicode canonical equivalence checks (i.e. the semantics of `String.==` and `Character.==`).

```swift
extension UTF8Span {
  /// Whether `self` is equivalent to `other` under Unicode Canonical
  /// Equivalence.
  @_unavailableInEmbedded
  public func isCanonicallyEquivalent(
    to other: UTF8Span
  ) -> Bool

  /// Whether `self` orders less than `other` under Unicode Canonical
  /// Equivalence using normalized code-unit order (in NFC).
  @_unavailableInEmbedded
  public func isCanonicallyLessThan(
    _ other: UTF8Span
  ) -> Bool
}
```

#### Extracting sub-spans

Slicing a `UTF8Span` is nuanced and depends on the caller's desired use. They can only be sliced at scalar-aligned code unit offsets or else it will break the valid-UTF8 invariant. Furthermore, if the caller desires consistent grapheme breaking behavior without externally managing grapheme breaking state, they must be sliced along `Character` boundaries. For this reason, we have exposed slicing as `prefix` and `suffix` operations on `UTF8Span`'s iterators instead of `Span`'s' `extracting` methods.

### Queries

`UTF8Span` checks at construction time and remembers whether its contents are all ASCII. Additional checks can be requested and remembered.

```swift
extension UTF8Span {
  /// Returns whether the validated contents were all-ASCII. This is checked at
  /// initialization time and remembered.
  @inlinable
  public var isASCII: Bool { get }

  /// Returns whether the contents are known to be NFC. This is not
  /// always checked at initialization time and is set by `checkForNFC`.
  @inlinable
  @_unavailableInEmbedded
  public var isKnownNFC: Bool { get }

  /// Do a scan checking for whether the contents are in Normal Form C.
  /// When the contents are in NFC, canonical equivalence checks are much
  /// faster.
  ///
  /// `quickCheck` will check for a subset of NFC contents using the
  /// NFCQuickCheck algorithm, which is faster than the full normalization
  /// algorithm. However, it cannot detect all NFC contents.
  ///
  /// Updates the `isKnownNFC` bit.
  @_unavailableInEmbedded
  public mutating func checkForNFC(
    quickCheck: Bool
  ) -> Bool

  /// Returns whether every `Character` (i.e. grapheme cluster)
  /// is known to be comprised of a single `Unicode.Scalar`.
  ///
  /// This is not always checked at initialization time. It is set by
  /// `checkForSingleScalarCharacters`.
  @_unavailableInEmbedded
  @inlinable
  public var isKnownSingleScalarCharacters: Bool { get }

  /// Do a scan, checking whether every `Character` (i.e. grapheme cluster)
  /// is comprised of only a single `Unicode.Scalar`. When a span contains
  /// only single-scalar characters, character operations are much faster.
  ///
  /// `quickCheck` will check for a subset of single-scalar character contents
  /// using a faster algorithm than the full grapheme breaking algorithm.
  /// However, it cannot detect all single-scalar `Character` contents.
  ///
  /// Updates the `isKnownSingleScalarCharacters` bit.
  @_unavailableInEmbedded
  public mutating func checkForSingleScalarCharacters(
    quickCheck: Bool
  ) -> Bool
}
```

**QUESTION**: There is an even quicker quick-check for NFC (checking if all scalars are `<0x300`, which covers extended latin characters). Should we expose that level as well?

### `UTF8Span` from `String`

We will add `utf8Span`-style properties to `String` and `Substring`, in line with however [SE-0456](https://forums.swift.org/t/se-0456-add-span-providing-properties-to-standard-library-types/77233/17) turns out.


### `Span`-like functionality

A `UTF8Span` is similar to a `Span<UInt8>`, but with the valid-UTF8 invariant and additional information such as `isASCII`. We propose a way to get a `Span<UInt8>` from a `UTF8Span` as well as some methods directly on `UTF8Span`:

```
extension UTF8Span {
  @_alwaysEmitIntoClient
  public var isEmpty: Bool { get }

  @_alwaysEmitIntoClient
  public var storage: Span<UInt8> { get }

  /// Calls a closure with a pointer to the viewed contiguous storage.
  ///
  /// The buffer pointer passed as an argument to `body` is valid only
  /// during the execution of `withUnsafeBufferPointer(_:)`.
  /// Do not store or return the pointer for later use.
  ///
  /// - Parameter body: A closure with an `UnsafeBufferPointer` parameter
  ///   that points to the viewed contiguous storage. If `body` has
  ///   a return value, that value is also used as the return value
  ///   for the `withUnsafeBufferPointer(_:)` method. The closure's
  ///   parameter is valid only for the duration of its execution.
  /// - Returns: The return value of the `body` closure parameter.
  @_alwaysEmitIntoClient
  borrowing public func withUnsafeBufferPointer<
    E: Error, Result: ~Copyable & ~Escapable
  >(
    _ body: (_ buffer: borrowing UnsafeBufferPointer<UInt8>) throws(E) -> Result
  ) throws(E) -> dependsOn(self) Result
}
```

### Getting a `String` from a `UTF8Span`

**QUESTION**: We should make it easier than `String(decoding:as)` to make a `String` copy of the `UTF8Span`, especially since `UTF8Span` cannot conform to `Sequence` or `Collection`. This will form an ARC-managed copy and not something that will share the (ephemeral) storage. 

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the standard library and runtime.

## Future directions

### Streaming grapheme breaking

Grapheme-breaking, which identifies where the boundaries between `Character`s are, is more complex than scalar decoding. Grapheme breaking can be ran from any scalar-aligned position, either with a given state from having processed previous scalars, or with a "fresh" state (as though that position were the start of new content).

While the code units in a `UTF8Span` are always scalar-aligned (in order to be validly encoded), whether a span is grapheme-cluster aligned depends on its intended use. For example, `AttributedString` stores its content using rope-like storage, in which the entire content is a sequence of spans were each individual span is scalar-aligned but not necessarily grapheme-cluster aligned.

A potential approach to exposing this functionality is to make the stdlib's `GraphemeBreakingState` public and define API for finding grapheme-breaks.

```swift
extension Unicode {
  public struct GraphemeBreakingState: Sendable, Equatable {
    public init()
  }
}
```

One approach is to add API to the grapheme breaking state so that the state can find the next break (while updating itself). Another is to pass grapheme breaking state to an iterator on UTF8Span, like below:

```swift
extension UTF8Span {
  public struct GraphemeBreakIterator: ~Escapable {
    public var codeUnits: UTF8Span
    public var currentCodeUnitOffset: Int
    public var state: Unicode.GraphemeBreakingState

    public init(_ span: UTF8Span)

    public init(_ span: UTF8Span, using state: Unicode.GraphemeBreakingState)

    public mutating func next() -> Bool

    public mutating func previous() -> Bool


    public mutating func skipForward()

    public mutating func skipForward(by n: Int)

    public mutating func skipBack()

    public mutating func skipBack(by n: Int)

    public mutating func reset(
      roundingBackwardsFrom i: Int, using: Unicode.GraphemeBreakingState
    )

    public mutating func reset(
      roundingForwardsFrom i: Int, using: Unicode.GraphemeBreakingState
    )

    public mutating func reset(
      uncheckedAssumingAlignedTo i: Int, using: Unicode.GraphemeBreakingState
    )

    public func prefix() -> UTF8Span
    public func suffix() -> UTF8Span
  }
```


### More alignments

Future API could include word iterators (either [simple](https://www.unicode.org/reports/tr18/#Simple_Word_Boundaries) or [default](https://www.unicode.org/reports/tr18/#Default_Word_Boundaries)), line iterators, etc.

### Normalization

Future API could include checks for whether the content is in a particular normal form (not just NFC).

### UnicodeScalarView and CharacterView

Like `Span`, we are deferring adding any collection-like types to non-escapable `UTF8Span`. Future work could include adding view types that conform to a new `Container`-like protocol.

For an example implementation of those see [the `UTFSpanViews.swift` test file](https://github.com/apple/swift-collections/pull/394).

### More algorithms

We propose equality checks (e.g. `scalarsEqual`), as those are incredibly common and useful operations. We have (tentatively) deferred other algorithms until non-escapable collections are figured out.

However, we can add select high-value algorithms if motivated by the community.

### More validation API

Future work includes returning all the encoding errors found in a given input.

```swift
extension UTF8 {
  public static func checkAllErrors(
    _ s: some Sequence<UInt8>
  ) -> some Sequence<UTF8.EncodingError>
```

See [`_checkAllErrors` in `UTF8EncodingError.swift`](https://github.com/apple/swift-collections/pull/394).

### Transcoded iterators, normalized iterators, case-folded iterators, etc

We could provide lazily transcoded, normalized, case-folded, etc., iterators. If we do any of these for `UTF8Span`, we should consider adding equivalents views on `String`, `Substring`, etc.

### Regex or regex-like support

Future API additions would be to support `Regex`es on `UTF8Span`. We'd expose grapheme-level semantics, scalar-level semantics, and introduce byte-level semantics.

Another future direction could be to add many routines corresponding to the underlying operations performed by the regex engine, which would be useful for parser-combinator libraries who wish to expose `String`'s model of Unicode by using the stdlib's accelerated implementation.


### Canonical Spaceships

Should a `ComparisonResult` (or [spaceship](https://forums.swift.org/t/pitch-comparison-reform/5662)) be added to Swift, we could support that operation under canonical equivalence in a single pass rather than subsequent calls to `isCanonicallyEquivalent(to:)` and `isCanonicallyLessThan(_:)`.


### Exposing `String`'s storage class

String's internal storage class is null-terminated valid UTF-8 (by substituting replacement characters) and implements range-replaceable operations along scalar boundaries. We could consider exposing the storage class itself, which might be useful for embedded platforms that don't have `String`.

### Track other bits

Future work include tracking whether the contents are NULL-terminated (useful for C bridging), whether the contents contain any newlines or only a single newline at the end (useful for accelerating Regex `.`), etc.

### Putting more API on String

`String` would also benefit from the query API, such as `isKnownNFC` and corresponding scan methods. Because a string may be a lazily-bridged instance of `NSString`, we don't always have the bits available to query or set, but this may become viable pending future improvements in bridging.

### Generalize printing and logging facilities

Many printing and logging protocols and facilities operate in terms of `String`. They could be generalized to work in terms of UTF-8 bytes instead, which is important for embedded.

## Alternatives considered

### Invalid start / end of input UTF-8 encoding errors

Earlier prototypes had `.invalidStartOfInput` and `.invalidEndOfInput` UTF8 validation errors to communicate that the input was perhaps incomplete or not slices along scalar boundaries. In this scenario, `.invalidStartOfInput` is equivalent to `.unexpectedContinuation` with the range's lower bound equal to 0 and `.invalidEndOfInput` is equivalent to `.truncatedScalar` with the range's upper bound equal to `count`.

This was rejected so as to not have two ways to encode the same error. There is no loss of information and `.unexpectedContinuation`/`.truncatedScalar` with ranges are more semantically precise.

### An unsafe UTF8 Buffer Pointer type

An [earlier pitch](https://forums.swift.org/t/pitch-utf-8-processing-over-unsafe-contiguous-bytes/69715) proposed an unsafe version of `UTF8Span`. Now that we have `~Escapable`, a memory-safe `UTF8Span` is better.

### Alternatives to Iterators

#### Functions

A previous version of this pitch had code unit offset taking API directly on UTF8Span instead of using iterators as proposed. This lead to a large number of unweildy API. For example, instead of:

```swift
extension UTF8Span.ScalarIterator {
  public mutating func next() -> Unicode.Scalar? { }
}
```

we had:

```swift
extension UTF8Span {
/// Decode the `Unicode.Scalar` starting at `i`. Return it and the start of
  /// the next scalar.
  ///
  /// `i` must be scalar-aligned.
  @_alwaysEmitIntoClient
  public func decodeNextScalar(
    _ i: Int
  ) -> (Unicode.Scalar, nextScalarStart: Int)

  /// Decode the `Unicode.Scalar` starting at `i`. Return it and the start of
  /// the next scalar.
  ///
  /// `i` must be scalar-aligned.
  ///
  /// This function does not validate that `i` is within the span's bounds;
  /// this is an unsafe operation.
  @_alwaysEmitIntoClient
  public func decodeNextScalar(
    unchecked i: Int
  ) -> (Unicode.Scalar, nextScalarStart: Int)

  /// Decode the `Unicode.Scalar` starting at `i`. Return it and the start of
  /// the next scalar.
  ///
  /// `i` must be scalar-aligned.
  ///
  /// This function does not validate that `i` is within the span's bounds;
  /// this is an unsafe operation.
  ///
  ///
  /// This function does not validate that `i` is scalar-aligned; this is an
  /// unsafe operation if `i` isn't.
  @_alwaysEmitIntoClient
  public func decodeNextScalar(
    uncheckedAssumingAligned i: Int
  ) -> (Unicode.Scalar, nextScalarStart: Int)
}
```

Every operation had `unchecked:` and `uncheckedAssumingAligned:` variants, which were needed to implement higher-performance constructs such as iterators and string processing features (including the `Regex` engine).

This API made the caller manage the scalar-alignment invariant, while the iterator-style API proposed maintains this invariant internally, allowing it to use the most efficient implementation.

Scalar-alignment can still be checked and managed by the caller through the `reset` API, which safely round forwards or backwards as needed. And, for high performance use cases where the caller knows that a given position is appropriately aligned already (for example, revisiting a prior point in a string during `Regex` processing), there's the `reset(uncheckedAssumingAlignedTo:)` API available.

### Collections

Because `Collection`s are `Escapable`, we cannot conform nested `View` types to `Collection`.


## Acknowledgments

Karoy Lorentey, Karl, Geordie_J, and fclout, contributed to this proposal with their clarifying questions and discussions.









