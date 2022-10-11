 Single Quoted Character Literals

 * Proposal: [SE-XXXX](0000-single-quoted-character-literals.md)
 * Authors: [Kelvin Ma (“Taylor Swift”)](https://github.com/kelvin13), [John Holdsworth](https://github.com/johnno1962)
 * Review manager: [Ben Cohen](https://github.com/airspeedswift)
 * Status: **Pending third review** 
 * Implementation: [https://github.com/apple/swift/pull/61477)
 * Threads: [1](https://forums.swift.org/t/prepitch-character-integer-literals/10442) [2](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188)

 ## Introduction

 Swift emphasizes a unicode-correct definition of what constitutes a `Character`, but unlike most common programming languages, Swift does not have a dedicated syntax for `Character` literals. Instead, three overlapping “ExpressibleBy” protocols and Swift’s type inference come together to produce a confusing syntax where a double quoted string literal can take the role of a `String`, `Character`, or `Unicode.Scalar` value depending on its content, and the expression context. 

 This proposal assigns a dedicated syntax for `Character` and `Unicode.Scalar` values, using single quote (`'`) delimiters. This change solely affects the type inference of single literals, and does not seek to change the current compiler validation behaviour for these constructs.

 ## Motivation

 A pain point of using characters in Swift is they lack a first-class literal syntax. Users have to manually coerce string literals to a `Character` or `Unicode.Scalar` type using `as Character` or `as Unicode.Scalar`, respectively. Having the collection share the same syntax as its element also harms code clarity and makes it difficult to tell if a double-quoted literal is being used as a string or a character in some cases.

 While the motivation for distinguishing between `String` and `Character` literals mostly consists of ergonomic and readability concerns, doing so would also bring Swift in line with other popular languages which do make this syntactic distinction, and facilitates a subsequent effort to improve support for low-level `UInt8`/`Int8` buffer processing tasks common in parsers and codecs.

 ## Proposed solution

 We propose to adopt the `'x'` as an alternative syntax for all textual literal types up to and including `ExtendedGraphemeClusterLiteral`, but not including `StringLiteral`. These literals will be used to express `Character`, `Unicode.Scalar`, and types like `UTF16.CodeUnit` in the standard library. These literals would have a default type of `Character`, as `Character` is the preferred element type of `String`. In addition where the character literal is a single ASCII code point conversions to an integer value are made available using a new `ExpressibleByASCIILiteral` conformance.

 Use of single quotes for character/scalar literals is highly precedented in other languages, including C, Objective-C, C++, Java, Elm, and Rust, although different languages have slightly differing ideas about what a “character” is. We choose to use the single quote syntax specifically because it reinforces the notion that strings and character values are different: the former is a sequence, the later is an element (though a single element can itself be a `String`). Character types also don’t support string literal interpolation and can be obtimized, which is another reason to move away from double quotes.
 
 Advantages for a developer to migrate to the single quote distinction:
 
  * Differentiate in the source when a literal is intended to be a Character or UnicodeScalar
  * Distinct default type of `Character` making available that type's methods and properties.
  * Compile time best-effort check that the literal is in fact a single Character/Unicode grapheme.

 Improvements to the new implementation over that previously reviewed:
 
  * SingleQuoted literals have their own new `ExpressibleBy` marker protocols preventing source breaking changes to the use of double quoted literals in existing source.
  * Distinct protocol for ASCII literals further localising the more contentious integer conversions.
 
 ### Example usage
 
 Some expressions using single quoted literal syntax, their value and their type:

```Swift
	'€' // >€< Character
	'€' as String // >€< String
	"1"+"1" // >11< String
	"1"+'€' // >1€< String
	'1'+'1' as String // >11< String
	'1'+'1' as Int // >98< Int
	Int("0123") as Any // >Optional(123)< Optional<Int>
	Int('€') as Any // >nil< Optional<Int>
	Int('3') // >51< Int
	'a'+1 //  >98< Int
	['a', 'b'] as [Int8], // >[97, 98]< Array<Int8>
	'a' * 'b' as Int8, // overflows at compilation
	'b' - 'a' + 10 // >11< Int
	"123".firstIndex(of: '2') as Any 
		// >Optional(Swift.String.Index(_rawBits: 65799))< Optional<Index>
	'👩🏼‍🚀'.asciiValue as Any /// >nil< Optional<UInt8>
	('😎' as UnicodeScalar).value // >128526< UInt32
	('👩🏼‍🚀' as UnicodeScalar).value // compilation error
```
 ### Single quotes in Swift, a historical perspective

 In Swift 1.0, single quotes were reserved for some yet-to-be determined syntactical purpose. Since then, pretty much all of the things that might have used single quotes have already found homes in other parts of the Swift syntactical space:

 - syntax for [multi-line string literals](https://github.com/apple/swift-evolution/blob/master/proposals/0168-multi-line-string-literals.md) uses triple quotes (`"""`)

 - string interpolation syntax uses standard double quote syntax. 

 - raw-mode string literals settled into the `#""#` syntax. 

 - In current discussions around [regex literals](https://forums.swift.org/t/string-update/7398/6), most people seem to prefer slashes (`/`) or `#//#` syntax.

 Given that, and the desire for lightweight syntax for single character syntax, and the precedent in other languages for characters, it is natural to use single quotes for this purpose.

## Detailed design

 This is a change that is internal to the Swift compiler and does not affect how these literal values are represented at runtime and hence does not affect the ABI. Single quoted literals are largely identical to double quoted `String` literals, supporting the same existing escape syntax, and they reuse the same code in the lexer which happened to already support parsing single quoted syntax. However, the compiler would in addition perform a best-effort attempt at validating that they contain a single extended grapheme cluster at compile time, as it currently does when an `as Character` type coercion annotation is present. Validation behaviour for `Unicode.Scalar` literals will be unaffected. 
 
```Swift
// Modified String literal protocol hierarchy:
ExpressibleByStringLiteral
  ↳ ExpressibleByExtendedGraphemeClusterLiteral
      ↳ ExpressibleByUnicodeScalarLiteral
          ↳ @_marker ExpressibleBySingleQuotedLiteral
              ↳ @_marker ExpressibleByASCIILiteral
```
This is realised by introducing two new `ExpressibleBy` marker protocols: `ExpressibleBySingleQuotedLiteral` and `ExpressibleByASCIILiteral` which are inserted above the existing `ExpressibleByUnicodeScalarLiteral` in the double quoted literal protocols. As they are prefixed with `@_marker` it is assumed this will not affect the ABI of the existing protocol's witness table layouts. The `ExpressibleBySingleQuotedLiteral` is used only to change the default type of single quoted literals in an expression without type context and the `ExpressibleByASCIILiteral` used to gate the ASCII to integer value conversions. While the inheritance relationship of the ABI-locked `ExpressibleBy` protocols technically entails that `Character` and `Unicode.Scalar` literals can be implicitly promoted to `String` literals, it would be possible in future for the compiler to statically reject such cases at the type checking stage, without affecting ABI, in the interest of untangling the various textual literal forms. As literal delimiters are a purely compile-time construct, and all double-quoted literals currently default to `String`, this will have zero impact on all existing Swift code.

 ## Source compatibility

As the use of the new single quoted syntax is opt-in existing code will continue to compile as before i.e. the proposed implementation is not source breaking. Only where the user has opted to use the new single quoted spelling will the integer conversions be available. This is possible to add a warning and fix-it to prompt the user to move to the new syntax in the course of time. In practice, the Character and Unicode.Scalar types occur do not occur frequently in code so this would not be an arduous migration.

 ## Effect on ABI stability

 Assuming injecting `@_marker` protocols does not alter witness table layout and ABI, this is a purely lexer- and type checker-level change which does not affect the storage or entry points of `Character` and `Unicode.Scalar`. These initializers are an implementation artifact of Swift's protocol-driven literals model, and are meant to be automatically invoked by the compiler. As they are not intended for “public consumption”, we see no reason to continue having the compiler invoke them.

 ## Effect on API resilience

 This is a purely lexer- and type checker-level change which does not affect the API of the standard library.

 ## Alternatives considered

 The most obvious alternative is to simply leave things the way they are where double quoted `String` literals can perform service as `Character` or `UnicodeScalar` values as required. At its heart, while this is transparent to users, this devalues the role of `Characters` in source code — a distinction that may come in handy working in lower-level code. 

 Another alternative discussed on [another thread](https://forums.swift.org/t/unicode-scalar-literals/22224) was “Unicode Scalar Literals”. Unicode scalar literals would have the benefit of allowing concise access to codepoint and ASCII APIs, as methods and properties could be accessed from `'a'` expressions instead of unwieldy `('a' as Unicode.Scalar)` expressions. However the authors feel this would contradict Swift’s `String` philosophy, which explicitly recognizes `Character` as the natural element of `String`, not `Unicode.Scalar`. In the end this is configurable in the implementataion.
