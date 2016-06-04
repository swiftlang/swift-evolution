# Remove `@noreturn` attribute and introduce an empty `NoReturn` type

* Proposal: [SE-0102](0102-noreturn-bottom-type.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Status: **Scheduled for review June 21...27**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

We should remove the rarely-used `@noreturn` function type attribute and
instead express functions that don't return in terms of a standard
unconstructible uninhabited type.

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution)

## Motivation

Functions that never return, such as `exit`, `fatalError`, or `dispatchMain`, use
the `@noreturn` attribute to communicate this fact to the compiler. This lets
the compiler avoid generating incorrect control flow diagnostics for conditions
such as "function does not provide a `return` value" after a function call
that intentionally ends the program. It's relatively rare that users need to
write new functions that don't return; however, `@noreturn` as currently
designed generates complexity. As an orthogonal attribute of function
types, its interaction must be specified with every other aspect of function
types, including `throws` and non-void returns. Does `@noreturn throws` mean
"cannot return normally, but can throw", or does it mean "cannot return
*at all*?" Is `@noreturn () -> Int` allowed, and if so, does it behave
differently from `@noreturn () -> ()`? Should it be possible for generic
operations such as function composition to be parameterized by or overload
on `@noreturn`, so that `compose(exit, getExitCode)` is itself `@noreturn`?

Swift already allows for the definition of **uninhabited types**. An enum type that
has no cases has no valid values and cannot be constructed, a fact that
many Swift users already exploit as a namespacing mechanism.
A function declared to return an uninhabited type *cannot* return normally.

```swift
public /*closed*/ enum Empty { /*no values*/ }

func foo() -> Empty {
  fatalError("no way out!")
}
```

The ability to express `@noreturn` thus exists in the language already and
does not require an attribute. Once this concept is understood,
answers to the other questions about `@noreturn` fall out naturally.
`() throws -> NoReturn` clearly cannot return normally but can still throw.
It becomes impossible for a function to claim both to not return and have a
return type. Since `NoReturn` is a first-class type, it can propagate naturally
through generic operators without requiring overloading or new generics
features. The net result is a simpler, more consistent, and more expressive model
for handling nonreturning functions.

## Proposed solution

The `@noreturn` attribute is removed from the language.
Where `@noreturn` is currently used to exempt nonterminating code paths from
control flow requirements such as exiting a `guard...else` clause or
`return`-ing from a non-`Void` function, that exemption is
transfered to expressions of *uninhabited type*.

The standard library
exports a new public closed enum type `NoReturn`, defined to have no cases:

```swift
public /*closed*/ enum NoReturn {
  /* this space intentionally left blank */
}
```

## Detailed design

### Language design

An *uninhabited type* is defined as a type that visibly has no values:

- An enum is an uninhabited type if it is known to have no cases, or if all of its
  cases are known, all of them have associated values, and all of its
  associated value types are empty.

  Note that under the
  resilience model, an external public enum cannot be considered empty unless
  it is closed, since it must otherwise be assumed to have private or
  retroactively added cases.
  
- A tuple, struct, or class is an uninhabited type if it has any stored properties of
  uninhabited type.
  
- Functions and metatypes are never uninhabited types.

If an expression of uninhabited type is evaluated, it is considered unreachable
by control flow diagnostics:

```swift
func noReturn() -> NoReturn {
  fatalError() // fatalError also returns NoReturn, so no need to `return`
}

func pickPositiveNumber(below limit: Int) -> Int {
  guard limit >= 1 else {
    noReturn()
    // No need to exit guarded scope after noReturn
  }
  return rand(limit)
}
```

An ignored expression of uninhabited type should also not produce an "unused
result" warning.

### SIL and runtime design

The `noreturn` attribute still needs to exist at the SIL level, since SIL
lowered function types encode the exact calling convention of functions,
including imported C functions. A function returning an uninhabited type at the semantic
level may still need to have a specific inhabited return type for ABI purposes.

There is currently a hole in our model. An enum with no cases is treated like
a zero-sized type by type layout, and is loaded and stored like one, so a value
of uninhabited type can be summoned by loading from a pointer:

```swift
func revengeOfNoReturn() -> NoReturn {
  return UnsafeMutablePointer.alloc(1).memory
}
```

This can already be argued to be undefined behavior since the allocation is not
(and cannot be) `initialize`-d first, but this hole can be fixed by making a
load or store of an uninhabited type into
a trap operation, both statically in IRGen (perhaps with a SIL diagnostic
pass to warn when we statically see uninhabited loads or stores) and at runtime
by giving uninhabited types a value witness table whose operations trap.

## Impact on existing code

The number of `@noreturn` functions in the wild is fairly small, and all of
them I can find return `Void`. It should be trivial to migrate
existing `@noreturn` functions to use `-> NoReturn`.

## Alternatives considered

### Naming `NoReturn`

The best name for the standard library uninhabited type is up for debate.
`NoReturn` seems to me like the name most immediately obvious to most users
compared to these alternatives:

- `Void` might have been mathematically appropriate, but alas has already been
  heavily confused with "unit" in C-derived circles.
- Names like `Nothing`, `Nil`, etc. have the potential to be confused with the
  `nil` value of `Optional`, or with returning `Void`.
- Type theory jargon like `Bottom` wouldn't be immediately understood by many
  users.
  
Instead of one standard type, it might be also useful for documentation purposes to
have multiple types to indicate *how* a type doesn't return, e.g.:

```swift
enum Exit {} /// Exit process normally
func exit(_ code: Int) -> Exit

enum Abort {} /// Exit process abnormally
func fatalError(_ message: String) -> Abort

enum InfiniteLoop {} /// Takes over control of the process
func dispatchMain() -> InfiniteLoop
```

### `NoReturn` as a universal "bottom" subtype

An uninhabited type can be seen as a subtype of any other type--if evaluating
an expression never produces a value, it doesn't matter what the type of that
expression is. If this were supported by the compiler, it would enable some
potentially useful things, for instance using a nonreturning function directly
as a parameter to a higher-order function that expects a result
(`array.filter(fatalError)`) or allowing a subclass to override a method and
covariantly return `NoReturn`. This can be considered as a separate proposal.
Moving from `@noreturn` to `-> NoReturn` is not a regression here, since the
compiler does not allow an arbitrary conversion from `@noreturn (T...) -> U`
to `(T...) -> V` today. The most important use case, a nonreturning function
in void context, will still work by the existing `(T...) -> U` to
`(T...) -> Void` subtyping rule.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
