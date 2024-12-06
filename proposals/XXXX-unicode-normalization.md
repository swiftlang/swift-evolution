# Unicode Normalization

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Karl Wagner](https://github.com/karwa), [Michael Ilseman](https://github.com/milseman)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/...))


## Introduction


Unicode Normalization Forms are formally defined normalizations of Unicode strings which make it possible to determine whether any two Unicode strings are equivalent to each other.

Normalization is a fundamental operation when processing Unicode text, and as such deserves to be one of the core text processing algorithms exposed by the standard library. It is used by the standard library internally to implement basic String operations and is of great importance to other libraries.


## Motivation


Normalization determines whether two pieces of text can be considered equivalent: if two pieces of text are normalized to the same form, and they are equivalent, they will consist of exactly the same Unicode scalars (and by extension, the same UTF-8/16 code-units).

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

Additionally, some scalars are equivalent to a sequence of scalars and combining marks. These are called _canonical composites_, and when producing the canonical or compatibility normal form of some text, we can further choose for it to contain either decomposed or precomposed representations of these composites.

These are different forms, but importantly are _not_ additional categories of equivalence. Applications are free to compose or decompose text without affecting equivalence.

**Example:** The famous "é"

|                 |                                                                                     |
|-----------------|-------------------------------------------------------------------------------------|
| **Decomposed**  | "e\u{0301}" (2 scalars: U+0065 LATIN SMALL LETTER E, U+0301 COMBINING ACUTE ACCENT) |
| **Precomposed** | "é" (1 scalar: U+00E9 LATIN SMALL LETTER E WITH ACUTE)                              |

```swift
// Decomposed and Precomposed forms are canonically equivalent.
// Applications can choose to work with whichever form
// is more convenient for them.

assert("e\u{0301}" == "é")
```

This defines all four normal forms:

|                 | **Canonical** | **Compatibility** |
|-----------------|:-------------:|:-----------------:|
| **Decomposed**  |      NFD      |        NFKD       |
| **Precomposed** |      NFC      |        NFKC       |

Canonical equivalence is particularly important. The Unicode standard says that programs _should_ treat canonically-equivalent strings identically, and are always free to normalise strings to a canonically-equivalent form internally without fear of altering the text's interpretation.

> C6. _A process shall not assume that the interpretations of two canonical-equivalent character sequences are distinct._
>
> - The implications of this conformance clause are twofold. First, a process is never required to give different interpretations to two different, but canonical-equivalent character sequences. Second, no process can assume that another process will make a distinction between two different, but canonical-equivalent character sequences.
>
> - Ideally, an implementation would always interpret two canonical-equivalent character sequences identically. [...]
>
> C7. _When a process purports not to modify the interpretation of a valid coded character sequence, it shall make no change to that coded character sequence other than the possible replacement of character sequences by their canonical-equivalent sequences._
>
> - Replacement of a character sequence by a **compatibility-equivalent** sequence _does_ modify the interpretation of the text.
>
> Unicode Standard 15.0, 3.2 Conformance Requirements

Accordingly, as part of ensuring that Swift has first-class support for Unicode, it was decided that String's default `Equatable` semantics (the `==` operator) would test canonical equivalence. As a result, by default applications get the ideal behaviour described by the Unicode standard - for instance, if one inserts a String in to an `Array` or `Set` it can be found again using any canonically-equivalent String.

```swift
var strings: Set<String> = []

strings.insert("\u{00E9}")            // precomposed e + acute accent
assert(strings.contains("e\u{0301}")) // decomposed e + acute accent
```

Other libraries would like similar Unicode support in their own data structures without requiring `String` for storage, or may require normalisation to implement specific algorithms, standards, or protocols. For instance, normalising to NFD or NFKD allows one to more easily remove diacritics for fuzzy search algorithms and spoof detection, and processing Internationalised Domain Names (IDNs) requires normalising to NFC.

Additionally, String can store and preserve any sequence of code-points, including non-normalised text -- however, since its comparison operators test canonical equivalence, in the worst case both operands will have to be normalised on-the-fly. Normalisation may allocate buffers and involves lookups in to Unicode property databases, so this may not always be desirable.

The ability to normalise text in advance (rather than on-the-fly) can deliver some significant benefits. Recall that canonically-equivalent strings, when normalised to the same form, encode to the same bytes of UTF8; so if our text is already normalised we can perform a simple binary comparison (such as `memcmp`), and our results will still be consistent with String's default operators. We pay the cost of normalisation once _per string_ rather than paying it up to twice _per comparison operation_.

Consider a Trie data structure (which is often used with textual data):

```
      root
     /  |  \
    a   b   c
   / \   \   \
  p   t   a   a
 /     \   \   \
p       e   t   t
```

When performing a lookup, we compare the next element in the string we are searching for with the children of our current node and repeat that process to descend the Trie. For instance, when searching for the word "app", we descend from the root to the "a" node, then to the "p" node, etc. If the Trie were filled with _normalised_ text and the search string were also normalised, these could be simple binary comparisons (with no allocations or table lookups) while still matching all canonically-equivalent strings. In fact, so long as we normalise everything going in, the fundamental operation of the Trie doesn't need to know _anything_ about Unicode; it can just operate on binary blobs. Other data structures could benefit from similar techniques - everything from B-Trees (many comparisons) to Bloom filters (computing many hashes).

In summary, normalisation is an extremely important operation and there are many, significant benefits to exposing it in the standard library.


### Versioning and Stability


Unicode is a versioned standard which regularly assigns new code-points, meaning systems running older software are likely to encounter code-points from the future and must handle that situation gracefully. We must be able to compare strings containing unassigned code-points so normalisation must accept them and process them in _some way_, but the result is only locally meaningful. If we normalise a string containing unassigned code-points, a newer system which actually has data for those code-points might not agree that the result is normalised, so we say the normalisation is _unstable_.

Developers often need firmer guarantees of stability. If we persist keys in a database, it is important to know that they will remain distinct (no past or future version of Unicode will decide that they are equivalent), and if we store a sorted list of normalised strings, no other version of Unicode will change them and consider the list unsorted. When a Swift package implements an industry protocol requiring NFC text, it can be important to know whether another system might disagree that the text is NFC. [NIST Digital Identity Guidelines](https://pages.nist.gov/800-63-3/sp800-63b.html#sec5) require the hashing of Unicode passwords to be performed on their stable normalisation.

This is achievable. On the consumer side, the normalisation algorithm is designed in such a way that normalised text will not be un-normalised, even by an older system which lacks data for some of the code-points. Producing a stable normalisation is fairly straightforward - the only added requirement is that the process must fail if the string contains an unassigned code-point. Once a code-point has been assigned it is covered by Unicode's normalisation stability policy, which states:

> Once a character is encoded, its canonical combining class and decomposition mapping will not be changed in a way that will destabilize normalization.

The result is referred to by Unicode as a "Stabilised String", and it offers some important guarantees:

> Once a string has been normalized by the NPSS [Normalization Process for Stabilized Strings] for a particular normalization form, it will never change if renormalized for that same normalization form by an implementation that supports any version of Unicode, past or future. 
>
> For example, if an implementation normalizes a string to NFC, following the constraints of NPSS (aborting with an error if it encounters any unassigned code point for the version of Unicode it supports), the resulting normalized string would be stable: it would remain completely unchanged if renormalized to NFC by any conformant Unicode normalization implementation supporting a prior or a future version of the standard.
>
> UAX#15 Unicode Normalization Forms

Since normalisation determines equivalence, stabilised strings have the kind of properties we are looking for: if they are distinct they will always be distinct, and if they are sorted, a comparator such as String's `<` operator which sorts based on normalised code-points will always consider them sorted.

Note that there is no guarantee that two systems will produce _the same_ stabilised string for the same un-normalised input. Even though that is generally the case, there have been clerical errors in past versions of Unicode which needed correction. In practice, only 7 code-points have ever had their normalisations changed in this way, the [most recent of which](https://www.unicode.org/versions/corrigendum4.html) was over 20 years ago.

> _Q: Does this mean that if I take an identifier (as above) and normalize it on system A and system B, both with a different version of normalization, I will get the same result?_
>
> In general, yes. Note, however, that the stability guarantee only applies to _normalized_ data. There are indeed _exceptional_ situations in which un-normalized data, normalized using different versions of the standard, can result in different strings after normalization. The types of exceptional situations involved are carefully limited to situations where there were errors in the definition of mappings for normalization, and where applying the erroneous mappings would effectively result in corrupting the data (rather than merely normalizing it).
>
> _Q: Are these exceptional circumstances of any importance in practical application?_
>
> No. They affect only a tiny number of characters in Unicode, and, in addition, these characters occur extremely rarely, or only in very contrived situations. Many protocols can safely disallow any of them, and avoid the situation altogether.
>
> [Unicode FAQ: Normalization](https://www.unicode.org/faq/normalization.html#17)

The guarantees provided by stabilised strings are likely to be attractive to many Swift developers. In addition to normalisation, it makes sense for the standard library to also offer APIs for producing _stable_ normalisations.

#### Stability over ancient versions of Unicode

Early versions of Unicode experienced significant churn and the modern definition of normalization stability was added in version 4.1. When we talk about stability of assigned code points, we are referring to notions of stability from 4.1 onwards. A normalized string is stable from either the version of Unicode in which the latest code point was assigned or Unicode version 4.1 (whichever one is later).


### Existing API


Currently, normalisation is only exposed via Foundation:

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

- It only accepts input text as a String. There are other interesting data structures which may contain Unicode text, and copying to a String can be a significant overhead for them.

  The existing API also does not support normalising a Substring or Character; only entire Strings.

- It eagerly normalises the entirety of its input. This is suboptimal when comparing strings or checking if a string is already normalised; applications typically want to early-exit as soon the result is apparent.

- It is incompatible with streaming APIs. Streams provide their data in incremental chunks, not aligned to any normalisation boundaries. However, normalisation is not closed to concatenation:

  > even if two strings X and Y are normalized, their string concatenation X+Y is not guaranteed to be normalized.

  This means a program wanting to operate on a stream of normalised text cannot just normalise each chunk separately. In order to work with the existing API, they would have to forgo streaming entirely, buffer all of the incoming data, copy it in to a String, then normalise the entire String at once.


## Proposed solution


We propose 3 levels of API, targeting:

- Strings
- Custom storage and incremental normalisation, and
- Stateful normaliser

Additionally, we are proposing a handful of smaller enhancements to help developers process text using these APIs.

The proposal aims to advance text processing in Swift and unlock certain key use-cases, but it is not exhaustive. There will remain a healthy amount of subject matter for future consideration.


### 1. Strings


We propose to introduce functions on StringProtocol (String, Substring) and Character which produce a normalised copy of their contents:

```swift
extension Unicode {

  @frozen
  public enum CanonicalNormalizationForm {
    case nfd
    case nfc
  }

  @frozen
  public enum CompatibilityNormalizationForm {
    case nfkd
    case nfkc
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

  /// Returns a copy of this string in the given normal form.
  ///
  /// The result _may not_ be canonically equivalent to this string.
  ///
  public func normalized(
    _ form: Unicode.CompatibilityNormalizationForm
  ) -> String

  /// Returns a copy of this string in the given normal form,
  /// if the result is stable.
  ///
  /// A stable normalization will not change if normalized again
  /// to the same form by any version of Unicode, past or future.
  ///
  /// The result, if not `nil`, is canonically equivalent
  /// to this string.
  ///
  public func stableNormalization(
    _ form: Unicode.CanonicalNormalizationForm
  ) -> String?

  /// Returns a copy of this string in the given normal form,
  /// if the result is stable.
  ///
  /// A stable normalization will not change if normalized again
  /// to the same form by any version of Unicode, past or future.
  ///
  /// The result _may not_ be canonically equivalent to this string.
  ///
  public func stableNormalization(
    _ form: Unicode.CompatibilityNormalizationForm
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

Character does not offer a `stableNormalization` function, as the definition of character boundaries is not stable across Unicode versions. While this doesn't technically matter for the purpose of normalisation, it seems wrong to mention stability in the context of characters while their boundaries remain unstable.

Character also does not offer compatibility normalisation, as the compatibility decomposition of a Character may result in multiple Characters. However, Characters may be normalised to their canonical equivalents.

Usage:

```swift
// Here, a database treats keys as binary blobs.
// We normalise at the application level
// to retrofit canonical equivalence for lookups.

func persist(key: String, value: String) throws {
  guard let stableKey = key.stableNormalization(.nfc) else {
    throw UnsupportedKeyError(key)
  }
  try writeToDatabase(binaryKey: stableKey.utf8, value: value)
}

func lookup(key: String) -> String? {
  let normalizedKey = key.normalized(.nfc)
  lookupInDatabase(binaryKey: normalizedKey.utf8)
}

try! persist(key: "cafe\u{0301}", value: "Present")

lookup(key: "caf\u{00E9}") // ✅ "Present"
```


#### The Standard Library's preferred form and documenting String's sort order


String's comparison behaviour sorts canonically-equivalent strings identically, which already implies that it must behave as if its contents were normalised. However, it has never been documented which form it normalises to. We propose documenting it, and moreover documenting it in code:

```swift
extension Unicode.CanonicalNormalizationForm {

  /// The normal form preferred by the Swift Standard Library.
  ///
  /// String's conformance to `Comparable` sorts values
  /// as if their contents were normalized to this form.
  ///
  public static var preferredForm: Self { get }
}
```

This allows developers to use normalisation to achieve predictable performance, with the guarantee that their results are consistent with String's default operators.

```swift
struct NormalizedStringHeap {
  
  // Stores normalised UTF8Views internally
  // for cheaper code-unit level comparisons.
  // [!] Requires String.UTF8View: Comparable
  private var heap: Heap<String.UTF8View> = ...

  mutating func insert(_ element: String) {
    let normalized = element.normalized(.preferredForm)
    heap.insert(normalized.utf8)
  }

  // This needs to be consistent with String.<
  var min: String? {
    heap.min.map { utf8 in String(utf8) }
  }
}
```

If an application would like to take advantage of normalisation but doesn't have a preference for a particular form, the standard library's preferred form should be chosen.


### 2. Custom storage and incremental normalisation


For text in non-String storage, or operations which can early-exit, we propose introducing API which allows developers to lazily normalize any `Sequence<Unicode.Scalar>`. This API is exposed via a new `.normalized` namespace wrapper:

Namespace:

```swift
extension Unicode {

  /// Normalized representations of Unicode text.
  ///
  /// This type exposes `Sequence`s and `AsyncSequence`s which
  /// wrap a source of Unicode scalars and lazily normalize it.
  ///
  @frozen
  public struct NormalizedScalars<Source> { ... }
}

extension Sequence<Unicode.Scalar> {

  /// A namespace providing normalized versions of this sequence's contents.
  ///
  public var normalized: NormalizedScalars<Self> { get }
}
```

Normalised sequence:

```swift
extension Unicode.NormalizedScalars
 where Source: Sequence<Unicode.Scalar> {
  
  /// The contents of the source, normalized to NFD.
  ///
  public var nfd: NFD { get }

  @frozen 
  public struct NFD: Sequence {
    public typealias Element = Unicode.Scalar
  }

  // and same for NFC, NFKD, NFKC.
}
```

Usage:

```swift
struct Trie {

  private class Node {
    var children: [Unicode.Scalar: Node]
    var hasTerminator: Bool
  }

  private var root = Node()

  func contains(_ key: some StringProtocol) -> Bool {
    var node = root
    for scalar in key.unicodeScalars.normalized.nfc {
      guard let next = node.children[scalar] else {
        // Early-exit: 
        // We know that 'key' isn't in this Trie,
        // no need to normalize the rest of it.
        return false
      }
      node = next
    }
    return node.hasTerminator
  }
}
```

We also propose async versions of the above, to complement the `AsyncUnicodeScalarSequence` available in Foundation.

```swift
extension AsyncSequence where Element == Unicode.Scalar {

  /// A namespace providing normalized versions of this sequence's contents.
  ///
  public var normalized: Unicode.NormalizedScalars<Self> { get }
}

extension Unicode.NormalizedScalars
 where Source: AsyncSequence<Unicode.Scalar> {
  
  /// The contents of the source, normalized to NFD.
  ///
  public var nfd: AsyncNFD { get }

  @frozen 
  public struct AsyncNFD: AsyncSequence {
    public typealias Element = Unicode.Scalar
    public typealias Failure = Source.Failure
  }

  // and same for NFC, NFKD, NFKC.
}
```

Usage:

```swift
import Foundation

let url = URL(...)

for try await scalar in url.resourceBytes.unicodeScalars.normalized.nfc {
  // NFC scalars, loaded and normalized on-demand.
}
```

We do **not** propose exposing normalised scalars as a Collection. This is explained in Alternatives Considered.


### 3. Stateful normaliser


While `Sequence` and `AsyncSequence`-level APIs are sufficient for most developers, specialised use-cases may benefit from directly applying the normalisation algorithm. For these, we propose a stateful normaliser, which encapsulates the state of a single "logical" text stream and is fed "physical" chunks of source data.

```swift
extension Unicode {
  
  /// A normalizer representing a single logical text stream.
  ///
  /// The normalizer has value semantics, so it may be copied
  /// and stored indefinitely, and is inherently thread-safe.
  ///
  public struct NFDNormalizer: Sendable {
    
    public init()

    /// Returns the next normalized scalar,
    /// consuming data from the given source if necessary.
    ///
    public mutating func resume(
      consuming source: inout some IteratorProtocol<Unicode.Scalar>
    ) -> Unicode.Scalar?


    /// Returns the next normalized scalar,
    /// iteratively invoking the scalar producer if necessary
    ///
    public mutating func resume(
      scalarProducer: () -> Unicode.Scalar?
    ) -> Unicode.Scalar?

    /// Marks the end of the logical text stream
    /// and returns remaining data from the normalizer's buffers.
    ///
    public mutating func flush() -> Unicode.Scalar?

    /// Resets the normalizer to its initial state.
    ///
    /// Any allocated buffer capacity will be kept and reused
    /// unless it exceeds the given maximum capacity,
    /// in which case it will be discarded.
    ///
    public mutating func reset(maximumCapacity: Int = default)
  }

  // and same for NFC, NFKD, NFKC.
}
```

This construct is vital to the implementation of the generic async streams, and examining that implementation illustrates some important aspects of using this interface.

```swift
struct Unicode.AsyncNFC<Source>.AsyncIterator: AsyncIteratorProtocol {

  var source: Source.AsyncIterator
  var normalizer = Unicode.NFCNormalizer()
  var pending = Optional<Unicode.Scalar>.none

  mutating func next(
    isolation actor: isolated (any Actor)?
  ) async throws(Source.Failure) -> Unicode.Scalar? {

    // Equivalent to: "pending.take() ?? try await source.next()"
    func _pendingOrNextFromSource() async throws(Source.Failure) -> Unicode.Scalar? {
      if pending != nil { return pending.take() }
      return try await source.next(isolation: actor)
    }

    while let scalar = try await _pendingOrNextFromSource() {
      var iter = CollectionOfOne(scalar).makeIterator()
      if let output = normalizer.resume(consuming: &iter) {
        pending = iter.next()
        return output
      }
      assert(iter.next() == nil)
    }

    return normalizer.flush()
  }
}
```

The first time we call `.next()`, the iterator pulls a single Unicode scalar from its upstream source and feeds it to the normaliser. A single scalar is generally not enough to begin emitting normalised content (what if a later scalar composes with this one?), so the normaliser may return `nil`, indicating that it has consumed all content from `iter` but has nothing to return just yet. Eventually, after feeding enough scalars, the normaliser may begin emitting its results (returning a non-nil value `output`). 

It is important to note that when the normaliser returns a non-nil value from `.resume()`, it may not have consumed all data from the iterator. We need to store the iterator somewhere so the normaliser can continue to consume it on subsequent calls to `.next()`, and keep doing so until it returns `nil`. Otherwise, we would accidentally be dropping content.

Because we only have a single scalar we can say `pending = iter.next()`, which is conceptually the same as storing the iterator (we just do it this way because it lets us write slightly neater code, using `_pendingOrNextFromSource` rather than a second loop). Once that is done, we can return the scalar emitted by the normaliser to our caller. All state required by the normalisation algorithm is contained within the stateful normaliser.

Finally, after all pending and upstream content is consumed, we call `flush()` to mark the end of the stream and return any remaining content from the normaliser's internal buffers.

This may seem a bit involved - and it is! This is our lowest-level interface, designed for specialised usecases which cannot easily be adapted to use the higher-level `(Async)Sequence` APIs. Those APIs are built using this one, and should generally be preferred unless there is a good reason to take manual control.

So in which kinds of usecases might one wish to manually apply the normalisation algorithm? For one, there are times where we do not have the entire logical text stream physically in memory, and cannot suspend (i.e. we are not in an async context).

```swift
withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1024) { buffer in
  
  var normalizer = Unicode.NFCNormalizer()

  while let bytesRead = read(from: fd, into: buffer) {
    var scalars = bytes.prefix(bytesRead).makeUnicodeScalarIterator()
    while let nfcScalar = normalizer.resume(consuming: &scalars) {
      process(nfcScalar)
    }
    assert(scalars.next() == nil)
  }

  while let nfcScalar = normalizer.flush() {
    process(nfcScalar)
  }
}
```

Sometimes, we want to normalise lots of strings - perhaps searching for match, or comparing to find an insertion point. Hoisting the normaliser state out of the loop and resetting it allows us to keep any allocated buffer capacity.

```swift
// Many, many strings that are not known to be normalized.
let database: [String] = [...]

func contains(_ key: String) {

  let key = key.normalized(.nfc)
  var normalizer = Unicode.NFCNormalizer()

  NextWord: for word in database {

    // Reset the normalizer, but keep any allocated capacity.
    normalizer.reset()

    // Use the normalizer to process 'word', 
    // early-exiting as soon as it diverges from 'key'.
    var keyScalars  = key.unicodeScalars.makeIterator()
    var wordScalars = word.unicodeScalars.makeIterator()

    while let scalar = normalizer.resume(consuming: &wordScalars) ?? normalizer.flush() {
      guard scalar == keyScalars.next() else { 
        continue NextWord
      }
    }

    // Check that we matched the entirety of 'key'.
    if keyScalars.next() == nil {
      return true
    }
  }

  return false
}
```

The closure-taking API is useful for situations where an instance of `IteratorProtocol` cannot be formed, such as when it is derived from the contents of a non-escapable type such as `UTF8Span`.

```swift
extension UTF8Span {
  func nthNormalizedScalar(
    _ n: Int
  ) -> Unicode.Scalar? {
    var normalizer = NFCNormalizer()
    var pos = 0
    var count = 0

    while true {
      guard let s = normalizer.resume(scalarProducer: {
        guard pos < count else {
          return nil
        }
        let (scalar, next) = self.decodeNextScalar(
          uncheckedAssumingAligned: pos)
        pos = next
        return scalar
      }) else {
        return nil
      }

      if count == n { return s }
      count += 1
    }
  }
}
```

### Other Additions


We propose a range of minor additions related to the use of the above API.


#### Unicode.Scalar properties


So that streaming use-cases can efficiently produce stabilised strings, we will add a `.isUnassigned` property to `Unicode.Scalar`:

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

We will also add "Quick Check" properties, which are useful in a range of Unicode algorithms.

```swift
extension Unicode {

  @frozen
  public enum QuickCheckResult {
    case yes
    case no
    case maybe
  }
}

extension Unicode.Scalar.Properties {

  // The QC properties for decomposed forms
  // always return yes or no.

  public var isNFD_QC: Bool  { get }
  public var isNKFD_QC: Bool { get }

  // The QC properties for precomposed forms
  // can return "maybe".

  public var isNFC_QC: Unicode.QuickCheckResult  { get }
  public var isNFKC_QC: Unicode.QuickCheckResult { get }
}
```


#### Checking for Normalisation


It is possible to efficiently check whether text is already normalised. We offer this on all of the types mentioned above that are used for storing text:

- `StringProtocol` (String/Substring)
- `Character`
- `Sequence<Unicode.Scalar>`
- `Collection<Unicode.Scalar>`
- `AsyncSequence where Element == Unicode.Scalar`

```swift
extension Sequence<Unicode.Scalar> {

  public func isNormalized(
    _ form: Unicode.CanonicalNormalizationForm
  ) -> Bool

  public func isNormalized(
    _ form: Unicode.CompatibilityNormalizationForm
  ) -> Bool
}
```

Of note, we offer a test for compatibility normalisation on `Character` even though it does not have a `.normalized()` function for compatibility forms. Also, there is a unique implementation for `Collection` which can be more efficient than the one for single-pass sequences.

The results of these functions are definite, with no false positives or false negatives.


#### Add common protocol conformances to String views


String's default comparison and equivalence operations ensure applications handle Unicode text correctly. Once we add normalisation APIs, developers will be able to take manual control over how these semantics are implemented - for instance, by ensuring all data in a `Heap` is normalised to the same form for efficient comparisons.

However, String does not always know when its contents are normalised. Instead, a developer who is maintaining this invariant themselves should be able to easily opt-in to code-unit or scalar level comparison semantics.

```swift
struct NormalizedStringHeap {

  // [!] Requires String.UTF8View: Comparable
  var heap: Heap<String.UTF8View> = ...

  mutating func insert(_ element: String) {
    // .insert performs O(log(count)) comparisons.
    //
    // Now they are guaranteed to be simple binary comparisons,
    // with no allocations or table lookups,
    // while having the same semantics as String.<
    heap.insert(aString.normalized(.preferredForm).utf8)
  }
}
```

We propose adding the following conformances to String's `UTF8View`, `UTF16View`, and `UnicodeScalarView`:

- `Equatable`. Semantics: Exact code-unit/scalar match.
- `Hashable`. Semantics: Must match Equatable.
- `Comparable`. Semantics: Lexicographical comparison of code-units/scalars.

These conformances will likely also be useful for embedded applications, where String itself may lack them.


#### Creating a String or Character from Scalars


This is a straightforward gap in String's API.

```swift
extension String {
  public init(_: some Sequence<Unicode.Scalar>)
}

extension Character {
  /// Returns `nil` if more than one extended grapheme cluster
  /// is present.
  public init?(_: some Sequence<Unicode.Scalar>)
}
```


## Source compatibility


The proposed interfaces are additive and do not conflict with Foundation's existing normalisation API.


## ABI compatibility


This proposal is purely an extension of the ABI of the standard library and does not change any existing features.

The proposed interface is designed to minimise ABI commitments. The standard library's internal Unicode data structures and normalisation implementation are not committed to ABI. All other interfaces are built using the stateful normaliser, which is resilient and its core functions are non-inlinable.


## Implications on adoption


The proposed APIs will require a new version of the standard library. They are not backwards-deployable because they involve new types.


## Future directions


### NormalizedString type


This proposal has mentioned a few times that String does not always know when its contents are normalised, and sometimes developers need to maintain that invariant manually as part of their data structure design. One could imagine a `NormalizedString` type which _is_ always known to be normalised.

The interfaces exposed by this proposal could be used to prototype such a type in a package.


### Normalizing append, inits


We have mentioned that normalisation is not closed to concatenation:

> even if two strings X and Y are normalized, their string concatenation X+Y is not guaranteed to be normalized.

We could offer a normalising `.append` operation, which produces a normalised result by only normalising the boundary between X and Y. This could be something for the aforementioned `NormalizedString`.

We could also offer `String` initialisers which normalise their contents. There are many String initialisers and it is not clear how best to integrate normalisation with them, so we would rather subset it out of this proposal (which is large enough as it is).


### Related forms


There are some non-standard normalisation (and adjacent) forms:

- Fast C or D ("FCD") is not technically a normalisation form (different FCD strings can be canonically equivalent), but it can be checked efficiently and allow full normalisation to be avoided if one has specifically-prepared data tables.

- Fast C Contiguous ("FCC") is a variant of NFC which passes the FCD test.

- NFKC is very often immediately case-folded. Unicode even publishes separate NFKC_CaseFold tables to perform this transformation in a single step, and Swift's `Unicode.Scalar.Properties` already includes a `.changesWhenNFKCCaseFolded` property.

We could certainly add support for any/all of these in future proposals. Nothing in this proposal should be understood as precluding any of the above.


### NormalizationSegments view


Unicode text can be considered as a series of normalisation segments - regions of text which can be normalised independently of each other. This is useful for things like substring matching. It would be useful to expose these segments for more advanced processing in custom text storage, and to allow normalised substring searches.


### Advanced Quick Checks


It would be useful to explore how we can use Quick Check results to speed up later normalisation. String already has this built-in, so if you write:

```swift
let nfcString = someString.normalized(.nfc)

for scalar in nfcString.unicodeScalars.normalized.nfc {
  ...
}
```

`nfcString` may have an internal performance bit set so we know it is NFC. If it does, the streaming normaliser in the `for`-loop detects this and knows it doesn't need to normalise the contents a second time. It would be nice if we could generalise this, or at least take note of a normalised prefix that we can skip.

### Normalizing intializers

We could define initializers similar to `String(decoding:as)`, e.g. `String(normalizing:)`, which decode and transform the contents into the stdlib's preferred normal form without always needing to create an intermediary `String` instance. Such strings will compare much faster to each other, but may have different contents when viewed under the `UnicodeScalarView`, `UTF8View`, or `UTF16View`.

### Normalized code units

Normalization API is presented in terms of `Unicode.Scalar`s, but a lower-level interface might run directly on top of (validated) UTF-8 code units. Many useful normalization fast-paths can be implemented directly on top of UTF-8 without needing to decode. 

For example, any `Unicode.Scalar` that is less than `U+0300` is in NFC and can be skipped over for NFC normalization. In UTF-8, this amounts to skipping until we find a byte that is `0xCC` or larger.


### Protocol abstraction

The normalization process itself is an algorithm that is ran over data tables. Future work could include protocols that run the algorithm but allow libraries to provide their own modified or version-specific data tables.

## Alternatives considered


### Naming


**`StringProtocol.stableNormalization`**

An alternative name for this could be `.stabilized`, which is closer to the name used by Unicode ("Stabilised String") and grammatically similar to `.normalized` (both adjectives which describe the result).

But `.stabilized` by itself is a bit vague - it doesn't describe what is happening as well as `.stableNormalization` does, and the latter is more likely to appear in autocomplete next to `.normalized`, which gives developers an important clue that the result of `.normalized` may not be stable. `.normalizedIfStable` is another option, but doesn't flow as nicely and is arguably even further from the technical term.

Alternatively, we could use a noun for `.normalize` as well (making it `.normalization`), but that would be inconsistent with other properties such as `.uppercased()`, `.lowercased()`, `.sorted()`, `.shuffled()`, etc.

While the asymmetry is very slightly irksome, on balance it seems like the best option.


### Lazily-normalised Collections


We only propose API for producing a normalised `Sequence` of scalars - which can be iterated over, but does not include a built-in notion of position that one can resume from or create slices between. While it is possible to invent such a concept, it comes with some important drawbacks and may not actually prove to be useful in practice.

The first drawback is performance. There are essentially two ways to implement such an index:

1. A thin index, containing an offset.

  The index does not contain any state from the normaliser, meaning indexing operations such as `index(after:)` must traverse a significant amount of content. Unfortunately, this means simple loops become quadratic:

  ```swift
  let lazyNormalized = someScalars.normalized.nfc

  var i = lazyNormalized.startIndex
  while i < lazyNormalized.endIndex {
    // Computing the next index would be O(n),
    // so doing it n times would be quadratic.
    lazyNormalized.formIndex(after: &i)
  }
  ```

  We could attempt to use offsets from the start of a normalisation segment (a place where we can cleanly start normalising from) to reduce the amount that needs to be traversed, but ultimately there is no limit to the length of a normalisation segment.

2. A fat index, containing the stateful normaliser.

  The previous strategy suffered from the fact that indexes did not capture the entire state of the normalisation algorithm. To solve this, we could stash a stateful normaliser in the index. This works, and it solves the complexity issue, but non-trivial indexes come with their own set of challenges. For instance, `startIndex` must a stored property so it can be returned in constant time, but doing so means that simple loops like the one above will involve _at least_ one copy-on-write. And this applies to any attempt to store indexes.

  ```swift
  var i = lazyNormalized.startIndex
  lazyNormalized.formIndex(after: &i) // COW 🐮

  importantIndexes.append(i)
  lazyNormalized.formIndex(after: &i) // COW 🐮
  ```

  Many generic Collection algorithms will not expect indexes to be so heavyweight, and it is likely that lazy normalisation will stop being worth it as the number of stored indexes and repeated traversals grows - developers would likely be better served eagerly copying to an Array in this case.

The second drawback is that we cannot easily map elements of the result back to locations in the source data. This would be perhaps the most useful feature of a Collection interface; for instance, when searching for a substring, simply knowing whether the substring is _present_ is often not enough -- we also want to know _which portion_ of the original contents match the substring (so we could highlight it in a user interface or something).

However, normalisation may break scalars apart (so multiple locations in the result would map to a single source location), join them (a single location in the result maps to multiple source locations), and reorder them. While we _could in theory_ maintain provenance information throughout the normalisation process, it would likely be a significant detriment to performance and the results would not make much intuitive sense.

For instance, consider the following:

```
original: <U+1EA5, U+0328>         ( ấ - LATIN SMALL LETTER A WITH CIRCUMFLEX AND ACUTE,  ̨ - COMBINING OGONEK )
NFC:      <U+0105, U+0302, U+0301> ( ą - LATIN SMALL LETTER A WITH OGONEK,  ̂ - COMBINING CIRCUMFLEX ACCENT,  ́ - COMBINING ACUTE ACCENT)
```

What happened was that the precomposed scalar in the original text was broken apart, and it turns out that composition prefers the ogonek, and the result does not compose with any of the other combining marks. In terms of mapping to source indexes, we get the following table:

| Result Index | Corresponding Source Indexes |
|--------------|------------------------------|
| 0            | [0, 1]                       |
| 1            | 0                            |
| 2            | 0                            |

This kind of information is difficult for applications to process on arbitrary strings. Moreover, it encourages misunderstandings when matching substrings - if a program searches for the single scalar "ą" (small a with ogonek) in a lazy NFC Collection, it would find it, and map the result to the sequence of source scalars 0...1. But that's not a correct result: that range of source scalars contains other accents, too.

What this shows is that when matching substrings, we need to match entire normalisation segments, not individual scalars - the _sequences_ shown above are equivalent, but the particular scalars involved and their provenance (which scalars were merged, which were split, etc) are not particularly relevant. If a developer wants to know which portion of a string matches a substring, they should track source locations at the level of entire segments (which is much more straightforward). We could offer this kind of Collection view in future.

Indeed, this is what Swift's Regex type does. Canonical equivalence requires matching with `Character` semantics, which are naturally aligned on normalisation segment boundaries.

In summary, we feel a lazily-normalising scalar-to-scalar Collection is not the best interface to expose. The public API we _will_ expose is capable enough to allow a basic interface to be built ([example](https://gist.github.com/karwa/863de5648e3b2bdb59bfebd4c1871a82)), but it is not a good fit for the standard library.

### Normal forms and data tables

The stdlib currently ships data tables which support NFC and NFD normal forms. The stdlib does not currently ship NFKC and NFKD data tables. NFKC and NFKD are for purposes other than checking canonical equivalence, and as such it may make sense to relegate those API to another library instead of the stdlib, such as swift-foundation.

### Stability queries instead of stable-string producing API

This pitch proposes `String.stableNormalization(...) -> String?` which will produce a normalized string if the contents are stable under any version of Unicode.

An alternative formulation could be stability queries on String. For example, asking whether the contents are stable in any Unicode version since 4.1, forwards-stable from the processes's current version of Unicode onwards, the latest version of Unicode form which it's contents are stable, etc.

### Swift version instead of Unicode versions

Each version of Swift implements a particular version of Unicode. When we talk about stable, we are referring to stability across versions of Unicode and not necessarily tied to versions of Swift. Swift may fix bugs in its implementation of a particular version of Unicode.

### Codifying the stdlib's preferred normal form

The stdlib internally uses NFC as its normal form of choice. It is significantly more compact than NFD (which is also why content is often already stored in NFC) and has better fast-paths for commonly used scripts. However, this is not currently established publicly. We could establish this in this proposal, whether with different names or in doc comments.

### Init of `NormalizedScalars` instead of extension on Sequence

We pitch an extension on `Sequence<Unicode.Scalar` which can construct a `NormalizedScalars`. Alternatively, we could have an init on `NormalizedScalars` taking the sequence, which would have more constrained visibility. We could also have both.




## Acknowledgments


[Alejandro Alonso](https://github.com/azoy) originally implemented normalisation in the standard library. The proposed interfaces build on his work.