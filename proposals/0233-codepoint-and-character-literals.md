* Proposal: SE-0233
* Authors: [Kelvin Ma](https://github.com/kelvin13) ([@*taylorswift*](https://forums.swift.org/u/taylorswift/summary)), [Chris Lattner](https://github.com/lattner) ([@*Chris_Lattner3*](https://forums.swift.org/u/Chris_Lattner3/summary)), [John Holdsworth](https://github.com/johnno1962) ([@*johnno1962*](https://forums.swift.org/u/johnno1962/summary))
* Review manager: 
* Status: *Awaiting review*
* Implementation (WIP): [`unicodeintegerliterals`](https://github.com/kelvin13/swift/tree/unicodeintegerliterals)
* Threads: [1](https://forums.swift.org/t/prepitch-character-integer-literals/10442)

## Introduction

Swift’s `String` type is designed for Unicode correctness and abstracts away the underlying binary representation of the string to model it as a `Collection` of grapheme clusters. This is an appropriate string model for human-readable text, as to a human reader, the atomic unit of a string is (usually) the extended grapheme cluster. When treated this way, many logical string operations “just work” the way users expect. 

However, it is also common in programming to need to express values which are intrinsically numeric, but have textual meaning, when taken as a Unicode scalar value. We propose adding a new literal type `CodepointLiteral` which takes single-quotes (`'`), and is transparently convertible to Swift’s integer types. This syntax will extend to all “scalar” text literals, up to and including `Character` (through the `CharacterLiteral` type), and will become the preferred literal syntax these types.

## Background and terminology

Swift (and Unicode) strings and characters sit atop two levels of abstraction over a binary buffer. These levels of abstraction are the **unicode codepoint** and the **unicode grapheme**.

Unicode codepoints are the atomic unit of Unicode. They are integers from `0x00_0000 ... 0x10_FFFF` which are assigned to characters such as `'é'` or control characters such as `'\n'`. The integer value of a codepoint is called its **unicode scalar**<sup>†</sup> and corresponds to the Swift type `Unicode.Scalar`.

Extended grapheme clusters (usually just **graphemes**) are ranges of codepoint sequences which humans percieve as logically a single “character”. This corresponds to the Swift `Character` type. An example of a grapheme is the `'👩‍✈️'` emoji, which contains three codepoints: `'👩'`, `'\u{200D}'` (zero-width joiner), and `'✈️'`. Grapheme breaking is context-dependent — `'👩'`, `'\u{200D}'`, and `'✈️'` are all valid graphemes in isolation, yet concatenating them in sequence “fuses” them into a single grapheme.

```swift
var string:String = "👩"
print(string, string.count)
// 👩 1

string.append("\u{200D}")
string.append("✈️")
print(string, string.count)
// 👩‍✈️ 1
```

Because characters can (somewhat confusingly) be built up from other characters, in this proposal we will only use the word **character** as a loose term for the general concept of a “textual unit”.

> † Valid unicode codepoints are actually a superset of valid unicode scalars, as certain codepoint values (`0xD800 ... 0xDFFF`) are reserved and so do not represent characters. These codepoints are used as sentinel shorts in the UTF-16 encoding, or, are simply unused at this time. This distinction is unimportant to this proposal.  

## Motivation 

For correctness and efficiency, `[UInt8]` (or another integer array type) is usually the most appropriate representation for a bytestring. (See [*Stop converting `Data` to `String`*](https://gist.github.com/kelvin13/516a5e3bc699a6b72009ff23f836a4bd) for a discussion on why `String` is an *inappropriate* domain.)

A major pain point of integer arrays is that they lack a clear and readable literal type. In C, `'a'` is a `uint8_t` literal, equivalent to `97`. Swift has no such equivalent, requiring awkward spellings like `UInt8(ascii: "a")`, or `UInt8(truncatingIfNeeded: ("a" as Unicode.Scalar).value)` for the codepoints above `0x80`. Alternatives, like spelling out the values in hex or decimal directly, are even worse. This harms readability of code, and is one of the sore points of bytestring processing in Swift.

```c
static char const hexcodes[16] = {
    '0', '1', '2', '3', '4' ,'5', '6', '7', '8', '9', 
    'a', 'b', 'c', 'd', 'e', 'f'
};
```

```swift
let hexcodes = [
    UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"),
    UInt8(ascii: "4"), UInt8(ascii: "5"), UInt8(ascii: "6"), UInt8(ascii: "7"),
    UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b"),
    UInt8(ascii: "c"), UInt8(ascii: "d"), UInt8(ascii: "e"), UInt8(ascii: "f")
]    
```

Sheer verbosity can be reduced by applying “clever” higher-level constructs such as

```swift 
let hexcodes = [
    "0", "1", "2", "3",
    "4", "5", "6", "7",
    "8", "9", "a", "b",
    "c", "d", "e", "f"
].map{ UInt8(ascii: $0) }
```

or even 

```swift 
let hexcodes = Array(UInt8(ascii: "0") ... UInt8(ascii: "9")) + 
               Array(UInt8(ascii: "a") ... UInt8(ascii: "f"))
```

though this comes at the expense of an even higher noise-to-signal ratio, as we are forced to reference concepts such as function mapping, or concatenation, range construction, `Array` materialization, and run-time type conversion, when all we wanted to express was a fixed set of hardcoded values.

In addition, the `init(ascii:)` initializer only exists on `UInt8`. If you're working with other types like `Int8` (common when dealing with C APIs that take `char`), it is much more awkward.  Consider scanning through a `char*` buffer as an `UnsafeBufferPointer<Int8>`:

```swift
for scalar in int8buffer {
    switch scalar {
    case Int8(UInt8(ascii: "a")) ... Int8(UInt8(ascii: "f")):
        // lowercase hex letter
    case Int8(UInt8(ascii: "A")) ... Int8(UInt8(ascii: "F")):
        // uppercase hex letter
    case Int8(UInt8(ascii: "0")) ... Int8(UInt8(ascii: "9")):
        // hex digit
    default:
        // something else
    }
}
```

Aside from being ugly and verbose, transforming `Character` or `Unicode.Scalar` literals also sacrifices compile-time guarantees. The statement `let codepoint:UInt16 = 128578` is a compile time error, whereas `let codepoint = UInt16(("🙂" as Unicode.Scalar).value)` is a run time error.

Codepoints are inherently textual, so it should be possible to express them with a textual literal without requiring layers upon layers of transformations. Just as applying the `String` APIs runs counter to Swift’s stated design goals of safety and efficiency, forcing users to express basic data values in such a convoluted and unreadable way runs counter to our design goal of [expressiveness](https://swift.org/about/#swiftorg-and-open-source).

Michel Fortin put it best: “*You need to express characters as code points or sometime lower-level integers in the parser. If it's a complicated mess to express this, then the parser becomes a complicated mess.*”

Codepoint literals would provide benefits to `String` users. One of the [future directions](https://gist.github.com/milseman/bb39ef7f170641ae52c13600a512782f#unmanaged-strings) for `String` is to provide performance-sensitive or low-level users with direct access to code units. Having numeric character literals for use with this API is hugely motivating. 

Furthermore, improving Swift’s bytestring ergonomics is an important part of our long term goal of expanding into embedded platforms. [Here’s one embedded developer’s take on the proposal](https://forums.swift.org/t/prepitch-character-integer-literals/10442/140?u=taylorswift).

## Proposed solution 

Let's do the obvious thing here, and add a textual literal type for Swift’s integer types. The value of the literal will be the value of its codepoint. We will introduce the protocols `ExpressibleByCodepointLiteral` and `ExpressibleByCharacterLiteral`, with the following conformances:

| `ExpressibleBy`… | `CodepointLiteral` | `CharacterLiteral` | `StringLiteral` | 
| --- | --- | --- | --- |
| `UInt8:`, … , `Int:` | yes | no | no |
| `Unicode.Scalar:` | yes | no | no |
| `Character:` | yes (inherited) | yes | no |
| `String:` | no | no | yes |

As valid Unicode scalar values are losslessly convertible to `Character` values, the `ExpressibleByCharacterLiteral` protocol will inherit from `ExpressibleByCodepointLiteral`. 

This proposal effectively separates `String` literals from `Character` literals and below. Unlike the existing `ExpressibleByUnicodeScalarLiteral` and `ExpressibleByExtendedGraphemeClusterLiteral` protocols, `String` and `StaticString` will not be valid inputs for custom `ExpressibleByCharacterLiteral` conformances, and `Character` and above will not be valid inputs for custom `ExpressibleByCodepointLiteral` conformances.

| `init(`…`)` | `codepointLiteral:` | `characterLiteral:` | `stringLiteral:` | 
| --- | --- | --- | --- |
| `UInt8`, … , `Int` | yes | no  | no  |
| `Unicode.Scalar`  | yes  | no  | no  |
| `Character`       | no   | yes | no  |
| `String`          | no   | no  | yes |
| `StaticString`    | no   | no  | yes |

This is a great simplification over the current textual literal protocols, which define implicit subtyping relationships between all Swift textual types from `Unicode.Scalar` up to `StaticString`.

`ExpressibleByCodepointLiteral` will work essentially as `ExpressibleByIntegerLiteral` works today. This allows us to statically diagnose overflowing codepoint literals, just as the compiler and standard library already work together to detect overflowing integer literals:

|                    | `'a'` | `'é'` | `'β'` | `'𓀎'` | `'👩‍✈️'` | `"ab"` |
| --- | --- | --- | --- | --- | --- | --- |
| `:String`          |          |        |          |       |         | "ab"
| `:Character`       | `'a'`    | `'é'`  | `'β'`    | `'𓀎'` | `'👩‍✈️'`
| `:Unicode.Scalar`  | U+0061   | U+00E9 | U+03B2   | U+1300E
| `:UInt32`          | 97       | 233  | 946        | 77838
| `:UInt16`          | 97       | 233  | 946        |
| `:UInt8`           | 97       | 233 
| `:Int8`            | 97       | −23  

Note that unlike `ExpressibleByIntegerLiteral`, the highest bit of the codepoint goes into the sign bit of the integer value. This makes processing C `char` buffers easier.

Single-quote literals may express multi-codepoint grapheme clusters. Thus, the following is a valid character literal:

```
let flag: Character = '🇨🇦'
```

With these changes, the hex code example can be written much more naturally:

```swift
let hexcodes: [UInt8] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 
    'a', 'b', 'c', 'd', 'e', 'f'
]

for scalar in int8buffer {
    switch scalar {
    case 'a' ... 'f':
        // lowercase hex letter
    case 'A' ... 'F':
        // uppercase hex letter
    case '0' ... '9':
        // hex digit
    default:
        // something else
    }
}
```

For reasons explained in the Detailed Design section, we propose defining the operators `+` and `*` on `Character × Character`, and `Character × Int`, respectively.

### Choice of single quotes

The proposed solution is syntax-agnostic and can actually be implemented entirely using double quotes. However, conforming some classes of textual literals to integer types can lead to some interesting spellings such as `"1" + "1" == 98` instead of `"11"`. We forsee problems arising from this to be quite rare, as type inference will almost always catch such mistakes, and very few users are likely to express a `String` with two literals instead of the much shorter `"11"`. 

Nevertheless, mixing arithmetic operators with double-quoted literals seems like a recipe for confusion, and there is enough popular demand for single-quoted literals that there is a compelling case for using a different quote syntax for these literals.

We propose to adopt the `'x'` syntax for all textual literal types, up to and including `ExtendedGraphemeClusterLiteral`, but not including `StringLiteral`. These literals will be used to express integer types, `Character`, `Unicode.Scalar`, and types like `UTF16.CodeUnit` in the standard library. 

The default inferred literal type for `let x = 'a'` will be `Character`. This follows the principle of least surprise, as most users expect `'1' + '1'` to evaluate to `"11"` more than `98`.

Use of single quotes for character/scalar literals is *heavily* precedented in other languages, including C, Objective-C, C++, Java, and Rust, although different languages have slightly differing ideas about what a “character” is.  We choose to use the single quote syntax specifically because it reinforces the notion that strings and character values are different: the former is a sequence, the later is a scalar (and "integer-like").  Character types also don't support string literal interpolation, which is another reason to move away from double quotes.

One significant corner case is worth mentioning: some methods may be overloaded on both `Character` and `String`.  This design allows natural user-side syntax for differentiating between the two.

### Single quotes in Swift, a historical perspective

In Swift 1.0, we wanted to reserve single quotes for some yet-to-be determined syntactical purpose. However, today, pretty much all of the things that we once thought we might want to use single quotes for have already found homes in other parts of the Swift syntactical space.  For example, syntax for [multi-line string literals](https://github.com/apple/swift-evolution/blob/master/proposals/0168-multi-line-string-literals.md) uses triple quotes (`"""`), and string interpolation syntax uses standard double quote syntax. With the passage of [SE-0200](https://github.com/apple/swift-evolution/blob/master/proposals/0200-raw-string-escaping.md), raw-mode string literals settled into the `#""#` syntax. In current discussions around [regex literals](https://forums.swift.org/t/string-update/7398/6), most people seem to prefer slashes (`/`).

At this point, it is clear that the early syntactic conservatism was unwarranted.  We do not forsee another use for this syntax, and given the strong precedent in other languages for characters, it is natural to use it.

### Existing double quote initializers for characters

We propose deprecating the double quote literal form for `Character` and `Unicode.Scalar` types and slowly migrating them out of Swift.

```swift
let c2 = 'f'               // preferred
let c1: Character = "f"   // deprecated
```

## Detailed Design 

This proposal attempts to design `ExpressibleByCodepointLiteral` and `ExpressibleByCharacterLiteral` as similarly to the existing protocols as possible, to aid migration. Each protocol has an `associatedtype` constraint for its literal initializer:

```swift
protocol ExpressibleByCodepointLiteral {
    associatedtype CodepointLiteralType : {UInt8, Int8, ..., Int}
    
    init(codepointLiteral: CodepointLiteralType)
}
```
```swift
protocol ExpressibleByCharacterLiteral : ExpressibleByCodepointLiteral {
    associatedtype CharacterLiteralType : {Character}
    
    init(characterLiteral: CharacterLiteralType)
}
```

Following language precedent, the `associatedtype` of a conforming type’s implementation signals to the compiler the most stringent level of compile-time checks it should do. 

```swift
struct Byte : ExpressibleByCodepointLiteral {
    let value: UInt8 
    init(codepointLiteral: UInt8) {
        self.value = codepointLiteral
    }
}
struct Short : ExpressibleByCodepointLiteral {
    let value: UInt16 
    init(codepointLiteral: UInt16) {
        self.value = codepointLiteral
    }
}

let short: Short = '→' 
// Short(value: 8594)

let byte: Byte   = '→' 
// error: codepoint literal '8594' overflows when stored into 'UInt8'
```

The set of allowed types for `Self.CodepointLiteralType`, `Self.CharacterLiteralType` is much smaller than those for `Self.UnicodeScalarLiteralType`, `Self.ExtendedGraphemeClusterLiteralType`. Most of the extraneous allowed types (such as `String` for `ExpressibleByUnicodeScalarLiteral.init(unicodeScalarLiteral:)`) are of little use to users conforming their custom types to these protocols. Stripping them out greatly simplifies the standard library implementation.

Types conforming to `ExpressibleByCharacterLiteral` will only need to provide the `init(characterLiteral:)` initializer, as `ExpressibleByCodepointLiteral` conformance can be derived from it.

```swift 
extension ExpressibleByCharacterLiteral where 
    CharacterLiteralType == Character {
    
    public init(codepointLiteral value: UInt32)
}
```

The default inferred type for all single-quoted literals will be `Character`, addressing an unrelated, but longstanding pain point in Swift, where `Character`s had no dedicated literal syntax.

```
typealias CharacterLiteralType = Character
typealias CodepointLiteralType = Character 
```

A potential point of confusion arises from the expression 

```
let a = '1' + '1'
```

which most users expect to return the `String` `"11"`. If the character literals are instead inferred to be of type `Int`, this will produce the numeric result `98`. We believe a simple solution is to define `+` on `Character × Character` such that `'1' + '1' == "11"`. The multiplication operator `*` should also be defined on `Character × Int` such that `'1' * 5 == "11111"`. This is precedented in popular languages such as Python. Other arithmetic operators such as `-` need not be defined for `Character` as these symbols are generally meaningless in a textual context.

```swift  
extension Character {
    public static func + (lhs: Character, rhs: Character) -> String 
    public static func * (repeatedValue: Character, count: Int) -> String
}
```

## Source compatibility 

This proposal could be done in a way that is strictly additive, but we feel it is best to deprecate the existing double quote initializers for characters, and the `UInt8.init(ascii:)` initializer.  

Here is a specific sketch of a deprecation policy: 
  
  * Continue accepting these in Swift 4 mode with no change.  
  
  * Introduce the new syntax support into Swift 5.
  
  * Swift 5 mode would start producing deprecation warnings (with a fixit to change double quotes to single quotes.)
  
  * The Swift 4 to 5 migrator would change the syntax (by virtue of applying the deprecation fixits.)
  
  * Swift 6 would not accept the old syntax.

The `ExpressibleByUnicodeScalarLiteral` and user-facing `ExpressibleByExtendedGraphemeClusterLiteral` protocols should be deprecated and removed, as they are no longer necessary. Few users implement custom literal conformances, and most of those who do should be able to migrate their old conformances by a simple find and replace:

```
ExpressibleByUnicodeScalarLiteral → ExpressibleByCodepointLiteral
ExpressibleByExtendedGraphemeClusterLiteral → ExpressibleByCharacterLiteral
unicodeScalarLiteral → codepointLiteral
extendedGraphemeClusterLiteral → characterLiteral
```

Conformances which are implemented with initializers that take `String` or `StaticString` will be broken, but can be easily and transparently fixed by casting the `Character` input to the appropriate `String` type.

## Effect on ABI stability 

No effect as this is an additive change.  Heroic work could be done to try to prevent the `UInt8.init(ascii:)` initializer and other to-be-deprecated conformances from being part of the ABI.  This seems unnecessary though.

## Effect on API resilience 

None. 

## Alternatives considered 

### Integer initializers 

Some have proposed extending the `UInt8(ascii:)` initializer to other integer types (`Int8`, `UInt16`, … , `Int`), and other codepoint ranges (`unicode8:`, `unicode16:`). However, this forgoes compile-time validity and overflow checking, and involves a substantial increase in API surface area for questionable gain. 32-bit initializers are also problematic, as they would overlap with `Unicode.Scalar.value`, which means codepoint values would be spelled differently depending on their desired width.
