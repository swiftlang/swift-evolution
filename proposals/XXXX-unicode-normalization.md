# Unicode Normalization APIs

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Karl Wagner](https://github.com/karwa)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Unicode Normalization Forms are formally defined normalizations of Unicode strings which make it possible to determine whether any two Unicode strings are equivalent to each other.

Normalization is a fundamental operation when processing Unicode text, and as such deserves to be one of the core text processing algorithms exposed by the standard library. It is used by the standard library internally to implement basic String operations and is of great importance to other libraries.

## Motivation

Normalization determines whether two pieces of text can be considered equivalent: if two pieces of text are normalized to the same form, and they are equivalent, they will consist of exactly the same Unicode scalars.

Unicode defines two categories of equivalence:

- Canonical Equivalence

  > A fundamental equivalency between characters or sequences of characters which represent the same abstract character, and which when correctly displayed should always have the same visual appearance and behavior.
  >
  > UAX#15 Unicode Normalization Forms

  **Example:** `Ω` (U+2126 OHM SIGN) is canonically equivalent to `Ω` (U+03A9 GREEK CAPITAL LETTER OMEGA)

- Compatiblity Equivalence

  > It is best to think of these Normalization Forms as being like uppercase or lowercase mappings: useful in certain contexts for identifying core meanings, but also performing modifications to the text that may not always be appropriate.
  >
  > UAX#15 Unicode Normalization Forms

  **Example:** "Ⅳ" (U+2163 ROMAN NUMERAL FOUR) is compatibility equivalent to the ASCII string "IV".

Additionally, some scalars are equivalent to a sequence of scalars and combining marks. These are called _canonical composites_, and when producing text in its canonical or compatibility form, we can further choose for it to contain either the decomposed or precomposed representations of these composites. 

**Example:** The famous "é"

|                 |                                                                          |
|-----------------|--------------------------------------------------------------------------|
| **Decomposed**  | "e\u{0301}" (U+0065 LATIN SMALL LETTER E, U+0301 COMBINING ACUTE ACCENT) |
| **Precomposed** | "é" (U+00E9 LATIN SMALL LETTER E WITH ACUTE)                             |

This defines all four normal forms:

|                 | **Canonical** | **Compatibility** |
|-----------------|:-------------:|:-----------------:|
| **Decomposed**  |      NFD      |        NFKD       |
| **Precomposed** |      NFC      |        NFKC       |

This proposal will only cover canonical normalisation, in forms NFD and NFC. It does not rule out support for compatibility normalisation eventually (either in the standard library, Foundation, or some other Unicode supplement library), but they are not in this proposal.

Canonical equivalence is important for all applications because it is a more fundamental equivalence. The Unicode standard states that applications may normalise strings to their canonical equivalents without modifying the text's interpretation, so it can be applied fairly liberally.

> C7. _When a process purports not to modify the interpretation of a valid coded character sequence, it shall make no change to that coded character sequence other than the possible replacement of character sequences by their canonical-equivalent sequences._
>
> Replacement of a character sequence by a compatibility-equivalent sequence _does_ modify the interpretation of the text.
>
> Unicode Standard 15.0, 3.2 Conformance Requirements

Canonical equivalence is particularly relevant for Swift applications: it is what String's `==` operator tests, and String's `<` operator sorts strings by lexicographical comparison of their NFC contents.

> 🚧 TODO: Is the behaviour of `<` a documented guarantee?

Because normalisation turns equivalent strings in to exactly the same sequence of scalars, they also encode to the same code-units. This means we can perform simple binary comparisons such as `memcmp` over blobs of normalised UTF8, and our results will be consistent with String's built-in operations.

This enables many data structures to be implemented more efficiently, with semantics that match the expectations of Swift developers. NFD and NFC normalisation are also a part of many protocols and standards which developers would like to implement in Swift.

There are also opportunities to optimise strings when used in other data structures. Let's say I have a `Heap` of strings; `swift-collections` documents that inserting an element in to the heap requires `O(log(count))` comparisons. If all of these strings were normalised, those comparisons could just be `memcmp`s without any allocations or Unicode table lookups.

Some applications, such as those which persist normalised strings, additionally need to know whether the normalisation is stable.

### Versioning and Stability

Unicode is a versioned standard which regularly assigns new code-points, meaning systems running older software are likely to encounter code-points from the future and must handle that situation gracefully. But how can a system normalise text containing code-points it lacks data for?

Fundamentally, if a string contains unassigned code-points, its normalisation is unstable. If a system conforming to Unicode 15 normalises text containing code-points first assigned in Unicode 20, it is not guaranteed that Unicode 20 will also consider that text normalised. The normalisation process is designed to be forwards-compatibile by ensuring that if text is already normalised according to Unicode 20, normalising it again on the older Unicode 15 system would leave it completely unchanged.

Developers often need firmer guarantees of stability. When a key is persisted in a database, it needs to remain discoverable to future clients. When a package implements an industry protocol requiring NFC text, it can be important for it to know whether the normaliser is "actively" normalising text it understands, or whether it is passing-through a potentially unstable normalisation.

Producing a stable normalisation is straightforward - the only additional requirement is that the process fails if the string contains unassigned code-points. For all assigned code-points, Unicode's normalisation stability policy takes effect:

> Once a character is encoded, its canonical combining class and decomposition mapping will not be changed in a way that will destabilize normalization.

The strings we get as a result are referred to as "Stabilised Strings" by Unicode.

> Once a string has been normalized by the NPSS [Normalization Process for Stabilized Strings] for a particular normalization form, it will never change if renormalized for that same normalization form by an implementation that supports any version of Unicode, past or future. 
>
> For example, if an implementation normalizes a string to NFC, following the constraints of NPSS (aborting with an error if it encounters any unassigned code point for the version of Unicode it supports), the resulting normalized string would be stable: it would remain completely unchanged if renormalized to NFC by any conformant Unicode normalization implementation supporting a prior or a future version of the standard.
>
> UAX#15 Unicode Normalization Forms

If we offer normalisation APIs, it makes sense to also offer APIs for stabilised strings.

### Existing API

Currently, normalization is only exposed via Foundation:

```swift
extension String {
  var decomposedStringWithCanonicalMapping: String { get }
  var decomposedStringWithCompatibilityMapping: String { get }
  var precomposedStringWithCanonicalMapping: String { get }
  var precomposedStringWithCompatibilityMapping: String { get }
}
```

There are many reasons to want to revise this interface and bring the functionality in to the standard library:

- It is hard to find, using terminology most users will not understand. Many developers will hear about normalisation, and "NFC" and "NFD" are familiar terms of art in that context, but it's difficult to join the dots between "NFC" and `precomposedStringWithCanonicalMapping`.

  [In JavaScript](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/normalize) and many other languages, this operation is:

  ```javascript
  "some string".normalize("NFC");
  ```

- It does not expose an interface for producing stabilised strings.

- It only accepts input text as a String. Many libraries store text in other types during their processing, and copying to a String can be a significant overhead.

  The existing API also does not support normalising a Substring or Character; only Strings.

- It eagerly normalises the entirety of its input. This is suboptimal when comparing strings for equivalence; applications typically want to early-exit as soon the strings diverge.

- It is incompatible with streaming APIs. Streams provide their data in incremental chunks, not aligned to any normalisation boundaries. Normalisation is not closed to concatenation:

  > even if two strings X and Y are normalized, their string concatenation X+Y is not guaranteed to be normalized.

  This means streaming APIs cannot normalise data in chunks as they receive it using the existing API - instead they would need to buffer all of the incoming data, copy it in to a String, then normalise the entire String at once.

## Proposed solution

We will provide 3 categories of APIs for producing normalised text, targeting: Strings, Sequences, and even more advanced use-cases.

### 1. Strings

We will introduce functions on StringProtocol (Strings and Substrings) and Character which produce a normalized copy of their contents:

```swift
extension Unicode {

  @frozen
  public enum CanonicalNormalizationForm {
    case nfd
    case nfc
  }
}

extension StringProtocol {

  /// Returns a copy of this string in the given normal form.
  ///
  /// The result is canonically equivalent to this string.
  ///
  public func normalized(
    _ form: Unicode.CanonicalNormalizationForm
  ) -> String

  /// Returns a copy of this string in the given normal form,
  /// if that form is stable in future versions of Unicode.
  ///
  /// The result, if not `nil`, is canonically equivalent
  /// to this string.
  ///
  public func stabilized(
    _ form: Unicode.CanonicalNormalizationForm
  ) -> String?
}

extension Character {

  /// Returns a copy of this character in the given normal form.
  ///
  /// The result is canonically equivalent to this character.
  ///
  public func normalized(
    _ form: Unicode.CanonicalNormalizationForm
  ) -> Character
}
```

Usage:

```swift
"abc".normalized(.nfc)

func persist(key: String, value: Any) throws {

  guard let stableKey = key.stabilized(.nfd) else {
    throw UnsupportedKeyError(key)
  }
  try writeToDatabase(key: stableKey.utf8, value: value)
}
```

Character does not offer a `stabilized` function, as the definition of character boundaries is not stable across Unicode versions. However, they may still be normalised.

#### The Standard Library's preferred form

These APIs are an ideal opportunity for the standard library's String implementation to set internal flags noting that it contains normalised contents. This can be a huge optimisation for common operations such as comparison and hashing.

However, there are some caveats about this flag:

1. We do not guarantee that every String will have a flag.

2. If a flag exists, it might be lost across mutations, and new strings formed by concatenating the flagged string might not inherit the flag.

While the standard library is free to add performance flags for as many forms as it likes, there is also value in agreeing on one, "preferred" form. 

It is important to note that normalising to this form is not required for correct operation of any standard library APIs.

```swift
extension Unicode.CanonicalNormalizationForm {

  /// The normal form preferred by the Swift Standard Library.
  ///
  /// Normalizing a String to this form may allow for
  /// more efficient comparison or other operations. 
  ///
  public static var preferredForm: Self { get }
}
```

It doesn't make guarantees, but the reality is that in the current standard library implementation, large Strings _do_ have such a flag and small Strings _do not_. It would be silly not to take advantage of it where we can, but rather than let it spread as some urban legend that "NFC strings are faster" only for people to see confusing results, it would be better to just give it a name and document it.

For expert use-cases needing more robust performance guarantees, they can be recovered by manually normalising the contents and performing comparisons on String views:

```swift
struct NormalizedStringHeap {
  // Note: String.UTF8View should be Comparable
  var heap: Heap<String.UTF8View> = ...

  mutating func insert(_ element: String) {
    // .insert performs O(log(count)) comparisons.
    // Now they are guaranteed to just be a memcmp,
    // and have the same semantics as String.<
    heap.insert(aString.normalized(.preferredForm).utf8)
  }
}
```

Even here, `.preferredForm` can benefit us - one of the operations String would likely optimise if it happens to have a performance flag is making `.normalized(.preferredForm)` on a normalised string a no-op.

### 2. Sequences

We will also introduce a streaming API which allows developers to lazily normalize any `Sequence<Unicode.Scalar>`, via a new `.normalized` namespace wrapper:

Namespace:

```swift
extension Unicode {

  /// A namespace for normalized representations of Unicode text.
  ///
  @frozen
  public struct NormalizedScalars<Source> { ... }
}

extension Sequence where Element == Unicode.Scalar {

  /// A namespace providing normalized versions of this sequence's contents.
  ///
  @inlinable
  public var normalized: NormalizedScalars<Self> { get }
}
```

Normalised streams:

```swift
extension Unicode.NormalizedScalars
 where Source: Sequence<Unicode.Scalar> {
  
  /// The contents of the source, normalized to NFD.
  ///
  @inlinable
  public var nfd: NFD { get }

  @frozen 
  public struct NFD: Sequence {
    public typealias Element = Unicode.Scalar
  }

  // and same for NFC.
}
```

Usage:

```swift
func process(_ input: Array<Unicode.Scalar>) {
  for scalar in input.normalized.nfc {
    // NFC scalars, normalised on-demand.
  }
}

for scalar in "café".unicodeScalars.normalized.nfd {
  // scalar: "c", "a", "f", "e", "\u{0301}"
}
```

We also introduce async versions of these sequences:

```swift
extension AsyncSequence where Element == Unicode.Scalar {

  /// A namespace providing normalized versions of this sequence's contents.
  ///
  @inlinable
  public var normalized: Unicode.NormalizedScalars<Self> { get }
}

extension Unicode.NormalizedScalars
 where Source: AsyncSequence<Unicode.Scalar> {
  
  /// The contents of the source, normalized to NFD.
  ///
  @inlinable
  public var nfd: AsyncNFD { get }

  @frozen 
  public struct AsycNFD: AsyncSequence {
    public typealias Element = Unicode.Scalar
    public typealias Failure = Source.Failure
  }

  // and same for NFC.
}
```

Usage:

```swift
import Foundation

let url = URL(...)

for try await scalar in url.resourceBytes.unicodeScalars.normalized.nfc {
  // NFC scalars, loaded and normalised on-demand.
}
```

Additionally, so that streaming use-cases can efficiently produce stabilised strings, we will add a `.isUnassigned` property to `Unicode.Scalar`:

```swift
extension Unicode.Scalar {
  public var isUnassigned: Bool { get }
}
```

Currently the standard library offers two ways to access this information:

```swift
scalar.properties.generalCategory == .unassigned
scalar.properties.age == nil
```

Unfortunately these queries are less amenable to fast paths covering large contiguous blocks of known-assigned scalars. We can significantly reduce the number of table lookups for the most common scripts with a simple boolean property.

### 3. Stateful normaliser

Not all streams can be easily modelled as iterators. Sometimes it is more useful to have a stateful normaliser, which can be fed with new chunks of input data at various points of the program.

```swift
extension Unicode {
  
  /// A stateful normalizer representing a single logical text stream.
  ///
  public struct NFDNormalizer: Sendable {
    
    public init()

    /// Returns the next normalized scalar, consuming data using the given iterator if necessary.
    ///
    @inlinable
    public mutating func resume(
      consuming source: inout some IteratorProtocol<Unicode.Scalar>
    ) -> Unicode.Scalar?

    /// Finalizes the normalizer and returns any remaining data from its buffers.
    ///
    public mutating func flush() -> Unicode.Scalar?
  }

  // Same for NFC
}
```

This is our lowest-level interface for normalisation. It represents a single logical text stream, which is provided in pieces using multiple physical streams. It consists of a bag of state and two functions: one to feed it data, and another to flush any buffers it may have once you have no more data to feed it.

Given the resilience requirements of the standard library, the normaliser is non-frozen and its core algorithm non-inlinable. 

Usage:

```swift
var normalizer = Unicode.NFDNormalizer()

// Consume an input stream and print its normalized representation.
var input: some IteratorProtocol<Unicode.Scalar> = ...
while let scalar = normalizer.resume(consuming: &input) {
  print(scalar)
}

// Once 'resume' returns nil, it has consumed all of 'input'.
assert(input.next() == nil)

// We could resume again, consuming from another input source.
var input2: some IteratorProtocol<Unicode.Scalar> = ...
while let scalar = normalizer.resume(consuming: &input2) {
  print(scalar)
}
assert(input2.next() == nil)

// Finally, when we are done consuming input sources:
while let scalar = normalizer.flush() {
  print(scalar)
}
```

As long as the normalizer's state is stored somewhere, you can suspend and resume processing at any time.

After starting to `flush()`, future attempts to `resume()` the normaliser will return `nil` while not consuming any data. This allows optional chaining to be used to process a final sequence and flush the normalizer:

```swift
struct MyNFDIterator: IteratorProtocol {

    var source: Source.Iterator
    var normalizer: Unicode.NFDNormalizer

    mutating func next() -> Unicode.Scalar? {
      normalizer.resume(consuming: &source) ?? normalizer.flush() // <-
    }
  }
```

### Other Additions

```swift
// + Document String's Comparable behaviour.

extension String {
  init(_: some Sequence<Unicode.Scalar>)
}

extension String.UTF8View: Equatable {}
extension String.UTF8View: Hashable {}
extension String.UTF8View: Comparable {}
// and same for UTF16View, UnicodeScalarView.
```

### Case Study: WebURL

The WebURL package includes a pure-Swift implementation of UTS#46 (internationalised domain names), and part of its processing includes normalising a domain string to NFC. Domains are often used for making security decisions, and it is important that "café.fr" and "cafe\\u{0301}.fr" produce the same normalised result.

 The package currently uses the Foundation API mentioned above, but by switching to the proposed standard library interface, it would gain the following benefits:

- Robustness against unstable normalisations. Because normalisation comes from a system library on Apple platforms (Foundation or the Swift standard library), it might be using an older version of Unicode. With a new fast assignment check on `Unicode.Scalar`, the package can quickly detect when the normalised result might be unstable.

- 30% lower execution time. WebURL's core parser works at the buffers-of-UTF8 level, because it only really needs Unicode awareness for one particular kind of domain string. With the previous API, the domain portion of the buffer would needed to be copied in to a String, normalised in full (which copies in to a new string), then decoded to scalars so they can be passed to later processing.

  The new implementation is a single stream, decoding UTF8 to scalars, then normalising those scalars on-demand and passing the result through a mapping table. We removed two full-copies and simplified the overall process, invalid data is detected early, and where/when to buffer now becomes a library choice.

Performance could be improved further once we add normalisation checking functions.

## Detailed design

** TODO **
** TODO **
** TODO **
** TODO **

Describe the design of the solution in detail. If it involves new
syntax in the language, show the additions and changes to the Swift
grammar. If it's a new API, show the full API and its documentation
comments detailing what it does. The detail in this section should be
sufficient for someone who is *not* one of the authors to be able to
reasonably implement the feature.

## Source compatibility

The proposed interfaces are additive and do not conflict with Foundation's existing normalisation API.

Furthermore, it is possible to extend the interface (for instance, with compatibility normal forms), and the compiler is able to disambiguate between them:

```swift
// Possible extension in a future standard library/community package:

enum CompatibilityNormalizationForm {
  case nkfd
  case nfkc
}

extension StringProtocol {
  func normalized(
    _ form: CompatibilityNormalizationForm
  ) -> String
}

"abc".normalized(.nfc)  // Works. Calls canonical normalisation function.
"abc".normalized(.nfkc) // Works. Calls compatibility normalisation function.
```

## ABI compatibility

This proposal is purely an extension of the ABI of the
standard library and does not change any existing features.

The proposed interface is designed to minimise ABI commitments. The standard library's internal Unicode data structures and normalisation algorithm are not committed to ABI. All other interfaces are built using the stateful normaliser, which is resilient and its core functions are non-inlinable.

## Implications on adoption

The proposed APIs will require a new version of the standard library. They are not backwards-deployable.

## Future directions

### Compatibility normalisation

It's possible Regex will need to add it eventually, but it's out of scope for this proposal. Any future support should be able to use the API patterns established here.

### Checking for normalisation

The proposed APIs allow us to implement a naive check for normalisation:

```swift
scalars.elementsEqual(scalars.normalized.nfc)
```

It is possible to implement this check more efficiently, but the API requires further design work. The Unicode standard describes an efficient, no-allocation check (appropriately named "Quick Check"), but it produces a tri-state Yes/No/Maybe result. We'd probably want to expose that for experts, but we'd also want a way to resolve the "Maybe" condition and produce a definitive Yes/No result.

Additionally, it would be useful to explore how we can use the Quick Check result to speed up later normalisation. String already has this built-in, so if you write:

```swift
let nfcString = someString.normalized(.nfc)

for scalar in nfcString.unicodeScalars.normalized.nfc {
  ...
}
```

`nfcString` has an internal performance bit set so we know it is NFC. The streaming normaliser in the `for`-loop detects this and knows it doesn't need to normalise the contents a second time. We could use a Quick Check result to generalise this.


## Alternatives considered

** TODO **
** TODO **
** TODO **
** TODO **

Describe alternative approaches to addressing the same problem.
This is an important part of most proposal documents.  Reviewers
are often familiar with other approaches prior to review and may
have reasons to prefer them.  This section is your first opportunity
to try to convince them that your approach is the right one, and
even if you don't fully succeed, you can help set the terms of the
conversation and make the review a much more productive exchange
of ideas.

You should be fair about other proposals, but you do not have to
be neutral; after all, you are specifically proposing something
else.  Describe any advantages these alternatives might have, but
also be sure to explain the disadvantages that led you to prefer
the approach in this proposal.

You should update this section during the pitch phase to discuss
any particularly interesting alternatives raised by the community.
You do not need to list every idea raised during the pitch, just
the ones you think raise points that are worth discussing.  Of course,
if you decide the alternative is more compelling than what's in
the current proposal, you should change the main proposal; be sure
to then discuss your previous proposal in this section and explain
why the new idea is better.

## Acknowledgments

** TODO **
** TODO **
** TODO **
** TODO **

If significant changes or improvements suggested by members of the 
community were incorporated into the proposal as it developed, take a
moment here to thank them for their contributions. Swift evolution is a 
collaborative process, and everyone's input should receive recognition!

Generally, you should not acknowledge anyone who is listed as a
co-author or as the review manager.
