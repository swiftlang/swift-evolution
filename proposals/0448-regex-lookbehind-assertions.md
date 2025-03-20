# Regex lookbehind assertions

* Proposal: [SE-0448](0448-regex-lookbehind-assertions.md)
* Authors: [Jacob Hearst](https://github.com/JacobHearst) [Michael Ilseman](https://github.com/milseman)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Accepted**
* Implementation: https://github.com/swiftlang/swift-experimental-string-processing/pull/760
* Review:
  ([pitch](https://forums.swift.org/t/pitch-regex-reverse-matching/73482))
  ([review](https://forums.swift.org/t/se-0448-regex-lookbehind-assertions/74672))
  ([acceptance](https://forums.swift.org/t/accepted-se-0448-regex-lookbehind-assertions/75111))


## Introduction

Regex supports lookahead assertions, but does not currently support lookbehind assertions. We propose adding these.

## Motivation

Modern regular expression engines support lookbehind assertions, whether fixed length (Perl, PCRE2, Python, Java) or arbitrary length (.NET, Javascript).

## Proposed solution

We propose supporting arbitrary-length lookbehind regexes which can be achieved by performing matching in reverse.

Like lookahead assertions, lookbehind assertions are _zero-width_, meaning they do not affect the current match position.

Examples:


```swift
"abc".firstMatch(of: /a(?<=a)bc/)  // matches "abc"
"abc".firstMatch(of: /a(?<=b)c/)   // no match
"abc".firstMatch(of: /a(?<=.)./)   // matches "ab"
"abc".firstMatch(of: /ab(?<=a)c/)  // no match
"abc".firstMatch(of: /ab(?<=.a)c/) // no match
"abc".firstMatch(of: /ab(?<=a.)c/) // matches "abc"
```

Lookbehind assertions run in reverse, i.e. right-to-left, meaning that right-most eager quantifications have the opportunity to consume more of the input than left-most. This does not affect whether an input matches, but could affect the value of captures inside of a lookbehind assertion:

```swift
"abcdefg".wholeMatch(of: /(.+)(.+)/)
// Produces ("abcdefg", "abcdef", "g")

"abcdefg".wholeMatch(of: /.*(?<=(.+)(.+)/))
// Produces ("abcdefg", "a", "bcdefg")
```

## Detailed design


### Syntax

Lookbehind assertion syntax is already supported in the existing [Regex syntax](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0355-regex-syntax-run-time-construction.md#lookahead-and-lookbehind).

The engine is currently incapable of running them, so a compilation error is thrown:

```swift
let regex = /(?<=a)b/
// error: Cannot parse regular expression: lookbehind is not currently supported
```

With this proposal, this restriction is lifted and the following syntactic forms will be accepted:

```swift
// Positive lookbehind
/a(?<=b)c/
/a(*plb:b)c/
/a(*positive_lookbehind:b)c/

// Negative lookbehind
/a(?<!b)c/
/a(*nlb:b)c/
/a(*negative_lookbehind:b)c/
```

### Regex builders
This proposal adds support for both positive and negative lookbehind assertions when using the Regex builder, for example:

```swift
// Positive Lookbehind
Regex {
  "a"
  Lookbehind { "b" }
  "c"
}

// Negative lookbehind
Regex {
  "a"
  NegativeLookbehind { "b" }
  "c"
}
```

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the standard library and runtime.

## Future directions

### Support PCRE's `\K`

Future work includes supporting PCRE's `\K`, which resets the current produced match.

### Reverse matching API

Earlier versions of this pitch added API to run regex in reverse from the end of the string. However, we faced difficulties communicating the nuance of reverse matching in API and this is an obscure feature that isn't supported by mainstream languages.

## Alternatives considered

### Fixed length lookbehind assertions only

Fixed-length lookbehind assertions are easier to implement and retrofit onto existing engines. Python only supports a single fixed-width concatenation sequence, PCRE2 additionally supports alternations of fixed-width concatenations, and Java additionally supports bounded quantifications within.

However, this would limit Swift's expressivity compared to Javascript and .NET, as well as be insufficient for reverse matching API.


## Acknowledgments

cherrycoke, bjhomer, Simulacroton, and rnantes provided use cases and rationale for lookbehind assertions. xwu provided feedback on the difficulties of communicating reverse matching in API. ksluder, nikolai.ruhe, and pyrtsa surfaced interesting examples and documentation needs.





