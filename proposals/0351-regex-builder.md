# Regex builder DSL

* Proposal: [SE-0351](0351-regex-builder.md)
* Authors: [Richard Wei](https://github.com/rxwei), [Michael Ilseman](https://github.com/milseman), [Nate Cook](https://github.com/natecook1000)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Implementation: [apple/swift-experimental-string-processing](https://github.com/apple/swift-experimental-string-processing/tree/main/Sources/_StringProcessing/RegexDSL)
  * Available in nightly toolchain snapshots with `import _StringProcessing`
* Status: **Active Review (4 - 15 April 2022)**

**Table of Contents**
- [Introduction](#introduction)
- [Motivation](#motivation)
- [Proposed solution](#proposed-solution)
- [Detailed design](#detailed-design)
  - [`RegexComponent` protocol](#regexcomponent-protocol)
  - [Concatenation](#concatenation)
  - [Alternation](#alternation)
  - [Quantification](#quantification)
  - [Capture and reference](#capture-and-reference)
  - [Subpattern](#subpattern)
  - [Scoping](#scoping)
- [Source compatibility](#source-compatibility)
- [Effect on ABI stability](#effect-on-abi-stability)
- [Effect on API resilience](#effect-on-api-resilience)
- [Alternatives considered](#alternatives-considered)

## Introduction

[Declarative string processing] aims to offer powerful pattern matching capabilities with expressivity, clarity, type safety, and ease of use. To achieve this, we propose to introduce a result-builder-based DSL, **regex builder**, for creating and composing regular expressions (**regex**es).

Regex builder is part of the Swift Standard Library but resides in a standalone module named `RegexBuilder`. By importing `RegexBuilder`, you get all necessary API for building a regex.

```swift
import RegexBuilder

let emailPattern = Regex {
  let word = OneOrMore(.word)
  Capture {
    ZeroOrMore {
      word
      "."
    }
    word
  }
  "@"
  Capture {
    word
    OneOrMore {
      "."
      word
    }
  }
} // => Regex<(Substring, Substring, Substring)>

let email = "My email is my.name@mail.swift.org."
if let match = email.firstMatch(of: emailPattern) {
  let (wholeMatch, name, domain) = match.output
  // wholeMatch: "My email is my.name@mail.swift.org."
  //       name: "my.name"
  //     domain: "mail.swift.org"
}
```

This proposal introduces all core API for creating and composing regexes that echos the textual [regex syntax] and [strongly typed regex captures], but does not formally specify the matching semantics or define character classes.

## Motivation

Regex is a fundemental and powerful tool for textual pattern matching. It is a domain-specific language often expressed as text. For example, given the following bank statement:

```
CREDIT    04062020    PayPal transfer    $4.99
CREDIT    04032020    Payroll            $69.73
DEBIT     04022020    ACH transfer       $38.25
DEBIT     03242020    IRS tax payment    $52249.98
```

One can write the follow textual regex to match each line:

```
(CREDIT|DEBIT)\s+(\d{2}\d{2}\d{4})\s+([\w\s]+\w)\s+(\$\d+\.\d{2})
```

While a regex like this is very compact and expressive, it is very difficult read, write and use:

1. Syntactic special characters, e.g. `\`, `(`, `[`, `{`, are too dense to be readable.
2. It contains a hierarchy of subpatterns fit into a single line of text.
3. No code completion when typing syntactic components.
4. Capturing groups produce raw data (i.e. a range or a substring) and can only be converted to other data structures after matching.
5. While comments `(?#...)` can be added inline, it only complicates readability.

## Proposed solution

We introduce regex builder, a result-builder-based API for creating and composing regexes. This API resides in a new module named `RegexBuilder` that is to be shipped as part of the Swift toolchain.

With regex builder, the regex for matching a bank statement can be written as the following:

```swift
import RegexBuilder

enum TransactionKind: String {
   case credit = "CREDIT"
   case debit = "DEBIT"
}

struct Date {
  var month, day, year: Int
  init?(mmddyyyy: String) { ... }
}

struct Amount {
  var valueTimes100: Int
  init?(twoDecimalPlaces text: Substring) { ... }
}

let statementPattern = Regex {
  // Parse the transaction kind.
  TryCapture {
    ChoiceOf {
      "CREDIT"
      "DEBIT"
    }
  } transform: {
    TransactionKind(rawValue: String($0))
  }
  OneOrMore(.whitespace)
  // Parse the date, e.g. "01012021".
  TryCapture {
    Repeat(.digit, count: 2)
    Repeat(.digit, count: 2)
    Repeat(.digit, count: 4)
  } transform: { Date(mmddyyyy: $0) }
  OneOrMore(.whitespace)
  // Parse the transaction description, e.g. "ACH transfer".
  Capture {
    OneOrMore(.custom([
      .characterClass(.word),
      .characterClass(.whitespace)
    ]))
    CharacterClass.word
  } transform: { String($0) }
  OneOrMore(.whitespace)
  "$"
  // Parse the amount, e.g. `$100.00`.
  TryCapture {
    OneOrMore(.digit)
    "."
    Repeat(.digit, count: 2)
  } transform: { Amount(twoDecimalPlaces: $0) }
} // => Regex<(Substring, TransactionKind, Date, String, Amount)>


let statement = """
  CREDIT    04062020    PayPal transfer    $4.99
  CREDIT    04032020    Payroll            $69.73
  DEBIT     04022020    ACH transfer       $38.25
  DEBIT     03242020    IRS tax payment    $52249.98
  """
for match in statement.matches(of: statementPattern) {
  let (line, kind, date, description, amount) = match.output
  ...
}
```

Regex builder addresses all of textual regexes' shortcomings presented in the [Motivation](#motivation) section:
1. Capture groups and quantifiers are expressed as API calls that are easy to read.
2. Scoping and indentations clearly distinguish subpatterns in the hierarchy.
3. Code completion is available when the developer types an API call.
4. Capturing groups can be transformed into structured data at the regex declaration site.
5. Normal code comments can be written within a regex declaration to further improve readability.

## Detailed design

### `RegexComponent` protocol

One of the goals of the regex builder DSL is allowing the developers to easily compose regexes from common currency types and literals, or even define custom patterns to use for matching. We introduce `RegexComponent`, a protocol that unifies all types that can represent a component of a regex.

```swift
public protocol RegexComponent {
  associatedtype Output
  @RegexComponentBuilder
  var regex: Regex<Output> { get }
}
```

By conforming standard library types to `RegexComponent`, we allow them to be used inside the regex builder DSL as a match target.

```swift
// A string represents a regex that matches the string.
extension String: RegexComponent {
  public var regex: Regex<Substring> { get }
}

// A substring represents a regex that matches the substring.
extension Substring: RegexComponent {
  public var regex: Regex<Substring> { get }
}

// A character represents a regex that matches the character.
extension Character: RegexComponent {
  public var regex: Regex<Substring> { get }
}

// A unicode scalar represents a regex that matches the scalar.
extension UnicodeScalar: RegexComponent {
  public var regex: Regex<Substring> { get }
}

// To be introduced in a future pitch.
extension CharacterClass: RegexComponent {
  public var regex: Regex<Substring> { get }
}
```

Since regexes are composable, the `Regex` type itself also conforms to `RegexComponent`.

```swift
extension Regex: RegexComponent {
  public var regex: Self { self }
}
```

All of the regex builder DSL in the rest of this pitch will accept generic components that conform to `RegexComponent`.

### Concatenation

A regex can be viewed as a concatenation of smaller regexes. In the regex builder DSL, `RegexComponentBuilder` is the basic facility to allow developers to compose regexes by concatenation.

```swift
@resultBuilder
public enum RegexComponentBuilder { ... }
```

A closure marked with `@RegexComponentBuilder` will be transformed to produce a `Regex` by concatenating all of its components, where the result type's `Output` type will be a `Substring` followed by concatenated captures (tuple when plural).

> #### Recap: Regex capturing basics
> 
> `Regex` is a generic type with generic parameter `Output`.
>
> ```swift
> struct Regex<Output> { ... }
> ```
> 
> When a regex does not contain any capturing groups, its `Output` type is `Substring`, which represents the whole matched portion of the input.
>
> ```swift
> let noCaptures = #/a/# // => Regex<Substring>
> ```
>
> When a regex contains capturing groups, i.e. `(...)`, the `Output` type is extended as a tuple to also contain *capture types*. Capture types are tuple elements after the first element.
> 
> ```swift
> //                           ________________________________
> //                        .0 |                           .0 |
> //                  ____________________                _________
> let yesCaptures = #/a(?:(b+)c(d+))+e(f)?/# // => Regex<(Substring, Substring, Substring, Substring?)>
> //                      ---- ----   ---                            ---------  ---------  ----------
> //                    .1 | .2 |   .3 |                              .1 |       .2 |       .3 |
> //                       |    |      |                                 |          |          |
> //                       |    |      |_______________________________  |  ______  |  ________|
> //                       |    |                                        |          |
> //                       |    |______________________________________  |  ______  |
> //                       |                                             |
> //                       |_____________________________________________|
> //                                                                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
> //                                                                          Capture types
> ```

We introduce a new initializer `Regex.init(_:)` which accepts a `@RegexComponentBuilder` closure. This initializer is the entry point for creating a regex using the regex builder DSL.

```swift
extension Regex {
  public init<R: RegexComponent>(
    @RegexComponentBuilder _ content: () -> R
  ) where R.Output == Output
}
```

Example:

```swift
Regex {
   regex0 // Regex<Substring>
   regex1 // Regex<(Substring, Int)>
   regex2 // Regex<(Substring, Float)>
   regex3 // Regex<(Substring, Substring)>
} // Regex<(Substring, Int, Float, Substring)>
```

This above regex will be transformed to:

```swift
Regex {
  let e0 = RegexComponentBuilder.buildExpression(regex0) // Regex<Substring>
  let e1 = RegexComponentBuilder.buildExpression(regex1) // Regex<(Substring, Int)>
  let e2 = RegexComponentBuilder.buildExpression(regex2) // Regex<(Substring, Float)>
  let e3 = RegexComponentBuilder.buildExpression(regex3) // Regex<(Substring, Substring)>
  let r0 = RegexComponentBuilder.buildPartialBlock(first: e0)
  let r1 = RegexComponentBuilder.buildPartialBlock(accumulated: r0, next: e1)
  let r2 = RegexComponentBuilder.buildPartialBlock(accumulated: r1, next: e2)
  let r3 = RegexComponentBuilder.buildPartialBlock(accumulated: r2, next: e3)
  return r3
} // Regex<(Substring, Int, Float, Substring)>
```

Basic methods in `RegexComponentBuilder`, e.g. `buildBlock()`, provides support for creating the most fundamental blocks. The `buildExpression` method wraps a user-provided component in a `RegexComponentBuilder.Component` structure, before passing the component to other builder methods. This is used for saving the source location of the component so that runtime errors can be reported with an accurate location.

```swift
@resultBuilder
public enum RegexComponentBuilder {
  /// Returns an empty regex.
  public static func buildBlock() -> Regex<Substring>

  /// A builder component that stores a regex component and its source location
  /// for debugging purposes.
  public struct Component<Value: RegexComponent> {
    public var value: Value
    public var file: String
    public var function: String
    public var line: Int
    public var column: Int
  }

  /// Returns a component by wrapping the component regex in `Component` and
  /// recording its source location.
  public static func buildExpression<R: RegexComponent>(
    _ regex: R, 
    file: String = #file, 
    function: String = #function, 
    line: Int = #line,
    column: Int = #column
  ) -> Component<R>
}
```

When it comes to concatenation, `RegexComponentBuilder` utilizes the [recently proposed `buildPartialBlock` feature](https://forums.swift.org/t/pitch-buildpartialblock-for-result-builders/55561/1) to be able to concatenate all components' capture types to a single result tuple. `buildPartialBlock(first:)` provides support for creating a regex from a single component, and `buildPartialBlock(accumulated:next:)` support for creating a regex from multiple results.

Before Swift supports variadic generics, `buildPartialBlock(first:)` and `buildPartialBlock(accumulated:next:)` must be overloaded to support concatenating regexes of supported capture quantities (arities).
- `buildPartialBlock(first:)` is overloaded `arity` times such that a unary block with a component of any supported capture arity will produce a regex with capture type `Substring` followed by the component's capture types. The base overload, `buildPartialBlock<R>(first:) -> Regex<Substring>`, must be marked with `@_disfavoredOverload` to prevent it from shadowing other overloads.
- `buildPartialBlock(accumulated:next:)` is overloaded up to `arity^2` times to account for all possible pairs of regexes that make up 10 captures.

In the initial version of the DSL, we plan to support regexes with up to 10 captures, as 10 captures are sufficient for most use cases. These overloads can be superceded by variadic versions of `buildPartialBlock(first:)` and `buildPartialBlock(accumulated:next:)` in a future release.

```swift
extension RegexComponentBuilder {
  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single method:
  //
  //   public static func buildPartialBlock<
  //     R, WholeMatch, Capture...
  //   >(
  //     first component: Component<R>
  //   ) -> Regex<(Substring, Capture...)>
  //   where Component.Output == (WholeMatch, Capture...),

  @_disfavoredOverload
  public static func buildPartialBlock<R: RegexComponent>(
    first r: Component<R>
  ) -> Regex<Substring>

  public static func buildPartialBlock<W, C0, R: RegexComponent>(
    first r: Component<R>
  ) -> Regex<(Substring, C0)> where R.Output == (W, C0)

  public static func buildPartialBlock<W, C0, C1, R: RegexComponent>(
    first r: Component<R>
  ) -> Regex<(Substring, C0, C1)> where R.Output == (W, C0, C1)

  // ... `O(arity)` overloads of `buildPartialBlock(first:)`

  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single method:
  //
  //   public static func buildPartialBlock<
  //     AccumulatedWholeMatch, NextWholeMatch,
  //     AccumulatedCapture..., NextCapture...,
  //     Accumulated: RegexComponent, Next: RegexComponent
  //   >(
  //     accumulated: Accumulated, next: Component<Next>
  //   ) -> Regex<(Substring, AccumulatedCapture..., NextCapture...)>
  //   where Accumulated.Output == (AccumulatedWholeMatch, AccumulatedCapture...),
  //         Next.Output == (NextWholeMatch, NextCapture...)
  
  public static func buildPartialBlock<W0, W1, C0, R0: RegexComponent, R1: RegexComponent>(
    accumulated: R0, next: Component<R1>
  ) -> Regex<(Substring, C0)> where R0.Output == W0, R1.Output == (W1, C0)
  
  public static func buildPartialBlock<W0, W1, C0, C1, R0: RegexComponent, R1: RegexComponent>(
    accumulated: R0, next: Component<R1>
  ) -> Regex<(Substring, C0, C1)> where R0.Output == W0, R1.Output == (W1, C0, C1)
  
  public static func buildPartialBlock<W0, W1, C0, C1, C2, R0: RegexComponent, R1: RegexComponent>(
    accumulated: R0, next: Component<R1>
  ) -> Regex<(Substring, C0, C1, C2)> where R0.Output == W0, R1.Output == (W1, C0, C1, C2)

  // ... `O(arity^2)` overloads of `buildPartialBlock(accumulated:next:)`
}
```

To support `if #available(...)` statements, `buildLimitedAvailability(_:)` is defined with overloads to support up to 10 captures. The overload for non-capturing regexes, due to the lack of generic constraints, must be annotated with `@_disfavoredOverload` in order not shadow other overloads. We expect that a variadic-generic version of this method will eventually superseded all of these overloads.

```swift
extension RegexComponentBuilder {
  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single method:
  //
  //   public static func buildLimitedAvailability<
  //     Component, WholeMatch, Capture...
  //   >(
  //     _ component: Component
  //   ) where Component.Output == (WholeMatch, Capture...)

  @_disfavoredOverload
  public static func buildLimitedAvailability<R: RegexComponent>(
    _ component: Component<R>
  ) -> Regex<Substring>
  
  public static func buildLimitedAvailability<W, C0, R: RegexComponent>(
    _ component: Component<R>
  ) -> Regex<(Substring, C0?)>
  
  public static func buildLimitedAvailability<W, C0, C1, R: RegexComponent>(
    _ component: Component<R>
  ) -> Regex<(Substring, C0?, C1?)>
  
  // ... `O(arity)` overloads of `buildLimitedAvailability(_:)`
}
```

`buildOptional` and `buildEither` are intentionally not supported due to ergonomic issues and fundamental semantic differences between regex conditionals and result builder conditionals. Please refer to the [alternatives considered](#support-buildoptional-and-buildeither) section for detailed rationale.

### Alternation

Alternations are used to match one of multiple patterns. An alternation wraps its underlying patterns' capture types in an `Optional` and concatenates them together, first to last.

```swift
let choice = ChoiceOf {
  regex1 // Regex<(Substring, Int)>
  regex2 // Regex<(Substring, Float)>
  regex3 // Regex<(Substring, Substring)>
  regex0 // Regex<Substring>
} // => Regex<(Substring, Int?, Float?, Substring?)>
```

`AlternationBuilder` is a result builder type for creating alternations from components of a block.

```swift
@resultBuilder
public struct AlternationBuilder { ... }
```

To the developer, the top-level API is a type named `ChoiceOf`. This type has an initializer that accepts an `@AlternationBuilder` closure.

```swift
public struct ChoiceOf<Output>: RegexComponent {
  public var regex: Regex<Output> { get }
  public init<R: RegexComponent>(
    @AlternationBuilder builder: () -> R
  ) where R.Output == Output
}
```

`AlternationBuilder` is mostly similar to `RegexComponent` with the following distinctions:
- Empty blocks are not supported.
- Capture types are wrapped in a layer of `Optional` before being concatenated in the resulting `Output` type.
- `buildEither(first:)` and `buildEither(second:)` are overloaded for each supported capture arity because they need to wrap capture types in `Optional`.

```swift
@resultBuilder
public enum AlternationBuilder {
  public typealias Component<Value> = RegexComponentBuilder.Component<Value>

  /// Returns a component by wrapping the component regex in `Component` and
  /// recording its source location.
  public static func buildExpression<R: RegexComponent>(
    _ regex: R, 
    file: String = #file, 
    function: String = #function, 
    line: Int = #line,
    column: Int = #column
  ) -> Component<R>

  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single method:
  //
  //   public static func buildPartialBlock<
  //     R, WholeMatch, Capture...
  //   >(
  //     first component: Component<R>
  //   ) -> Regex<(Substring, Capture?...)>
  //   where Component.Output == (WholeMatch, Capture...),

  @_disfavoredOverload
  public static func buildPartialBlock<R: RegexComponent>(
    first r: Component<R>
  ) -> Regex<Substring>

  public static func buildPartialBlock<W, C0, R: RegexComponent>(
    first r: Component<R>
  ) -> Regex<(Substring, C0?)> where R.Output == (W, C0)

  public static func buildPartialBlock<W, C0, C1, R: RegexComponent>(
    first r: Component<R>
  ) -> Regex<(Substring, C0?, C1?)> where R.Output == (W, C0, C1)

  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single method:
  //
  //   public static func buildPartialBlock<
  //     AccumulatedWholeMatch, NextWholeMatch,
  //     AccumulatedCapture..., NextCapture...,
  //     Accumulated: RegexComponent, Next: RegexComponent
  //   >(
  //     accumulated: Accumulated, next: Component<Next>
  //   ) -> Regex<(Substring, AccumulatedCapture..., NextCapture...)>
  //   where Accumulated.Output == (AccumulatedWholeMatch, AccumulatedCapture...),
  //         Next.Output == (NextWholeMatch, NextCapture...)
  
  public static func buildPartialBlock<W0, W1, C0, R0: RegexComponent, R1: RegexComponent>(
    accumulated: R0, next: Component<R1>
  ) -> Regex<(Substring, C0?)>  where R0.Output == W0, R1.Output == (W1, C0)
  
  public static func buildPartialBlock<W0, W1, C0, C1, R0: RegexComponent, R1: RegexComponent>(
    accumulated: R0, next: Component<R1>
  ) -> Regex<(Substring, C0?, C1?)>  where R0.Output == W0, R1.Output == (W1, C0, C1)
  
  public static func buildPartialBlock<W0, W1, C0, C1, C2, R0: RegexComponent, R1: RegexComponent>(
    accumulated: R0, next: Component<R1>
  ) -> Regex<(Substring, C0?, C1?, C2?)> where R0.Output == W0, R1.Output == (W1, C0, C1, C2)

  // ... `O(arity^2)` overloads of `buildPartialBlock(accumulated:next:)`
}

extension AlternationBuilder {
  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single method:
  //
  //   public static func buildLimitedAvailability<
  //     Component, WholeMatch, Capture...
  //   >(
  //     _ component: Component
  //   ) -> Regex<(Substring, Capture?...)>
  //   where Component.Output == (WholeMatch, Capture...)

  @_disfavoredOverload
  public static func buildLimitedAvailability<R: RegexComponent>(
    _ component: Component<R>
  ) -> Regex<Substring>
  
  public static func buildLimitedAvailability<W, C0, R: RegexComponent>(
    _ component: Component<R>
  ) -> Regex<(Substring, C0?)>
  
  public static func buildLimitedAvailability<W, C0, C1, R: RegexComponent>(
    _ component: Component<R>
  ) -> Regex<(Substring, C0?, C1?)>
  
  // ... `O(arity)` overloads of `buildLimitedAvailability(_:)`
  
  public static func buildLimitedAvailability<W, C0, C1, C2, C3, C4, C5, C6, C7, C8, C9, R: RegexComponent>(
    _ component: Component<R>
  ) -> Regex<(Substring, C0?, C1?, C2?, C3?, C4?, C5?, C6?, C7?, C8, C9?)> where R.Output == (W, C0, C1, C2, C3, C4, C5, C6, C7, C8, C9)
}
```

### Quantification

Quantifiers are free functions that take a regex or a `@RegexComponentBuilder` closure that produces a regex. The result is a regex whose `Output` type is the same as the argument's, when the lower bound of quantification is greater than `0`; otherwise, it is an `Optional` thereof.

Quantifiers are generic types that can be created from a regex component. Their `Output` type is inferred from initializers. Each of these types corresponds to a quantifier in the textual regex.

| Quantifier in regex builder | Quantifier in textual regex |
|-----------------------------|-----------------------------|
| `OneOrMore(...)`            | `...+`                      |
| `ZeroOrMore(...)`           | `...*`                      |
| `Optionally(...)`           | `...?`                      |
| `Repeat(..., count: n)`     | `...{n}`                    |
| `Repeat(..., n...)`         | `...{n,}`                   |
| `Repeat(..., n...m)`        | `...{n,m}`                  |

```swift
public struct OneOrMore<Output>: RegexComponent {
  public var regex: Regex<Output> { get }
}

public struct ZeroOrMore<Output>: RegexComponent {
  public var regex: Regex<Output> { get }
}

public struct Optionally<Output>: RegexComponent {
  public var regex: Regex<Output> { get }
}

public struct Repeat<Output>: RegexComponent {
  public var regex: Regex<Output> { get }
}
```

Like quantifiers in textual regexes, the developer can specify how eager the pattern should be matched against using `QuantificationBehavior`. Static properties in `QuantificationBehavior` are named like adverbs for fluency at a quantifier call site.

```swift
/// Specifies how much to attempt to match when using a quantifier.
public struct QuantificationBehavior {
  /// Match as much of the input string as possible, backtracking when
  /// necessary.
  public static var eagerly: QuantificationBehavior { get }
  
  /// Match as little of the input string as possible, expanding the matched
  /// region as necessary to complete a match.
  public static var reluctantly: QuantificationBehavior { get }
  
  /// Match as much of the input string as possible, performing no backtracking.
  public static var possessively: QuantificationBehavior { get }
}
```

Each quantification behavior corresponds to a quantification behavior in the textual regex.

| Quantifier behavior in regex builder | Quantifier behavior in textual regex |
|--------------------------------------|--------------------------------------|
| `.eagerly`                           | no suffix                            |
| `.reluctantly`                       | suffix `?`                           |
| `.possessively`                      | suffix `+`                           |

`OneOrMore` and count-based `Repeat` are quantifiers that produce a new regex with the original capture types. Their `Output` type is `Substring` followed by the component's capture types. `ZeroOrMore`, `Optionally`, and range-based `Repeat` are quantifiers that produce a new regex with optional capture types. Their `Output` type is `Substring` followed by the component's capture types wrapped in `Optional`.

| Quantifier                                           | Component `Output`         | Result `Output`            |
|------------------------------------------------------|----------------------------|----------------------------|
| `OneOrMore`<br>`Repeat(..., count: ...)`             | `(WholeMatch, Capture...)` | `(Substring, Capture...)`  |
| `OneOrMore`<br>`Repeat(..., count: ...)`             | `WholeMatch` (non-tuple)   | `Substring`                |
| `ZeroOrMore`<br>`Optionally`<br>`Repeat(..., n...m)` | `(WholeMatch, Capture...)` | `(Substring, Capture?...)` |
| `ZeroOrMore`<br>`Optionally`<br>`Repeat(..., n...m)` | `WholeMatch` (non-tuple)   | `Substring`                |

Due to the lack of variadic generics, these functions must be overloaded for every supported capture arity.

```swift
extension OneOrMore {
  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single set of methods:
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture...
  //   >(
  //     _ component: Component,
  //     _ behavior: QuantificationBehavior = .eagerly
  //   )
  //   where Output == (Substring, Capture...)>,
  //         Component.Output == (WholeMatch, Capture...)
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture...
  //   >(
  //     _ behavior: QuantificationBehavior = .eagerly,
  //     @RegexComponentBuilder _ component: () -> Component
  //   )
  //   where Output == (Substring, Capture...),
  //         Component.Output == (WholeMatch, Capture...)

  @_disfavoredOverload
  public init<Component: RegexComponent>(
    _ component: Component,
    _ behavior: QuantificationBehavior = .eagerly
  ) where Output == Substring
  
  @_disfavoredOverload
  public init<Component: RegexComponent>(
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == Substring
  
  public init<W, C0, Component: RegexComponent>(
    _ component: Component,
    _ behavior: QuantificationBehavior = .eagerly
  ) where Output == (Substring, C0), Component.Output == (W, C0)
  
  public init<W, C0, Component: RegexComponent>(
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == (Substring, C0), Component.Output == (W, C0)
  
  // ... `O(arity)` overloads
}

extension ZeroOrMore {
  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single set of methods:
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture...
  //   >(
  //     _ component: Component,
  //     _ behavior: QuantificationBehavior = .eagerly
  //   )
  //   where Output == (Substring, Capture?...)>,
  //         Component.Output == (WholeMatch, Capture...)
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture...
  //   >(
  //     _ behavior: QuantificationBehavior = .eagerly,
  //     @RegexComponentBuilder _ component: () -> Component
  //   )
  //   where Output == (Substring, Capture?...),
  //         Component.Output == (WholeMatch, Capture...)

  @_disfavoredOverload
  public init<Component: RegexComponent>(
    _ component: Component,
    _ behavior: QuantificationBehavior = .eagerly
  ) where Output == Substring
  
  @_disfavoredOverload
  public init<Component: RegexComponent>(
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == Substring
  
  public init<W, C0, Component: RegexComponent>(
    _ component: Component,
    _ behavior: QuantificationBehavior = .eagerly
  ) where Output == (Substring, C0?), Component.Output == (W, C0)
  
  public init<W, C0, Component: RegexComponent>(
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == (Substring, C0?), Component.Output == (W, C0)
  
  // ... `O(arity)` overloads
}

extension Optionally {
  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single set of methods:
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture...
  //   >(
  //     _ component: Component,
  //     _ behavior: QuantificationBehavior = .eagerly
  //   )
  //   where Output == (Substring, Capture?...),
  //         Component.Output == (WholeMatch, Capture...)
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture...
  //   >(
  //     _ behavior: QuantificationBehavior = .eagerly,
  //     @RegexComponentBuilder _ component: () -> Component
  //   )
  //   where Output == (Substring, Capture?...)>,
  //         Component.Output == (WholeMatch, Capture...)
  
  @_disfavoredOverload
  public init<Component: RegexComponent>(
    _ component: Component,
    _ behavior: QuantificationBehavior = .eagerly
  ) where Output == Substring
  
  @_disfavoredOverload
  public init<Component: RegexComponent>(
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == Substring
  
  public init<W, C0, Component: RegexComponent>(
    _ component: Component,
    _ behavior: QuantificationBehavior = .eagerly
  ) where Output == (Substring, C0?), Component.Output == (W, C0)
  
  public init<W, C0, Component: RegexComponent>(
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == (Substring, C0?), Component.Output == (W, C0)
  
  // ... `O(arity)` overloads
}

extension Repeat {
  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single set of methods:
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture...
  //   >(
  //     _ component: Component,
  //     count: Int,
  //     _ behavior: QuantificationBehavior = .eagerly
  //   )
  //   where Output == (Substring, Capture...),
  //         Component.Output == (WholeMatch, Capture...)
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture...
  //   >(
  //     count: Int,
  //     _ behavior: QuantificationBehavior = .eagerly,
  //     @RegexComponentBuilder _ component: () -> Component
  //   )
  //   where Output == (Substring, Capture...),
  //         Component.Output == (WholeMatch, Capture...)
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture..., RE: RangeExpression
  //   >(
  //     _ component: Component,
  //     _ expression: RE,
  //     _ behavior: QuantificationBehavior = .eagerly
  //   )
  //   where Output == (Substring, Capture?...),
  //         Component.Output == (WholeMatch, Capture...)
  //
  //   public init<
  //     Component: RegexComponent, WholeMatch, Capture..., RE: RangeExpression
  //   >(
  //     _ expression: RE,
  //     _ behavior: QuantificationBehavior = .eagerly,
  //     @RegexComponentBuilder _ component: () -> Component
  //   )
  //   where Output == (Substring, Capture?...),
  //         Component.Output == (WholeMatch, Capture...)
  
  // Nullary

  @_disfavoredOverload
  public init<Component: RegexComponent>(
    _ component: Component,
    count: Int,
    _ behavior: QuantificationBehavior = .eagerly
  ) where Output == Substring, R.Bound == Int
  
  @_disfavoredOverload
  public init<Component: RegexComponent>(
    count: Int,
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == Substring, R.Bound == Int
  
  @_disfavoredOverload
  public init<Component: RegexComponent, RE: RangeExpression>(
    _ component: Component,
    _ expression: RE,
    _ behavior: QuantificationBehavior = .eagerly
  ) where Output == Substring, R.Bound == Int
  
  @_disfavoredOverload
  public init<Component: RegexComponent, RE: RangeExpression>(
    _ expression: RE,
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == Substring, R.Bound == Int
  
  
  // Unary

  public init<W, C0, Component: RegexComponent>(
    _ component: Component,
    count: Int,
    _ behavior: QuantificationBehavior = .eagerly
  )
  where Output == (Substring, C0),
        Component.Output == (Substring, C0),
        R.Bound == Int
  
  public init<W, C0, Component: RegexComponent>(
    count: Int,
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  )
  where Output == (Substring, C0),
        Component.Output == (Substring, C0),
        R.Bound == Int
  
  public init<W, C0, Component: RegexComponent, RE: RangeExpression>(
    _ component: Component,
    _ expression: RE,
    _ behavior: QuantificationBehavior = .eagerly
  )
  where Output == (Substring, C0?),
        Component.Output == (W, C0),
        R.Bound == Int
  
  public init<W, C0, Component: RegexComponent, RE: RangeExpression>(
    _ expression: RE,
    _ behavior: QuantificationBehavior = .eagerly,
    @RegexComponentBuilder _ component: () -> Component
  )
  where Output == (Substring, C0?),
        Component.Output == (W, C0),
        R.Bound == Int
  
  // ... `O(arity)` overloads
}
```

### Capture and reference

`Capture` and `TryCapture` produce a new `Regex` by inserting the captured pattern's whole match (`.0`) to the `.1` position of `Output`. When a transform closure is provided, the whole match of the captured content will be transformed to using the closure.

```swift
public struct Capture<Output>: RegexComponent {
  public var regex: Regex<Output> { get }
}

public struct TryCapture<Output>: RegexComponent {
  public var regex: Regex<Output> { get }
}
```

The difference between `Capture` and `TryCapture` is that `TryCapture` works better with transform closures that can return `nil` or throw, whereas `Capture` relies on the user to handle errors within a transform closure. With `TryCapture`, when the closure returns `nil` or throws, the failure becomes a no-match.
  
```swift
// Below are `Capture` and `TryCapture` initializer variants on capture arity 0.
// Higher capture arities are omitted for simplicity.
  
extension Capture {
  public init<R: RegexComponent, W>(
    _ component: R
  ) where Output == (Substring, W), R.Output == W
  
  public init<R: RegexComponent, W>(
    _ component: R, as reference: Reference<W>
  ) where Output == (Substring, W), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    _ component: R,
    transform: @escaping (Substring) -> NewCapture
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    _ component: R,
    as reference: Reference<NewCapture>,
    transform: @escaping (Substring) -> NewCapture
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W>(
    @RegexComponentBuilder _ component: () -> R
  ) where Output == (Substring, W), R.Output == W
  
  public init<R: RegexComponent, W>(
    as reference: Reference<W>,
    @RegexComponentBuilder _ component: () -> R
  ) where Output == (Substring, W), R.Output == W
}
  
extension TryCapture {
  public init<R: RegexComponent, W, NewCapture>(
    _ component: R,
    transform: @escaping (Substring) throws -> NewCapture
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    _ component: R,
    as reference: Reference<NewCapture>,
    transform: @escaping (Substring) throws -> NewCapture
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    _ component: R,
    transform: @escaping (Substring) -> NewCapture?
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    _ component: R,
    as reference: Reference<NewCapture>,
    transform: @escaping (Substring) -> NewCapture?
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    @RegexComponentBuilder _ component: () -> R,
    transform: @escaping (Substring) -> NewCapture
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    as reference: Reference<NewCapture>,
    @RegexComponentBuilder _ component: () -> R,
    transform: @escaping (Substring) throws -> NewCapture
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    @RegexComponentBuilder _ component: () -> R,
    transform: @escaping (Substring) -> NewCapture?
  ) where Output == (Substring, NewCapture), R.Output == W
  
  public init<R: RegexComponent, W, NewCapture>(
    as reference: Reference<NewCapture>,
    @RegexComponentBuilder _ component: () -> R,
    transform: @escaping (Substring) -> NewCapture?
  ) where Output == (Substring, NewCapture), R.Output == W

  // ... `O(arity)` overloads
}
```

Example:

```swift
let regex = Regex {
  OneOrMore("a")
  Capture {
    TryCapture("b") { Int($0) }
    ZeroOrMore {
      TryCapture("c") { Double($0) }
    }
    Optionally("e")
  }
}
```

Variants of `Capture` and `TryCapture` accept a `Reference` argument. References can be used to achieve named captures and named backreferences from textual regexes.

```swift
/// A reference to a regex capture.
public struct Reference<Capture>: RegexComponent {
  public init(_ captureType: Capture.Type = Capture.self)
  public var regex: Regex<Capture>
}

extension Regex.Match {
  /// Returns the capture referenced by the given reference.
  ///
  /// - Precondition: The reference must have been captured in the regex that produced this match.
  public subscript<Capture>(_ reference: Reference<Capture>) -> Capture { get }
}
```

When capturing some regex with a reference specified, the reference will refer to the most recently captured content. The reference itself can be used as a regex to match the most recently captured content, or as a name to look up the result of matching.

```swift
let a = Reference(Substring.self)
let b = Reference(Substring.self)
let regex = Regex {
  Capture("abc", as: a)
  Capture("def", as: b)
  a
  Capture(b)
}

if let result = input.firstMatch(of: regex) {
  print(result[a]) // => "abc"
  print(result[b]) // => "def"
}
```

A regex is considered invalid when it contains a use of reference without it ever being captured in the regex. When this occurs in the regex builder DSL, a runtime error will be reported. Similarly, the use of a reference in a `Regex.Match.subscript(_:)` must have been captured in the regex that produced the match.

### Subpattern

In textual regex, one can refer to a subpattern to avoid duplicating the subpattern, for example:

```
(you|I) say (goodbye|hello); (?1) say (?2)
```

The above regex is equivalent to

```
(you|I) say (goodbye|hello); (you|I) say (goodbye|hello)
```

With regex builder, there is no special API required to reuse existing subpatterns, as a subpattern can be defined modularly using a `let` binding inside or outside a regex builder closure.

```swift
Regex {
  let subject = ChoiceOf {
    "I"
    "you"
  }
  let object = ChoiceOf {
    "goodbye"
    "hello"
  }
  subject
  "say"
  object
  ";"
  subject
  "say"
  object
}
```

### Scoping

In textual regexes, atomic groups (`(?>...)`) can be used to define a backtracking scope. That is, when the regex engine exits from the scope successfully, it throws away all backtracking positions from the scope. In regex builder, the `Local` type serves this purpose.

```swift
public struct Local<Output>: RegexComponent {
  public var regex: Regex<Output>

  // The following builder methods implement what would be possible with
  // variadic generics (using imaginary syntax) as a single set of methods:
  //
  //   public init<WholeMatch, Capture..., Component: RegexComponent>(
  //     @RegexComponentBuilder _ component: () -> Component
  //   ) where Output == (Substring, Capture...), Component.Output == (WholeMatch, Capture...)

  @_disfavoredOverload
  public init<Component: RegexComponent>(
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == Substring

  public init<W, C0, Component: RegexComponent>(
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == (Substring, C0), Component.Output == (W, C0)
  
  public init<W, C0, C1, Component: RegexComponent>(
    @RegexComponentBuilder _ component: () -> Component
  ) where Output == (Substring, C0, C1), Component.Output == (W, C0, C1)
  
  // ... `O(arity)` overloads
}
```

For example, the following regex matches string `abcc` but not `abc`.

```swift
Regex {
  "a"
  Local {
    ChoiceOf {
      "bc"
      "b"
    }
  }
  "c"
}
```

## Source compatibility

Regex builder will be shipped in a new module named `RegexBuilder`, and thus will not affect the source compatibility of the existing code.

## Effect on ABI stability

The proposed feature does not change the ABI of existing features.

## Effect on API resilience

The proposed feature relies heavily upon overloads of `buildBlock` and `buildPartialBlock(accumulated:next:)` to work for different capture arities. In the fullness of time, we are hoping for variadic generics to supercede existing overloads. Such a change should not involve ABI-breaking modifications as it is merely a change of overload resolution.

## Future directions

### Conversion to textual regex

Sometimes it may be useful to convert a regex created using regex builder to textual regex. This may be achieved in the future by extending `RegexComponent` with a computed property.

```swift
extension RegexComponent {
  public func makeTextualRegex() -> String?
}
```

It is worth noting that the internal representation of a `Regex` is _not_ textual regex, but an efficient pattern matching bytecode compiled from an abstract syntax tree. Moreover, not every `Regex` can be converted to textual regex. Regex builder supports arbitrary types that conform to the `RegexComponent` protocol, including `CustomMatchingRegexComponent` (pitched in [String Processing Algorithms]) which can be implemented with arbitrary code. If a `Regex` contains a `CustomMatchingRegexComponent`, it cannot be converted to textual regex.

### Recursive subpatterns

Sometimes, a textual regex may also use `(?R)` or `(?0)` to recusively evaluate the entire regex. For example, the following textual regex matches "I say you say I say you say hello".

```
(you|I) say (goodbye|hello|(?R))
```

For this, `Regex` offers a special initializer that allows its pattern to recursively reference itself. This is somewhat akin to a fixed-point combinator.

```swift
extension Regex {
  public init<R: RegexComponent>(
    @RegexComponentBuilder _ content: (Regex<Substring>) -> R
  ) where R.Output == Match
}
```

With this initializer, the above regex can be expressed as the following using regex builder.

```swift
Regex { wholeSentence in
  ChoiceOf {
   "I"
   "you"
  }
  "say"
  ChoiceOf {
    "goodbye"
    "hello"
    wholeSentence
  }
}
```

There are some concerns with this design which we need to consider:
- Due to the lack of labeling, the argument to the builder closure can be arbitrarily named and cause confusion.
- When there is an initializer that accepts a result builder closure, overloading that initializer with the same argument labels could lead to bad error messages upon interor type errors.

## Alternatives considered

### Operators for quantification and alternation

While `ChoiceOf` and quantifier types provide a general way of creating alternations and quantifications, we recognize that some synctactic sugar can be useful for creating one-liners like in textual regexes, e.g. infix operator `|`, postfix operator `*`, etc.

```swift
// The following functions implement what would be possible with variadic
// generics (using imaginary syntax) as a single function:
//
//   public func | <
//     R0: RegexComponent, R1: RegexComponent,
//     WholeMatch0, WholeMatch1, 
//     Capture0..., Capture1...
//   >(
//     _ r0: RegexComponent,
//     _ r1: RegexComponent
//   ) -> Regex<(Substring, Capture0?..., Capture1?...)>
//     where R0.Output == (WholeMatch0, Capture0...),
//           R1.Output == (WholeMatch1, Capture1...)

@_disfavoredOverload
public func | <R0, R1>(lhs: R0, rhs: R1) -> Regex<Substring> where R0: RegexComponent, R1: RegexComponent {

public func | <R0, R1, W1, C0>(lhs: R0, rhs: R1) -> Regex<(Substring, C0?)> where R0: RegexComponent, R1: RegexComponent, R1.Output == (W1, C0)

public func | <R0, R1, W1, C0, C1>(lhs: R0, rhs: R1) -> Regex<(Substring, C0?, C1?)> where R0: RegexComponent, R1: RegexComponent, R1.Output == (W1, C0, C1)

// ... `O(arity^2)` overloads.
```

However, like `RegexComponentBuilder.buildPartialBlock(accumulated:next:)`, operators such as `|`, `+`, `*`, `.?` require a large number of overloads to work with regexes of every capture arity, compounded by the fact that operator type checking is prone to performance issues in Swift. Here is a list of

| Opreator      | Meaning                   | Required number of overloads |
|---------------|---------------------------|------------------------------|
| Infix `\|`    | Choice of two             | `O(arity^2)`                 |
| Postfix `*`   | Zero or more eagerly      | `O(arity)`                   |
| Postfix `*?`  | Zero or more reluctantly  | `O(arity)`                   |
| Postfix `*+`  | Zero or more possessively | `O(arity)`                   |
| Postfix `+`   | One or more eagerly       | `O(arity)`                   |
| Postfix `+?`  | One or more reluctantly   | `O(arity)`                   |
| Postfix `++`  | One or more possessively  | `O(arity)`                   |
| Postfix `.?`  | Optionally eagerly        | `O(arity)`                   |
| Postfix `.??` | Optionally reluctantly    | `O(arity)`                   |
| Postfix `.?+` | Optionally possessively   | `O(arity)`                   |

 When variadic generics are supported in the future, we may be able to define one function per operator and reduce type checking burdens.
 
### Postfix `capture` and `tryCapture` methods

An earlier iteration of regex builder declared `capture` and `tryCapture` as methods on `RegexComponent`, meaning that you can append `.capture(...)` to any subpattern within a regex to capture it. For example:

```swift
Regex {
  OneOrMore {
    r0.capture()
    r1
  }.capture()
} // => Regex<(Substring, Substring, Substring)>
```

However, there are two shortcomings of this design:

1. When a subpattern to be captured contains multiple components, the developer has to explicitly group them using a `Regex { ... }` block.

    ```swift
    let emailPattern = Regex {
      let word = OneOrMore(.word)
      Regex { // <= Had to explicitly group multiple components
        ZeroOrMore {
          word
          "."
        }
        word
      }.capture()
      "@"
      Regex {
        word
        OneOrMore {
          "."
          word
        }
      }.capture()
    } // => Regex<(Substring, Substring, Substring)>
    ```

2. When there are nested captures, it is harder to number the captures visually because the order `capture()` appears is flipped in the postfix (method) notation.

    ```swift
    let emailSuffixPattern = Regex {
      "@"
      Regex {
        word
        OneOrMore {
          "."
          word.capture() // top-level domain (.0)
        }
      }.capture() // full domain (.1)
    } // => Regex<(Substring, Substring, Substring)>
      //
      //          full domain ^~~~~~~~~
      //                top-level domain ^~~~~~~~~
    ```
    
    In comparison, prefix notation (`Capture` and `TryCapture` as a types) makes it easier to visually capture captures as you can number captures in the order they appear from top to bottom. This is consistent with textual regexes where capturing groups are numbered by the left parenthesis of the group from left to right.

    ```swift
    let emailSuffixPattern = Regex {
      Capture { // full domain (.0)
        word
        OneOrMore {
          "."
          Capture(word) // top-level domain (.1)
        }
      }
    } // => Regex<(Substring, Substring, Substring)>
      //
      //          full domain ^~~~~~~~~
      //                top-level domain ^~~~~~~~~
    ```
  
### Unify quantifiers under `Repeat`

Since `Repeat` is the most general version of quantifiers, one could argue for all quantifiers to be unified under the type `Repeat`, for example:

```swift
Repeat(oneOrMore: r)
Repeat(zeroOrMore: r)
Repeat(optionally: r)
```

However, given that one-or-more (`+`), zero-or-more (`*`) and optional (`?`) are the most common quantifiers in textual regexes, we believe that these quantifiers deserve their own type and should be written as a single word instead of two. This can also reduce visual clutter when the quantification is used in multiple places of a regex.

### Free functions instead of types

One could argue that type such as `OneOrMore<Output>` could be defined as a top-level function that returns `Regex`. While it is entirely possible to do so, it would lose the name scoping benefits of a type and pollute the top-level namespace with `O(arity^2)` overloads of quantifiers, `capture`, `tryCapture`, etc. This could be detrimental to the usefulness of code completion.

Another reason to use types instead of free functions is consistency with existing result-builder-based DSLs such as SwiftUI.

### Support `buildOptional` and `buildEither`

To support `if` statements, an earlier iteration of this proposal defined `buildEither(first:)`, `buildEither(second:)` and `buildOptional(_:)` as the following:

```swift
extension RegexComponentBuilder {
  public static func buildEither<
    Component, WholeMatch, Capture...
  >(
    first component: Component
  ) -> Regex<(Substring, Capture...)>
  where Component.Output == (WholeMatch, Capture...)

  public static func buildEither<
    Component, WholeMatch, Capture...
  >(
    second component: Component
  ) -> Regex<(Substring, Capture...)>
  where Component.Output == (WholeMatch, Capture...)

  public static func buildOptional<
    Component, WholeMatch, Capture...
  >(
    _ component: Component?
  ) where Component.Output == (WholeMatch, Capture...)
}
```

However, multiple-branch control flow statements (e.g. `if`-`else` and `switch`) would need to be required to produce either the same regex type, which is limiting, or an "either-like" type, which can be difficult to work with when nested. Unlike `ChoiceOf`, producing a tuple of optionals is not an option, because the branch taken would be decided when the builder closure is executed, and it would cause capture numbering to be inconsistent with conventional regex.

Moreover, result builder conditionals does not work the same way as regex conditionals.  In regex conditionals, the conditions are themselves regexes and are evaluated by the regex engine during matching, whereas result builder conditionals are evaluated as part of the builder closure.  We hope that a future result builder feature will support "lifting" control flow conditions into the DSL domain, e.g. supporting `Regex<Bool>` as a condition.

### Flatten optionals

With the proposed design, `ChoiceOf` with `AlternationBuilder` wraps every component's capture type with an `Optional`. This means that any `ChoiceOf` with optional-capturing components would lead to a doubly-nested optional captures. This could make the result of matching harder to use.

```swift
ChoiceOf {
  OneOrMore(Capture(.digit)) // Output == (Substring, Substring)
  Optionally {
    ZeroOrMore(Capture(.word)) // Output == (Substring, Substring?)
    "a"
  } // Output == (Substring, Substring??)
} // Output == (Substring, Substring?, Substring???)
```

One way to improve this could be overloading quantifier initializers (e.g. `ZeroOrMore.init(_:)`) and `AlternationBuilder.buildPartialBlock` to flatten any optionals upon composition. However, this would be non-trivial. Quantifier initializers would need to be overloaded `O(2^arity)` times to account for all possible positions of `Optional` that may appear in the `Output` tuple. Even worse, `AlternationBuilder.buildPartialBlock` would need to be overloaded `O(arity!)` times to account for all possible combinations of two `Output` tuples with all possible positions of `Optional` that may appear in one of the `Output` tuples.

### Structured rather than flat captures

We propose inferring capture types in such a way as to align with the traditional numbering of backreferences. This is because much of the motivation behind providing regex in Swift is their familiarity.

If we decided to deprioritize this motivation, there are opportunities to infer safer, more ergonomic, and arguably more intuitive types for captures. For example, to be consistent with traditional regex backreferences quantifications of multiple or nested captures had to produce parallel arrays rather than an array of tuples.

```swift
OneOrMore {
  Capture {
    OneOrMore(.hexDigit)
  }
  ".."
  Capture {
    OneOrMore(.hexDigit)
  }
}

// Flat capture types:
// => `Output == (Substring, Substring, Substring)>`

// Structured capture types:
// => `Output == (Substring, (Substring, Substring))`
```

Similarly, an alternation of multiple or nested captures could produce a structured alternation type (or an anonymous sum type) rather than flat optionals.

This is cool, but it adds extra complexity to regex builder and it isn't as clear because the generic type no longer aligns with the traditional regex backreference numbering. We think the consistency of the flat capture types trumps the added safety and ergonomics of the structured capture types.


[Declarative String Processing]: https://github.com/apple/swift-experimental-string-processing/blob/main/Documentation/DeclarativeStringProcessing.md
[Strongly Typed Regex Captures]: https://github.com/apple/swift-experimental-string-processing/blob/main/Documentation/Evolution/StronglyTypedCaptures.md
[Regex Syntax]: https://github.com/apple/swift-experimental-string-processing/blob/main/Documentation/Evolution/RegexSyntax.md
[String Processing Algorithms]: https://github.com/apple/swift-experimental-string-processing/blob/main/Documentation/Evolution/StringProcessingAlgorithms.md
