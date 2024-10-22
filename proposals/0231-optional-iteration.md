# Optional Iteration

* Proposal: [SE-0231](0231-optional-iteration.md)
* Author: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Rejected**
* Implementation: [apple/swift#19207](https://github.com/apple/swift/pull/19207)
* Decision Notes: [Rationale](https://forums.swift.org/t/rejected-se-0231-optional-iteration/17805)

## Introduction

Optionals are a key feature of Swift and a powerful tool that seamlessly interacts with code. In particular, they serve a great means in expressing "act accordingly if there's a value, skip otherwise". Some vivid examples of such behavior are optional chaining, optional invocation `foo?()`, `if let`, [optional patterns](https://docs.swift.org/swift-book/ReferenceManual/Patterns.html#grammar_optional-pattern), optional assignments and `guard let`. This proposal considers further supporting this convenience in `for-in` loops.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/another-try-at-allowing-optional-iteration/14376?u=anthonylatsis)

## Motivation

Most Swift statements provide convenience patterns and handling for optionals. We have optional binding patterns for `while`, `if` and `guard`. Consider `switch`, that can be used directly on an optional to match against the unwrapped value. Nevertheless, it is important to keep in mind that exhaustiveness still applies, that is, the `nil` case must also be handled either explicitly or via the `default` clause:

```swift
let str: Int? = nil

switch str {
case 0: print()
case 1: print()
default: print()
}
```

Optional patterns bring a succinct way of handling the `.some` case when optional binding is unavailable:

```swift
for case let unwrapped? in sequence { ... }
```

Optional assignment lets you skip an assignment if the lvalue is nil, sparing the need to write an entire `if-else` or deal with access exclusivity when using the ternary operator. A very useful albeit sparsely documented feature.

```swift
var ages = ["Amy" : 30, "Graham" : 5]
ages["Anthony"]? = 21
ages["Graham"]? = 6
print(ages) // ["Amy" : 30, "Graham" : 6]
``` 

Loops are a common statement in almost every codebase. Similarly, a possibility to optionally iterate over a sequence (iterate if there is a value, otherwise skip) when the `nil` case is of no interest is self-explanatory. While usage of optional sequences is often treated as misconception, there are several common ways one could end up with an optional sequence through Standard Library APIs and language constructs themselves. Amongst the most prevalent are optional chaining and dictionary getters. An indentation-sensitive area of which optional arrays are an integral part is decoding and deserialization, i.e parsing a JSON response.
Swift currently doesn't offer a mechanism for expressing optional iteration directly: optional sequences are illegal as a `for-in` loop argument. For a safe option, developers often resort to optional binding, which requires additional nesting:

```swift
if let sequence = optionalSequence {
  for element in sequence { ... }
}
```
There are several workarounds to avoid that extra level of indentation, none of which can be called a general solution:
* `guard` is a pretty straight-forward option for a simple scenario, but `guard` doesn't fall through – if handling the nil case is unnecessary and there follows flow-sensitive logic that is resistant to `nil` or doesn't depend on that whatsoever, rearranging the flow with `guard` is likely to become a counterproductive experiment that affects readability while still keeping the indentation.
* Coalescing `??` with an empty literal is only valid with types that conform to a corresponding `ExpressibleByLiteral` protocol. Just in the Standard Library, there is a considerable amount of sequence types that cannot be expressed literally. Most of them are frequently used indirectly:
  * [Type-erasing](https://developer.apple.com/documentation/swift/anysequence#see-also) and [lazy](https://developer.apple.com/documentation/swift/lazysequence#see-also) wrappers
  * [Zipped](https://developer.apple.com/documentation/swift/zip2sequence) and [enumerated](https://developer.apple.com/documentation/swift/enumeratedsequence) sequences
  * `String` views ([`String.UTF8View`](https://developer.apple.com/documentation/swift/string/utf8view), [`String.UTF16View`](https://developer.apple.com/documentation/swift/string/utf16view), [`String.UnicodeScalarView`](https://developer.apple.com/documentation/swift/string/unicodescalarview))
  * [Default indices](https://developer.apple.com/documentation/swift/defaultindices)
  * [Reversed](https://developer.apple.com/documentation/swift/reversedcollection) and [repeated](https://developer.apple.com/documentation/swift/repeated) collections
  * Strides ([`StrideTo`](https://developer.apple.com/documentation/swift/strideto), [`StrideThrough`](https://developer.apple.com/documentation/swift/stridethrough))
  * [Flattened](https://developer.apple.com/documentation/swift/flattensequence), [joined](https://developer.apple.com/documentation/swift/joinedsequence) and [unfolding](https://developer.apple.com/documentation/swift/unfoldsequence) sequences.
  
  An empty instance is not guaranteed to exist for an arbitrary sequence regardless of whether it can be expressed           literally.  This helps to see another flaw in the `?? #placeholder#` fix-it from an engineer's perspective. There are       potentially untraceable cases when the fix-it is wrong. Furthermore, literals are unavailable in generic contexts that     aren't additionally constrained to an `ExpressibleBy*Literal` protocol.

* Reaching for `sequence?.forEach` is not an alternative if you are using control transfer statements, such as `continue` and `break`. The differences are clearly listed in the [documentation](https://developer.apple.com/documentation/swift/sequence/3018367-foreach):

  > Using the forEach method is distinct from a for-in loop in two important ways:
  >
  > 1. You cannot use a `break` or `continue` statement to exit the current call of the body closure or skip subsequent calls.
  >
  > 2. Using the `return` statement in the body closure will exit only from the current call to body, not from any outer   
  >    scope, and won’t skip subsequent calls.

## Proposed solution

This proposal introduces optional iteration (`for?`) and hence the possibility to use optional sequences as the corresponding attribute in `for-in` loops. 

``` swift 
let array: [Int]? = nil

for? element in array { ... }
// Equivalent to
if let unwrappedArray = array {
  for element in unwrappedArray { ... }
}
```

The `?` notation here is a semantic emphasis rather than a functional unit: there is no `for!`. Syntactically marking an optional iteration is redundant, however, in contrast to `switch`, nil values are *skipped silently*. Swift strives to follow a style where silent handling of `nil` is acknowledged via the `?` sigil, distinctly reflected in optional chaining syntax. This decision was primarily based on inconsistency and potential confusion that an otherwise left without syntactic changes `for-in` loop could potentially lead to ("clarity over brevity"). 

``` swift
for element in optionalArray { ... } // Silently handling optionals implicitly is a style that Swift prefers to eschew.
```

From the author's point of view, the solution's most significant advantage is generality and hence scalability. `for?` is independent of the nature and form of the sequence argument and freely composes with any possible expression, be it a cast, `try`, or a mere optional chain. Albeit being an unprecedented optional handling case among statements on the grounds of the need to always omit the identifier to which the unwrapped value is bound, the community points out inconsistency in relation to other statements.

## Detailed design

An optional `for-in` loop over a nil sequence does nothing. To be precise, it trips over nil when `sequence?.makeIterator()` is invoked and continues execution. Otherwise, it iterates normally. One can roughly imagine an optional `for-in` loop as `sequence?.forEach` with all the pattern-matching features and benefits of a `for-in` statement. 

The `?` notation in `for?` is required when the passed sequence is optional and disallowed otherwise.
```swift
let array: [Int] = [1, 2, 3]
let optArray: [Int]? = nil

for element in optArray { // The usual 'must be force-unwrapped' error, but with the preferred fixit to use 'for?'
...
}

for? element in array { // error: optional for-in loop must not be used on a non-optional sequence of type '[Int]'
...
}
```

## Source compatibility

This feature is purely additive.

## Effect on ABI stability

None

## Alternatives considered

### Imitating optional chaining

A syntactically less disruptive approach, the idea of which is denoting an optional iteration by selectively following the sequence expression with `?`:

```swift 
let array: [Int]? = [1, 2, 3]
for element in sequence? { ... }
```
A terminating `?` sigil here can be thought of as bringing the `for` loop into the optional chain with the sequence and mirrors the force-unwrapping case (`sequence!`). The technique implies that a degenerate optional chain (`sequence?`) should end with the `?` sigil, but expressions that already acknowledge optionality, for instance `sequence?.reversed()`, `data as? [T]`, `try? sequenceReturningMethod()`, may be left as-is. It is unclear how to address expressions that don't acknowledge optionality but carry their own syntax without resorting to parenthesizing. One example of such an expression would be `try methodReturningOptionalSequence()`.

#### Nested optionals

As a mechanism that inherently runs only on *non-optional* sequences, `for-in` asks for optional flattening. The position inclines for expressions that acknowledge optionality to keep their optional flattening behavior, while enabling optional flattening on degenerate optional chains, so that types such as `[T]???...` can be iterated without *additional* syntactic load.

### Purely implicit

The option of leaving out any syntactic changes was also discussed and met concern from the community. The drawback is briefly explained in the [Proposed solution](#proposed-solution) section.
