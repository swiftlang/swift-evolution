# Regex reverse matching

* Proposal: [SE-NNNN](nnnn-regex-reverse-matching.md)
* Authors: [Jacob Hearst](https://github.com/JacobHearst) [Michael Ilseman](https://github.com/milseman)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Bug: rdar://132158055
* Implementation: [Prototype](https://github.com/JacobHearst/swift-experimental-string-processing/tree/reverse-matching)
* Upcoming Feature Flag: (pending)


## Introduction

Regex supports matching strings forwards, including lookahead assertions, but does not currently support matching in reverse or lookbehind assertions. We propose adding these.

## Motivation

Modern regular expression engines support lookbehind assertions, whether fixed length (Perl, PCRE2, Python, Java) or arbitrary length (.NET, Javascript).

## Proposed solution

We propose supporting arbitrary-length lookbehind regexes which can be achieved by performing matching in reverse. We also propose API to run a regex in reverse from the end of a string.

A regex that matches a string going forwards will also match going in reverse, but may produce a different match. For example, in a regex that has multiple eager quantifications:

```
"abcdefg".wholeMatch(of: /(.+)(.+)/)
// Produces ("abcdefg", "abcdef", "g")

"abcdefg".wholeReverseMatch(of: /(.+)(.+)/)
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
// Positive lookabehind
/a(?<=b)c/
/a(*plb:b)c/
/a(*positive_lookbehind:b)c/

// Negative lookabehind
/a(?<!b)c/
/a(*nlb:b)c/
/a(*negative_lookbehind:b)c/

```

### Regex builders

**TODO**: add Regex builders for positive and negative lookbehind

### API

**TODO**: Add reverse variants of matching API, e.g. `firstReverseMatch()`.


## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the standard library and runtime.

## Future directions

### Support PCRE's `\K`

Future work includes supporting PCRE's `\K`, which resets the current produced match.

## Alternatives considered

### Fixed length lookbehind assertions only

Fixed-length lookbehind assertions are easier to implement and retrofit onto existing engines. Python only supports a single fixed-width concatenation sequence, PCRE2 additionally supports alternations of fixed-width concatenations, and Java additionally supports bounded quantifications within.

However, this would limit Swift's expressivity compared to Javascript and .NET, as well as be insufficient for reverse matching API.

### Using the word "last" in API names

Our proposed reverse matching APIs use the word "reverse" to denote the regex is running in reverse from the end of the string. An alternative name to `firstReverseMatch` could be `lastMatch`. We rejected `lastMatch` because reverse matching doesn't necessarily produce the same match as `str.matches(of: regex).last`.



## Acknowledgments

cherrycoke, bjhomer, Simulacroton, and rnantes provided use cases and rationale for lookbehind assertions.




