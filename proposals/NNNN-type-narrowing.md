# Type Narrowing

* Proposal: [SE-NNNN](NNNN-type-narrowing.md)
* Author: [Haravikk](https://github.com/haravikk)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is to introduce type-narrowing to Swift, enabling the type-checker to track the specific type of a polymorphic variable without the use of conditional binding.

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution)

## Motivation

The purpose of this proposal is simplify narrowing of a polymorphic type, while also retaining mutability. Currently it is possible to handle narrowing in various ways, but none is really ideal:

Example with shadowing:
```
if var foo = foo as? T {
    foo.someMethodSpecificToT()
    foo.someMutatingMethodSpecificToT()
}
```
However, in the case of a mutating method, only the copy is modified, not the original (if `T` is a struct).

Example without shadowing:
```
if var thisFoo = foo as? T {
    thisFoo.someMethodSpecificToT()
    thisFoo.someMutatingMethodSpecificToT()
    foo = thisFoo
}
```
Here we need to modify the copy, then assign back to `foo`, likely producing an unnecessary copy in the process.

## Proposed solution

The proposed solution is to enable implicit, automatic type-narrowing of a variable based upon certain trigger conditions. The simplest way to think of type-narrowing is as an extension of type-inference; granting the ability of the type-checker to infer narrower types simple from the way in which a variable is used.

## Detailed design

Implicit narrowing of type will essentially work by having the type-checker maintain a stack of types for each variable in each branch of code. Any time a narrowing trigger is encountered, if it identifies a new, narrower, type then this is added to the stack.

When a variable is used, it is treated as the narrowest type on the stack, giving access to the more specific methods and properties of that type.

The simplest narrowing trigger will be the `is` keyword, which identifies the type and explicitly narrows it within the appropriate scope, like so:
```
if foo is T {
    foo.someMethodSpecificToT()
    foo.someMutatingMethodSpecificToT()
}
```
Here we see that `foo` is modifiable directly as type `T`. Use of `is` in this way will be available in all conditionals, including `case` statements.

### Narrowing Triggers

The following initial triggers for narrowing are proposed:
| Trigger | Description
|---------|---------------
| `is`    | Explicitly narrows a variable to whichever type it is confirmed to be.
| `=`     | Assigning a new value to a variable signals to the type-checker that the variable is now of that type.

### Narrowing Properties

It is also possible to narrow properties, allowing the following:
```
struct Foo { value:Any }
var foo:Foo = getValueFromSomewhere()
if foo.value is T {
    foo.value.someMethodSpecificToT()
    foo.value.someMutatingMethodSpecificToT()
}
```

### Classes and Concurrency

Implicit type-narrowing is only permitted on value types; this because narrowing of a reference type by the current thread could potentially be broken by another, leading to inconsistent values. However, narrowing can still be performed explicitly by using a force operator like so:
```
class Foo { value:Any }
var foo:Foo = getValueFromSomewhere()
if foo.value is! T {
    foo.value.someMethodSpecificToT()
    foo.value.someMutatingMethodSpecificToT()
}
```
Use of this force operator enables type narrowing exactly as for a value type, however, behind the scenes the type of the variable is tested for consistency, and will produce an runtime concurrent modification error if it no longer matches what the type-checker expects. Thus the developer, in using the force operator, must choose whether they decide whether the reference is safe.

To support refernces that are known to be safe a new `@concurrency(safe)` attribute is also proposed; this is used to mark variables/properties that are known to hold the only reference to an object instance, or to do-so in a way that is safe (e.g- storage for a copy-on-write type). Variables with this attribute do not require the force operator, and do require additional type-checking at runtime.

### Type Widening

Once narrowed, assigning a wider (parent) type will cause the type-checker to roll back the stack of types for that variable until it finds a match, from this point on the variable is now treated as the new, wider type. An example:
```
struct A {}
struct B : A { func someMethodSpecificToB() {}}

var foo:A = getValueFromSomewhere()
if foo as B { // foo is now of type B
    foo = A()
    foo.someMethodSpecificToB() // error, foo is now of type A
}
```

## Impact on existing code

This change is purely additive.

However, with this feature implemented it may be desirable for `if var foo = foo as? T` to become a warning due to its potential to be a mistake.

## Alternatives considered

This feature is primarily intended as an alternative to shadowing and copying with casting which, though it works, can be confusing and does allowing mutation of the original variable.
