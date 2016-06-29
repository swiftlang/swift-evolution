# Remove type system significance of function argument labels

* Proposal: [SE-0111](0111-remove-arg-label-type-significance.md)
* Author: Austin Zheng
* Status: **Awaiting review**
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

Removing this feature simplifies the type system and brings its behavior in line with the intended semantics of Swift naming:

> Essentially, argument labels become part of the names of declarations (only!), which is consistent with our view that the names of functions/methods/initializers include all of the argument names.

## Proposed solution

We propose simplifying the type system by removing the significance of the argument labels from the type system. Function types may only be defined in terms of the types of the formal parameters and the return value, and writing out a function type that includes argument labels is disallowed:

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

// NOT ALLOWED
let badFn : (x: Int, y: Int) -> Bool
```

This change would also allow functions referred to by their fully-qualified names to be invoked without redundancy:

```swift
// Before:
doSomething(x:y:)(x: 10, y: 10)

// After:
doSomething(x:y:)(10, 10)
```

## Impact on existing code

Minor changes to user code may be required if this proposal is accepted.

## Alternatives considered

Don't make this change.
