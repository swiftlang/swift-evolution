# Single-quoted code unit literals

 * Proposal: SE-NNNN
 * Authors: [taylorswift](https://github.com/kelvin13), [John Holdsworth](https://github.com/johnno1962)
 * Review manager:
 * Status:
 * Implementation:
 * Threads:
 [1](https://forums.swift.org/t/prepitch-character-integer-literals/10442)
 [2](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188)
 [3](https://forums.swift.org/t/single-quoted-character-literals-why-yes-again/61898/)

## Introduction

In swift, double-quoted literals (`"a"`) can have several different meanings, depending on type context and visible `typealias` definitions. Using the same notation for `String`-like collection types, and their `Character`-like element types has led to difficulty communicating the meaning of operators such as `+=`, and developer confusion surrounding the availability of standard library APIs such as `func + (lhs:Character, rhs:Character)`, which does not exist in the standard library today, but is widely imagined to exist due to its syntactical similarity to `func + (lhs:String, rhs:String)`.

It is also a longstanding pain point that developers writing code that performs low-level unicode string processing or buffer-decoding tasks have no type-safe way of expressing UTF-8 or UTF-16 code units using a human-readable literal syntax.

As a solution to both problems, we propose adding single-quoted literals (`'a'`) to the language, aiming to:

1.  untangle collection-element syntactical overloading, and
2.  provide a natural avenue for expressing UTF-8 and UTF-16 code units in source.

Four years ago during the review of a similar proposal, [SE-0243](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188), these were seen as two unrelated issues that both happened to motivate adding single-quoted literals to the language, and it was [advised](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188/341) that the feature be broken up to address each problem separately. 

However, as we have iterated the design and gained more experience with low-level unicode string processing in the language, it has become apparent that the two problems are in fact interconnected, and that problem 1) prevents us from addressing problem 2) in a way that is consistent with the design of the language.

### Feature overview

This proposal:

1.  Introduces a new lexical expression, **the single-quoted literal** (`'a'`), to the language syntax.

    This **concurs** with the position taken by the core team in 2018 during the review of SE-0243.

2.  Introduces four **new literal expression domains** to the standard library:

    i.      `ExpressibleByASCIILiteral`,

    ii.     `ExpressibleByBMPLiteral`,

    iii.    `ExpressibleByCodepointLiteral`, and

    iv.     `ExpressibleByCharacterLiteral`;

    which will be independent of the existing double-quoted expression domains such as [`ExpressibleByUnicodeScalarLiteral`](https://swiftinit.org/reference/swift/expressiblebyunicodescalarliteral).

    This **contradicts** the position taken by the core team in 2018.

3.  Adds **conformances for standard library types** to the new expression domains:

    i.      [`UInt8`]()`:ExpressibleByASCIILiteral`

    ii.     [`UInt16`]()`:ExpressibleByBMPLiteral`

    iii.    [`Unicode.Scalar`]()`:ExpressibleByCodepointLiteral`

    iv.     [`Character`]()`:ExpressibleByCharacterLiteral`

    This was not part of SE-0243, but a related feature, that would have allowed users to enable expressing [`FixedWidthInteger`](https://swiftinit.org/reference/swift/fixedwidthinteger) types with single-quoted literals via retroactive `ExpressibleByUnicodeScalarLiteral` conformances, was.

4.  Adds default implementations for the requirements of the new expression domain protocols where `Self` conforms to one of the following double-quoted expression domains, to **allow user-defined types to opt-in to the new syntax**, and allow users to retroactively enable the single-quoted syntax for library types:

    i.      [`ExpressibleByUnicodeScalarLiteral`](https://swiftinit.org/reference/swift/expressiblebyunicodescalarliteral)

    ii.     [`ExpressibleByExtendedGraphemeClusterLiteral`](https://swiftinit.org/reference/swift/expressiblebyextendedgraphemeclusterliteral)

    This was not part of SE-0243.

### Differences from previous versions of this proposal

Proposals similar to this proposal have been pitched twice in the past.

1. [SE-0243: Codepoint and Character Literals](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188) ([rejected](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188/341))

2. [(unreviewed): Single Quoted Character Literals](https://forums.swift.org/t/single-quoted-character-literals-why-yes-again/61898)

To summarize differences from these previous proposals:

1.  This proposal **does not require or encourage deprecating double-quoted syntax** for `Character`, `Unicode.Scalar`, etc., although the community may wish to explore this direction should this proposal be accepted.

    SE-0243 [mapped out a path to deprecate](https://github.com/apple/swift-evolution/blob/main/proposals/0243-codepoint-and-character-literals.md#existing-double-quote-initializers-for-characters) this syntax.

2.  This proposal **does not introduce character-to-integer ‘conversions’ in the general case**, only for the UTF code unit types `UInt8` and `UInt16`.

    Previous proposals called for general `FixedWidthInteger` convertibility, including `Int` convertibility.

3.  This proposal does not enable “performing arithmetic on strings”, although this proposal will **make it easier to express low-level ASCII arithmetic** in a human-readable form.

    Previous proposals would have allowed arithmetic on double-quoted literals to typecheck in the medium term (until swift 6), and advocated for using compiler warnings and eventual deprecation of double-quoted character literals to mitigate this issue.

4.  This proposal **does not enable single-quoted syntax for `String`/`StaticString`**, even for single-character strings.

    Previous proposals would have caused [`ExpressibleByStringLiteral`](https://swiftinit.org/reference/swift/expressiblebystringliteral) to imply conformance to expression domain protocols that use single-quoted syntax.

5.  This proposal **does not modify the existing double-quoted literal expression domain hierarchy**.

    Previous proposals called for restructuring the double-quoted protocol hierarchy to achieve item 4.

## Motivation

### Collection-element syntactical overloading (CESO)

Many programming languages draw a visual distinction between their “textual collection” type and their “textual unit” type:

```c
char const* const this_is_a_collection = "a";
char const this_is_an_element = 'a';
```

In the general case, swift follows the same philosophy:

```swift
let collection:[Int] = [1]
let element:Int = 1
```

We do not allow implicit promotion of collection elements to collections, so the following is ill-formed:

```swift
let invalid:[Int] = 1
```

Strings and characters are not an exception to this rule, and it is not legal to implicitly promote a `Character` to a `String`:

```swift
let invalid:String = ("a" as Character)
```

Despite this, it is a common misconception that character-to-string promotion exists in the language because characters and strings share a common double-quoted literal syntax. To facilitate discussion, we will refer to this phenomenon as **collection-element syntactical overloading** (CESO).

One consequence of CESO is that developers often encounter statements that look like the following:

```swift
let a:String = "a"
let ab:String = "a" + "b"
```

and mistakenly conclude that it is possible to concatenate two characters and get a `String` as a result, even though such an operation would be analogous to:

```swift
1 + 1 == [1, 1]
```

Therefore, some feel it is desirable to have single-quoted character expressions in order to visually strengthen the following analogy:

```swift
let a:[Int]  = [1] + [1]
let b:String = "1" + "1"
```

CESO is academically distasteful, but it rarely causes problems (that developers are likely to consciously attribute to CESO) in everyday programming, which is why much of the desire among swift developers at large for single-quoted literals stems instead from low-level unicode string processing.

### Low-level unicode string processing (LLSP)

**Low-level unicode string processing** (LLSP) means slightly different things to different users, but it usually boils down to the need to express UTF-8 and UTF-16 code units (`UInt8` and `UInt16`) with a human-readable character literal. For example, LLSP users generally want to be able to do things like the following:

```swift
func findTag(html:ByteBuffer) -> Tag
{
    let start:Int = html.readableBytesView.firstIndex(of: '<')
    ...
}
```

```swift
func isHTTPS(url:[UInt8]) -> Bool
{
    url.starts(with: ['h', 't', 't', 'p', 's', ':', '/', '/'])
}
```

```swift
func csv(text:String.UTF8View) -> [Substring.UTF8View]
{
    text.split(separator: ',')
}
```

Due to its low-level nature, LLSP often occurs in proximity to code unit arithmetic:

```swift
mutating
func next() -> UInt8?
{
    while let digit:UInt8 = self.iterator.next()
    {
        switch digit 
        {
        case '0' ... '9':   return digit      - '0'
        case 'a' ... 'f':   return digit + 10 - 'a'
        case 'A' ... 'F':   return digit + 10 - 'A'
        default:            continue
        }
    }
    return nil
}
```

which is sometimes derided as “performing arithmetic on characters”, although strictly speaking, we are not performing arithmetic on characters, we are performing arithmetic on character encodings, with constants expressed using characters.

Although it is usually possible to rewrite such algorithms using higher-level `String` and `Character` APIs, such approaches suffer from [major performance issues](https://forums.swift.org/t/single-quoted-character-literals-why-yes-again/61898/30), and are not a viable substitute for LLSP.

In the absence of code unit literals, some LLSP users fall back to expressing code unit constants with hexadecimal integer literals.

```swift
        switch digit 
        {
        case 0x30 ... 0x39: return digit      - 0x30
        case 0x61 ... 0x66: return digit + 10 - 0x61
        case 0x41 ... 0x46: return digit + 10 - 0x41
        default:            continue
        }
```

This suffers from poor readability, so code reviewers often recommend force-casting from a unicode scalar literal instead. For example, rather than merging an implementation like the following:

```swift
func findSection<UTF16>(utf16:UTF16) -> UTF16.Index?
    where UTF16:BidirectionalCollection<UInt16>
{
    utf16.firstIndex(of: 0xA7)
}
```

a reviewer or a style guide may recommend:

```swift
func findSection<UTF16>(utf16:UTF16) -> UTF16.Index?
    where UTF16:BidirectionalCollection<UInt16>
{
    utf16.firstIndex(
        of: UInt16.init(exactly: ("§" as Unicode.Scalar).value)!)
}
```

However, storing numeric unicode offsets into unicode code units is hazardous because it does not account for text encoding. For example, someone may try to port `findSection(utf16:)` to operate on UTF-8 strings, and come up with something like the following:

```swift
func findSection<UTF8>(utf8:UTF8) -> UTF8.Index?
    where UTF8:BidirectionalCollection<UInt8>
{
    utf8.firstIndex(
        of: UInt8.init(exactly: ("§" as Unicode.Scalar).value)!)
}
```

Despite the [`UInt8.init(exactly:)`](https://swiftinit.org/reference/swift/uint8.init%28exactly:%29?overload=ss17FixedWidthIntegerPsE7exactlyxSgqd___tcSBRd__lufc) conversion succeeding, this implementation is incorrect, because UTF-8 does not encode `'§'` using its integral codepoint value — it must be encoded as a multi-byte code unit sequence.

Expressing the code unit with an integer literal is equally unsafe. Even though it typechecks and does not trap at run-time, the following implementation is also incorrect:

```swift
func findSection<UTF8>(utf8:UTF8) -> UTF8.Index?
    where UTF8:BidirectionalCollection<UInt8>
{
    utf8.firstIndex(of: 0xA7)
}
```

Using the dedicated [`UInt8.init(ascii:)`](https://swiftinit.org/reference/swift/uint8.init%28ascii:%29) initializer is slightly better, but would still not alert the programmer of the bug until it crashed at run-time.

```swift
func findSection<UTF8>(utf8:UTF8) -> UTF8.Index?
    where UTF8:BidirectionalCollection<UInt8>
{
    utf8.firstIndex(of: UInt8.init(ascii: "§")!)
}
```

Therefore, from a type safety perspective, it is desirable to have compiler support for restricted, encoding-aware literal expression domains, such that the following would trigger a compilation error:

```swift
func findSection<UTF8>(utf8:UTF8) -> String?
    where UTF8:BidirectionalCollection<UInt8>
{
    utf8.firstIndex(of: '§')
//                      ^~~
//  error: character literal '§' encodes a UTF-8 continuation byte
//         when stored into type 'UInt8'
}
```

As a maximalist position, some LLSP users in the past have advocated for general integer convertibility based on unicode scalar offset, including convertibility with `Int`. However, nearly all real-world use cases are grounded in UTF-8 or UTF-16 string processing, so this proposal only advocates for interoperability with `UInt8` and `UInt16`, as is consistent with the type definitions for [`String.UTF8View.Element`](https://swiftinit.org/reference/swift/string/utf8view/element) and [`String.UTF16View.Element`](https://swiftinit.org/reference/swift/string/utf16view).

### Relationship between CESO and LLSP arithmetic

Most people who care about single-quoted literals are **against CESO**, **in favor of LLSP**, or some mixture of the two.

In the past, CESO and LLSP were seen as disjoint causes.

-   CESO is more likely to draw opposition from individuals for whom language philosophy and language education are salient, such as language architects, work group members, etc.

-   CESO opponents support adding **single-quoted literals** to the language.

-   Some CESO opponents dismiss LLSP concerns, because they hold the viewpoint that string processing should be encoding-agnostic. In their view, `Character`, not `UInt8` or `UInt16`, is the correct level of abstraction.

-   LLSP is more likely to draw support from individuals who work in unicode encoding-aware contexts, such as server-side development, file format decoders/encoders, high-performance text processing, etc.

-   LLSP proponents support adding **code unit literals** to the language, and using them to express `UInt8` and `UInt16`.

-   Some LLSP proponents dismiss CESO concerns, because they regard it as principally aesthetic in nature. In their view, quote syntax is irrelevant, and code unit literals could just as well be spelled using double quotes.

In the past, this created an impasse, because CESO opponents tend to jettison items important to LLSP proponents, and LLSP proponents tend to regard efforts to advance CESO-only proposals as a form of legislative decoupling, engendering distrust between the two camps.

As we have iterated on our design, it has become apparent that CESO causes the code unit arithmetic implications of LLSP to be confusing to experienced users, and unacceptably dangerous to new users. Thus, the two problems are connected, and adding LLSP features requires reducing the occurence of CESO in the language.

The issues CESO causes are almost entirely due to the double meaning of the `+` operator.

In collection contexts, `+` denotes concatenation:

```swift
let integers:[Int] = [1] + [1]
let string:String  = "." + "."
```

In non-collection contexts, `+` denotes addition:

```swift
let integer:Int  =  1  +  1
let scalar:UInt8 = '.' + '.' // hypothetical
```

Earlier proposals were LLSP-biased, and did not regard cleanly separating collection syntax from element syntax as an important goal. In order to gain the widest immediate adoption of single-quoted code unit literals, we proposed grandfathering in all existing (and future) types that could be expressed with:

1.  A double-quoted character (extended grapheme cluster) literal, or

2.  A double-quoted unicode scalar literal (implies #1),

to use the single-quoted syntax by default. Because `String` can be expressed by a double-quoted unicode scalar literal, this meant that single-character strings could be coerced from single-quoted character literals. An unfortunate implication of this design is that `'.' + '.'` would produce either a collection, or an element, depending on type context.

```swift
let a:String = "." + "." // returns ".."
let b:String = '.' + '.' // returns ".."
let c:UInt8  = '.' + '.' // returns 0x5C
```

Under this proposal, `b` would not be legal, eliminating this source of potential confusion.

Under this proposal, `c` would be legal, but would generate a compiler warning specially-cased for `+`.


### Arguments in favor of CESO

Some LLSP-centric thinking can overlap with pro-CESO positions.

One LLSP-centric school of thought holds that [`Unicode.UTF8.CodeUnit`](https://swiftinit.org/reference/swift/unicode/utf8/codeunit) is the natural atomic unit of a UTF-8 string, and that characters with multi-byte encodings under UTF-8 (such as general `Character`s) are conceptually collections like `String`. Supporters of this idea support adding a `Character.+(_:_:)` operator that returns a `String` to the standard library.

Because we propose enabling single-quoted syntax for `Character`s, this implies that

```swift
let b:String = '.' + '.'
```

must be legal, which implies support for CESO.

We do not endorse this idea, because of its potential for confusion with code unit arithmetic.

### Arguments against LLSP

Some users of non-unicode text encodings, such as [EBCDIC](https://en.wikipedia.org/wiki/EBCDIC), oppose associating `UInt8` and `UInt16` with unicode literals. They are not necessarily opposed to the unicode-based nature of swift’s string APIs, but view byte- and word-level abstractions such as `UInt8` and `UInt16` as a neutral ground that should not be associated with a particular text encoding.

We do not find this argument convincing, because nothing about this proposal would actually worsen the EBCDIC experience today — EBCDIC users could simply continue expressing EBCDIC code units using integer literals as is the status-quo.

## Proposed solution

This proposal **contradicts** two recommendations the 2018 core team made in its rejection of SE-0243, which this proposal is based on (emphasis added):

> **A**. One concern raised during the review was that because `ExpressibleByStringLiteral` refines `ExpressibleByExtendedGraphemeClusterLiteral`, then type context will allow expressions like `'x' + 'y' == "xy"`. The core team agrees that this is unfortunate and that if these protocols were redesigned, this refinement would not exist. However, **this is not considered enough of an issue** to justify introducing new protocols to avoid the problem.

> **B**. The core team recommends breaking this proposal out into two separate proposals that could be re-pitched and (depending on the pitch outcome) re-run.

**Part 2** (Literal expression domains) of this proposal contradicts **Recommendation A**. In our view, this is justified, because at the time of SE-0243, `'x' + 'y' == "xy"` was considered a “CESO problem”, and the impact of expression domain protocol inheritance on code unit arithmetic was not yet fully understood.

*   With the understanding we have today, `'x' + 'y' == "xy"` not only entrenches CESO in the language, it also makes LLSP unacceptably confusing. In a sense, it is the worst of both worlds, and the cost of retrofitting the existing double-quoted protocol hierarchy is greater than initially believed.

*   As we have explored this design space with respect to syntax migration strategies, we have also come to believe that introducing an independent protocol hierarchy holds value on its own, because it gives users greater control over opting types in to using the new syntax, and migrating types off of using the old syntax. It also reinforces the concept that single-quoted literals are a new and different construct, rather than just “prettier double-quoted literals”.

Some components of **Part 3** (3.i., 3.ii.) overlap with or resemble features **Recommendation B** called for jettisoning from SE-0243. In our view this is justified, because some of the design choices we make in **Part 2** only make sense in the context of **Part 3.i. – 3.ii.**

*   The ASCII and BMP literal expression domains only exist to support UTF-8 and UTF-16 use cases. At the `Unicode.Scalar` abstraction level and above, there is no value in having more-restricted domains available.

*   In a world where UTF-8 did not exist, we would not want to draw the borders of the “byte-size” expression domain to match the ASCII encoding. We would probably want to draw the border at the [Latin-1 Supplement Block](https://en.wikipedia.org/wiki/Latin-1_Supplement), since it has a one-to-one mapping with `UInt8` states.

    In a more cynical view, this proposal consciously handicaps [ISO/IEC 8859-1](https://en.wikipedia.org/wiki/ISO/IEC_8859-1) use cases in order to preserve UTF-8 interoperability. **ISO/IEC 8859-1 users cannot use single-quoted literals to express `UInt8`-encoded non-ASCII characters.** This restriction would not make sense if the eventual goal were not to improve UTF-8 type safety.

*   `ExpressibleByASCIILiteral` and `ExpressibleByBMPLiteral` would be root protocols, and it would not be possible to add them in a later proposal without breaking ABI.

### 1.  Single-quoted literals

We propose adding a new lexical expression, the single-quoted literal (`'a'`), to the language syntax.

**All of the following would be valid single-quoted literals**:

```swift
('a' as Never)          //  A
('é' as Never)          //  B
('🇺🇸' as Never)         //  C
('\r\n' as Never)       //  D
('\0' as Never)         //  E
('\'' as Never)         //  F
('\u{61}' as Never)     //  G
```

The lexer can already understand and reject these kinds of single-quoted literals, so this change would only naturalize them.

**The following would be a valid single-quoted literal, even though it is not a valid double-quoted literal today**:

```swift
('"' as Never)          //  H
```

This is the *only* case we propose of a single-quoted literal that would not be a valid double-quoted literal today.

**The following would be grammatically-valid single-quoted literals**, even though the compiler could likely reject and diagnose them without type context using knowledge of unicode:

```swift
('abc' as Never)        //  I
('\u{D800}' as Never)   //  J
```

The compiler today can reject **Case I**’s double-quoted equivalent *with* type context, but we expect that it would be able to reject **Case I** single-quoted form without type context.

The compiler today can already reject **Case J**’s double-quoted equivalent without type context.

**The following would *not* be a valid single-quoted literals, even though they are valid double-quoted literals today**:

```swift
('' as Never)           //  K
(''' as Never)          //  L
```

The compiler today can reject **Case K**’s double-quoted equivalent *with* type context, but we expect that it would be able to reject **Case K** single-quoted form without type context.

**Case L** could be special-cased and accepted, but we feel that it would be more consistent to require U+0027 to be written with a backslash (**Case F**).

These are the *only* two cases we propose of double-quoted literals that would not be formally-valid single-quoted literals.

**The following would *not* be valid single-quoted literals**:

```swift
('\' as Never)          //  M
('\x{D800}' as Never)   //  N
('\u{}' as Never)       //  O
('\u{FFFFFFFFF}' as Never)  // P
('\f' as Never)         // Q
('\(foo)' as Never)     // R
```

In theory, we could permit **Case M**, but we felt that it would be more consistent to require U+00B8 to be written with two backslashes.

Note that to simplify discussion, we do not consider string interpolation literals, like **Case R**, to be “double-quoted literals” in this proposal.

### 2.  Literal expression domains

We propose that single-quoted literals will support four literal expression domains:

i.      [**ASCII characters**](https://en.wikipedia.org/wiki/ASCII) (`ExpressibleByASCIILiteral`),

ii.     [**BMP characters**](https://en.wikipedia.org/wiki/Plane_(Unicode)#Basic_Multilingual_Plane) (`ExpressibleByBMPLiteral`),

iii.    **General unicode codepoints** (`ExpressibleByCodepointLiteral`), and

iv.     **General extended grapheme clusters** (`ExpressibleByCharacterLiteral`).

#### Domain protocol inheritance

Every literal expression domain in the proposed list of domains will be exposed as a standard library protocol.

Expression domains that appear lower in the list are supersets of domains that appear higher in the list, and **conforming to its associated “`ExpressibleBy`” protocol implies conforming to the associated protocols of all the domains above it**.

#### Promoted literal types

Each expression domain except for `ExpressibleByBMPLiteral` will support exactly one promoted literal type. A **promoted literal type** is a concrete standard library type that the `init` witness for an “`ExpressibleBy`” protocol can accept as an argument.

All existing non-container “`ExpressibleBy`” protocols, except for [`ExpressibleByNilLiteral`](https://swiftinit.org/reference/swift/expressiblebynilliteral), allow configuring a promoted literal type via an `associatedtype` requirement, such as [`ExtendedGraphemeClusterLiteralType`](https://swiftinit.org/reference/swift/expressiblebyextendedgraphemeclusterliteral/extendedgraphemeclusterliteraltype).

The set of allowed promoted literal types usually progresses in the opposite direction of the domain protocol inheritance relationships. For example, `ExtendedGraphemeClusterLiteralType` supports

-   `StaticString`,
-   `String`, and
-   `Character`,

but it does not support

-   `Unicode.Scalar`.

Developers often find promoted literal types confusing, and we feel that having multiple promoted literal types rarely justifies the added complexity.

#### i. ASCII characters (`ExpressibleByASCIILiteral`)

In an `ExpressibleByASCIILiteral` type context, single-quoted literals can contain ASCII characters (U+0000 – U+007F).

ASCII literals would have a promoted literal type of `UInt8`.

All of **the following would be valid single-quoted ASCII literals**:

```swift
('\0' as some ExpressibleByASCIILiteral)
('\u{0}' as some ExpressibleByASCIILiteral)
('\n' as some ExpressibleByASCIILiteral)
('a' as some ExpressibleByASCIILiteral)
('\\' as some ExpressibleByASCIILiteral)
('\u{7F}' as some ExpressibleByASCIILiteral)
```

The following would be valid single-quoted literals, but **not single-quoted ASCII literals**, even though their unicode codepoints could be represented in `UInt8`.

```swift
('é' as some ExpressibleByBMPLiteral)
('\u{E9}' as some ExpressibleByBMPLiteral)
```

The compiler would always be able to reject invalid ASCII literals at compile time.

#### ii. BMP characters (`ExpressibleByBMPLiteral`)

In an `ExpressibleByBMPLiteral` type context, single-quoted literals can contain BMP characters (U+0000 – U+D7FF, and U+E000 – U+FFFF).

BMP literals will support two promoted literal types: `UInt16` and `Unicode.Scalar`. Unlike the other three proposed protocols, BMP literals need two promoted literal types because it is only possible to recover their expression domain by intersecting `UInt16` with `Unicode.Scalar`.

**Every valid ASCII literal would be a valid BMP literal,** but they would be encoded as `UInt16` or `Unicode.Scalar` values instead of `UInt8` values.

All of **the following would be valid single-quoted BMP literals**, even though they would not be valid ASCII literals:

```swift
('€' as some ExpressibleByBMPLiteral)
('\u{20AC}' as some ExpressibleByBMPLiteral)
```

The following would be a formally-valid single-quoted literal, but **would not be a valid BMP literal**:

```swift
('\u{D800}' as Never)
```

Because none of the proposed literal expression domains accept `'\u{D800}'`, the compiler could reject this even without an `ExpressibleByBMPLiteral` type context.

The compiler would always be able to reject invalid BMP literals at compile time.

#### iii. General unicode codepoints (`ExpressibleByCodepointLiteral`)

In an `ExpressibleByCodepointLiteral` type context, single-quoted literals can contain any unicode codepoint.

`ExpressibleByCodepointLiteral`’s expression domain would be exactly the same as `ExpressibleByUnicodeScalarLiteral`’s domain today, except it would use single quotes instead of double quotes.

Unlike `ExpressibleByUnicodeScalarLiteral`, `ExpressibleByCodepointLiteral` would only support a promoted literal type of `Unicode.Scalar`.

The compiler can already reject invalid unicode codepoint literals at compile time.

#### iv. General extended grapheme clusters (`ExpressibleByCharacterLiteral`)

In an `ExpressibleByCharacterLiteral` type context, single-quoted literals can contain a general extended grapheme cluster.

`ExpressibleByCharacterLiteral`’s expression domain would be exactly the same as `ExpressibleByExtendedGraphemeClusterLiteral`’s domain today, except it would use single quotes instead of double quotes.

Unlike `ExpressibleByExtendedGraphemeClusterLiteral`, `ExpressibleByCharacterLiteral` would only support a promoted literal type of `Character`.

The criteria for a valid extended grapheme cluster literal changes slowly over time and is managed by the OS. The compiler cannot reject all invalid extended grapheme cluster literals at compile time, but it can reject a subset of them.

### 3.  Conformances for standard library types

We propose adding conformances for the following standard library types to the new expression domain protocols:

i.      [`UInt8`](https://swiftinit.org/reference/swift/uint8)`:ExpressibleByASCIILiteral`

ii.     [`UInt16`](https://swiftinit.org/reference/swift/uint16)`:ExpressibleByBMPLiteral`

iii.    [`Unicode.Scalar`](https://swiftinit.org/reference/swift/unicode/scalar)`:ExpressibleByCodepointLiteral`

iv.     [`Character`](https://swiftinit.org/reference/swift/character)`:ExpressibleByCharacterLiteral`

For the avoidance of confusion, each type in the list above is its own promoted literal type, and it is this conformance, not the role they play as promoted single-quoted literal types, that enables the single-quoted syntax.

Users can also conform their own types to the new expression domain protocols to opt-in to the single-quoted syntax.

In the absence of type information, the compiler will infer the `Character` type for a single-quoted literal, regardless of whether it qualifies for one of the more restricted expression domains.

```swift
let auto = 'x' // as Character
```

#### Diagnostics for `+`

As a special case, we propose that **the compiler will emit a warning diagnostic if it detects usage of the binary operators `+` on two single-quoted literal expressions that are inferred to have type `UInt8` or `UInt16`**.

```swift
let _:UInt8 = '1' + '1'
//            ~~~~~~~~^
//  warning: addition of two single-quoted literal expressions
```

To silence the warning, one of the operands must be parenthesized with an `as UInt8` or `as UInt16` annotation.

```swift
let _:UInt8 = '1' + ('1' as UInt8)
```

No warning will be emitted unless two single-quoted literals appear directly in a binary `+` operator expression, even if one of the operands was initialized with a single-quoted literal.

```swift
let x:UInt8 = '1'
let _:UInt8 = '1' + x
```

No warning will be emitted for `+=`, because a literal can never be passed `inout`.

```swift
var x:UInt8 = '1'
x += '1'
```

No warning will be emitted for `-`, `*`, `/`, etc.

```swift
let _:UInt8 = '1' - '1'
let _:UInt8 = '1' * '1'
let _:UInt8 = '1' / '1'
```

Although it uses knowledge of the inferred operand types, this warning will behave like a lexical diagnostic, since there is no such thing as a “single-quoted literal” at the typechecker level. The warning will match any operator using the identifier `+` regardless of declaring module.

It will not be possible to disable the warning on a custom `+` operator.

```swift
func + (lhs:UInt8, rhs:UInt8) -> UInt8

let _:UInt8 = '1' + '1'
//            ~~~~~~~~^
//  warning: addition of two single-quoted literal expressions
```

The warning will not apply to user defined operand types, standard library types that are retroactively-conformed to enable the single-quoted syntax, or mixed-type operators, even if they return `UInt8` or `UInt16`.

```swift
extension Int:ExpressibleByBMPLiteral
{
}

let _:Int = '1' + '1'
```

```swift
func + (lhs:Character, rhs:Character) -> String

let _:String = '1' + '1'
```

```swift
func + (lhs:UInt8, rhs:UInt8) -> UInt16

let _:UInt16 = '1' + '1'
```

Note that many such expressions would fail to compile anyway (without an explicit `as` coercion), due to ambiguous type inference.

```swift
func + (lhs:Int, rhs:Int) -> UInt8

let _:UInt8 = '1' + '1'
//                ^
//  error: ambiguous use of operator '+'
//  note: found this candidate
//      public static func + (lhs:UInt8, rhs:UInt8) -> UInt8
//                         ^
//  note: found this candidate
//      func + (lhs:Int, rhs:Int) -> UInt8
//           ^
```

### 4.  Migrating to single-quoted syntax

To aid migration to single-quoted literals, we propose adding default implementations for the requirements of the new expression domain protocols where `Self` conforms to one of the following double-quoted expression domains, to allow user-defined types to opt-in to the new syntax, and allow users to retroactively enable the single-quoted syntax for library types:

i.      [`ExpressibleByUnicodeScalarLiteral`](https://swiftinit.org/reference/swift/expressiblebyunicodescalarliteral).

ii.     [`ExpressibleByExtendedGraphemeClusterLiteral`](https://swiftinit.org/reference/swift/expressiblebyextendedgraphemeclusterliteral).

These default implementations will be available for any of their respective promoted literal types except for `StaticString`.

These default implementations will be available as extension members on `ExpressibleByCodepointLiteral` and `ExpressibleByCharacterLiteral`, not `ExpressibleByUnicodeScalarLiteral` or `ExpressibleByExtendedGraphemeClusterLiteral`.

If desired, users can disable the double-quoted syntax for their own types by removing conformances to `ExpressibleByUnicodeScalarLiteral` and `ExpressibleByExtendedGraphemeClusterLiteral`. There is no requirement to disable the double-quoted syntax in order to enable the single-quoted syntax.

## Detailed design

We will add a marker protocol `_ExpressibleByBuiltinBMPLiteral` to the standard library:

```swift
@_marker
protocol _ExpressibleByBuiltinBMPLiteral
{
}
extension UInt16:_ExpressibleByBuiltinBMPLiteral
{
}
extension Unicode.Scalar:_ExpressibleByBuiltinBMPLiteral
{
}
```

The new literal expression domain protocols will be defined as follows:

```swift
public
protocol ExpressibleByASCIILiteral
{
    init(asciiLiteral:UInt8)
}

public
protocol ExpressibleByBMPLiteral:ExpressibleByASCIILiteral
{
    associatedtype BMPLiteralType:_ExpressibleByBuiltinBMPLiteral
    init(bmpLiteral:BMPLiteralType)
}

public
protocol ExpressibleByCodepointLiteral:ExpressibleByBMPLiteral
    where BMPLiteralType == Unicode.Scalar
{
    init(codepointLiteral:Unicode.Scalar)
}

public
protocol ExpressibleByCharacterLiteral:ExpressibleByCodepointLiteral
{
    init(characterLiteral:Character)
}
```

Derived protocols will provide witnesses for their immediate ancestor.

```swift
extension ExpressibleByBMPLiteral
    where BMPLiteralType == UInt16
{
    @_alwaysEmitIntoClient
    public
    init(asciiLiteral:UInt8)
    {
        self.init(bmpLiteral: .init(asciiLiteral))
    }
}
extension ExpressibleByBMPLiteral
    where BMPLiteralType == Unicode.Scalar
{
    @_alwaysEmitIntoClient
    public
    init(asciiLiteral:UInt8)
    {
        self.init(bmpLiteral: .init(asciiLiteral))
    }
}
extension ExpressibleByCodepointLiteral
{
    @_alwaysEmitIntoClient
    public
    init(bmpLiteral:Unicode.Scalar)
    {
        self.init(codepointLiteral: bmpLiteral)
    }
}
extension ExpressibleByCharacterLiteral
{
    @_alwaysEmitIntoClient
    public
    init(codepointLiteral:Unicode.Scalar)
    {
        self.init(characterLiteral: .init(codepointLiteral))
    }
}
```

A note on `ExpressibleByCodepointLiteral.init(bmpLiteral:)`: because `UInt16` can encode values (such as the surrogates) that are outside the BMP literal expression domain, not every `UInt16` value can generate a valid `Unicode.Scalar`. Therefore `ExpressibleByCodepointLiteral` constrains `BMPLiteralType` to be `Unicode.Scalar`.

This does not affect `ExpressibleByBMPLiteral.init(asciiLiteral:)`, because every `UInt8` value is a valid `Unicode.Scalar`, even though half of them cannot be written with an ASCII literal.

`ExpressibleByCodepointLiteral` will provide default implementations when `Self` conforms to `ExpressibleByUnicodeScalarLiteral`:

```swift
extension ExpressibleByCodepointLiteral
    where   Self:ExpressibleByUnicodeScalarLiteral,
            UnicodeScalarLiteralType == Unicode.Scalar
{
    @_alwaysEmitIntoClient
    public
    init(codepointLiteral:Unicode.Scalar)
    {
        self.init(unicodeScalarLiteral: codepointLiteral)
    }
}
extension ExpressibleByCodepointLiteral
    where   Self:ExpressibleByUnicodeScalarLiteral,
            UnicodeScalarLiteralType == Character
{
    @_alwaysEmitIntoClient
    public
    init(codepointLiteral:Unicode.Scalar)
    {
        self.init(unicodeScalarLiteral: .init(codepointLiteral))
    }
}
extension ExpressibleByCodepointLiteral
    where   Self:ExpressibleByUnicodeScalarLiteral,
            UnicodeScalarLiteralType == String
{
    @_alwaysEmitIntoClient
    public
    init(codepointLiteral:Unicode.Scalar)
    {
        self.init(unicodeScalarLiteral: .init(codepointLiteral))
    }
}
```

`ExpressibleByCharacterLiteral` will provide default implementations when `Self` conforms to `ExpressibleByExtendedGraphemeClusterLiteral`:

```swift
extension ExpressibleByCharacterLiteral
    where   Self:ExpressibleByExtendedGraphemeClusterLiteral,
            ExtendedGraphemeClusterLiteralType == Character
{
    @_alwaysEmitIntoClient
    public
    init(characterLiteral:Character)
    {
        self.init(extendedGraphemeClusterLiteral: characterLiteral)
    }
}
extension ExpressibleByCharacterLiteral
    where   Self:ExpressibleByExtendedGraphemeClusterLiteral,
            ExtendedGraphemeClusterLiteralType == String
{
    @_alwaysEmitIntoClient
    public
    init(characterLiteral:Character)
    {
        self.init(extendedGraphemeClusterLiteral: .init(characterLiteral))
    }
}
```

The following standard library types would gain conformances:

```swift
extension Unicode.UTF8.CodeUnit:ExpressibleByASCIILiteral
{
    @_alwaysEmitIntoClient
    public
    init(asciiLiteral:UInt8)
    {
        self = asciiLiteral
    }
}
extension Unicode.UTF16.CodeUnit:ExpressibleByBMPLiteral
{
    @_alwaysEmitIntoClient
    public
    init(bmpLiteral:UInt16)
    {
        self = bmpLiteral
    }
}
extension Unicode.Scalar:ExpressibleByCodepointLiteral
{
    @_alwaysEmitIntoClient
    public
    init(codepointLiteral:Unicode.Scalar)
    {
        self = codepointLiteral
    }
}
extension Character:ExpressibleByCharacterLiteral
{
    @_alwaysEmitIntoClient
    public
    init(characterLiteral:Character)
    {
        self = characterLiteral
    }
}
```

## Source compatibility

Single-quoted literal expressions will be purely additive.

Introducing the new single-quoted literal expression domain protocols will be purely additive, but may collide in name with user-defined types. Standard library symbols are disadvantaged in name resolution, so this will not affect user code, it will simply render the new protocols inaccessible.

Conformances of standard library types to the new single-quoted literal expression domain protocols will be purely additive. Witnesses added to implement these conformances may collide in signature with user-defined extensions on their respective types.

Default implementations provided for the new expression domain protocols will be provided as extensions on those protocols, and therefore cannot possibly collide with any extant API.


 ## Effect on ABI stability

Passing a standard library type expressed as a single-quoted literal to an older ABI-stable framework will work.

```swift
import TicTacToe

TicTacToe.example(character: 'x' as Character)
```

Passing a library type expressed as a single-quoted literal to an older ABI-stable framework will not work by default, but can be made to work by adding a retroactive protocol conformance.

```swift
extension TicTacToe.Cell:ExpressibleByCharacterLiteral
{
}

TicTacToe.example(cell: 'x' as TicTacToe.Cell)
```

Passing a concrete type to a generic ABI-stable API will work, even if the API is constrained using the double-quoted expression domain protocols.

```swift
//  constrained to `some ExpressibleByExtendedGraphemeClusterLiteral`
TicTacToe.genericExample(
    someCharacterExpression: 'x' as Character)
TicTacToe.genericExample(
    someCharacterExpression: 'x' as TicTacToe.Cell)
```

Passing a generic type to a a generic ABI-stable API without the double-quoted type constraint will not work.

```swift
func foo(x:some ExpressibleByCharacterLiteral)
{
    TicTacToe.genericExample(someCharacterExpression: x)
    //  invalid, because `ExpressibleByCharacterLiteral` does
    //  not imply `ExpressibleByExtendedGraphemeClusterLiteral`
}
```

Back-deploying an implementation that uses single-quoted literals to express standard library types will work, even if the caller does not understand the new protocols, and even if the API uses generics.

```swift
public
func addGossipGirlSignature(
    to utf16:inout some RangeReplaceableCollection<UInt16>)
{
    utf16.append('x')
    utf16.append('o')
    utf16.append('x')
    utf16.append('o')
}
```

Back-deploying an implementation that uses single-quoted literals to express library types will not work by default, can be made to work by adding a retroactive protocol conformance.
```swift
import TicTacToe

extension TicTacToe.Cell:ExpressibleByCodepointLiteral
{
}

public
func addGossipGirlSignature(
    to cells:inout some RangeReplaceableCollection<TicTacToe.Cell>)
{
    cells.append('x')
    cells.append('o')
    cells.append('x')
    cells.append('o')
}
```
