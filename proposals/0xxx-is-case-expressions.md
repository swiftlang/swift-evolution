# `is case` expressions

* Proposal: [SE-0XXX](0XXX-is-case-expressions.md)
* Authors: [Cal Stephens](https://github.com/calda), [Matthew Cheok](https://github.com/matthewcheok)
* Review Manager: TBD
* Status: **Implementation available**
* Implementation: [apple/swift#XXX](https://github.com/apple/swift/pull/XXX), including a downloadable toolchain.
* Review: ([draft proposal](https://forums.swift.org/t/proposal-draft-for-is-case-pattern-match-boolean-expressions/58260))

## Introduction

Users regularly ask for an easy way to test if an enum matches a particular case, even if the enum is not Equatable, or if the case in question has payloads. A quick search of the forums turned up [threads as old as 2015](https://forums.swift.org/t/allowing-non-binding-pattern-matching-as-a-bool-expression/294/2) asking about this---that is, about as old as the open source project itself.

## Motivation

Currently to test if an enum matches a specific case, the two main alternatives are to write a test via a `switch` statement or an `if case let`:

```swift
let result = switch <expr> {
  case <pattern>: true
  default: false
}
```

```swift
let result = if case <pattern> = <expr> { true } else { false }
```

In both cases, until recently the result needs to be first stored in a local variable before it can be used in subsequent more complex expressions. With the introduction of `if` and `switch` expressions ([SE-390](https://github.com/apple/swift-evolution/blob/main/proposals/0380-if-switch-expressions.md)), this is somewhat mitigated but it still results in code that is potentially difficult to parse at a glance.

Several options are discussed in the Alternatives considered section below. They fall into 2 buckets and describe:

1. **Work-arounds for manual or generated code**
This is code that is manually-written, code-generated, or necessitates the use of a [macro](https://forums.swift.org/t/proposal-draft-for-is-case-pattern-match-boolean-expressions/58260/65) to make subsequent uses of this test more egronomic to use.

2. **Additions or changes to the grammar of Swift** Additional syntax that allows testing if an enum matches a particular case to be written concisely and clearly.

We propose the following addition the grammar that includes a new expression, `<expr> is case <pattern>`, that evaluates to true or false based on whether `<expr>` matches `<pattern>`. This allows for an easy and concise way to describe a pattern test inline.

## Detailed Design

The Swift grammar gains a new expression production:

```swift
infix-expression -> is case <pattern>
```
The pattern must not have a trailing type-annotation, and recursively must not contain a value-binding-pattern (see Future Directions below).

`<expr> is case <pattern>` should be considered equivalent to the following code:

```swift
({ () -> Bool in
  switch <expr> {
  case <pattern>: return true
  default: return false
  }
})()
```

The use of `<pattern>` allows a broader set of tests in addition to testing if an enum matches a particular case. This allows for the following uses:
- `foo is case .bar` (enum case)
- `foo is case .bar(42)` (enum case with associated values)
- `foo is case .bar(42, _)` (enum case with partially matched associated values)
- `for is case 42` (integer literal)
- `foo is case true` (boolean literal)
- `foo is case "A string"` (string literal)
- `foo is case bar` (other expression)

This syntax can also be extended by overloading the `~=` operator just as in within `switch` statements.

## Precedence
By analogy with `<expr> is <type>`, this expression should be usable within `&&`/`||` chains. That is, `x && y is case .z && w` should be equivalent to `x && (y is case .z) && w`. At the same time, other binary operators need to bind more tightly: `x is case y ..< z` should be interpreted as `x is case (y ..< z)`. This behavior is already implemented for chains of infix-expressions using precedence, but adding expression-patterns to the mix may be tricky to implement.

Open question: should `x ?? y is case .z` be treated as `x ?? (y is case .z)` or `(x ?? y) is case .z`? The former matches `is`'s CastingPrecedence, designed around `as?`, but the latter is still an option, and both have plausible uses: `alwaysDark ?? (systemMode is case .dark)` vs `(overriddenMode ?? systemMode) is case .dark`. The precedence of `is case` should be higher than `ComparisonPrecedence` no matter what, though.

If the pattern is known to always or never match the expression at compile time, the compiler should emit a warning. This includes "irrefutable" patterns that merely destructure their expression; these are not significantly different from type-casting patterns that are statically known to be upcasts, or values known to be out of range through constant propagation.

## Source compatibility and ABI
This is an additive change to expression syntax that requires no additional runtime support; it has no source- or binary-compatibility implications beyond not being available in earlier versions of the compiler.

## Alternatives considered

### Do nothing
[SE-390](https://github.com/apple/swift-evolution/blob/main/proposals/0380-if-switch-expressions.md) allowed control-flow statements to be treated as expressions, and you could implement this with `if case <pattern> = <expr> { true } else { false }`, without having to wrap in a closure-like expansion above. However, this is still pretty verbose, and even Rust, which has generalized control-flow expressions, still provides a `matches!` macro in its standard library. 

### Per-case optional properties
For years now there's been an idea that for case foo(bar: Int, baz: Int), the compiler could synthesize some or all of the following computed instance properties:

- `isFoo: Bool`
- `asFoo: (bar: Int, baz: Int)?`
- `bar: Int?`
- `bar: Int (if every case has a field bar: Int)`

This would handle the most common use for `is case`, checking if a value with known enum type has a particular case. However, it does not cover all the use cases, such as matching nested values. Even if such a feature is proposed and accepted through the evolution process, `is case` would still be useful.

### `case <pattern> = <expr>`
There have been a handful of other proposed spellings over the years, most notably `case <pattern> = <expr>`, by analogy with the existing `if case`. However, while this syntax is not likely to be ambiguous in practice, it does suffer from the main flaw of if case: the pattern comes first and therefore cannot be code-completed from the expression when typed left-to-right. The single `=` also suggests assignment even though the result is a boolean.

### `<expr> case <pattern>`
This is more concise, but would make it harder to parse switch statements:

```swift
  doSomething()
case is UIButton // missing colon
  doSomethingElse()
```

While this example is contrived, it shows how the compiler would have to jump through extra hoops to understand incomplete or erroneous code. So it's a good thing no one has seriously suggested this.

### Special-case `==` or `~=`
People like using `==` to compare non-payload cases, and `~=` is already used to match expression patterns. We could change the compiler to treat these differently from normal operators, allowing `<expr> == <pattern>` or `<pattern> ~= <expr>`. I'm personally not a fan of this, but I can't think of an inherent reason why it wouldn't work for enum cases. I'm hesitant to use `==` when other forms of matching are involved, but `~=` doesn't have that problem. It does, however, put the pattern on the left (established by existing implementations of the operator function), which again is sub-optimal for code completion. From a learning perspective, operators are also generally a bit harder to read and search for.

### Change `is`
In theory, the existing cast-testing syntax `<expr>` is `<type>` could be expanded to `<expr>` is `<pattern>`, with `<expr>` is `<type>` effectively becoming sugar for `expr is` (`is <type>`). This makes a very satisfying, compact syntax for pattern-matching as a boolean expression... but may add confusion around pattern matching in switch statements, where `case <type>` is disallowed, and `case <type>.self` is an expression pattern. I don't think there's an actual conflict here, but only because of the requirement that types-as-values be adorned with `.self`. Without that, `case is <type>` would check runtime casting, but `case <type>` would invoke custom expression matching, if an appropriate match operator is defined. ([SE-0090](https://github.com/apple/swift-evolution/blob/main/proposals/0090-remove-dot-self.md) proposed to lift this restriction, but was deferred.)

Additionally, because there's an implementation of expression pattern matching that uses Equatable, we run into the risk of adding x is y to the existing `x == y` and `x === y`. Having too many notions of equality makes the language harder to learn, as well as making it easier to accidentally pick the wrong one.

`is case` sidesteps all these issues, and doesn't preclude shortening to plain `is` later if we decide the upsides outweigh the downsides.

### Wait for a Grand Unifying Pattern-Matching Proposal
There are a good handful of places where Swift's existing pattern-matching falls short, including `if case` as discussed above, the verbosity of `let` in patterns where `case` is already present, the lack of destructuring support for structs and classes due to library evolution principles, and the inability for expression-matching to generate bindings. Proposals to address some or all of these issues, especially the last, might come with a new syntax for pattern matching that makes sense in and outside of flow control. Adding `is case` does not help with these larger issues; it's only a convenience for a particular use case.

This is all true, and yet at the same time this feature has been proposed every year since Swift went open source (see the Acknowledgments below). If something else supersedes it in the future, that's all right; its existence will still have saved time and energy for many a developer.

## Acknowledgments
[Jordan Rose](https://belkadan.com/blog) wrote a draft proposal for which this proposal builds upon.

Andrew Bennett was the first person who suggested the spelling is case for this operation, way back in [2015](https://forums.swift.org/t/allowing-non-binding-pattern-matching-as-a-bool-expression/294/2).

Alex Lew ([2015](https://forums.swift.org/t/allowing-non-binding-pattern-matching-as-a-bool-expression/294/2)), Sam Dods ([2016](https://forums.swift.org/t/proposal-treat-case-foo-bar-as-a-boolean-expression/2546)), Tamas Lustyik ([2017](https://forums.swift.org/t/testing-enum-cases-with-associated-values/7091)), Suyash Srijan ([2018](https://forums.swift.org/t/comparing-enums-without-their-associated-values/18944)), Owen Voorhees ([2019](https://forums.swift.org/t/pitch-case-expressions-for-pattern-matching/20348)), Ilias Karim ([2020](https://forums.swift.org/t/proposal-sanity-check-assigning-a-case-statement-to-a-boolean/40584)), and Michael Long ([2021](https://forums.swift.org/t/enumeration-case-evaluates-as-boolean/54266)) have brought up this "missing feature" in the past, often generating good discussion. (There may have been more that we missed as well, and this isn't even counting "Using Swift" threads!)

Jon Hull ([2018](https://forums.swift.org/t/if-case-in/15000)), among others, for related discussion on restructuring if case.