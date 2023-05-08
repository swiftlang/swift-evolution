# Make `borrowing` and `consuming` parameters require explicit copying with the `copy` operator

* Proposal: [SE-ABCD](ABCD-borrowing-consuming-no-implicit-copy.md)
* Authors: [Joe Groff](https://github.com/jckarter), [Andrew Trick](https://github.com/atrick/), [Michael Gottesman](https://github.com/gottesmm), [Kavon Favardin](https://github.com/kavon)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Previous Proposal: [SE-0377](0377-parameter-ownership-modifiers.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-making-borrowing-and-consuming-parameters-require-manual-copying-with-a-copy-operator/64843/11))

## Introduction

This proposal changes the `borrowing` and `consuming` parameter modifiers to
make it so that the parameter binding is **not implicitly copyable**. Similarly,
the `borrowing` and `consuming` method modifiers make the `self` binding
within the method not implicitly copyable. We also introduce a new operator,
`copy x`, as a way to explicitly allow a copy to occur.

## Motivation

The `borrowing` and `consuming` modifiers were introduced by
[SE-0377](0377-parameter-ownership-modifiers.md) as a way to allow for
developers to optimize the calling convention of their functions while
working with copyable types, and also to specify the ownership convention
for working with noncopyable types introduced by
[SE-0390](0390-noncopyable-structs-and-enums.md). Even when working with
values of copyable type, the use of these ownership modifiers is a strong
signal that the developer is optimizing the copying behavior of the function,
but with Swift's normal implicit copying behavior, it is difficult to validate
the effect, if any, of manipulating the ownership convention on the efficiency
of the code.

Furthermore, as we develop the ownership model, we also plan to
introduce [borrow bindings](https://forums.swift.org/t/pitch-borrow-and-inout-declaration-keywords/62366)
as a way to bind local variables to the internal storage of data structures
without copying. We also believe these bindings should not be implicitly
copying, since it would likely subvert developers' expectations to bind
a variable to a borrow of a value, and then have the value of that binding
get implicitly copied. Making it so that `borrowing` parameters are also
not implicitly copyable provides a consistent model between the parameter
modifiers and corresponding binding kinds.

## Proposed solution

We propose to make it so that parameters modified by the `borrowing` or
`consuming` ownership modifiers, as well as the `self` parameter to methods
modified by the `borrowing` or `consuming` method modifiers, is not implicitly
copyable. In cases where copying is acceptable, the new `copy x` operator allows
a copy to occur.

## Detailed design

Bindings to parameters modified by the `borrowing` or `consuming` modifier
become not implicitly copyable:

```
func foo(x: borrowing String) -> (String, String) {
    return (x, x) // ERROR: needs to copy `x`
}
func bar(x: consuming String) -> (String, String) {
    return (x, x) // ERROR: needs to copy `x`
}
```

So does the `self` parameter to methods with the method-level `borrowing`
or `consuming` modifier:

```
extension String {
    borrowing func foo() -> (String, String) {
        return (self, self) // ERROR: needs to copy `self`
    }
    consuming func bar() -> (String, String) {
        return (self, self) // ERROR: needs to copy `x`
    }
}
```

A value would need to be implicitly copied if:

- a *consuming operation* is applied to a `borrowing` binding, or
- a *consuming operation* is applied to a `consuming` binding after it has
  already been consumed, or while a *borrowing* or *mutating operation* is simultaneously
  being performed on the same binding

where *consuming*, *borrowing*, and *mutating operations* are as described for
values of noncopyable type in
[SE-0390](https://github.com/apple/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md#using-noncopyable-values).
In essence, disabling implicit copying for a value makes it behave as if it
were a value of noncopyable type.

To allow a copy to occur, the `copy x` operator may be used:

```
func dup(_ x: borrowing String) -> (String, String) {
    return (copy x, copy x) // OK, copies explicitly allowed here
}
```

`copy x` is a *borrowing operation* on `x` that returns an independently
owned copy of the current value of `x`. The copy may then be independently 
consumed or modified without affecting the original `x`. Note that, while
`copy` allows for a copy to occur, it is not a strict
obligation for the compiler to do so; the copy may still be optimized away
if it is deemed semantically unnecessary.

`copy` is a contextual keyword, parsed as an operator if it is immediately
followed by an identifier on the same line, like the `consume x` operator before
it. In all other cases, `copy` is still treated as a reference to a
declaration named `copy`, as it would have been prior to this proposal.

The constraint on implicit copies only affects the parameter binding itself.
The value of the parameter may be passed to other functions, or assigned to
other variables (if the convention allows), at which point the value may 
be implicitly copied through those other parameter or variable bindings.

```
func foo(x: borrowing String) {
    let y = x // ERROR: attempt to copy `x`
    bar(z: x) // OK, invoking `bar(z:)` does not require copying `x`
}

func bar(z: String) {
    let w = z // OK, z is implicitly copyable here
}

func baz(a: consuming String) {
    // let aa = (a, a) // ERROR: attempt to copy `a`

    let b = a
    let bb = (b, b) // OK, b is implicitly copyable
}
```

## Source compatibility

SE-0377 has not yet shipped with any released version of Swift, so although
this is a breaking change to the behavior specified by SE-0377, it should not
affect any production code in released versions of Swift.

## ABI compatibility

This change has no ABI impact.

## Implications on adoption

This constraint somewhat increases the risk of source breakage when adopting
the `borrowing` and `consuming` modifiers, since there will be more
bindings that don't allow for implicit copying to match convention changes.
However, we believe this sort of source break is desirable for code using
the ownership modifiers, because the breaks will indicate to developers 
where copies become necessary or unnecessary as they manipulate
the conventions of their performance-sensitive APIs.

## Future directions

### `borrowing`, `mutating`, and `consuming` local variables

Swift currently lacks the ability to form local bindings to part of an
aggregate without copying that part, other than by passing the part as
an argument to a function call. We plan to introduce [`borrow` and `inout`
bindings](https://forums.swift.org/t/pitch-borrow-and-inout-declaration-keywords/62366)
that will provide this functionality, with the same no-implicit-copy constraint
described by this proposal applied to these bindings.

### Consistency for `inout` parameters and the `self` parameter of `mutating` methods

`inout` parameters and `mutating` methods have been part of Swift since before
version 1.0, and their existing behavior allows for implicit copying of the
current value of the binding. We can't change the existing language
behavior in Swift 5, but accepting this proposal would leave `inout` parameters
and `mutating self` inconsistent with the new modifiers. There are a few things
we could potentially do about that:

- We could change the behavior of `inout` and `mutating self` parameters to
  make them not implicitly copyable in Swift 6 language mode.
- `inout` is also conspicuous now in not following the `-ing` convention we've
  settled on for `consuming`/`borrowing`/`mutating` modifiers. We could introduce
  `mutating` as a new parameter modifier spelling, with no-implicit-copy
  behavior.

One consideration is that, whereas `borrowing` and `consuming` are strictly
optional for code that works only with copyable types, and is OK with letting
the compiler manage copies automatically, there is no way to get in-place
mutation through function parameters except via `inout`.  Tying
no-implicit-copy behavior to mutating parameters could be seen as a violation
of the "progressive disclosure" goal of these ownership features, since
developers would not be able to avoid interacting with the ownership model when
using `inout` parameters anymore.

## Alternatives considered

### `@noImplicitCopy` attribute

Instead of having no-implicit-copy behavior be tied to the ownership-related
binding forms and parameter modifiers, we could have an attribute that can
be applied to any binding to say that it should not be implicitly copyable:

```
@noImplicitCopy(self)
func foo(x: @noImplicitCopy String) {
    @noImplicitCopy let y = copy x
}
```

We had [pitched this possibility](https://forums.swift.org/t/pitch-noimplicitcopy-attribute-for-local-variables-and-function-parameters/61506),
but community feedback rightly pointed out the syntactic weight and noise
of this approach, as well as the fact that, as an attribute, it makes the
ability to control copies feel like an afterthought not well integrated
with the rest of the language. We've decided not to continue in this direction,
since we think that attaching no-implicit-copy behavior to the ownership
modifiers themselves leads to a more coherent design.

### `copy` as a regular function

Unlike the `consume x` or `borrow x` operator, copying doesn't have any specific
semantic needs that couldn't be done by a regular function. Instead of an
operator, `copy` could be defined as a regular standard library function:

```
func copy<T>(_ value: T) -> T {
    return value
}
```

We propose `copy x` as an operator, because it makes the relation to
`consume x` and `borrow x`, and it avoids the issues of polluting the
global identifier namespace and occasionally needing to be qualified as
`Swift.copy` if it was a standard library function.

### Transitive no-implicit-copy constraint

The no-implicit-copy constraint for a `borrowing` and `consuming` parameter
only applies to that binding, and is not carried over to other variables
or function call arguments receiving the binding's value. We could also
say that the parameter can only be passed as an argument to another function
if that function's parameter uses the `borrowing` or `consuming` modifier to
keep implicit copies suppressed, or that it cannot be bound to `let` or `var`
bindings and must be bound using one of the borrowing bindings once we have
those. However, we think those additional restrictions would only make the
`borrowing` and `consuming` modifiers harder to adopt, since developers would
only be able to use them in cases where they can introduce them bottom-up from
leaf functions.

The transitivity restriction also would not really improve
local reasoning; since the restriction is only on *implicit* copies, but
explicit copies are still possible, calling into another function may lead
to that other function performing copies, whether they're implicit or not.
The only way to be sure would be to inspect the callee's implementation.
One of the goals of SE-0377 is to introduce the parameter ownership modifiers
in a way that minimizes disruption to the the rest of a codebase, allowing
for the modifiers to be easily adopted in spots where the added control is
necessary, and a transitivity requirement would interfere with that goal for
little benefit.
