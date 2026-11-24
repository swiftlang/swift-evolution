# Add `bidiClass` to `Unicode.Scalar.Properties`

* Proposal: [SE-0559](0559-unicode-bidi-class.md)
* Authors: [Chris Chapman](https://github.com/cjchapman), [Michael Ilseman](https://github.com/milseman)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active review (October 21...November 4, 2026)**
* Implementation: [swiftlang/swift#91404](https://github.com/swiftlang/swift/pull/91404)
* Review: ([pitch](https://forums.swift.org/t/pitch-add-bidiclass-to-unicode-scalar-properties/89097)) ([review](https://forums.swift.org/t/se-0559-add-bidiclass-to-unicode-scalar-properties/90186))

## Summary of changes

Adds a `bidiClass` property to `Unicode.Scalar.Properties` that returns a scalar's Unicode `Bidi_Class`, along with a new `Unicode.BidiClass` type to represent its values.

## Motivation

`Unicode.Scalar.Properties` exposes many of the scalar properties defined by the Unicode Standard, but not `Bidi_Class`, the classification that drives the Unicode Bidirectional Algorithm ([UAX #9](https://www.unicode.org/reports/tr9/)).

Code that lays out or transforms bidirectional text needs each scalar's `Bidi_Class`. An example task is deciding whether a piece of text must be wrapped in the isolate controls `U+2068 FIRST STRONG ISOLATE` and `U+2069 POP DIRECTIONAL ISOLATE` before being embedded in surrounding text of the opposite direction, so that it does not reorder its neighbors. That decision requires knowing whether the text contains strong-directional or numeric scalars, which is exactly what `Bidi_Class` reports. The closely related `generalCategory` is not a substitute: it does not distinguish a strong left-to-right letter from a strong right-to-left one.

Today this value must come from elsewhere, and the most direct source, the system's ICU library, is the same pain point described in [SE-0211](0211-unicode-scalar-properties.md). Swift's Foundation ran into this when implementing list-item isolate wrapping in `ListFormatStyle`.

## Proposed solution

We add a `bidiClass` computed property to `Unicode.Scalar.Properties`, and a `Unicode.BidiClass` enum for its values, paralleling the existing `generalCategory` property and `Unicode.GeneralCategory` enum:

```swift
let scalar: Unicode.Scalar = "\u{05D0}"  // HEBREW LETTER ALEF
scalar.properties.bidiClass  // .rightToLeft
```

Every scalar has a defined `Bidi_Class`: scalars not explicitly assigned one, including unassigned code points, take a code-point-based default. So `bidiClass` returns a value for every `Unicode.Scalar`.

## Detailed design

`Unicode.BidiClass` is a non-frozen enum with one case per `Bidi_Class` value. It is annotated `@objc` so that it has a fixed, single-byte layout while still allowing new cases to be added in the future. The `Bidi_Class` values are defined by [Unicode Standard Annex #44 (UAX #44)](https://unicode.org/reports/tr44/#Bidi_Class_Values). Case names are derived from those long value names, and each case's documentation names the bidirectional class it represents:

```swift
extension Unicode {

  /// The classification of a scalar used by the Unicode Bidirectional
  /// Algorithm.
  ///
  /// Every Unicode scalar has a bidirectional class that determines how it is
  /// ordered relative to surrounding scalars when text is laid out. Scalars not
  /// otherwise assigned a value take a default based on their code point, so
  /// this classification is defined for every scalar.
  @available(SwiftStdlib 6.5, *)
  @objc
  public enum BidiClass: UInt8, Sendable {
    /// A strong left-to-right character.
    ///
    /// This value corresponds to the bidirectional class `Left_To_Right`
    /// (abbreviated `L`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case leftToRight

    /// A strong right-to-left (non-Arabic-type) character.
    ///
    /// This value corresponds to the bidirectional class `Right_To_Left`
    /// (abbreviated `R`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case rightToLeft

    /// A strong right-to-left (Arabic-type) character.
    ///
    /// This value corresponds to the bidirectional class `Arabic_Letter`
    /// (abbreviated `AL`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case arabicLetter

    /// A European number.
    ///
    /// This value corresponds to the bidirectional class `European_Number`
    /// (abbreviated `EN`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case europeanNumber

    /// A European number separator.
    ///
    /// This value corresponds to the bidirectional class `European_Separator`
    /// (abbreviated `ES`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case europeanSeparator

    /// A European number terminator.
    ///
    /// This value corresponds to the bidirectional class `European_Terminator`
    /// (abbreviated `ET`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case europeanTerminator

    /// An Arabic number.
    ///
    /// This value corresponds to the bidirectional class `Arabic_Number`
    /// (abbreviated `AN`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case arabicNumber

    /// A common number separator.
    ///
    /// This value corresponds to the bidirectional class `Common_Separator`
    /// (abbreviated `CS`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case commonSeparator

    /// A nonspacing mark.
    ///
    /// This value corresponds to the bidirectional class `Nonspacing_Mark`
    /// (abbreviated `NSM`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case nonspacingMark

    /// A boundary neutral.
    ///
    /// This value corresponds to the bidirectional class `Boundary_Neutral`
    /// (abbreviated `BN`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case boundaryNeutral

    /// A paragraph separator.
    ///
    /// This value corresponds to the bidirectional class `Paragraph_Separator`
    /// (abbreviated `B`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case paragraphSeparator

    /// A segment separator.
    ///
    /// This value corresponds to the bidirectional class `Segment_Separator`
    /// (abbreviated `S`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case segmentSeparator

    /// A whitespace character.
    ///
    /// This value corresponds to the bidirectional class `White_Space`
    /// (abbreviated `WS`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case whitespace

    /// A neutral character of another type.
    ///
    /// This value corresponds to the bidirectional class `Other_Neutral`
    /// (abbreviated `ON`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case otherNeutral

    /// A left-to-right embedding format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Left_To_Right_Embedding` (abbreviated `LRE`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case leftToRightEmbedding

    /// A left-to-right override format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Left_To_Right_Override` (abbreviated `LRO`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case leftToRightOverride

    /// A right-to-left embedding format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Right_To_Left_Embedding` (abbreviated `RLE`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case rightToLeftEmbedding

    /// A right-to-left override format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Right_To_Left_Override` (abbreviated `RLO`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case rightToLeftOverride

    /// A pop directional format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Pop_Directional_Format` (abbreviated `PDF`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case popDirectionalFormat

    /// A left-to-right isolate format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Left_To_Right_Isolate` (abbreviated `LRI`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case leftToRightIsolate

    /// A right-to-left isolate format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Right_To_Left_Isolate` (abbreviated `RLI`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case rightToLeftIsolate

    /// A first strong isolate format character.
    ///
    /// This value corresponds to the bidirectional class `First_Strong_Isolate`
    /// (abbreviated `FSI`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case firstStrongIsolate

    /// A pop directional isolate format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Pop_Directional_Isolate` (abbreviated `PDI`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    case popDirectionalIsolate
  }
}

extension Unicode.Scalar.Properties {

  /// The bidirectional class of the scalar.
  ///
  /// This property corresponds to the "Bidi_Class" property in the
  /// [Unicode Standard](http://www.unicode.org/versions/latest/).
  @available(SwiftStdlib 6.5, *)
  public var bidiClass: Unicode.BidiClass { get }
}
```

`White_Space` is spelled `whitespace` rather than `whiteSpace`, matching the existing `isWhitespace` property, which corresponds to the `White_Space` binary property.

As an `@objc` enum with a `UInt8` raw type, `Unicode.BidiClass` has a public synthesized `rawValue` property and failable `init?(rawValue:)` initializer. The raw values carry no meaning beyond identifying a case. `Unicode.BidiClass` does not conform to `Comparable`, because `Bidi_Class` values have no meaningful ordering.

The values follow the Unicode Character Database's `DerivedBidiClass.txt`, including its `@missing` default rules.

## Source compatibility

This proposal is purely additive and has no source compatibility impact.

## ABI compatibility

This proposal is purely an extension of the ABI of the standard library. `Unicode.BidiClass` is a fixed-layout enum that only permits new trivial cases to be added. Future `Bidi_Class` values can be added as new cases without breaking ABI or source compatibility.

Because the raw values are part of the ABI, existing cases keep their declaration order, and new cases are added after the existing ones.

## Implications on adoption

Using `bidiClass` requires a version of the standard library that includes it. On platforms where the standard library ships as part of the operating system, that means a new OS version. The property cannot be back-deployed, because it depends on Unicode data in the standard library's runtime.

## Alternatives considered

### Using a `RawRepresentable` struct

An earlier version of this proposal used the `RawRepresentable` struct pattern with static members, as `Unicode.CanonicalCombiningClass` does, to get a fixed-layout but extensible enum-like API. However, unlike canonical combining classes, the specific backing values for `BidiClass` are not ordered or meaningful.

This revision uses an `@objc` enum instead, which provides the same layout with real enum cases.

### Calling it `bidirectionalCharacterClass` or similar

In Unicode, "bidi" is an established term of art and there's strong precedent to use more direct Unicode terminology inside the `Unicode` namespace. For example, the properties `isBidiControl` and `isBidiMirrored` are also inside `Unicode.Scalar.Properties`.



