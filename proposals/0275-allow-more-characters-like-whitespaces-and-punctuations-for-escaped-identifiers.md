# Allow more characters (like whitespaces and punctuations) for escaped identifiers

* Proposal: [SE-0275](0275-allow-more-characters-like-whitespaces-and-punctuations-for-escaped-identifiers.md)

* Authors: [Alfredo Delli Bovi](https://github.com/adellibovi)

* Review Manager: [Joe Groff](https://github.com/jckarter)

* Status: **Active Review (January 13...January 20, 2020)**

* Implementation: [apple/swift#28966](https://github.com/apple/swift/pull/28966)

## Introduction
Swift has a beautiful concise yet expressive syntax.
As part of that, escaped identifiers are adopted to allow usage of reserved keywords.
This proposal wants to extend the character allowance for escaped identifiers with more Unicode scalars, like whitespace and punctuation.
It will enable to have method names (or other identifiers) with a more readable and natural language like the following:
```swift
func `test validation should succeed when input is less than ten`()
```
## Motivation
Naming could be hard and having descriptive methods, like in tests, may result in declarations that are hard to read because of its lack of whitespace and punctuations or other symbols. Enabling natural language would improve readability.

Maintainers of different projects under the [Swift Source Compatibility](https://swift.org/source-compatibility/#current-list-of-projects) uses, instead of Swift's method declaration, testing frameworks, like [Quick](https://github.com/Quick/Quick), because (among other reasons) how they can elegantly express tests descriptions.

Other modern languages like [F#](https://fsharp.org) and [Kotlin](https://kotlinlang.org) saw the value in supporting natural language for escaped identifiers. Today, naming methods with spaces and punctuation are, for those languages, a standard for tests, widely adopted and supported by different test runners and reporting tools.

## Proposed solution
This proposal wants to extend the current grammar for every escaped identifier (properties, methods, types etc...) by allowing every Unicode scalar.

A declaration to an escaped identifier will follow the existing back-ticked syntax.
```swift
func `test validation should succeed when input is less than ten`()
var `some var` = 0
```

As per referencing.
```swift
`test validation should succeed when input is less than ten`()
foo.`property with space`
```
In fact, by allowing a larger set of characters, we will remove current limitations and, as an example, we will enable us to reference an operator, which currently produces an error.
```swift
let add = Int.`+`
```

### Grammar
This proposal wants to replace the following grammar:
```
identifier → ` identifier-head identifier-characters opt `
```
with:
```
identifier → ` escaped-identifier `
escaped-identifier -> Any Unicode scalar value except U+000A or U+000D or U+0060
```

### Objective-C Interoperability
Objective-C declarations do not support every type of Unicode scalar value.
If willing to expose an escaped identifier that includes a not supported Objective-C character, we can sanitize it using the existing `@objc` annotation like the following:
```swift
@objc(sanitizedName)
```

## Source compatibility
This feature is strictly additive.

## Effect on ABI stability
This feature does not affect the ABI.

## Effect on API resilience
This feature does not affect the API.

## Alternatives considered
It was considered to extend the grammars for methods declaration only, this was later discarded because we want to keep usage consistency and it would be hard to explain why an escaped identifier may support a certain set of characters in a context and a different one in another context.
