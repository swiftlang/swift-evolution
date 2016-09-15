# Remove `@noreturn` attribute and introduce an empty `Never` type

* Proposal: [SE-0102](0102-noreturn-bottom-type.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000205.html)
* Bug: [SR-1953](https://bugs.swift.org/browse/SR-1953)

## Introduction

We should remove the rarely-used `@noreturn` function type attribute and
instead express functions that don't return in terms of a standard
uninhabited type.

Swift-evolution threads:

- [SE-0097: Normalizing naming for "negative" attributes](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000167.html)
  was the review discussion from which this proposal arose.
- [Change @noreturn to unconstructible return type](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160530/020140.html)

## Motivation

Functions that never return, such as `exit`, `fatalError`, or `dispatchMain`,
use the `@noreturn` attribute to communicate this fact to the compiler. This
lets the compiler avoid generating incorrect control flow diagnostics for
conditions such as "function does not provide a `return` value" after a
function call that intentionally ends the program. It's relatively rare that
users need to write new functions that don't return; however, `@noreturn` as
currently designed generates complexity. As an orthogonal attribute of function
types, its interaction must be specified with every other aspect of function
types, including `throws` and non-void returns. Does `@noreturn throws` mean
"cannot return normally, but can throw", or does it mean "cannot return *at
all*?" Is `@noreturn () -> Int` allowed, and if so, does it behave differently
from `@noreturn () -> ()`? Should it be possible for generic operations such as
function composition to be parameterized by or overload on `@noreturn`, so that
`compose(exit, getExitCode)` is itself `@noreturn`?

Swift already allows for the definition of **uninhabited types**. An enum type that
has no cases has no valid values and cannot be constructed, a fact that
many Swift users already exploit as a namespacing mechanism.
A function declared to return an uninhabited type *cannot* return normally.

```swift
/// The type of expressions that can never happen.
public /*closed*/ enum Never { /*no values*/ }

func foo() -> Never {
  fatalError("no way out!")
}
```

The ability to express `@noreturn` thus exists in the language already and
does not require an attribute. Once this concept is understood,
answers to the other questions about `@noreturn` fall out naturally.
`() throws -> Never` clearly cannot return normally but can still throw.
It becomes impossible for a function to claim both to not return and have a
return type. Since `Never` is a first-class type, it can propagate naturally
through generic operators without requiring overloading or new generics
features. The net result is a simpler, more consistent, and more expressive model
for handling nonreturning functions.

## Proposed solution

The `@noreturn` attribute is removed from the language.
Where `@noreturn` is currently used to exempt nonterminating code paths from
control flow requirements such as exiting a `guard...else` clause or
`return`-ing from a non-`Void` function, that exemption is
transferred to expressions of *uninhabited type*.

## Detailed design

### Language design

An *uninhabited type* is defined as a type that visibly has no values:

- An enum is an uninhabited type if it is known to have no cases, or if all of its
  cases are known, all of them have associated values, and all of its
  associated value types are empty.

  Note that under the resilience model, an external public enum cannot be
  considered empty unless it is closed, since it must otherwise be assumed to
  have private or retroactively added cases.
  
- A tuple, struct, or class is an uninhabited type if it has any stored
  properties of uninhabited type.

  Under the resilience model, this again means that only fragile external types
  can be reliably considered uninhabited. A resilient external struct or
  class's properties cannot be assumed to be stored.
  
- Functions and metatypes are never uninhabited types.

If an expression of uninhabited type is evaluated, it is considered unreachable
by control flow diagnostics:

```swift
func noReturn() -> Never {
  fatalError() // fatalError also returns Never, so no need to `return`
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
result" warning. Code that would run after an uninhabited expression should
raise "will not be executed" warnings.

### Standard library

The standard library
exports a new public closed enum type `Never`, defined to have no cases:

```swift
public /*closed*/ enum Never {
  /* this space intentionally left blank */
}
```

This type should be used by convention as the return type of functions that don't
return. Existing `@noreturn` functions in the standard library and SDK, such
as `fatalError`, are changed to return `Never`. The Clang importer also imports
C and Objective-C functions declared with `__attribute__((noreturn))` as
returning `Never` in Swift.

### SIL and runtime design

The `noreturn` attribute still needs to exist at the SIL level, since SIL
lowered function types encode the exact calling convention of functions,
including imported C functions. A function returning an uninhabited type at the
semantic level may still need to be lowered to have a specific inhabited return
type for ABI purposes.

There is currently a hole in our model. An uninhabited type is treated like
a zero-sized type by type layout, and is loaded and stored like one, so a value
of uninhabited type can be summoned by loading from a pointer:

```swift
func neverSayNever() -> Never {
  return UnsafeMutablePointer.alloc(1).memory
}
```

This can already be argued to be undefined behavior since the allocation is not
(and cannot be) `initialize`-d first, but it would nonetheless be safer to
make a load or store of an uninhabited type into
a trap operation, both statically in IRGen (perhaps with a SIL diagnostic
pass to warn when we statically see uninhabited loads or stores) and at runtime
by giving uninhabited types a value witness table whose operations trap.

## Impact on existing code

The number of `@noreturn` functions in the wild is fairly small, and all of
them I can find return `Void`. It should be trivial to migrate
existing `@noreturn` functions to use `-> Never`.

## Alternatives considered

### Naming `Never`

The best name for the standard library uninhabited type was a point of
contention. Many of the names suggested by type theory literature or
experience in functional programming circles are wanting:

- `Void` might have been mathematically appropriate, but alas has already been
  heavily confused with "unit" in C-derived circles.
- Names like `Nothing`, `Nil`, etc. have the potential to be confused with the
  `nil` value of `Optional`, or with returning `Void`.
- Type theory jargon like `Bottom` wouldn't be immediately understood by many
  users.

The first revision of this proposal suggested `NoReturn`, but
in discussion, the alternative name `Never` was suggested, which was strongly
preferred by most participants. `Never`
properly implies the temporal aspect--this function returns *never*
--and also generalizes well to other potential applications for an uninhabited
type. For instance, if we gained the ability to support typed `throws`, then
`() throws<Never> -> Void` would also clearly communicate a function that never
throws.

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

This proposal chooses not to go in this direction.

### `Never` as a universal "bottom" subtype

An uninhabited type can be seen as a subtype of any other type--if evaluating
an expression never produces a value, it doesn't matter what the type of that
expression is. If this were supported by the compiler, it would enable some
potentially useful things, for instance using a nonreturning function directly
as a parameter to a higher-order function that expects a result
(`array.filter(fatalError)`) or allowing a subclass to override a method and
covariantly return `Never`. This can be considered as a separate proposal.
Moving from `@noreturn` to `-> Never` is not a regression here, since the
compiler does not allow an arbitrary conversion from `@noreturn (T...) -> U`
to `(T...) -> V` today. The most important use case, a nonreturning function
in void context, will still work by the existing `(T...) -> U` to
`(T...) -> Void` subtyping rule.

