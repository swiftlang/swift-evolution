# Refining identifier and operator symbology

* Proposal: [SE-NNNN](NNNN-refining-identifier-and-operator-symbology.md)
* Authors: [Xiaodi Wu](https://github.com/xwu), [Jacob Bandes-Storch](https://github.com/jtbandes), [Erica Sadun](https://github.com/erica), Jonathan Shapiro, [João Pinheiro](https://github.com/joaopinheiro)
* Review Manager: TBD
* Status: **Awaiting review**

<!--
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->


## Introduction

This proposal refines and rationalizes Swift's identifier and operator
symbology. Specifically, this proposal:

- refines the set of valid identifier characters based on Unicode
recommendations, with customizations principally to accommodate emoji;
- refines the set of valid operator characters based on Unicode categories; and
- changes rules as to where dots may appear in operators.


### Prior discussion threads and proposals

- [Define backslash '\' as a operator-head in the swift grammar](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170130/031461.html)
- [Refining Identifier and Operator Symbology](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161017/028174.html) (a precursor to this document)
- [Proposal: Normalize Unicode identifiers](https://github.com/apple/swift-evolution/pull/531)
- [Lexical matters: identifiers and operators](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160926/027479.html)
- [Unicode identifiers & operators](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160912/027108.html), with [pre-proposal](https://gist.github.com/jtbandes/c0b0c072181dcd22c3147802025d0b59)
- [Proposal: Allow Single Dollar Sign as Valid Identifier](https://github.com/apple/swift-evolution/pull/354)
- [Free the '$' Symbol!](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151228/005133.html)
- [Request to add middle dot (U+00B7) as operator character?](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/003176.html)


## Motivation

Swift supports programmers from many languages and cultures. However, the
current identifier and operator character sets do not conform to any Unicode
standards, nor have they been rationalized in the language or compiler
documentation. These deserve a well-considered, standards-based revision.

As Chris Lattner has written:

> We need a token to be unambiguously an operator or identifier - we can have
> different rules for the leading and subsequent characters though.

<!-- -->

> …our current operator space (particularly the Unicode segments covered) is not
> super well considered.  It would be great for someone to take a more
> systematic pass over them to rationalize things.

**Identifiers**, which serve as *names* for various entities, are linguistic in
nature and must permit a variety of characters in order to properly serve
non–English-speaking coders. This issue has been considered by the communities
of many programming languages already, and the Unicode Consortium has published
recommendations on how to choose identifier character sets. Swift should make an
effort to conform to these recommendations.

**Operators**, on the other hand, should be rare and carefully chosen because
they suffer from limited discoverability and readability. They are by nature
*symbols*, not names. This places a cognitive cost on users with respect to
recall ("What is the operator that applies the behavior I need?") and
recognition ("What does the operator in this code do?"). While almost every
non-trivial program defines new identifiers, most programs do not define new
operators.


### Inconsistency

Concrete discrepancies and edge cases motivate these proposed changes. For
example:

- The Greek question mark ; is a valid identifier.
- Some *non-combining* diacritics ´ ¨ ꓻ are valid in identifiers.
- Braille patterns ⠟, which are letter-like, are operator characters.
- Other symbols such as ⚄ and ♄ are operator characters despite not being
  "operator-like."
- Currency symbols are split across operators (¢ £ ¤ ¥) and identifiers (₪ € ₱ ₹
  ฿ ...).
- 🙂🤘▶️🛩 are identifiers, while ☹️✌️🔼✈️♠️ are operators.
- A few characters 〡〢〣〤〥〦〧〨〩   〪  〫  〬  〭  〮  〯 are valid in **both**
  identifiers and operators.


### Invisible distinctions

Identifiers that take advantage of Swift's Unicode support are not normalized.
This allows different representations of the same characters to be considered
distinct identifiers. For example:

    let Å = "Angstrom"
    let Å = "Latin Capital Letter A With Ring Above"
    let Å = "Latin Capital Letter A + Combining Ring Above"

Non-printing characters such as ZERO WIDTH SPACE and ZERO WIDTH NON-JOINER are
also accepted as valid identifier chracters without any restrictions.

    let ab = "ab"
    let a​b = "a + ZERO WIDTH SPACE + b"

    func xy() { print("xy") }
    func x‌y() { print("x + ZERO WIDTH NON-JOINER + y") }


### Timeline
 
These matters should be considered in a near timeframe (Swift 4). Identifier and
operator character sets are fundamental parts of Swift grammar, and changes are
inevitably source-breaking.


### Non-goals

The aim of this proposal is to rationalize the set of valid operator characters
and the set of valid identifier characters using Unicode **categories** and
specific Unicode **recommendations** where available. The smallest necessary
customizations are made to increase backwards compatibility, but no attempt is
made to expand Swift grammar or to "improve" Unicode. Specifically, the
following questions are potential subjects of separate study, either within the
purview of the Swift open source project or of the Unicode Consortium:

- **Expanding the set of valid operator or identifier characters.** For example,
`$` is not currently a valid operator in Swift, there are no current Unicode
recommendations regarding operators in programming languages, and `$` is not
enumerated among the list of "mathematical" characters in Unicode. Although is
possible for Swift to customize its implementation of Unicode recommendations to
add `$` as a valid operator, that is an expansion of Swift grammar distinct from
the task of rationalizing Swift symbology according to Unicode standards.
Therefore, this document neither proposes nor opposes its addition. For similar
reasons, this document refines the inclusion of emoji in identifiers based on
Unicode categories, but it neither proposes nor opposes the inclusion of
non-emoji pictographic symbols to the set of valid identifier characters.

- **Rectifying Unicode shortcomings.** Although it is possible to discover
shortcomings concerning particular characters in the current version of Unicode,
no attempt is made to preempt the Unicode standardization process by "patching"
such issues in the Swift grammar. For example, in the current version of
Unicode, ⁗ QUADRUPLE PRIME is not deemed to be "mathematical" (even though ‴
TRIPLE PRIME *is* deemed to be "mathematical"). Certainly, this issue would be
appropriate to report to Unicode and may well be corrected in a future revision
of the standard. However, as the Swift community is not congruent with the
community of experts that specialize in Unicode, there is no rational basis to
expect that Swift-only determinations of what Unicode "should have done"
(without vetting through Unicode's standardization processes) are likely to
result in a better outcome than the existing Unicode standard. Therefore, no
attempt is made to augment the Unicode derived category `Math` with ⁗ QUADRUPLE
PRIME in this proposal. Similarly, Unicode recommends certain normalization
forms for identifiers in code, which are proposed here for adoption by Swift,
but these normalization forms do not eliminate all possible combinations of
"confusable" characters. This proposal does not attempt to invent an ad-hoc
normalization form in an attempt to "improve" Unicode recommendations.

- **Implementing additional features.** Innovative ideas such as **mixfix**
operators are detailed below in *Future directions*. This proposal does not
attempt to introduce any such features.


## Precedent in other languages

**Haskell** distinguishes identifiers/operators by their [general
category](http://www.fileformat.info/info/unicode/category/index.htm) (for
instance, "any Unicode lowercase letter" or "any Unicode symbol or
punctuation"). Identifiers can start with any lowercase letter or `_`, and they
may contain any letter, digit, `'`, or `_`. This includes letters like δ and Я,
and digits like ٢.

- [Haskell Syntax Reference](https://www.haskell.org/onlinereport/syntax-iso.html)
- [Haskell Lexer](https://github.com/ghc/ghc/blob/714bebff44076061d0a719c4eda2cfd213b7ac3d/compiler/parser/Lexer.x#L1949-L1973)

**Scala** similarly allows letters, numbers, `$`, and `_` in identifiers,
distinguishing by general categories `Ll`, `Lu`, `Lt`, `Lo`, and `Nl`. Operator
characters include mathematical and other symbols (`Sm` and `So`) in addition to
certain ASCII characters.

- [Scala Lexical Syntax](http://www.scala-lang.org/files/archive/spec/2.11/01-lexical-syntax.html#lexical-syntax)

**ECMAScript 2015** uses `ID_Start` and `ID_Continue`, as well as
`Other_ID_Start` and `Other_ID_Continue`, for identifiers.

- [ECMAScript Specification: Names and Keywords](http://www.ecma-international.org/ecma-262/6.0/#sec-names-and-keywords)

**Python 3** uses `XID_Start` and `XID_Continue`.

- [The Python Language Reference: Identifiers and Keywords](https://docs.python.org/3/reference/lexical_analysis.html#grammar-token-identifier)
- [PEP 3131: Supporting Non-ASCII Identifiers](https://www.python.org/dev/peps/pep-3131/)


## Proposed solution

**Identifiers.** Adopt recommendations made in [UAX#31 Identifier and Pattern
Syntax](http://unicode.org/reports/tr31/), deriving the sets of valid identifier
characters from `ID_Start` and `ID_Continue`. Adopt specific customizations
principally to accommodate **emoji**. Consider two identifiers equivalent when
they produce the same normalized form under [Normalization Form C
(NFC)](http://unicode.org/reports/tr15/), as recommended in UAX#31 for
case-sensitive use cases.

 | Is an identifier | Is not an identifier
--- | --- | ---
**Shall be an identifier** | [120,617 code points](http://unicode.org/cldr/utility/list-unicodeset.jsp?a=%5B%5B%5Ba-zA-Z%0D%0A_%0D%0A%5Cu00A8%0D%0A%5Cu00AA%0D%0A%5Cu00AD%0D%0A%5Cu00AF%0D%0A%5Cu00B2-%5Cu00B5%0D%0A%5Cu00B7-%5Cu00BA%0D%0A%5Cu00BC-%5Cu00BE%0D%0A%5Cu00C0-%5Cu00D6%0D%0A%5Cu00D8-%5Cu00F6%0D%0A%5Cu00F8-%5Cu00FF%0D%0A%5Cu0100-%5Cu02FF%0D%0A%5Cu0370-%5Cu167F%0D%0A%5Cu1681-%5Cu180D%0D%0A%5Cu180F-%5Cu1DBF%0D%0A%5Cu1E00-%5Cu1FFF%0D%0A%5Cu200B-%5Cu200D%0D%0A%5Cu202A-%5Cu202E%0D%0A%5Cu203F-%5Cu2040%0D%0A%5Cu2054%0D%0A%5Cu2060-%5Cu206F%0D%0A%5Cu2070-%5Cu20CF%0D%0A%5Cu2100-%5Cu218F%0D%0A%5Cu2460-%5Cu24FF%0D%0A%5Cu2776-%5Cu2793%0D%0A%5Cu2C00-%5Cu2DFF%0D%0A%5Cu2E80-%5Cu2FFF%0D%0A%5Cu3004-%5Cu3007%0D%0A%5Cu3021-%5Cu302F%0D%0A%5Cu3031-%5Cu303F%0D%0A%5Cu3040-%5CuD7FF%0D%0A%5CuF900-%5CuFD3D%0D%0A%5CuFD40-%5CuFDCF%0D%0A%5CuFDF0-%5CuFE1F%0D%0A%5CuFE30-%5CuFE44%0D%0A%5CuFE47-%5CuFFFD%0D%0A%5CU00010000-%5CU0001FFFD%0D%0A%5CU00020000-%5CU0002FFFD%0D%0A%5CU00030000-%5CU0003FFFD%0D%0A%5CU00040000-%5CU0004FFFD%0D%0A%5CU00050000-%5CU0005FFFD%0D%0A%5CU00060000-%5CU0006FFFD%0D%0A%5CU00070000-%5CU0007FFFD%0D%0A%5CU00080000-%5CU0008FFFD%0D%0A%5CU00090000-%5CU0009FFFD%0D%0A%5CU000A0000-%5CU000AFFFD%0D%0A%5CU000B0000-%5CU000BFFFD%0D%0A%5CU000C0000-%5CU000CFFFD%0D%0A%5CU000D0000-%5CU000DFFFD%0D%0A%5CU000E0000-%5CU000EFFFD%5D%0D%0A%5B0-9%0D%0A%5Cu0300-%5Cu036F%0D%0A%5Cu1DC0-%5Cu1DFF%0D%0A%5Cu20D0-%5Cu20FF%0D%0A%5CuFE20-%5CuFE2F%5D%5D%0D%0A%26+%5B%5B%3AID_Continue%3A%5D%0D%0A_%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+-+%5B%3APattern_Syntax%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+-+%5B%3APattern_Syntax%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Flag_Sequences%3A%5D+%5B%3AEmoji_Keycap_Sequences%3A%5D+%5B%3AEmoji_Modifier_Sequences%3A%5D%5D%5D%5D&g=&i=) | [699 emoji](http://unicode.org/cldr/utility/list-unicodeset.jsp?a=%5B%5B%5B%3AID_Continue%3A%5D%0D%0A_%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+-+%5B%3APattern_Syntax%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+-+%5B%3APattern_Syntax%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Flag_Sequences%3A%5D+%5B%3AEmoji_Keycap_Sequences%3A%5D+%5B%3AEmoji_Modifier_Sequences%3A%5D%5D%5D%0D%0A-%5B%5Ba-zA-Z%0D%0A_%0D%0A%5Cu00A8%0D%0A%5Cu00AA%0D%0A%5Cu00AD%0D%0A%5Cu00AF%0D%0A%5Cu00B2-%5Cu00B5%0D%0A%5Cu00B7-%5Cu00BA%0D%0A%5Cu00BC-%5Cu00BE%0D%0A%5Cu00C0-%5Cu00D6%0D%0A%5Cu00D8-%5Cu00F6%0D%0A%5Cu00F8-%5Cu00FF%0D%0A%5Cu0100-%5Cu02FF%0D%0A%5Cu0370-%5Cu167F%0D%0A%5Cu1681-%5Cu180D%0D%0A%5Cu180F-%5Cu1DBF%0D%0A%5Cu1E00-%5Cu1FFF%0D%0A%5Cu200B-%5Cu200D%0D%0A%5Cu202A-%5Cu202E%0D%0A%5Cu203F-%5Cu2040%0D%0A%5Cu2054%0D%0A%5Cu2060-%5Cu206F%0D%0A%5Cu2070-%5Cu20CF%0D%0A%5Cu2100-%5Cu218F%0D%0A%5Cu2460-%5Cu24FF%0D%0A%5Cu2776-%5Cu2793%0D%0A%5Cu2C00-%5Cu2DFF%0D%0A%5Cu2E80-%5Cu2FFF%0D%0A%5Cu3004-%5Cu3007%0D%0A%5Cu3021-%5Cu302F%0D%0A%5Cu3031-%5Cu303F%0D%0A%5Cu3040-%5CuD7FF%0D%0A%5CuF900-%5CuFD3D%0D%0A%5CuFD40-%5CuFDCF%0D%0A%5CuFDF0-%5CuFE1F%0D%0A%5CuFE30-%5CuFE44%0D%0A%5CuFE47-%5CuFFFD%0D%0A%5CU00010000-%5CU0001FFFD%0D%0A%5CU00020000-%5CU0002FFFD%0D%0A%5CU00030000-%5CU0003FFFD%0D%0A%5CU00040000-%5CU0004FFFD%0D%0A%5CU00050000-%5CU0005FFFD%0D%0A%5CU00060000-%5CU0006FFFD%0D%0A%5CU00070000-%5CU0007FFFD%0D%0A%5CU00080000-%5CU0008FFFD%0D%0A%5CU00090000-%5CU0009FFFD%0D%0A%5CU000A0000-%5CU000AFFFD%0D%0A%5CU000B0000-%5CU000BFFFD%0D%0A%5CU000C0000-%5CU000CFFFD%0D%0A%5CU000D0000-%5CU000DFFFD%0D%0A%5CU000E0000-%5CU000EFFFD%5D%0D%0A%5B0-9%0D%0A%5Cu0300-%5Cu036F%0D%0A%5Cu1DC0-%5Cu1DFF%0D%0A%5Cu20D0-%5Cu20FF%0D%0A%5CuFE20-%5CuFE2F%5D%5D%5D&g=&i=)
**Shall not be an identifier** | [846,137 unassigned;<br>4,929 other code points](http://unicode.org/cldr/utility/list-unicodeset.jsp?a=%5B%5B%5Ba-zA-Z%0D%0A_%0D%0A%5Cu00A8%0D%0A%5Cu00AA%0D%0A%5Cu00AD%0D%0A%5Cu00AF%0D%0A%5Cu00B2-%5Cu00B5%0D%0A%5Cu00B7-%5Cu00BA%0D%0A%5Cu00BC-%5Cu00BE%0D%0A%5Cu00C0-%5Cu00D6%0D%0A%5Cu00D8-%5Cu00F6%0D%0A%5Cu00F8-%5Cu00FF%0D%0A%5Cu0100-%5Cu02FF%0D%0A%5Cu0370-%5Cu167F%0D%0A%5Cu1681-%5Cu180D%0D%0A%5Cu180F-%5Cu1DBF%0D%0A%5Cu1E00-%5Cu1FFF%0D%0A%5Cu200B-%5Cu200D%0D%0A%5Cu202A-%5Cu202E%0D%0A%5Cu203F-%5Cu2040%0D%0A%5Cu2054%0D%0A%5Cu2060-%5Cu206F%0D%0A%5Cu2070-%5Cu20CF%0D%0A%5Cu2100-%5Cu218F%0D%0A%5Cu2460-%5Cu24FF%0D%0A%5Cu2776-%5Cu2793%0D%0A%5Cu2C00-%5Cu2DFF%0D%0A%5Cu2E80-%5Cu2FFF%0D%0A%5Cu3004-%5Cu3007%0D%0A%5Cu3021-%5Cu302F%0D%0A%5Cu3031-%5Cu303F%0D%0A%5Cu3040-%5CuD7FF%0D%0A%5CuF900-%5CuFD3D%0D%0A%5CuFD40-%5CuFDCF%0D%0A%5CuFDF0-%5CuFE1F%0D%0A%5CuFE30-%5CuFE44%0D%0A%5CuFE47-%5CuFFFD%0D%0A%5CU00010000-%5CU0001FFFD%0D%0A%5CU00020000-%5CU0002FFFD%0D%0A%5CU00030000-%5CU0003FFFD%0D%0A%5CU00040000-%5CU0004FFFD%0D%0A%5CU00050000-%5CU0005FFFD%0D%0A%5CU00060000-%5CU0006FFFD%0D%0A%5CU00070000-%5CU0007FFFD%0D%0A%5CU00080000-%5CU0008FFFD%0D%0A%5CU00090000-%5CU0009FFFD%0D%0A%5CU000A0000-%5CU000AFFFD%0D%0A%5CU000B0000-%5CU000BFFFD%0D%0A%5CU000C0000-%5CU000CFFFD%0D%0A%5CU000D0000-%5CU000DFFFD%0D%0A%5CU000E0000-%5CU000EFFFD%5D%0D%0A%5B0-9%0D%0A%5Cu0300-%5Cu036F%0D%0A%5Cu1DC0-%5Cu1DFF%0D%0A%5Cu20D0-%5Cu20FF%0D%0A%5CuFE20-%5CuFE2F%5D%5D%0D%0A-%5B%5B%3AID_Continue%3A%5D%0D%0A_%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+-+%5B%3APattern_Syntax%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+-+%5B%3APattern_Syntax%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Flag_Sequences%3A%5D+%5B%3AEmoji_Keycap_Sequences%3A%5D+%5B%3AEmoji_Modifier_Sequences%3A%5D%5D%5D%5D&g=&i=) | *All other code points*

**Operators.** No Unicode recommendation currently exists on the topic of
"operator identifiers," although work is ongoing as part of a future update to
UAX#31. The aim of the proposed definition presented in this document is to
identify, using Unicode categories, a reasonable set of operators that (a) may
be in current use in Swift code; and (b) are likely to be included in future
versions of UAX#31. It is not intended to be a final judgment on all code points
that should ever be valid in Swift operators, for which it is proposed that
Swift await the recommendations of the Unicode Consortium.

Therefore, adopt an approach to define the set of valid operator characters
based primarily on the Unicode categories `Math` and `Pattern_Syntax` (an
approach analogous to that which is used to define `ID_Start` and `ID_Continue`
in Unicode recommendations), informed by [UAX#25 Unicode Support for
Mathematics](http://www.unicode.org/reports/tr25/). Augment the set of valid
operator characters with a number of currently valid Swift operator characters
to increase backward compatibility. Consider two operators equivalent when they
produce the same normalized form under [Normalization Form KC
(NFKC)](http://unicode.org/reports/tr15/), as recommended in UAX#31 for
case-insensitive use cases. Fullwidth variants such as FULLWIDTH HYPHEN-MINUS
are equivalent to their non-fullwidth counterparts after normalization under
NFKC (but not NFC).

 | Is an operator | Is not an operator
--- | --- | ---
**Shall be an operator** | [986 code points](http://unicode.org/cldr/utility/list-unicodeset.jsp?a=[%5b%5b%3aPattern%5fSyntax%3a%5d%20%26%20%5b%3aMath%3a%5d%0d%0a%2d%20%5b%3aBlock%3dGeometric%20Shapes%3a%5d%0d%0a%2d%20%5b%3aBlock%3dMiscellaneous%20Symbols%3a%5d%0d%0a%2d%20%5b%3aBlock%3dMiscellaneous%20Technical%3a%5d%0d%0a%5b%21%20%25%20%5c%26%20%2a%20%5c%2d%20%2f%20%3f%20%5c%5c%20%5c%5e%20¡%20¦%20§%20°%20¶%20¿%20†%20‡%20•%20‰%20‱%20※%20‽%20⁂%20⁅%20⁆%20⁊%20⁋%20⁌%20⁍%20⁎%20⁑%5d%5d%26%5b%5b%0d%0a%5b%2f%20%5c%2d%20%2b%20%21%20%2a%20%25%20%3c%2d%3e%20%5c%26%20%7c%20%5c%5e%20%7e%20%3f%5d%0d%0aU%2b00A1%2dU%2b00A7%0d%0aU%2b00A9%20U%2b00AB%0d%0aU%2b00AC%20U%2b00AE%0d%0aU%2b00B0%2dU%2b00B1%20U%2b00B6%20U%2b00BB%20U%2b00BF%20U%2b00D7%20U%2b00F7%0d%0aU%2b2016%2dU%2b2017%20U%2b2020%2dU%2b2027%0d%0aU%2b2030%2dU%2b203E%0d%0aU%2b2041%2dU%2b2053%0d%0aU%2b2055%2dU%2b205E%0d%0aU%2b2190%2dU%2b23FF%0d%0aU%2b2500%2dU%2b2775%0d%0aU%2b2794%2dU%2b2BFF%0d%0aU%2b2E00%2dU%2b2E7F%0d%0aU%2b3001%2dU%2b3003%0d%0aU%2b3008%2dU%2b3030%0d%0a%5d%0d%0a%5b%0d%0aU%2b0300%2dU%2b036F%0d%0aU%2b1DC0%2dU%2b1DFF%0d%0aU%2b20D0%2dU%2b20FF%0d%0aU%2bFE00%2dU%2bFE0F%0d%0aU%2bFE20%2dU%2bFE2F%0d%0aU%2bE0100%2dU%2bE01EF%0d%0a%5d%5d]) | `\`
**Shall not be an operator** | [130 unassigned;<br>2,024 other code points](http://unicode.org/cldr/utility/list-unicodeset.jsp?a=[%5b%5b%0d%0a%5b%2f%20%5c%2d%20%2b%20%21%20%2a%20%25%20%3c%2d%3e%20%5c%26%20%7c%20%5c%5e%20%7e%20%3f%5d%0d%0aU%2b00A1%2dU%2b00A7%0d%0aU%2b00A9%20U%2b00AB%0d%0aU%2b00AC%20U%2b00AE%0d%0aU%2b00B0%2dU%2b00B1%20U%2b00B6%20U%2b00BB%20U%2b00BF%20U%2b00D7%20U%2b00F7%0d%0aU%2b2016%2dU%2b2017%20U%2b2020%2dU%2b2027%0d%0aU%2b2030%2dU%2b203E%0d%0aU%2b2041%2dU%2b2053%0d%0aU%2b2055%2dU%2b205E%0d%0aU%2b2190%2dU%2b23FF%0d%0aU%2b2500%2dU%2b2775%0d%0aU%2b2794%2dU%2b2BFF%0d%0aU%2b2E00%2dU%2b2E7F%0d%0aU%2b3001%2dU%2b3003%0d%0aU%2b3008%2dU%2b3030%0d%0a%5d%0d%0a%5b%0d%0aU%2b0300%2dU%2b036F%0d%0aU%2b1DC0%2dU%2b1DFF%0d%0aU%2b20D0%2dU%2b20FF%0d%0aU%2bFE00%2dU%2bFE0F%0d%0aU%2bFE20%2dU%2bFE2F%0d%0aU%2bE0100%2dU%2bE01EF%0d%0a%5d%5d-%5b%5b%3aPattern%5fSyntax%3a%5d%20%26%20%5b%3aMath%3a%5d%0d%0a%2d%20%5b%3aBlock%3dGeometric%20Shapes%3a%5d%0d%0a%2d%20%5b%3aBlock%3dMiscellaneous%20Symbols%3a%5d%0d%0a%2d%20%5b%3aBlock%3dMiscellaneous%20Technical%3a%5d%0d%0a%5b%21%20%25%20%5c%26%20%2a%20%5c%2d%20%2f%20%3f%20%5c%5c%20%5c%5e%20¡%20¦%20§%20°%20¶%20¿%20†%20‡%20•%20‰%20‱%20※%20‽%20⁂%20⁅%20⁆%20⁊%20⁋%20⁌%20⁍%20⁎%20⁑%5d%5d]) | *All other code points*

**Dots.** Adopt a rule to allow dots to appear in operators at any location, but
only in runs of two or more. (Currently, dots must be leading.)


## Detailed design

### Identifiers

Swift identifier characters shall [conform to
UAX#31](http://unicode.org/reports/tr31/#Conformance) as follows:

- [**UAX31-C1.**](http://unicode.org/reports/tr31/#C1) The conformance described
  herein refers to the Unicode 9.0.0 version of UAX#31.

- [**UAX31-C2.**](http://unicode.org/reports/tr31/#C2) Swift shall observe the
  following requirements:

  - [**UAX31-R1.**](http://unicode.org/reports/tr31/#R1) Swift shall augment the
    definition of "Default Identifiers" with the following **profiles**:

    1. `ID_Start` and `ID_Continue` shall be used for `Start` and `Continue`,
       replacing `XID_Start` and `XID_Continue`. This **excludes** characters in
       `Other_ID_Start` and `Other_ID_Continue`.

    2. _ 005F LOW LINE shall additionally be allowed as a `Start` character.
    
    3. Certain emoji shall additionally be allowed as `Start` characters. A
       detailed design for emoji permitted in identifiers is given below.

    4. [**UAX31-R1a.**](http://unicode.org/reports/tr31/#R1a) The join-control
       characters ZWJ and ZWNJ are strictly limited to the special cases A1, A2,
       and B described in UAX#31.

  - [**UAX31-R4.**](http://unicode.org/reports/tr31/#R4) Swift shall consider
    two identifiers equivalent when they produce the same normalized form under
    [Normalization Form C (NFC)](http://unicode.org/reports/tr15/), as
    recommended in UAX#31 for **case-sensitive** use cases.

#### Grammar changes

    identifier-head → [:ID_Start:]
    identifier-head → _
    identifier-head → identifier-emoji
    identifier-character → identifier-head
    identifier-character → [:ID_Continue:]

### Operators

Swift operator characters shall be determined as follows:

- Valid operator characters shall consist of `Pattern_Syntax` code points with a
derived property `Math`. However, the following blocks are excluded: Geometric
Shapes, Miscellaneous Symbols, and Miscellaneous Technical. In UnicodeSet
notation:

  ```
  [:Pattern_Syntax:] & [:Math:]
  - [:Block=Geometric Shapes:]
  - [:Block=Miscellaneous Symbols:]
  - [:Block=Miscellaneous Technical:]
  ```

  `Math` captures a fuller set of operators than is possible using `Sm`, and we
avoid the inclusion of characters in `So` that are clearly not "operator-like"
(such as Braille). `Math` code points in the excluded blocks include sign parts
such as ⎲ SUMMATION TOP and tenuously "operator-like" code points such as ♠️
BLACK SPADE SUIT.

- The set of valid operator characters shall be augmented with the following
ASCII characters: `!`, `%`, `&`, `*`, `-`, `/`, `?`, `\`, `^`. These ASCII
characters are required by the Swift standard library and/or considered "weakly
mathematical" in [UAX#25](http://www.unicode.org/reports/tr25/).

- For increased compatibility with Swift 3, the set of valid operator characters
shall be augmented with the following Latin-1 Supplement characters: `¡`, `¦`,
`§`, `°`, `¶`, `¿`. For the same reason, augment the set of valid operator
characters with the following General Punctuation characters: † DAGGER, ‡ DOUBLE
DAGGER, • BULLET, ‰ PER MILLE SIGN, ‱ PER TEN THOUSAND SIGN, ※ REFERENCE MARK, ‽
INTERROBANG, ⁂ ASTERISM, ⁅ LEFT SQUARE BRACKET WITH QUILL, ⁆ RIGHT SQUARE
BRACKET WITH QUILL, ⁊ TIRONIAN SIGN ET, ⁋ REVERSED PILCROW SIGN, ⁌ BLACK
LEFTWARDS BULLET, ⁍ BLACK RIGHTWARDS BULLET, ⁎ LOW ASTERISK, ⁑ TWO ASTERISKS
ALIGNED VERTICALLY.

- Swift shall consider two operators equivalent when they produce the same
normalized form under [Normalization Form KC
(NFKC)](http://unicode.org/reports/tr15/), as recommended in UAX#31 for
*case-insensitive* use cases. Crucially, fullwidth variants such as FULLWIDTH
HYPHEN-MINUS are equivalent to their non-fullwidth counterparts after
normalization under NFKC (but not NFC).

- Certain strongly mathematical arrows now have an _alternative_ emoji
presentation, and future versions of Unicode may add such an emoji presentation
to any Swift operator character. Some but not all "environments" or applications
(for instance, Safari but not TextWrangler) display the alternative emoji
presentation at all times, and such discrepancies between applications are
explicitly permitted by Unicode recommendations (see dicussion in _Emoji_).
However, it would be highly unusual to define the set of valid operator
characters based on an essentially arbitrary criterion as to whether an
alternative emoji presentation is retroactively assigned to a code point, and
codifying how IDEs display Unicode characters in Swift files is outside the
scope of this proposal. Therefore, valid operator characters are defined without
regard to the presence or absence of an alternative emoji presentation, and
U+FE0E VARIATION SELECTOR-15 (text presentation selector) is _optionally_
permitted to follow an operator character that has an alternative emoji
presentation. Note that variation selectors are discarded by normalization.

[These revised rules](http://unicode.org/cldr/utility/list-unicodeset.jsp?a=%5B%3APattern_Syntax%3A%5D+%26+%5B%3AMath%3A%5D%0D%0A-+%5B%3ABlock%3DGeometric+Shapes%3A%5D%0D%0A-+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%0D%0A-+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%0D%0A%5B%21+%25+%5C%26+*+%5C-+%2F+%3F+%5C%5C+%5C%5E+¡+¦+§+°+¶+¿+†+‡+•+‰+‱+※+‽+⁂+⁅+⁆+⁊+⁋+⁌+⁍+⁎+⁑%5D&g=&i=)
produce a set of 987 code points for operator characters. Since `ID_Start` is
derived in part by exclusion of `Pattern_Syntax` code points, it is assured that
operator and identifier characters do not overlap (although this assurance does
not extend to emoji, which require additional design as detailed below).

All current restrictions on reserved tokens and operators remain. Swift reserves
`=`, `->`, `//`, `/*`, `*/`, `.`, `?`, prefix `<`, prefix `&`,  postfix `>`, and
postfix `!`.

#### Dots

Swift's existing rule for dots in operators is:

> If an operator doesn’t begin with a dot, it can’t contain a dot elsewhere.

This proposal modifies the rule to:

> Dots may only appear in operators in sequences of two or more.

Incorporating the "two-dot rule" offers the following benefits:

* It avoids lexical complications arising from lone `.`.

* The approach is conservative, erring on the side of overly restrictive.
  Dropping the rule in future (and thereby allowing single dots) may be
  possible.

* It does not require special cases for existing infix dot operators in the
  standard library, `...` (closed range) and `..<` (half-open range). It leaves
  open the possibility of adding analogous half-open and fully-open range
  operators `<..` and `<..<`. 

Finally, this proposal *reserves* the `..` operator for a possible "method
cascade" syntax in the future [as supported by
Dart](http://news.dartlang.org/2012/02/method-cascades-in-dart-posted-by-gilad.html).

#### Grammar changes

    operator → operator-head operator-characters[opt]
    
    operator-head → [[:Pattern_Syntax:] & [:Math:] - [:Emoji:] - [:Block=Geometric Shapes:] - [:Block=Miscellaneous Symbols:] - [:Block=Miscellaneous Technical:]]
    operator-head → [[:Pattern_Syntax:] & [:Math:] & [:Emoji:] - [:Block=Geometric Shapes:] - [:Block=Miscellaneous Symbols:] - [:Block=Miscellaneous Technical:]] U+FE0E[opt]
    operator-head → ! | % | & | * | - | / | ? | \ | ^ | ¡ | ¦ | § | ° | ¶ | ¿
    operator-head → † | ‡ | • | ‰ | ‱ | ※ | ‽ | ⁂ | ⁅ | ⁆ | ⁊ | ⁋ | ⁌ | ⁍ | ⁎ | ⁑
    operator-head → operator-dot operator-dots
    operator-character → operator-head
    operator-characters → operator-character operator-characters[opt]

    operator-dot → .
    operator-dots → operator-dot operator-dots[opt]


### Emoji

The inclusion of emoji among valid identifier characters, though highly desired,
presents significant challenges:

- Emoji characters are not displayed uniformly across different platforms.

- Whether any particular character is presented as emoji or text depends on a
matrix of considerations, including "environment" (e.g., Safari vs. XCode),
presence or absence of a variant selector, and whether the character itself
defaults to "emoji presentation" or "text presentation." This behavior is
specifically documented in [Unicode
recommendations](http://unicode.org/reports/tr51/#Presentation_Style).

- Some emoji not classified as `Math` depict operators: ❗️❓➕➖➗✖️. [A Unicode
chart](http://unicode.org/emoji/charts/emoji-ordering.html) provides additional
information by dividing emoji according to "rough categories," but it warns that
these categories "may change at any time, and should not be used in production."

- Full emoji support would require allowing identifiers to contain zero-width
joiner sequences that UAX#31 would forbid. Some normalization scheme would have
to be devised to account for Unicode recommendations that `👩‍❤️‍👨` (U+1F469
U+200D U+2764 U+FE0F U+200D U+1F468) can be displayed as either `💑` (U+1F491)
or, as a fallback, `👩❤️👨` (U+1F469 U+2764 U+FE0F U+1F468).

For maximum consistency across platforms, valid emoji in Swift identifiers shall
be determined using the following rules:

- Emoji shall include code points with default emoji presentation (as opposed to
text presentation), minus `Emoji_Defectives` and `ID_Continue`. Exclude
`Pattern_Syntax` code points unless they are in the following blocks:
Miscellaneous Symbols, Miscellaneous Technical.

- Emoji shall include `Emoji` code points with default text presentation *when
immediately followed by U+FE0F VARIATION SELECTOR-16 (emoji presentation
selector)*, minus `Emoji_Defectives` and `ID_Continue`. Again, exclude
`Pattern_Syntax` code points unless they are in the following blocks:
Miscellaneous Symbols, Miscellaneous Technical. (Note that the emoji picker on
Apple platforms--and, possibly, other platforms--automatically inserts U+FE0F
VARIATION SELECTOR-16 when a user selects such code points; for instance,
selecting ❤️ inserts U+2764 U+FE0F. Therefore, it is important that the
invisible U+FE0F be permitted strictly in this use case. Note also that
variation selectors are discarded by normalization.)

- Emoji shall include `Emoji_Flag_Sequences`, `Emoji_Keycap_Sequences`, and (to
the extent not already included) `Emoji_Modifier_Sequences`.

[These revised rules](http://unicode.org/cldr/utility/list-unicodeset.jsp?a=%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+-+%5B%3APattern_Syntax%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%5D%0D%0A%5B%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+-+%5B%3APattern_Syntax%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Symbols%3A%5D%5D%0D%0A%5B%5B%3AEmoji%3A%5D+-+%5B%3AEmoji_Defectives%3A%5D+-+%5B%3AEmoji_Presentation%3A%5D+-+%5B%3AID_Continue%3A%5D+%26+%5B%3APattern_Syntax%3A%5D+%26+%5B%3ABlock%3DMiscellaneous+Technical%3A%5D%5D%0D%0A%5B%3AEmoji_Flag_Sequences%3A%5D%0D%0A%5B%3AEmoji_Keycap_Sequences%3A%5D%0D%0A%5B%3AEmoji_Modifier_Sequences%3A%5D&g=&i=)
produce a set of 1,625 code points or sequences, of which 98 are currently
categorized as operator characters.

#### Grammar changes

```
identifier-emoji → [[:Emoji_Presentation:] - [:Emoji_Defectives:] - [:ID_Continue:] - [:Pattern_Syntax:]]
identifier-emoji → [[:Emoji_Presentation:] - [:Emoji_Defectives:] - [:ID_Continue:] & [:Pattern_Syntax:] & [:Block=Miscellaneous Symbols:]]
identifier-emoji → [[:Emoji_Presentation:] - [:Emoji_Defectives:] - [:ID_Continue:] & [:Pattern_Syntax:] & [:Block=Miscellaneous Technical:]]
identifier-emoji → [[:Emoji:] - [:Emoji_Defectives:] - [:Emoji_Presentation:] - [:ID_Continue:] - [:Pattern_Syntax:]] U+FE0F
identifier-emoji → [[:Emoji:] - [:Emoji_Defectives:] - [:Emoji_Presentation:] - [:ID_Continue:] & [:Pattern_Syntax:] & [:Block=Miscellaneous Symbols:]] U+FE0F
identifier-emoji → [[:Emoji:] - [:Emoji_Defectives:] - [:Emoji_Presentation:] - [:ID_Continue:] & [:Pattern_Syntax:] & [:Block=Miscellaneous Technical:]] U+FE0F
identifier-emoji → [[:Emoji_Flag_Sequences:] [:Emoji_Keycap_Sequences:] [:Emoji_Modifier_Sequences:]]
```

## Source compatibility

This change is source-breaking where developers have incorporated certain emoji
in identifiers or certain non-ASCII characters in operators. This is unlikely to
be a significant breakage for the majority of Swift code. Diagnostics for
invalid characters are already produced today. We can improve them easily if
needed.

Maintaining source compatibility for Swift 3 should be easy: keep the old
parsing and identifier lookup code.

## Effect on ABI stability

This proposal does not affect the ABI format itself. Normalization of Unicode
identifiers would affect the ABI of compiled modules. The standard library will
not be affected; it uses ASCII symbols with no combining characters.

## Effect on API resilience

This proposal doesn't affect API resilience.

## Alternatives considered

- Use NFKC instead of NFC for identifiers. The decision to use NFC is based on
UAX#31, which states:

  > Generally if the programming language has case-sensitive identifiers, then
  > Normalization Form C is appropriate; whereas, if the programming language
  > has case-insensitive identifiers, then Normalization Form KC is more
  > appropriate.

- Eliminate emoji from identifiers and restrict operator characters to a limited
number of ASCII code points. This approach would be simpler, but feedback on
Swift-Evolution has been overwhelmingly against such a change.

- Hand-pick a set of "operator-like" characters to include. The proposal authors
tried this painstaking approach and came up with a relatively agreeable set of
about [650 code points](http://unicode.org/cldr/utility/list-unicodeset.jsp?a=%5B%21%5C%24%25%5C%26*%2B%5C-%2F%3C%3D%3E%3F%5C%5E%7C~%0D%0A%0D%0A%5Cu00AC%0D%0A%5Cu00B1%0D%0A%5Cu00B7%0D%0A%5Cu00D7%0D%0A%5Cu00F7%0D%0A%0D%0A%5Cu2208-%5Cu220D%0D%0A%5Cu220F-%5Cu2211%0D%0A%5Cu22C0-%5Cu22C3%0D%0A%5Cu2212-%5Cu221D%0D%0A%5Cu2238%0D%0A%5Cu223A%0D%0A%5Cu2240%0D%0A%5Cu228C-%5Cu228E%0D%0A%5Cu2293-%5Cu22A3%0D%0A%5Cu22BA-%5Cu22BD%0D%0A%5Cu22C4-%5Cu22C7%0D%0A%5Cu22C9-%5Cu22CC%0D%0A%5Cu22D2-%5Cu22D3%0D%0A%5Cu2223-%5Cu222A%0D%0A%5Cu2236-%5Cu2237%0D%0A%5Cu2239%0D%0A%5Cu223B-%5Cu223E%0D%0A%5Cu2241-%5Cu228B%0D%0A%5Cu228F-%5Cu2292%0D%0A%5Cu22A6-%5Cu22B9%0D%0A%5Cu22C8%0D%0A%5Cu22CD%0D%0A%5Cu22D0-%5Cu22D1%0D%0A%5Cu22D4-%5Cu22FF%0D%0A%5Cu22CE-%5Cu22CF%0D%0A%0D%0A%5Cu2A00-%5Cu2AFF%0D%0A%0D%0A%5Cu27C2%0D%0A%5Cu27C3%0D%0A%5Cu27C4%0D%0A%5Cu27C7%0D%0A%5Cu27C8%0D%0A%5Cu27C9%0D%0A%5Cu27CA%0D%0A%5Cu27CE-%5Cu27D7%0D%0A%5Cu27DA-%5Cu27DF%0D%0A%5Cu27E0-%5Cu27E5%0D%0A%0D%0A%5Cu29B5-%5Cu29C3%0D%0A%5Cu29C4-%5Cu29C9%0D%0A%5Cu29CA-%5Cu29D0%0D%0A%5Cu29D1-%5Cu29D7%0D%0A%5Cu29DF%0D%0A%5Cu29E1%0D%0A%5Cu29E2%0D%0A%5Cu29E3-%5Cu29E6%0D%0A%5Cu29FA%0D%0A%5Cu29FB%0D%0A%0D%0A%5Cu2308-%5Cu230B%0D%0A%5Cu2336-%5Cu237A%0D%0A%5Cu2395%5D).
Such a list can carefully avoid idiosyncrasies in the Unicode standard. However,
a character-by-character inventory is unlikely to converge on consensus, as
likely to introduce unintended Swift-specific idiosyncrasies as it is to avoid
Unicode shortcomings, and inconsistent with the Unicode method of deriving such
lists using categories.

- Continue to allow single `.` in operators, perhaps even expanding the original
rule to allow them anywhere (even if the operator does not begin with `.`).

  This would allow a wider variety of custom operators (for some interesting
possibilities, see the operators in Haskell's
[Lens](https://github.com/ekmett/lens/wiki/Operators) package). However, there
are a handful of potential complications:

  - Combining prefix or postfix operators with member access: `foo*.bar` would
need to be parsed as `foo *. bar` rather than `(foo*).bar`. Parentheses could be
required to disambiguate.

  - Combining infix operators with contextual members: `foo*.bar` would need to
be parsed as `foo *. bar` rather than `foo * (.bar)`. Whitespace or parentheses
could be required to disambiguate.

  - Hypothetically, if operators were accessible as members such as
`MyNumber.+`, allowing operators with single `.`s would require escaping
operator names (perhaps with backticks, such as `` MyNumber.`+` ``).

  This would also require operators of the form `[!?]*\.` (for example `.` `?.`
`!.`  `!!.`) to be reserved, to prevent users from defining custom operators
that conflict with member access and optional chaining.

  We believe that requiring dots to appear in groups of at least two, while in
some ways more restrictive, will prevent a significant amount of future pain,
and does not require special-case considerations such as the above.


## Future directions

While not within the scope of this proposal, the following considerations may
provide useful context for the proposed changes. We encourage the community to
pick up these topics when the time is right.

- **Introduce a syntax for method cascades.** The Dart language supports [method
cascades](http://news.dartlang.org/2012/02/method-cascades-in-dart-posted-by-
gilad.html), whereby multiple methods can be called on an object within one
expression: `foo..bar()..baz()` effectively performs `foo.bar(); foo.baz()`.
This syntax can also be used with assignments and subscripts. Such a feature
might be very useful in Swift; this proposal reserves the `..` operator so that
it may be added in the future.

- **Introduce "mixfix" operator declarations.** Mixfix operators are based on
pattern matching and would allow more than two operands. For example, the
ternary operator `? :` can be defined as a mixfix operator with three "holes":
`_ ? _ : _`. Subscripts might be subsumed by mixfix declarations such as `_ [ _
]`. Some holes could be made `@autoclosure`, and there might even be holes whose
argument is represented as an AST, rather than a value or thunk, supporting
advanced metaprogramming (for instance, F#'s [code
quotations](https://docs.microsoft.com/en-us/dotnet/articles/fsharp/language-
reference/code-quotations)). Should mixfix operators become supported, it would
be sensible to add brackets to the set of valid operator characters.

- **Diminish or remove the lexical distinction between operators and
identifiers.** If precedence and fixity applied to traditional identifiers as
well as operators, it would be possible to incorporate ASCII equivalents for
standard operators (e.g. `and` for `&&`, to allow `A and B`). If additionally
combined with mixfix operator support, this might enable powerful DSLs (for
instance, C#'s [LINQ](https://en.wikipedia.org/wiki/Language_Integrated_Query)).
