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

## Motivation

Naming could be hard and having descriptive methods, like in tests, may result in declarations that are hard to read because of its lack of whitespace and punctuations or other symbols. Enabling natural language would improve readability.

```swift
func `test validation should succeed when input is less than ten`() // currently not possible
// vs
func testValidationShouldSucceedWhenInputIsLessThanTen() // camelCase
func test_Validation_Should_Succeed_When_Input_Is_Less_Than_Ten() // camel_Case_Mixed_Snake_Case
func test_validationShouldSucceed_whenInputIs_lessThanTen() //camelCase_Mixed_SnakeCase_Grouped
```

Maintainers of different projects under the [Swift Source Compatibility](https://swift.org/source-compatibility/#current-list-of-projects) uses, instead of Swift's method declaration, testing frameworks, like [Quick](https://github.com/Quick/Quick), because (among other reasons) how they can elegantly express tests descriptions.

Other modern languages like [F#](https://fsharp.org) and [Kotlin](https://kotlinlang.org) saw the value in supporting natural language for escaped identifiers. Today, naming methods with spaces and punctuation are, for those languages, a standard for tests, widely adopted and supported by different test runners and reporting tools.

Another limitation of identifiers is that they can include digits (0-9), but they can not start with one.
There are certain scenarios where it would be beneficial to be able to start with a digit.
```swift
enum Version {
    case `1`   // currently not possible
    case `1.2` // currently not possible
}
enum HTTPStatus {
    case `300`  // currently not possible
}
```
Code generators are also affected, as they are required to mangle invalid code points in identifiers in order to produce correct Swift code.
As an example, asset names to typed values tools, like [R.swift](https://github.com/mac-cain13/R.swift), can not express identifiers like `10_circle` (and others from Apple's SF Symbols), without losing a 1 to 1 map to their original asset names. Having to prefix (i.e.: `_10_circle`), replace (i.e.: `ten_circle`) or strip (i.e.: `_circle`) will affect discoverability of those.

Non-English idioms, like French, heavily rely on apostrophes or hyphens and trying to replace those code points in an identifier will likely result in a less readable version.

## Proposed solution
This proposal wants to extend the current grammar for every escaped identifier (properties, methods, types, etc...) by allowing every Unicode scalar except every type of line terminators and back-ticks.

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

It is important to clarify how escaped identifiers will behave.
In general, an escaped identifier will respect any meaning the non-escaping version may have, if rappresentable.
This means that any current semantic restriction will be respected:
* Dollar identifiers are compiler-reserved names and defining ``` `$identifierNames` ``` will produce an error, as it is already happening.
* Escaped identifiers that can be expressed, within their context, without back-ticks as operators, will be considered operators, therefore they will respect operators semantics.
```swift
static func `+`(lhs: Int, rhs: Int) -> Int // Is an operator
func `test +`() // Is not an operator but a valid method
```

The proposal, by allowing a larger set of characters will remove other limitations as, for example, referencing to operators.
```swift
let add = Int.`+` // currently not possible
```

### Grammar
This proposal wants to replace the following grammar:
```
identifier → ` identifier-head identifier-characters opt `
```
with:
```
identifier → ` escaped-identifier `
escaped-identifier -> Any Unicode scalar value except U+000A (line feed), U+000B (vertical tab), U+000C (form feed), U+000D (carriage return), U+0085 (next line), U+2028 (line separator), U+2029 (paragraph separator) or U+0060 (back-tick)
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

It was suggested, as an alternative, for the testing method names use case to add a method attribute:
```
@test("test validation should succeed when input is less than ten")
func testValidationShouldSuccedWhenInputIsLessThanTen() {}
```
It was not considered a valid option for few reasons:
* it introduces information redudancy
* it is not applicable for the rest of the issues mentioned above
* adding a new attribute would likely to introduce more complexity to the compiler and to the test runner

Swift currently treats Unicode values individually, this means that a character that can have different representations (like a-grave: U+00E0 'à' or U+0061 U+0300 'a' + combining grave accent) will be treated as different identifiers. Swift also supports unprintable characters like zero-width character (U+200B) that allows identifiers that look the same be treated as different.
```swift
let ​ = 3 // Currently valid, zero-width character identifier
let space​Here = 3 // Currently valid, with zero-width character between `space` and `Here`
let spaceHere = 3 // Currently valid, does not from the above because not using zero width character
let à = 3 // U+00E0 // Currently valid
let à = 3 // U+0061 U+0300 // Currently valid, does not from the above because represented differently
```
While this issue can be related to escaped identifiers too, we believe it should be addressed separately as it is an existing issue that is affecting non-escaping identifiers and other grammars tokens.

## Future direction
It may be possible, if relevant, to support new lines or back-ticks using a similar raw string literals approach.
```swift
func #`this has a ` back-tick`#()
func ###`this has a 
new line`###()
```

It was considered that the proposal, by including code points like `<`, `>`, `.` may confuse a possible future runtime API for type retrieval by a string (i.e.: `typeByName("Foo<Int>.Bar")`). In that hypothetical scenario using back-ticks as part of string could be sufficient in order to resolve ambiguity. 
