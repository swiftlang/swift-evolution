# Optional Iteration

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anthony Latsis](https://github.com/AnthonyLatsis)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

Optionals are a key feature of Swift; they comprise a concise and elegant syntax that serves a great means of brevity
when it comes to expressing "do something if there's a value, skip otherwise".
Thereby, we have a powerful tool that seamlessly interacts with code. Some vivid examples are optional chaining,
optional invocation `foo?()` and even `if let`. This proposal considers further supporting this convenience in `for-in` loops.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/another-try-at-allowing-optional-iteration/14376?u=anthonylatsis)

## Motivation

Loops are indeed a common statement. When working with optional sequences, a possibility to optionally iterate
(that is, iterate if there is a value, otherwise skip) is self-explanatory. However, Swift currently doesn't offer a way to express
this 'natively', in the language of optionals. Optional sequences are illegal as a `for-in` loop attribute. The most common and correct way of putting it,
especially when we need to handle the `nil` case (`else`) is

```swift
if let sequence = optionalSequence {
  for element in sequence { ... }
} // else { ... }
```

Alternative workarounds include `?? []` (for `Array`) and `sequence?.forEach`.

The bottom line being, if we don't require `else`, why not say `for? element in optionalSequence { ... }` ?

## Proposed solution

Optional `for-in` loops and the possibility to use optional sequences therein. The `?` notation, however, will be a semantic
emphasys rather than a functional syntactic unit. There will be no `for!`. The latter is redundant, but this decision was primarily
made based on the potential confusion that an otherwise left without syntactic changes `for-in` loop could lead to confusion
("clarity over brevity"). The `?`, in fact, is not necessary: the sequence can be force-unwrapped if needed or left as-is
without requiring addition syntax.

``` swift
var array: [Int]? = [1, 2, 3]

for element in array { ... } // An optional loop with exactly the same syntax is considered a source of confusion

for? element in array { ... }

```

## Detailed design

An optional `for-in` loop over a nil sequence does nothing. Otherwise, it iterates normally. The `?` notation in `for?` is
required if the passed sequence is optional. Roughly, one can imagine an optional `for-in` loop as `sequence?.forEach`.

With a yet rather vague picture of the implementation, I assume one of the options is to enclose an optional loop in an `if-let`
statement during sil-gen.

## Source compatibility

This feature is purely additive and hence does not imply source-breaking changes.
Usage is context-sensitive and migration should be up to the user.

## Effect on ABI stability

This feature likely changes the code generation model.

## Alternatives considered

An similar approach was to leave out any syntactic changes. The downsides are briefly explained in the
(Proposed solution)[proposed-solution] section.
