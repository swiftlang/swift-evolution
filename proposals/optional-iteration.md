# Optional Iteration

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Pull request: [apple/swift#19207](https://github.com/apple/swift/pull/19207)

## Introduction

Optionals are a key feature of Swift and a powerful tool that seamlessly interacts with code; they comprise an elegant and concise syntax that serves a great means in expressing "act accordingly if there's a value, skip otherwise".
Some vivid examples of such behavior are optional chaining, optional invocation `foo?()`, `if let`, `guard let` and `switch`. This proposal considers further supporting this convenience in `for-in` loops.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/another-try-at-allowing-optional-iteration/14376?u=anthonylatsis)

## Motivation

Most statements provide convenience patterns and behavior for optionals. Consider `switch`, that can be used on optional values to switch over the unwrapped value if the value exists.

```swift
let str: Int? = nil

switch str {
case 0: print()
case 1: print()
default: print()
}
```

Loops are a common statement in almost every codebase. Similarly, a possibility to optionally iterate over a sequence (that is, iterate if there is a value, otherwise skip) is self-explanatory. However, Swift currently doesn't offer a pattern for expressing this directly: optional sequences are illegal as a `for-in` loop attribute. For a safe option, this makes us resort to optional binding:

```swift
if let sequence = optionalSequence {
  for element in sequence { ... }
}
```

To avoid additional nesting, you can coalesce with `?? []` for `Array` only or use `sequence?.forEach`, which excludes usage of control transfer statements. As stated, both of these workarounds have considerable drawbacks.

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

The `?` notation, however, is a semantic emphasys rather than a functional syntactic unit. There is no `for!`. The latter is redundant, but this decision was primarily made based on the inconsistency and potential confusion that an otherwise left without syntactic changes `for-in` loop could potentially lead to ("clarity over brevity"). The `?`, in fact, is not necessary: the sequence can be force-unwrapped if needed or left as-is without additional syntax.

``` swift
var array: [Int]? = [1, 2, 3]

for element in array { ... } // An optional loop with exactly the same syntax is considered a source of confusion

for? element in array { ... }

```

## Detailed design

An optional `for-in` loop over a nil sequence does nothing. To be precise, it trips over nil when`sequence?.makeIterator()` is invoked and continues execution. Otherwise, it iterates normally. Roughly, one can imagine an optional `for-in` loop as `sequence?.forEach()`.

The `?` notation in `for?` is required if the passed sequence is optional and disallowed otherwise.
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

The option of leaving out any syntactic changes was also discussed and met concern from the community. The drawback is briefly explained in the [Proposed solution](#proposed-solution) section. However, `switch` provides this convenience without additional syntactic sugar.
