# Add `bidiClass` to `Unicode.Scalar.Properties`

* Proposal: [SE-NNNN](NNNN-unicode-bidi-class.md)
* Authors: [Chris Chapman](https://github.com/cjchapman), [Michael Ilseman](https://github.com/milseman)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#91404](https://github.com/swiftlang/swift/pull/91404)
* Review: ([pitch](https://forums.swift.org/t/pitch-add-bidiclass-to-unicode-scalar-properties/89097))

## Summary of changes

Adds a `bidiClass` property to `Unicode.Scalar.Properties` that returns a scalar's Unicode `Bidi_Class`, the classification that drives the Unicode Bidirectional Algorithm, along with a new `Unicode.BidiClass` type to represent its values.

## Motivation

`Unicode.Scalar.Properties` exposes many of the scalar properties defined by the Unicode Standard, but not `Bidi_Class`, the classification that drives the Unicode Bidirectional Algorithm ([UAX #9](https://www.unicode.org/reports/tr9/)).

Code that lays out or transforms bidirectional text needs each scalar's `Bidi_Class`. An example task is deciding whether a piece of text must be wrapped in the isolate controls `U+2068 FIRST STRONG ISOLATE` and `U+2069 POP DIRECTIONAL ISOLATE` before being embedded in surrounding text of the opposite direction, so that it does not reorder its neighbors. That decision requires knowing whether the text contains strong-directional or numeric scalars, which is exactly what `Bidi_Class` reports. The closely related `generalCategory` is not a substitute: it does not distinguish a strong left-to-right letter from a strong right-to-left one.

Today this value must come from elsewhere, and the most direct source, the system's ICU library, is the same pain point described in [SE-0211](0211-unicode-scalar-properties.md). Swift's Foundation ran into this when implementing list-item isolate wrapping in `ListFormatStyle`.

## Proposed solution

We add a `bidiClass` computed property to `Unicode.Scalar.Properties`, and a `Unicode.BidiClass` type for its values. The property parallels the existing `generalCategory`, and the type follows the design of `Unicode.CanonicalCombiningClass`:

```swift
let scalar: Unicode.Scalar = "\u{05D0}"  // HEBREW LETTER ALEF
scalar.properties.bidiClass  // .rightToLeft
```

Every scalar has a defined `Bidi_Class`: scalars not explicitly assigned one, including unassigned code points, take a code-point-based default. So `bidiClass` returns a value for every `Unicode.Scalar`.

## Detailed design

Like `Unicode.CanonicalCombiningClass`, `Unicode.BidiClass` is a `RawRepresentable` struct with a `UInt8` raw value and one static member per `Bidi_Class` value. Unlike `Unicode.CanonicalCombiningClass`, it is `@frozen`, for efficient storage and comparison. The `Bidi_Class` values are defined by [Unicode Standard Annex #44 (UAX #44)](https://unicode.org/reports/tr44/#Bidi_Class_Values). Member names are derived from those long value names, and each member's documentation names the bidirectional class it represents:

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
  @frozen
  public struct BidiClass: Hashable, RawRepresentable, Sendable {
    /// The raw integer value of the bidirectional class.
    ///
    /// The raw values are assigned by the standard library and are stable, but
    /// are not defined by the Unicode Standard, which assigns no integers to
    /// `Bidi_Class` values.
    public let rawValue: UInt8

    /// Creates a new bidirectional class with the given raw integer value.
    ///
    /// - Parameter rawValue: The raw integer value of the bidirectional class.
    public init(rawValue: UInt8)

    /// A strong left-to-right character.
    ///
    /// This value corresponds to the bidirectional class `Left_To_Right`
    /// (abbreviated `L`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var leftToRight: BidiClass { get }

    /// A strong right-to-left (non-Arabic-type) character.
    ///
    /// This value corresponds to the bidirectional class `Right_To_Left`
    /// (abbreviated `R`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var rightToLeft: BidiClass { get }

    /// A strong right-to-left (Arabic-type) character.
    ///
    /// This value corresponds to the bidirectional class `Arabic_Letter`
    /// (abbreviated `AL`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var arabicLetter: BidiClass { get }

    /// A European number.
    ///
    /// This value corresponds to the bidirectional class `European_Number`
    /// (abbreviated `EN`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var europeanNumber: BidiClass { get }

    /// A European number separator.
    ///
    /// This value corresponds to the bidirectional class `European_Separator`
    /// (abbreviated `ES`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var europeanSeparator: BidiClass { get }

    /// A European number terminator.
    ///
    /// This value corresponds to the bidirectional class `European_Terminator`
    /// (abbreviated `ET`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var europeanTerminator: BidiClass { get }

    /// An Arabic number.
    ///
    /// This value corresponds to the bidirectional class `Arabic_Number`
    /// (abbreviated `AN`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var arabicNumber: BidiClass { get }

    /// A common number separator.
    ///
    /// This value corresponds to the bidirectional class `Common_Separator`
    /// (abbreviated `CS`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var commonSeparator: BidiClass { get }

    /// A nonspacing mark.
    ///
    /// This value corresponds to the bidirectional class `Nonspacing_Mark`
    /// (abbreviated `NSM`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var nonspacingMark: BidiClass { get }

    /// A boundary neutral.
    ///
    /// This value corresponds to the bidirectional class `Boundary_Neutral`
    /// (abbreviated `BN`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var boundaryNeutral: BidiClass { get }

    /// A paragraph separator.
    ///
    /// This value corresponds to the bidirectional class `Paragraph_Separator`
    /// (abbreviated `B`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var paragraphSeparator: BidiClass { get }

    /// A segment separator.
    ///
    /// This value corresponds to the bidirectional class `Segment_Separator`
    /// (abbreviated `S`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var segmentSeparator: BidiClass { get }

    /// A whitespace character.
    ///
    /// This value corresponds to the bidirectional class `White_Space`
    /// (abbreviated `WS`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var whitespace: BidiClass { get }

    /// A neutral character of another type.
    ///
    /// This value corresponds to the bidirectional class `Other_Neutral`
    /// (abbreviated `ON`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var otherNeutral: BidiClass { get }

    /// A left-to-right embedding format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Left_To_Right_Embedding` (abbreviated `LRE`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var leftToRightEmbedding: BidiClass { get }

    /// A left-to-right override format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Left_To_Right_Override` (abbreviated `LRO`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var leftToRightOverride: BidiClass { get }

    /// A right-to-left embedding format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Right_To_Left_Embedding` (abbreviated `RLE`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var rightToLeftEmbedding: BidiClass { get }

    /// A right-to-left override format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Right_To_Left_Override` (abbreviated `RLO`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var rightToLeftOverride: BidiClass { get }

    /// A pop directional format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Pop_Directional_Format` (abbreviated `PDF`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var popDirectionalFormat: BidiClass { get }

    /// A left-to-right isolate format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Left_To_Right_Isolate` (abbreviated `LRI`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var leftToRightIsolate: BidiClass { get }

    /// A right-to-left isolate format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Right_To_Left_Isolate` (abbreviated `RLI`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var rightToLeftIsolate: BidiClass { get }

    /// A first strong isolate format character.
    ///
    /// This value corresponds to the bidirectional class `First_Strong_Isolate`
    /// (abbreviated `FSI`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var firstStrongIsolate: BidiClass { get }

    /// A pop directional isolate format character.
    ///
    /// This value corresponds to the bidirectional class
    /// `Pop_Directional_Isolate` (abbreviated `PDI`) in the
    /// [Unicode Standard](https://unicode.org/reports/tr44/#Bidi_Class_Values).
    @export(implementation) public static var popDirectionalIsolate: BidiClass { get }
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

The raw integer values are assigned by the standard library and are stable, but, unlike `Unicode.CanonicalCombiningClass`, they are not defined by the Unicode Standard, which assigns no integers to `Bidi_Class` values. `init(rawValue:)` is non-failable, so a value from a future version of the Unicode data that this API does not yet name remains representable and round-trips. `Unicode.BidiClass` does not conform to `Comparable`, because `Bidi_Class` values have no meaningful ordering.

The values follow the Unicode Character Database's `DerivedBidiClass.txt`, including its `@missing` default rules.

## Source compatibility

This proposal is purely additive and has no source compatibility impact.

## ABI compatibility

This proposal is purely an extension of the ABI of the standard library. `Unicode.BidiClass` is a frozen struct wrapping a single `UInt8`, so its layout is fixed and it can be stored and compared as cheaply as that integer. The static members are annotated `@export(implementation)` ([SE-0497](0497-definition-visibility.md)), so each access is emitted into the client and inlines to a constant, adding no accessor symbols to the standard library's ABI. Because those constants are compiled into clients, the raw value of each named member cannot change once it ships.

Future `Bidi_Class` values can be added as new static members without breaking ABI or source compatibility, and any raw value, including one this API does not yet name, remains representable via `init(rawValue:)`.

## Implications on adoption

Using `bidiClass` requires a version of the standard library that includes it. On platforms where the standard library ships as part of the operating system, that means a new OS version. The property cannot be back-deployed, because it depends on Unicode data in the standard library's runtime.

## Alternatives considered

### Representing `Bidi_Class` as an enum

`Unicode.GeneralCategory` is an enum, and `Unicode.BidiClass` could be one too. A `@frozen` enum would have the same compact layout, but it could never gain cases, so a future `Bidi_Class` value could not be added. That has happened before: Unicode 6.3 added the four isolate classes. A non-`@frozen` enum could gain cases, but its layout would be resilient, so code outside the standard library would handle it indirectly rather than as a single byte.

A frozen struct with static members gets both a fixed one-byte layout and room for new values, and values this API does not yet name remain representable via `init(rawValue:)`. The tradeoff is that a `switch` over a `Unicode.BidiClass` always needs a `default` case, and the compiler does not flag that `switch` when new values are added.
