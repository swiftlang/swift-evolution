# Feature name

* Proposal: [SE-0243a](0243a-single-quoted-character-literals.md)
* Authors: [Kelvin Ma (“Taylor Swift”)](https://github.com/kelvin13), [John Holdsworth](https://github.com/johnno1962)
* Review manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Second review** 
* Implementation: [apple/swift#21873](https://github.com/apple/swift/pull/21873)
* Threads: [1](https://forums.swift.org/t/prepitch-character-integer-literals/10442) [2](https://forums.swift.org/t/se-0243-codepoint-and-character-literals/21188)

## Introduction

Swift brought with it a new, 21st century definition for what constitutes a `Character` but unlike most common computer languages, Swift does not have a separate syntax for `Character` literals. Instead, using the interplay of three "ExpressibleBy" protocols and type inference Swift allows a double quoted string literal to take the role of a `Character` or `UnicodeScalar` value dependant on the expression context. This proposal would like to put forward that literals intended to be used in a Character or UnicodeScalar context should be delimited by single quote (`'`) characters and within the limits of Unicode versions past, present and future be checked by the compiler to contain only a single "extended grapheme cluster".

## Motivation

While the motivation for distinguishing between `String` and `Character` literals is primarily aesthetic it brings Swift into line with other common computer languages and will hopefully facilitate a separate subsequent proposal to improve the ergonomics of low level work with buffers of `Int8` values in parsers and JSON decoders. While this is a "Source Breaking" change to the Swift language for which the bar has to be set high, the situations where Character literals are used are comparatively rare and would benefit from the emphasis of distinct literal form. It will be easy for the compiler to provide a fixit and migration tool during transition.

## Proposed solution

If adopted, this proposal would require literal values that are intended for use as a `Character` or `UnicodeScalar` to be delimited by single quote rather than double quotes as they are at present. These literals would have a default type of `Character` or it is possible literals that happen to be UnicodScalars should have a differential default type `UnicodeScalar` which would allow direct access to the rich `UnicodeScalar` API. This proposal is the result of breaking a previous Swift evolution pitch [SE-0243](0243-codepoint-and-character-literals.md) into two parts. This first part to argue the case for single quoted "Character literal" syntax independently to be followed by an discussion of how this syntax could be used to improve the ergonomics of working with buffers of integers by extending the standard library.

## Detailed design

This is a change that is internal to the Swift compiler and does not affect how these literal values are represented at runtime and hence does not affect the ABI. Single quoted literals are largely identical to double quoted `String` literals supporting the existing escape characters as they reuse the same code in the lexer. An additional check is made however that they contain a single "Extended Grapheme Cluster" early on in parsing. The inheritance relationship of the `ExpressibleBy` protocols locked into the Swift ABI is such that these single quoted literal will be able to be used where you require a `String` but double quoted literals will no longer be able to specify `Character` or `UnicodeScalar` literals. This behaviour is viewed as a feature as you will be able to construct a string from a combination of characters i.e. `"ab" == 'a' + 'b'`

## Source compatibility

There are very few functions in the Swift ABI that require `Character` or `UnicodeScalar` arguments and it is only in these places that it will be necessary to use the new syntax. The compiler can easily detect these situations and provide a "fixit" and the migration tool can readily be adapted to convert code automatically.

## Effect on ABI stability

This is a compilation phase change not affecting storage of literals.

## Effect on API resilience

This is a compilation phase change not prejudicing  future storage of literals.

## Alternatives considered

The most obvious alternative is to simply leave things the way they are where double quoted `String` literals can perform service as `Character` or `UnicodeScalar` values as required. At it's heart, while this is transparent to users it devalues the role of `Characters` in source code — a distinction that may come in handy working in lower level code. It's also something users need to learn coming to Swift from another language. Easier to bring across the existing convention.

Another alternative discussed on [another thread](https://forums.swift.org/t/unicode-scalar-literals/22224) was "Unicode Scalar Literals". This author feels this would be a corruption of Swift's no compromise String model. It would seem a mistake to build the subtle distinction between a Character and UnicodeScalar into the language when the atomic component of Strings as a collection is `Character` (Extended Grapheme Cluster).