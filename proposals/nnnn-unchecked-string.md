# UncheckedString (raw string support for Swift)

* Proposal: [SE-NNNN](NNNN-unchecked-string.md)
* Authors: [Alastair Houghton](https://github.com/al45tair)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#91970](https://github.com/swiftlang/swift/pull/91970), [swiftlang/swift-syntax#3428](https://github.com/swiftlang/swift-syntax/pull/3428)
* Review: ([pitch](https://forums.swift.org/t/pitch-uncheckedstring-raw-string-support-for-swift/89571))

## Summary of changes

This proposal adds an `UncheckedString` type to the Swift standard library
and compiler.  `UncheckedString` assumes no particular character encoding
and is even generic on code unit size, so you can use it to hold 8-bit,
16-bit or even 32-bit string types.

## Motivation

There are plenty of strings that are not necessarily UTF-8, for instance:

* File paths
* Command line arguments
* Environment variables
* HTTP and MIME headers

Many Swift programs that manipulate these kinds of strings currently assume
that they are UTF-8 and will fail with a fatal error when supplied with a
string that is not.  This can easily happen in practice, particularly on
traditional UNIX-like platforms where filenames are really a "bag of bytes"
in no particular encoding, and users are free to configure their terminals
to use any character encoding they wish.

Even on Apple platforms, where people commonly assume UTF-8, the user's
terminal might not be UTF-8 (and they might even be connected using SSH
from some other system, so this can't be fixed by making macOS terminal
only support UTF-8), which means command line arguments and environment
variables could end up being encoded using some other encoding scheme.

Additionally, on Windows, UTF-16/WTF-16/UCS-2 strings are in common use,
but Windows software generally doesn't pay too much attention to validity,
so it's very common to see things that are not really valid UTF-16.  Not
only is the conversion between UTF-16 and UTF-8 Swift `String` inefficient,
but it very commonly will not actually work because the string wasn't
really valid Unicode.  Using UTF-16 strings on Windows is also awkward
because of the lack of a literal syntax.

Currently, programs that expect to deal correctly with all of these cases
are forced to either use unnatural representations for the string data in
question (like `Array<UInt8>` or `Data`), which makes inspecting and
manipulating the string awkward, or they end up building their own raw
string type, which will often have poor performance and a limited API
surface.  It's also difficult or impossible to write string literals in
code when taking either of these approaches.

`UncheckedString` solves all of these problems by creating a new string-like
type that supports

* Arbitrary `FixedWidthInteger` code units.
* A similar set of APIs to `String`, including full mutation support
  (`UncheckedString` conforms to `RangeReplaceableCollection`, so it can be
  built up incrementally with `append`, `insert`, `replaceSubrange`, and so
  on, not just constructed once and read).
* Efficient COW storage, with the small string optimization.
* Compiler-supported string literal syntax, including a new hexadecimal
  escape sequence to allow the use of raw code units.
* `encode()`/`decode()` APIs to transform between `UncheckedString`
  and `String`.

All with good performance.

## Proposed solution

The proposal adds a new _generic_ string-like type, `UncheckedString`,
along with `UncheckedSubString` and `UncheckedStringProtocol`:

```swift
struct UncheckedString<Element: FixedWidthInteger>: UncheckedStringProtocol {
  ...
}

struct UncheckedSubString<Element: FixedWidthInteger>: UncheckedStringProtocol {
  ...
}

protocol UncheckedStringProtocol: 
    BidirectionalCollection, Equatable, Hashable, Comparable,
    CustomDebugStringConvertible, CustomUncheckedStringConvertible
  where Iterator.Element: FixedWidthInteger,
    Index == Int,
    SubSequence: UncheckedStringProtocol,
    UncheckedStringElement == Element {
  ...
}
```

The API for these types is similar to the API on `String`, `SubString` and
`StringProtocol`.  Significant departures include:

* `UncheckedString` is generic over its element type, which is not
  `Character`, but instead some `FixedWidthInteger`.
* `UncheckedString.Index` is `Int`.  This makes sense because subscripting
  provides direct access to the code units themselves, and we do not know
  the encoding.
* `UncheckedString` is encoding-agnostic.  It's just a collection of code
  units.  It needn't even be ASCII-based, though in practice most uses of
  it will be.
* `UncheckedString` supports an extra character escape, `\x{hh}`, which
  allows the direct specification of individual code units.
* `UncheckedString` and `UncheckedSubString` both conform to
  `RangeReplaceableCollection`, so, unlike a bare `Array<UInt8>` or `Data`,
  they support in-place mutation (`append`, `insert`, `remove(at:)`,
  `replaceSubrange`, `reserveCapacity`, `+`/`+=`, and so on) as well as
  construction from a fixed `Collection`.
* Ordering (`<`) is defined element-wise on the raw `Element` values, using
  whatever ordering `Element` itself provides -- there is no attempt to
  impose a culturally meaningful or even a byte-oriented order.  This means,
  for instance, that `UncheckedString<Int8>` and `UncheckedString<UInt8>`
  holding the same underlying bytes can compare differently, since `Int8`
  and `UInt8` disagree about the ordering of byte values 0x80--0xFF.
* There is presently no regular expression support for `UncheckedString`.

Like `String` and `Substring`, `UncheckedString` and `UncheckedSubString`
both conform to `Sendable`.  Also like `String`, `UncheckedString` and
`UncheckedSubString` provide an `isTriviallyIdentical(to:)` method, which is
a cheap, O(1), check for whether two values share the same underlying
storage, as distinct from `==`s O(*n*) check for equal content.

There are also counterparts of `CustomStringConvertible`,
`ExpressibleByStringLiteral`, `ExpressibleByStringInterpolation` and
`DefaultStringInterpolation` that support the use of literals and even
interpolation with `UncheckedString`.

## Detailed design

### `UncheckedString` literals

`UncheckedString` supports literals through the
`ExpressibleByUncheckedStringLiteral`
and `ExpressibleByUncheckedStringInterpolation` protocols:

```swift
extension UncheckedString: ExpressibleByUncheckedStringLiteral {
  public typealias UncheckedStringLiteralType = UncheckedString<Element>

  @_transparent
  public init(uncheckedStringLiteral value: UncheckedString<Element>) {
    self = value
  }
}

extension UncheckedString: ExpressibleByUncheckedStringInterpolation {
  public init(stringInterpolation: StringInterpolation) {
    self.init(taking: stringInterpolation.chars)
  }
}
```

Currently valid string literals will continue to be interpreted as `String`
or `Character` literals as they are today, for instance:

```swift
let name = "René Descartes"  // `name` is a `String`
```

Users can explicitly request an `UncheckedString`

```swift
let utf8Name: UncheckedString<UInt8> = "René Descartes"
let utf16Name: UncheckedString<UInt16> = "René Descartes"
let utf8Name2 = "René Descartes" as UncheckedString<UInt8>
let utf16Name2 = "René Descartes" as UncheckedString<UInt16>
```

Swift source files are encoded in UTF-8, and any Unicode codepoints used
in a string literal will be transformed into appropriately encoded Unicode
given the width of the `UncheckedString` element type (so
`UncheckedString<UInt8>` would get UTF-8 encoding, `UncheckedString<UInt16>`
would get UTF-16 encoding, and `UncheckedString<UInt32>` will get UCS-4
encoding for any explicit Unicode in the input).  The existing `\u{hh}`
escape sequences are also supported for `UncheckedString`, with the same
semantics as literal characters.

We are also adding an `\x{hh}` escape sequence that allows the user to
specify directly a code unit in an `UncheckedString`.  This escape is _only_
permitted for `UncheckedString` literals, and the compiler is aware that if
it sees it, the literal in question _must_ be an `UncheckedString` and not
a `String` or `Character` literal, for instance:

```swift
let iso8859Name = "Ren\x{e9} Descartes" // UncheckedString<UInt8>

// This is a compile-time error:
let invalidName: String = "Ren\x{e9} Descartes"
```

The `\x{hh}` escape can take any number of hexadecimal digits, subject to
the value fitting into the `UncheckedString`'s `Element` type, for example:

```swift
let smileyUTF8 = "\x{f0}\x{9f}\x{98}\x{90}"
let smileyUTF16: UncheckedString<UInt16> = "\x{d83d}\x{de00}"
let smileyUCS4: UncheckedString<UInt32> = "\x{1f600}"
```

The compiler further guarantees that `UncheckedString` literal data is
encoded in the binary as a sequence of code units of the specified type,
using the endianness appropriate for the target.  That is,

```swift
let wideString: UncheckedString<UInt16> = "Hello, World 😀"
```

on a little-endian system results in the data

```
48 00 65 00 6c 00 6c 00 6f 00 2c 00 20 00 57 00   H.e.l.l.o.,. .W.
6f 00 72 00 6c 00 64 00 20 00 3d d8 00 de         o.r.l.d. .=Ø.Þ
```

in the final binary.  It is not transcoded at runtime, but instead forms
a real 16-bit string constant.

### Compile-time literal type resolution

The compiler currently hard-codes knowledge about the types of string
literals, but we need it to choose appropriately on the basis of the
literal in question (if it contains a `\x{hh}` escape) and/or the
surrounding context, since we want things like

```swift
let utf8Name: UncheckedString<UInt8> = "René Descartes"
let utf16Name: UncheckedString<UInt16> = "René Descartes"
let utf8Name2 = "René Descartes" as UncheckedString<UInt8>
let utf16Name2 = "René Descartes" as UncheckedString<UInt16>
```

or even

```swift
let nameExpression: UncheckedString<UInt8> = "René" + " " + "Descartes"
```

to work.

To accomplish this, we add a family of "umbrella" protocols such as
`ExpressibleByPossiblyUncheckedStringLiteral`, re-parenting the existing
`ExpressibleByStringLiteral` protocol and also acting as the parent of a
new `ExpressibleByUncheckedStringLiteral` protocol.  This allows us to
express in the type system the idea that a literal _might_ be a normal
`String` literal, but _also_ might be an `UncheckedString` literal; the
existing type checking machinery can then pick the most appropriate
interpretation based on surrounding type information.

While doing this, we ensure that in the absence of any other information:

1. A literal that does not contain `\x{hh}` will be a `String` literal, and
2. A literal that _does_ contain `\x{hh}` will be an
   `UncheckedString<UInt8>` literal.

`UncheckedString` literals must also worry about their element type; to
account for this, we modify the compiler so that it maintains UTF-8 data,
as well as a "splice" list containing any characters specified using
`\x{hh}` escapes.  This is then used by SILGen and IRGen to generate an
appropriate constant on the basis of the type information, which by the
time it gets to those layers has been fixed.

### `CustomUncheckedStringConvertible` API

`UncheckedString` has a counterpart to `CustomStringConvertible`, namely
`CustomUncheckedStringConvertible`, which allows a type to declare that
it can be converted to an `UncheckedString`:

```swift
/// A type that can provide a raw, native-width representation of itself for
/// interpolation into an `UncheckedString`.
///
/// Unlike `String`'s `CustomStringConvertible`, which produces Unicode text,
/// a `CustomUncheckedStringConvertible` type produces raw `Element` data
/// directly -- no implicit encoding, transcoding, or textual description is
/// involved. `UncheckedString` interpolation only accepts values that
/// conform to this protocol (rather than any `CustomStringConvertible`
/// value, the way `String` interpolation does), since nothing about
/// `UncheckedString` implies a text encoding that an arbitrary describable
/// value could be rendered through.
///
/// `UncheckedStringProtocol` (and therefore `UncheckedString` and
/// `UncheckedSubString`) conforms to this protocol automatically, producing
/// its own character data. Any other type can opt in by declaring the
/// conformance and implementing `withUncheckedStringRepresentation`.
@available(SwiftStdlib 9999, *)
public protocol CustomUncheckedStringConvertible {
  /// The element type of the raw representation this type provides.
  associatedtype UncheckedStringElement: FixedWidthInteger

  /// Calls the given closure with a buffer containing this value's raw
  /// `UncheckedStringElement` representation.
  func withUncheckedStringRepresentation<R, Failure>(
    _ body: (Span<UncheckedStringElement>) throws(Failure) -> R
  ) throws(Failure) -> R
}
```

### `UncheckedStringProtocol` API

Again paralleling `String`, `UncheckedString` and `UncheckedSubString` both
implement `UncheckedStringProtocol`:

```swift
// A type that can represent a string as a collection of characters.
///
/// Unlike `StringProtocol`, no assumptions are made about the encoding or
/// type of the characters.
@available(SwiftStdlib 9999, *)
public protocol UncheckedStringProtocol
  : BidirectionalCollection, Equatable, Hashable, Comparable,
    CustomDebugStringConvertible, CustomUncheckedStringConvertible
  where Iterator.Element: FixedWidthInteger,
    Index == Int,
    SubSequence: UncheckedStringProtocol,
    UncheckedStringElement == Element
{
  typealias SubSequence = UncheckedSubString<Element>

  /// Calls the given closure with a buffer of `Element`s,
  /// which are *not* necessarily NUL-terminated.
  func withCharacterData<R, E>(
    _ body: (Span<Element>) throws(E) -> R
  ) throws(E) -> R
}
```

Note the previous comment about `Comparable`; because it is defined
lexicographically over raw `Element` values and because there is no attempt
at byte-wise or locale-aware ordering, ordering is sensitive to `Element`'s
signedness: i.e. `UncheckedString<Int8>` and
`UncheckedString<UInt8>` values holding identical underlying bytes can
compare differently to one another for any byte in `0x80...0xFF`, since
`Int8` and `UInt8` disagree about the relative order of those values.

### `UncheckedString` API

`UncheckedString` can be constructed empty, or from a `Collection`, and
exposes its length via `count`/`isEmpty`:

```swift
/// A string value that is a collection of characters in an unspecified
/// encoding.
...
@available(SwiftStdlib 9999, *)
public struct UncheckedString<E: FixedWidthInteger>: UncheckedStringProtocol {
  public typealias Element = E
  public typealias SubSequence = UncheckedSubString<Element>
  public typealias Index = Int

  @inlinable
  public var count: Int { get }

  @inlinable
  public var isEmpty: Bool { get }

  /// Constructs an empty string
  @inlinable
  public init()

  /// Constructs a string from a collection of character elements.
  ///
  /// - Parameters:
  ///
  ///   - c: A `Collection` containing the character elements.
  ///
  public init<C: Collection>(_ c: C) where C.Element == Element
}
```

Beyond this, `UncheckedString` and `UncheckedSubString` conform to
`BidirectionalCollection`, `RangeReplaceableCollection`, `Equatable`,
`Hashable`, and `Comparable` (all via `UncheckedStringProtocol`), and provide
`hasPrefix`/`hasSuffix` overloads that accept any `UncheckedStringProtocol`
value of the same `Element` (so an `UncheckedString<UInt8>` and an
`UncheckedSubString<UInt8>` can be compared against one another, not just
against another value of the exact same type).

Because they conform to `RangeReplaceableCollection`, values can be mutated
in place, rather than only constructed once from a fixed `Collection`:

```swift
var path: UncheckedString<UInt8> = "/usr/local"
path.append(contentsOf: "/bin")
path += "/swift"
// path is now "/usr/local/bin/swift"
```

`UncheckedString`'s `CustomDebugStringConvertible` conformance renders
non-printable and non-ASCII elements using the same `\x{hh}` notation used
by its literals, and escapes literal backslash and double-quote characters,
so that `String(reflecting:)`/`debugPrint` produce output that could, in
most cases, be pasted back in as a literal.

### Interpolation

While `UncheckedString` itself directly implements `init(stringInterpolation:)`
in a similar manner to `String`, we also provide an analogue of
`DefaultStringInterpolation`, namely `DefaultUncheckedStringInterpolation`;
if a type is `ExpressibleByUncheckedStringInterpolation` and has a
`StringInterpolation` that is equal to
`DefaultUncheckedStringInterpolation<Element>`, then the type will have an
  `init(stringInterpolation:)` method generated for it automatically.

For instance:

```swift
struct WrappedUncheckedString: ExpressibleByUncheckedStringInterpolation {
  typealias StringInterpolation = DefaultUncheckedStringInterpolation<UInt8>

  var storage: UncheckedString<UInt8>

  init(uncheckedStringLiteral value: UncheckedString<UInt8>) {
    storage = value
  }
}

let s: WrappedUncheckedString = "Hello"
let w: UncheckedString<UInt8> = "World"
let h: WrappedUncheckedString = "Hello, \(w)!"
```

### Identity comparison

Alongside `==`, which checks for equal *content*, `UncheckedString` and
`UncheckedSubString` provide `isTriviallyIdentical(to:)`, an O(1) check for
whether two values are backed by the same storage (or are otherwise known,
cheaply, to be equivalent to sharing storage). This mirrors `String`'s
existing `isTriviallyIdentical(to:)`:

```swift
@available(SwiftStdlib 9999, *)
extension UncheckedString {
  /// Returns whether this string and `other` share the same underlying
  /// storage, making them cheap (O(1)) to compare, as opposed to `==`,
  /// which compares content and may take O(*n*) time.
  ///
  /// `isTriviallyIdentical(to:)` is not required to return `true` for two
  /// values holding equal content -- for instance, two small strings with
  /// the same characters are not guaranteed to be considered identical,
  /// even though there is no separate heap allocation involved.
  @inlinable
  public func isTriviallyIdentical(to other: Self) -> Bool
}
```

This is useful, for example, to cheaply short-circuit a comparison, or to
detect whether a copy-on-write mutation actually triggered a copy.

It also has support for C strings:

```swift
@available(SwiftStdlib 9999, *)
extension UncheckedString {
  /// Creates a string from a NUL-terminated sequence of characters.
  @inlinable
  public init(cString: UnsafePointer<Element>)

  /// Calls the given closure with a pointer to the contents of the string,
  /// represented as a NUL-terminated sequence of `Element`s.
  @inlinable
  public func withCString<R, Failure>(
    _ body: (UnsafePointer<Element>) throws(Failure) -> R
  ) throws(Failure) -> R
}
```

along with special support for `CChar` for `UncheckedString<UInt8>`:

```swift
// For UInt8, also allow CChar
@available(SwiftStdlib 9999, *)
extension UncheckedString where Element == UInt8 {
  /// Calls the given closure with a pointer to the contents of the string,
  /// represented as a NUL-terminated sequence of `Element`s.
  @inlinable
  public func withCString<R, Failure>(
    _ body: (UnsafePointer<CChar>) throws(Failure) -> R
  ) throws(Failure) -> R

  /// Creates a string from a NUL-terminated sequence of characters.
  @inlinable
  public init(cString nullTerminatedCharacters: UnsafePointer<CChar>)
}
```

`UncheckedString`'s own `count` and iteration have no opinion about
zero-valued elements; unlike a C string, a zero-valued `Element` occurring
*within* an `UncheckedString`'s logical content is ordinary data like any
other, and is included in `count` and preserved by mutation.  The
NUL-termination handled by `withCString`, `init(cString:)`, and pointer
conversions to C APIs is a *separate*, implicit terminator appended after
the string's `count` elements, not a delimiter within them.  Consequently,
if a string's logical content happens to contain an embedded zero-valued
element (for instance, byte 0x00 in an `UncheckedString<UInt8>` built from
already-decoded data), passing it to `withCString` or a `UnsafePointer<Element>`
argument will still produce a well-formed, NUL-terminated buffer, but any C
API reading that buffer will see it as ending at the *first* zero-valued
element, silently ignoring anything in the string past that point, even
though `count` reports the full, untruncated length. This is the same
hazard `String`/`Substring` already have when converted to C strings.

An additional feature of `UncheckedString` is support for _immortal_ strings,
which are strings whose memory is allocated elsewhere somehow (for instance
by the compiler or linker, or by code outside of the `UncheckedString`
implementation) and that will never be released.

```swift
@available(SwiftStdlib 9999, *)
extension UncheckedString {
  /// Creates a string from a NUL-terminated immortal string.
  @inlinable
  public init(immortalString: UnsafePointer<Element>)

  // Creates a string from an immortal string that isn't NUL terminated.
  @inlinable
  public init(immortalString: UnsafeBufferPointer<Element>)
}
```

`UncheckedString` also provides direct access to character data using the
`withCharacterData` API:

```swift
@available(SwiftStdlib 9999, *)
extension UncheckedString {
  /// Calls the given closure with a buffer of `Element`s,
  /// which are *not* necessarily NUL-terminated.
  @inlinable
  public func withCharacterData<R, Failure>(
    _ body: (Span<Element>) throws(Failure) -> R
  ) throws(Failure) -> R
}
```

Finally, sub-sequences use the `UncheckedSubString` type:

```swift
@available(SwiftStdlib 9999, *)
public struct UncheckedSubString<E: FixedWidthInteger>
  : UncheckedStringProtocol
{
  public typealias Element = E
  public typealias SubSequence = UncheckedSubString<Element>
  public typealias Index = Int

  ...
}
```

### Encoding/Decoding

As a convenience for working with encoded strings, `UncheckedString`
provides a `decode` API that attempts to convert its contents to a UTF-8
`String`:

```swift
public enum UncheckedStringFailEncoding {
  case fail
}

public enum UncheckedStringSubstituteEncoding {
  case substitute
}

@available(SwiftStdlib 9999, *)
public extension UncheckedString {
  /// Attempt to decode an `UncheckedString` using the specified encoding
  ///
  /// - Parameters:
  ///   - encoding:  The encoding to use.
  ///   - onInvalidEncoding: `.fail` to return `nil`, or `.substitute` to
  ///                replace invalid encodings with the substitution
  ///                character.
  ///
  /// - Returns a `String` if decoding was successful.
  func decode<Encoding: Unicode.Encoding>(
    as encoding: Encoding.Type,
    onInvalidEncoding: UncheckedStringFailEncoding = .fail
  ) -> String? where Encoding.CodeUnit == Element

  /// Attempt to decode an `UncheckedString` using the specified encoding
  ///
  /// - Parameters:
  ///   - encoding:  The encoding to use.
  ///   - onInvalidEncoding: `.fail` to return `nil`, or `.substitute` to
  ///                replace invalid encodings with the substitution
  ///                character.
  ///
  /// - Returns a `String` if decoding was successful.
  func decode<Encoding: Unicode.Encoding>(
    as encoding: Encoding.Type,
    onInvalidEncoding: UncheckedStringSubstituteEncoding
  ) -> String where Encoding.CodeUnit == Element
}
```

We also add an `encode` API, mirroring this one, on `String` itself:

```swift
@available(SwiftStdlib 9999, *)
public extension String {
  /// Attempt to encode a `String` using the specified encoding.
  ///
  /// - Parameters:
  ///   - encoding:  The encoding to use.
  ///   - onUnsupportedEncoding: `.fail` to return `nil`, or `.substitute`
  ///                to use a substitution character.
  ///
  /// - Returns an `UncheckedString` if encoding was successful.
  func encode<Encoding: Unicode.Encoding>(
    as encoding: Encoding.Type,
    onUnsupportedEncoding: UncheckedStringFailEncoding = .fail
  ) -> UncheckedString<Encoding.CodeUnit>?

  /// Attempt to encode a `String` using the specified encoding.
  ///
  /// - Parameters:
  ///   - encoding:  The encoding to use.
  ///   - onUnsupportedEncoding: `.fail` to return `nil`, or `.substitute`
  ///                to use a substitution character.
  ///
  /// - Returns an `UncheckedString` if encoding was successful.
  func encode<Encoding: Unicode.Encoding>(
    as encoding: Encoding.Type,
    onUnsupportedEncoding: UncheckedStringSubstituteEncoding
  ) -> UncheckedString<Encoding.CodeUnit>
}
```

This allows the user to write things like

```swift
// Assuming the existence of an encoding `Windows1252` `Unicode.Encoding`
// type (this isn't provided by the standard library presently).

guard let ansiName = "René Descartes".encode(as: Windows1252.self) else {
  fatalError("Cannot encode René Descartes' name for Windows")
}

guard let swiftName = ansiName.decode(as: Windows1252.self) else {
  fatalError("Cannot decode René Descartes' name from Windows")
}

assert(swiftName == "René Descartes")
```

### `Codable` support

`UncheckedString` conforms to `Encodable`/`Decodable` whenever its `Element`
does, encoding itself as an unkeyed container of its own raw `Element`
values -- the same representation `Array<Element>` would use, and (for
`UInt8`) the same representation `Data` uses. This is unrelated to the
`encode(as:)`/`decode(as:)` APIs above: those convert to/from `String`
under an explicit, named text `Unicode.Encoding`, whereas `Codable`
conformance serializes the raw code units with no text encoding involved at
all, for interop with `Encoder`/`Decoder`-based formats such as JSON or
property lists.

```swift
@available(SwiftStdlib 9999, *)
extension UncheckedString: Encodable where Element: Encodable {
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.unkeyedContainer()
    try withCharacterData { data in
      var i = 0
      while i < data.count {
        try container.encode(data[i])
        i += 1
      }
    }
  }
}

@available(SwiftStdlib 9999, *)
extension UncheckedString: Decodable where Element: Decodable {
  public init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var elements = [Element]()
    if let count = container.count {
      elements.reserveCapacity(count)
    }
    while !container.isAtEnd {
      elements.append(try container.decode(Element.self))
    }
    self.init(taking: elements)
  }
}
```

`UncheckedString` deliberately does *not* attempt to encode itself as
`String` text (whether by guessing/forcing a Unicode encoding, or via a
`debugDescription`-style `\x{hh}`-escaped string), since doing so would
reintroduce the encoding-guessing hazard the type exists to avoid, and
would make the wire representation's *shape* depend on whether a given
instance's bytes happen to be printable text.

`UncheckedSubString`, like `Substring`, does not conform to `Codable`.
Convert to `UncheckedString` first to encode one -- this already works
today with no new API, since `UncheckedString` already has
`init<C: Collection>(_:) where C.Element == Element` and
`UncheckedSubString` already conforms to `Collection` with a matching
`Element`:

```swift
try container.encode(UncheckedString(mySubstring))
```

Note that this conformance is only available outside of Embedded Swift.
Embedded Swift does not support the `Codable` infrastructure at all (it
relies on existentials and runtime type metadata that Embedded Swift
excludes), so `Encodable`/`Decodable`/`Encoder`/`Decoder` themselves are
not present there, and `UncheckedString`'s conditional conformance to them
is unavailable for the same reason.

## Conversion to C string types

`UncheckedString` supports conversions to C string pointers in a similar
manner to the conversions supported by `String`.  That is, it is permitted
to pass an `UncheckedString` to a function that expects an
`UnsafePointer<Element>` or `UnsafeRawPointer`.

This has the same risks as the similar feature of the `String` type; the
`UncheckedString` must persist at least long enough for the code in question
to make use of the pointer it has been passed.  It is up to the user to
ensure that that is the case.

This feature is a considerably quality of life improvement on Windows, where
interacting with the wide character APIs is commonplace, as it allows users
to make explicit use of UTF-16 strings and string constants without having
to transcode at runtime.

## Implementation Details

It's worth noting a few implementation details here; `UncheckedString` does
have the small string optimization, and under the covers stores its data
using `UncheckedStringStorage`:

```swift
@frozen
@usableFromInline
enum UncheckedStringStorage<CharType: FixedWidthInteger> {
  case empty
  case small(SmallUncheckedStringStorage<CharType>)
  case immortal(ImmortalUncheckedStringStorage<CharType>)
  case `dynamic`(DynamicUncheckedStringStorage<CharType>)

  @usableFromInline
  var count: Int {
    switch self {
      case .empty: return 0
      case .small(let rawStorage): return Int(rawStorage.count)
      case .immortal(let rawStorage): return Int(rawStorage.count)
      case .dynamic(let rawStorage): return Int(rawStorage.count)
    }
  }
}
```

The `small` variant stores character data inline, and is 16 bytes on 64-bit
platforms or 8 bytes on 32-bit.

The `immortal` variant holds an immutable pointer, a count and some flags.

The `dynamic` variant stores the actual data in an array of `[CharType]`,
and also holds a count (on 64-bit) and some flags.

The only important flag currently is a NUL-termination flag.  Dynamic strings
are _always_ NUL-terminated.  Immortal strings _may_ be NUL-terminated, or
they may not.  Small strings do not have the flag and are not NUL-terminated.

The implementation will promote a string to `dynamic` if it grows above the
size allowed for a small string, or if space is reserved for a string too
large for a small string.  Once promoted to dynamic, it will not be
demoted to `small`, to avoid allocation thrashing — if a string is being
mutated and is `dynamic`, it's likely it will be mutated further, and we
don't want to throw away the backing store at that point.

### Performance

Performance of `UncheckedString<UInt8>` is generally better than that of
`String`, since, of course, `UncheckedString` does not need to do any
Unicode processing.

That is not to say that people should use `UncheckedString` instead of
`String`; for most programs, `String` will remain the right choice, as it
is safer and supports Unicode and indeed regular expressions, and there
are tricks (such as working on the UTF-8 view) that give good performance
for `String` and that should probably be preferred in most cases.

## Source compatibility

This proposal is purely additive.  It does affect parsing slightly, in
that a string literal containing a `\x{hh}` escape is _only_ allowed for
`UncheckedString` literals, but since `\x{hh}` is not currently a valid
escape sequence there should be no source compatibility issue.

Making the literals work did involve some surgery in the type checker,
but this should not affect anyone not using the new type.

The changes in the standard library are purely additive in nature, and
won't affect anything not using these types.

## ABI compatibility

This proposal _does_ introduce new umbrella protocols as parents of
the `ExpressibleByStringLiteral`, `ExpressibleByStringInterpolation`,
`ExpressibleByExtendedGraphemeClusterLiteral` and
`ExpressibleByUnicodeScalarLiteral`, in order to allow the type checker
to correctly select between `String` and `UncheckedString` literals.

This should not impact existing code, however.

## Implications on adoption

This proposal requires new versions of Swift Syntax and the compiler,
in addition to the standard library.

Programs using the `UncheckedString` type will need to be using a new
enough compiler and standard library.

## Future directions

We could, in future, add a `WideString` type that holds _checked_
UTF-16 data.  This might be interesting on Windows, or perhaps for
Java interop, though in both of those cases there might be concerns
about whether other code on the system actually cared to maintain
proper UTF-16 invariants (i.e. it's possible that `UncheckedString<UInt16>`
or `UncheckedString<CWideChar>` is preferable anyway).

`FilePath` could use `UncheckedString` as its backing store.

We could add regular expression support for `UncheckedString`s.

## Alternatives considered

### Storing non-UTF-8 string data in `Array` or `Data`.

The downsides here are significant; there is no literal support,
whatsoever, and `Array` and `Data` do not support all of the methods
one might expect on a `String`-like type, which leads to rather
unnatural looking programs.

Additionally, `UncheckedString` has a `CustomDebugStringConvertible`
override, which means that you can easily inspect one in a string-like
format, which isn't the case for `Array` or `Data`.

### Attempting to convert non-UTF-8 data to UTF-8 `String`s

This works _some_ of the time, for instance for string data that we know
to be pure ASCII, but is potentially inefficient — for instance, there is
no need to go checking MIME or HTTP headers to make sure that the header
names are valid UTF-8, and if you do so then you also have to handle the
situation where one of them turns out not to be (for instance because an
attacker is sending malformed data to your program).

Additionally, conversions can be expensive, and quite often you would need
to convert back the other way again when serializing data.

### Element being constrained to some type besides FixedWidthInteger

On some platforms, or with some compiler flags on some platforms, `CChar`
might be signed.  Thus requiring conformance to `UnsignedInteger` is too
strict.  `FixedWidthInteger` seems a reasonable requirement given that the
expected use case here is that `Element` will be `UInt8`, `CChar`, `UInt16`,
`CWideChar` (on Windows only — `CWideChar` on POSIX platforms is unfortunately
defined as `Unicode.Scalar`, which is not a `FixedWidthInteger` and which is
also, arguably, incorrect) or possibly `UInt32`.

### Other `Codable` encodings for `UncheckedString`

We considered several alternatives to the array-of-`Element` encoding
described in "`Codable` support" above:

* **Best-effort decoding to `String`, encoded as a single-value string
  container.** Reintroduces exactly the encoding-guessing hazard
  `UncheckedString` exists to avoid, and produces a wire *shape* that
  depends on the byte content (a JSON string for input that happens to be
  valid text, something else otherwise) rather than being fixed by the
  static type -- bad for schema stability.

* **A single string using `\x{hh}`-style escapes**, mirroring
  `UncheckedString`'s own `debugDescription` format, instead of an array of
  integers. This is more compact and human-readable for the common case of
  mostly-printable-ASCII content (paths, headers), and -- unlike the array
  form -- the result can, in most cases, be pasted back in as a Swift
  literal. However: it still makes the wire shape "a string," inviting a
  non-Swift consumer to wrongly assume ordinary UTF-8 text; it requires
  layering a second, Swift-specific escape grammar *inside* whatever
  escaping the target format already applies to strings (a literal `\`
  becomes `\x{5c}`, which a JSON encoder, for instance, would then
  re-escape again as `\\x{5c}` on the wire); it has no precedent in the
  standard library or Foundation -- `Data`'s closest analog, base64, is
  deliberately kept *out* of `Data`'s own `Codable` conformance and pushed
  into `JSONEncoder`'s `dataEncodingStrategy` instead, precisely so the
  type's own conformance stays format-neutral; the "compact" argument
  inverts for genuinely binary payloads (`\x{hh}` costs more per byte than
  an integer-array entry) and doesn't hold as well as it first appears for
  `UncheckedString<UInt16>` holding real non-English text, since most such
  content falls outside the 32-127 "printable" window and gets escaped
  anyway; and it needs meaningfully more decode-side code (a hand-written
  variable-length hex-escape parser with its own malformed/truncated/
  overflow error cases) than the array form's zero format-specific parsing.
  This reads more like a plausible *encoder-level* policy for someone who
  specifically wants human-readable JSON, similar to
  `dataEncodingStrategy`, than something `UncheckedString`'s own default
  conformance should do.

* **A single string using `%hh`-style escapes**.  Avoids the problem of
  clashing with the JSON escape syntax, but otherwise suffers from similar
  problems to the `\x{hh}`-style escapes, and would not be easily paste-able
  as a Swift literal.

* **A string with an array of replacement characters**.  This is similar to
  the representation used within the compiler before generation of the final
  literal bytes.  The idea here is that each `\x{hh}` escape would be
  represented in the string by a Unicode REPLACEMENT CHARACTER (U+FFFD),
  as well as separate array containing the character offset and the value
  to replace it with.  This representation is justified within the compiler
  because it allows existing code to print string literals in a reasonable
  manner without worrying about `\x{hh}` escapes, and we also do not know
  the width of the target encoding until much later on.  As a general-purpose
  encoding format, however, it seems unnecessarily complex.

* **Delegating to `Array<Element>`'s existing `Codable` conformance**,
  via an intermediate `Array(self)` (`encoder.singleValueContainer().encode(Array(self))`
  / `decoder.singleValueContainer().decode([Element].self)`) instead of
  writing the loop directly. This produces the same wire format, but
  forces a redundant array copy on encode, and `Array`'s own `Decodable`
  conformance doesn't pre-size via the decoder's reported element count at
  all, silently forgoing the presizing optimization `UncheckedString`'s own
  `init(from:)` performs (mirroring `Data.init(from:)`). Not worth it for
  either direction.

* **Not conforming to `Codable` at all.** This is the "do nothing"
  baseline; insufficient given how commonly path-, header-, and
  environment-variable-like data ends up embedded inside larger `Codable`
  request/response/config/log models.

## Acknowledgments

Claude helped somewhat with this document and quite a bit with the
implementation.
