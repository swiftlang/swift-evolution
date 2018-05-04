# Character Properties
* Proposal: TBD
* Authors: [Michael Ilseman](https://github.com/milseman), [Tony Allevato](https://github.com/allevato)
* Review Manager: TBD
* Status: TBD
* Implementation: https://github.com/apple/swift/pull/15880

## Introduction

@allevato (a co-author here) proposed [Add Unicode Properties to Unicode.Scalar](https://github.com/apple/swift-evolution/blob/master/proposals/0211-unicode-scalar-properties.md), which exposes Unicode properties from the [Unicode Character Database](http://unicode.org/reports/tr44/). These are Unicode expert/enthusiast oriented properties that give a finer granularity of control and answer highly-technical and specific Unicody enquiries.

However, they are not ergonomic and Swift makes no attempt to clarify their interpretation or usage: meaning and proper interpretation is directly tied to the Unicode Standard and the version of Unicode available at run time. There's some low-hanging ergo-fruit ripe for picking by exposing properties directly on `Character`.

Pitch thread: [Character and String properties](https://forums.swift.org/t/pitch-character-and-string-properties/11620)

## Motivation

`String` is a collection whose element is `Character`, which represents an [extended grapheme cluster](https://unicode.org/reports/tr29/#Grapheme_Cluster_Boundaries) (commonly just called “grapheme”).  This makes `Character` one of the first types encountered both by newcomers to Swift as well as by experienced Swift developers playing around in new domains (e.g. scripting). Yet `Character` exposes little functionality other than the ability to order it with respect to other characters, and a way to access the raw [Unicode scalar values](https://unicode.org/glossary/#unicode_scalar_value) that comprise it.

This proposal adds several queries to increase the usefulness of `Character` and approachability of programing in Swift. It tries to walk the fuzzy line between what Swift can give reasonably good answers to, and what would require the user to adopt more elaborate linguistic analysis frameworks or techniques.

## Proposed Solution
(Note that Unicode does not define properties on graphemes in general. Swift is defining its own semantics in terms of Unicode semantics derived from scalar properties, semantics on strings, or both)

### Character Properties

```swift
extension Character {
  /// Whether this Character is ASCII.
  @inlinable
  public var isASCII: Bool { return asciiValue != nil }

  /// Returns the ASCII encoding value of this Character, if ASCII.
  ///
  /// Note: "\r\n" (CR-LF) is normalized to "\n" (LF), which will return 0x0A
  @inlinable
  public var asciiValue: UInt8? {
    if _slowPath(self == ._crlf) { return 0x000A /* LINE FEED (LF) */ }
    if _slowPath(!_isSingleScalar || _firstScalar.value >= 0x80) { return nil }
    return UInt8(_firstScalar.value)
  }

  /// Whether this Character represents whitespace, including newlines.
  ///
  /// Examples:
  ///   * "\t" (U+0009 CHARACTER TABULATION)
  ///   * " " (U+0020 SPACE)
  ///   * U+2029 PARAGRAPH SEPARATOR
  ///   * U+3000 IDEOGRAPHIC SPACE
  ///
  public var isWhitespace: Bool { ... }

  /// Whether this Character represents a newline.
  ///
  /// * "\n" (U+000A): LINE FEED (LF)
  /// * "\r" (U+000D): CARRIAGE RETURN (CR)
  /// * "\r\n" (U+000A U+000D): CR-LF
  /// * U+0085: NEXT LINE (NEL)
  /// * U+2028: LINE SEPARATOR
  /// * U+2029: PARAGRAPH SEPARATOR
  ///
  public var isNewline: Bool { ... }

  /// Whether this Character represents a number.
  ///
  /// Examples:
  ///   * "7" (U+0037 DIGIT SEVEN)
  ///   * "⅚" (U+215A VULGAR FRACTION FIVE SIXTHS)
  ///   * "㊈" (U+3288 CIRCLED IDEOGRAPH NINE)
  ///   * "𝟠" (U+1D7E0 MATHEMATICAL DOUBLE-STRUCK DIGIT EIGHT)
  ///   * "๒" (U+0E52 THAI DIGIT TWO)
  ///
  public var isNumber: Bool { ... }

  /// Whether this Character represents a whole number. See
  /// `Character.wholeNumberValue`
  @inlinable
  public var isWholeNumber: Bool { return wholeNumberValue != nil }

  /// If this Character is a whole number, return the value it represents, else
  /// nil.
  ///
  /// Examples:
  ///   * "1" (U+0031 DIGIT ONE) => 1
  ///   * "५" (U+096B DEVANAGARI DIGIT FIVE) => 5
  ///   * "๙" (U+0E59 THAI DIGIT NINE) => 9
  ///   * "万" (U+4E07 CJK UNIFIED IDEOGRAPH-4E07) => 10_000
  ///
  public var wholeNumberValue: Int? { ... }

  /// Whether this Character represents a hexadecimal digit.
  ///
  /// Hexadecimal digits include 0-9, Latin letters a-f and A-F, and their
  /// fullwidth compatibility forms. To get their value, see
  /// `Character.hexadecimalDigitValue`
  @inlinable
  public var isHexadecimalDigit: Bool { return hexadecimalDigitValue != nil }

  /// If this Character is a hexadecimal digit, returns the value it represents,
  /// else nil.
  ///
  /// Hexadecimal digits include 0-9, Latin letters a-f and A-F, and their
  /// fullwidth compatibility forms.
  public var hexadecimalDigitValue: Int? { ... }

  /// Whether this Character is a letter.
  ///
  /// Examples:
  ///   * "A" (U+0041 LATIN CAPITAL LETTER A)
  ///   * "é" (U+0065 LATIN SMALL LETTER E, U+0301 COMBINING ACUTE ACCENT)
  ///   * "ϴ" (U+03F4 GREEK CAPITAL THETA SYMBOL)
  //   * "ڈ" (U+0688 ARABIC LETTER DDAL)
  ///   * "日" (U+65E5 CJK UNIFIED IDEOGRAPH-65E5)
  ///   * "ᚨ" (U+16A8 RUNIC LETTER ANSUZ A)
  ///
  public var isLetter: Bool { ... }

  /// Perform case conversion to uppercase
  ///
  /// Examples:
  ///   * "é" (U+0065 LATIN SMALL LETTER E, U+0301 COMBINING ACUTE ACCENT)
  ///     => "É" (U+0045 LATIN CAPITAL LETTER E, U+0301 COMBINING ACUTE ACCENT)
  ///   * "и" (U+0438 CYRILLIC SMALL LETTER I)
  ///     => "И" (U+0418 CYRILLIC CAPITAL LETTER I)
  ///   * "π" (U+03C0 GREEK SMALL LETTER PI)
  ///     => "Π" (U+03A0 GREEK CAPITAL LETTER PI)
  ///   * "ß" (U+00DF LATIN SMALL LETTER SHARP S)
  ///     => "SS" (U+0053 LATIN CAPITAL LETTER S, U+0053 LATIN CAPITAL LETTER S)
  ///
  /// Note: Returns a String as case conversion can result in multiple
  /// Characters.
  @inlinable
  public func uppercased() -> String { return String(self).uppercased() }

  /// Perform case conversion to lowercase
  ///
  /// Examples:
  ///   * "É" (U+0045 LATIN CAPITAL LETTER E, U+0301 COMBINING ACUTE ACCENT)
  ///     => "é" (U+0065 LATIN SMALL LETTER E, U+0301 COMBINING ACUTE ACCENT)
  ///   * "И" (U+0418 CYRILLIC CAPITAL LETTER I)
  ///     => "и" (U+0438 CYRILLIC SMALL LETTER I)
  ///   * "Π" (U+03A0 GREEK CAPITAL LETTER PI)
  ///     => "π" (U+03C0 GREEK SMALL LETTER PI)
  ///
  /// Note: Returns a String as case conversion can result in multiple
  /// Characters.
  @inlinable
  public func lowercased() -> String { return String(self).lowercased() }

  @inlinable
  internal var _isUppercased: Bool { return String(self) == self.uppercased() }
  @inlinable
  internal var _isLowercased: Bool { return String(self) == self.lowercased() }

  /// Whether this Character is considered uppercase.
  ///
  /// Uppercase Characters vary under case-conversion to lowercase, but not when
  /// converted to uppercase.
  ///
  /// Examples:
  ///   * "É" (U+0045 LATIN CAPITAL LETTER E, U+0301 COMBINING ACUTE ACCENT)
  ///   * "И" (U+0418 CYRILLIC CAPITAL LETTER I)
  ///   * "Π" (U+03A0 GREEK CAPITAL LETTER PI)
  ///
  @inlinable
  public var isUppercase: Bool { return _isUppercased && isCased }

  /// Whether this Character is considered lowercase.
  ///
  /// Lowercase Characters vary under case-conversion to lowercase, but not when
  /// converted to uppercase.
  ///
  /// Examples:
  ///   * "é" (U+0065 LATIN SMALL LETTER E, U+0301 COMBINING ACUTE ACCENT)
  ///   * "и" (U+0438 CYRILLIC SMALL LETTER I)
  ///   * "π" (U+03C0 GREEK SMALL LETTER PI)
  ///
  @inlinable
  public var isLowercase: Bool { return _isLowercased && isCased }

  /// Whether this Character changes under any form of case conversion.
  @inlinable
  public var isCased: Bool { return !_isUppercased || !_isLowercased }

  /// Whether this Character represents a symbol
  ///
  /// Examples:
  ///   * "®" (U+00AE REGISTERED SIGN)
  ///   * "⌹" (U+2339 APL FUNCTIONAL SYMBOL QUAD DIVIDE)
  ///   * "⡆" (U+2846 BRAILLE PATTERN DOTS-237)
  ///
  public var isSymbol: Bool { ... }

  /// Whether this Character represents a symbol used in mathematical formulas
  ///
  /// Examples:
  ///   * "+" (U+002B PLUS SIGN)
  ///   * "∫" (U+222B INTEGRAL)
  ///   * "ϰ" (U+03F0 GREEK KAPPA SYMBOL)
  ///
  /// Note: This is not a strict subset of isSymbol. This includes characters
  /// used both as letters and commonly in mathematical formulas. For example,
  /// "ϰ" (U+03F0 GREEK KAPPA SYMBOL) is considered a both mathematical symbol
  /// and a letter.
  ///
  public var isMathSymbol: Bool { ... }

  /// Whether this Character represents a currency symbol
  ///
  /// Examples:
  ///   * "$" (U+0024 DOLLAR SIGN)
  ///   * "¥" (U+00A5 YEN SIGN)
  ///   * "€" (U+20AC EURO SIGN)
  public var isCurrencySymbol: Bool { ... }

  /// Whether this Character represents punctuation
  ///
  /// Examples:
  ///   * "!" (U+0021 EXCLAMATION MARK)
  //   * "؟" (U+061F ARABIC QUESTION MARK)
  ///   * "…" (U+2026 HORIZONTAL ELLIPSIS)
  ///   * "—" (U+2014 EM DASH)
  ///   * "“" (U+201C LEFT DOUBLE QUOTATION MARK)
  ///
  public var isPunctuation: Bool { ... }
}
```

(example bodies of `@inlinable` methods are provided to demonstrate the semantic requirements impacted by ABI stability. They are not necessarily the most efficient implementation possible).

Additionally, we propose an explicit `ascii:` label be added to `FixedWidthInteger`’s failable init from a `String`, and an additional one defined over `Character`. We argue the old name is harmful and an explicit label more closely adheres to the [API Design Guidelines](https://swift.org/documentation/api-design-guidelines/). See “Detailed Semantics and Rationale” below.

```diff
- FixedWidthInteger.init?<S: StringProtocol>(_: S, radix: Int = 10)
+ FixedWidthInteger.init?<S: StringProtocol>(ascii: S, radix: Int = 10)
+ FixedWithInteger.init?(ascii: Character, radix: Int = 10)
```


## Detailed Semantics and Rationale

Some fuzziness is inherent in modeling human writing systems and the rules of grapheme breaking allow for semantically meaningless, yet technically valid, graphemes. In light of all this, we make a best effort and try to discover some principle to follow. Principles are useful for evaluating tradeoffs, but are not hard rules that always lead to a single clear answer.

The closest applicable principle might be something similar to W3C’s [Principle of Tolerance](https://www.w3.org/DesignIssues/Principles.html), paraphrased as “Be liberal in what you accept, conservative in what you produce”. Perhaps another phrasing could be “Be permissive when fuzzy, restrictive when specific”. 

### Restrictive When Specific

Properties that provide a clear interpretation or which the stdlib produces a specific value for should be restrictive. One example is `wholeNumberValue`. `wholeNumberValue` *produces* an `Int` from a `Character`, which means it needs to be *restrictive*, permitting only the graphemes with unambiguous whole number values. It only returns a value for single-scalar graphemes whose sole scalar has an integral numeric value. Thus, `wholeNumberValue` returns nil for “7̅” (7 followed by U+0305 COMBINING OVERLINE) as there is no clear interpretation of the value. Any attempt to produce a specific integer from “7̅” would be suspect.

### Permissive When Fuzzy

Where there is no clear interpretation or specific value to produce, we try to be as permissive as reasonable. For example, `isLetter` just queries the first scalar to see if it is “letter-like”, and thus handles unforeseeable combinations of a base letter-like scalar with subsequent combining, modifying, or extending scalars. `isLetter` merely answers a general (fuzzy) question, but doesn’t prescribe further interpretation.

Permissive APIs should in general be non-inlinable and their documentation may be less precise regarding details and corner cases. This allows for a greater degree of library evolution.

### API Semantics

Below is a grouping of semantics into “restrictive”, which means accept/reject based on analysis of the entire grapheme, and “permissive”, which means accept/reject based on analysis of a portion of the grapheme.

Restrictive:

* Values:  `isASCII` / `asciiValue`, `isWholeNumber` / `wholeNumberValue`, `isHexDigit` / `hexDigitValue`
* Casing:  `isUppercase` / `uppercased()`, `isLowercase` / `lowercased()`, `isCased`

Permissive:

* Fuzzy queries: `isNumber`, `isLetter`, `isSymbol` / `isMathSymbol` / `isCurrencySymbol`, `isPunctuation`
* Whitespace (maybe*): `isWhitespace` and `isNewline` 

\* Newlines encompass more than hard line-breaks in traditional written language; they are common terminators for programmer strings. If a `Character` is “\n\u{301}” (a newline with a combining accent over it), is this a newline? Either interpretation can lead to inconsistencies. If true, then a program might skip the first scalar in a new entry (whatever such a combining scalar at the start could mean). If we say false, then a `String` with newline terminators inside of it would return false for `myStr.contains { $0.isNewline }`, which is counter-intuitive. This same reasoning may apply to whitespace.

A couple options:

1. Permissive, to keep consistency with `myStr.contains { $0.isNewline }`, and is consistent with grapheme-by-grapheme processing concerns in general
2. Restrictive, to prevent the programmer from skipping over relevant scalars, at the risk of counter-intuitive string processing behavior
3. Rename to `hasNewline`, keeping permissive semantics
4. Drop from this pitch in favor of an eventual `String.lines` or something similar.

We think choice #1 is arguably less bad than #2 and more directly reflects the messy reality of grapheme-by-grapheme processing. We slightly prefer #1 to choice #3 or #4 as #1 is a common sense query that we feel Swift should be able to answer. Though it does permit some meaningless graphemes, we don’t see any clearly harmful behavior as a result for realistic inputs, nor anticipate malicious behavior for malicious inputs. But, we could easily be convinced either way (see Considered Alternatives below).

### Adding `ascii:` Label to `FixedWidthInteger.init?<S: StringProtocol>(_: S, radix: Int = 10)`

We argue that the `ascii:` label is required to clarify two primary ambiguities: the kinds of digits accepted and the encoding subset supported.

The existence of support for radices up to 36 implies that the kinds of digits accepted be restricted to Latin numerals and consecutively-encoded Latin letters (i.e. hexadecimal digits along with the next 20 letters). This is quite a mental leap to make without an explicit label. Additionally, this initializer rejects fullwidth compatibility forms which are otherwise considered digits with radices (i.e. they are hexadecimal digits with similar subsequent 20 letters).

We argue that the rules regarding omitting argument label for value-preserving type conversions do not apply as this initializer is not monomorphic due to casing.

This label’s clarity is more apparent in the proposed `FixedWithInteger.init?(ascii: Character, radix: Int = 10)`, and would preserve clarity with more-permissive initializers in the future.

## Source Compatibility
The properties on `Character` are strictly additive. The addition of the `ascii:` label to `FixedWithInteger.init(_:String,radix:Int)` will need to go through the normal unavailable/renamed deprecation process.

## Effect on ABI Stability
Most of these changes are additive: they introduce new ABI surface area to keep stable.

### `@inlinable` and Non-`@inlinable` Properties

`@inlinable` affects the ABI stability and library evolution impact of a change. `@inlinable`’s sweet spot hits APIs that are extremely unlikely to change their semantics and are frequently used or often part of a program’s “hot path”. ASCII-related queries check both of these boxes. For other properties whose semantics can be expressed entirely in terms of other API, `@inlinable` allows the optimizer to optimize across multiple calls and specific usage without giving up a meaningful degree of library evolution. `isWholeNumber` checking `wholeNumberValue` for `nil` is an example of this, as these two methods are semantically tied and the optimizer could (in theory) reuse the result of one for the other. We can always safely supply a new finely-tuned implementation of `isWholeNumber` in future versions of the stdlib, provided semantics are equivalent.

Properties where we may change our strategy (or details of implementation) to accommodate future versions of Unicode and unanticipated changes or corner-cases should be non-`@inlinable`.

## Additions and Alternatives Considered

### Titlecase

Titlecase can be useful for some legacy scalars (ligatures) as well as for Strings when combined with word-breaking logic. However, it seems pretty obscure to surface on Character directly.

### String.Lines, String.Words

These have been deferred from this pitch to keep focus and await a more generalized lazy split collection.

### Rename Permissive `isFoo` to `hasFoo`

This was mentioned above in discussion of `isNewline` semantics and could also apply to `isWhitespace`. However, it would be awkward for `isNumber` or `isLetter`. What the behavior should be for exotic whitespace and newlines is heavily debatable. We’re sticking to `isNewline/isWhitespace` for now, but are open to argument.

### Design as `Character.has(OptionSet<…>, exclusively: …)`

There could be something valuable to glean from this, but we reject this approach as somewhat un-Swifty with a poor discovery experience, especially for new or casual users. It does, however, make the semantic distinctions above very explicit at the call site.

### Add Failable FixedWidthInteger/FloatingPoint Initializers Taking Character

In addition to (or perhaps instead of) properties like `wholeNumberValue`, add `Character`-based `FixedWidthInteger.init?(_:Character)`. Similarly `FloatingPoint.init?(_:Character)` which includes vulgar fractions and the like (if single-scalar, perhaps). However, these do not have direct counterparts in this pitch as named, at least without an explicit argument label clarifying their semantics.

We could consider adding something like `FixedWidthInteger.init?(hexDigit: Character)` and `FixedWithInteger.init?(wholeNumber: Character)` which correspond to `hexDigitValue` and `wholeNumberValue`, and similarly a counterpart for `String`. But, we don’t feel this carries it weight as surfaced directly at the top level of e.g. `Int`. We prefer to keep this avenue open for future directions involving more general number parsing and grapheme evaluation logic.

### Keep `FixedWidthInteger.init(_:radix:)` around, or change `FixedWidthInteger.init(_:radix:) to support full-width compatibility forms`

Rather than rename with an `ascii:` label, keep the old name around to be built upon later with a general number parsing system. We argue that the radix argument makes such an API highly dubious if not constrained to ASCII and full-width compatibility forms (e.g. akin to proposed `Character.hexDigitValue`).

Another alternative is to change the semantics to also accept full-width compatibility forms. Much of the argument for why the API should have an explicit label still apply, though the `radix` label does provide some prodding when provided. We’d prefer the explicit label if possible, but this could be a lessor of evils source-compatibility-preserving alternative.

### Drop `isASCII/HexDigit/WholeNumber`: Check for `nil` Instead

This alternative is to drop `isASCII`, `isHexDigit`, and `isWholeNumber` and instead use `if let` or compare explicitly to `nil`.

We decided to provide these convenience properties both for discoverability as well as use in more complex expressions: `c.isHexDigit && c.isLetter`, `c.isASCII && c.isWhitespace`, etc. We don’t think they add significant weight or undue API surface area.
