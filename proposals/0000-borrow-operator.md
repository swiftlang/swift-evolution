# Borrow Operator, Pass-by-Borrow, and Pass-by-Value

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: ...
* Review Manager: TBD
* Status: ...

<!--

*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

-->

## Introduction

In this document, we propose adding a new operator to the language, marked by
the context sensitive keyword `borrow`, that causes the compiler to pass
arguments using a `pass-by-borrow` convention instead of a `pass-by-value`
convention.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Swift normally passes arguments using a `pass-by-value` convention. A
`pass-by-value` argument convention implies that each argument is passed as a
separate value to the callee. This has the effect that the compiler is allowed
(and sometimes required) to introduce temporary copies of arguments into the
program in caller callsites.

As an elucidating example, consider the following code:

```
func useValueTwice(_ x: Type, _ y: Type) {}

var a: Type = ...
useValueTwice(a, a)
```

Since `useValueTwice` is using default Swift conventions, we pass `a` as two
separate guaranteed parameters to `useValueTwice`. Inside `useValueTwice`, `x`
and `y` both appears to be separate truly borrowed values in the sense that
`useValueTwice` has immutable access to two different values and does not take
ownership of those values. In order for the compiler to achieve this, it must
necessarily copy `a` to ensure that it can pass two different values to
`useValueTwice`. These copies are observable program behavior and are in fact a
desired default behavior since otherwise in general cases we couldn't write code
like the above that takes the same argument multiple times. We instead would
necessarily require the compiler to insert an error similar to an exclusivity
violation which is undesireable:

```
useValueTwiceWithoutPassByValue(a, a) // Error! Cannot pass a value twice!
```

In certain cases though, this `pass-by-value` behavior and the implicit copies
it requires the compiler to insert may be undesireable due to the author needing
strict performance guarantees that implicit copies like the above are never
generated. For most programs this guarantee is not needed since the optimizer
generally does a good enough job eliminating such copies. But in critical system
code, good enough is not an acceptable constraint and a true semantic guarantee
is needed.

## Proposed solution

We propose introducing a new context sensitive keyword called `borrow` that when
applied to a function argument forces Swift to use a `pass-by-borrow` convention
on a specific argument instead of a `pass-by-value` convention. This would thus
forbid the compiler from inserting such copies and instead cause the compiler to
emit an error in such a case:

```
var a: Type = ...
useValueTwice(borrow a, borrow a) // Error! Cannot overlapping borrows of 'a'!
```

The result of the usage of borrow is that a performance minded programmer would
be able to sleep well at night knowing that their code doesn't have copies in
this code.

## Detailed design

The `borrow` keyword can be applied in argument positions to lets, vars, and
arguments. The application of the keyword would cause the compiler to use a
`pass-by-borrow` convention for that parameter instead of a `pass-by-value`
convention. First we define the `pass-by-value` convention as follows:

1. `let` and non-`inout` parameters: Formally, the compiler always copies the
   `let` or non-`inout` parameter into a new independent value and passes the
   value as the parameter. To the callee this value appears as an independent
   immutable value that is different from all other parameters.

2. `var` and `inout` parameters: Formally the compiler after formal evaluations
   have completed, emits an access to the lvalue and then copies the value from
   the lvalue into a new rvalue. The rvalue is then passed as an independent
   value to the guaranteed parameter. Similar to the `let` case, this rvalue in
   the callee appears as an independent immutable value that is different from
   all other parameters.

We define the `pass-by-borrow` convention as follows:

1. `let` and non-inout parameters: This would cause the compiler to not emit
   defensive copies when calling guaranteed parameters. Since a let is immutable
   and a guaranteed parameter is immutable, we would allow for a let to be
   passed multiple times as a `pass-by-borrow` parameter.

2. `var` and `inout` parameters: This would cause the compiler to formally
   evaluate the `var`/`inout` using a read exclusivity scope and then use a
   borrowed formal access to pass the value to the function argument. This is
   the same mechanism used to pass vars as an inout parameter except we have
   exclusive read access instead of exclusive write access to the given memory.

Since the `var`/`inout` case takes exclusive read access to the underlying
memory, once cannot pass such a binding multiple times to the same function:

```
var a: Type = ...
// Error! Cannot take exclusive access to the same variable twice
useValueTwice(borrow a, borrow a)
```

necessarily this implies that we must also error if one passes a `var`/`inout`
once as a `by-borrow` parameter and once as a `by-value` parameter, one will
also achieve an exclusivity violation since one will attempt to access the
`var`/`inout` for the lvalue-to-rvalue conversion /after/ the formal evaluation
of the borrowed argument has begun. Example:

```
var a: Type = ...
// Error! Cannot take exclusive access to the same variable twice
useValueTwice(borrow a, a)
```

In pseudo-code this would look as follows:

```
var a: Type = ...
// Formal evaluation
let firstArgAddr = access a

// RValue access
let secondArgAddr = access a // Error! Cannot take exclusive access to the same variable twice
let rvalue = copy secondArgAddr
end_access secondArgAddr

// Formal access (nothing to do)

// Call function
useValueTwice(firstArgAddr, rvalue)

// Tear down
end_access firstArgAddr
```

## Source compatibility

`borrow` will only be allowed to be applied to lvalues (similar to `take`) and
thus should not create any source breaks with function or variable names that
use the phrase borrow. So there shouldn't be any source compatibility breaks.

## Effect on ABI stability

`borrow` does not affect the ABI of the caller where it is used or the ABI of
the callee it is used to call. It only changes code in the caller used to call
the callee and to the callee is invisible.

## Effect on API resilience

As noted above, using `borrow` in a function body does not affect how users call
the caller or the callee.

## Alternatives considered

???

## Future Directions

1. Automatic use of pass-by-borrow for borrowed parameters.
2. Require this for initialization of borrowed var decls?

## Acknowledgments

??
