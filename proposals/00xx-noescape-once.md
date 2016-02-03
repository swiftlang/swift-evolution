# Marking closures as executing exactly once

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Swift Developer](https://github.com/swiftdev)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal introduces an optional `once` argument to the `@noescape`
attribute. The `@noescape(once)` attribute enforces that the closure does not
escape, and that it is run exactly once on any code path returning from the
function. For clients, it allows the compiler to relax initialization
requirements and close the gap between closure and "inline code" a little bit.

Swift-evolution thread: [Guaranteed closure execution](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160125/008167.html)

## Motivation

In Swift, multiple functions execute a closure to temporarily grant code
special guarantees. For instance, the standard library's `withUnsafePointer`
affords the closure with a pointer to an object's representation, and the
`autoreleasepool` function wraps a closure with code that creates (and later
destroys) an autorelease pool.

Currently, if you want to initialize a variable inside such a closure, you need
to make it mutable and initially assign it a dummy value, because the compiler
can't prove that the function will execute the closure exactly once. For
instance:

	var x: Int = 0 // `var` declaration, with some irrelevant value
	f { x = 1 }
	print(x)

## Proposed solution

By adding the `@noescape(once)` attribute to the closure parameter, we tell the
compiler that the function will be executed exactly once on any code path that
leaves the function's scope:

	func f(@noescape(once) closure: () -> ()) {
	    closure()
	}

With this information, the compiler can now realize that the `x` variable will
be written to exactly once. It can now be marked as a `let` variable:

	let x: Int  // Not initialized
	f { x = 1 }
	print(x)    // Guaranteed to be initialized

This new form is safer and cleaner, as the compiler will prevent you from
assigning to `x` more than once.

## Detailed design

In addition to the regular advantages and constraints applied to `@noescape`
parameters, `@noescape(once)` parameters must be called exactly once on any code
path where the function returns. Specifically:

* passing it to another function that accepts a `@noescape(once)` closure of the
	same type is allowed and counts as executing it once;
* it is required to be executed on code paths that throw;
* it is not required to be executed on a code path that calls a function that
	does not return.

A `@noescape(once)` closure may only read from variables that were initialized
before it was formed. For instance, in an example with two `@noescape(once)`
closures, the compiler cannot assume that one closure runs before the other.

    func f(@noescape(once) a: () -> (), @noescape(once) b: () -> ()) { /* snip */ }
    
    let x: Int
    f({x = 1}) { print(x) } // invalid: x has not been initialized

A `@noescape(once)` parameter may only be passed as a parameter to another
function that accepts a `@noescape(once)` parameter. In that case, it counts as
having been called.

A closure passed with a `@noescape(once)` parameter may initialize `let` or
`var` variables from its parent scope as if it was executed at the call site.

(Probably incomplete?)

## Impact on existing code

This feature is purely additive. Existing code will continue to work as
expected.

## Alternatives considered

It was mentioned in the discussion that the "once" behavior and `@noescape` look
orthogonal, and the "once" behavior could be useful on closures that escape.
However, it is only possible to verify that a closure has been executed exactly
once if it does not escape. Because of this, "once" and `@noescape` are better
left together.

