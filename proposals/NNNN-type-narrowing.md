# Type Narrowing

* Proposal: [SE-NNNN](NNNN-type-narrowing.md)
* Author: [Haravikk](https://github.com/haravikk)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is to introduce type-narrowing to Swift, enabling the type-checker to automatically infer a narrower type from context such as conditionals.

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution)

## Motivation

Currently in Swift there are various pieces of boilerplate required in order to manually narrow types. The most obvious is in the case of polymorphism:

```
let foo:A = B() // B extends A
if let foo = foo as? B {
    foo.someMethodSpecificToB()
    foo.someOtherMethodSpecificToB()
}
```

But also in the case of unwrapping of optionals:

```
var foo:A? = A()
if var foo = foo { // foo is now unwrapped and shadowed
    foo.someMethod()
    foo!.someMutatingMethod() // Can't be done
}
```

## Proposed solution

The proposed solution to the boiler-plate is to introduce type-narrowing, essentially a finer grained knowledge of 
type based upon context. Thus as any contextual clue indicating a more or less specific type are encountered, the 
type of the variable will reflect this from that point onwards.

## Detailed design

The concept of type-narrowing would essentially treat all variables as having not just a single type, but 
instead as having a stack of increasingly specific (narrow) types.

Whenever a contextual clue such as a conditional is encountered, the type checker will infer whether this narrows 
the type, and add the new narrow type to the stack from that point onwards. Whenever the type widens again narrower 
types are popped from the stack.

Here are the above examples re-written to take advantage of type-narrowing:

```
let foo:A = B() // B extends A
if foo is B { // B is added to foo's type stack
    foo.someMethodSpecificToB()
    foo.someOtherMethodSpecificToB()
}
// B is popped from foo's type stack
```
```
var foo:A? = A()
if foo != nil { // Optional<A>.some is added to foo's type stack
   foo.someMethod()
   foo.someMutatingMethod() // Can modify mutable original
}
// Optional<A>.some is popped from foo's type stack
```

### Enum Types

As seen in the simple optional example, to implement optional support each `case` in an `enum` is considered 
be a unique sub-type of the enum itself, thus allowing narrowing to `nil` (`.none`) and non-`nil` (`.some`) types.

This behaviour actually enables some other useful behaviours, specifically, if a value is known to be either 
`nil` or non-`nil` then the need to unwrap or force unwrap the value can be eliminated entirely, with the 
compiler able to produce errors if these are used incorrectly, for example:

```
var foo:A? = A()
foo.someMethod() // A is non-nil, no operators required!
foo = nil
foo!.someMethod() // Error: foo is always nil at this point
```

However, unwrapping of the value is only possible if the case contains either no value at all, or contains a 
single value able to satisfy the variable's original type requirements. In other words, the value stored in 
`Optional<A>.some` satisfies the type requirements of `var foo:A?`, thus it is implicitly unwrapped for use.
For general enums this likely means no cases are implicitly unwrapped unless using a type of `Any`.

### Type Widening

In some cases a type may be narrowed, only to be used in a way that makes no sense for the narrowed type. In cases 
such as these the operation is tested against each type in the stack to determine whether the type must instead be 
widened. If a widened type is found it is selected (with re-narrowing where possible) otherwise an error is 
produced as normal.

For example:

```
let foo:A? = A()
if (foo != nil) { // Type of foo is Optional<A>.some
    foo.someMethod()
    foo = nil // Type of foo is widened to Optional<A>, then re-narrowed to Optional<A>.none
} // Type of foo is Optional<A>.none
foo.someMethod() // Error: foo is always nil at this point
```

### Multiple Conditions and Branching

When dealing with complex conditionals or branches, all paths must agree on a common type for narrowing to occur.
For example:

```
let foo:A? = B() // B extends A
let bar:C = C() // C extends B

if (foo != nil) || (foo == bar) { // Optional<A>.some is added to foo's type stack
    if foo is B { // Optional<B>.some is added to foo's type stack
        foo.someMethodSpecificToB()
    } // Optional<B>.some is popped from foo's type stack
    foo = nil // Type of foo is re-narrowed as Optional<A>.none
} // Type of foo is Optional<A>.none in all branches
foo.someMethod() // Error: foo is always nil at this point
```

Here we can see that the extra condition `(foo == bar)` does not prevent type-narrowing, as the variable `bar` 
cannot be `nil` so both conditions require a type of `Optional<A>.some` as a minimum.

In this example `foo` is also `nil` at the end of both branches, thus its type can remain narrowed past this point.

### Mutable values

When a mutable optional type is narrowed as non-`nil`, it will become directly accessible without the need to unwrap it. For example:

```
struct Foo { var value:Int }
struct Bar { var foo:Foo? }

var b = Bar(foo: Foo(value: 5));
b.foo.value = 10 // Equivalent to b.foo!.value = 10
```

### Concurrency and Classes

The exception to the above mutable values are class types of potentially unsafe origin. In other words, type-narrowing will ingore properties of classes unless they are wholly owned by the current scope, and never passed outside of it. Consider:

```
struct Foo { var value:Int }
class Bar { var foo:Foo? }

func myMethod(bar:Bar) { // bar is external, so cannot be trusted
    if (b.foo != nil) {
        b.foo!.value = 10
    }
}
```

In the above example type-narrowing does not take effect as it cannot guarantee that `bar.foo` will not change after being tested, since the class to which it belongs came from out of scope. As such the developer will need to use unwrapping as normal. However, since the type checker knows that `.foo` **should** be non-`nil`, it can provide a warning to indicate a risk of concurrency failures, and also change the force unwrap behaviour to produce a concurrency error at a runtime, rather than a more generic error message, thus making it easier to detect potentially unsafe operations.

With this in mind, it may be worth considering an attribute for classes such as `@concurrent(safe)` or similar, enabling the type-checker to know when a class cannot be modified externally, and thus narrow the type(s) as normal. This will depend on what the planned concurrency model for native Swift entails however.

### Context Triggers

| Trigger | Impact
|---------|---
| `as`    | Explicitly narrows a type with `as!` failing and `as?` narrowing to `Type?` instead when this is not possible.
| `is`    | Anywhere a type is tested will allow the type-checker to infer the new type if there was a match (and other conditions agree).
| `case`  | Any form of exhaustive test on an enum type allows it to be narrowed either to that case or the opposite, e.g- `foo != nil` eliminates `.none`, leaving only `.some` as the type, which can then be implicitly unwrapped (see Enum Types above).
| `=`     | Assigning a value to a type will either narrow it if the new value is a sub-type, or will trigger widening to find a new common type, before attempting to re-narrow from there.

There may be other triggers that should be considered.

## Impact on existing code

Although this change is technically additive, it will impact any code in which there are currently errors 
that type-narrowing would have detected; for example, attempting to manipulate a predictably `nil` value.

## Alternatives considered

One of the main advantages of type-narrowing is that it functions as an alternative to other features. This 
includes alternative syntax for shadowing/unwrapping of optionals, in which case type-narrowing allows an optional
to be implicitly unwrapped simply by testing it, and without the need to introduce any new syntax.
