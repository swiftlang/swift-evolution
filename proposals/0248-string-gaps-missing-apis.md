# String Gaps and Missing APIs

* Proposal: [SE-0248](0248-string-gaps-missing-apis.md)
* Author: [Michael Ilseman](https://github.com/milseman)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 5.1)**
* Implementation: [apple/swift#22869](https://github.com/apple/swift/pull/22869)
* Bugs: [apple/swift#52358](https://github.com/apple/swift/issues/52358)

## Introduction

String and related types are missing trivial and obvious functionality, much of which currently exists internally but has not been made API. We propose adding 9 new methods/properties and 3 new code unit views.

Swift-evolution thread: [Pitch: String Gaps and Missing APIs](https://forums.swift.org/t/pitch-string-gaps-and-missing-apis/20984)

## Motivation

These missing APIs address [commonly encountered](https://forums.swift.org/t/efficiently-retrieving-utf8-from-a-character-in-a-string/19916) gaps and [missing functionality](https://github.com/apple/swift/issues/52358) for users of String and its various types, often leading developers to [reinvent](https://github.com/apple/swift-nio-http2/blob/master/Sources/NIOHPACK/HPACKHeader.swift#L412) the same trivial definitions.

## Proposed solution

We propose:

* 6 simple APIs on Unicode’s various encodings
* 2 generic initializers for string indices and ranges of indices
* `Substring.base`, equivalent to `Slice.base`
* Make `Character.UTF8View` and `Character.UTF16View` public
* Add `Unicode.Scalar.UTF8View`

## Detailed design

### 1. Unicode obvious/trivial additions

This functionality existed internally as helpers and is generally useful (even if they’re simple) for anyone working with Unicode.

```swift

extension Unicode.ASCII {
  /// Returns whether the given code unit represents an ASCII scalar
  public static func isASCII(_ x: CodeUnit) -> Bool
}

extension Unicode.UTF8 {
  /// Returns the number of code units required to encode the given Unicode
  /// scalar.
  ///
  /// Because a Unicode scalar value can require up to 21 bits to store its
  /// value, some Unicode scalars are represented in UTF-8 by a sequence of up
  /// to 4 code units. The first code unit is designated a *lead* byte and the
  /// rest are *continuation* bytes.
  ///
  ///     let anA: Unicode.Scalar = "A"
  ///     print(anA.value)
  ///     // Prints "65"
  ///     print(UTF8.width(anA))
  ///     // Prints "1"
  ///
  ///     let anApple: Unicode.Scalar = "🍎"
  ///     print(anApple.value)
  ///     // Prints "127822"
  ///     print(UTF16.width(anApple))
  ///     // Prints "4"
  ///
  /// - Parameter x: A Unicode scalar value.
  /// - Returns: The width of `x` when encoded in UTF-8, from `1` to `4`.
  public static func width(_ x: Unicode.Scalar) -> Int

  /// Returns whether the given code unit represents an ASCII scalar
  public static func isASCII(_ x: CodeUnit) -> Bool
}

extension Unicode.UTF16 {
  /// Returns a Boolean value indicating whether the specified code unit is a
  /// high or low surrogate code unit.
  public static func isSurrogate(_ x: CodeUnit) -> Bool

  /// Returns whether the given code unit represents an ASCII scalar
  public static func isASCII(_ x: CodeUnit) -> Bool
}

extension Unicode.UTF32 {
  /// Returns whether the given code unit represents an ASCII scalar
  public static func isASCII(_ x: CodeUnit) -> Bool
}

```

### 2. Generic initializers for String.Index and Range

Concrete versions of this exist parameterized over String, but versions generic over StringProtocol are missing.

```swift
extension String.Index {
  /// Creates an index in the given string that corresponds exactly to the
  /// specified position.
  ///
  /// If the index passed as `sourcePosition` represents the start of an
  /// extended grapheme cluster---the element type of a string---then the
  /// initializer succeeds.
  ///
  /// The following example converts the position of the Unicode scalar `"e"`
  /// into its corresponding position in the string. The character at that
  /// position is the composed `"é"` character.
  ///
  ///     let cafe = "Cafe\u{0301}"
  ///     print(cafe)
  ///     // Prints "Café"
  ///
  ///     let scalarsIndex = cafe.unicodeScalars.firstIndex(of: "e")!
  ///     let stringIndex = String.Index(scalarsIndex, within: cafe)!
  ///
  ///     print(cafe[...stringIndex])
  ///     // Prints "Café"
  ///
  /// If the index passed as `sourcePosition` doesn't have an exact
  /// corresponding position in `target`, the result of the initializer is
  /// `nil`. For example, an attempt to convert the position of the combining
  /// acute accent (`"\u{0301}"`) fails. Combining Unicode scalars do not have
  /// their own position in a string.
  ///
  ///     let nextScalarsIndex = cafe.unicodeScalars.index(after: scalarsIndex)
  ///     let nextStringIndex = String.Index(nextScalarsIndex, within: cafe)
  ///
  ///     print(nextStringIndex)
  ///     // Prints "nil"
  ///
  /// - Parameters:
  ///   - sourcePosition: A position in a view of the `target` parameter.
  ///     `sourcePosition` must be a valid index of at least one of the views
  ///     of `target`.
  ///   - target: The string referenced by the resulting index.
  public init?<S: StringProtocol>(
    _ sourcePosition: String.Index, within target: S
  )
}

extension Range where Bound == String.Index {
    public init?<S: StringProtocol>(_ range: NSRange, in string: __shared S)
}
```

### 3. Substring provides access to its base

Slice, the default SubSequence type, provides `base` for accessing the original Collection. Substring, String’s SubSequence, should as well.

```swift
extension Substring {
  /// Returns the underlying string from which this Substring was derived.
  public var base: String { get }
}

```

### 4. Add in missing views on Character

Character’s UTF8View and UTF16View has existed internally, but we should make it public.

```swift

extension Character {
  /// A view of a character's contents as a collection of UTF-8 code units. See
  /// String.UTF8View for more information
  public typealias UTF8View = String.UTF8View

  /// A UTF-8 encoding of `self`.
  public var utf8: UTF8View { get }

  /// A view of a character's contents as a collection of UTF-16 code units. See
  /// String.UTF16View for more information
  public typealias UTF16View = String.UTF16View

  /// A UTF-16 encoding of `self`.
  public var utf16: UTF16View { get }
}
```


### 5. Add in a RandomAccessCollection UTF8View on Unicode.Scalar

Unicode.Scalar has a UTF16View with is a RandomAccessCollection, but not a UTF8View.

```swift
extension Unicode.Scalar {
  public struct UTF8View {
    internal init(value: Unicode.Scalar)
    internal var value: Unicode.Scalar
  }

  public var utf8: UTF8View { get }
}

extension Unicode.Scalar.UTF8View : RandomAccessCollection {
  public typealias Indices = Range<Int>

  /// The position of the first code unit.
  public var startIndex: Int { get }

  /// The "past the end" position---that is, the position one
  /// greater than the last valid subscript argument.
  ///
  /// If the collection is empty, `endIndex` is equal to `startIndex`.
  public var endIndex: Int { get }

  /// Accesses the code unit at the specified position.
  ///
  /// - Parameter position: The position of the element to access. `position`
  ///   must be a valid index of the collection that is not equal to the
  ///   `endIndex` property.
  public subscript(position: Int) -> UTF8.CodeUnit
}
```

## Source compatibility

All changes are additive.

## Effect on ABI stability

All changes are additive.

## Effect on API resilience

* Unicode encoding additions and `Substring.base` are trivial and can never change in definition, so their implementations are exposed.
* `String.Index` initializers are resilient and versioned.
* Character’s views already exist as inlinable in 5.0, we just replace `internal` with `public`
* Unicode.Scalar.UTF8View's implementation is fully exposed (for performance), but is versioned

## Alternatives considered

### Do Nothing

Various flavors of “do nothing” include stating a given API is not useful or waiting for a rethink of some core concept. Each of these API gaps frequently come up on the forums, bug reports, or seeing developer usage in the wild. Rethinks are unlikely to happen anytime soon. We believe these gaps should be closed immediately.

### Do More

This proposal is meant to round out holes and provide some simple additions, keeping the scope narrow for Swift 5.1. We could certainly do more in all of these areas, but that would require a more design iteration and could be dependent on other missing functionality.

