# Removing currying `func` declaration syntax

* Proposal: [SE-0002](https://github.com/apple/swift-evolution/blob/master/proposals/0002-remove-currying.md)
* Author(s): [Joe Groff](https://github.com/jckarter)
* Status: **Accepted**

## Introduction

Curried function declaration syntax `func foo(x: Int)(y: Int)` is of limited
usefulness and creates a lot of language and implementation complexity. We
should remove it.

## Motivation

The presence of curried function syntax has knock-on effects, complicating
other language features:

- The presence of currying invites confusion over keyword rules and the
  declaration name of functions. We've argued several times over whether
  curried arguments represent a continuation of the function's arguments, begin
  the argument list of a new function, or deserve to follow different rules
  altogether.
- It has subtle interactions with 'var' and 'inout' argument
  annotations. A curried function with 'inout' parameters anywhere other than
  its first clause cannot be partially applied without surprising semantic
  restrictions, limiting its usefulness. With 'var' parameters, there's the
  question of at what level the 'var' gets bound; many users expect it at the
  outermost partial application, but we currently bind at the innermost partial
  application.

The idioms of the standard library, Cocoa, and most third-party code don't
really make ML-style argument currying of free functions profitable. In
Cocoa and the standard library, most things are methods, where we can still get
useful partial application via `self.method` and maybe someday `.map { f($0)
}` as well. The curried function design also predates the design of the
keyword argument model. We have plans to move away
from the arguments-are-a-single-tuple model too (which is already belied by
things like `@autoclosure` and `inout`), which pushes us even further away from
the ML argument model.

Many users have observed the uselessness of our currying feature, and asked for
Scala-style `f(_, 1)` freeform partial application as an alternative. The fact
that even functionally-oriented users don't see much value in our currying
feature makes me feel like we might be better off without it. It definitely fails
the "would we add it if we didn't have it already" test.

## Detailed design

We remove support for multiple argument patterns in `func` declarations,
reducing the grammar for `func-signature` to allow only one `argument` clause.
For migration purposes, existing code that uses currying declaration syntax
can be transformed to explicitly return a closure instead:

```swift
  // Before:
  func curried(x: Int)(y: String) -> Float {
    return Float(x) + Float(y)!
  }

  // After:
  func curried(x: Int) -> (String) -> Float {
    return {(y: String) -> Float in
      return Float(x) + Float(y)!
    }
  }
```

I don't propose changing the semantics of methods, which formally remain
functions of type `Self -> Args -> Return`.

## Impact on existing code

This is removing a language feature, so will obviously break existing code
that uses the feature. We feel that currying is of sufficiently marginal 
utility, runs against the grain of emerging language practice, and there's a
reasonable automatic migration, so the impact is acceptable in order to
simplify the language.

## Alternatives considered

The alternative would be to preserve currying as-is, which as discussed above,
is not ideal. Although I don't propose taking any immediate action, future
alternative designs to provide similar functionality in a more idiomatic way
include:

- Scala-like ad-hoc partial application syntax, such that something like
  `foo(_, bar: 2)` would be shorthand for `{ x in foo(x, bar: 2) }`. This
  has the benefit of arguably being more readable with our keyword-argument-
  oriented API design, and also more flexible than traditional currying,
  which requires argument order to be preconsidered by the API designer.
- Method and/or operator slicing syntax. We have `self.method` to partially
  bind a method to its `self` parameter, and could potentially add
  `.method(argument)` to partially bind a method to its non-self arguments,
  which would be especially useful for higher-order methods like `map`
  and `filter`. Haskell-like `(2+)`/`(+2)` syntax for partially applying
  operators might also be nice.
