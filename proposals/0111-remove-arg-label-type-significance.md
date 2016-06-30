# Remove type system significance of function argument labels

* Proposal: [SE-0111](0111-remove-arg-label-type-significance.md)
* Author: Austin Zheng
* Status: **Active review June 30 ... July 4 **
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

Swift's type system should not allow function argument labels to be expressed as part of a function type.

Discussion: [pre-proposal](http://thread.gmane.org/gmane.comp.lang.swift.evolution/21369)

## Motivation

Right now, argument labels are considered significant by the type system, and the type system establishes subtyping relationships between function types with and without argument labels. Here is an example:

```swift
func doSomething(x: Int, y: Int) -> Bool {
	return x == y
}

let fn1 : (Int, Int) -> Bool = doSomething
// Okay
fn1(1, 2)

// fn2's type is actually (x: Int, y: Int) -> Bool
let fn2 = doSomething

// Okay
fn2(x: 1, y: 2)
// NOT ALLOWED
fn2(1, 2)
```

Removing this feature simplifies the type system. It also changes the way argument labels are treated to be consistent with how default arguments are treated; that is, tied to a declaration and not part of the type system:

> Essentially, argument labels become part of the names of declarations (only!), which is consistent with our view that the names of functions/methods/initializers include all of the argument names.

## Proposed solution

We propose simplifying the type system by removing the significance of the argument labels from the type system. Function types may only be defined in terms of the types of the formal parameters and the return value.

```swift
func doSomething(x: Int, y: Int) -> Bool {
	return x == y
}

func somethingElse(a: Int, b: Int) -> Bool {
	return a > b
}

// fn2's type is (Int, Int) -> Bool
var fn2 = doSomething

// Okay
fn2(1, 2)

// Okay
fn2 = somethingElse
```

Writing out a function type containing argument labels will continue to be allowed, as such labels may serve as documentation for consumers of the API.

Rather than the compiler establishing implicit subtyping relationships between function types with identical constituent types but different labels, the labels will simply be ignored outright and all such function types will be considered identical. (This does not affect the programmer experience.)

```swift
var fn3 : (x: Int, y: Int) -> Bool
var fn4 : (a: Int, b: Int) -> Bool

func foo(a: Int, b: Int) -> Bool { return false }

// All okay
fn3 = foo
fn4 = foo
fn3 = fn4
fn4 = fn3
```

This change would also allow functions referred to by their fully-qualified names to be invoked without redundancy:

```swift
// Before:
doSomething(x:y:)(x: 10, y: 10)

// After:
doSomething(x:y:)(10, 10)
```

## Detailed design

The examples above demonstrate when argument labels are and aren't necessary when invoking a function or function-like member.

More formally, the rules for when argument labels are necessary follow the rules for default arguments, and can be spelled out as such:

* If the invocation refers directly to the name of the function as stated in the declaration, the argument labels need to be supplied: either in the reference, or in the argument list itself.

	```swift
	func doSomething(x: Int, y: Int) -> Bool { return true }

	// In the reference
	doSomething(x:y:)(10, 10)

	// In the argument list
	doSomething(x: 10, y: 10)
	```

* If the invocation refers to a value, property, or variable of function type, the argument labels do not need to be supplied.

	```swift
	func doSomething(x: Int, y: Int) -> Bool { return true }

	let x = doSomething

	x(10, 10)
	```

## Impact on existing code

Minor changes to user code may be required if this proposal is accepted.

Note that this proposal intentionally does not affect the treatment of labeled tuples by the type system (for example, `func homeCoordinates() -> (x: Int, y: Int)`); it only affects parameter lists used to invoke values of function type.

## Alternatives considered

Don't adopt this proposal. Also:

### Prohibit spelling function types with argument labels

Rather than allowing purely cosmetic argument labels to be written as part of a function type, prohibit labels altogether:

```swift
// NOT ALLOWED
let a : (a: Int, b: Int) -> Bool

// Must write:
// let a : (Int, Int) -> Bool
```

The primary disadvantage of this alternative is that it prohibits the use of cosmetic argument labels as a form of documentation for libraries and modules vending out APIs. It is often more convenient to look at the type signature than to pull up the documentation. (Adopting this alternative would also cause more existing code to stop working than if the main proposal were adopted.)

The primary advantage of this alternative is that it prevents users from falsely assuming that argument labels are significant (and that labeling their function types as such will prevent them from improperly assigning a value of `(a: Int, b: Int) -> Void` type to a variable of `(x: Int, b: Int) -> Void` type). It also removes the possibility of users drawing a false equivalence between the definition of parameter lists in function types, and the definition of tuple types with named members (where the labels are significant).
