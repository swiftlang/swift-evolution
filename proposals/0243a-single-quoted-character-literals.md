# Feature name

* Proposal: [SE-0243a](0243a-single-quoted-character-literals.md)
* Authors: [Kelvin Ma (“Taylor Swift”)](https://github.com/kelvin13), [John Holdsworth](https://github.com/johnno1962)
* Review manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Second review** 
* Implementation: [apple/swift#21873](https://github.com/apple/swift/pull/21873)
* Threads: [1](https://forums.swift.org/t/prepitch-character-integer-literals/10442) [2](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188)

## Introduction

Swift emphasizes a unicode-correct definition of what constitutes a `Character`, but unlike most common programming languages, Swift does not have a dedicated syntax for `Character` literals. Instead, three overlapping “ExpressibleBy” protocols and type inference come together to produce a confusing syntax where a double quoted string literal can take the role of a `String`, `Character`, or `Unicode.Scalar` value depending on its content, and the expression context. 

This proposal assigns a dedicated syntax for `Character` and `Unicode.Scalar` values, using single quote (`'`) delimiters. This change solely affects the type inference of single- and double-quoted literals, and does not seek to change the current compiler validation behavior for these constructs.

## Motivation

A pain point of using characters in Swift is they lack a first-class literal syntax. Users have to manually coerce string literals to a `Character` or `Unicode.Scalar` type using `as Character` or `as Unicode.Scalar`, respectively. Having the collection share the same syntax as its element also harms code clarity and makes it difficult to tell if a double-quoted literal is being used as a string or character in some cases.

While the motivation for distinguishing between `String` and `Character` literals most consists of ergonomic and readability concerns, doing so would also bring Swift into line with other common computer languages which make this syntactic distinction, and will hopefully facilitate a possible subsequent effort to improve support for low level work with buffers of `UInt8`/`Int8` values in parsers and codecs. While this is a “source breaking” change to the language, the situations where `Character` literals are used are relatively rare and would benefit from the migration to a distinct literal form. It will be straightforward for the compiler to provide a fixit and migration tool during the transition.

## Proposed solution

This proposal is a subset of a previous Swift evolution pitch [SE-0243](0243-codepoint-and-character-literals.md).

We propose to adopt the `'x'` syntax for all textual literal types up to and including `ExtendedGraphemeClusterLiteral`, but not including `StringLiteral`. These literals will be used to express `Character`, `Unicode.Scalar`, and types like `UTF16.CodeUnit` in the standard library. These literals would have a default type of `Character`, as `Character` is the preferred element type of `String`. 

Use of single quotes for character/scalar literals is precedented in other languages, including C, Objective-C, C++, Java, and Rust, although different languages have slightly differing ideas about what a “character” is. We choose to use the single quote syntax specifically because it reinforces the notion that strings and character values are different: the former is a sequence, the later is an element. Character types also don't support string literal interpolation, which is another reason to move away from double quotes.

## Detailed design

This is a change that is internal to the Swift compiler and does not affect how these literal values are represented at runtime and hence does not affect the ABI. Single quoted literals are largely identical to double quoted `String` literals supporting the existing escape characters, and they could reuse the same code in the lexer. However, the compiler would in addition perform a best-effort attempt at validating that they contain a single extended grapheme cluster at compile time, as it currently does when an `as Character` type coercion annotation is present. Validation behavior for `Unicode.Scalar` literals will be unaffected. 

While the inheritance relationship of the ABI-locked `ExpressibleBy` protocols technically entails that `Character` and `Unicode.Scalar` literals can be implicitly promoted to `String` literals, it is possible for the compiler to statically reject such cases at the type checking stage, without affecting ABI, in the interest of untangling the various textual literal forms. As literal delimiters are a purely compile-time construct, and all double-quoted literals currently default to `String`, this will have zero impact on all existing Swift code.

## Source compatibility

There are few functions in the standard library that take `Character` or `Unicode.Scalar` arguments and it is only in these places that it will be necessary to use the new syntax. The compiler can easily detect these situations and provide a fixit and automated code migration.

Here is a specific sketch of a deprecation policy:

    Introduce the new syntax support into Swift 5.1.

    Swift 5.1 mode would start producing deprecation warnings (with a fixit to change double quotes to single quotes.)

    The Swift 5 to 5.1 migrator would change the syntax (by virtue of applying the deprecation fixits.)

    Swift 6 would not accept the old syntax.

## Effect on ABI stability

This is a purely lexer- and type checker-level change which does not affect the storage or entry points of `Character` and `Unicode.Scalar`. Cases of implicit promotion of `Character` or `Unicode.Scalar` literals in a `String` context will be statically rejected, but the dynamic `String.init(unicodeScalarLiteral:)` and `String.init(extendedGraphemeClusterLiteral:)` entry points will remain accessible, per ABI requirements. These initializers are an implementation artifact of Swift's protocol-driven literals model, and are meant to be automatically invoked by the compiler. As they are not intended for “public consumption”, we see no reason to continue having the compiler invoke them.

## Effect on API resilience

This is a purely lexer- and type checker-level change which does not affect the API of the standard library.

## Alternatives considered

The most obvious alternative is to simply leave things the way they are where double quoted `String` literals can perform service as `Character` or `UnicodeScalar` values as required. At it’s heart, while this is transparent to users it devalues the role of `Characters` in source code — a distinction that may come in handy working in lower level code. 

Another alternative discussed on [another thread](https://forums.swift.org/t/unicode-scalar-literals/22224) was “Unicode Scalar Literals”. Unicode scalar literals would have the benefit of allowing concise access to codepoint and ASCII APIs, as methods could be called on `'a'` expressions instead of unwieldy `('a' as Unicode.Scalar)` expressions. However the authors feel this would contradict Swift’s `String` philosophy, which explicitly recognizes `Character` as the natural element of `String`, not `Unicode.Scalar`.
