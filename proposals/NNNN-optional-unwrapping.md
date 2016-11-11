# Optional Unwrapping

* Proposal: [SE-NNNN](NNNN-type-narrowing.md)
* Author: [Haravikk](https://github.com/haravikk)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is to introduce unwrapping as an explicit concept in Swift.

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution)

## Motivation

Currently when dealing with `Optionals` it is necessary to use conditional binding to extract an unwrapped version of a variable; this is fine when dealing with a copy, but introduces a number of awkward cases when mutability is required, especially when the original variable is shadowed at the same time.

Example with shadowing:
```
var foo:T? = getValueFromSomewhere()
if var foo = foo {
	print(foo.someValue)
	foo.someMutatingMethod()
	foo.someValue = "Foo"
}
```
In the above example the copy is mutated, rather than the original (if `T` is a struct).

Example without shadowing:
```
var foo:T? = getValueFromSomewhere()
if let thisFoo = foo {
	print(thisFoo.someValue)
	foo!.someMutatingMethod()
	foo!.someValue = "Foo"
}
```
In this example we have to use force unwrapping multiple times, even though we know that `foo` is not-nil.

## Proposed solution

The proposed solution is to introduce a new `unwrap` keyword (or similar). This will explicitly check that a variable is non-`nil` and allow the value to be mutated directly.

## Detailed design

The `unwrap` keyword will be usable on any `Optional` variable or property, causing it to behave as a non-`Optional` within that scope. If the variable was immutable, then its unwrapped form remains immutable. To demonstrate with the above example:
```
var foo:T? = getValueFromSomewhere()
if unwrap foo {
	print(foo.someValue)
	foo.someMutatingMethod()
	foo.someValue = "Foo"
}
```
This keyword can be used anywhere that a conditional can normally be used, as well as within `case` statements.

### Unwrapping Properties

An advantage of unwrapping is that it doesn't just apply to simple variables, but also to properties of types, enabling the following:
```
struct Foo { var value:T? }
var foo:Foo = getValueFromSomewhere()
if unwrap foo.value {
	print(foo.value)
	foo.value.someMutatingMethod()
	foo.value.someValue = "Foo"
}
```

### Classes and Concurrency

Unwrapping of classes is not permitted with the default `unwrap` keyword, as this represents a possible concurrency issue if a value unwrapped by the current thread were modified by another. To unwrap a class therefore requires a force operator like so:
```
class Foo { var value:T? }
var foo:Foo = getClassInstanceFromSomewhere()
if unwrap! foo.value {
	print(foo.value)
	foo.value.someMutatingMethod()
	foo.value.someValue = "Foo"
}
```
Behind the scenes all operations on a variable force unwrapped in this way behave as if using the normal force unwrap operator. The difference here however is that as we know that these operations **should** be safe we can now give a more specific runtime error that can point to the potential error being the result of either mutation or concurrent modification.

**NOTE**: The use of a reference type at any level disqualifies force unwrapping, so in the example above `foo.value` cannot be unwrapped normally because `foo` is a reference type, even though `value` isn't.

### `nil` assignment

Once unwrapped it is no longer possible to assign a value of `nil` or an `Optional` to the original variable as normal; this is because the unwrapped variable may itself be an `Optional`, thus assigning `nil` or an `Optional` would alter the unwrapped value (if possible), rather than the original. Consider:
```
var foo:T?? = getValueFromSomewhere()
if unwrap foo { // foo is now T? rather than T??
	foo = nil
}
print(foo) // Prints Optional(nil), not nil
```
In order to assign `nil` or an `Optional` to the original variable after it was unwrapped we must instead use a force operator to assign it. In addition to assigning to the original variable, this also "breaks" the unwrap, causing the type of the variable to revert unless it is unwrapped again. For example:
```
var foo:T? = getValueFromSomewhere()
if unwrap foo { // foo is now type T
	foo = nil! // sets original value to nil and breaks unwrapping
	foo.someMethod() // will not compile, as type is once again T?
}
```

## Impact on existing code

This change is purely additive.

However with this feature implemented it may be desirable to make variable shadowing a warning, particularly in the case of shadowing with a mutable variable, as it should no longer be necessary.

## Alternatives considered

This feature is primarily intended to replace the alternative, namely variable shadowing which, though it works, can be a bit confusing and isn't necessarily the best way to handle optionals in more complex cases. 
