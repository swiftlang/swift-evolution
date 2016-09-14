# Remove type system significance of function argument labels

* Proposal: [SE-0111](0111-remove-arg-label-type-significance.md)
* Author: Austin Zheng
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000216.html), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000233.html)
* Bug: [SR-2009](https://bugs.swift.org/browse/SR-2009)

## Introduction

Swift's type system should not allow function argument labels to be expressed as part of a function type.

Discussion: [pre-proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/021793.html)

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

As currently implemented, this feature can lead to surprising behavior:

```swift
func sinkBattleship(atX x: Int, y: Int) -> Bool { /* ... */ }

func meetsBattingAverage(ofHits hits: Int, forRuns runs: Int) -> Bool { /* ... */ }

var battingAveragePredicate : (ofHits: Int, forRuns: Int) -> Bool = meetsBattingAverage
battingAveragePredicate = sinkBattleship

// sinkBattleship is invoked
battingAveragePredicate(ofHits: 1, forRuns: 2)
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

Writing out a function type containing argument labels will be prohibited:

```swift
// NOT ALLOWED
let fn3 : (a: Int, b: Int) -> Bool

// Must write:
// let fn3 : (Int, Int) -> Bool
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

	// Note that this will be an error:
	// doSomething(x:y:)(x: 10, y: 10)
	```

* If the invocation refers to a value, property, or variable of function type, the argument labels do not need to be supplied. It will be an error to supply argument labels in this situation.

	```swift
	func doSomething(x: Int, y: Int) -> Bool { return true }

	let x = doSomething

	x(10, 10)

	// NOT ALLOWED
	x(x: 10, y: 10)

	// NOT ALLOWED
	x(something: 10, anotherThing: 10)
	```

## Impact on existing code

Minor changes to user code may be required if this proposal is accepted.

Note that this proposal intentionally does not affect the treatment of labeled tuples by the type system (for example, `func homeCoordinates() -> (x: Int, y: Int)`); it only affects parameter lists used to invoke values of function type.

## Alternatives considered

Besides simply not adopting this proposal:

### Allow spelling function types with purely cosmetic argument labels

Rather than prohibiting labels altogther, allow a function type to be written with purely cosmetic argument labels:

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

Instead of having the compiler establish implicit subtyping relationships between function types with identical constituent types but different labels, the labels will simply be ignored outright and all such function types will be considered identical. (This does not affect the programmer experience.)

The primary advantage of this alternative is that it allows the use of cosmetic argument labels as a form of documentation for libraries and modules vending out APIs. It is often more convenient to look at the type signature than to pull up the documentation. (Adopting this alternative would also cause more existing code to stop working than if the main proposal were adopted.)

The primary disadvantage of this alternative is that it may lead users into falsely assuming that argument labels are significant (and that labeling their function types as such will prevent them from improperly assigning a value of `(a: Int, b: Int) -> Void` type to a variable of `(x: Int, b: Int) -> Void` type). It also creates the possibility of users drawing a false equivalence between the definition of parameter lists in function types, and the definition of tuple types with named members (where the labels are significant).

### Prohibit implicit subtyping

Instead of adopting the approach laid out in the main proposal, properly enforce the significance of argument labels in function types by disallowing implicit conversions between functions with identical constituent types and different labels. (It will still be permitted to convert a function type with argument labels into an equivalent function type without labels.)

```swift
func sinkBattleship(atX x: Int, y: Int) -> Bool { /* ... */ }

func meetsBattingAverage(ofHits hits: Int, forRuns runs: Int) -> Bool { /* ... */ }

var battingAveragePredicate : (ofHits: Int, forRuns: Int) -> Bool = meetsBattingAverage

// NOT ALLOWED
// sinkBattleship has incompatible argument labels
battingAveragePredicate = sinkBattleship

// Okay
var genericFunc : (Int, Int) -> Bool = sinkBattleship
genericFunc = battingAveragePredicate
```
