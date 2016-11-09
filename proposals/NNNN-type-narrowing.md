# Type Narrowing

* Proposal: [SE-NNNN](NNNN-type-narrowing.md)
* Author: [Haravikk](https://github.com/haravikk)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is to introduce type-narrowing to Swift, enabling the type-checker to track the specific type of a variable without the use of conditional binding.

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

The proposed solution is to enable explicit type-narrowing of a variable.

## Detailed design

Explicit type-narrowing will use the `as` keyword to test the type of a variable and, if it is a match, will cause the variable's type to be narrowed within that scope. To demonstrate with the above example:
```
if foo as T {
    foo.someMethodSpecificToT()
    foo.someMutatingMethodSpecificToT()
}
```
Here we see that `foo` is modifiable directly as type `T`. Use of `as` in this way will be available in all conditionals, including `case` statements.

### Narrowing Properties

It is also possible to narrow properties, allowing the following:
```
struct Foo { value:Any }
var foo:Foo = getValueFromSomewhere()
if foo.value as T {
    foo.value.someMethodSpecificToT()
    foo.value.someMutatingMethodSpecificToT()
}
```

### Classes and Concurrency

Narrowing on classes is not permitted with the default `as` keyword, as this represents a possible concurrency issue if a variable narrowed by the current thread is modified by another, therefore a force operator is required like so:
```
class Foo { value:Any }
var foo:Foo = getValueFromSomewhere()
if foo.value as! T {
    foo.value.someMethodSpecificToT()
    foo.value.someMutatingMethodSpecificToT()
}
```
Behind the scenes the type of `foo.value` is tested atomtically to ensure it is still of type `T`, if it is not then a runtime error is produced (just as if a normal use of `as!` had failed), however, since the type-checker that knows that this **should** have been safe for a single thread, it can produce a more specific concurrent modification error.

### Type Widening

Once narrowed, assigning a wider (parent) type is considered an error, however this can still be achieved using the force operator, but doing so "breaks" the narrowing, causing the variable to switch to the new, wider, type from that point on.
```
struct A {}
struct B : A { func someMethodSpecificToB() {}}

var foo:A = getValueFromSomewhere()
if foo as B {
    foo = A()!
    foo.someMethodSpecificToB() // error, foo is now of type A
}
```

## Impact on existing code

This change is purely additive.

However, with this feature implemented it may be desirable for `if var foo = foo as? T` to become a warning due to its potential to be a mistake.

## Alternatives considered

This feature is primarily intended as an alternative to shadowing and copying with casting which, though it works, can be confusing and does allowing mutation of the original variable.
