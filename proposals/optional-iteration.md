# Optional Iteration

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Pull request: [apple/swift#19207](https://github.com/apple/swift/pull/19207)

## Introduction

Optionals are a key feature of Swift and a powerful tool that seamlessly interacts with code. In particular, they serve a great means in expressing "act accordingly if there's a value, skip otherwise". Some vivid examples of such behavior are optional chaining, optional invocation `foo?()`, `if let` and `guard let`. This proposal considers further supporting this convenience in `for-in` loops.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/another-try-at-allowing-optional-iteration/14376?u=anthonylatsis)

## Motivation

Most Swift statements provide convenience patterns and handling for optionals. We have optional binding patterns for `while`, `if` and `guard`. Consider `switch`, that can be used directly on an optional to match against the unwrapped value. Nevertheless, it is important to keep in mind that exhaustiveness still applies, that is, the `nil` case must be handled either explicitly or via the `default` clause:

```swift
let str: Int? = nil

switch str {
case 0: print()
case 1: print()
default: print()
}
```

Loops too are a common statement in almost every codebase. Similarly, the possibility to optionally iterate over a sequence (iterate if there is a value, otherwise skip) is self-explanatory. While usage of optional sequences is often treated as misconception, there are several common ways one could end up with an optional sequence through Standard Library APIs and language constructs themselves. For instance, optional chaining and dictionary getters. An indentation-sensitive area of which optional arrays are an integral part is decoding and deserialization, i.e parsing a JSON response.
Swift currently doesn't offer a mechanism for expressing optional iteration directly: optional sequences are illegal as a `for-in` loop attribute. For a safe option, this makes us resort to optional binding:

```swift
if let sequence = optionalSequence {
  for element in sequence { ... }
}
```
There are several workarounds to avoid additional nesting, none of which can be called a general solution:
* Coalescing with `?? []` is only valid with types that conform to `ExpressibleByArrayLiteral`. The needless allocation of `[]` is also something rather to be eschewed than encouraged. Furthermore, an empty instance is not guaranteed to exist for an arbitrary sequence.
* Reaching for `sequence?.forEach` excludes control transfer statements, such as `continue` and `break`. The differences are clearly listed in the [documentation](https://developer.apple.com/documentation/swift/sequence/3018367-foreach):

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

The `?` notation here is a semantic emphasys rather than a functional unit: there is no `for!`. Syntactically marking an optional iteration is redundant, however, in constrast to `switch`, nil values are *skipped silently*. Swift strives to follow a style where silent handling of `nil` is acknowledged via the `?` sigil, distinctly reflected in optional chaining. This decision was primarily based on inconsistency and potential confusion that an otherwise left without syntactic changes `for-in` loop could potentially lead to ("clarity over brevity").  

``` swift
var array: [Int]? = [1, 2, 3]

for element in array { ... } // Silently handling optionals implicitly is a style that Swift prefers to eschew.

for? element in array { ... }

```

## Detailed design

An optional `for-in` loop over a nil sequence does nothing. To be precise, it trips over nil when `sequence?.makeIterator()` is invoked and continues execution. Otherwise, it iterates normally. Roughly, one can imagine an optional `for-in` loop as `sequence?.forEach()`. 

The `?` notation in `for?` is required when the passed sequence is optional and disallowed otherwise.
```swift
let array: [Int] = [1, 2, 3]
let optArray: [Int]? = nil

for element in optArray { // The usual 'must be force-unwrapped' error, but with the preffered fixit to use 'for?' 
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

A syntactically less disruptive approach, the idea of which is denoting an optional iteration by following the sequence expression with `?`:

```swift 
let array: [Int]? = [1, 2, 3]
for element in sequence? { ... }
```
Since a nonterminated optional chain is otherwise meaningless, this can be interpreted as bringing the `for` loop into the optional chain with the sequence and mirrors the force-unwrapping case. Furthermore, keeping the statement itself intact gives us an analogue that is more or less consistent with an "optional switch". 

### Purely implicit

The option of leaving out any syntactic changes was also discussed and met concern from the community. The drawback is briefly explained in the [Proposed solution](#proposed-solution) section.
