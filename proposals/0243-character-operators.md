# Character Literal Opertaors

* Proposal: [SE-0243](0243-character-operators.md)
* Authors: [Dianna ma (“Taylor Swift”)](https://github.com/kelvin13), [John Holdsworth](https://github.com/johnno1962)
* Review manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Second review** 
* Implementation: [apple/swift#NNN](https://github.com/apple/swift/compare/main...johnno1962:swift:character-ops?expand=1)
* Threads: [1](https://forums.swift.org/t/prepitch-character-integer-literals/10442) [2](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188) [3](https://forums.swift.org/t/single-quoted-character-literals-why-yes-again/61898)

## Introduction

This proposal reboots efforts to improve the ergonomics of the Swift language for a class of code involved in parsing, for example JSON or the Swift language itself. Whereas previously it was thought a single quoted syntax for these literals could be pressed into service alongside integer express-ability it was realised that adding few well chosen operators to the standard library could serve the most pressing use cases. That this works and is performant has been demonstrated in [this PR](https://github.com/apple/swift-syntax/pull/2439#issuecomment-1922292277) to the `swift-syntax` library where the readability of code was increased with an ever so slight improvement in performance.

## Motivation

At present, the rather cumbersome constructs `UInt8(ascii: "c")` or perhaps `UnicadeScalar("c").value` are the only interface to the binary integer equivalent of `unicode scalars` in the Swift language. Data is not always UInt8 or UInt32 however so, frequently these have to be combined with a cast and overall the ergonomics are sub-optimal. For example, when wanting to `switch` over a range of values as in the previous version of the lexer code cluttered with `UInt8(ascii: "x")` in the PR mentioned above.

Swift allows you to define operators for equivalence and also for the pattern matching used in `switch` statements. It is sufficient therefore to add binary operators to allow direct comparisons between integer types and unicode scalars. This approach has been shown to be perfectly performant and effectively "compiles down to the same thing".

## Proposed solution

Specifically, this proposal puts forward that the following code be added to the file: stdlib/public/core/UnicodeScalar.swift in the standard library:

```Swift
/// Allows direct comparisons between UInt8 and double quoted literals.
extension UInt8 {
  /// Basic equality operator
  @_transparent @_alwaysEmitIntoClient
  public static func == (i: Self, s: Unicode.Scalar) -> Bool {
    return i == UInt8(ascii: s)
  }
  /// Basic inequality operator
  @_transparent @_alwaysEmitIntoClient
  public static func != (i: Self, s: Unicode.Scalar) -> Bool {
    return i != UInt8(ascii: s)
  }
  /// Used in switch statements
  @_transparent @_alwaysEmitIntoClient
  public static func ~= (s: Unicode.Scalar, i: Self) -> Bool {
    return i == UInt8(ascii: s)
  }
}

extension UInt8? {
  /// Optional equality operator
  @_transparent @_alwaysEmitIntoClient
  public static func == (i: Self, s: Unicode.Scalar) -> Bool {
    return i == UInt8(ascii: s)
  }
  /// Optional inequality operator
  @_transparent @_alwaysEmitIntoClient
  public static func != (i: Self, s: Unicode.Scalar) -> Bool {
    return i != UInt8(ascii: s)
  }
  /// Used in switch statements
  @_transparent @_alwaysEmitIntoClient
  public static func ~= (s: Unicode.Scalar, i: Self) -> Bool {
    return i == UInt8(ascii: s)
  }
}

extension Array where Element: FixedWidthInteger {
    /// Initialise an Integer array with "unicode scalars"
    @inlinable @_alwaysEmitIntoClient @_unavailableInEmbedded
    public init(scalars: String) {
      self.init(scalars.unicodeScalars.map { Element(unicode: $0) })
    }
}

extension FixedWidthInteger {
  /// Construct with value `v.value`.
  @inlinable @_alwaysEmitIntoClient
  public init(unicode v: Unicode.Scalar) {
    _precondition(v.value <= Self.max,
        "Code point value does not fit into type")
    self = Self(v.value)
  }
}
```

The last initialiser can be considered optional but could be considered as an alternative to the existing `IntX(UncodeScalar("c").value)` incantation people are expected to discover at the moment for non-ascii code points.

## Source compatibility

The operators proposed are additive and after running the existing test suite the net effect seems to be to change the diagnostics given on some pattern matching code which was invalid anyway. The last initialiser proposed can affect what is currently valid code such as the following:

```Swift
unicodeScalars.map(UInt32.init)
`
Becomes ambiguous and needs to be rewritten explicitly as:

```Swift
unicodeScalars.map { UInt32($0) }
```

## Effect on ABI stability

The new operator have been annotated with `@_alwaysEmitIntoClient` so any code using them will back-port to versions of the Swift runtime before these operators were added.

## Effect on API resilience

The operators are straightforward and it is not anticipated they would need to evolve their ABI.

## Alternatives considered

There is a long history to the proposal and this is a much scaled back version with less collateral impact on the language than previously reviewed proposals which still satisfy the main use cases. It uses the features of the language rather than changing the language itself. One could argue that users would still be able to define these operators themselves but in the end it is a question of whether this would be a battery sufficiently useful to be included in the standard library. Including them would help discovery as something that people might have previously expected to work coming from another language would "simply work".