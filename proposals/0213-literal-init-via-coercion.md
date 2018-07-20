# Literal initialization via coercion

* Proposal: [SE-0213](0213-literal-init-via-coercion.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 5)**
* Implementation: [apple/swift#17860](https://github.com/apple/swift/pull/17860)

## Introduction

`T(literal)` should construct T using the appropriate literal protocol if possible.

Swift-evolution thread: [Literal initialization via coercion](https://forums.swift.org/t/literal-initialization-via-coercion/11251)

## Motivation

Currently types conforming to literal protocols are type-checked using regular
initializer rules, which means that for expressions like `UInt32(42)` the
type-checker is going to look up a set of available initializer choices and
attempt them one-by-one trying to deduce the best solution.

This is not always a desired behavior when it comes to numeric and
other literals, because it means that argument is going to be type-checked
separately (most likely to some default literal type like `Int`) and passed
to an initializer call. At the same time coercion behavior would treat
the expression above as `42 as UInt32` where `42` is ascribed to be `UInt32`
and constructed without an intermediate type.

## Proposed solution

The proposed change makes all initializer expressions involving literal types
behave like coercion of literal to specified type if such type conforms to the
expected literal protocol. As a result expressions like `UInt64(0xffff_ffff_ffff_ffff)`,
which result in compile-time overflow under current rules, become valid. It
also simplifies type-checker logic and leads to speed-up in some complex expressions.

This change also makes some of the errors which currently only happen at runtime
become compile-time instead e.g. `Character("ab")`.

## Detailed design

Based on the [previous discussion on this topic](https://forums.swift.org/t/proposal-t-literal-should-construct-t-using-the-appropriate-literal-protocol-if-possible/2861) here is the formal typing rule:

```
Given a function call expression of the form `A(B)` (that is, an expr-call with a single,
unlabelled argument) where B is a literal expression, if `A` has type `T.Type`
for some type `T` and there is a declared conformance of `T` to an appropriate literal protocol
for `B`, then `A` is directly constructed using `init` witness to literal protocol
(as if the expression were written "B as A").
```

This behavior could be avoided by spelling initializer call verbosely e.g. `UInt32.init(42)`.

Implementation is going to transform `CallExpr` with `TypeExpr` as a applicator into
implicit `CoerceExpr` if the aforementioned typing rule holds before forming constraint system.

## Source compatibility

This is a source breaking change because it’s possible to declare a conformance to
a literal protocol and also have a failable initializer with the same parameter type:

```swift
struct Q: ExpressibleByStringLiteral {
  typealias StringLiteralType =  String

  var question: String

  init?(_ possibleQuestion: StringLiteralType) {
    return nil
  }

  init(stringLiteral str: StringLiteralType) {
    self.question = str
  }
}

_ = Q("ultimate question")    // 'nil'
_ = "ultimate question" as Q  // Q(question: 'ultimate question')
```

Although such situations are possible, we consider them to be quite rare
in practice. FWIW, none were found in the compatibility test suite.


## Effect on ABI stability

Does not affect ABI stability

## Effect on API resilience

Does not affect API resilience

## Alternatives considered

Not to make this change.
